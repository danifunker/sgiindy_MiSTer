//============================================================================
//  sim_top - headless top level for CPU validation.
//
//  Instantiates the core exactly as `sgiindy.sv` will on hardware, but hangs
//  C++-backed models off the memory, PROM and GIO64 ports. There is no video,
//  no audio and no HPS, because nothing through milestone M1 needs any of it -
//  the cpu-tests suite wants RAM, an SCC and (optionally) a device in GIO
//  slot 0, and that is all this provides.
//
//  The GUI harness (`sim_gui.cpp`) drives this same module rather than a
//  separate `emu` wrapper - one top level, one set of device models, and CPU
//  regressions still run in CI with no SDL, no window and no ImGui build.
//============================================================================

module sim_top
(
    input  wire        clk,
    input  wire        reset,
    // Serial-side clock for the SCC. On hardware this is 3.6864 MHz from a
    // PLL; here the harness supplies it directly so a test can pick a rate
    // that keeps the run short. The console tap is bit-rate independent, so
    // only a test that decodes the TX line actually cares.
    input  wire        sclk,
    input  wire [31:0] boot_pc,
    input  wire        gio_present,

    // Serial receive for the console channel. Idle mark is 1; the GUI harness
    // shifts typed characters out on it so the Command Monitor can be driven.
    input  wire        rxdb,

    // Console tap: one pulse per byte handed to the SCC transmitter.
    output wire        tx_valid,
    output wire  [7:0] tx_data,
    output wire        tx_chan,
    output wire        txda,
    output wire        txdb,

    // Bus trace, sampled by the harness every cycle.
    output wire        bus_req,
    output wire        bus_we,
    output wire [31:0] bus_addr,
    output wire [63:0] bus_wdata,
    output wire  [7:0] bus_be,
    output wire [63:0] bus_rdata,
    output wire        bus_ack,
    output wire        bus_unclaimed,
    output wire  [5:0] cpu_error
);

    wire        ram_req, ram_we, ram_ack;
    wire [31:0] ram_addr;
    wire [63:0] ram_wdata, ram_rdata;
    wire  [7:0] ram_be;

    wire        prom_req, prom_ack;
    wire [31:0] prom_addr;
    wire [63:0] prom_rdata;

    wire        gio_req, gio_we, gio_ack;
    wire [31:0] gio_addr;
    wire [63:0] gio_wdata, gio_rdata;
    wire  [7:0] gio_be;

    // RTC_TICK_DIV: 5000 clocks per centisecond instead of the hardware
    // 500000, so the machine's clock runs a hundred times faster than the
    // simulated wall clock. The PROM waits for the seconds register to change
    // during boot; at the real ratio that single wait is fifty million cycles
    // and dominates the run. Nothing the harness checks depends on the rate -
    // it is the same accommodation as feeding the SCC a fast `sclk`.
    // PIT_TICK_DIV: 5 clocks per timer count instead of 50, so the machine's
    // microsecond is a tenth of the real one and every DELAY() costs a tenth
    // of the cycles. calibrate_delay measures its 512-iteration loop against
    // this same timer, so the calibration stays self-consistent - it just
    // concludes the machine is ten times faster, which for a core running with
    // both caches off and a bus round trip per instruction is arguably nearer
    // the truth than 50 MHz is. The margin matters: the routine restarts
    // forever if the loop measures more than 10000 counts, and at this setting
    // it measures about 2000.
    sgi_indy #(.MEM_MB(64), .RTC_TICK_DIV(5000), .PIT_TICK_DIV(5)) u_core
    (
        .clk           (clk),
        .ce            (1'b1),
        .reset         (reset),
        .sclk          (sclk),
        .boot_pc       (boot_pc),

        .ram_req       (ram_req),
        .ram_we        (ram_we),
        .ram_addr      (ram_addr),
        .ram_wdata     (ram_wdata),
        .ram_be        (ram_be),
        .ram_rdata     (ram_rdata),
        .ram_ack       (ram_ack),

        .prom_req      (prom_req),
        .prom_addr     (prom_addr),
        .prom_rdata    (prom_rdata),
        .prom_ack      (prom_ack),

        .gio_req       (gio_req),
        .gio_we        (gio_we),
        .gio_addr      (gio_addr),
        .gio_wdata     (gio_wdata),
        .gio_be        (gio_be),
        .gio_rdata     (gio_rdata),
        .gio_ack       (gio_ack),
        .gio_present   (gio_present),

        .rxda          (1'b1),          // idle mark - nothing plugged in
        .txda          (txda),
        .rxdb          (rxdb),
        .txdb          (txdb),
        .scc_int_n     (),
        .tx_valid      (tx_valid),
        .tx_data       (tx_data),
        .tx_chan       (tx_chan),

        .bus_req_o     (bus_req),
        .bus_we_o      (bus_we),
        .bus_addr_o    (bus_addr),
        .bus_wdata_o   (bus_wdata),
        .bus_be_o      (bus_be),
        .bus_rdata_o   (bus_rdata),
        .bus_ack_o     (bus_ack),
        .bus_unclaimed (bus_unclaimed),
        .cpu_error     (cpu_error)
    );

    sim_ram u_ram  (.clk(clk), .space(32'd0), .req(ram_req),  .we(ram_we),
                    .addr(ram_addr),  .wdata(ram_wdata), .be(ram_be),
                    .rdata(ram_rdata), .ack(ram_ack));

    sim_ram u_prom (.clk(clk), .space(32'd1), .req(prom_req), .we(1'b0),
                    .addr(prom_addr), .wdata(64'd0), .be(8'd0),
                    .rdata(prom_rdata), .ack(prom_ack));

    sim_ram u_gio  (.clk(clk), .space(32'd2), .req(gio_req),  .we(gio_we),
                    .addr(gio_addr),  .wdata(gio_wdata), .be(gio_be),
                    .rdata(gio_rdata), .ack(gio_ack));

endmodule
