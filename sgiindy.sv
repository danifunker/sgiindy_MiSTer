//============================================================================
//  sgiindy - the MiSTer top level for the SGI Indy (IP24) core.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version. See NOTICE.md - the licence is GPL-3.0 because the
//  vendored R4300i is.
//
//  WHAT THIS IS. Until now this file was the stock MiSTer template with a
//  `mycore` noise generator in it, and every claim this project makes about
//  the machine comes from Verilator rather than from hardware. This is the
//  wiring that makes a fit possible: the chipset, its memory, its console,
//  its disks and its screen, on a DE10-Nano.
//
//  IT HAS BEEN THROUGH QUARTUS AND IT MEETS TIMING. The whole flow completes
//  on a 5CSEBA6U23I7 - 73% of the ALMs, positive slack on every clock - and
//  `scripts/build.sh` reproduces it. What that does NOT prove is that the
//  machine runs: a fit checks wiring, not behaviour, and everything this
//  project claims about the behaviour still comes from Verilator. Treat a
//  hardware run as a bring-up exercise and read docs/18-mister-integration.md
//  first; it lists what is known to be missing rather than leaving it to be
//  discovered. `scripts/deploy.sh` puts a build on a board.
//
//  THE FOUR THINGS WORTH KNOWING BEFORE READING THE CODE:
//
//  1. EVERYTHING IS IN DDR3. 64 MB of Indy memory and 16 MB of Newport frame
//     buffer against 688 KB of M10K, most of which the CPU's caches already
//     have. ddr3_mux.sv carves the 256 MB window MiSTer gives a core.
//  2. THE PROM COMES OFF THE SD CARD. It is SGI firmware; it is not in the
//     bitstream. The framework loads `boot.rom` out of the core's directory
//     by itself at startup; the OSD's "Load PROM" does the same job by hand.
//     Either way ioctl writes it into DDR3 and the core is held in reset
//     until the download finishes.
//  3. THE VIDEO IS CORRECT AND THE REFRESH IS LOW. The raster is exactly the
//     one the PROM's timing table describes - 1318 x 1065, asserted by
//     tests/run-newport.sh - but VC2 derives its pixel clock by dividing the
//     core clock, so a table written for 107.5 MHz comes out at 50 and the
//     frame rate is about 28 Hz. That is a refresh rate, not a defect; 60 Hz
//     needs a second clock domain and not a faster core. See the doc.
//  4. THE SERIAL CONSOLE IS ON THE USER I/O UART. With no graphics board
//     fitted the PROM talks to a terminal, and that is still the most useful
//     way to drive this machine.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Ports this core does not use /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// No SDRAM module is required: everything lives in the HPS's DDR3.
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// No audio path. HAL2 answers its revision register and nothing else - this
// core reports an audio processor rather than having one. docs/FEATURES_EVALUATE.md
assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

// 1280x1024 is 5:4. The Indy's own monitor was 5:4 and the PROM's boot screen
// is drawn for it, so that is what "Original" means here.
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd5 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd4 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"SGIIndy;;",
	"-;",
	"FS0,BIN,Load PROM;",
	"-;",
	// `SC` RATHER THAN `S`, AND THE C IS THE WHOLE POINT: it makes the mount
	// SURVIVE A CORE RELOAD. The framework parses this string on the ARM side;
	// `S` mounts an image and forgets it, `SC` also writes the path to
	// /media/fat/config/SGIIndy.s<n> when it is selected (Main_MiSTer
	// menu.cpp:2782) and mounts it again from there at every core start
	// (user_io.cpp:977-1006), with no OSD interaction at all - the same shape
	// as boot.rom arriving at index 0.
	//
	// That matters here more than on most cores because this machine takes
	// thirty seconds to draw its boot screen and is relaunched constantly
	// during bring-up, and because the screenshot API does not capture the OSD,
	// so blind menu navigation cannot be verified.
	//
	// The saved path is written when an image is chosen in the OSD.
	// scripts/mount.sh writes it directly instead, because the screenshot API
	// does not capture the OSD and a blind menu walk cannot be verified. The
	// format is not a text file: FileSaveConfig writes the whole of menu.cpp's
	// `char selPath[1024]`, so the path goes in NUL-terminated and zero-padded.
	"SC1,IMGISOCHD,SCSI ID1;",
	"SC2,IMGISOCHD,SCSI ID2;",
	"SC3,IMGISOCHD,SCSI ID6 CD;",
	"-;",
	"O[10],Graphics board,Fitted,None;",
	"O[11],Primary caches,On,Off;",
	"O[13:12],Memory,48MB,32MB,64MB;",
	// A BRING-UP INSTRUMENT, NOT A FEATURE. The first hardware run drew a
	// perfect 1318x1024 raster and a black screen, and black has two causes
	// that look the same from outside: the frame buffer read returning
	// nothing, or the palette answering black for every index. This shows the
	// frame buffer's own colour index as grey with CMAP taken out of the path,
	// and serves index 0x80 for a line-cache miss instead of black - so the
	// three cases finally look different from each other.
	"O[14],Video debug,Off,Raw index;",
	// THE OTHER BRING-UP INSTRUMENT. With the graphics board unfitted the
	// machine demonstrably runs - main memory carries szmem's walking-bit
	// patterns - and the ARM's /dev/ttyS1 has counted rx:0 bytes, ever. So the
	// console is absent, and two very different things would look identical
	// from outside: the SCC not transmitting, or nothing between UART_TXD and
	// the HPS UART working at all. This puts a transmitter of the core's own
	// on the pin, in one clock domain or the other.
	"O[16:15],UART debug,Off,0x55 from clk_sys,0x55 from sclk;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;",
	"V,v",`BUILD_DATE
};

///////////////////////////   HPS   //////////////////////////////

// Four virtual drives: 0 is unused by the block interface (the PROM arrives
// through ioctl, not through sd_*), and 1..3 are SCSI. They are deliberately
// NOT one slot per SCSI ID: sgi_scsi.sv's TARGET_EN builds IDs 1, 2 and 6
// only, so three slots is the whole machine and seven would be four menu
// entries that can never be filled.
localparam int VDNUM = 4;

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;

wire  [3:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;

wire [31:0] sd_lba[VDNUM];
wire  [3:0] sd_rd, sd_wr, sd_ack;
wire [12:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din[VDNUM];
wire        sd_buff_wr;

// The chipset presents a PER-TARGET lba and read-back word, and each menu
// slot takes its own target's pair - hps_io reads sd_lba[slot] for the slot
// it is servicing, so this is what keeps a disk request and a CD request that
// overlap from serving each other's addresses (docs/29's last-match-wins
// mux, retired 2026-09-02).
wire [31:0] scsi_sd_lba      [7];
wire [15:0] scsi_sd_buff_din [7];
wire  [6:0] scsi_sd_rd, scsi_sd_wr, scsi_sd_ack, scsi_img_mounted;

assign sd_lba[0] = 0;
assign sd_lba[1] = scsi_sd_lba[1];
assign sd_lba[2] = scsi_sd_lba[2];
assign sd_lba[3] = scsi_sd_lba[6];
assign sd_buff_din[0] = 0;
assign sd_buff_din[1] = scsi_sd_buff_din[1];
assign sd_buff_din[2] = scsi_sd_buff_din[2];
assign sd_buff_din[3] = scsi_sd_buff_din[6];

// Menu slot -> SCSI ID. Slot 1 is ID 1, slot 2 is ID 2, slot 3 is ID 6, which
// is where SGI put the internal CD-ROM and where CDROM_IDS elaborates one.
assign sd_rd = {scsi_sd_rd[6], scsi_sd_rd[2], scsi_sd_rd[1], 1'b0};
assign sd_wr = {scsi_sd_wr[6], scsi_sd_wr[2], scsi_sd_wr[1], 1'b0};
assign scsi_sd_ack       = {sd_ack[3], 3'b000, sd_ack[2], sd_ack[1], 1'b0};
assign scsi_img_mounted  = {img_mounted[3], 3'b000, img_mounted[2], img_mounted[1], 1'b0};

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(VDNUM)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(0),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)
);

///////////////////////////   CLOCKS   ///////////////////////////

wire clk_sys, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

localparam int CLK_SYS_HZ = 50_000_000;

// THE SCC'S SERIAL CLOCK IS 3.6864 MHz ON A REAL MACHINE and it is the only
// thing that sets the console's bit rate, so it cannot be approximated by a
// convenient integer divide: 50 MHz over 3.6864 MHz is 13.56. This is a
// numerically controlled oscillator instead - add a constant every clock and
// toggle on the carry - which lands within a fraction of a percent, and a
// UART does not care about a fraction of a percent.
//
//   INC = 2 * 3.6864e6 / 50e6 * 2^32   (twice, because it toggles)
localparam [31:0] SCLK_INC = 32'd633_187_924;
reg [31:0] sclk_acc;
reg        sclk;
always @(posedge clk_sys) begin
	reg carry;
	{carry, sclk_acc} <= {1'b0, sclk_acc} + {1'b0, SCLK_INC};
	if (carry) sclk <= ~sclk;
end

/////////////////////////   MEMORY SIZE   ///////////////////////

// EVERY ONE OF THESE IS A SIZE THE MC CAN ACTUALLY EXPRESS, which is not the
// same as any number of megabytes. A bank is four SIMMs and the parts that do
// not need the BNK bit give banks of 64, 16 and 4 MB, so an installable size
// is a sum of those across at most four banks - 32 is 16+16, 48 is 16+16+16,
// 64 is one bank. rtl/sgi/sgi_memmap.sv has the derivation, and asking for 32
// as one 32 MB bank is what made `--ram-mb 32` fail once: the PROM probed a
// bank that could not answer and its own diagnostic said so. All three boot in
// simulation and the PROM reports each one back.
//
// 48 MB IS FIRST, SO IT IS THE DEFAULT. It is the size sgi_memmap.sv calls
// "the MiSTer single-SDRAM fit" - three 16 MB banks - and it is a real Indy
// configuration rather than a compromise. 64 is the ceiling: this is a single
// RAM configuration. The MC can express 96 and 128 across more banks and
// sgi_memmap.sv will build them, but they are not offered, because a size the
// board cannot be is not a choice - it is a way to get "No usable memory
// found" out of a machine that looked fine in the menu.
wire [1:0] mem_sel = status[13:12];
wire [31:0] mem_mb = (mem_sel == 2'd1) ? 32'd32
                   : (mem_sel == 2'd2) ? 32'd64
                   :                     32'd48;

//////////////////////////   RESET   /////////////////////////////

// The core stays in reset while the PROM is being written into DDR3, and for
// a while afterwards. The tail matters: r4300_wrap.vhd's SETTLE_CLOCKS is
// 1024 because each cache answers reset by walking 512 tag entries one per
// clock and neither of them looks at the CPU's own reset - a first cached
// access landing inside that walk is not latched, and the pipeline wedges
// 4096 clocks later. That is written up in docs/08-resume-prompt.md; this
// counter is the top level's half of the same rule.
// INDEX 0 IS BOTH WAYS IN. The CONF_STR entry above is `FS0`, so a hand-picked
// file arrives as index 0 - and MiSTer's framework loads `boot.rom` from the
// core's own directory at startup with the same index 0, with no CONF_STR
// entry required and the `.rom` name hardcoded. One decode covers both, which
// is why there is no second download path for the automatic one.
//
// THE FRAMEWORK RELEASES RESET BEFORE IT SENDS boot.rom. It clears status[0]
// and only then starts the transfer, so between those two moments the CPU is
// fetching from a PROM region that holds whatever DDR3 came up with. That is
// survivable and not ignorable: the line below re-asserts reset the instant
// the download begins, and the counter holds it for 65,535 clocks after the
// end. Nothing the machine did in that window outlives the reset - the PROM
// region is read-only to the core, so garbage cannot have damaged the image
// that is about to be executed.
// THE WHOLE LOW BYTE, NOT JUST THE SLOT NUMBER. `ioctl_index` carries the slot
// in [5:0] and an EXTENSION INDEX in [7:6], and the framework uses that upper
// field for its own automatic uploads: at every core start it sends
// games/<core>/boot0.rom .. boot3.rom at index `i << 6` (Main_MiSTer
// user_io.cpp:1629), with no CONF_STR entry and no OSD. Matching on [5:0]
// alone therefore accepts boot1.rom, boot2.rom and boot3.rom AS THE BOOT PROM
// and writes them over it. Nothing does that today because those files do not
// exist, which is exactly what makes it worth fixing before one of them does -
// the symptom would be a machine that executes garbage from its first fetch,
// three layers from a file somebody dropped in the games directory.
wire prom_download = ioctl_download && (ioctl_index[7:0] == 8'd0);

// A CHANGE OF MEMORY SIZE RESETS THE MACHINE, because the PROM sizes memory
// exactly once - `szmem` probes each bank at boot and writes the result into
// the MC's config registers - and nothing re-reads it. Changing it underneath
// a running machine would leave the guest addressing memory that had moved.
reg [1:0] mem_sel_d;
reg [15:0] rst_cnt = 16'hFFFF;
always @(posedge clk_sys) begin
	mem_sel_d <= mem_sel;
	if (RESET | status[0] | buttons[1] | prom_download | ~pll_locked
	    | (mem_sel != mem_sel_d))
		rst_cnt <= 16'hFFFF;
	else if (rst_cnt != 0)
		rst_cnt <= rst_cnt - 1'd1;
end
wire reset = (rst_cnt != 0);

/////////////////////   PROM DOWNLOAD   //////////////////////////

// ioctl hands over two bytes at a time; DDR3 takes eight. Four halfwords are
// assembled and written as one doubleword.
//
// THE BYTE ORDER IS THE ONE THING HERE THAT CANNOT BE CHECKED WITHOUT
// HARDWARE. This core's memory convention is that `data[63-8*i -: 8]` is the
// byte at `addr + i`, so the FIRST byte of the file belongs in the MOST
// significant lane - the PROM is a big-endian MIPS image and the CPU fetches
// it as one. hps_io's WIDE mode presents the earlier of the two bytes in the
// LOW half of ioctl_dout, so each halfword is swapped end for end on the way
// in. If the machine comes up executing garbage from the very first fetch,
// this swap is the first thing to try inverting.
reg [63:0] dl_word;
reg [31:0] dl_addr;
reg        dl_req;
wire       dl_ack;

always @(posedge clk_sys) begin
	if (dl_req && dl_ack) dl_req <= 0;

	if (ioctl_wr && prom_download) begin
		case (ioctl_addr[2:1])
			2'd0: dl_word[63:48] <= {ioctl_dout[7:0], ioctl_dout[15:8]};
			2'd1: dl_word[47:32] <= {ioctl_dout[7:0], ioctl_dout[15:8]};
			2'd2: dl_word[31:16] <= {ioctl_dout[7:0], ioctl_dout[15:8]};
			2'd3: begin
				dl_word[15:0] <= {ioctl_dout[7:0], ioctl_dout[15:8]};
				dl_addr <= {5'b0, ioctl_addr[26:3], 3'b000};
				dl_req  <= 1;
			end
		endcase
	end

	if (reset && !prom_download) dl_req <= 0;
end

// THE MACHINE'S ETHERNET ADDRESS, AT RUN TIME.
//
// It cannot be compiled in: two boards on one network must not share it. The
// framework uploads games/<core>/boot0.rom .. boot3.rom at ioctl index `i << 6`
// at every core start, with no CONF_STR entry and no OSD (Main_MiSTer
// user_io.cpp:1629) - the same silent channel boot.rom arrives on at index 0.
// scripts/deploy.sh writes boot1.rom on the device, six bytes, with the
// MiSTer's own last octet in it, so index 0x40 is this machine's MAC.
//
// THE ORDER IS WHAT MAKES THIS WORK. The framework sends boot1.rom BEFORE
// boot.rom, and boot.rom's download re-asserts reset and holds it for 65,535
// clocks - so the address is latched well before the guest can read it, and
// sgi_ds1386.sv seeds it into the NVRAM three clocks after reset releases.
//
// Not reset: the PROM download's own reset would otherwise wipe it. The
// declared value is the fallback for a card with no boot1.rom on it, and it is
// a valid address rather than zeros, because a machine with no eaddr panics the
// IRIX installer - see rtl/sgi/eeprom_93c56.sv.
//
// hps_io's WIDE mode puts the earlier of each pair of bytes in the LOW half of
// ioctl_dout, the same swap the PROM download does above.
wire mac_download = ioctl_download && (ioctl_index[7:0] == 8'h40);
reg [47:0] mac_addr = 48'h08_00_69_12_34_56;

always @(posedge clk_sys) begin
	if (ioctl_wr && mac_download) begin
		case (ioctl_addr[2:1])
			2'd0: mac_addr[47:32] <= {ioctl_dout[7:0], ioctl_dout[15:8]};
			2'd1: mac_addr[31:16] <= {ioctl_dout[7:0], ioctl_dout[15:8]};
			2'd2: mac_addr[15:0]  <= {ioctl_dout[7:0], ioctl_dout[15:8]};
		endcase
	end
end

////////////////////////   THE MACHINE   /////////////////////////

wire        ram_req, ram_we, ram_ack;
wire [31:0] ram_addr;
wire [63:0] ram_wdata, ram_rdata;
wire  [7:0] ram_be;

wire        prom_req, prom_ack;
wire [31:0] prom_addr;
wire [63:0] prom_rdata;

wire        fbw_req, fbw_we, fbw_ack;
wire [31:0] fbw_addr;
wire [63:0] fbw_wdata, fbw_rdata;
wire  [7:0] fbw_be;

// Newport's display port, and the scanline cache that stands between it and
// DDR3. Newport does not wait for this read - there is no handshake on the
// display side of a VRAM - so something has to make the answer always be
// there. See rtl/mister/fb_linecache.sv.
wire        fbr_req, fbr_ack;
wire [31:0] fbr_addr;
wire [63:0] fbr_rdata;
// The second serial port: the auxiliary planes, and the rasteriser's mark
// that keeps its line cache's flag table honest.
wire        fba_req, fba_ack;
wire [31:0] fba_addr;
wire [63:0] fba_rdata;
wire        aux_mark;
wire [10:0] aux_mark_line;

// One burst port on the mux, two line caches behind fb_fetch_arb.
wire        lc_req, lc_taken, lc_valid;
wire [31:0] lc_addr;
wire  [7:0] lc_burst;
wire [63:0] lc_dout;
wire        lc_miss, la_miss;
wire        lr_req, lr_taken, lr_valid, la_req, la_taken, la_valid;
wire [31:0] lr_addr, la_addr;
wire  [7:0] lr_burst, la_burst;
wire [63:0] lr_dout, la_dout;
wire [31:0] la_skips;

wire        vid_ce_pix, vid_hsync, vid_vsync, vid_de;
wire  [7:0] vid_r, vid_g, vid_b;

wire        txda, txdb;

// SCSI debug beacon words out of the core (docs/28), to the writer below.
wire [63:0] scsi_bcn [7];
wire [63:0] hpc3_dma_bcn;   // HPC3 SCSI0 DMA channel state (docs/29)
wire [63:0] int_bcn [2];    // interrupt-delivery diagnostics (docs/29)
wire [63:0] vdma_bcn [4];   // VDMA / Newport pixel-DMA diagnostics (docs/33)

sgi_indy u_core
(
	.clk              (clk_sys),
	.ce               (1'b1),
	.reset            (reset),
	.sclk             (sclk),

	// The PROM's reset vector. KSEG1, uncached, as an R4000 starts.
	.boot_pc          (32'hBFC00000),
	.icache_en        (~status[11]),
	.dcache_en        (~status[11]),

	.mem_mb           (mem_mb),
	.dbg_raw_index    (status[14]),

	.ram_req          (ram_req),
	.ram_we           (ram_we),
	.ram_addr         (ram_addr),
	.ram_wdata        (ram_wdata),
	.ram_be           (ram_be),
	.ram_rdata        (ram_rdata),
	.ram_ack          (ram_ack),

	.prom_req         (prom_req),
	.prom_addr        (prom_addr),
	.prom_rdata       (prom_rdata),
	.prom_ack         (prom_ack),

	// No GIO64 expansion card. The test device is a simulation fixture.
	.gio_req          (),
	.gio_we           (),
	.gio_addr         (),
	.gio_wdata        (),
	.gio_be           (),
	.gio_rdata        (64'h0),
	.gio_ack          (1'b0),
	.gio_present      (1'b0),

	// FITTING THE GRAPHICS BOARD MOVES THE CONSOLE OFF THE SERIAL PORT. ARCS
	// installs a DisplayController with ConsoleOut|Output and the PROM stops
	// printing to the SCC entirely, so "Graphics board: None" is not a
	// degraded mode - it is how you get a terminal.
	.gfx_present      (~status[10]),

	.fbw_req          (fbw_req),
	.fbw_we           (fbw_we),
	.fbw_addr         (fbw_addr),
	.fbw_wdata        (fbw_wdata),
	.fbw_be           (fbw_be),
	.fbw_rdata        (fbw_rdata),
	.fbw_ack          (fbw_ack),

	.fbr_req          (fbr_req),
	.fbr_addr         (fbr_addr),
	.fbr_rdata        (fbr_rdata),
	.fbr_ack          (fbr_ack),
	.fba_req          (fba_req),
	.fba_addr         (fba_addr),
	.fba_rdata        (fba_rdata),
	.fba_ack          (fba_ack),
	.aux_mark         (aux_mark),
	.aux_mark_line    (aux_mark_line),

	.vid_ce_pix       (vid_ce_pix),
	.vid_hsync        (vid_hsync),
	.vid_vsync        (vid_vsync),
	.vid_de           (vid_de),
	.vid_r            (vid_r),
	.vid_g            (vid_g),
	.vid_b            (vid_b),

	// SCC channel B is tty1, the SGI console, and it goes to the board's UART.
	// Channel A has nothing plugged into it, and an idle line is a mark.
	.rxda             (1'b1),
	.txda             (txda),
	.rxdb             (UART_RXD),
	.txdb             (txdb),
	.scc_int_n        (),

	.ps2_key          (ps2_key),
	.ps2_mouse        (ps2_mouse),

	.mac_addr         (mac_addr),

	.scsi_img_mounted (scsi_img_mounted),
	.scsi_img_blocks  (img_size[40:9]),
	.scsi_sd_lba      (scsi_sd_lba),
	.scsi_sd_rd       (scsi_sd_rd),
	.scsi_sd_wr       (scsi_sd_wr),
	.scsi_sd_ack      (scsi_sd_ack),
	.scsi_sd_buff_addr(sd_buff_addr[7:0]),
	.scsi_sd_buff_dout(sd_buff_dout),
	.scsi_sd_buff_din (scsi_sd_buff_din),
	.scsi_sd_buff_wr  (sd_buff_wr),

	.dbg_scsi_bcn     (scsi_bcn),
	.dbg_hpc3_dma     (hpc3_dma_bcn),
	.dbg_int_bcn      (int_bcn),
	.dbg_vdma_bcn     (vdma_bcn),

	// Debug taps: the console byte tap and the bus mirror. They exist for the
	// simulation harness and nothing on hardware reads them. (Do not start a
	// line comment with the word V-e-r-i-l-a-t-o-r - it is taken as a pragma
	// and the next word has to be one it knows.)
	.tx_valid         (),
	.tx_data          (),
	.tx_chan          (),
	.bus_req_o        (),
	.bus_we_o         (),
	.bus_addr_o       (),
	.bus_wdata_o      (),
	.bus_be_o         (),
	.bus_rdata_o      (),
	.bus_ack_o        (),
	.bus_unclaimed    (),
	.cpu_error        (),
	.irq_lines_o      (),
	.int2_state_o     ()
);

// ---- the UART bring-up probe ------------------------------------------
// Two 8N1 transmitters sending 0x55 forever at 9600 baud, one in each clock
// domain, because which of the two arrives is the whole question. 0x55 is one
// transition per bit time, so a rate that is merely wrong shows up as framing
// errors and a climbing rx count rather than as more silence - and silence is
// the thing that has to be told apart from silence here.
//
//   status[16:15] = 0   the SCC, as normal
//                 = 1   the pattern, timed from clk_sys
//                 = 2   the pattern, timed from sclk
//
// If 1 arrives and 2 does not, `sclk` is dead and the SCC was never at fault.
// If neither arrives, the fault is between this pin and /dev/ttyS1 and nothing
// inside the machine is worth looking at yet.
localparam int DBG_DIV_SYS = CLK_SYS_HZ / 9600;      // 50 MHz  -> 5208
localparam int DBG_DIV_SER = 3686400 / 9600;         // 3.6864 MHz -> 384

reg [12:0] dbg_div_a; reg [3:0] dbg_bit_a;
always @(posedge clk_sys) begin
	if (dbg_div_a >= 13'(DBG_DIV_SYS - 1)) begin
		dbg_div_a <= 13'd0;
		dbg_bit_a <= (dbg_bit_a == 4'd9) ? 4'd0 : dbg_bit_a + 4'd1;
	end else dbg_div_a <= dbg_div_a + 13'd1;
end

reg [8:0] dbg_div_b; reg [3:0] dbg_bit_b;
always @(posedge sclk) begin
	if (dbg_div_b >= 9'(DBG_DIV_SER - 1)) begin
		dbg_div_b <= 9'd0;
		dbg_bit_b <= (dbg_bit_b == 4'd9) ? 4'd0 : dbg_bit_b + 4'd1;
	end else dbg_div_b <= dbg_div_b + 9'd1;
end

// Bit 0 is the start bit, 9 is the stop bit, and 1..8 carry 0x55 least
// significant bit first - which is exactly the low bit of the counter.
function automatic logic dbg_serial(input logic [3:0] b);
	if (b == 4'd0)      dbg_serial = 1'b0;
	else if (b == 4'd9) dbg_serial = 1'b1;
	else                dbg_serial = b[0];
endfunction

assign UART_TXD = (status[16:15] == 2'd1) ? dbg_serial(dbg_bit_a)
                : (status[16:15] == 2'd2) ? dbg_serial(dbg_bit_b)
                :                           txdb;

////////////////////////////   MEMORY   //////////////////////////

assign DDRAM_CLK = clk_sys;

// The drawing planes: every line, every frame.
fb_linecache #(.TRACK_ZERO(1'b0)) u_linecache
(
	.clk       (clk_sys),
	.reset     (reset),

	.px_req    (fbr_req),
	.px_addr   (fbr_addr),
	.px_rdata  (fbr_rdata),
	.px_ack    (fbr_ack),
	.vs        (vid_vsync),
	.mark      (1'b0),
	.mark_line (11'd0),

	.fbr_req       (lr_req),
	.fbr_addr      (lr_addr),
	.fbr_burst     (lr_burst),
	.fbr_taken     (lr_taken),
	.fbr_dout      (lr_dout),
	.fbr_dout_valid(lr_valid),

	.miss      (lc_miss),
	.dbg_skips (),
	.dbg_miss_mark (status[14])
);

// The auxiliary planes: only the lines the rasteriser has put something
// visible on, which on a desktop is almost none of them (fb_linecache.sv,
// TRACK_ZERO). The rest are published as zeros without a fetch.
fb_linecache #(.TRACK_ZERO(1'b1)) u_auxcache
(
	.clk       (clk_sys),
	.reset     (reset),

	.px_req    (fba_req),
	.px_addr   (fba_addr),
	.px_rdata  (fba_rdata),
	.px_ack    (fba_ack),
	.vs        (vid_vsync),
	.mark      (aux_mark),
	.mark_line (aux_mark_line),

	.fbr_req       (la_req),
	.fbr_addr      (la_addr),
	.fbr_burst     (la_burst),
	.fbr_taken     (la_taken),
	.fbr_dout      (la_dout),
	.fbr_dout_valid(la_valid),

	.miss      (la_miss),
	.dbg_skips (la_skips),
	.dbg_miss_mark (1'b0)
);

fb_fetch_arb u_fetch_arb
(
	.clk       (clk_sys),
	.reset     (reset),

	.a_req        (lr_req),
	.a_addr       (lr_addr),
	.a_burst      (lr_burst),
	.a_taken      (lr_taken),
	.a_dout       (lr_dout),
	.a_dout_valid (lr_valid),

	.b_req        (la_req),
	.b_addr       (la_addr),
	.b_burst      (la_burst),
	.b_taken      (la_taken),
	.b_dout       (la_dout),
	.b_dout_valid (la_valid),

	.fbr_req       (lc_req),
	.fbr_addr      (lc_addr),
	.fbr_burst     (lc_burst),
	.fbr_taken     (lc_taken),
	.fbr_dout      (lc_dout),
	.fbr_dout_valid(lc_valid)
);

ddr3_mux u_mem
(
	.clk       (clk_sys),
	.reset     (~pll_locked),

	.fbr_req       (lc_req),
	.fbr_addr      (lc_addr),
	.fbr_burst     (lc_burst),
	.fbr_taken     (lc_taken),
	.fbr_dout      (lc_dout),
	.fbr_dout_valid(lc_valid),

	.dl_req    (dl_req),
	.dl_addr   (dl_addr),
	.dl_wdata  (dl_word),
	.dl_be     (8'hFF),
	.dl_ack    (dl_ack),

	.ram_req   (ram_req),
	.ram_we    (ram_we),
	.ram_addr  (ram_addr),
	.ram_wdata (ram_wdata),
	.ram_be    (ram_be),
	.ram_rdata (ram_rdata),
	.ram_ack   (ram_ack),

	.prom_req  (prom_req),
	.prom_addr (prom_addr),
	.prom_rdata(prom_rdata),
	.prom_ack  (prom_ack),

	.fbw_req   (fbw_req),
	.fbw_we    (fbw_we),
	.fbw_addr  (fbw_addr),
	.fbw_wdata (fbw_wdata),
	.fbw_be    (fbw_be),
	.fbw_rdata (fbw_rdata),
	.fbw_ack   (fbw_ack),

	.bcn_req   (bcn_req),
	.bcn_addr  (bcn_addr),
	.bcn_wdata (bcn_wdata),

	.DDRAM_BUSY      (DDRAM_BUSY),
	.DDRAM_BURSTCNT  (DDRAM_BURSTCNT),
	.DDRAM_ADDR      (DDRAM_ADDR),
	.DDRAM_DOUT      (DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD        (DDRAM_RD),
	.DDRAM_DIN       (DDRAM_DIN),
	.DDRAM_BE        (DDRAM_BE),
	.DDRAM_WE        (DDRAM_WE)
);

// ---- SCSI debug beacon writer (docs/28, docs/29) ---------------------------
// Streams nine 64-bit SCSI status words into the otherwise-unused DDR3
// window at byte offset 0x05800000 (ARM physical 0x35800000), one word every
// 64 cycles, so tools/misterdeploy/ddr3_peek.py can watch the SCSI subsystem
// live while the guest is wedged. Lowest-priority master in ddr3_mux, so
// observation cannot perturb the guest. Word 0 is {BEC0, version, 00,
// heartbeat}; words 1..7 are sgi_scsi's dbg_bcn[0..6] (bus/HPS, wd33c93,
// target 1 A/B, target 6 A/B, target 1 sticky); word 8 is the HPC3 SCSI0 DMA
// channel state; words 9-10 are the interrupt-delivery diagnostics (docs/29).
// Runs on pll_locked alone - a guest reset must not stop the reporting.
// Build 12 (ver=6) added words 11-13: the MC VDMA engine, its descriptor
// addresses, and REX3's beat counters. Build 14 (ver=7) adds word 14: the
// display-interpretation word - DID and mode entry in use (docs/33). ver=8
// adds word 15: the two display line caches - drawing-plane misses, auxiliary
// misses, and lines the auxiliary cache published as zeros without a fetch
// (docs/36) - which is how the PIX_DIV=1 bandwidth budget is checked live.
localparam int BCN_WORDS = 16;

reg [15:0] lc_miss_cnt, la_miss_cnt;
always @(posedge clk_sys) begin
	if (~pll_locked) begin
		lc_miss_cnt <= 16'd0;
		la_miss_cnt <= 16'd0;
	end else begin
		if (lc_miss) lc_miss_cnt <= lc_miss_cnt + 16'd1;
		if (la_miss) la_miss_cnt <= la_miss_cnt + 16'd1;
	end
end
reg  [5:0]  bcn_div;
reg  [3:0]  bcn_idx;
reg  [31:0] bcn_beat;
reg         bcn_req;
reg  [31:0] bcn_addr;
reg  [63:0] bcn_wdata;

wire [63:0] bcn_src [BCN_WORDS];
assign bcn_src[0] = { 16'hBEC0, 8'h08, 8'h00, bcn_beat };
assign bcn_src[1] = scsi_bcn[0];
assign bcn_src[2] = scsi_bcn[1];
assign bcn_src[3] = scsi_bcn[2];
assign bcn_src[4] = scsi_bcn[3];
assign bcn_src[5] = scsi_bcn[4];
assign bcn_src[6] = scsi_bcn[5];
assign bcn_src[7] = scsi_bcn[6];
assign bcn_src[8] = hpc3_dma_bcn;
assign bcn_src[9] = int_bcn[0];
assign bcn_src[10] = int_bcn[1];
assign bcn_src[11] = vdma_bcn[0];
assign bcn_src[12] = vdma_bcn[1];
assign bcn_src[13] = vdma_bcn[2];
assign bcn_src[14] = vdma_bcn[3];
assign bcn_src[15] = { lc_miss_cnt, la_miss_cnt, la_skips };

always @(posedge clk_sys) begin
	if (~pll_locked) begin
		bcn_div   <= 6'd0;
		bcn_idx   <= 4'd0;
		bcn_beat  <= 32'd0;
		bcn_req   <= 1'b0;
		bcn_addr  <= 32'h0;
		bcn_wdata <= 64'h0;
	end else begin
		bcn_req <= 1'b0;
		bcn_div <= bcn_div + 6'd1;
		if (bcn_div == 6'd63) begin
			bcn_req   <= 1'b1;
			bcn_addr  <= 32'h0580_0000 + {25'd0, bcn_idx, 3'b000};
			bcn_wdata <= bcn_src[bcn_idx];
			if (bcn_idx == BCN_WORDS-1) begin
				bcn_idx  <= 4'd0;
				bcn_beat <= bcn_beat + 32'd1;
			end else begin
				bcn_idx  <= bcn_idx + 4'd1;
			end
		end
	end
end

/////////////////////////////   VIDEO   //////////////////////////

// Straight out of VC2's timing generator. There is no scandoubler and no line
// doubler: the raster is already 1318 x 1065 progressive, which is more than
// MiSTer's scaler needs to work with, and what it is short of is not lines but
// FRAME RATE. See the header, and docs/18-mister-integration.md.
assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = vid_ce_pix;
assign VGA_DE = vid_de;
assign VGA_HS = vid_hsync;
assign VGA_VS = vid_vsync;
assign VGA_R  = vid_r;
assign VGA_G  = vid_g;
assign VGA_B  = vid_b;

// The disk light follows the SCSI block interface, which is the only thing in
// this machine that touches the SD card while it runs.
assign LED_DISK  = |sd_rd | |sd_wr;
assign LED_POWER = 0;
assign LED_USER  = prom_download;

endmodule
