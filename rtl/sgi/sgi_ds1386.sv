//============================================================================
//  sgi_ds1386 - Dallas DS1386-8K, the real-time clock and the NVRAM that
//  holds the PROM's environment.
//
//  It hangs off HPC3's battery-backed-RAM window, ONE DEVICE BYTE PER 32-BIT
//  WORD: device byte N is the word at 0x1FBE0000 + N*4, value in the low byte.
//  The PROM's own primitives settle that beyond argument - nvram_read and
//  nvram_write (0xBFC110B0 / 0xBFC11144) both compute 0xBFBE0100 + off*4 and
//  step by four - and it is why the PROM's "NVRAM offset 0" is device byte
//  0x40: the first 0x40 bytes are the clock and its control registers.
//
//  Register layout, matching IRIS's src/ds1x86.rs (which boots IRIX with it):
//
//    0x00 hundredths   0x01 seconds     0x02 minutes    0x03 minutes alarm
//    0x04 hours        0x05 hours alarm 0x06 day of wk  0x07 day alarm
//    0x08 date         0x09 month       0x0A year       0x0B command
//    0x0C, 0x0D watchdog                0x0E, 0x0F control
//    0x10-0x3F        further control space, plain storage here
//    0x40-0x1FFF      the NVRAM the PROM keeps its environment in
//
//  Everything is BCD except the day of week. Bit 7 of the command register is
//  TE, transfer enable: while it is clear the clock is frozen, which is how
//  software reads a consistent time and how it sets one.
//
//  CONTENTS ARE VOLATILE. On hardware this part has a battery; here it powers
//  up blank, so the PROM finds a bad checksum and reinitialises its
//  environment on every boot. That is the documented failure mode rather than
//  a hang - see docs/03-boot-prom.md on the checksum and the validity tag -
//  and it is the one thing standing between this and a remembered `setenv`.
//  Wiring the array to MiSTer's SD-card save path is the fix.
//============================================================================

module sgi_ds1386 #(
    // System clocks per centisecond. 500000 is the 50 MHz R4000 bus clock the
    // MC's RPSS divider implies (see sgi_mc.sv).
    parameter int TICK_DIV = 500_000,

    // Power-on date, since there is no battery. On hardware this should come
    // from MiSTer's HPS clock at load time; until then it is a fixed, plainly
    // wrong-but-plausible value rather than 00:00 on an unset part.
    parameter logic [7:0] POR_YEAR  = 8'h56,   // BCD, offset from 1940 => 1996
    parameter logic [7:0] POR_MONTH = 8'h02,
    parameter logic [7:0] POR_DATE  = 8'h12,
    parameter logic [7:0] POR_DAY   = 8'h02,   // 1 = Monday
    parameter logic [7:0] POR_HOUR  = 8'h12
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,

    input  logic        sel,          // one-cycle request pulse, address in window
    input  logic        we,
    input  logic [14:0] addr,         // offset into the 32 KB window, 8-aligned
    input  logic  [7:0] be,
    input  logic [63:0] wdata,
    output logic [63:0] rdata,
    output logic        ack
);

    localparam int R_HUNDREDTHS = 0;
    localparam int R_SECONDS    = 1;
    localparam int R_MINUTES    = 2;
    localparam int R_HOURS      = 4;
    localparam int R_DAY        = 6;
    localparam int R_DATE       = 8;
    localparam int R_MONTH      = 9;
    localparam int R_YEAR       = 10;
    localparam int R_COMMAND    = 11;

    logic  [7:0] rtc [0:15];
    // TWO BANKS, NOT ONE ARRAY, and that is what puts the NVRAM in M10Ks.
    //
    // This used to be a single `logic [7:0] nv [0:8191]`. That array has FOUR
    // ports - dev_rd(1'b0) and dev_rd(1'b1) each read it, and the unrolled
    // write loop below writes it twice - and a memory block has two. So
    // Quartus could not infer one and built all 65,536 bits out of flip-flops:
    // 65,713 registers and 30,430 ALUTs, more logic than the entire R4300i,
    // and on its own most of what made the design miss the device.
    //
    // The split costs nothing because the device index is {addr[14:3], w}:
    // the bit that separates the two accesses IS w. Bank w holds every byte
    // whose index has w in bit 0, addressed by addr[14:3], so each bank ends
    // up with exactly one reader and one writer - the simple dual-port
    // template Quartus does infer. nv0[0:7] and nv1[0:7] are the unused
    // shadow of the 16 clock registers, as before.
    logic  [7:0] nv0 [0:4095];        // device bytes whose index bit 0 is 0
    logic  [7:0] nv1 [0:4095];        // ...and whose index bit 0 is 1
    logic [31:0] tick;

    wire te = rtc[R_COMMAND][7];

    // ---- bus ------------------------------------------------------------
    // Device byte for each half of the doubleword: w=0 is the byte at addr+0,
    // w=1 the one at addr+4, and addr[2] is always zero.
    function automatic logic [12:0] dev_idx(input logic w);
        dev_idx = {addr[14:3], w};
    endfunction

    // ---- read path, SHAPED SO THE NVRAM INFERS AS M10Ks --------------------
    //
    // Quartus will only put an array in a memory block when the array read
    // goes straight into a register. A read ENABLE is fine; a mux or a
    // zeroing default between the array and the flop is not, and inference
    // then fails silently and the array becomes flip-flops. The old read was
    //
    //     rdata <= 64'h0;  ...  if (sel) rdata <= {..., dev_rd(1'b0), ...};
    //
    // which put both the rtc/nv mux and a default of zero in the way. All
    // three shapes were checked against 17.0.2 Lite before this was rewritten:
    // enable alone infers, enable plus mux does not, and mux-after-register
    // does.
    //
    // So each bank is read into its own register with nothing in between, the
    // clock-register value and the "is this one of the 16 clock registers"
    // decision are registered beside it, and the mux moves after them. That
    // keeps the timing identical: rdata settles one cycle after addr, which is
    // the same cycle ack is asserted, exactly as before.
    //
    // rdata is no longer forced to zero between accesses. That is safe because
    // sgi_indy.sv only ever samples it under rtc_ack - see the read mux there.
    //
    // Index arithmetic, from dev_idx = {addr[14:3], w}:
    //   dev_idx(w) < 16     <=>  addr[14:6] == 0      (independent of w)
    //   dev_idx(w)[3:0]     ==   {addr[5:3], w}
    //   nv[dev_idx(w)]      ==   nv<w>[addr[14:3]]
    wire dev_low = (addr[14:6] == 9'd0);

    // The reads live in the SAME always_ff as the writes, below. Quartus only
    // infers a memory when it can see both halves in one clocked process; with
    // the reads in a process of their own it does not recognise the array at
    // all, and says nothing about it either - no "uninferred RAM" message, it
    // simply builds 65,536 flip-flops.
    logic [7:0] nvq0, nvq1, rtcq0, rtcq1;
    logic       lowq;

    assign rdata = {24'h0, (lowq ? rtcq0 : nvq0),
                    24'h0, (lowq ? rtcq1 : nvq1)};

    // Whichever byte lane is enabled carries the value; see sgi_ioc.sv.
    function automatic logic [7:0] dev_wr_byte(input logic w);
        dev_wr_byte = 8'h00;
        for (int b = 0; b < 4; b++)
            if (be[7 - 4*w - b]) dev_wr_byte = wdata[56 - 32*w - 8*b +: 8];
    endfunction

    wire [1:0] wr_en = {sel && we && (|be[3:0]), sel && we && (|be[7:4])};

    // ---- BCD calendar ----------------------------------------------------
    // Incrementing in BCD directly rather than keeping a binary count and
    // converting: the registers ARE the state on this part, software writes
    // them, and a converted view would have to be reversed on every write.
    function automatic logic [7:0] bcd_inc(input logic [7:0] v);
        bcd_inc = (v[3:0] == 4'd9) ? {v[7:4] + 4'd1, 4'd0} : {v[7:4], v[3:0] + 4'd1};
    endfunction

    // Days in the current month, BCD. February is 29 in a leap year; the year
    // register counts from 1940, so "divisible by four" is enough until 2100 -
    // 2000 was a leap year and this part cannot reach 2100.
    function automatic logic [7:0] month_len(input logic [7:0] m, input logic [7:0] y);
        logic [7:0] yb;
        yb = {4'd0, y[7:4]} * 8'd10 + {4'd0, y[3:0]};
        case (m)
            8'h02:  month_len = (yb[1:0] == 2'b00) ? 8'h29 : 8'h28;
            8'h04, 8'h06, 8'h09, 8'h11: month_len = 8'h30;
            default: month_len = 8'h31;
        endcase
    endfunction

    integer i;
    always_ff @(posedge clk) begin
        ack   <= 1'b0;

        // Unconditional, and ahead of the reset branch: an array read with
        // nothing between it and its register is the only shape that infers.
        nvq0  <= nv0[addr[14:3]];
        nvq1  <= nv1[addr[14:3]];
        rtcq0 <= rtc[{addr[5:3], 1'b0}];
        rtcq1 <= rtc[{addr[5:3], 1'b1}];
        lowq  <= dev_low;

        if (reset) begin
            for (i = 0; i < 16; i = i + 1) rtc[i] <= 8'h00;
            rtc[R_YEAR]    <= POR_YEAR;
            rtc[R_MONTH]   <= POR_MONTH;
            rtc[R_DATE]    <= POR_DATE;
            rtc[R_DAY]     <= POR_DAY;
            rtc[R_HOURS]   <= POR_HOUR;
            rtc[R_COMMAND] <= 8'h80;          // TE set: the clock runs
            tick           <= 32'd0;
        end else begin
            //---------------- the clock ----------------
            if (ce && te) begin
                if (tick >= TICK_DIV - 1) begin
                    tick <= 32'd0;
                    if (rtc[R_HUNDREDTHS] != 8'h99) begin
                        rtc[R_HUNDREDTHS] <= bcd_inc(rtc[R_HUNDREDTHS]);
                    end else begin
                        rtc[R_HUNDREDTHS] <= 8'h00;
                        if (rtc[R_SECONDS] != 8'h59) begin
                            rtc[R_SECONDS] <= bcd_inc(rtc[R_SECONDS]);
                        end else begin
                            rtc[R_SECONDS] <= 8'h00;
                            if (rtc[R_MINUTES] != 8'h59) begin
                                rtc[R_MINUTES] <= bcd_inc(rtc[R_MINUTES]);
                            end else begin
                                rtc[R_MINUTES] <= 8'h00;
                                // Hours are 24-hour here: bit 6 selects 12-hour
                                // mode on a real part and nothing sets it.
                                if (rtc[R_HOURS] != 8'h23) begin
                                    rtc[R_HOURS] <= bcd_inc(rtc[R_HOURS]);
                                end else begin
                                    rtc[R_HOURS] <= 8'h00;
                                    rtc[R_DAY]   <= (rtc[R_DAY] >= 8'h07) ? 8'h01
                                                                          : bcd_inc(rtc[R_DAY]);
                                    if (rtc[R_DATE] != month_len(rtc[R_MONTH], rtc[R_YEAR])) begin
                                        rtc[R_DATE] <= bcd_inc(rtc[R_DATE]);
                                    end else begin
                                        rtc[R_DATE] <= 8'h01;
                                        if (rtc[R_MONTH] != 8'h12) begin
                                            rtc[R_MONTH] <= bcd_inc(rtc[R_MONTH]);
                                        end else begin
                                            rtc[R_MONTH] <= 8'h01;
                                            rtc[R_YEAR]  <= (rtc[R_YEAR] == 8'h99) ? 8'h00
                                                                                   : bcd_inc(rtc[R_YEAR]);
                                        end
                                    end
                                end
                            end
                        end
                    end
                end else begin
                    tick <= tick + 32'd1;
                end
            end

            //---------------- bus ----------------
            // A software write to a time register lands after the tick above,
            // so setting the clock always wins over the same cycle's carry.
            // The clock registers keep the loop; the two NVRAM banks are
            // written flat instead, one plain enabled store each. Nested in
            // the loop - under `if (wr_en[w])`, past a block-local `idx` -
            // Quartus does not recognise them as memory writes at all and
            // never even reports them as uninferred.
            //
            // Same decode, spelled without dev_idx: idx = {addr[14:3], w}, so
            // idx < 16 is addr[14:6] == 0 for either half, and idx[3:0] is
            // {addr[5:3], w}.
            for (int w = 0; w < 2; w++)
                if (wr_en[w] && dev_low) rtc[{addr[5:3], w[0]}] <= dev_wr_byte(w[0]);

            if (wr_en[0] && !dev_low) nv0[addr[14:3]] <= dev_wr_byte(1'b0);
            if (wr_en[1] && !dev_low) nv1[addr[14:3]] <= dev_wr_byte(1'b1);

            if (sel) ack <= 1'b1;
        end
    end

endmodule
