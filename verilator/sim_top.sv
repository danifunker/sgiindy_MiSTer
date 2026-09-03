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
    // Newport fitted. Clearing it puts the console back on the serial port,
    // which is what every regression in tests/ watches.
    input  wire        gfx_present,
    // Primary caches, so a failure can be bisected onto one of them from the
    // command line rather than by rebuilding. Both on for a normal run.
    input  wire        icache_en,
    input  wire        dcache_en,

    // Serial receive for the console channel. Idle mark is 1; the GUI harness
    // shifts typed characters out on it so the Command Monitor can be driven.
    input  wire        rxdb,

    // Host input devices, in MiSTer's decoded PS/2 form. The harness toggles
    // the top bit of each to signal an event, exactly as hps_io does.
    input  wire [10:0] ps2_key,
    input  wire [24:0] ps2_mouse,

    // SCSI block device, one slot per target. The harness models the disk in
    // C++ (sim_devices.cpp) the way hps_io does on hardware.
    input  wire  [6:0] scsi_img_mounted,
    input  wire [31:0] scsi_img_blocks,
    // FLAT, not unpacked arrays, and only at this boundary: Verilator 5.020
    // gives an unpacked-array TOP-LEVEL port a raw C array while the internal
    // signal is VlUnpacked, and the glue it then generates between the two
    // does not compile (and at -O3 the mismatch surfaces earlier, as the
    // no-location internal fault). Packed vectors dodge the whole path, and
    // the layout is chosen so the C++ stays natural: [32*k +: 32] of the LBA
    // is word k of the VlWide, so top->scsi_sd_lba[i] still reads target i.
    output wire [7*32-1:0] scsi_sd_lba,
    output wire  [6:0] scsi_sd_rd,
    output wire  [6:0] scsi_sd_wr,
    input  wire  [6:0] scsi_sd_ack,
    input  wire  [7:0] scsi_sd_buff_addr,
    input  wire [15:0] scsi_sd_buff_dout,
    output wire [7*16-1:0] scsi_sd_buff_din,
    input  wire [31:0] mem_mb,
    input  wire        scsi_sd_buff_wr,

    // Video out, from Newport. The GUI turns this into a texture; on
    // hardware it is what sgiindy.sv hands to the scaler.
    output wire        vid_ce_pix,
    output wire        vid_hsync,
    output wire        vid_vsync,
    output wire        vid_de,
    output wire  [7:0] vid_r,
    output wire  [7:0] vid_g,
    output wire  [7:0] vid_b,

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
    output wire        bus_mem,
    output wire        bus_hole,
    output wire  [5:0] cpu_error,
    output wire [31:0] dbg_pc,
    output wire        dbg_pc_valid,
    output wire  [3:0] dbg_mode,
    output wire        dbg_exc,
    output wire  [4:0] dbg_exc_code,
    output wire [31:0] dbg_exc_epc,
    output wire [31:0] dbg_cop0,
    output wire [31:0] dbg_exc_bad,
    output wire [31:0] dbg_rpc,
    output wire        dbg_retire,
    output wire  [4:0] irq_lines,
    output wire [39:0] int2_state
);

    wire        ram_req, ram_we, ram_ack, ram_last;
    wire [31:0] ram_addr;
    wire [63:0] ram_wdata, ram_rdata;
    wire  [7:0] ram_be;
    wire  [2:0] ram_burst;

    wire        prom_req, prom_ack;
    wire [31:0] prom_addr;
    wire [63:0] prom_rdata;

    wire        gio_req, gio_we, gio_ack;
    wire [31:0] gio_addr;
    wire [63:0] gio_wdata, gio_rdata;
    wire  [7:0] gio_be;

    // Newport's frame buffer. Two ports on one backing store, which is what a
    // VRAM is: the rasteriser writes through the random port while the
    // display reads through the serial one.
    wire        fbw_req, fbw_we, fbw_ack;
    wire [31:0] fbw_addr;
    wire [63:0] fbw_wdata, fbw_rdata;
    wire  [7:0] fbw_be;
    wire        fbr_req, fbr_ack;
    wire [31:0] fbr_addr;
    wire [63:0] fbr_rdata;
    wire        fba_req, fba_ack;
    wire [31:0] fba_addr;
    wire [63:0] fba_rdata;

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
    // The core's per-target arrays, packed onto the flat ports above.
    logic [31:0] scsi_sd_lba_arr      [7];
    logic [15:0] scsi_sd_buff_din_arr [7];
    for (genvar k = 0; k < 7; k++) begin : g_sd_flat
        assign scsi_sd_lba[32*k +: 32]      = scsi_sd_lba_arr[k];
        assign scsi_sd_buff_din[16*k +: 16] = scsi_sd_buff_din_arr[k];
    end

    sgi_indy #(.MEM_MB(64), .RTC_TICK_DIV(5000), .PIT_TICK_DIV(5)) u_core
    (
        .clk           (clk),
        .ce            (1'b1),
        .reset         (reset),
        .sclk          (sclk),
        .boot_pc       (boot_pc),
        .icache_en     (icache_en),
        .dcache_en     (dcache_en),

        .ps2_key       (ps2_key),
        .ps2_mouse     (ps2_mouse),

        .scsi_img_mounted (scsi_img_mounted),
        .scsi_img_blocks  (scsi_img_blocks),
        .scsi_sd_lba      (scsi_sd_lba_arr),
        .scsi_sd_rd       (scsi_sd_rd),
        .scsi_sd_wr       (scsi_sd_wr),
        .scsi_sd_ack      (scsi_sd_ack),
        .scsi_sd_buff_addr(scsi_sd_buff_addr),
        .scsi_sd_buff_dout(scsi_sd_buff_dout),
        .scsi_sd_buff_din (scsi_sd_buff_din_arr),
        .mem_mb           (mem_mb),
        .scsi_sd_buff_wr  (scsi_sd_buff_wr),

        .ram_req       (ram_req),
        .ram_we        (ram_we),
        .ram_addr      (ram_addr),
        .ram_wdata     (ram_wdata),
        .ram_be        (ram_be),
        .ram_burst     (ram_burst),
        .ram_rdata     (ram_rdata),
        .ram_ack       (ram_ack),
        .ram_last      (ram_last),

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
        .gfx_present   (gfx_present),

        // The harness has no OSD and no MAC file to upload, so the machine
        // gets sgiindy.sv's power-on default: sgi_ds1386.sv seeds it into the
        // RTC's NVRAM, which is where the PROM reads `eaddr` from, and the
        // IRIX installer dereferences the null it gets back without one.
        .mac_addr      (48'h08_00_69_12_34_56),
        .dbg_raw_index (1'b0),   // --fbindex does this in C++, on the dump

        .fbw_req       (fbw_req),
        .fbw_we        (fbw_we),
        .fbw_addr      (fbw_addr),
        .fbw_wdata     (fbw_wdata),
        .fbw_be        (fbw_be),
        .fbw_rdata     (fbw_rdata),
        .fbw_ack       (fbw_ack),
        .fbr_req       (fbr_req),
        .fbr_addr      (fbr_addr),
        .fbr_rdata     (fbr_rdata),
        .fbr_ack       (fbr_ack),
        .fba_req       (fba_req),
        .fba_addr      (fba_addr),
        .fba_rdata     (fba_rdata),
        .fba_ack       (fba_ack),
        .aux_mark      (),
        .aux_mark_line (),

        .vid_ce_pix    (vid_ce_pix),
        .vid_hsync     (vid_hsync),
        .vid_vsync     (vid_vsync),
        .vid_de        (vid_de),
        .vid_r         (vid_r),
        .vid_g         (vid_g),
        .vid_b         (vid_b),

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
        .bus_mem_o     (bus_mem),
        .bus_hole_o    (bus_hole),
        .cpu_error     (cpu_error),
        .dbg_pc        (dbg_pc),
        .dbg_pc_valid  (dbg_pc_valid),
        .dbg_mode      (dbg_mode),
        .dbg_exc       (dbg_exc),
        .dbg_exc_code  (dbg_exc_code),
        .dbg_exc_epc   (dbg_exc_epc),
        .dbg_cop0      (dbg_cop0),
        .dbg_exc_bad   (dbg_exc_bad),
        .dbg_rpc       (dbg_rpc),
        .dbg_retire    (dbg_retire),
        .dbg_scsi_bcn  (),
        .dbg_hpc3_dma  (),
        .dbg_int_bcn   (),
        .dbg_vdma_bcn  (),
        .irq_lines_o   (irq_lines),
        .int2_state_o  (int2_state)
    );

    sim_ram u_ram  (.clk(clk), .space(32'd0), .req(ram_req),  .we(ram_we),
                    .addr(ram_addr),  .wdata(ram_wdata), .be(ram_be),
                    .burst(ram_burst),
                    .rdata(ram_rdata), .ack(ram_ack), .last(ram_last));

    // Single-word ports, as on the board: ddr3_mux's PROM port does not
    // burst, so a line fill that lands in the PROM is fetched word by word
    // here too.
    sim_ram u_prom (.clk(clk), .space(32'd1), .req(prom_req), .we(1'b0),
                    .addr(prom_addr), .wdata(64'd0), .be(8'd0), .burst(3'd1),
                    .rdata(prom_rdata), .ack(prom_ack), .last());

    sim_ram u_gio  (.clk(clk), .space(32'd2), .req(gio_req),  .we(gio_we),
                    .addr(gio_addr),  .wdata(gio_wdata), .be(gio_be),
                    .burst(3'd1),
                    .rdata(gio_rdata), .ack(gio_ack), .last());

    // Both frame buffer ports address the same C++ backing store, so the
    // harness can dump the screen as one image and the two ports behave the
    // way a real VRAM's two ports do.
    sim_ram u_fbw  (.clk(clk), .space(32'd3), .req(fbw_req), .we(fbw_we),
                    .addr(fbw_addr), .wdata(fbw_wdata), .be(fbw_be),
                    .burst(3'd1),
                    .rdata(fbw_rdata), .ack(fbw_ack), .last());

    sim_ram u_fbr  (.clk(clk), .space(32'd3), .req(fbr_req), .we(1'b0),
                    .addr(fbr_addr), .wdata(64'd0), .be(8'd0), .burst(3'd1),
                    .rdata(fbr_rdata), .ack(fbr_ack), .last());
    // The display's second serial port, for the auxiliary plane region. On
    // MiSTer a line cache with a per-line flag table sits here; against this
    // one-cycle memory the plain read is the same picture.
    sim_ram u_fba  (.clk(clk), .space(32'd3), .req(fba_req), .we(1'b0),
                    .addr(fba_addr), .wdata(64'd0), .be(8'd0), .burst(3'd1),
                    .rdata(fba_rdata), .ack(fba_ack), .last());

endmodule
