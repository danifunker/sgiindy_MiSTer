//============================================================================
//  fb_linecache - several scanlines ahead of the display, so DDR3 latency
//  never reaches the pixel.
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
//  AND THE DISPLAY CAN BE ASKING FOR MORE THAN THE BRIDGE HAS, WHICH IS NOT
//  SOMETHING A CACHE CAN FIX. A DE10-Nano measured it: the first 710 pixels of
//  every 1318-pixel line missed, every line, for ever. The arithmetic says why
//  and it is not subtle. At one pixel per clock the display wants LINE_WORDS
//  words per 1680-clock line - 0.80 words a clock - and the MiSTer DDR3 port
//  is 64 bits at 50 MHz, so its ABSOLUTE PEAK is 1.00. The display alone was
//  asking for eighty per cent of the bus before the CPU or the rasteriser
//  asked for anything, and it measured 0.52 delivered.
//
//  MORE BUFFERS DO NOT HELP A SUSTAINED DEFICIT, and that was worth measuring
//  rather than assuming: at one pixel per clock, going from two line buffers
//  to eight moved the miss rate from 98.8% to 97%. Buffers absorb jitter. They
//  cannot absorb a rate that is simply too low, and nor can a bigger burst -
//  64 to 255 words a burst moved it by a tenth.
//
//  WHAT FIXED IT WAS HALVING THE DEMAND: newport.sv's PIX_DIV is 2 again.
//  THAT PARAMETER AND THIS FILE ARE COUPLED AND NOTHING ENFORCES IT. PIX_DIV
//  went from 2 to 1 to double the frame rate, which also doubled the display's
//  memory demand and pushed it past what the bridge can supply - and the unit
//  test in tb_linecache.cpp still said PIX_DIV was 2, so it handed the fill
//  engine exactly twice the time it had and passed with zero misses while the
//  hardware missed more than half of every line. A model kinder than the
//  hardware is not a test of the hardware. (Do not start a line comment in
//  this file with the tool's name - it is read as a pragma.)
//
//  THE REAL FIX IS TO STOP FETCHING EIGHT BYTES TO USE ONE. The store is a
//  64-bit word per pixel - 24 bits of drawing planes, 24 of auxiliary - and
//  the display reads `pix_word[7:0]` in index mode and never reads the
//  auxiliary planes at all. Packing the drawing planes so one 64-bit read
//  serves two pixels would halve the traffic and let the pixel clock go back
//  to one per clock. That is a REX3 addressing change and it is written up in
//  docs/18-mister-integration.md rather than attempted here.
//
//  NBUF IS FOUR RATHER THAN TWO FOR MARGIN, NOT AS THE FIX. Two passes the
//  unit test at PIX_DIV=2, but that test has one master on the bus and the
//  machine has three; four buffers give the fill three line times instead of
//  one to absorb whatever the CPU and the rasteriser take. Each buffer is
//  LINE_WORDS x 64 bits of M10K, so four is 344 Kbit of the device's 5.6.
//
//  HOW IT KNOWS WHAT TO FETCH. The display's access pattern is not a guess -
//  it is fully determined. VC2 walks x from 0 across a line and advances y at
//  the end of each visible one, so a request's line number is
//  `addr / (STRIDE * 8)` and the lines are wanted strictly in order. The
//  buffers are therefore a ring: `fill_idx` walks them, `fill_line` counts up,
//  and the fill is throttled to stay less than NBUF ahead of the line being
//  displayed - which is exactly the condition that stops it overwriting a
//  buffer still in use. At the top of a frame the sequence jumps back to zero,
//  which no "fetch the next one" rule predicts - hence `vs`, which restarts
//  the ring during vertical blanking, where there is time to refill it.
//
//  A MISS SERVES BLACK RATHER THAN STALLING, because stalling is not on the
//  menu: there is no back-pressure on this path. A miss costs one pixel of
//  black, which is visible and self-correcting - the honest failure. `miss` is
//  brought out so that a top level can count them, and `dbg_miss_mark` makes
//  one visible on a screen, which is how the DE10-Nano's were found at all: a
//  miss and a frame buffer that is genuinely black look identical otherwise.
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
    // Line buffers. NBUF-1 is how many line times a fill gets. Margin against
    // the other two masters, not the fix for the deficit - see the header.
    parameter int NBUF       = 4,
    // Words per burst. The bridge takes up to 255. Larger is slightly better
    // for the display and worse for everyone behind the same arbiter, and the
    // measurement says it barely matters: 64 to 255 moved the miss rate by a
    // tenth when the display was over-subscribed.
    parameter int BURST      = 128
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

    output logic        miss,          // a pixel was asked for and not resident

    // ---- bring-up instrument, not a feature ------------------------------
    // A miss serves black, which is indistinguishable from a frame buffer that
    // really is black - and on the first hardware run those were the two
    // candidates. With this set a miss serves index 0x80 instead, so a display
    // that is not being fed shows as mid-grey under newport's dbg_raw_index
    // rather than as nothing at all. It is what found the fill shortfall.
    input  logic        dbg_miss_mark
);

    localparam int AW = $clog2(LINE_WORDS);
    localparam int LINE_SHIFT = $clog2(STRIDE) + 3;   // bytes per line, log2
    localparam int SW = $clog2(NBUF);

    // Which line each buffer holds, and whether it holds anything.
    logic [10:0]     tag [NBUF];
    logic [NBUF-1:0] val;

    // The ring: which buffer is being filled, and with which line.
    logic [SW-1:0] fill_idx;
    logic [10:0]   fill_line;
    logic [AW:0]   fill_pos;      // words already placed in the buffer
    logic  [8:0]   burst_left;

    // The line the display is actually reading, latched on a request. Between
    // requests px_addr still moves - it is combinational from VC2's counters,
    // which keep running through blanking - so the throttle must not look at
    // it directly.
    logic [10:0]  disp_line;
    logic         vs_d, restart;

    wire [10:0]   req_line = px_addr[LINE_SHIFT + 10 : LINE_SHIFT];
    wire [AW-1:0] req_off  = px_addr[LINE_SHIFT-1 : 3];

    // ---- the buffers -----------------------------------------------------
    // ONE ARRAY PER BUFFER, NOT ONE ARRAY OF ARRAYS. An array indexed by a
    // variable buffer number is a mux in front of a memory, and Quartus infers
    // no memory at all from that - it builds LINE_WORDS x 64 x NBUF
    // flip-flops and says nothing. Each of these is a plain single-write,
    // single-read block with the read going straight into a register, which is
    // the shape that becomes an M10K; the mux is AFTER the registers.
    logic [63:0] q [NBUF];
    logic        fill_wr;

    genvar g;
    generate
        for (g = 0; g < NBUF; g++) begin : lbuf
            logic [63:0] mem [LINE_WORDS];
            // ABOVE ANY RESET, for the reason np_vc2.sv spells out: a reset on
            // the register an array reads into stops the inference. The read
            // is unconditional anyway.
            always_ff @(posedge clk) begin
                q[g] <= mem[req_off];
                if (fill_wr && fill_idx == SW'(g)) mem[fill_pos[AW-1:0]] <= fbr_dout;
            end
        end
    endgenerate

    // ---- the display's read ----------------------------------------------
    // Registered, one cycle after the request, which is exactly what the
    // simulator's memory did and what newport.sv's readout already expects.
    logic [SW-1:0] hit_idx, sel_q;
    logic          hit_any;
    always_comb begin
        hit_idx = '0;
        hit_any = 1'b0;
        for (int i = 0; i < NBUF; i++)
            if (val[i] && tag[i] == req_line) begin
                hit_idx = SW'(i);
                hit_any = 1'b1;
            end
    end

    logic ack_q, miss_q;
    assign px_rdata = miss_q ? (dbg_miss_mark ? 64'h80 : 64'h0) : q[sel_q];
    assign px_ack   = ack_q;
    assign miss     = miss_q;

    // ---- the fill engine -------------------------------------------------
    typedef enum logic [1:0] { F_IDLE, F_REQ, F_DATA } fstate_t;
    fstate_t fst;

    wire [31:0] line_base  = 32'({21'b0, fill_line} << LINE_SHIFT);
    wire [31:0] fill_byte  = 32'({20'b0, fill_pos} << 3);
    wire [31:0] words_left = 32'(LINE_WORDS) - 32'({20'b0, fill_pos});

    assign fbr_addr  = line_base + fill_byte;
    assign fbr_burst = (words_left < 32'(BURST)) ? words_left[7:0] : 8'(BURST);
    assign fbr_req   = (fst == F_REQ);

    assign fill_wr = (fst == F_DATA) && fbr_dout_valid;

    // HOW FAR AHEAD THE FILL IS ALLOWED TO RUN, and this one comparison is the
    // whole of the eviction policy. The lines are wanted strictly in order, so
    // the buffer `fill_idx` is about to overwrite holds line fill_line - NBUF,
    // which the display has already passed as long as the fill is less than
    // NBUF lines ahead of it. Signed, because at the top of a frame the fill
    // restarts at zero while `disp_line` is still the last line of the frame
    // before - and an unsigned compare there reads as "enormously ahead" and
    // stalls the prefetcher for a whole frame.
    wire signed [12:0] ahead = $signed({2'b0, fill_line}) - $signed({2'b0, disp_line});
    wire may_fill = restart || (ahead < 13'sd0) || (ahead < $signed(13'(NBUF)));

    always_ff @(posedge clk) begin
        if (reset) begin
            val <= '0;
            for (int i = 0; i < NBUF; i++) tag[i] <= 11'h7FF;
            fill_idx  <= '0;
            fill_line <= 11'd0;
            fill_pos  <= '0;
            burst_left <= 9'd0;
            disp_line <= 11'h7FF;
            fst       <= F_IDLE;
            vs_d      <= 1'b0;
            restart   <= 1'b1;
            ack_q     <= 1'b0;
            miss_q    <= 1'b0;
            sel_q     <= '0;
        end else begin
            ack_q  <= 1'b0;
            miss_q <= 1'b0;

            if (px_req) begin
                ack_q     <= 1'b1;
                sel_q     <= hit_idx;
                miss_q    <= !hit_any;
                disp_line <= req_line;
            end

            vs_d <= vs;
            if (vs && !vs_d) begin
                // A new frame. Everything held is from the frame before and
                // none of it will be asked for again, so throw it away and
                // refill from line zero - there is a whole vertical blanking
                // interval to get ahead in.
                restart <= 1'b1;
            end

            case (fst)
                F_IDLE: begin
                    if (restart) begin
                        restart   <= 1'b0;
                        val       <= '0;
                        fill_idx  <= '0;
                        fill_line <= 11'd0;
                        fill_pos  <= '0;
                        // AND THE DISPLAY POINTER TOO. It is still holding the
                        // last visible line of the frame before - px_req stops
                        // during blanking - so leaving it there makes the fill
                        // look a thousand lines behind and it never throttles.
                        disp_line <= 11'd0;
                        fst       <= F_REQ;
                    end else if (may_fill) begin
                        fill_pos <= '0;
                        // The buffer about to be overwritten stops being
                        // valid the moment the first word lands in it.
                        val[fill_idx] <= 1'b0;
                        fst      <= F_REQ;
                    end
                end

                F_REQ: if (fbr_taken) begin
                    burst_left <= {1'b0, fbr_burst};
                    fst        <= F_DATA;
                end

                default: if (fbr_dout_valid) begin
                    fill_pos   <= fill_pos + 1'b1;
                    burst_left <= burst_left - 9'd1;
                    if (burst_left <= 9'd1) begin
                        if (int'(fill_pos) + 1 >= LINE_WORDS) begin
                            // The line is complete: publish it and step the
                            // ring on.
                            tag[fill_idx] <= fill_line;
                            val[fill_idx] <= 1'b1;
                            fill_idx      <= (fill_idx == SW'(NBUF-1))
                                             ? '0 : fill_idx + 1'b1;
                            fill_line     <= fill_line + 11'd1;
                            fst           <= F_IDLE;
                        end else begin
                            fst <= F_REQ;
                        end
                    end
                end
            endcase
        end
    end

endmodule
