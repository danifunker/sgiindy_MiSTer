//============================================================================
//  tb_ds1386 -- the DS1386's time registers against the MiSTer's clock
//  (docs/design/r4600-accuracy-clock-disk.md). `make -C verilator tb_ds1386`.
//
//  Drives hps_io's RTC bus the way Main_MiSTer's send_rtc() and hps_io.sv do
//  it - the four data words first, bit 64 toggled at the end of the command -
//  and reads the registers back through the part's own bus, the way the PROM
//  and IRIX do. Checks:
//    T1  power-on: the fixed 1996 date, clock running
//    T2  a host time loads every register, year counted from 1940, weekday
//        Sunday-0 turned into Monday-1
//    T3  the loaded time advances: a second rolls over at the tick rate
//    T4  a reset keeps the host's time (battery semantics) and the clock runs
//    T5  a host time that arrives DURING reset is loaded once reset releases
//    T6  the year boundaries: 1999, 2000, 2039, 1940
//    T7  software still sets the clock: a write wins over the host's time
//============================================================================
`timescale 1ns/1ps
module tb_ds1386;

localparam int TICK_DIV = 10;          // clocks per centisecond, for speed

reg clk = 0;
always #5 clk = ~clk;

reg         reset = 1;
reg  [64:0] host_rtc = '0;
reg         sel = 0, we = 0;
reg  [14:0] addr = 0;
reg   [7:0] be = 0;
reg  [63:0] wdata = 0;
wire [63:0] rdata;
wire        ack;

sgi_ds1386 #(.TICK_DIV(TICK_DIV)) dut (
    .clk      (clk),
    .reset    (reset),
    .mac_addr (48'h08_00_69_12_34_56),
    .ce       (1'b1),
    .host_rtc (host_rtc),
    .sel      (sel),
    .we       (we),
    .addr     (addr),
    .be       (be),
    .wdata    (wdata),
    .rdata    (rdata),
    .ack      (ack)
);

integer errors = 0;

// One device byte, the way the bus presents it: device byte N is the word at
// N*4, i.e. addr[14:3] = N >> 1 and the half (w) = N & 1; w = 0 comes back in
// rdata[39:32], w = 1 in rdata[7:0], one clock after the request.
task automatic rd(input int n, output logic [7:0] v);
    @(negedge clk);
    addr = 15'((n >> 1) << 3); sel = 1; we = 0; be = 8'hFF;
    @(negedge clk);
    sel = 0;
    v = (n & 1) ? rdata[7:0] : rdata[39:32];
endtask

task automatic wr(input int n, input logic [7:0] v);
    @(negedge clk);
    addr = 15'((n >> 1) << 3); sel = 1; we = 1;
    if (n & 1) begin be = 8'h01; wdata = {56'h0, v}; end
    else       begin be = 8'h10; wdata = {24'h0, v, 32'h0}; end
    @(negedge clk);
    sel = 0; we = 0; be = 0;
endtask

task automatic expect_reg(input string what, input int n, input logic [7:0] want);
    logic [7:0] got;
    rd(n, got);
    if (got !== want) begin
        $display("FAIL %s: reg 0x%02x = %02x, want %02x", what, n, got, want);
        errors++;
    end
endtask

// send_rtc(): sec, min, hour, mday, month (1-12), year of century, wday
// (0 = Sunday), all BCD but wday; then hps_io toggles bit 64 at command end.
task automatic host_send(input logic [7:0] sec, input logic [7:0] mn, input logic [7:0] hr,
                         input logic [7:0] mday, input logic [7:0] mon, input logic [7:0] yy,
                         input logic [7:0] wday);
    @(negedge clk);
    host_rtc[15:0]  = {mn, sec};
    @(negedge clk);
    host_rtc[31:16] = {mday, hr};
    @(negedge clk);
    host_rtc[47:32] = {yy, mon};
    @(negedge clk);
    host_rtc[63:48] = {8'h40, wday};
    @(negedge clk);
    host_rtc[64] = ~host_rtc[64];
endtask

// Centiseconds of clock time.
task automatic run_cs(input int cs);
    repeat (cs * TICK_DIV) @(posedge clk);
endtask

initial begin
    logic [7:0] v;
    repeat (4) @(posedge clk);
    @(negedge clk) reset = 0;
    repeat (8) @(posedge clk);          // the MAC seed runs three clocks

    // T1: power-on date 1996-02-12 12:00, TE set
    expect_reg("T1 year",    10, 8'h56);
    expect_reg("T1 month",    9, 8'h02);
    expect_reg("T1 date",     8, 8'h12);
    expect_reg("T1 hours",    4, 8'h12);
    expect_reg("T1 command", 11, 8'h80);

    // T2: 2026-09-16 13:45:38, a Wednesday (wday 3)
    host_send(8'h38, 8'h45, 8'h13, 8'h16, 8'h09, 8'h26, 8'd3);
    repeat (2) @(posedge clk);
    expect_reg("T2 seconds",  1, 8'h38);
    expect_reg("T2 minutes",  2, 8'h45);
    expect_reg("T2 hours",    4, 8'h13);
    expect_reg("T2 day",      6, 8'h03);
    expect_reg("T2 date",     8, 8'h16);
    expect_reg("T2 month",    9, 8'h09);
    expect_reg("T2 year",    10, 8'h86);    // 2026 - 1940 = 86

    // T3: a second later it reads :39
    run_cs(100);
    expect_reg("T3 seconds",  1, 8'h39);

    // T4: a reset keeps the host's time, and the clock keeps running after it
    @(negedge clk) reset = 1;
    repeat (20) @(posedge clk);
    @(negedge clk) reset = 0;
    expect_reg("T4 year",    10, 8'h86);
    expect_reg("T4 minutes",  2, 8'h45);
    expect_reg("T4 command", 11, 8'h80);
    run_cs(100);
    expect_reg("T4 seconds",  1, 8'h40);

    // T5: a time sent while the machine is held in reset (boot.rom's
    // download does this) is loaded when reset releases. A Sunday.
    @(negedge clk) reset = 1;
    host_send(8'h07, 8'h06, 8'h05, 8'h04, 8'h03, 8'h27, 8'd0);
    repeat (20) @(posedge clk);
    @(negedge clk) reset = 0;
    repeat (2) @(posedge clk);
    expect_reg("T5 seconds",  1, 8'h07);
    expect_reg("T5 hours",    4, 8'h05);
    expect_reg("T5 day",      6, 8'h07);    // Sunday is 7 when Monday is 1
    expect_reg("T5 month",    9, 8'h03);
    expect_reg("T5 year",    10, 8'h87);

    // T6: year boundaries
    host_send(8'h00, 8'h00, 8'h00, 8'h01, 8'h01, 8'h99, 8'd5);
    repeat (2) @(posedge clk);
    expect_reg("T6 1999",    10, 8'h59);
    host_send(8'h00, 8'h00, 8'h00, 8'h01, 8'h01, 8'h00, 8'd6);
    repeat (2) @(posedge clk);
    expect_reg("T6 2000",    10, 8'h60);
    host_send(8'h00, 8'h00, 8'h00, 8'h01, 8'h01, 8'h39, 8'd6);
    repeat (2) @(posedge clk);
    expect_reg("T6 2039",    10, 8'h99);
    host_send(8'h00, 8'h00, 8'h00, 8'h01, 8'h01, 8'h40, 8'd1);
    repeat (2) @(posedge clk);
    expect_reg("T6 1940",    10, 8'h00);

    // T7: software sets the clock the DS1386 way - TE clear, write, TE set -
    // and what it wrote is what reads back.
    wr(11, 8'h00);
    wr(10, 8'h83);
    wr(2,  8'h59);
    wr(11, 8'h80);
    expect_reg("T7 year",    10, 8'h83);
    expect_reg("T7 minutes",  2, 8'h59);

    if (errors == 0) $display("tb_ds1386: PASS");
    else             $display("tb_ds1386: %0d FAILED", errors);
    $finish;
end

endmodule
