//============================================================================
//  syn_top - a synthesis harness for measuring the fit. NOT the MiSTer core.
//
//  WHAT THIS IS FOR. `sgiindy.sv` is still the stock MiSTer template, and a
//  real core needs an SDRAM controller, hps_io, a PLL and video before it will
//  build - none of which exist yet. But the question "does the chipset and the
//  R4300i fit on a DE10-Nano, and at what clock" does not need any of them: it
//  needs the core logic synthesised against the right device.
//
//  So this wraps `sgi_indy` in the smallest thing Quartus will compile and
//  report on, and nothing here is meant to run. Do not confuse a clean fit
//  report with a working core.
//
//  WHY THE LFSR AND THE XOR. A module whose inputs are constants and whose
//  outputs go nowhere is optimised to nothing, and the report then says the
//  design is free. Every input is driven from a shift register that Quartus
//  cannot fold, and every output is reduced into one registered bit that
//  leaves through a pin, so the logic has to survive. It also keeps the pin
//  count to single figures, which matters because `sgi_indy` has sixty-odd
//  ports and the fitter will not place a design asking for more pins than the
//  package has.
//
//  MEM_MB IS TIED TO A CONSTANT HERE, on purpose. It is a runtime input in
//  simulation so `--ram-mb` can change the machine's size, but on hardware it
//  is fixed by which SDRAM is fitted, and tying it lets the bank arithmetic in
//  sgi_memmap fold away. Leaving it live would put adders and comparators in
//  the report that a real core would never build. 48 is the single-SDRAM
//  target: three 16 MB banks.
//============================================================================

module syn_top (
    input  logic       CLK_50,
    input  logic       RESET_N,
    input  logic       SEED,
    output logic       OUT_BIT,
    output logic       LOCKED
);

    // The core's target size. See the header.
    localparam logic [31:0] MEM_MB_FIXED = 32'd48;

    logic reset = 1'b1;
    always_ff @(posedge CLK_50) reset <= ~RESET_N;

    // ---- an unfoldable source of stimulus --------------------------------
    // A maximal-length LFSR. Quartus cannot prove anything about its value, so
    // everything downstream of it has to be built.
    logic [63:0] lfsr = 64'h1;
    always_ff @(posedge CLK_50)
        lfsr <= {lfsr[62:0], lfsr[63] ^ lfsr[62] ^ lfsr[60] ^ lfsr[59] ^ SEED};

    // ---- the core --------------------------------------------------------
    logic [31:0] scsi_sd_lba;
    logic  [6:0] scsi_sd_rd, scsi_sd_wr;
    logic [15:0] scsi_sd_buff_din;
    logic        ram_req, ram_we;
    logic [31:0] ram_addr;
    logic [63:0] ram_wdata;
    logic  [7:0] ram_be;
    logic        prom_req;
    logic [31:0] prom_addr;
    logic        gio_req, gio_we;
    logic [31:0] gio_addr;
    logic [63:0] gio_wdata;
    logic  [7:0] gio_be;

    // Newport's two frame buffer ports and its video output. The store itself
    // is not in this project - 10 MB of it is external memory on hardware -
    // so the read data comes from the LFSR like every other input here, and
    // the video pins are folded into OUT_BIT with the rest.
    logic        fbw_req, fbw_we;
    logic [31:0] fbw_addr;
    logic [63:0] fbw_wdata;
    logic  [7:0] fbw_be;
    logic        fbr_req;
    logic [31:0] fbr_addr;
    logic        vid_ce_pix, vid_hsync, vid_vsync, vid_de;
    logic  [7:0] vid_r, vid_g, vid_b;

    sgi_indy u_core (
        .clk              (CLK_50),
        .ce               (lfsr[0]),
        .reset            (reset),
        .sclk             (CLK_50),
        .boot_pc          ({lfsr[31:1], 1'b0}),
        .icache_en        (lfsr[1]),
        .dcache_en        (lfsr[2]),

        .mem_mb           (MEM_MB_FIXED),

        .scsi_img_mounted (lfsr[9:3]),
        .scsi_img_blocks  (lfsr[40:9]),
        .scsi_sd_lba      (scsi_sd_lba),
        .scsi_sd_rd       (scsi_sd_rd),
        .scsi_sd_wr       (scsi_sd_wr),
        .scsi_sd_ack      (lfsr[16:10]),
        .scsi_sd_buff_addr(lfsr[24:17]),
        .scsi_sd_buff_dout(lfsr[40:25]),
        .scsi_sd_buff_din (scsi_sd_buff_din),
        .scsi_sd_buff_wr  (lfsr[41]),

        .ps2_key          (lfsr[52:42]),
        .ps2_mouse        (lfsr[63:39]),

        .ram_req          (ram_req),
        .ram_we           (ram_we),
        .ram_addr         (ram_addr),
        .ram_wdata        (ram_wdata),
        .ram_be           (ram_be),
        .ram_rdata        (lfsr),
        .ram_ack          (lfsr[3]),

        .prom_req         (prom_req),
        .prom_addr        (prom_addr),
        .prom_rdata       (~lfsr),
        .prom_ack         (lfsr[4]),

        .gio_req          (gio_req),
        .gio_we           (gio_we),
        .gio_addr         (gio_addr),
        .gio_wdata        (gio_wdata),
        .gio_be           (gio_be),
        .gio_rdata        ({lfsr[31:0], lfsr[63:32]}),
        .gio_ack          (lfsr[5]),
        .gio_present      (lfsr[6]),
        .gfx_present      (lfsr[7]),

        .fbw_req          (fbw_req),
        .fbw_we           (fbw_we),
        .fbw_addr         (fbw_addr),
        .fbw_wdata        (fbw_wdata),
        .fbw_be           (fbw_be),
        .fbw_rdata        ({lfsr[47:16], lfsr[31:0]}),
        .fbw_ack          (lfsr[8]),

        .fbr_req          (fbr_req),
        .fbr_addr         (fbr_addr),
        .fbr_rdata        ({lfsr[15:0], lfsr[63:16]}),
        .fbr_ack          (lfsr[9]),

        .vid_ce_pix       (vid_ce_pix),
        .vid_hsync        (vid_hsync),
        .vid_vsync        (vid_vsync),
        .vid_de           (vid_de),
        .vid_r            (vid_r),
        .vid_g            (vid_g),
        .vid_b            (vid_b)
    );

    // ---- reduce every output to one pin ----------------------------------
    always_ff @(posedge CLK_50)
        OUT_BIT <= ^{scsi_sd_lba, scsi_sd_rd, scsi_sd_wr, scsi_sd_buff_din,
                     ram_req, ram_we, ram_addr, ram_wdata, ram_be,
                     prom_req, prom_addr,
                     gio_req, gio_we, gio_addr, gio_wdata, gio_be,
                     fbw_req, fbw_we, fbw_addr, fbw_wdata, fbw_be,
                     fbr_req, fbr_addr,
                     vid_ce_pix, vid_hsync, vid_vsync, vid_de,
                     vid_r, vid_g, vid_b};

    assign LOCKED = ~reset;

endmodule
