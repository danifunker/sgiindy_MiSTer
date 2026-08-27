//============================================================================
//  sim_top - headless top level for CPU validation.
//
//  Instantiates the core exactly as `sgiindy.sv` will on hardware, but hangs
//  C++-backed models off the memory, PROM and GIO64 ports. There is no video,
//  no audio and no HPS, because nothing through milestone M1 needs any of it -
//  the cpu-tests suite wants RAM, an SCC and (optionally) a device in GIO
//  slot 0, and that is all this provides.
//
//  The GUI harness (`sim.v`, module `emu`) comes later and wraps the same
//  core; keeping the headless top separate means CPU regressions can run in
//  CI with no SDL, no window and no ImGui build.
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

    sgi_indy #(.MEM_MB(64)) u_core
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
        .rxdb          (1'b1),
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
