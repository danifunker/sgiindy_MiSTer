//============================================================================
//  pit8254 - the 8254-style three-channel timer inside IOC2, at IOC + 0xB0.
//
//  The PROM's calibrate_delay (0xBFC31490) is what makes this mandatory: it
//  programs counter 2 in mode 2 with 10000, runs a fixed 512-iteration loop,
//  latches the counter and reads back how far it got. That number is how many
//  microseconds the loop took, and every later DELAY() is scaled by it. A
//  counter that just reads back what was written returns 0x2727 - the byte the
//  PROM last stored there, twice - which is greater than 10000, and the routine
//  concludes the measurement was garbage and starts over, forever.
//
//  The input clock is 1 MHz, so one count is one microsecond. That is IRIS's
//  value (Pit8254::new(1_000_000, ...) in src/ioc.rs) and it is what makes the
//  PROM's arithmetic come out in microseconds.
//
//  Scope: enough of the part for that, and for the periodic interrupts IRIX
//  will want from counters 0 and 1. Modes 0 and 4 stop at zero; everything
//  else reloads, which covers modes 2 and 3 - the only ones anything here
//  programs. The BCD bit is ignored: nothing on this machine sets it.
//============================================================================

module pit8254 #(
    // System clocks per timer count. 50 at the 50 MHz R4000 bus clock gives
    // the 1 MHz the PROM's microsecond arithmetic assumes.
    parameter int TICK_DIV = 50
)(
    input  logic       clk,
    input  logic       reset,
    input  logic       ce,

    input  logic       rd,          // one-cycle read strobe (has side effects)
    input  logic       wr,          // one-cycle write strobe
    input  logic [1:0] sel,         // 0..2 = counter, 3 = control word
    input  logic [7:0] din,
    output logic [7:0] dout,

    output logic [2:0] out          // counter outputs, for interrupt wiring
);

    logic [15:0] count  [0:2];
    logic [15:0] reload [0:2];
    logic [15:0] latch  [0:2];
    logic        latched[0:2];
    logic  [1:0] rw     [0:2];      // 00 latch, 01 LSB, 10 MSB, 11 LSB then MSB
    logic  [2:0] mode   [0:2];
    logic        running[0:2];
    logic        rd_msb [0:2];      // next read of an LSB/MSB pair is the MSB
    logic        wr_msb [0:2];      // next write of an LSB/MSB pair is the MSB

    logic [15:0] tick;

    // A mode that counts to zero and stops, rather than reloading.
    function automatic logic one_shot(input logic [2:0] m);
        one_shot = (m == 3'd0) || (m == 3'd4);
    endfunction

    // Combinational read. The byte depends on rw and, for an LSB/MSB pair, on
    // which half was read last - which is why the strobe below is a real read
    // strobe and not just "selected".
    always_comb begin
        logic [15:0] v;
        dout = 8'h00;
        if (sel != 2'd3) begin
            v = latched[sel] ? latch[sel] : count[sel];
            case (rw[sel])
                2'b01:   dout = v[7:0];
                2'b10:   dout = v[15:8];
                default: dout = rd_msb[sel] ? v[15:8] : v[7:0];
            endcase
        end
    end

    integer i;
    always_ff @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 3; i = i + 1) begin
                count[i]   <= 16'h0;
                reload[i]  <= 16'h0;
                latch[i]   <= 16'h0;
                latched[i] <= 1'b0;
                rw[i]      <= 2'b11;
                mode[i]    <= 3'd0;
                running[i] <= 1'b0;
                rd_msb[i]  <= 1'b0;
                wr_msb[i]  <= 1'b0;
            end
            tick <= 16'h0;
            out  <= 3'b000;
        end else begin
            //---------------- count ----------------
            if (ce) begin
                if (tick >= TICK_DIV[15:0] - 16'd1) begin
                    tick <= 16'h0;
                    for (i = 0; i < 3; i = i + 1) begin
                        if (running[i]) begin
                            if (count[i] == 16'h0) begin
                                out[i] <= 1'b1;
                                if (one_shot(mode[i])) running[i] <= 1'b0;
                                else                   count[i]   <= reload[i];
                            end else begin
                                count[i] <= count[i] - 16'd1;
                                out[i]   <= 1'b0;
                            end
                        end
                    end
                end else begin
                    tick <= tick + 16'd1;
                end
            end

            //---------------- register access ----------------
            if (wr) begin
                if (sel == 2'd3) begin
                    // Control word: SC[7:6] counter, RW[5:4], M[3:1], BCD[0].
                    if (din[5:4] == 2'b00) begin
                        // Counter latch command: freeze a copy for reading, so
                        // software sees a consistent 16-bit value.
                        if (din[7:6] != 2'b11) begin
                            latch[din[7:6]]   <= count[din[7:6]];
                            latched[din[7:6]] <= 1'b1;
                            rd_msb[din[7:6]]  <= 1'b0;
                        end
                    end else if (din[7:6] != 2'b11) begin
                        rw[din[7:6]]      <= din[5:4];
                        mode[din[7:6]]    <= din[3:1];
                        running[din[7:6]] <= 1'b0;
                        latched[din[7:6]] <= 1'b0;
                        rd_msb[din[7:6]]  <= 1'b0;
                        wr_msb[din[7:6]]  <= 1'b0;
                    end
                end else begin
                    case (rw[sel])
                        2'b01: begin
                            reload[sel]  <= {8'h00, din};
                            count[sel]   <= {8'h00, din};
                            running[sel] <= 1'b1;
                        end
                        2'b10: begin
                            reload[sel]  <= {din, 8'h00};
                            count[sel]   <= {din, 8'h00};
                            running[sel] <= 1'b1;
                        end
                        default:
                            // LSB then MSB: the counter starts on the second
                            // write, which is why the PROM's two stores of
                            // 0x10 and 0x27 load 0x2710 and not two counters.
                            if (!wr_msb[sel]) begin
                                reload[sel][7:0] <= din;
                                wr_msb[sel]      <= 1'b1;
                                running[sel]     <= 1'b0;
                            end else begin
                                reload[sel][15:8] <= din;
                                count[sel]        <= {din, reload[sel][7:0]};
                                wr_msb[sel]       <= 1'b0;
                                running[sel]      <= 1'b1;
                            end
                    endcase
                end
            end else if (rd && sel != 2'd3) begin
                if (rw[sel] == 2'b11) begin
                    rd_msb[sel] <= ~rd_msb[sel];
                    // The latched copy is released once both halves have been
                    // taken, so the next read sees the live count again.
                    if (rd_msb[sel]) latched[sel] <= 1'b0;
                end else begin
                    latched[sel] <= 1'b0;
                end
            end
        end
    end

endmodule
