//============================================================================
//  mc_gio_dma - the MC's GIO64 DMA engine: fill, and both copy directions.
//
//  WHY THE COPY MODES EXIST NOW, AND IT IS NOT A FEATURE REQUEST EITHER.
//  This engine used to implement fill-to-memory alone - the mode the PROM's
//  boot memory clear uses - on the argument that "this machine HAS no GIO64
//  device". That argument died the day the Newport went in: IRIX's ng1 driver
//  moves EVERY pixel X draws through this engine (Ng1PixelDma -> vdma_set_tlb
//  -> MCdma in the kernel, disassembled in docs/33), as memory-to-GIO
//  transfers into REX3's HOSTRW port, with the source address translated
//  through the MC's own four-entry DMA TLB. The old stub reported those
//  transfers instantly finished without moving a byte and without raising the
//  DMA-done interrupt, so X sat on a semaphore until its timer fired:
//  `ng1 pixel dma write timeout`, and a black desktop with a working cursor.
//
//  THE REFERENCE IS IRIS's dma_worker AND translate_addr IN src/mc.rs,
//  transcribed loop for loop. The register semantics:
//
//    line_count = size[31:16]     line_width = size[15:0]
//    line_zoom  = stride[25:16]   stride     = signed(stride[15:0])
//    zoom_count = count[25:16]    byte_count = count[15:0]
//
//    for line_count lines:
//        for zoom_count reps:
//            move bytes until byte_count runs out
//            byte_count reloads from line_width
//            between reps the address rewinds by line_width
//        zoom_count reloads from line_zoom
//        the address advances by the signed stride
//
//  FILL writes gio_adr (low three bits cleared) as 32-bit words to memory.
//  MEM->GIO packs up to eight bytes per beat, MSB first - the byte at the
//  lowest address in wdata[63:56] - and writes each beat to the SAME GIO
//  address; the address never increments, because on the far end it is
//  REX3's HOSTRW register with the GO bit, not a buffer. GIO->MEM is the
//  reverse: one 64-bit read per beat, bytes scattered to memory MSB first.
//  A short final beat is padded with zeros, exactly as IRIS pads it.
//
//  TRANSLATION (DMA_CTL bit 8). The memory-side address of a copy is a
//  VIRTUAL address: the µTLB's four entries (tag = vaddr[31:22]) each point
//  at a page-table fragment in physical memory, and the engine fetches the
//  PTE itself - ctl bit 0 picks 4- or 8-byte PTEs, ctl bit 1 picks 4 or 16 KB
//  pages. PTE bit 1 is valid, bit 2 is writable. Faults set the matching
//  DMA_CAUSE bit (FAULT=1, TLB_MISS=2, CLEAN=4), abort the transfer, and
//  raise the interrupt whatever INT_ENABLE says - IRIS does exactly that.
//  One translation is cached, because consecutive beats stay on a page.
//
//  WHAT IS STILL SKIPPED: descending copies (MODE_DIR clear). IRIX's ng1
//  always sets DIR - mode 0x50 for writes, 0x52 for reads - and nothing else
//  in either PROM or kernel issues a descending copy. A skipped mode still
//  reports an instantly-finished transfer with `mode_unsupported` on the
//  wire, which is the old stub's behaviour and the reason the PROM never
//  wedged on it.
//============================================================================

module mc_gio_dma (
    input  logic        clk,
    input  logic        reset,

    // ---- the latched descriptor, and go ---------------------------------
    // `start` is a one-cycle pulse from sgi_mc's register write. Everything
    // is sampled on that pulse and never read again: the CPU is free to
    // rewrite the registers the moment the transfer is running.
    input  logic        start,
    input  logic [31:0] d_memadr,
    input  logic [31:0] d_size,
    input  logic [31:0] d_stride,
    input  logic [31:0] d_gio_adr,
    input  logic [31:0] d_mode,
    input  logic [31:0] d_count,
    input  logic [31:0] d_ctl,
    // The four hi/lo µTLB pairs, flattened: entry n's hi word at
    // [64n +: 32], its lo word at [64n+32 +: 32]. Sampled live, not
    // latched - the driver programs them before every start.
    input  logic [255:0] tlb_flat,

    output logic        busy,
    output logic        done,              // one cycle, when a transfer ends
    output logic        mode_unsupported,  // held with `done` for a mode we skip
    // Held with `done`: the DMA_CAUSE bits this transfer earned.
    // fault[0]=FAULT (invalid PTE), [1]=TLB_MISS, [2]=CLEAN (write to a
    // clean page). All zero on success.
    output logic  [2:0] fault,
    // Held with `done` on a transfer that actually ran: the final memory
    // address, for sgi_mc's descriptor writeback (IRIS updates memadr and
    // clears size's line count and the whole count register at the end).
    output logic        wb_valid,
    output logic [31:0] wb_memadr,

    // ---- memory bus master ------------------------------------------------
    // Same shape and byte-lane convention as the HPC3's SCSI channel:
    // `wdata[63-8i -: 8]` is the byte at `addr+i` and `be[7-i]` guards it.
    // Held until `ack`. Reads answer on `rdata` with `ack`.
    output logic        m_req,
    output logic        m_we,
    output logic [31:0] m_addr,            // physical, doubleword aligned
    output logic [63:0] m_wdata,
    output logic  [7:0] m_be,
    input  logic [63:0] m_rdata,
    input  logic        m_ack,

    // ---- GIO bus master ---------------------------------------------------
    // One 64-bit beat per transaction at the descriptor's GIO address,
    // held until `ack`. sgi_indy routes it to the Newport's DMA port.
    output logic        g_req,
    output logic        g_we,
    output logic [31:0] g_addr,
    output logic [63:0] g_wdata,
    input  logic [63:0] g_rdata,
    input  logic        g_ack,

    // ---- observability ----------------------------------------------------
    // {state[3:0], last fault[2:0], skip, beats[15:0]} - a beacon word half.
    output logic [23:0] dbg
);

    // Mode/ctl bits, from IRIS's mc.rs.
    localparam int MODE_TO_HOST = 1;
    localparam int MODE_FILL    = 3;
    localparam int MODE_DIR     = 4;
    localparam int CTL_PTE8     = 0;
    localparam int CTL_PG16K    = 1;
    localparam int CTL_XLATE    = 8;

    typedef enum logic [3:0] {
        S_IDLE, S_CHECK, S_BEAT, S_MEMA, S_MEMB, S_GIO, S_PTE, S_STEP, S_DONE
    } state_t;
    state_t state;

    // What kind of transfer this is, decided once at start.
    typedef enum logic [1:0] { K_FILL, K_M2G, K_G2M } kind_t;
    kind_t kind;

    logic [15:0] line_count, line_width, byte_count;
    logic  [9:0] zoom_count, line_zoom;
    logic [15:0] stride;
    logic [31:0] vaddr, gio_adr, fill;
    logic        dir_up, skip, xlate, pte8, pg16k;

    // Per-beat working set, latched in S_BEAT.
    logic  [3:0] beat_len;                 // 1..8 bytes this beat moves
    logic  [2:0] lane0;                    // vaddr's lane within its qword
    logic  [3:0] n0;                       // bytes in the first aligned qword
    logic [63:0] beat;                     // the packed qword, MSB first

    // One-entry translation cache. `tag` is vaddr >> page_shift; `base` is
    // the PTE's frame as a byte address; `wr_ok` is PTE bit 2.
    logic        c_valid, c_wrok;
    logic [19:0] c_tag;
    logic [31:0] c_base;

    logic  [2:0] fault_code;
    logic [15:0] beats;

    // `stride` is signed 16-bit added to a 32-bit address.
    wire [31:0] stride_ext = {{16{stride[15]}}, stride};
    wire [31:0] width_ext  = {16'h0, line_width};

    // ---- mode decode ------------------------------------------------------
    wire is_fill = d_mode[MODE_FILL] && d_mode[MODE_TO_HOST];
    wire is_m2g  = !d_mode[MODE_FILL] && !d_mode[MODE_TO_HOST] && d_mode[MODE_DIR];
    wire is_g2m  = !d_mode[MODE_FILL] &&  d_mode[MODE_TO_HOST] && d_mode[MODE_DIR];
    wire supported = is_fill || is_m2g || is_g2m;

    // ---- the two memory sub-accesses of a beat ----------------------------
    // A beat's bytes are contiguous ascending from `vaddr`, so they live in
    // at most two aligned qwords: A holds the first `n0`, B the rest.
    wire [31:0] suba_addr = vaddr;
    wire [31:0] subb_addr = {vaddr[31:3], 3'b000} + 32'd8;
    // Which one the machine is working on right now - S_PTE remembers whose
    // translation it went to fetch.
    logic       xl_for_b;
    wire        on_b     = (state == S_MEMB) || ((state == S_PTE) && xl_for_b);
    wire [31:0] xl_vaddr = on_b ? subb_addr : suba_addr;

    // ---- translation ------------------------------------------------------
    wire [4:0]  page_shift = pg16k ? 5'd14 : 5'd12;
    wire [31:0] page_mask  = pg16k ? 32'h0000_3FFF : 32'h0000_0FFF;

    wire [19:0] xl_tag = xl_vaddr >> page_shift;
    wire        c_hit  = c_valid && (c_tag == xl_tag);

    // µTLB match, priority entry 0 first - IRIS walks 0..3 and takes the
    // first tag hit, valid or not.
    logic        tlb_found;
    logic [31:0] tlb_lo_hit;
    always_comb begin
        tlb_found  = 1'b0;
        tlb_lo_hit = 32'h0;
        for (int i = 3; i >= 0; i--) begin
            if (tlb_flat[64*i +: 32] >> 22 == xl_vaddr >> 22) begin
                tlb_found  = 1'b1;
                tlb_lo_hit = tlb_flat[64*i + 32 +: 32];
            end
        end
    end

    // PTEBase is TLBLO's [25:6] as a frame number: `(lo & 0x03ffffc0) << 6`
    // in IRIS, i.e. a byte address with those bits at [31:12]. VPNlo indexes
    // the fragment by PTE size.
    wire [31:0] pte_base = {tlb_lo_hit[25:6], 12'b0};
    wire [31:0] vpn_lo   = (xl_vaddr & 32'h003F_FFFF) >> page_shift;
    wire [31:0] pte_addr = pte_base + (pte8 ? (vpn_lo << 3) : (vpn_lo << 2));

    // The PTE out of the fetched qword: 8-byte PTEs take the low word (IRIS
    // reads 64 bits and keeps the bottom); 4-byte PTEs take the word the
    // address names - on this big-endian bus the word at +0 is rdata[63:32].
    wire [31:0] pte_word = pte8        ? m_rdata[31:0]
                         : pte_addr[2] ? m_rdata[31:0]
                                       : m_rdata[63:32];

    // Physical address of the current sub-access, once translation holds.
    wire [31:0] sub_phys = xlate ? (c_base | (xl_vaddr & page_mask))
                                 : xl_vaddr;

    // Whether the memory side of this transfer WRITES (fill and GIO->MEM do).
    wire mem_is_write = (kind != K_M2G);

    // ---- beat geometry, computed in S_BEAT --------------------------------
    wire [2:0] lane0_c = vaddr[2:0];
    wire [3:0] max0_c  = 4'd8 - {1'b0, lane0_c};
    // Fill steps four bytes at a time in IRIS - but an aligned ascending
    // fill with eight or more to go writes the pattern twice per beat and
    // covers eight, which leaves the identical memory image in half the
    // writes. That is not a luxury: the PROM's boot clear is ONE descriptor
    // covering all of RAM (2048 lines of 32 KB at 0xbfc01264), the CPU polls
    // RUN for the whole of it, and a slower-than-the-old-engine fill pushed
    // the sim boot past its stuck detector. Descending or unaligned fills
    // keep the reference's four-byte steps. Copies move up to eight bytes.
    logic [3:0] len_c;
    always_comb begin
        if (kind == K_FILL)
            len_c = (dir_up && lane0_c == 3'd0 && byte_count >= 16'd8)
                    ? 4'd8 : 4'd4;
        else if (byte_count >= 16'd8) len_c = 4'd8;
        else                          len_c = byte_count[3:0];
    end
    wire [3:0] n0_c = (len_c > max0_c) ? max0_c : len_c;

    // Byte enables for a sub-access of n bytes starting at lane o:
    // be[7-i] guards byte i, so the mask is n ones shifted down by o.
    function automatic logic [7:0] be_of(input logic [2:0] o, input logic [3:0] n);
        logic [7:0] m;
        begin
            m = 8'hFF << (4'd8 - n);
            be_of = m >> o;
        end
    endfunction

    // Zero everything past `n` bytes of a beat, as IRIS's packing does.
    function automatic logic [63:0] mask_len(input logic [63:0] v,
                                             input logic [3:0] n);
        if (n >= 4'd8) mask_len = v;
        else           mask_len = v & (64'hFFFF_FFFF_FFFF_FFFF
                                       << {(4'd8 - n), 3'b000});
    endfunction

    // ---- bus masters -------------------------------------------------------
    // Sub A's write data: stream byte 0 belongs at lane `lane0`. Sub B's
    // remaining bytes start at lane 0 of the next qword.
    wire [63:0] wdat_a = beat >> {lane0, 3'b000};
    wire [63:0] wdat_b = beat << {n0, 3'b000};

    wire on_pte = (state == S_PTE);
    // A memory sub-access may not leave while its translation is unresolved
    // or faulted - `sub_phys` would carry a stale cache entry, and the
    // arbiter latches a held request the cycle it sees it.
    wire xl_ok  = !xlate || (c_hit && !(mem_is_write && !c_wrok));
    assign m_req   = ((state == S_MEMA) || (state == S_MEMB)) && xl_ok
                   || on_pte;
    assign m_we    = on_pte ? 1'b0 : mem_is_write;
    assign m_addr  = on_pte ? {pte_addr[31:3], 3'b000}
                            : {sub_phys[31:3], 3'b000};
    assign m_wdata = (state == S_MEMB) ? wdat_b : wdat_a;
    assign m_be    = (state == S_MEMB) ? be_of(3'd0, beat_len - n0)
                                       : be_of(lane0, n0);

    assign g_req   = (state == S_GIO);
    assign g_we    = (kind == K_M2G);
    assign g_addr  = gio_adr;
    assign g_wdata = beat;

    assign busy    = (state != S_IDLE);

    assign dbg = {state, fault_code, skip, beats};

    // The memory states stall on translation before their request may leave;
    // these three name the outcomes so the state arms below stay readable.
    wire xl_need  = xlate && !c_hit;
    wire xl_miss  = xl_need && (!tlb_found || !tlb_lo_hit[1]);
    wire xl_clean = xlate && c_hit && mem_is_write && !c_wrok;

    always_ff @(posedge clk) begin
        if (reset) begin
            state            <= S_IDLE;
            done             <= 1'b0;
            mode_unsupported <= 1'b0;
            fault            <= 3'b0;
            wb_valid         <= 1'b0;
            wb_memadr        <= 32'h0;
            fault_code       <= 3'b0;
            beats            <= 16'h0;
            c_valid          <= 1'b0;
            xl_for_b         <= 1'b0;
        end else begin
            done     <= 1'b0;
            wb_valid <= 1'b0;

            case (state)
                S_IDLE: if (start) begin
                    line_count <= d_size[31:16];
                    line_width <= d_size[15:0];
                    line_zoom  <= d_stride[25:16];
                    stride     <= d_stride[15:0];
                    zoom_count <= d_count[25:16];
                    byte_count <= d_count[15:0];
                    vaddr      <= d_memadr;
                    gio_adr    <= d_gio_adr;
                    fill       <= {d_gio_adr[31:3], 3'b000};
                    dir_up     <= d_mode[MODE_DIR];
                    xlate      <= d_ctl[CTL_XLATE];
                    pte8       <= d_ctl[CTL_PTE8];
                    pg16k      <= d_ctl[CTL_PG16K];
                    kind       <= is_fill ? K_FILL : is_m2g ? K_M2G : K_G2M;
                    skip       <= !supported;
                    fault_code <= 3'b0;
                    c_valid    <= 1'b0;
                    beats      <= 16'h0;
                    xl_for_b   <= 1'b0;
                    // A descriptor with no lines finishes instantly - that is
                    // not an error and must not run for ever.
                    state      <= (!supported || d_size[31:16] == 16'h0)
                                  ? S_DONE : S_CHECK;
                end

                // The `while byte_count > 0` test and the unwinding of the
                // two outer counts, straight from IRIS's loops. byte_count
                // always reloads from line_width, never from what it started
                // at: the first pass can be a different length from the rest.
                S_CHECK:
                    if (byte_count != 16'h0) begin
                        state <= S_BEAT;
                    end else begin
                        byte_count <= line_width;
                        if (zoom_count > 10'd1) begin
                            zoom_count <= zoom_count - 10'd1;
                            // Rewind to the start of the line; `vaddr` has
                            // already stepped past the last byte.
                            vaddr      <= dir_up ? vaddr - width_ext
                                                 : vaddr + width_ext;
                        end else begin
                            // End of the line: zoom reloads and the stride
                            // advances - and, exactly as in IRIS's loop, both
                            // happen after the LAST line too, so the
                            // written-back memadr includes the final stride.
                            // vdma_wait polls memadr for progress and the
                            // fault handler restarts from it; the value has
                            // to be the reference's, not almost-it.
                            zoom_count <= line_zoom;
                            vaddr      <= vaddr + stride_ext;
                            line_count <= line_count - 16'd1;
                            if (line_count <= 16'd1) state <= S_DONE;
                        end
                    end

                // Latch this beat's geometry and dispatch it.
                S_BEAT: begin
                    beat_len <= len_c;
                    lane0    <= lane0_c;
                    n0       <= n0_c;
                    xl_for_b <= 1'b0;
                    case (kind)
                        // Fill is a write beat with the pattern preloaded in
                        // both words - the byte enables trim a 4-byte step -
                        // reusing the copy path's scatter.
                        K_FILL:  begin beat <= {fill, fill}; state <= S_MEMA; end
                        K_M2G:   begin beat <= 64'h0;        state <= S_MEMA; end
                        default: begin beat <= 64'h0;        state <= S_GIO;  end
                    endcase
                end

                // First aligned qword of the memory side. Translation runs
                // before the request leaves: a cache miss detours through
                // S_PTE and comes back here with the entry filled.
                S_MEMA: begin
                    if (xl_miss) begin
                        fault_code <= 3'b010;              // TLB_MISS
                        state      <= S_DONE;
                    end else if (xl_need) begin
                        xl_for_b <= 1'b0;
                        state    <= S_PTE;
                    end else if (xl_clean) begin
                        fault_code <= 3'b100;              // CLEAN
                        state      <= S_DONE;
                    end else if (m_ack) begin
                        if (kind == K_M2G)
                            beat <= mask_len(m_rdata << {lane0, 3'b000},
                                             beat_len);
                        if (beat_len > n0)
                            state <= S_MEMB;
                        else
                            state <= (kind == K_M2G) ? S_GIO : S_STEP;
                    end
                end

                // Second aligned qword, when the beat crosses one.
                S_MEMB: begin
                    if (xl_miss) begin
                        fault_code <= 3'b010;
                        state      <= S_DONE;
                    end else if (xl_need) begin
                        xl_for_b <= 1'b1;
                        state    <= S_PTE;
                    end else if (xl_clean) begin
                        fault_code <= 3'b100;
                        state      <= S_DONE;
                    end else if (m_ack) begin
                        if (kind == K_M2G)
                            beat <= mask_len(beat | (m_rdata >> {n0, 3'b000}),
                                             beat_len);
                        state <= (kind == K_M2G) ? S_GIO : S_STEP;
                    end
                end

                // Fetch the PTE the matched µTLB entry points at, check it,
                // cache the translation, and resume the sub-access.
                S_PTE: if (m_ack) begin
                    if (!pte_word[1]) begin
                        fault_code <= 3'b001;              // FAULT
                        state      <= S_DONE;
                    end else if (mem_is_write && !pte_word[2]) begin
                        fault_code <= 3'b100;              // CLEAN
                        state      <= S_DONE;
                    end else begin
                        c_valid <= 1'b1;
                        c_tag   <= xl_tag;
                        c_base  <= {pte_word[25:6], 12'b0};
                        c_wrok  <= pte_word[2];
                        state   <= xl_for_b ? S_MEMB : S_MEMA;
                    end
                end

                // The GIO beat: a write for MEM->GIO, a read for GIO->MEM.
                S_GIO: if (g_ack) begin
                    beats <= beats + 16'd1;
                    if (kind == K_G2M) begin
                        beat  <= mask_len(g_rdata, beat_len);
                        state <= S_MEMA;
                    end else
                        state <= S_STEP;
                end

                // The step every finished beat takes. An ascending fill or
                // copy advances by what the beat moved; a descending fill
                // steps its reference four.
                S_STEP: begin
                    if (kind == K_FILL && !dir_up)
                        vaddr <= vaddr - 32'd4;
                    else
                        vaddr <= vaddr + {28'h0, beat_len};
                    byte_count <= (byte_count > {12'h0, beat_len})
                                  ? byte_count - {12'h0, beat_len} : 16'd0;
                    state <= S_CHECK;
                end

                S_DONE: begin
                    done             <= 1'b1;
                    mode_unsupported <= skip;
                    fault            <= fault_code;
                    wb_valid         <= !skip;
                    wb_memadr        <= vaddr;
                    state            <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
