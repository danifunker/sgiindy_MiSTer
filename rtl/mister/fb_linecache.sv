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
//  and it is not subtle. At one pixel per clock and EIGHT bytes a pixel the
//  display wanted 1344 words per 1680-clock line - 0.80 words a clock - and
//  the MiSTer DDR3 port is 64 bits at 50 MHz, so its ABSOLUTE PEAK is 1.00.
//  The display alone was asking for eighty per cent of the bus before the CPU
//  or the rasteriser asked for anything, and it measured 0.52 delivered.
//
//  MORE BUFFERS DO NOT HELP A SUSTAINED DEFICIT, and that was worth measuring
//  rather than assuming: at one pixel per clock, going from two line buffers
//  to eight moved the miss rate from 98.8% to 97%. Buffers absorb jitter. They
//  cannot absorb a rate that is simply too low, and nor can a bigger burst -
//  64 to 255 words a burst moved it by a tenth.
//
//  WHAT FIXED IT FOR GOOD WAS FETCHING LESS PER PIXEL. The frame buffer is now
//  two plane sets of FOUR bytes a pixel - the drawing planes in one region,
//  the auxiliary planes (overlay, popup, window ID) in another, two pixels to
//  a 64-bit word - so the display's drawing-plane stream is 660-odd words a
//  line, 0.39 words a clock at one pixel per clock. One instance of this
//  module serves each region. The auxiliary one carries the per-line flag
//  table described under TRACK_ZERO: X leaves the auxiliary planes empty
//  almost everywhere, and a line known to hold nothing visible there is
//  published as zeros without a fetch, so on a plain desktop the auxiliary
//  stream costs almost nothing and the bus is back under half loaded with
//  PIX_DIV at 1. (Do not start a line comment in this file with the tool's
//  name - it is read as a pragma.)
//
//  PIX_DIV IN newport.sv AND THE PIXEL WIDTH HERE ARE COUPLED AND NOTHING
//  ENFORCES IT. PIX_DIV went from 2 to 1 once before to double the frame rate,
//  which also doubled the display's memory demand and pushed it past what the
//  bridge can supply - and the unit test in tb_linecache.cpp still said
//  PIX_DIV was 2, so it handed the fill engine exactly twice the time it had
//  and passed with zero misses while the hardware missed more than half of
//  every line. A model kinder than the hardware is not a test of the hardware.
//
//  NBUF IS FOUR RATHER THAN TWO FOR MARGIN, NOT AS THE FIX. Two passes the
//  unit test, but that test has one master on the bus and the machine has
//  three; four buffers give the fill three line times instead of one to
//  absorb whatever the CPU and the rasteriser take. Each buffer is LINE_WORDS
//  x 64 bits of M10K.
//
//  HOW IT KNOWS WHAT TO FETCH. The display's access pattern is not a guess -
//  it is fully determined. VC2 walks x from 0 across a line and advances y at
//  the end of each visible one, so a request's line number is
//  `addr / (STRIDE * BYTES_PER_PX)` and the lines are wanted strictly in
//  order. The buffers are therefore a ring: `fill_idx` walks them, `fill_line`
//  counts up, and the fill is throttled to stay less than NBUF ahead of the
//  line being displayed - which is exactly the condition that stops it
//  overwriting a buffer still in use. At the top of a frame the sequence
//  jumps back to zero, which no "fetch the next one" rule predicts - hence
//  `vs`, which restarts the ring during vertical blanking, where there is time
//  to refill it.
//
//  TRACK_ZERO - THE AUXILIARY PLANES ARE ALMOST ALWAYS EMPTY. The compositor
//  only ever looks at the popup bits and the overlay byte of the auxiliary
//  word (ZERO_MASK names them, for both pixels of a word), and on a desktop
//  those are zero on every line that is not under a menu. So this keeps one
//  flag per frame buffer line: "may hold something under the mask". The
//  rasteriser SETS it whenever it writes a value with such bits into the
//  auxiliary planes of that line (`mark`, `mark_line`); the fill CLEARS it
//  when a whole line it fetched came back with nothing under the mask - unless
//  a mark for that line landed while the fetch was in flight, in which case
//  the fetch may predate the write and the flag stays. A line whose flag is
//  clear is published as zeros without touching memory. Flags reset to SET,
//  so the first frame after reset fetches everything and the table settles
//  from what is actually there. The drawing-plane instance leaves TRACK_ZERO
//  off and fetches every line.
//
//  A MISS SERVES BLACK RATHER THAN STALLING, because stalling is not on the
//  menu: there is no back-pressure on this path. A miss costs one pixel of
//  black, which is visible and self-correcting - the honest failure. `miss` is
//  brought out so that a top level can count them, and `dbg_miss_mark` makes
//  one visible on a screen, which is how the DE10-Nano's were found at all: a
//  miss and a frame buffer that is genuinely black look identical otherwise.
//============================================================================

module fb_linecache #(
    // Pixels per frame buffer line, and bytes per pixel IN THIS REGION. Each
    // plane set is a 32-bit slot per pixel on a 2048-pixel stride, two pixels
    // to a 64-bit word.
    parameter int STRIDE       = 2048,
    parameter int BYTES_PER_PX = 4,
    // How many words of a line the display actually needs. The visible span of
    // the widest timing table in np_timing.h is 1318 pixels = 659 words;
    // fetching the whole 1024-word line would cost half as much again for
    // nothing.
    parameter int LINE_WORDS   = 672,
    // Lines in the frame buffer. The fill stops here and waits for the next
    // frame's restart: a fill that walked on through the vertical blanking
    // would fetch memory beyond the frame (the other plane region, in fact)
    // and, worse, alias its flag onto line 0's - which is how line 0 went
    // black in the unit test.
    parameter int LINES        = 1024,
    // Words per burst. The bridge takes up to 255. Larger is slightly better
    // for the display and worse for everyone behind the same arbiter, and the
    // measurement says it barely matters: 64 to 255 moved the miss rate by a
    // tenth when the display was over-subscribed.
    parameter int BURST        = 128,
    // The per-line flag table (see the header). Off for the drawing planes.
    parameter bit TRACK_ZERO   = 1'b0,
    // The bits of a fetched word the display can ever see: per 32-bit pixel
    // slot the overlay byte pair [23:8] and the popup bits [3:2].
    parameter logic [63:0] ZERO_MASK = 64'h00FFFF0C_00FFFF0C
) (
    input  logic        clk,
    input  logic        reset,

    // ---- from the display side of newport.sv -----------------------------
    input  logic        px_req,        // one pulse per pixel
    input  logic [31:0] px_addr,       // byte address in this region
    output logic [63:0] px_rdata,      // the whole word; the caller picks its half
    output logic        px_ack,
    // VC2's vertical sync, in this clock domain. The prefetcher restarts on
    // its rising edge.
    input  logic        vs,

    // ---- from the rasteriser (TRACK_ZERO only) ---------------------------
    input  logic        mark,          // a visible auxiliary value was written
    input  logic [10:0] mark_line,     // ...into this frame buffer line

    // ---- to the DDR3 mux's burst read port -------------------------------
    output logic        fbr_req,
    output logic [31:0] fbr_addr,
    output logic  [7:0] fbr_burst,
    input  logic        fbr_taken,
    input  logic [63:0] fbr_dout,
    input  logic        fbr_dout_valid,

    output logic        miss,          // a pixel was asked for and not resident
    // Lines published as zeros without a fetch, since reset. What TRACK_ZERO
    // is saving, as a number the beacon can show.
    output logic [31:0] dbg_skips,

    // ---- bring-up instrument, not a feature ------------------------------
    // A miss serves black, which is indistinguishable from a frame buffer that
    // really is black - and on the first hardware run those were the two
    // candidates. With this set a miss serves index 0x80 instead, so a display
    // that is not being fed shows as mid-grey under newport's dbg_raw_index
    // rather than as nothing at all. It is what found the fill shortfall.
    input  logic        dbg_miss_mark
);

    localparam int AW = $clog2(LINE_WORDS);
    localparam int LINE_SHIFT = $clog2(STRIDE) + $clog2(BYTES_PER_PX);   // bytes per line, log2
    // FIXED AT FOUR because the buffers are written out one by one; see the
    // comment on them. NBUF-1 is how many line times a fill gets, which is
    // margin against the other two masters rather than the fix for the
    // bandwidth deficit - the header has that.
    localparam int NBUF = 4;
    localparam int SW = $clog2(NBUF);

    // Which line each buffer holds, whether it holds anything, and whether
    // what it holds is a line published as zeros without a fetch.
    logic [10:0]     tag [NBUF];
    logic [NBUF-1:0] val;
    logic [NBUF-1:0] zero;

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

    // ---- the per-line flag table (TRACK_ZERO) ----------------------------
    // 1024 flip-flops. Set wins over clear in the same cycle: the set is the
    // last assignment in the clocked block below.
    logic [1023:0] flag;
    logic          nz_acc;         // something under the mask seen in this fill
    logic          marked_during;  // a mark for fill_line landed during it
    wire           fill_flag = TRACK_ZERO ? flag[fill_line[9:0]] : 1'b1;
    wire           dout_nz   = |(fbr_dout & ZERO_MASK);

    // ---- the buffers -----------------------------------------------------
    // FOUR ARRAYS WRITTEN OUT LONGHAND, AND THAT IS NOT A STYLE CHOICE. The
    // obvious version of this is a generate loop declaring one array per
    // iteration, and Quartus infers NO MEMORY FROM IT AT ALL - an array
    // declared inside a generate block, written behind that block-local
    // declaration, is the shape the RAM inference does not recognise. It does
    // not warn, either: the whole point of Info (276014) is the arrays it
    // COULD see, and these produced no message whatsoever. What it produced
    // was 166,268 registers against a device with about 84,000, a fit that
    // failed at 291%, and no clue in the log.
    //
    // So: four plain arrays, four unconditional registered reads hoisted above
    // any reset, and one plain enabled store each. The mux is AFTER the
    // registers. This is the same shape the two-buffer version used and it is
    // the only one measured to work here - see the memory note on Quartus RAM
    // inference and syn/README.md.
    //
    // The cost is that NBUF is fixed at four rather than being a parameter.
    // That is worth it: an elegant version that silently builds flip-flops is
    // not a version.
    logic [SW-1:0] sel_q;
    logic          zero_q;
    logic [63:0] buf0 [LINE_WORDS];
    logic [63:0] buf1 [LINE_WORDS];
    logic [63:0] buf2 [LINE_WORDS];
    logic [63:0] buf3 [LINE_WORDS];
    logic [63:0] q0, q1, q2, q3;
    logic        fill_wr;

    always_ff @(posedge clk) begin
        // ABOVE ANY RESET, for the reason np_vc2.sv spells out: a reset on the
        // register an array reads into stops the inference. These reads are
        // unconditional anyway.
        q0 <= buf0[req_off];
        q1 <= buf1[req_off];
        q2 <= buf2[req_off];
        q3 <= buf3[req_off];
        if (fill_wr && fill_idx == 2'd0) buf0[fill_pos[AW-1:0]] <= fbr_dout;
        if (fill_wr && fill_idx == 2'd1) buf1[fill_pos[AW-1:0]] <= fbr_dout;
        if (fill_wr && fill_idx == 2'd2) buf2[fill_pos[AW-1:0]] <= fbr_dout;
        if (fill_wr && fill_idx == 2'd3) buf3[fill_pos[AW-1:0]] <= fbr_dout;
    end

    logic [63:0] q_sel;
    always_comb begin
        case (sel_q)
            2'd0:    q_sel = q0;
            2'd1:    q_sel = q1;
            2'd2:    q_sel = q2;
            default: q_sel = q3;
        endcase
    end

    // ---- the display's read ----------------------------------------------
    // Registered, one cycle after the request, which is exactly what the
    // simulator's memory did and what newport.sv's readout already expects.
    logic [SW-1:0] hit_idx;
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
    assign px_rdata = miss_q ? (dbg_miss_mark ? 64'h80 : 64'h0)
                    : zero_q ? 64'h0 : q_sel;
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
    wire may_fill = (restart || (ahead < 13'sd0) || (ahead < $signed(13'(NBUF))))
                  && (int'(fill_line) < LINES);

    always_ff @(posedge clk) begin
        if (reset) begin
            val <= '0;
            zero <= '0;
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
            zero_q    <= 1'b0;
            flag      <= '1;
            nz_acc    <= 1'b0;
            marked_during <= 1'b0;
            dbg_skips <= 32'd0;
        end else begin
            ack_q  <= 1'b0;
            miss_q <= 1'b0;

            if (px_req) begin
                ack_q     <= 1'b1;
                sel_q     <= hit_idx;
                zero_q    <= zero[hit_idx];
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

            if (mark && fst != F_IDLE && mark_line == fill_line)
                marked_during <= 1'b1;

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
                        // The very first line of a frame is fetched or
                        // published on the next pass through F_IDLE, where
                        // its flag is consulted like any other.
                    end else if (may_fill) begin
                        if (!fill_flag) begin
                            // Nothing visible on this line: publish zeros
                            // without a fetch and step the ring on.
                            tag[fill_idx]  <= fill_line;
                            val[fill_idx]  <= 1'b1;
                            zero[fill_idx] <= 1'b1;
                            fill_idx       <= (fill_idx == SW'(NBUF-1))
                                              ? '0 : fill_idx + 1'b1;
                            fill_line      <= fill_line + 11'd1;
                            dbg_skips      <= dbg_skips + 32'd1;
                        end else begin
                            fill_pos <= '0;
                            // The buffer about to be overwritten stops being
                            // valid the moment the first word lands in it.
                            val[fill_idx]  <= 1'b0;
                            zero[fill_idx] <= 1'b0;
                            nz_acc         <= 1'b0;
                            marked_during  <= 1'b0;
                            fst      <= F_REQ;
                        end
                    end
                end

                F_REQ: if (fbr_taken) begin
                    burst_left <= {1'b0, fbr_burst};
                    fst        <= F_DATA;
                end

                default: if (fbr_dout_valid) begin
                    fill_pos   <= fill_pos + 1'b1;
                    burst_left <= burst_left - 9'd1;
                    nz_acc     <= nz_acc | dout_nz;
                    if (burst_left <= 9'd1) begin
                        if (int'(fill_pos) + 1 >= LINE_WORDS) begin
                            // The line is complete: publish it and step the
                            // ring on. A line with nothing under the mask
                            // drops its flag, unless a write to it may have
                            // landed behind the fetch.
                            tag[fill_idx] <= fill_line;
                            val[fill_idx] <= 1'b1;
                            fill_idx      <= (fill_idx == SW'(NBUF-1))
                                             ? '0 : fill_idx + 1'b1;
                            fill_line     <= fill_line + 11'd1;
                            fst           <= F_IDLE;
                            if (TRACK_ZERO && !(nz_acc | dout_nz) && !marked_during)
                                flag[fill_line[9:0]] <= 1'b0;
                        end else begin
                            fst <= F_REQ;
                        end
                    end
                end
            endcase

            // Last, so that it wins over the clear above when both name the
            // same line in the same cycle.
            if (TRACK_ZERO && mark)
                flag[mark_line[9:0]] <= 1'b1;
        end
    end

endmodule
