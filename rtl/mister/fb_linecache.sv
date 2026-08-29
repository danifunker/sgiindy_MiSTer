//============================================================================
//  fb_linecache - a scanline ahead of the display, so DDR3 latency never
//  reaches the pixel.
//
//  THE PROBLEM THIS SOLVES IS NOT BANDWIDTH, IT IS THAT NEWPORT DOES NOT WAIT.
//  `newport.sv` issues one frame buffer read per pixel and latches whatever
//  comes back whenever it comes back - there is no handshake on that path and
//  there should not be, because on a real board the display side reads a VRAM
//  *serial* port, which cannot stall. Against the simulator's one-cycle memory
//  that is exactly right. Against DDR3, whose latency is long and variable,
//  the pixel that arrives belongs to a read issued some cycles ago and the
//  number of cycles moves around: a horizontal smear that changes with memory
//  load, which is the same symptom the Display Control Bus bug produced and a
//  completely different cause.
//
//  So this sits between them and answers every read out of a block RAM. It is
//  in rtl/mister/ and not in rtl/newport/ ON PURPOSE: nothing about the
//  graphics board changes, so every test that checks the picture still checks
//  the same core, and this is a property of the memory system it was plugged
//  into rather than of the Indy.
//
//  HOW IT KNOWS WHAT TO FETCH. The display's access pattern is not a guess -
//  it is fully determined. VC2 walks x from 0 across a line and advances y at
//  the end of each visible one, so a request's line number is
//  `addr / (STRIDE * 8)` and the next line wanted is always that plus one.
//  Two buffers: one being read, one being filled with the line after it. At
//  the top of a frame the sequence jumps from the last line back to zero,
//  which no "fetch the next one" rule predicts - hence `vs`, which restarts
//  the prefetcher at line zero during vertical blanking, where there is a
//  whole frame's worth of time to do it.
//
//  A MISS SERVES BLACK RATHER THAN STALLING, because stalling is not on the
//  menu: there is no back-pressure on this path. A miss can only happen on the
//  first frame after reset or if a fill did not finish in a line time, and it
//  costs one line of black, which is visible and self-correcting - the honest
//  failure. `miss` is brought out so that a top level can count them.
//============================================================================

module fb_linecache #(
    // Pixels per frame buffer line, and bytes per pixel. Newport's store is
    // eight bytes a pixel - 24 bits of drawing planes and 24 of auxiliary -
    // on a 2048-pixel stride.
    parameter int STRIDE     = 2048,
    // How many of those a line actually needs. The visible span of the widest
    // timing table in np_timing.h is 1318 pixels; fetching the whole 2048
    // would cost a third more memory traffic for nothing.
    parameter int LINE_WORDS = 1344,
    // Words per burst. The bridge takes up to 255; 64 keeps a single fill from
    // owning the bus for too long at a stretch, which matters because the CPU
    // is behind the same arbiter.
    parameter int BURST      = 64
) (
    input  logic        clk,
    input  logic        reset,

    // ---- from the display side of newport.sv -----------------------------
    input  logic        px_req,        // one pulse per pixel
    input  logic [31:0] px_addr,       // byte address in the frame buffer
    output logic [63:0] px_rdata,
    output logic        px_ack,
    // VC2's vertical sync, in this clock domain. The prefetcher restarts on
    // its rising edge.
    input  logic        vs,

    // ---- to the DDR3 mux's burst read port -------------------------------
    output logic        fbr_req,
    output logic [31:0] fbr_addr,
    output logic  [7:0] fbr_burst,
    input  logic        fbr_taken,
    input  logic [63:0] fbr_dout,
    input  logic        fbr_dout_valid,

    output logic        miss           // a pixel was asked for and not resident
);

    localparam int AW = $clog2(LINE_WORDS);
    localparam int LINE_SHIFT = $clog2(STRIDE) + 3;   // bytes per line, log2

    // Two line buffers. Simple dual port: one write port for the fill, one
    // read port for the display - which is the shape that infers as M10K, and
    // getting it wrong here costs the same way it cost the real-time clock
    // 30,430 ALUTs. See syn/README.md.
    logic [63:0] buf0 [LINE_WORDS];
    logic [63:0] buf1 [LINE_WORDS];

    // Which line each buffer holds, and whether it holds anything.
    logic [10:0] tag0, tag1;
    logic        val0, val1;

    // The buffer being filled. The other one is the one being displayed.
    logic        fill_sel;

    wire [10:0] req_line = px_addr[LINE_SHIFT + 10 : LINE_SHIFT];
    wire [AW-1:0] req_off  = px_addr[LINE_SHIFT-1 : 3];

    wire hit0 = val0 && (tag0 == req_line);
    wire hit1 = val1 && (tag1 == req_line);

    // ---- the fill engine -------------------------------------------------
    typedef enum logic [1:0] { F_IDLE, F_REQ, F_DATA } fstate_t;
    fstate_t      fst;
    logic [10:0]  fill_line;
    logic [AW:0]  fill_pos;      // words already placed in the buffer
    logic  [8:0]  burst_left;

    // The line the prefetcher should be working on: one past whatever the
    // display last asked for, or zero after a vertical sync.
    logic [10:0]  want_line;
    // The line the display is actually reading, latched on a request. Between
    // requests px_addr still moves - it is combinational from VC2's counters,
    // which keep running through blanking - so the eviction decision must not
    // look at it directly.
    logic [10:0]  disp_line;
    logic         vs_d, restart;

    // Widths spelled out rather than left to inference: this is an address,
    // and an address that silently grew or lost a bit is the expensive kind of
    // mistake. See ddr3_mux.sv, where exactly that truncated a region base.
    wire [31:0] line_base = 32'({21'b0, fill_line} << LINE_SHIFT);
    wire [31:0] fill_byte = 32'({20'b0, fill_pos} << 3);
    wire [31:0] words_left = 32'(LINE_WORDS) - 32'({20'b0, fill_pos});

    assign fbr_addr  = line_base + fill_byte;
    assign fbr_burst = (words_left < 32'(BURST)) ? words_left[7:0] : 8'(BURST);
    assign fbr_req   = (fst == F_REQ);

    // ---- the display's read ----------------------------------------------
    // REGISTERED, one cycle after the request, which is exactly what the
    // simulator's memory did and what newport.sv's readout already expects.
    logic [63:0] q0, q1;
    logic        sel_q, ack_q, miss_q;

    assign px_rdata = miss_q ? 64'h0 : (sel_q ? q1 : q0);
    assign px_ack   = ack_q;
    assign miss     = miss_q;

    always_ff @(posedge clk) begin
        // ABOVE THE RESET, for the reason np_vc2.sv spells out: a reset on the
        // register an array reads into stops Quartus inferring a memory, and
        // these two are 172 Kbit that would become flip-flops. The reads are
        // unconditional anyway.
        q0 <= buf0[req_off];
        q1 <= buf1[req_off];

        if (reset) begin
            val0 <= 1'b0; val1 <= 1'b0;
            tag0 <= 11'h7FF; tag1 <= 11'h7FF;
            fill_sel <= 1'b0;
            fst <= F_IDLE;
            fill_line <= 11'd0;
            fill_pos <= '0;
            burst_left <= 9'd0;
            want_line <= 11'd0;
            disp_line <= 11'h7FF;
            vs_d <= 1'b0;
            restart <= 1'b1;
            ack_q <= 1'b0; miss_q <= 1'b0; sel_q <= 1'b0;
        end else begin
            ack_q  <= 1'b0;
            miss_q <= 1'b0;

            // ---- the display's read, unconditionally one cycle -----------
            // (the array read itself is hoisted above the reset, see above)
            if (px_req) begin
                ack_q  <= 1'b1;
                sel_q  <= hit1;
                miss_q <= !(hit0 || hit1);
            end

            // ---- what to prefetch ----------------------------------------
            // A request for line L means L+1 is next. That is the whole
            // policy, and it is right because the display never skips.
            if (px_req) begin
                want_line <= req_line + 11'd1;
                disp_line <= req_line;
            end

            vs_d <= vs;
            if (vs && !vs_d) begin
                // A new frame. The next line wanted is zero, and there is a
                // whole vertical blanking interval to fetch it in.
                want_line <= 11'd0;
                restart   <= 1'b1;
            end

            // ---- the fill engine -----------------------------------------
            case (fst)
                F_IDLE: begin
                    // Start a line whenever the one we want is not already
                    // resident somewhere.
                    automatic logic have =
                        (val0 && tag0 == want_line) || (val1 && tag1 == want_line);
                    // Buffer 0 is serving the display, so buffer 1 is free.
                    automatic logic use1 = (val0 && tag0 == disp_line);
                    if (restart || !have) begin
                        restart   <= 1'b0;
                        fill_line <= want_line;
                        fill_pos  <= '0;
                        // FILL WHICHEVER BUFFER THE DISPLAY IS NOT READING,
                        // and invalidate that same one. The first version of
                        // this had the sense inverted and invalidated the
                        // other buffer as well, so a fill could land in the
                        // line being displayed: the unit test saw it as a run
                        // of pixels from the wrong line AND as a tenth of
                        // every frame missing, because a buffer that was being
                        // filled was also being read and then thrown away.
                        fill_sel  <= use1;
                        if (use1) val1 <= 1'b0;
                        else      val0 <= 1'b0;
                        fst       <= F_REQ;
                    end
                end

                F_REQ: if (fbr_taken) begin
                    burst_left <= {1'b0, fbr_burst};
                    fst        <= F_DATA;
                end

                default: if (fbr_dout_valid) begin
                    if (fill_sel) buf1[fill_pos[AW-1:0]] <= fbr_dout;
                    else          buf0[fill_pos[AW-1:0]] <= fbr_dout;
                    fill_pos   <= fill_pos + 1'b1;
                    burst_left <= burst_left - 9'd1;
                    if (burst_left <= 9'd1) begin
                        if (int'(fill_pos) + 1 >= LINE_WORDS) begin
                            // The line is complete: publish it.
                            if (fill_sel) begin tag1 <= fill_line; val1 <= 1'b1; end
                            else          begin tag0 <= fill_line; val0 <= 1'b1; end
                            fst <= F_IDLE;
                        end else begin
                            fst <= F_REQ;
                        end
                    end
                end
            endcase
        end
    end

endmodule
