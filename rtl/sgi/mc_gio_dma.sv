//============================================================================
//  mc_gio_dma - the MC's GIO64 DMA engine, the fill half of it.
//
//  WHY THIS EXISTS, AND IT IS NOT A FEATURE REQUEST. Until this module the
//  engine was a stub: its registers held what was written to them and a start
//  reported an instantly-finished transfer, but no data moved. The PROM clears
//  memory through it at boot and was told the clear had worked, so the guest
//  booted on whatever DDR3 happened to contain. On a MiSTer that is the
//  PREVIOUS RUN's memory, because DDR3 survives a core reload and a warm
//  reboot of the HPS - and one particular pattern of leftovers stops the boot
//  dead at rex3Clear. A machine that had drawn its whole boot screen sat black
//  for an evening on a bitstream that was md5-verified three ways. See
//  docs/08-resume-prompt.md and tools/misterdeploy/memclear.py, which is the
//  workaround this replaces.
//
//  WHAT IS IMPLEMENTED: fill-to-memory, which is the mode the PROM's clear
//  uses and the only one this machine can perform. The register semantics are
//  IRIS's `dma_worker` in src/mc.rs, which is the oracle for this chip:
//
//    line_count = size[31:16]     line_width = size[15:0]
//    line_zoom  = stride[25:16]   stride     = signed(stride[15:0])
//    zoom_count = count[25:16]    byte_count = count[15:0]
//    fill value = gio_adr with the low three bits cleared
//
//    for line_count lines:
//        for zoom_count reps:
//            write the fill value as 32-bit words until byte_count runs out
//            byte_count reloads from line_width
//            between reps the address rewinds by line_width
//        zoom_count reloads from line_zoom
//        the address advances by the signed stride
//
//  THE FILL VALUE IS THE GIO ADDRESS REGISTER, which is not a thing anyone
//  guesses. `phys.write32(addr, gio_addr)` in mc.rs: in fill mode the GIO side
//  is never read, so that register carries the pattern instead.
//
//  WHAT IS NOT IMPLEMENTED, deliberately rather than by omission: the GIO
//  transfer modes. Mem->GIO and GIO->Mem move data between memory and a device
//  on the GIO64 bus, and this machine HAS no GIO64 device - the only thing at
//  a GIO address is the empty expansion slot the cpu-tests probe reads. An
//  engine that faithfully copied memory into a void would be more code and no
//  more function. Those modes keep the old behaviour, reporting an
//  instantly-finished transfer, and `mode_unsupported` says so on the wire so
//  the reason is visible in a trace rather than inferred from silence.
//
//  Address translation (DMA_CTL_XLATE, the four-entry uTLB) is also not
//  implemented. The PROM's clear runs untranslated; IRIX's use of it does not,
//  and that is the next piece if this engine ever needs to serve IRIX.
//============================================================================

module mc_gio_dma (
    input  logic        clk,
    input  logic        reset,

    // ---- the latched descriptor, and go ---------------------------------
    // `start` is a one-cycle pulse from sgi_mc's register write. Everything
    // else is sampled on that pulse and never read again, which is what the
    // real engine does: the CPU is free to rewrite the registers the moment
    // the transfer is running.
    input  logic        start,
    input  logic [31:0] d_memadr,
    input  logic [31:0] d_size,
    input  logic [31:0] d_stride,
    input  logic [31:0] d_gio_adr,
    input  logic [31:0] d_mode,
    input  logic [31:0] d_count,
    input  logic [31:0] d_ctl,

    output logic        busy,
    output logic        done,              // one cycle, when a transfer ends
    output logic        mode_unsupported,  // held with `done` for a mode we skip

    // ---- bus master ------------------------------------------------------
    // Same shape and the same byte-lane convention as the HPC3's SCSI channel:
    // `wdata[63-8i -: 8]` is the byte at `addr+i` and `be[7-i]` guards it.
    // Held until `ack`, which is what sgi_indy.sv's arbiter expects.
    output logic        m_req,
    output logic        m_we,
    output logic [31:0] m_addr,            // physical, doubleword aligned
    output logic [63:0] m_wdata,
    output logic  [7:0] m_be,
    input  logic        m_ack
);

    // Mode bits, from IRIS's mc.rs. Note FILL is bit 3 and not bit 2 - a
    // comment in that file says bit 2 and its own constant says 3; the
    // constant is what the code uses and what the PROM's descriptor sets.
    localparam int MODE_TO_HOST = 1;
    localparam int MODE_FILL    = 3;
    localparam int MODE_DIR     = 4;
    localparam int CTL_XLATE    = 8;

    // The state names follow IRIS's three nested loops rather than the bus:
    // S_CHECK is the `while byte_count > 0` test and the unwinding of the two
    // outer counts, and it is a state rather than a branch off S_ACK because
    // a descriptor can arrive with byte_count already zero. Deciding whether
    // to write in the same place the loop condition lives is what keeps this
    // honest against the reference - an earlier version tested after the
    // write and issued one write too many for an empty line.
    typedef enum logic [2:0] { S_IDLE, S_CHECK, S_WRITE, S_ACK, S_DONE } state_t;
    state_t state;

    logic [15:0] line_count, line_width, byte_count;
    logic  [9:0] zoom_count, line_zoom;
    logic [15:0] stride;
    logic [31:0] addr, fill;
    logic        dir_up, skip;

    // 32 bits into a 64-bit lane. Offset 0 is the HIGH half: the byte at
    // addr+0 lives in wdata[63:56].
    wire        hi   = ~addr[2];
    wire [63:0] wdat = hi ? {fill, 32'h0} : {32'h0, fill};
    wire  [7:0] wben = hi ? 8'b1111_0000  : 8'b0000_1111;

    assign m_we    = 1'b1;                 // this engine only ever writes
    assign m_addr  = {addr[31:3], 3'b000};
    assign m_wdata = wdat;
    assign m_be    = wben;
    assign m_req   = (state == S_WRITE);
    assign busy    = (state != S_IDLE);

    // `stride` is a signed 16-bit quantity added to a 32-bit address, so it
    // has to be sign extended - a stride of -8 is 0xFFF8 in the register and
    // must not become +65528.
    wire [31:0] stride_ext = {{16{stride[15]}}, stride};
    wire [31:0] width_ext  = {16'h0, line_width};

    wire supported = d_mode[MODE_FILL] && d_mode[MODE_TO_HOST] && !d_ctl[CTL_XLATE];

    always_ff @(posedge clk) begin
        if (reset) begin
            state            <= S_IDLE;
            done             <= 1'b0;
            mode_unsupported <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: if (start) begin
                    line_count <= d_size[31:16];
                    line_width <= d_size[15:0];
                    line_zoom  <= d_stride[25:16];
                    stride     <= d_stride[15:0];
                    zoom_count <= d_count[25:16];
                    byte_count <= d_count[15:0];
                    addr       <= d_memadr;
                    fill       <= {d_gio_adr[31:3], 3'b000};
                    dir_up     <= d_mode[MODE_DIR];
                    skip       <= !supported;
                    // Everything this engine does not do finishes instantly,
                    // exactly as the stub did, and so does a descriptor with
                    // no lines in it - which is not an error and must not run
                    // for ever.
                    state      <= (!supported || d_size[31:16] == 16'h0)
                                  ? S_DONE : S_CHECK;
                end

                S_CHECK:
                    if (byte_count != 16'h0) begin
                        state <= S_WRITE;
                    end else begin
                        // byte_count always reloads from line_width, never
                        // from what it started at: the first pass can be a
                        // different length from the rest, which is the whole
                        // point of the count/size split.
                        byte_count <= line_width;
                        if (zoom_count > 10'd1) begin
                            zoom_count <= zoom_count - 10'd1;
                            // Rewind to the start of the line. `addr` has
                            // already stepped past the last write, which is
                            // where the reference does this from too.
                            addr       <= dir_up ? addr - width_ext
                                                 : addr + width_ext;
                        end else if (line_count > 16'd1) begin
                            line_count <= line_count - 16'd1;
                            zoom_count <= line_zoom;
                            addr       <= addr + stride_ext;
                        end else begin
                            state <= S_DONE;
                        end
                    end

                // Held until the arbiter takes it.
                S_WRITE: if (m_ack) state <= S_ACK;

                S_ACK: begin
                    byte_count <= (byte_count > 16'd4) ? byte_count - 16'd4 : 16'd0;
                    addr       <= dir_up ? addr + 32'd4 : addr - 32'd4;
                    state      <= S_CHECK;
                end

                S_DONE: begin
                    done             <= 1'b1;
                    mode_unsupported <= skip;
                    state            <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
