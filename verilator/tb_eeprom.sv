//============================================================================
//  tb_eeprom -- the 93C56 configuration EEPROM model (rtl/sgi/eeprom_93c56.sv)
//  driven the way the PROM drives it. `make -C verilator tb_eeprom`.
//
//  Build 37 moved the array from flip-flops into an M10K: a registered read
//  and one registered write port, so a READ's word lands a clock after its
//  address and every store a clock after the edge that makes it. This checks
//  the protocol is unchanged by that, against a shadow copy kept here:
//    T1  power-up: word 0x11 is CACHSZ_PAGES, words 0x7D..0x7F the Ethernet
//        address, everything else erased
//    T2  WRITE without WREN is ignored; WREN, WRITE, WRDS lands the word, and
//        DO reads high (ready) once CS is raised again
//    T3  every address written with its own value and read back, twice, at
//        three different host speeds (SK edges 2, 5 and 40 clocks apart)
//    T4  ERASE, and ERASE after WRDS doing nothing
//    T5  WRAL and ERAL, one word per clock for 128 clocks
//    T6  a reset keeps what was written, re-seeds the Ethernet address and
//        clears the write enable
//    T7  a random mix of all of the above, 4000 commands
//============================================================================
`timescale 1ns/1ps
module tb_eeprom;

localparam logic [15:0] CACHSZ = 16'h0000;
localparam logic [47:0] MAC    = 48'h08_00_69_0A_1B_2C;

reg clk = 0;
always #5 clk = ~clk;

reg  reset = 1;
reg  cs = 0, sk = 0, di = 0;
wire do_out;

eeprom_93c56 #(.CACHSZ_PAGES(CACHSZ)) dut (
    .clk      (clk),
    .reset    (reset),
    .mac_addr (MAC),
    .cs       (cs),
    .sk       (sk),
    .di       (di),
    .do_out   (do_out)
);

integer errors = 0;
integer gap    = 2;              // clocks between host pin changes

logic [15:0] shadow [0:127];
logic        shadow_we;

task automatic wait_clocks(input int n);
    repeat (n) @(negedge clk);
endtask

// One pin change, then `gap` clocks - the MC register is written once per
// change, and a bus write is never shorter than that.
task automatic pins(input logic c, input logic s, input logic d);
    @(negedge clk);
    cs = c; sk = s; di = d;
    wait_clocks(gap);
endtask

// A bit into the part: DI, SK low, SK high (the rising edge samples DI).
task automatic send_bit(input logic b);
    pins(1'b1, sk, b);
    pins(1'b1, 1'b0, b);
    pins(1'b1, 1'b1, b);
endtask

task automatic cmd_start();
    pins(1'b0, sk, di);
    pins(1'b1, sk, di);
    pins(1'b1, 1'b1, di);
endtask

task automatic cmd_end();
    pins(1'b1, 1'b0, di);
    pins(1'b0, 1'b0, di);
    pins(1'b0, 1'b1, di);
endtask

task automatic send_cmd(input logic [1:0] op, input logic [7:0] a);
    send_bit(1'b1);
    for (int i = 1; i >= 0; i--) send_bit(op[i]);
    for (int i = 7; i >= 0; i--) send_bit(a[i]);
endtask

task automatic ee_read(input logic [6:0] a, output logic [15:0] v);
    cmd_start();
    send_cmd(2'b10, {1'b0, a});
    if (do_out !== 1'b0) begin
        $display("FAIL read %02x: no dummy zero after the address", a);
        errors++;
    end
    v = '0;
    for (int i = 15; i >= 0; i--) begin
        pins(1'b1, 1'b0, 1'b0);
        pins(1'b1, 1'b1, 1'b0);
        v[i] = do_out;
    end
    cmd_end();
endtask

task automatic ee_ctrl(input logic [1:0] sub);
    cmd_start();
    send_cmd(2'b00, {sub, 6'h15});
    cmd_end();
    if (sub == 2'b00) shadow_we = 1'b0;
    if (sub == 2'b11) shadow_we = 1'b1;
endtask

// The PROM's ready poll: CS up, DO must read 1.
task automatic ready_poll(input string what);
    pins(1'b1, sk, di);
    if (do_out !== 1'b1) begin
        $display("FAIL %s: DO low when polled for ready", what);
        errors++;
    end
    pins(1'b0, sk, di);
endtask

// WITHOUT WREN THE DATA IS NOT SENT. The model drops back to waiting for a
// start bit after a refused address, so sixteen data bits would be decoded as
// whatever command they happen to spell (1 00 11xxxxxx is WREN). The PROM
// never writes without WREN; a host that did would drop CS here.
task automatic ee_write(input logic [6:0] a, input logic [15:0] v);
    cmd_start();
    send_cmd(2'b01, {1'b0, a});
    if (shadow_we) for (int i = 15; i >= 0; i--) send_bit(v[i]);
    cmd_end();
    ready_poll("write");
    if (shadow_we) shadow[a] = v;
endtask

task automatic ee_erase(input logic [6:0] a);
    cmd_start();
    send_cmd(2'b11, {1'b0, a});
    cmd_end();
    if (shadow_we) shadow[a] = 16'hFFFF;
endtask

task automatic ee_wral(input logic [15:0] v);
    cmd_start();
    send_cmd(2'b00, 8'h40);
    if (shadow_we) for (int i = 15; i >= 0; i--) send_bit(v[i]);   // see ee_write
    wait_clocks(140);                 // 128 clocks of bulk fill
    cmd_end();
    if (shadow_we) for (int i = 0; i < 128; i++) shadow[i] = v;
endtask

task automatic ee_eral();
    cmd_start();
    send_cmd(2'b00, 8'h80);
    wait_clocks(140);
    cmd_end();
    if (shadow_we) for (int i = 0; i < 128; i++) shadow[i] = 16'hFFFF;
endtask

task automatic check(input logic [6:0] a, input string what);
    logic [15:0] v;
    ee_read(a, v);
    if (v !== shadow[a]) begin
        $display("FAIL %s: word %02x read %04x, expected %04x", what, a, v, shadow[a]);
        errors++;
    end
endtask

task automatic do_reset();
    @(negedge clk);
    reset = 1; cs = 0; sk = 0; di = 0;
    wait_clocks(5);
    reset = 0;
    wait_clocks(8);
    shadow[7'h7D] = MAC[47:32];
    shadow[7'h7E] = MAC[31:16];
    shadow[7'h7F] = MAC[15:0];
    shadow_we = 1'b0;
endtask

initial begin
    for (int i = 0; i < 128; i++) shadow[i] = 16'hFFFF;
    shadow[7'h11] = CACHSZ;
    do_reset();

    // T1
    for (int a = 0; a < 128; a++) check(7'(a), "T1 power-up");
    $display("T1 power-up contents: %0d errors so far", errors);

    // T2
    ee_write(7'h20, 16'h1234);           // no WREN yet: ignored
    check(7'h20, "T2 write without WREN");
    ee_ctrl(2'b11);
    ee_write(7'h20, 16'hBEEF);
    ee_ctrl(2'b00);
    check(7'h20, "T2 write");
    ee_write(7'h21, 16'h5555);           // after WRDS: ignored
    check(7'h21, "T2 write after WRDS");
    $display("T2 WREN / WRITE / WRDS: %0d errors so far", errors);

    // T3
    for (int pass = 0; pass < 3; pass++) begin
        gap = (pass == 0) ? 2 : (pass == 1) ? 5 : 40;
        ee_ctrl(2'b11);
        for (int a = 0; a < 128; a++) ee_write(7'(a), 16'(a * 16'h0101 + pass * 16'h1111));
        ee_ctrl(2'b00);
        for (int a = 0; a < 128; a++) check(7'(a), "T3 readback");
        for (int a = 127; a >= 0; a--) check(7'(a), "T3 readback, descending");
    end
    gap = 2;
    $display("T3 all 128 words at three host speeds: %0d errors so far", errors);

    // T4
    ee_erase(7'h33);                     // write enable is off
    check(7'h33, "T4 erase without WREN");
    ee_ctrl(2'b11);
    ee_erase(7'h33);
    ee_ctrl(2'b00);
    check(7'h33, "T4 erase");
    check(7'h34, "T4 neighbour of the erased word");
    $display("T4 ERASE: %0d errors so far", errors);

    // T5
    ee_ctrl(2'b11);
    ee_wral(16'hA5C3);
    for (int a = 0; a < 128; a++) check(7'(a), "T5 WRAL");
    ee_eral();
    ee_ctrl(2'b00);
    for (int a = 0; a < 128; a++) check(7'(a), "T5 ERAL");
    $display("T5 WRAL / ERAL: %0d errors so far", errors);

    // T6
    ee_ctrl(2'b11);
    ee_write(7'h11, 16'h0042);
    ee_write(7'h7D, 16'h0000);
    ee_write(7'h40, 16'hC0DE);
    do_reset();
    ee_write(7'h41, 16'hDEAD);           // WREN was cleared by the reset
    for (int a = 0; a < 128; a++) check(7'(a), "T6 after reset");
    $display("T6 reset: %0d errors so far", errors);

    // T7
    for (int n = 0; n < 4000; n++) begin
        automatic int r = $urandom_range(0, 99);
        automatic logic [6:0] a = 7'($urandom);
        gap = $urandom_range(2, 7);
        if      (r < 35) check(a, "T7 read");
        else if (r < 60) ee_write(a, 16'($urandom));
        else if (r < 70) ee_ctrl(2'b11);
        else if (r < 78) ee_ctrl(2'b00);
        else if (r < 88) ee_erase(a);
        else if (r < 90) ee_wral(16'($urandom));
        else if (r < 91) ee_eral();
        else if (r < 93) do_reset();
        else             check(a, "T7 read");
    end
    gap = 2;
    for (int a = 0; a < 128; a++) check(7'(a), "T7 final");
    $display("T7 random mix: %0d errors so far", errors);

    if (errors == 0) $display("tb_eeprom: PASS");
    else             $display("tb_eeprom: FAIL (%0d errors)", errors);
    $finish;
end

endmodule
