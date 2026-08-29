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
//  THE CURSOR IS NOT BUILT. The position registers exist and the PROM's
//  Ng1TpMovec writes them, and the glyph would come out of this same SRAM,
//  but nothing generates cursor planes yet. The PROM's own Ng1CursorInit is a
//  stub ("XXX Set the cursor colors !"), so nothing on the boot path notices.
//  See docs/16-newport-plan.md, milestone N4.
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
    output logic        vert_int
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
    wire [14:0] ram_ra = host_ram_rd ? ram_addr : fetch_a;

    logic [15:0] pix_div_ctr;
    logic        pix_phase;
    wire         pix_tick = ce_pix && pix_phase;

    assign ce_pix = (PIX_DIV <= 1) ? 1'b1 : (pix_div_ctr == PIX_DIV[15:0] - 16'd1);

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
            ram_q        <= 16'h0;
        end else begin
            ram_q <= ram[ram_ra[AW-1:0]];

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
            if (ce_pix) begin
                pix_div_ctr <= 16'h0;
                pix_phase   <= ~pix_phase;
                de_d        <= de;
                if (!de) x_ctr <= 11'h0;
                else     x_ctr <= x_ctr + 11'd1;
                // The end of a visible span is the line advance. Blanking
                // lines do not move the frame buffer row, so this counts
                // displayed lines rather than total lines.
                if (de_d && !de) y_ctr <= y_ctr + 11'd1;
            end else begin
                pix_div_ctr <= pix_div_ctr + 16'd1;
            end
            vert_int_n_d <= state_c[0];

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
