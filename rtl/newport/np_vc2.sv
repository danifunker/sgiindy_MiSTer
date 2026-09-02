//============================================================================
//  np_vc2 - Newport's video controller: video timing, cursor, display IDs.
//
//  THE VIDEO TIMING TABLE IS A PROGRAM AND THIS IS ITS INTERPRETER. There is
//  no 1280x1024 anywhere in this file, and there must not be: the PROM loads
//  one of np_timing.h's tables into the external SRAM and VC2 emits whatever
//  that table says, which is how one chip drove every monitor SGI shipped.
//
//  Format, from vc2.pdf section 3.4.1, confirmed against np_timing.h:
//
//    frame table   a list of (line-sequence pointer, line count) pairs at
//                  VIDEO_ENTRY_PTR. A count of zero ends the frame and
//                  restarts the list.
//    line          a list of state runs, followed by a pointer to the next
//                  line of the sequence. Every table in np_timing.h has each
//                  line point at itself, so a sequence is one line repeated.
//    state run     one or two 16-bit words:
//                    word 0: [15] end of line, [14:8] duration in units of
//                            two pixel clocks, [7] state B/C absent,
//                            [6:0] state A
//                    word 1: [15] end of line, [14:8] state B, [7] one,
//                            [6:0] state C
//                  State B and C persist across runs that omit them.
//
//  THE FIELD SPLIT IS WORTH CHECKING RATHER THAN TRUSTING, because the other
//  reading - state in the high field, duration in the low - also parses.
//  Decode n1280_ltab's first line with the rule above and the durations sum
//  to 841 two-pixel units = 1682 pixels, which is exactly
//  107.5 MHz / (60 Hz * 1065 lines), and the one 57-count run is the hsync
//  pulse at 114 pixels against 112 in the VESA timing for that mode. The
//  other reading gives 1258, which is not the horizontal total of anything.
//
//  Of the 21 timing channels this drives five: horizontal and vertical sync
//  and the vertical interrupt out of state C, the display enable out of state
//  A, and horizontal blanking out of state B. The rest are recorded and
//  unused - the VRAM transfer requests and serial enables belong to a VRAM
//  shift register this core does not have, because its frame buffer is
//  addressed rather than clocked out.
//
//  THE CURSOR IS BUILT, and it comes out of this same SRAM. `CURSOR_ENTRY`
//  points at the glyph; DC_CONTROL[7] enables it and [9] picks 64x64 one-plane
//  or 32x32 two-plane, the second plane sixty-four words further on. The
//  position registers are working copies the chip latches for itself - X when
//  software writes CURSOR_Y, Y at the vertical position pulse - and the hot
//  spot is 31 pixels up and to the left of what they hold.
//
//  A ROW IS FETCHED PER LINE, DURING BLANKING, and that is what keeps it out
//  of the way. Four words cover any row in either size, the line advance
//  happens on the falling edge of display enable, and there are hundreds of
//  blank pixel times after it - so the fetch never competes with the timing
//  generator for anything that matters, and it takes the read port on the same
//  terms the host does, by re-arming `fetch_wait`.
//
//  Its colours are NOT the BT445's cursor colour registers. See the port
//  comment on `cursor_pix`. See also docs/16-newport-plan.md, milestone N4.
//
//  ONE READ PORT, SHARED. The SRAM is a write port plus a single read port so
//  it infers as one simple dual-port memory rather than two copies. The host
//  takes the read port for the cycle it asks, and the timing generator's
//  fetch simply reissues - `fetch_wait` is re-armed - because its address is
//  held. Host reads of this SRAM are a diagnostic path; the PROM only writes
//  it, so the stolen cycle costs nothing on the boot path.
//============================================================================

module np_vc2 #(
    // The real part has a 32K x 16 external SRAM and the DID frame table is
    // one word per scanline, so this is not obviously oversized. The PROM's
    // video timing tables live at word 0 and word 0x400.
    parameter int RAM_WORDS = 32768,
    // Core clocks per pixel. The timing generator counts in units of two
    // pixel clocks, as the chip does. Two is the default so the frame buffer
    // read port is not asked for a word every single clock.
    parameter int PIX_DIV   = 2
) (
    input  logic        clk,
    input  logic        reset,

    // ---- Display Control Bus, from REX3 ----------------------------------
    input  logic        sel,
    input  logic        we,
    input  logic  [1:0] crs,        // 0 index, 1 high byte, 2 low byte, 3 RAM
    input  logic  [1:0] width,      // DCBMODE data width: 0 = 4 bytes, 1..3 = n
    input  logic [31:0] wdata,
    output logic [15:0] rdata,

    // ---- video output ----------------------------------------------------
    output logic        ce_pix,
    output logic        hsync,      // active high
    output logic        vsync,      // active high
    output logic        de,         // display enable
    output logic        hblank,
    output logic        vblank,
    // Where the pixel being emitted lives in the frame buffer, valid with
    // `de`. The readout side turns this into an address.
    output logic [10:0] pix_x,
    output logic [10:0] pix_y,
    // VERT_INT_REX_N as a one-clock pulse on its assertion.
    output logic        vert_int,

    // ---- the cursor ------------------------------------------------------
    // Two bits per pixel, valid with `pix_x`/`pix_y`, zero where the cursor is
    // not. Non-zero selects one of three colours - and NOT from the BT445's
    // cursor colour registers, which is where this was going to read them
    // from. IRIS's compositor takes them from CMAP at
    // (xmap cursor_cmap_msb << 5) | value (rex3.rs, compositor.rs); the DAC's
    // own cursor registers belong to its hardware cursor, which Newport does
    // not use. Checking the reference before building saved a wrong feature.
    output logic  [1:0] cursor_pix,

    // ---- the display ID --------------------------------------------------
    // The 5-bit DID for the pixel at `pix_x`/`pix_y`, from the DID table in
    // this SRAM - the per-window mechanism X uses to give every window its
    // own XMAP mode. Zero when DC_CONTROL's DID enable is clear, which is
    // the whole-screen-entry-0 world the PROM console lives in.
    output logic  [4:0] did,
    // {DID enable, walker state} for the DDR3 beacon (docs/33).
    output logic  [3:0] dbg_did
);

    localparam logic [4:0] R_VIDEO_ENTRY   = 5'h00;
    localparam logic [4:0] R_CURSOR_ENTRY  = 5'h01;
    localparam logic [4:0] R_CURSOR_X      = 5'h02;
    localparam logic [4:0] R_CURSOR_Y      = 5'h03;
    localparam logic [4:0] R_CUR_CURSOR_X  = 5'h04;
    localparam logic [4:0] R_DID_ENTRY     = 5'h05;
    localparam logic [4:0] R_SCANLINE_LEN  = 5'h06;
    localparam logic [4:0] R_RAM_ADDR      = 5'h07;
    localparam logic [4:0] R_VT_FRAME_PTR  = 5'h08;
    localparam logic [4:0] R_VT_LINE_SEQ   = 5'h09;
    localparam logic [4:0] R_VT_LINES_RUN  = 5'h0A;
    localparam logic [4:0] R_VERT_LINE_CTR = 5'h0B;
    localparam logic [4:0] R_CURS_TABLE_PTR = 5'h0C;
    localparam logic [4:0] R_WORK_CURSOR_Y  = 5'h0D;
    localparam logic [4:0] R_DC_CONTROL    = 5'h10;
    localparam logic [4:0] R_CONFIG        = 5'h1F;

    localparam int AW = $clog2(RAM_WORDS);

    logic [15:0] regs [32];
    logic  [4:0] index;
    logic [15:0] ram  [RAM_WORDS];

    wire [14:0] ram_addr = regs[R_RAM_ADDR][14:0];

    // ---- host side -------------------------------------------------------
    // CRS 1 addresses the high byte and CRS 2 the low byte for byte-wide
    // transfers; a 16-bit transfer through CRS 1 writes the whole register.
    // A 32-bit write through CRS 0 carries the index in [28:24] and the data
    // in [23:8], which is how vc2SetReg does it in one DCB cycle.
    wire is_byte = (width == 2'd1);
    wire is_word = (width == 2'd2);

    logic [15:0] host_val;
    logic  [4:0] host_idx;
    logic        host_reg_wr, host_idx_wr, host_ram_wr, host_ram_rd;

    always_comb begin
        host_val    = 16'h0;
        host_idx    = index;
        host_reg_wr = 1'b0;
        host_idx_wr = 1'b0;
        host_ram_wr = 1'b0;
        host_ram_rd = 1'b0;
        if (sel && we) begin
            case (crs)
                2'd0: begin
                    if (is_byte || is_word) begin
                        // A byte-wide DCB transfer delivers its datum in the
                        // low byte, the same end the driver stored it at.
                        host_idx    = is_byte ? wdata[4:0] : wdata[4:0];
                        host_idx_wr = 1'b1;
                    end else begin
                        host_idx    = wdata[28:24];
                        host_val    = wdata[23:8];
                        host_reg_wr = 1'b1;
                    end
                end
                2'd1: begin
                    host_val    = is_byte ? {wdata[7:0], regs[index][7:0]}
                                          : wdata[15:0];
                    host_reg_wr = 1'b1;
                end
                2'd2: begin
                    host_val    = {regs[index][15:8], wdata[7:0]};
                    host_reg_wr = 1'b1;
                end
                default: begin
                    host_val    = is_byte ? {8'h0, wdata[7:0]} : wdata[15:0];
                    host_ram_wr = 1'b1;
                end
            endcase
        end else if (sel && !we && crs == 2'd3) begin
            host_ram_rd = 1'b1;
        end
    end

    // ---- the video timing generator --------------------------------------
    typedef enum logic [2:0] {
        VT_OFF,
        VT_FRAME_PTR0,   // consume the line-sequence pointer
        VT_FRAME_CNT,    // consume the line count
        VT_RUN_W0,       // consume state run word 0
        VT_RUN_W1,       // consume state run word 1, when present
        VT_RUN,          // hold the state for its duration
        VT_LINE_END      // consume the pointer to the next line
    } vt_state_t;

    vt_state_t   vt;
    logic [14:0] frame_ptr, line_ptr, run_ptr, fetch_a;
    logic [15:0] lines_left;
    logic  [6:0] state_a, state_b, state_c;
    logic  [6:0] run_left;
    logic        run_eol;
    logic [15:0] ram_q;
    logic        fetch_wait;

    // The read port. The host wins the cycle it asks for; the generator's
    // fetch address is held, so re-arming `fetch_wait` is the whole recovery.
    // ---- the cursor ------------------------------------------------------
    // The glyph is in this SRAM. A row is four words in either size: 64x64 is
    // one plane of four, 32x32 is two planes of two, the second sixty-four
    // words on. Word 0 holds the leftmost sixteen pixels with bit 15 leftmost,
    // which is the order the part shifts them out in.
    wire        curs_en     = regs[R_DC_CONTROL][7];
    wire        curs_size64 = regs[R_DC_CONTROL][9];
    wire [14:0] curs_base   = regs[R_CURSOR_ENTRY][14:0];

    // Both position registers are the chip's own working copies, not the ones
    // software writes: X is latched when software writes CURSOR_Y (below) and
    // Y at the vertical position pulse, which is what stops a cursor tearing
    // when it moves mid-frame. The hot spot is 31 up and 31 left.
    wire signed [12:0] curs_x0 =
        $signed({2'b0, regs[R_CUR_CURSOR_X][10:0]}) - 13'sd31;
    wire signed [12:0] curs_y0 =
        $signed({2'b0, regs[R_WORK_CURSOR_Y][10:0]}) - 13'sd31;

    logic [15:0] curs_q;            // the cursor's own read port
    logic [15:0] curs_w [4];        // the row being displayed
    logic  [2:0] curs_step;         // 0 idle, 1..4 issuing a read
    logic        curs_cap;          // a read was issued last cycle
    logic  [1:0] curs_cap_i;
    logic        curs_row_ok;       // the cursor covers the line being drawn
    // THE ROW BEING FETCHED, LATCHED. It cannot be derived from `y_ctr` while
    // the fetch runs: the fetch starts on the line advance and `y_ctr` has
    // ALREADY moved on by the time the reads issue a cycle later, so a live
    // expression reads the row after the one wanted. Every row came out one
    // too far, which a solid cursor hides completely - the only symptom was
    // the last row of the glyph reading off the end into the plane above it
    // and vanishing. tb_vc2 now puts a mark on one row so an offset shows up
    // wherever it happens rather than only at the edge.
    logic  [5:0] curs_row_i;
`ifdef VC2_CURSOR_DEBUG
    logic [15:0] dbg_line_pix;
`endif

    wire curs_rd = (curs_step != 3'd0);
    wire [1:0] curs_i = curs_step[1:0] - 2'd1;

    // The row wanted is the one for the line AFTER this one, because the fetch
    // runs in the blanking that follows the line advance.
    wire signed [12:0] curs_cy = $signed({2'b0, y_ctr}) + 13'sd1 - curs_y0;
    wire curs_next_ok = curs_en && (curs_cy >= 13'sd0)
                     && (curs_cy < (curs_size64 ? 13'sd64 : 13'sd32));
    wire [5:0] curs_cy6 = curs_cy[5:0];

    wire [14:0] curs_a = curs_size64
        ? curs_base + {7'b0, curs_row_i, 2'b0} + {13'b0, curs_i}
        : (curs_i[1] ? curs_base + 15'd64 + {8'b0, curs_row_i, 1'b0} + {14'b0, curs_i[0]}
                     : curs_base           + {8'b0, curs_row_i, 1'b0} + {14'b0, curs_i[0]});

    // ---- and the pixel it produces ---------------------------------------
    wire signed [12:0] curs_cx = $signed({2'b0, x_ctr}) - curs_x0;
    wire curs_in_x = (curs_cx >= 13'sd0)
                  && (curs_cx < (curs_size64 ? 13'sd64 : 13'sd32));
    wire  [5:0] curs_cx6 = curs_cx[5:0];
    wire  [5:0] curs_b64 = 6'd63 - curs_cx6;
    wire  [4:0] curs_b32 = 5'd31 - curs_cx6[4:0];
    wire [63:0] curs_one = {curs_w[0], curs_w[1], curs_w[2], curs_w[3]};
    wire [31:0] curs_pl0 = {curs_w[0], curs_w[1]};
    wire [31:0] curs_pl1 = {curs_w[2], curs_w[3]};

    always_comb begin
        cursor_pix = 2'd0;
        if (curs_en && curs_row_ok && curs_in_x) begin
            if (curs_size64) cursor_pix = {1'b0, curs_one[curs_b64]};
            else             cursor_pix = {curs_pl1[curs_b32], curs_pl0[curs_b32]};
        end
    end

    wire [14:0] ram_ra = host_ram_rd ? ram_addr : fetch_a;

    // ---- the DID table walker --------------------------------------------
    // decode_did in IRIS's disp.rs, as a per-line walk instead of a frame
    // buffer of DIDs. The table: `ram[DID_ENTRY_PTR + y]` points at line y's
    // run list; the first word's low five bits are the DID from x = 0, and
    // every further word is {x[10:0], did[4:0]} - the current DID runs until
    // x, then the entry's DID takes over. An x of 0x7FF is end-of-line, and
    // a line pointer of 0xFFFF means no more lines.
    //
    // The walk shares the CURSOR's read port: the cursor's four reads run
    // first at each line end, this walker's three follow, and both are done
    // hundreds of blank pixels before the line needs either. Mid-line, the
    // walker fetches one entry per run boundary - the port is otherwise idle
    // during display, and the lookahead entry is fetched while the previous
    // run is still drawing.
    wire        did_en   = regs[R_DC_CONTROL][3];
    wire [14:0] did_base = regs[R_DID_ENTRY][14:0];

    typedef enum logic [2:0] {
        DID_IDLE, DID_LPTR, DID_E0, DID_E1, DID_RUN, DID_NEXT
    } did_state_t;
    did_state_t  dids;
    logic        did_ph;         // 0 = address presented, 1 = data captured
    logic [10:0] did_y;          // the display row being walked
    logic [14:0] did_eptr;
    logic  [4:0] did_cur, did_nxt;
    logic [10:0] did_nxt_x;
    logic        did_kick;       // a new line wants its walk
    logic        did_line_ok;    // the walk reached the run stage
    // A line pointer of 0xFFFF ends the TABLE, not the line: IRIS's
    // decode_did stops walking the frame there, so every later row keeps
    // DID 0 until the next frame restarts the walk from row zero.
    logic        did_frame_end;

    // The walker's address, held for both phases of a fetch.
    logic [14:0] did_a;
    always_comb begin
        case (dids)
            DID_LPTR:  did_a = did_base + {4'b0, did_y};
            default:   did_a = did_eptr;    // DID_E0/E1/NEXT
        endcase
    end

    assign did = (did_en && did_line_ok) ? did_cur : 5'd0;
    logic [2:0] dids_bits;
    assign dids_bits = dids;
    assign dbg_did   = {did_en, dids_bits};

    logic [15:0] pix_div_ctr;
    logic        pix_phase;
    wire         pix_tick = ce_pix && pix_phase;

    // PIXEL TIME STOPS WHILE THE GENERATOR IS FETCHING, and that is what makes
    // the emitted raster exactly the one the table describes.
    //
    // Walking the table costs clocks that are not part of any state run: a
    // word to read for each run, two for a run that carries state B and C, and
    // the next-line pointer at the end of every line. A real VC2 hides them in
    // a sixteen-deep state FIFO. Letting the pixel clock run through them
    // instead adds those clocks to the picture, and how much they add depends
    // on PIX_DIV: at two clocks per pixel the bubbles were about two pixels a
    // line and the display enable still measured the table's 1318 exactly, and
    // at one clock per pixel they became five and it measured 1323.
    //
    // So the divider is held instead. The frame takes a fraction of a percent
    // longer in wall-clock time and the raster is the table's, which is the
    // right way round: the geometry is what software and a monitor see, and
    // the extra microseconds are what nothing sees.
    wire vtg_stalled = vtg_enable && (vt != VT_RUN);

    assign ce_pix = ((PIX_DIV <= 1) ? 1'b1
                                    : (pix_div_ctr == PIX_DIV[15:0] - 16'd1))
                    && !vtg_stalled;

    // Every timing channel is active low.
    assign hsync  = ~state_c[2];       // HSYNC_ARC_N
    assign vsync  = ~state_c[1];       // VSYNC_ARC_N
    assign de     = ~state_a[2];       // DSPLY_EN_RO_N
    assign hblank = ~state_b[0];       // HBLANK_AB_N
    assign vblank =  state_a[0];       // VIS_LN_VC_N deasserted

    logic vert_int_n_d;
    assign vert_int = vert_int_n_d & ~state_c[0];   // falling edge = assertion

    logic [10:0] x_ctr, y_ctr;
    logic        de_d;
    assign pix_x = x_ctr;
    assign pix_y = y_ctr;

    // The chip will not respond at all until soft reset is released, and the
    // spec is explicit that both it and the DCB hang if you try. Gating the
    // generator on it is the same rule.
    wire vtg_enable = regs[R_DC_CONTROL][2] && regs[R_CONFIG][0];

    // rdata is read one or more cycles after `sel` by the DCB master, which
    // is what makes a registered SRAM read possible at all.
    always_comb begin
        case (crs)
            2'd0:    rdata = {11'h0, index};
            2'd1,
            2'd2:    rdata = regs[index];
            default: rdata = ram_q;
        endcase
    end

    integer i;
    always_ff @(posedge clk) begin
        // THE SRAM READ LIVES HERE, ABOVE THE RESET, AND THAT IS WHAT PUTS IT
        // IN M10Ks. Quartus infers a memory only when the array read goes
        // straight into a register with nothing in the way, and a reset on
        // that register is something in the way: with `ram_q <= 16'h0` in the
        // reset branch and the read in the else, this 32K x 16 array became
        // 524,288 flip-flops and Analysis & Synthesis gave up with
        //
        //   Error (276003): Cannot convert all sets of registers into RAM
        //   megafunctions ... exceeds the number of registers in the device
        //
        // sgi_ds1386.sv learned the same lesson at 30,430 ALUTs; syn/README.md
        // has that story. The read is unconditional, so hoisting it changes
        // nothing about behaviour - `ram_q` is only ever consumed under the
        // state machine's own control.
        ram_q <= ram[ram_ra[AW-1:0]];

        // A SECOND READ PORT, AND IT HAS TO BE ONE. The cursor fetch cannot
        // share the generator's: VT_RUN reads a word fetched when the run was
        // ENTERED and is deliberately outside the fetch stall, so a read
        // slipped in mid-run replaces `ram_q` with the cursor's word and the
        // generator walks its timing table off into whatever that was. On
        // hardware that was a raster that stopped existing - a black screen
        // over a frame buffer with the whole boot screen still in it.
        //
        // Quartus duplicates the array to give the second port, which costs
        // 512 Kbit of a device with 3.3 spare. That is a real price for a
        // 128-word glyph and it is still the right trade: the alternative is
        // interfering with a timing generator whose exactness is asserted, to
        // the pixel, by tests/run-newport.sh.
        //
        // THE DID WALKER RIDES THIS SAME PORT when the cursor is not using
        // it - the cursor's four reads and the walker's never overlap in
        // time by construction (cursor first at line end, walker after, both
        // gated on `curs_rd`), so the mux costs nothing and the third copy
        // of the array it would otherwise take is not spent.
        curs_q <= ram[(curs_rd ? curs_a[AW-1:0] : did_a[AW-1:0])];

        if (reset) begin
            for (i = 0; i < 32; i = i + 1) regs[i] <= 16'h0;
            index        <= 5'h0;
            vt           <= VT_OFF;
            frame_ptr    <= 15'h0;
            line_ptr     <= 15'h0;
            run_ptr      <= 15'h0;
            fetch_a      <= 15'h0;
            fetch_wait   <= 1'b0;
            lines_left   <= 16'h0;
            state_a      <= 7'h7F;
            state_b      <= 7'h7F;
            state_c      <= 7'h7F;
            run_left     <= 7'h0;
            run_eol      <= 1'b0;
            pix_div_ctr  <= 16'h0;
            pix_phase    <= 1'b0;
            x_ctr        <= 11'h0;
            y_ctr        <= 11'h0;
            de_d         <= 1'b0;
            vert_int_n_d <= 1'b1;
            curs_step    <= 3'd0;
            curs_cap     <= 1'b0;
            curs_cap_i   <= 2'd0;
            curs_row_ok  <= 1'b0;
            curs_row_i   <= 6'd0;
            dids         <= DID_IDLE;
            did_ph       <= 1'b0;
            did_y        <= 11'd0;
            did_eptr     <= 15'd0;
            did_cur      <= 5'd0;
            did_nxt      <= 5'd0;
            did_nxt_x    <= 11'h7FF;
            did_kick     <= 1'b0;
            did_line_ok  <= 1'b0;
            did_frame_end <= 1'b0;
        end else begin
            // ---- host access ---------------------------------------------
            if (host_idx_wr) index <= host_idx;
            if (host_reg_wr) begin
                regs[host_idx] <= host_val;
                index          <= host_idx;
                // Writing the cursor Y latch copies X into the working copy,
                // which is how the part avoids a torn cursor position.
                if (host_idx == R_CURSOR_Y) regs[R_CUR_CURSOR_X] <= regs[R_CURSOR_X];
                // Config[15:8] keeps the high byte of the last CRS 1 access
                // to registers 0x00..0x10, so software can recover it if a
                // transfer is interrupted.
                if (host_idx <= R_DC_CONTROL && crs == 2'd1)
                    regs[R_CONFIG][15:8] <= host_val[15:8];
            end
            if (host_ram_wr) begin
                ram[ram_addr[AW-1:0]] <= host_val;
                regs[R_RAM_ADDR]      <= {1'b0, ram_addr + 15'd1};
            end
            if (host_ram_rd)
                regs[R_RAM_ADDR] <= {1'b0, ram_addr + 15'd1};

            // ---- pixel clock ---------------------------------------------
            if (vtg_stalled) begin
                // Hold the divider where it is, so a run resumes on the phase
                // it was interrupted on rather than restarting mid-pixel.
                pix_div_ctr <= pix_div_ctr;
            end else if (ce_pix) begin
                pix_div_ctr <= 16'h0;
                pix_phase   <= ~pix_phase;
                de_d        <= de;
                if (!de) x_ctr <= 11'h0;
                else     x_ctr <= x_ctr + 11'd1;
                // The end of a visible span is the line advance. Blanking
                // lines do not move the frame buffer row, so this counts
                // displayed lines rather than total lines.
                if (de_d && !de) begin
                    y_ctr <= y_ctr + 11'd1;
                    // THE LINE HAS JUST ENDED, so there are hundreds of blank
                    // pixel times before the next one needs its cursor row.
                    // Four reads is all it takes and nothing else wants the
                    // port badly enough to notice.
                    curs_step   <= curs_next_ok ? 3'd1 : 3'd0;
                    curs_row_ok <= curs_next_ok;
                    curs_row_i  <= curs_cy6;
                    // The DID walk for the next line starts here too; its
                    // reads queue behind the cursor's on the shared port.
                    did_kick    <= 1'b1;
                    did_y       <= y_ctr + 11'd1;
`ifdef VC2_CURSOR_DEBUG
                    dbg_line_pix <= 16'd0;
                    if (y_ctr > 11'd35 && y_ctr < 11'd75)
                        $display("[VC2] end of line %0d: row_ok_during=%0d pixels=%0d | next cy=%0d ok=%0d",
                                 y_ctr, curs_row_ok, dbg_line_pix, curs_cy, curs_next_ok);
`endif
                end
            end else begin
                pix_div_ctr <= pix_div_ctr + 16'd1;
            end
            vert_int_n_d <= state_c[0];

`ifdef VC2_CURSOR_DEBUG
            if (ce_pix && de && cursor_pix != 2'd0) dbg_line_pix <= dbg_line_pix + 16'd1;
`endif
            // ---- the cursor row fetch -------------------------------------
            // `ram_q` lands the cycle after its address, so the capture runs
            // one behind the issue and both are just counters.
            curs_cap   <= curs_rd;
            curs_cap_i <= curs_i;
            if (curs_cap) curs_w[curs_cap_i] <= curs_q;
            if (curs_rd)  curs_step <= (curs_step == 3'd4) ? 3'd0
                                                          : curs_step + 3'd1;

            // ---- the DID walk ---------------------------------------------
            // Each fetch is two phases on the shared port: present the
            // address (waiting out the cursor), capture `curs_q` the cycle
            // after. The line pointer, the first entry, and one lookahead
            // run all land during blanking; mid-line only the lookahead
            // refresh after each run boundary touches the port.
            case (dids)
                DID_IDLE: ;
                DID_LPTR:
                    if (!did_ph) begin
                        if (!curs_rd) did_ph <= 1'b1;
                    end else begin
                        did_ph <= 1'b0;
                        if (curs_q == 16'hFFFF) begin
                            did_frame_end <= 1'b1;
                            dids          <= DID_IDLE;
                        end else begin
                            did_eptr <= curs_q[14:0];
                            dids     <= DID_E0;
                        end
                    end
                DID_E0:
                    if (!did_ph) begin
                        if (!curs_rd) did_ph <= 1'b1;
                    end else begin
                        did_ph   <= 1'b0;
                        did_cur  <= curs_q[4:0];
                        did_eptr <= did_eptr + 15'd1;
                        dids     <= DID_E1;
                    end
                DID_E1:
                    if (!did_ph) begin
                        if (!curs_rd) did_ph <= 1'b1;
                    end else begin
                        did_ph      <= 1'b0;
                        did_nxt_x   <= curs_q[15:5];
                        did_nxt     <= curs_q[4:0];
                        did_eptr    <= did_eptr + 15'd1;
                        did_line_ok <= 1'b1;
                        dids        <= DID_RUN;
                    end
                // The switch lands on the same tick the position counter
                // reaches the entry's x, so `did` changes exactly at that
                // pixel. 0x7FF is the table's end-of-line mark and sits past
                // any visible x, so it simply never matches.
                DID_RUN:
                    if (ce_pix && de && (x_ctr + 11'd1 == did_nxt_x)) begin
                        did_cur <= did_nxt;
                        dids    <= DID_NEXT;
                    end
                DID_NEXT:
                    if (!did_ph) begin
                        if (!curs_rd) did_ph <= 1'b1;
                    end else begin
                        did_ph   <= 1'b0;
                        did_eptr <= did_eptr + 15'd1;
                        // A run shorter than its own fetch takes effect the
                        // moment it is seen; anything longer becomes the
                        // lookahead.
                        if (curs_q[15:5] != 11'h7FF
                            && curs_q[15:5] <= x_ctr + 11'd1) begin
                            did_cur <= curs_q[4:0];
                        end else begin
                            did_nxt_x <= curs_q[15:5];
                            did_nxt   <= curs_q[4:0];
                            dids      <= DID_RUN;
                        end
                    end
                default: dids <= DID_IDLE;
            endcase

            // A new line restarts the walk outright; after the case so it
            // wins over whatever state the old line's walk was left in.
            // Row zero also lifts the table's end mark for the new frame.
            if (did_kick) begin
                did_kick    <= 1'b0;
                did_ph      <= 1'b0;
                did_line_ok <= 1'b0;
                did_nxt_x   <= 11'h7FF;
                if (did_y == 11'd0) did_frame_end <= 1'b0;
                dids        <= (did_en && (did_y == 11'd0 || !did_frame_end))
                               ? DID_LPTR : DID_IDLE;
            end

            // ---- the generator -------------------------------------------
            // `fetch_wait` covers the one cycle between presenting an address
            // and `ram_q` holding the word. VT_RUN is deliberately outside
            // that stall: its exit reads a word fetched when it was entered,
            // and a run lasts at least one pixel-pair tick, so the fetch has
            // long since landed. Stalling it too would add the fetch latency
            // to every state run and stretch the horizontal total.
            fetch_wait <= 1'b0;
            if (host_ram_rd) fetch_wait <= 1'b1;

            if (!vtg_enable) begin
                vt      <= VT_OFF;
                state_a <= 7'h7F;
                state_b <= 7'h7F;
                state_c <= 7'h7F;
            end else if (fetch_wait && vt != VT_RUN) begin
                // hold; ram_q is not yet the word this state wants
            end else begin
                case (vt)
                    VT_OFF: begin
                        frame_ptr  <= regs[R_VIDEO_ENTRY][14:0];
                        fetch_a    <= regs[R_VIDEO_ENTRY][14:0];
                        fetch_wait <= 1'b1;
                        y_ctr      <= 11'h0;
                        // The vertical position pulse also positions the
                        // cursor vertically - VT_VPOS_VC_N - which is what
                        // makes CURSOR_Y safe to write at any time.
                        regs[R_WORK_CURSOR_Y] <= regs[R_CURSOR_Y];
                        // Row zero's DID walk has no line-end to hang off.
                        did_kick   <= 1'b1;
                        did_y      <= 11'd0;
                        vt         <= VT_FRAME_PTR0;
                    end

                    // A frame-table entry is two words: the line-sequence
                    // pointer and the number of individual lines it produces.
                    VT_FRAME_PTR0: begin
                        line_ptr   <= ram_q[14:0];
                        fetch_a    <= frame_ptr + 15'd1;
                        fetch_wait <= 1'b1;
                        vt         <= VT_FRAME_CNT;
                    end
                    VT_FRAME_CNT: begin
                        if (ram_q == 16'h0) begin
                            // A count of zero ends the frame.
                            frame_ptr  <= regs[R_VIDEO_ENTRY][14:0];
                            fetch_a    <= regs[R_VIDEO_ENTRY][14:0];
                            fetch_wait <= 1'b1;
                            y_ctr      <= 11'h0;
                        // The vertical position pulse also positions the
                        // cursor vertically - VT_VPOS_VC_N - which is what
                        // makes CURSOR_Y safe to write at any time.
                        regs[R_WORK_CURSOR_Y] <= regs[R_CURSOR_Y];
                            did_kick   <= 1'b1;
                            did_y      <= 11'd0;
                            vt         <= VT_FRAME_PTR0;
                        end else begin
                            lines_left <= ram_q;
                            frame_ptr  <= frame_ptr + 15'd2;
                            run_ptr    <= line_ptr;
                            fetch_a    <= line_ptr;
                            fetch_wait <= 1'b1;
                            vt         <= VT_RUN_W0;
                        end
                    end

                    VT_RUN_W0: begin
                        run_left <= ram_q[14:8];
                        run_eol  <= ram_q[15];
                        state_a  <= ram_q[6:0];
                        if (ram_q[7]) begin
                            // State B and C carry over from the last run.
                            run_ptr <= run_ptr + 15'd1;
                            fetch_a <= run_ptr + 15'd1;
                            vt      <= VT_RUN;
                        end else begin
                            fetch_a    <= run_ptr + 15'd1;
                            fetch_wait <= 1'b1;
                            vt         <= VT_RUN_W1;
                        end
                    end
                    VT_RUN_W1: begin
                        state_b <= ram_q[14:8];
                        state_c <= ram_q[6:0];
                        run_ptr <= run_ptr + 15'd2;
                        fetch_a <= run_ptr + 15'd2;
                        vt      <= VT_RUN;
                    end

                    VT_RUN: begin
                        if (pix_tick) begin
                            // A DURATION FIELD OF D LASTS EXACTLY D TICKS, and
                            // that is measurable rather than a reading of the
                            // spec: every one of n1280's eight line sequences
                            // sums to 841 two-pixel units under this rule -
                            // 1682 pixels, which is 107.5 MHz / (60 Hz * 1065
                            // lines) - while D+1 gives them five different
                            // totals, and no two lines of one raster can have
                            // different lengths. No table in np_timing.h has a
                            // duration of zero, so this counts one tick for
                            // one rather than trying to skip a state that
                            // occupies no time.
                            if (run_left <= 7'd1) begin
                                // The word after a line's last run is the
                                // pointer to the next line of the sequence,
                                // and run_ptr was already advanced past the
                                // run, so ram_q is holding it.
                                vt <= run_eol ? VT_LINE_END : VT_RUN_W0;
                                // State A goes inactive while the end of the
                                // line is looked up. Without this the last run
                                // of a line - which in a real table is the
                                // visible one - stays asserted through the
                                // lookup and the display enable comes out a
                                // few pixels too wide. A real VC2 prefetches
                                // into a sixteen-deep state FIFO and has no
                                // such gap.
                                //
                                // ONLY STATE A. Its channels are the ones that
                                // belong to a line - display enable, serial
                                // enable, visible line, the horizontal cursor
                                // position. State B and C carry the vertical
                                // sync, which is asserted across three whole
                                // lines in every table in np_timing.h; blanking
                                // those here chops it into three pulses and the
                                // frame appears to be one line long.
                                if (run_eol) state_a <= 7'h7F;
                            end else begin
                                run_left <= run_left - 7'd1;
                            end
                        end
                    end

                    VT_LINE_END: begin
                        if (lines_left <= 16'd1) begin
                            fetch_a    <= frame_ptr;
                            fetch_wait <= 1'b1;
                            vt         <= VT_FRAME_PTR0;
                        end else begin
                            lines_left <= lines_left - 16'd1;
                            line_ptr   <= ram_q[14:0];
                            run_ptr    <= ram_q[14:0];
                            fetch_a    <= ram_q[14:0];
                            fetch_wait <= 1'b1;
                            vt         <= VT_RUN_W0;
                        end
                    end

                    default: vt <= VT_OFF;
                endcase
            end

            // Running pointers, for the diagnostics that read them back.
            regs[R_VT_FRAME_PTR]  <= {1'b0, frame_ptr};
            regs[R_VT_LINE_SEQ]   <= {1'b0, line_ptr};
            regs[R_VT_LINES_RUN]  <= lines_left;
            regs[R_VERT_LINE_CTR] <= {5'b0, y_ctr};
        end
    end

endmodule
