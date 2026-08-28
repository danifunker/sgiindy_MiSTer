/* verilator lint_off UNUSED */

// scsi.v
// implements a target only scsi device
  
module scsi
(
	input      clk,

	// scsi interface
	input 	  rst, // bus reset from initiator
	input 	  sys_rst, // system reset (CD engine state survives bus resets)
	input 	  sel,
	input 	  bus_busy, // another device currently holds the bus (its BSY)
	input 	  atn, // initiator requests to send a message
	input 	  cd_enable, // CDROM only: drive present (responds to selection even w/o disc)
	output 	  bsy, // target holds bus

	output 	  msg,
	output 	  cd,
	output 	  io,

	output 	  req,
	output 	  req_bus,   // bus-visible REQ (stays up across HPS block fetches in data phases)
	input 	  ack, // initiator acknowledges a request
	input     host_csr_rd, // pulse: host read the Current SCSI Bus Status reg (REQ poll)
	input     host_data_rd, // pulse: host read the SCSI data register via /DACK (next byte)

	input   [7:0] din, // data from initiator to target
	output  [7:0] dout, // data from target to initiator
	output [15:0] dout_pair,
	output [15:0] dout_pair_next,

	// CD audio PCM (CDROM targets only; zeros on disks). Mixed at the top.
	output signed [15:0] cd_snd_l,
	output signed [15:0] cd_snd_r,

	// interface to io controller
	input         img_mounted,
	input  [31:0] img_blocks,
	output [31:0] io_lba,
	output        io_rd,
	output reg 	  io_wr,
	input         io_ack,

	input   [7:0] sd_buff_addr,
	input   [4:0] sd_buff_addr_hi, // hps_io addr[12:8] (CD whole-frame bursts)
	input  [15:0] sd_buff_dout,
	output [15:0] sd_buff_din,
	input         sd_buff_wr,

	output        dbg_mounted,  // JTAG debug: is a disk mounted on this target?
	output [2:0]  dbg_phase,    // JTAG debug: current target phase
	output [7:0]  dbg_hs,       // JTAG debug: REQ/ACK handshake observations
	output [3:0]  dbg_hs2,      // JTAG debug: completion flags (survive bus reset)
	output [7:0]  dbg_cmd,      // JTAG debug: command-type bitmap (survive reset)

	// JTAG debug: word-write byte-serialization investigation. The ncr5380
	// feeds these in so we can capture, at the REAL target sample point, what
	// byte0/byte1 of the first word write actually latched vs the intended low
	// byte — pinning whether the low byte ever reaches the target.
	input         dbg_dma_word,    // ncr5380 dma_word_latched
	input         dbg_dma_long,    // ncr5380 dma_longword_latched
	input  [7:0]  dbg_dma_lowbyte, // ncr5380 dma_write_low_byte (intended odd byte)
	output [31:0] dbg_wrsnap,      // captured first-word-write snapshot
	output [31:0] dbg_selsnap,     // selection/command handshake observability

	// JTAG debug: multi-block WRITE stall observability (2026-06-10). Live
	// snapshot of the data-transfer state so the 16KB (32-block) result write
	// can be caught mid-stall: which block (data_cnt), phase, the io_wr/io_ack
	// block-flush handshake, the double-buffer select, and tlen.
	//   [15:0]=data_cnt [18:16]=phase [19]=data_complete [20]=io_wr [21]=io_ack
	//   [22]=io_busy [23]=sd_buff_sel [24]=cmd_write [30:25]=tlen[5:0] [31]=req
	output [31:0] dbg_wrstall,
	output [31:0] dbg_wrfb,     // JTAG WRFB: write-phase first-beat forensics
	output [31:0] dbg_ring,     // read-ring serve/refill bookkeeping (anchor feed)
	output [31:0] dbg_cda0,     // JTAG CDA0: cd_audio TOC/engine state (see cd_audio.sv)
	output [31:0] dbg_cda2,     // JTAG CDA2: last 0xC1 CDB {op9, start5, alloc7, alloc8}
output [31:0] dbg_cda3,     // JTAG CDA3: last play-class CDB {op, cdb3, cdb4, cdb5}
output [31:0] dbg_cda4,     // JTAG CDA4: last play-class CDB {cdb1, cdb6, cdb7, cdb8}
	output [31:0] dbg_cda1,     // JTAG CDA1: {toc_rdy,no_media,mounted,ok, sense_asc, sense_key, cmd_cnt, last_op}
	output [31:0] dbg_cdur,     // JTAG CDUR: cd_audio underrun counters (see cd_audio.sv)

	// ===== BlueSCSI Toolbox dedicated block interface (TOOLBOX_ENABLE only) ====
	// Isolated from the disk block interface above so the disk read/write path is
	// untouched (docs/BLUESCSI_CORE_HPS_CONTRACT.md). Inert when TOOLBOX_ENABLE=0.
	// The round-trip FSM that drives tb_rd/tb_wr is M1 stage 2; stage 1 wires the
	// slot end-to-end and ties the outputs off (fs ops 0xD0-D5 already CHECK, as
	// they are not in cmd_ok).
	input         tb_mounted,    // img_mounted[VD_TOOLBOX]: shared folder ready
	output [31:0] tb_lba,
	output        tb_rd,
	output        tb_wr,
	input         tb_ack,
	output [15:0] tb_buff_din
);

// SCSI device id
parameter [2:0] ID = 0;
// Set on the PRIMARY target only (ID 0). Gates the BlueSCSI Toolbox so just one
// target presents as a Toolbox device and owns the dedicated tb_* transport.
// docs/BLUESCSI_CORE_HPS_CONTRACT.md
parameter TOOLBOX_ENABLE = 0;
// Set on the CD-ROM target (ID 3) only. Gates the BlueSCSI Toolbox CD Changer
// (0xD7 LIST / 0xD8 SET NEXT / 0xDA COUNT) onto the SAME tb_* transport as the
// disk Toolbox, with the CD-changer opcode set + a CD-folder HPS handler.
// docs/BLUESCSI_CD_CHANGER_CONTRACT.md
parameter CDCHANGER_ENABLE = 0;
// tb transport buffer size (per lane), in address bits. 8 = one 512-byte SD
// sector (file Toolbox + single-block default). The CD changer sets 11 (8
// sectors = 4 KB) so LIST CDS serves the full 100-entry list in one
// fetch-all-then-serve pass. docs/BLUESCSI_CD_CHANGER_CONTRACT.md §4, §10.
parameter TB_ADDRW = 8;
// Apple CD-ROM mode (docs/plan_scsi_cdrom.md; MAME nscsi_cdrom_apple_device is
// the byte-for-byte oracle). 0 = hard disk: every CDROM conditional below
// constant-folds away, leaving the wedge-hardened disk target bit-identical.
// 1 = read-only CD-ROM: 2048-byte logical blocks served as 4 consecutive
// 512-byte HPS blocks (lba/tlen <<2), AppleCD INQUIRY/TOC/no-disc sense.
parameter CDROM = 0;

// Read-prefetch ring depth (number of 512-byte sectors held in the buffer).
// The read path keeps this many blocks fetched AHEAD of the Mac so the per-block
// HPS fetch latency is hidden and heavy reads (e.g. Control Panels) stream
// instead of stalling at every 512-byte boundary (the #2 pseudo-DMA stall;
// MAME's nscsi_harddisk reads each sector synchronously so it never stalls —
// docs/findings_scsi_dma_stall_offline_2026-06-14.md). RING_LOG=1 reproduces the
// original two-sector double buffer exactly. WRITES are unchanged: they stay on
// the original two-slot double buffer (slots 0/1) regardless of RING_LOG.
parameter  RING_LOG    = 5;             // log2(sectors); 5 => 32-sector / 16KB read ring
                                        // (was 3/8-sector; deepened 2026-06-15 for the #2
                                        // heavy-read stall: cold 7.5.5 extension loading drains
                                        // the ring faster than the HPS refills -> pseudo-DMA
                                        // stall -> driver I/O fail. 32 sectors hides more HPS
                                        // latency. RING_LOG=6 (32KB) needs 600 M10K > 553 avail
                                        // (cache = 3 mirror RAMs x 2 buffers x 2 disks); 5 fits
                                        // at ~504/553. For >16KB, drop the look-ahead mirror
                                        // RAMs (ram_c/ram_d) -> ~1/3 the M10K -> room for 48KB+.)
localparam RING_BLOCKS = 1 << RING_LOG; // sectors buffered for reads
localparam BUF_AW      = 8 + RING_LOG;  // dpram word-address width (256 words/sector)

assign dbg_mounted = mounted;

// BlueSCSI Toolbox transport — stage-1 tie-offs (the round-trip FSM is stage 2).
// The slot is wired end-to-end but inert; fs ops (0xD0-D5) already CHECK because
// they are not in cmd_ok. tb_mounted/tb_ack feed the stage-2 FSM.
// BlueSCSI Toolbox transport outputs — driven by the round-trip FSM below
// (search "Toolbox transport"). tb_buff_din is driven there (buffer read-back).
assign tb_lba = tb_lba_r;
assign tb_rd  = tb_rd_r;
assign tb_wr  = tb_wr_r;
assign dbg_phase = phase;

localparam PHASE_IDLE        = 3'd0;
localparam PHASE_CMD_IN      = 3'd1;
localparam PHASE_DATA_OUT    = 3'd2;
localparam PHASE_DATA_IN     = 3'd3;
localparam PHASE_STATUS_OUT  = 3'd4;
localparam PHASE_MESSAGE_OUT = 3'd5;
localparam PHASE_TB          = 3'd6;  // BlueSCSI Toolbox HPS round-trip
reg [2:0]  phase;

// ------------ sector buffer IO controller read/write -----------------------
// the buffer itself. Holds RING_BLOCKS sectors for reads; writes use slots 0/1.
reg sd_buff_sel;                   // WRITE double-buffer half (unchanged path)
reg [22:0] rd_hps_blk;             // READ ring: # of sectors fetched this command

// HPS sector-buffer byte order.  buffer0 always holds the byte the Mac reads
// FIRST (even byte) and buffer1 the odd byte.  The byte that lands in each
// physical buffer depends on how the IO controller packs sd_buff_dout:
//   * the real MiSTer HPS packs WIDE words LITTLE-endian: disk byte0 -> [7:0].
//   * the Verilator sim model (sim_blkdevice.cpp) packs BIG-endian: byte0->[15:8].
// JTAG probe PSC8 showed 0x5245 ('RE') on hardware where 0x4552 ('ER') was
// expected, confirming the swap.  Map the lanes so the Mac always receives the
// disk's natural big-endian byte order in both builds.
wire [7:0] buf0_q_a, buf1_q_a;
`ifdef VERILATOR
wire [7:0] buf0_data_a = sd_buff_dout[15:8];   // sim packs byte0 in high half
wire [7:0] buf1_data_a = sd_buff_dout[7:0];
assign sd_buff_din = {buf0_q_a, buf1_q_a};
`else
wire [7:0] buf0_data_a = sd_buff_dout[7:0];    // real HPS packs byte0 in low half
wire [7:0] buf1_data_a = sd_buff_dout[15:8];
assign sd_buff_din = {buf1_q_a, buf0_q_a};
`endif

// Buffer addressing. READS span the whole RING_BLOCKS-sector ring; WRITES stay
// on the original two-slot double buffer so the (experimental) write path is
// byte-for-byte unchanged. A command is either a read or a write, so the two
// schemes never collide on a port. The write/2-slot addresses are zero-extended
// to BUF_AW by assignment (no replication, so RING_LOG=1 / BUF_AW=9 still
// compiles and exactly reproduces the original double buffer).
wire [22:0] rd_cur_blk = data_cnt[31:9];               // sector the Mac is reading
wire [RING_LOG-1:0] rd_hps_slot = rd_hps_blk[RING_LOG-1:0];
wire [BUF_AW-1:0] hps_addr_wr = {sd_buff_sel, sd_buff_addr};   // write flush: slot 0/1
wire [BUF_AW-1:0] mac_addr_wr = data_cnt[9:1];                 // Mac write: slot 0/1
// HPS side (port A): read fills target the ring fetch-slot; write flushes keep
// the original sd_buff_sel half.
wire [BUF_AW-1:0] hps_addr = cmd_write ? hps_addr_wr : { rd_hps_slot, sd_buff_addr };
// Mac side (port B): reads address the full ring; writes the 2-slot half.
wire [BUF_AW-1:0] mac_addr = (phase == PHASE_DATA_IN) ? mac_addr_wr : data_cnt[BUF_AW:1];

wire [7:0] buffer0_dout;
wire [7:0] buffer0_dout_next;
wire [7:0] buffer0_dout_next2;
scsi_dpram #(.ADDRWIDTH(BUF_AW)) buffer0
(
	.clock(clk),

	.address_a(hps_addr),
	.data_a(buf0_data_a),
	.wren_a(sd_buff_wr && !ca_io_active),
	.q_a(buf0_q_a),

	.address_b(mac_addr),
	.data_b(store_low ? odd_byte_r : din),   // beat-role mux, see BEAT-ROLE FIX below
	.wren_b(buffer0_wr),
	.q_b(buffer0_dout),

	.address_c(mac_addr + 1'b1),
	.q_c(buffer0_dout_next),

	.address_d(mac_addr + 2'd2),
	.q_d(buffer0_dout_next2)
);

wire [7:0] buffer1_dout;
wire [7:0] buffer1_dout_next;
wire [7:0] buffer1_dout_next2;

// WORD-WRITE FIX (refinement, supersedes the direct-feed of dbg_dma_lowbyte):
//   buffer1 holds the ODD byte of each 16-bit unit. In word-mode pseudo-DMA the
//   target samples `din` a few cycles AFTER the ACK pulse, by which time din has
//   reverted to the EVEN byte (dout) — so without this fix the even byte was being
//   duplicated into the odd slot (iotest WRITE verify failed @offset1, actual==byte[0]).
//
//   First attempt (one-liner) fed `dbg_dma_lowbyte` (= ncr5380 dma_write_low_byte)
//   directly into data_b. That was functionally right when timing held, but had two
//   weaknesses:
//     (1) RACE: dma_write_low_byte re-latches on the NEXT CPU `i_dma_wr` rise. If the
//         next word's CPU access lands before the current word's buffer1 dpram-write
//         edge, buffer1 captures the NEXT word's odd byte → corrupt write.
//     (2) PATH: ncr5380 reg → cross-module → mux → BlockRAM data_b is a long combo
//         path on a fit-marginal design; intermittent setup violations corrupt the
//         write and cascade into a SCSI driver fault → Sad Mac on the first WRITE.
//
//   Refinement: latch the current word's odd byte LOCALLY at the word's FIRST
//   beat (stb_ack in PHASE_DATA_IN). At that moment dma_write_low_byte is stable
//   with the current word's wdata[7:0]. Hold it across beat 2's storage.
//   This is both race-free (locked to the current word, immune to the next CPU
//   access) and timing-friendly (BlockRAM data_b is now a short local-reg-to-RAM
//   path). Byte-mode (dbg_dma_word=0) still uses din directly, unchanged.
//
//   BEAT-ROLE FIX (2026-07-29, the +1-inserted-byte write corruption): the
//   original capture/pairing keyed on data_cnt[0] parity — capture at even
//   beats, store odd_byte_r at odd beats — which assumes every word-mode pair
//   lands (even,odd). The Mac driver hand-feeds the first bytes of a write in
//   BYTE mode before flipping to word pseudo-DMA (WRFB: first_word=0,
//   modeflips=1); when that prefix has ODD length the word beats land
//   (odd,even): the first beat hit buffer1 which stored a STALE odd_byte_r
//   (never captured this phase) and dropped the high byte on din — one
//   garbage byte inserted, the rest of the phase shifted one position. Fix:
//   key the DATA SOURCE on the beat's ROLE inside the word pair (wm_beat2),
//   not on count parity. Beat A: din is reliable (dout holds the high byte
//   through the train) — store din, capture dma_write_low_byte. Beat B: din
//   has reverted (the low byte's bus window is 1 cycle, before the ack even
//   rises) — store the captured odd_byte_r. Which BUFFER a beat lands in
//   stays keyed on data_cnt[0] (pure byte-position addressing, always
//   correct); only the value mux moves. Aligned pairs behave bit-identically
//   to the proven path; store_low is beat-locked at stb_ack so the wren-cycle
//   mux no longer samples the live dbg_dma_word (immune to a mid-train
//   re-latch by the next CPU access).
reg [7:0] odd_byte_r;
reg       wm_beat2;   // word pair half-done: next word-mode beat is beat B
reg       store_low;  // this cycle's pending dpram write stores odd_byte_r
always @(posedge clk) begin
	if (rst) begin
		odd_byte_r <= 8'h00;
		wm_beat2   <= 1'b0;
		store_low  <= 1'b0;
	end else begin
		store_low <= 1'b0;
		if (phase != PHASE_DATA_IN)
			wm_beat2 <= 1'b0;
		else if (stb_ack) begin
			// Test wm_beat2 FIRST: once a word pair is in flight the next beat
			// IS beat B by construction, so the decision must not consult the
			// live mode signal. dbg_dma_word (= ncr dma_word_latched) re-latches
			// on the NEXT CPU bus-cycle RISE, which is not DREQ-gated and can
			// land in the ~3-clock gap between the pair's two ACKs. If that next
			// access is byte-mode (the driver flips modes constantly — WRFB
			// measured up to 254 flips in one phase) a mode-first test would
			// mistake beat B for a byte beat, store the stale high byte still on
			// din, and re-slip the lane the fix exists to protect.
			if (wm_beat2) begin         // beat B: din stale, serve the captured low byte
				store_low <= 1'b1;
				wm_beat2  <= 1'b0;
			end else if (dbg_dma_word) begin
				// beat A: high byte on din, low byte stable in the ncr latch
				odd_byte_r <= dbg_dma_lowbyte;
				wm_beat2   <= 1'b1;
			end
			// byte beat: store din (store_low stays 0), wm_beat2 already clear
		end
	end
end

// ── MODE SELECT parameter parser: CD Audio Control page 0x0E (2026-07-29) ──
// The AppleCD Audio Player's VOLUME SLIDER is a MODE SELECT(6) carrying mode
// page 0x0E; until now every MODE SELECT byte was accepted and DISCARDED, so
// the slider was a silent no-op (docs/SCSI_CMD_GAPS.md item 2). Latch the four
// output ports' {channel, volume} and echo them in MODE SENSE page 0x0E (the
// player reads the slider position back); ports 0/1 scale the CD-DA PCM in
// cd_audio.sv. Parameter list framing (Snow target.rs 0x15 / [SPC] 6.7):
// 4-byte header (byte 3 = block descriptor length, 0 or 8) + descriptor +
// pages of {code, len, body}; page 0x0E body carries the ports at [6..13].
// Only the FIRST page is parsed (multi-page selects unobserved on Mac); the
// PF bit is not gated (BlueSCSI-permissive — a non-page payload cannot match
// code 0x0E at the page-code offset in practice). Byte extraction samples in
// the SAME cycle the sector-buffer dprams write (buffer0_wr/buffer1_wr) with
// their EXACT beat-role data expression (store_low ? odd_byte_r : din) — the
// f38c06f pairing law: never consult the live mode signal, the beat's ROLE
// decides the source. data_cnt has not advanced yet in that cycle (advance is
// on the ack FALLING edge), so it still indexes the byte being stored.
// State survives SCSI bus resets like the real drive (sys_rst clears it);
// defaults = Snow/BlueSCSI power-on page: ports 0/1 = channels 1/2 at full
// volume, ports 2/3 (rear) muted.
reg [7:0] cd_ap_ch0, cd_ap_vol0, cd_ap_ch1, cd_ap_vol1,
          cd_ap_ch2, cd_ap_vol2, cd_ap_ch3, cd_ap_vol3;
reg [7:0]  msel_bdlen;
reg [7:0]  msel_page;
wire [7:0]  msel_din  = store_low ? odd_byte_r : din;
wire [31:0] msel_pgoff = data_cnt - {24'd0, msel_bdlen} - 32'd4;
always @(posedge clk) begin
	if (sys_rst) begin
		cd_ap_ch0 <= 8'h01; cd_ap_vol0 <= 8'hFF;
		cd_ap_ch1 <= 8'h02; cd_ap_vol1 <= 8'hFF;
		cd_ap_ch2 <= 8'h04; cd_ap_vol2 <= 8'h00;
		cd_ap_ch3 <= 8'h08; cd_ap_vol3 <= 8'h00;
		msel_bdlen <= 8'd0; msel_page <= 8'd0;
	end else if ((CDROM != 0) && (phase != PHASE_DATA_IN)) begin
		msel_bdlen <= 8'd0;               // fresh command: assume no block
		msel_page  <= 8'd0;               // descriptor until byte 3 says so
	end else if ((CDROM != 0) && cmd_mode_select &&
	             (buffer0_wr || buffer1_wr)) begin
		if (data_cnt == 32'd3) msel_bdlen <= msel_din;
		if (data_cnt >= 32'd4) begin
			if (msel_pgoff == 32'd0) msel_page <= msel_din;
			else if (msel_page == 8'h0E) begin
				case (msel_pgoff)         // page header = 2 B; body[6..13]
				32'd8:  cd_ap_ch0  <= msel_din;
				32'd9:  cd_ap_vol0 <= msel_din;
				32'd10: cd_ap_ch1  <= msel_din;
				32'd11: cd_ap_vol1 <= msel_din;
				32'd12: cd_ap_ch2  <= msel_din;
				32'd13: cd_ap_vol2 <= msel_din;
				32'd14: cd_ap_ch3  <= msel_din;
				32'd15: cd_ap_vol3 <= msel_din;
				default: ;
				endcase
			end
		end
	end
end

scsi_dpram #(.ADDRWIDTH(BUF_AW)) buffer1
(
	.clock(clk),

	.address_a(hps_addr),
	.data_a(buf1_data_a),
	.wren_a(sd_buff_wr && !ca_io_active),
	.q_a(buf1_q_a),

	.address_b(mac_addr),
	.data_b(store_low ? odd_byte_r : din),   // beat-role mux, see BEAT-ROLE FIX above
	.wren_b(buffer1_wr),
	.q_b(buffer1_dout),

	.address_c(mac_addr + 1'b1),
	.q_c(buffer1_dout_next),

	.address_d(mac_addr + 2'd2),
	.q_d(buffer1_dout_next2)
);

reg old_io_ack;
always @(posedge clk) begin
	old_io_ack <= io_ack;
	if (phase == PHASE_IDLE)
		sd_buff_sel <= 0;
	else
		// ~ca_io_active: a CD-audio channel transfer started at bus-idle can
		// still be in flight when the Mac's next command reaches a data phase;
		// its ack falling here toggled the write double-buffer and bumped the
		// ring counter below - wrong sectors served (HW 2026-07-17: artifacted
		// CD icons, then a wedged READ). Same scope the io_busy term always had.
		if (old_io_ack & ~io_ack & ~ca_io_active) sd_buff_sel <= !sd_buff_sel;

	// READ ring fetch counter: # of sectors the HPS has delivered this command.
	// Reset alongside data_cnt (any non-transfer phase); bump on each io_ack
	// falling edge during a read. Writes never touch it (they use sd_buff_sel).
	if (phase != PHASE_DATA_OUT && phase != PHASE_DATA_IN &&
	    phase != PHASE_STATUS_OUT && phase != PHASE_MESSAGE_OUT)
		rd_hps_blk <= 23'd0;
	else if (old_io_ack & ~io_ack & cmd_read & ~ca_io_active)
		rd_hps_blk <= rd_hps_blk + 23'd1;
end

// -----------------------------------------------------------

// status replies
reg [7:0]  status;
`define STATUS_OK 8'h00
`define STATUS_CHECK_CONDITION 8'h02

// message codes
`define MSG_CMD_COMPLETE 8'h00
	
// drive scsi signals according to phase
assign msg = (phase == PHASE_MESSAGE_OUT);
assign cd = (phase == PHASE_CMD_IN) || (phase == PHASE_STATUS_OUT) || (phase == PHASE_MESSAGE_OUT);
assign io = (phase == PHASE_DATA_OUT) || (phase == PHASE_STATUS_OUT) || (phase == PHASE_MESSAGE_OUT);

// READ stall: for a block READ, the sector the Mac wants (rd_cur_blk) has not
// been fetched yet (only sectors [0, rd_hps_blk) are in the ring). Gated on
// cmd_read — INQUIRY/READ_CAPACITY/MODE_SENSE/REQUEST_SENSE also use DATA_OUT but
// serve data combinationally with no HPS fetch (rd_hps_blk stays 0), so they
// must NOT take this stall. Depth-independent; replaces the old 2-slot "half
// being filled" test. WRITE + non-data clauses unchanged.
// '&& mounted' in the read clause: media loss mid-READ (guest eject) stops
// the ring refill, and holding DTACK on data that will never arrive ground
// the whole OS at the 8ms watchdog ceiling per poll (HW 2026-07-17). With
// the medium gone the read completes with stale bytes and the driver gets
// its error through the normal status path instead.
// wr_pending lives at module scope (declared here, driven by the flush engine
// below) because io_busy must include it: between a block's req_wr edge and
// the flush issuing (io_wr rise) — one cycle normally, longer while a previous
// flush is still in flight — neither io_wr nor io_ack is high, so the old
// (io_wr | io_ack) busy term dropped REQ for that window and one extra
// pseudo-DMA word could land in the slot the flush hadn't read yet. TIM3
// install forensics 2026-07-28: a 7.5 MB write otherwise perfect except the
// FIRST WORD of one 512-byte block ("Machine Data" blk 81) — this window's
// exact signature.
reg    wr_pending;
// (2026-07-29) rd_ahead_blk: block of the FURTHEST byte one pseudo-DMA
// transaction can consume. The host-face serves din_pair/din_pair_next =
// bytes data_cnt..data_cnt+3, and a longword read CAPTURES the +2/+3 pair
// (its ACK-suppressed second word, ncr5380 dma_second_word_data) at the END
// of its FIRST bus cycle. When the driver's byte/word prefix skews the
// longword grid off the 512-byte block grid, that capture crosses into the
// NEXT ring block — which the old stall (rd_cur_blk only) never validated.
// At a just-in-time fill the capture read the ring slot's PREVIOUS occupant:
// TIM Voices 1 fork 0x18200 got 0x8080 (the bytes exactly one ring-depth =
// 4 KB earlier) instead of 0x3840; deterministic, 2 runs x 2 builds
// (HW 2026-07-29, CD sector 49385+512). Stall REQ
// until every byte the transaction can touch is in the ring. rd_ahead_needed
// clamps at the transfer TAIL, where +3 pokes past the last armed block: no
// fetch would ever arrive (deadlock), and the host never consumes those
// bytes (the driver's trailing word/byte reads stay inside the armed length
// and data_complete ends the phase first).
wire [22:0] rd_ahead_blk    = (data_cnt + 32'd3) >> 9;
wire        rd_ahead_needed = (rd_ahead_blk < rd_blk_total);
// Named so the always-on marginality anchor (MacLC.sv) loads the SAME
// comparator nets io_busy consumes, not shareable duplicates. Pure renaming
// of the two subexpressions below — no functional change (2026-08-03).
wire        rd_cur_unfilled   = (rd_cur_blk   >= rd_hps_blk);
wire        rd_ahead_unfilled = (rd_ahead_blk >= rd_hps_blk);
wire   io_busy = (phase == PHASE_DATA_OUT && cmd_read && mounted &&
                  (rd_cur_unfilled ||
                   (rd_ahead_needed && rd_ahead_unfilled))) ||
                 (phase == PHASE_DATA_IN  && (io_wr | wr_pending | (io_ack & ~ca_io_active)) && data_cnt[9] == sd_buff_sel) ||
                 (phase != PHASE_DATA_OUT && phase != PHASE_DATA_IN && (io_rd_d | io_wr | wr_pending | (io_ack & ~ca_io_active)));
// Ring-serve bookkeeping word for the always-on marginality anchor
// (MacLC.sv). The ring-stale corruption class (f5a3dec 07-17, 082dcc4 07-29,
// e66fd82 08-01, Finder colour-icon noise 08-03) lives in exactly this cone:
// a slot served at/past the rd_hps_blk fill boundary returns the slot's
// previous occupant silently. The value is never read — the word exists so
// probes-off fits keep these nets loaded as live logic (see the anchor
// comment block in MacLC.sv; do not trim or fold).
assign dbg_ring = { io_busy, rd_ahead_needed, rd_ahead_unfilled, rd_cur_unfilled,
                    rd_hps_blk[13:0], rd_ahead_blk[13:0] };
	// A zero-length transfer (e.g. INQUIRY with allocation length 0, or a
	// WRITE with transfer length 0) must complete immediately: data_complete
	// only sets on an ACK edge, which never comes when the initiator expects
	// no data — REQ would be held forever (same deadlock class as the
	// allocation-length over-serve).
	wire data_done = data_complete || (data_len == 32'd0) || tb_out_stalled || tb_get_abort;
	wire data_phase_complete = ((phase == PHASE_DATA_OUT) || (phase == PHASE_DATA_IN)) && data_done;
	// Toolbox DataIn serve-settle (driven near the tb FSM, declared here because
	// REQ consumes it). Zero outside a Toolbox/CD-changer DataIn serve.
	wire tb_srv_hold;
	// Toolbox STREAMING back-pressure (2026-07-31), also driven near the tb FSM.
	// GET: the serve has caught up with the HPS fetch. SEND: the collect has
	// lapped the ring and would overwrite a sector still waiting to be shipped.
	// Both are ordinary flow control -- REQ simply waits, exactly like io_busy on
	// the disk path -- and both are 0 whenever a transfer fits without streaming.
	wire tb_stream_stall;
	// 0xD4 SEND DATA inter-byte watchdog; zero outside that DataOut phase.
	wire tb_out_stalled;
	// GET fetch-retry budget exhausted mid-serve (tb_get_fault, TBS_STREAM):
	// force the data phase closed and CHECK instead of serving a stale sector.
	// Zero outside a Toolbox/CD-changer DataIn serve.
	wire tb_get_abort;
	// REQ assertion. Previously this was gated on !sel ("wait for the initiator
	// to drop SEL before the first REQ"). But the reference implementations
	// (Snow's NCR5380, MAME) assert REQ as soon as the target is selected and
	// in an information-transfer phase — they do NOT wait for SEL to deassert.
	// Our !sel gate added an extra handshake step: target asserts BSY at
	// CMD_IN, then withholds REQ until SEL drops. The Mac ROM driver's
	// SEL-release intermittently races that, the command never starts, the
	// driver times out and issues a bus RESET -> the CMD_IN->IDLE->reselect
	// loop seen on the FPGA (but not on real HW or MAME). Drop the !sel gate;
	// `phase != PHASE_IDLE` already prevents REQ during the IDLE->selection
	// sampling window, so REQ now comes up on selection like the references.
	assign req = (phase != PHASE_IDLE) && (phase != PHASE_TB) && !ack && !io_busy && !data_phase_complete &&
	             !tb_srv_hold && !tb_stream_stall;

	// Bus-VISIBLE REQ (CSR bit 5 / BSR DRQ): stays asserted across the HPS
	// 512-byte block-boundary fetches in the data phases. Real drives never
	// drop REQ mid-command for ~ms, and both oracles guarantee the same
	// observable (Snow pre-buffers whole responses; MAME synthesizes DRQ
	// from its FIFO). The System-7-era HD SC 4.3 driver polls CSR/BSR
	// between 512-byte pseudo-DMA chunks — when it saw our dead bus it
	// concluded the transfer died and parked forever (the Welcome wedge at
	// data_cnt=512). Flow control is unaffected: the DACK path still stalls
	// the CPU via `req` (DTACK gate) until the buffer half is really valid,
	// so a premature data access waits instead of reading stale bytes.
	// Non-data phases keep the io_busy suppression (status byte must not
	// be offered while a flush/fetch is still in flight).
	// (LBMacTwo 5adc2e1, HW-validated with 2d025c5 in round 6.)
	assign req_bus = (phase != PHASE_IDLE) && (phase != PHASE_TB) && !ack && !data_phase_complete &&
	                 ((phase == PHASE_DATA_OUT) || (phase == PHASE_DATA_IN) || !io_busy) &&
	                 !tb_srv_hold &&   // ~250 ns per byte, not the ~ms fetch stall above
	                 // The streaming stall DOES gate the bus-visible REQ/DRQ: unlike
	                 // a block-boundary disk fetch, there is genuinely no byte to
	                 // hand over, and the host must wait rather than latch a stale
	                 // one. It clears within one HPS sector time (~0.5 ms).
	                 !tb_stream_stall;

assign bsy = (phase != PHASE_IDLE);

assign dout = (phase == PHASE_STATUS_OUT)?status:
	 (phase == PHASE_MESSAGE_OUT)?`MSG_CMD_COMPLETE:
	 (phase == PHASE_DATA_OUT)?cmd_dout:
	 8'h00;
assign dout_pair = (phase == PHASE_STATUS_OUT)?{status, status}:
	 (phase == PHASE_MESSAGE_OUT)?{`MSG_CMD_COMPLETE, `MSG_CMD_COMPLETE}:
	 (phase == PHASE_DATA_OUT)?cmd_dout_pair:
	 16'h0000;
assign dout_pair_next = (phase == PHASE_STATUS_OUT)?{status, status}:
	 (phase == PHASE_MESSAGE_OUT)?{`MSG_CMD_COMPLETE, `MSG_CMD_COMPLETE}:
	 (phase == PHASE_DATA_OUT)?cmd_dout_pair_next:
	 16'h0000;

// de-multiplex different data sources
wire [7:0] cmd_dout =
		cmd_read?(data_cnt[0] ? buffer1_dout : buffer0_dout):
		cmd_inquiry?inquiry_dout:
		cmd_read_capacity?read_capacity_dout:
		cmd_mode_sense?mode_sense_dout:
		cmd_request_sense?request_sense_dout:
		cmd_cd_toc?cd_toc_dout:
		(cmd_cd_t43f2 || cmd_cd_t43f1)?cd_toc2_dout:
		cmd_cd_t43f0?cd_toc43_dout:
		cmd_cd_subq?cd_subq_dout:
		cmd_cd_subq43?cd_subq43_dout:
		cmd_cd_astat?cd_astat_dout:
		cmd_cd_hdr?cd_hdr_dout:
		cmd_tb_devinfo?tb_devinfo_dout:
		cmd_tb_debug?tb_debug_dout:
		(cmd_tb_fs_in || cmd_cdc_in)?tb_serve:
		8'h00;
wire [15:0] cmd_dout_pair =
		cmd_read?(data_cnt[0] ? {buffer1_dout, buffer0_dout_next} : {buffer0_dout, buffer1_dout}):
		cmd_inquiry?{inquiry_dout, inquiry_dout_next}:
		cmd_read_capacity?{read_capacity_dout, read_capacity_dout_next}:
		cmd_mode_sense?{mode_sense_dout, mode_sense_dout_next}:
		cmd_request_sense?{request_sense_dout, request_sense_dout_next}:
		cmd_cd_toc?{cd_toc_dout, cd_toc_dout_next}:
		(cmd_cd_t43f2 || cmd_cd_t43f1)?{cd_toc2_dout, cd_toc2_dout_next}:
		cmd_cd_t43f0?{cd_toc43_dout, cd_toc43_dout_next}:
		cmd_cd_subq?{cd_subq_dout, cd_subq_dout_next}:
		cmd_cd_subq43?{cd_subq43_dout, cd_subq43_dout_next}:
		cmd_cd_astat?{cd_astat_dout, cd_astat_dout_next}:
		cmd_cd_hdr?{cd_hdr_dout, cd_hdr_dout_next}:
		cmd_tb_devinfo?{tb_devinfo_dout, tb_devinfo_dout_next}:
		cmd_tb_debug?{tb_debug_dout, tb_debug_dout_next}:
		(cmd_tb_fs_in || cmd_cdc_in)?tb_serve_pair:
		16'h0000;
wire [15:0] cmd_dout_pair_next =
		cmd_read?(data_cnt[0] ? {buffer1_dout_next, buffer0_dout_next2} : {buffer0_dout_next, buffer1_dout_next}):
		cmd_inquiry?{inquiry_dout_next2, inquiry_dout_next3}:
		cmd_read_capacity?{read_capacity_dout_next2, read_capacity_dout_next3}:
		cmd_mode_sense?{mode_sense_dout_next2, mode_sense_dout_next3}:
		cmd_request_sense?{request_sense_dout_next2, request_sense_dout_next3}:
		cmd_cd_toc?{cd_toc_dout_next2, cd_toc_dout_next3}:
		(cmd_cd_t43f2 || cmd_cd_t43f1)?{cd_toc2_dout_next2, cd_toc2_dout_next3}:
		cmd_cd_t43f0?{cd_toc43_dout_next2, cd_toc43_dout_next3}:
		cmd_cd_subq?{cd_subq_dout_next2, cd_subq_dout_next3}:
		cmd_cd_subq43?{cd_subq43_dout_next2, cd_subq43_dout_next3}:
		cmd_cd_astat?{cd_astat_dout_next2, cd_astat_dout_next3}:
		cmd_cd_hdr?{cd_hdr_dout_next2, cd_hdr_dout_next3}:
		cmd_tb_devinfo?{tb_devinfo_dout_next2, tb_devinfo_dout_next3}:
		cmd_tb_debug?{tb_debug_dout_next2, tb_debug_dout_next3}:
		(cmd_tb_fs_in || cmd_cdc_in)?tb_serve_pair_next:
		16'h0000;

// REQUEST SENSE response: minimal fixed-format sense, "NO SENSE".
//   byte 0 = 0x70 (current error, valid=0), byte 7 = 0x0a (add'l length 10),
//   sense key (byte 2) = 0 = NO SENSE, all else 0.
//   CDROM serves the latched cd_sense_key/asc (byte 2 / byte 12) instead, so
//   the AppleCD driver sees NOT READY + vendor ASC 0xB0 while no disc is in.
function [7:0] sense_byte;
	input [31:0] cnt;
	begin
		sense_byte =
			(cnt == 32'd0 )?8'h70:
			(cnt == 32'd2 )?((CDROM != 0)?{4'd0, cd_sense_key}:8'h00):
			(cnt == 32'd7 )?8'h0a:
			(cnt == 32'd12)?((CDROM != 0)?cd_sense_asc:8'h00):
			8'h00;
	end
endfunction
wire [7:0] request_sense_dout       = sense_byte(data_cnt);
wire [7:0] request_sense_dout_next  = sense_byte(data_cnt_next);
wire [7:0] request_sense_dout_next2 = sense_byte(data_cnt_next2);
wire [7:0] request_sense_dout_next3 = sense_byte(data_cnt_next3);

// INQUIRY vendor id (8 bytes, space-padded). The value is SCSI_VENDOR_STRING,
// defined in the included rtl/scsi_vendor.vh (committed default "MiSTer  "). A
// throwaway build (e.g. BlueSCSI Toolbox co-testing) overrides the vendor by
// editing that one file — no build-specific vendor string ever lives here, and
// the edit is kept out of commits with:
//   git update-index --skip-worktree rtl/scsi_vendor.vh   (undo: --no-skip-worktree)
`include "scsi_vendor.vh"
localparam [63:0] SCSI_VENDOR_ID = `SCSI_VENDOR_STRING;

// output of inquiry command, identify as "MiSTer  VIRTUAL DISKx" (x = SCSI ID)
//   vendor  (bytes  8-15): "MiSTer  "        (8 chars, space-padded)
//   product (bytes 16-31): "VIRTUAL DISKx   " (16 chars, x = '0'+ID)
// (identifiers match lbmactwo_MiSTer rtl/scsi.v — keep the SCSI files in sync)
// additional-length byte = 31 -> standard 36-byte INQUIRY response (5 + 31),
// matching real drives and Snow. It was 32 (=37 total): a driver that reads
// the standard 36 bytes then left 1 unserved byte on the target -> REQ held
// forever -> the post-clamp Welcome wedge of 2026-06-10c.
// CDROM INQUIRY: byte-exact copy of MAME nscsi_cdrom_apple_device (data taken
// from the ROM of an AppleCD 150; the old scsi_empty_cd stub shipped the same
// descriptor). The
// stock Apple CD-ROM extension binds only to known Apple-shipped drives, so
// the SONY CDU-8002 identity is required for the driver to attach (this is
// hardware emulation fidelity, like MAME — not a vendor-string cosmetic).
// 5 + additional-length 0x31 = 54-byte standard response.
function [7:0] cd_inquiry_byte;
	input [31:0] cnt;
	begin
		cd_inquiry_byte =
			(cnt == 32'd0 )?8'h05:  // CD-ROM device class
			(cnt == 32'd1 )?8'h80:  // removable
			(cnt == 32'd2 )?8'h02:  // ANSI SCSI-2 (dialect tier; Snow-matched)
			(cnt == 32'd3 )?8'h02:
			(cnt == 32'd4 )?8'h31:  // additional length
			(cnt == 32'd8 )?"S":(cnt == 32'd9 )?"O":
			(cnt == 32'd10)?"N":(cnt == 32'd11)?"Y":
			((cnt >= 32'd12) && (cnt <= 32'd15))?" ":  // vendor pad
			(cnt == 32'd16)?"C":(cnt == 32'd17)?"D":
			(cnt == 32'd18)?"-":(cnt == 32'd19)?"R":
			(cnt == 32'd20)?"O":(cnt == 32'd21)?"M":
			(cnt == 32'd22)?" ":(cnt == 32'd23)?"C":
			(cnt == 32'd24)?"D":(cnt == 32'd25)?"U":
			(cnt == 32'd26)?"-":(cnt == 32'd27)?"8":
			(cnt == 32'd28)?"0":(cnt == 32'd29)?"0":
			(cnt == 32'd30)?"4":(cnt == 32'd31)?" ":  // 8004: standard dialect
			(cnt == 32'd32)?"1":(cnt == 32'd33)?".":
			(cnt == 32'd34)?"9":(cnt == 32'd35)?"a":
			(cnt == 32'd39)?8'hd0:(cnt == 32'd40)?8'h90:
			(cnt == 32'd41)?8'h27:(cnt == 32'd42)?8'h3e:
			(cnt == 32'd43)?8'h01:(cnt == 32'd44)?8'h04:
			(cnt == 32'd45)?8'h91:(cnt == 32'd47)?8'h18:
			(cnt == 32'd48)?8'h06:(cnt == 32'd49)?8'hf0:
			(cnt == 32'd50)?8'hfe:
			8'h00;
	end
endfunction

function [7:0] inquiry_byte;
	input [31:0] cnt;
	begin
		if (CDROM != 0) inquiry_byte = cd_inquiry_byte(cnt);
		else inquiry_byte =
			(cnt == 32'd4 )?8'd31:  // additional length

			// vendor id (bytes 8-15) from the SCSI_VENDOR_ID parameter. A string's
			// first char is its most-significant byte, so byte (cnt-8) sits at
			// SCSI_VENDOR_ID[(15-cnt)*8 +: 8]. Default "MiSTer  "; build-time
			// override lives in the gitignored rtl/scsi_vendor_local.vh (see above).
			((cnt >= 32'd8) && (cnt <= 32'd15)) ? SCSI_VENDOR_ID[(15 - cnt)*8 +: 8] :

			(cnt == 32'd16)?"V":(cnt == 32'd17)?"I":
			(cnt == 32'd18)?"R":(cnt == 32'd19)?"T":
			(cnt == 32'd20)?"U":(cnt == 32'd21)?"A":
			(cnt == 32'd22)?"L":(cnt == 32'd23)?" ":
			(cnt == 32'd24)?"D":(cnt == 32'd25)?"I":
			(cnt == 32'd26)?"S":(cnt == 32'd27)?"K":
			(cnt == 32'd28)?"0" + {5'd0, ID}:
			(cnt == 32'd29)?" ":(cnt == 32'd30)?" ":
			(cnt == 32'd31)?" ":
			8'h00;
	end
endfunction
wire [31:0] data_cnt_next = data_cnt + 32'd1;
wire [31:0] data_cnt_next2 = data_cnt + 32'd2;
wire [31:0] data_cnt_next3 = data_cnt + 32'd3;
wire [7:0] inquiry_dout       = inquiry_byte(data_cnt);
wire [7:0] inquiry_dout_next  = inquiry_byte(data_cnt_next);
wire [7:0] inquiry_dout_next2 = inquiry_byte(data_cnt_next2);
wire [7:0] inquiry_dout_next3 = inquiry_byte(data_cnt_next3);

// output of read capacity command
//wire [31:0] capacity = 32'd41056;   // 40960 + 96 blocks = 20MB
//wire [31:0] capacity = 32'd1024096;   // 1024000 + 96 blocks = 500MB
// Initialized: the CDROM target answers MODE SENSE before any image has ever
// been mounted (drive present, no disc), so the capacity bytes must not be X.
reg [31:0] capacity = 32'd0;
reg        mounted = 0;
always @(posedge clk) begin
	if (img_mounted) begin
		if (|img_blocks) begin
			// CDROM: capacity is in 2048-byte logical blocks (last LBA), i.e.
			// the mounted 512-block count / 4 - 1. Disks: 512-blocks - 1.
			capacity <= (CDROM != 0) ? ({2'b00, img_blocks[31:2]} - 1'd1)
			                         : (img_blocks - 1'd1);
			if (!mounted) $display("Image mounted on target %d, size: %d", ID, img_blocks);
			mounted <= 1;
		end else
			mounted <= 0;
	end else if ((CDROM != 0) && cd_eject_pulse)
		// EJECT (Apple 0xC0 or standard 0x1B LoEj — cmd_cd_eject_any): drop
		// the medium; the next img_mounted pulse (OSD mount or the BlueSCSI
		// CD-changer SET NEXT CD remap) is the "insert disc" edge the AppleCD
		// driver's insertion poll is waiting for. The HPS-side image stays
		// mounted — harmless, the target simply reports no-disc until then.
		mounted <= 0;
end

wire [7:0] read_capacity_dout =
		(data_cnt == 32'd0 )?capacity[31:24]:
		(data_cnt == 32'd1 )?capacity[23:16]:
		(data_cnt == 32'd2 )?capacity[15:8]:
		(data_cnt == 32'd3 )?capacity[7:0]:
		(data_cnt == 32'd6 )?((CDROM != 0)?8'h08:8'd2): // block length 2048 (CD) / 512 (disk)
		8'h00;
wire [7:0] read_capacity_dout_next =
		(data_cnt_next == 32'd0 )?capacity[31:24]:
		(data_cnt_next == 32'd1 )?capacity[23:16]:
		(data_cnt_next == 32'd2 )?capacity[15:8]:
		(data_cnt_next == 32'd3 )?capacity[7:0]:
		(data_cnt_next == 32'd6 )?((CDROM != 0)?8'h08:8'd2):
		8'h00;
wire [7:0] read_capacity_dout_next2 =
		(data_cnt_next2 == 32'd0 )?capacity[31:24]:
		(data_cnt_next2 == 32'd1 )?capacity[23:16]:
		(data_cnt_next2 == 32'd2 )?capacity[15:8]:
		(data_cnt_next2 == 32'd3 )?capacity[7:0]:
		(data_cnt_next2 == 32'd6 )?((CDROM != 0)?8'h08:8'd2):
		8'h00;
wire [7:0] read_capacity_dout_next3 =
		(data_cnt_next3 == 32'd0 )?capacity[31:24]:
		(data_cnt_next3 == 32'd1 )?capacity[23:16]:
		(data_cnt_next3 == 32'd2 )?capacity[15:8]:
		(data_cnt_next3 == 32'd3 )?capacity[7:0]:
		(data_cnt_next3 == 32'd6 )?((CDROM != 0)?8'h08:8'd2):
		8'h00;

// =====================================================================
// CDROM response synthesis (folds away on disk targets).
//
// The cd_audio engine (rtl/cd_audio.sv) owns the real multi-track TOC
// (fetched from the HPS MCDA blob window, with a synthesized single-track
// fallback for stock Main / sim / flat images), the AppleCD playback state
// machine and the live position registers. This section only wires its
// precomputed 0xC1 response RAM and live 0xCC/0xC2 registers into the
// serve lanes — the serve path stays free of any live arithmetic.
// Oracle: MAME nscsi_cdrom_apple_device, as before.
// =====================================================================
function [7:0] cd_bcd2bin;
	input [7:0] b;
	cd_bcd2bin = {4'd0, b[7:4]} * 8'd10 + {4'd0, b[3:0]};
endfunction

// cd_audio interface wires (driven by the generate block near the io logic)
wire        ca_io_active, ca_io_rd_w;
wire [31:0] ca_io_lba;
wire  [7:0] ca_ast_code, ca_cur_ctrl, ca_cur_trk;
wire  [7:0] ca_abs_m, ca_abs_s, ca_abs_f, ca_rel_m, ca_rel_s, ca_rel_f;
wire  [7:0] ca_t43_q0, ca_t43_q1, ca_t43_q2, ca_t43_q3;
wire  [9:0] ca_t43_len;
// 0x43 start-track filter (serve-time address transform; the table stays
// full-from-track-1): header bytes 0-3 serve as-is, descriptor bytes are
// offset so the FIRST served descriptor is the requested start track;
// start 0xAA = the lead-out row (the driver's very first ask on HW was
// {start=0xAA, alloc=12} = header + leadout only). The header's u16be
// length field is overridden to the filtered length. nreal is recovered
// from the table length: len = (nreal+1)*8 + 6 -> nreal = (len-14)>>3 +1;
// simpler: rows_total = (ca_t43_len - 10'd6) >> 3 (tracks + leadout).
wire [6:0]  ca_t43_nreal = (ca_t43_len >= 10'd14) ? ((ca_t43_len - 10'd14) >> 3) + 7'd1 : 7'd1;
wire [7:0]  ca_t43_start = cmd[6];
wire [6:0]  ca_t43_soff  =
	(ca_t43_start == 8'h00 || ca_t43_start == 8'h01) ? 7'd0 :
	(ca_t43_start == 8'hAA) ? ca_t43_nreal :
	(ca_t43_start > {1'b0, ca_t43_nreal}) ? ca_t43_nreal :
	ca_t43_start[6:0] - 7'd1;
// filtered data length (u16-be field value = bytes after the field = rows*8 + 2)
wire [9:0]  ca_t43_flen  = {(7'd1 + ca_t43_nreal - ca_t43_soff), 3'b000} + 10'd2;
wire [9:0]  ca_t43_tot   = ca_t43_flen + 10'd2;      // total serveable bytes
wire [8:0]  ca_t43_addr  = (data_cnt < 32'd4) ? data_cnt[8:0]
                         : (9'd4 + {ca_t43_soff, 3'b000} + (data_cnt[8:0] - 9'd4));
// standard audio-status codes ([PIONEER] 2-27C via Snow): 0x11 play,
// 0x12 paused, 0x13 completed/stopped (engine ast_code 0/1/3/5).
wire  [7:0] ca_ast_std = (ca_ast_code == 8'd0) ? 8'h11 :
                         (ca_ast_code == 8'd1) ? 8'h12 : 8'h13;
function [7:0] scsi_bin2bcd;           // 0..99 (vendor-dialect BCD serving)
	input [7:0] v;
	scsi_bin2bcd = {4'd0, (v / 8'd10)} << 4 | {4'd0, (v % 8'd10)};
endfunction
wire  [7:0] ca_toc_q0, ca_toc_q1, ca_toc_q2, ca_toc_q3;
wire        ca_toc_ready;
reg         ca_cmd_stb = 1'b0, ca_read_stb = 1'b0, ca_eject_stb = 1'b0;

// Apple 0xC1 serve addressing into the engine's response RAM:
//   layout [0..3] header, [4..7] lead-out, [8+4k..] track k+1 descriptors.
// Mode (CDB[9][7:6]) selects the base; track mode indexes by BCD CDB[5].
// Reads past the 99 precomputed descriptors clamp to the last one
// (byte-in-descriptor preserved) — MAME "keep returning the last track".
wire [7:0] ca_toc_trk_bin = cd_bcd2bin(cmd[5]);
wire [8:0] ca_toc_trk_k   = (ca_toc_trk_bin == 8'd0) ? 9'd0 :
                            (ca_toc_trk_bin >  8'd99) ? 9'd98 :
                            {1'b0, ca_toc_trk_bin} - 9'd1;
wire [8:0] ca_toc_base =
	(cmd[9][7:6] == 2'b01) ? 9'd4 :
	(cmd[9][7:6] == 2'b10) ? (9'd8 + {ca_toc_trk_k[6:0], 2'b00}) :
	                         9'd0;
wire [8:0] ca_toc_raw  = ca_toc_base + data_cnt[8:0];
wire [8:0] ca_toc_addr = (ca_toc_raw < 9'd404) ? ca_toc_raw
                       : (9'd400 + {7'd0, ca_toc_raw[1:0]});

wire [7:0] cd_toc_dout         = ca_toc_ready ? ca_toc_q0 : 8'h00;
wire [7:0] cd_toc_dout_next    = ca_toc_ready ? ca_toc_q1 : 8'h00;
wire [7:0] cd_toc_dout_next2   = ca_toc_ready ? ca_toc_q2 : 8'h00;
wire [7:0] cd_toc_dout_next3   = ca_toc_ready ? ca_toc_q3 : 8'h00;

// READ Q SUBCODE (0xC2, 9 bytes): control, track BCD, index 01, relative
// M/S/F, absolute M/S/F — live registers from the engine.
function [7:0] cd_subq_byte;
	input [31:0] cnt;
	begin
		cd_subq_byte = (cnt == 32'd1) ? scsi_bin2bcd(ca_cur_trk) :
		               (cnt == 32'd2) ? 8'h01 :
		               (cnt == 32'd3) ? scsi_bin2bcd(ca_rel_m) :
		               (cnt == 32'd4) ? scsi_bin2bcd(ca_rel_s) :
		               (cnt == 32'd5) ? scsi_bin2bcd(ca_rel_f) :
		               (cnt == 32'd6) ? scsi_bin2bcd(ca_abs_m) :
		               (cnt == 32'd7) ? scsi_bin2bcd(ca_abs_s) :
		               (cnt == 32'd8) ? scsi_bin2bcd(ca_abs_f) : 8'h00;
	end
endfunction

// AUDIO STATUS (0xCC, 6 bytes): {status, 0, ADR/control, abs M, S, F};
// type 1 (CDB[3]==1) reports channel volumes instead (0xFF = full).
function [7:0] cd_astat_byte;
	input [31:0] cnt;
	begin
		cd_astat_byte = (cnt == 32'd0) ? ((cmd[3] == 8'd1) ? 8'hFF : ca_ast_code) :
		                (cnt == 32'd1) ? ((cmd[3] == 8'd1) ? 8'hFF : 8'h00) :
		                (cnt == 32'd2) ? ca_cur_ctrl :
		                (cnt == 32'd3) ? scsi_bin2bcd(ca_abs_m) :
		                (cnt == 32'd4) ? scsi_bin2bcd(ca_abs_s) :
		                (cnt == 32'd5) ? scsi_bin2bcd(ca_abs_f) : 8'h00;
	end
endfunction

wire [7:0] cd_subq_dout        = cd_subq_byte(data_cnt);
wire [7:0] cd_subq_dout_next   = cd_subq_byte(data_cnt_next);
wire [7:0] cd_subq_dout_next2  = cd_subq_byte(data_cnt_next2);
wire [7:0] cd_subq_dout_next3  = cd_subq_byte(data_cnt_next3);
// standard 0x42 READ SUB-CHANNEL, format 1 (current position), MSF form,
// 16 bytes: {00, status, u16be len=12, 01, adr_ctrl, track, index=1,
// {0,M,S,F} abs, {0,M,S,F} rel} — binary values (Snow is the reference).
// Formats 2 (MCN/UPC) and 3 (ISRC) — gap item 1 of docs/SCSI_CMD_GAPS.md,
// closed 2026-07-29 — serve the honest BlueSCSI-style layouts: correct
// header (audio status + u16be data length 20), format echo at byte 4,
// and VALID=0 with zeroed digits (no disc metadata exists in the image
// containers we serve, and that is the truthful SCSI answer). Format 0
// and unknown formats keep today's position-layout serve (defensive:
// never observed, and CHECKing them — Snow's choice — risks proven
// driver paths for no gain).
function [7:0] cd_subq43_byte;
	input [31:0] cnt;
	begin
		cd_subq43_byte =
		    (cmd[3] == 8'h02) ? (            // MCN: 24 B, MCVAL=0, digits 0
		                 (cnt == 32'd1)  ? ca_ast_std :
		                 (cnt == 32'd3)  ? 8'd20 :
		                 (cnt == 32'd4)  ? 8'h02 : 8'h00) :
		    (cmd[3] == 8'h03) ? (            // ISRC: 24 B, TCVAL=0, track echo
		                 (cnt == 32'd1)  ? ca_ast_std :
		                 (cnt == 32'd3)  ? 8'd20 :
		                 (cnt == 32'd4)  ? 8'h03 :
		                 (cnt == 32'd6)  ? cmd[6] : 8'h00) :
		                 (                   // format 1 (and 0/unknown fallback)
		                 (cnt == 32'd1)  ? ca_ast_std :
		                 (cnt == 32'd3)  ? 8'd12 :
		                 (cnt == 32'd4)  ? 8'h01 :
		                 (cnt == 32'd5)  ? ca_cur_ctrl :
		                 (cnt == 32'd6)  ? ca_cur_trk :
		                 (cnt == 32'd7)  ? 8'h01 :
		                 (cnt == 32'd9)  ? ca_abs_m :
		                 (cnt == 32'd10) ? ca_abs_s :
		                 (cnt == 32'd11) ? ca_abs_f :
		                 (cnt == 32'd13) ? ca_rel_m :
		                 (cnt == 32'd14) ? ca_rel_s :
		                 (cnt == 32'd15) ? ca_rel_f : 8'h00);
	end
endfunction
wire [7:0] cd_subq43_dout       = cd_subq43_byte(data_cnt);
wire [7:0] cd_subq43_dout_next  = cd_subq43_byte(data_cnt_next);
wire [7:0] cd_subq43_dout_next2 = cd_subq43_byte(data_cnt_next2);
wire [7:0] cd_subq43_dout_next3 = cd_subq43_byte(data_cnt_next3);
function [7:0] t43_hdr_fix;      // filtered length in bytes 0/1; ZERO past the
	input [31:0] cnt;            // real payload (serving pads to the armed
	input [7:0]  raw;            // allocation length — see the data_len note)
	begin
		t43_hdr_fix = (cnt >= {22'd0, ca_t43_tot}) ? 8'h00 :
		              (cnt == 32'd0) ? {6'd0, ca_t43_flen[9:8]} :
		              (cnt == 32'd1) ? ca_t43_flen[7:0] : raw;
	end
endfunction
wire [7:0] cd_toc43_dout        = ca_toc_ready ? t43_hdr_fix(data_cnt,       ca_t43_q0) : 8'h00;
wire [7:0] cd_toc43_dout_next   = ca_toc_ready ? t43_hdr_fix(data_cnt_next,  ca_t43_q1) : 8'h00;
wire [7:0] cd_toc43_dout_next2  = ca_toc_ready ? t43_hdr_fix(data_cnt_next2, ca_t43_q2) : 8'h00;
wire [7:0] cd_toc43_dout_next3  = ca_toc_ready ? t43_hdr_fix(data_cnt_next3, ca_t43_q3) : 8'h00;

// format-2 FULL TOC / format-1 SESSION INFO: pre-rendered T2 plane, linear
// addressing (the plane IS the response image; session page at [496..507]).
// Zero-fill past the real payload — serving pads to the armed allocation
// per the serving law; the u16be length fields carry the true sizes.
wire [7:0]  ca_t2_q0, ca_t2_q1, ca_t2_q2, ca_t2_q3;
wire [9:0]  ca_t2_len;
wire        ca_disc_audio;
wire [8:0]  ca_t2_addr = (cmd_cd_t43f1 ? 9'd496 : 9'd0) + data_cnt[8:0];
function [7:0] t2_fix;           // full TOC: zero past toc2_len
	input [31:0] cnt;
	input [7:0]  raw;
	t2_fix = (cnt >= {22'd0, ca_t2_len}) ? 8'h00 : raw;
endfunction
function [7:0] sess_fix;         // session-info page: 12 real bytes
	input [31:0] cnt;
	input [7:0]  raw;
	sess_fix = (cnt >= 32'd12) ? 8'h00 : raw;
endfunction
wire [7:0] cd_toc2_dout        = !ca_toc_ready ? 8'h00 :
                                 cmd_cd_t43f1 ? sess_fix(data_cnt, ca_t2_q0) : t2_fix(data_cnt, ca_t2_q0);
wire [7:0] cd_toc2_dout_next   = !ca_toc_ready ? 8'h00 :
                                 cmd_cd_t43f1 ? sess_fix(data_cnt_next, ca_t2_q1) : t2_fix(data_cnt_next, ca_t2_q1);
wire [7:0] cd_toc2_dout_next2  = !ca_toc_ready ? 8'h00 :
                                 cmd_cd_t43f1 ? sess_fix(data_cnt_next2, ca_t2_q2) : t2_fix(data_cnt_next2, ca_t2_q2);
wire [7:0] cd_toc2_dout_next3  = !ca_toc_ready ? 8'h00 :
                                 cmd_cd_t43f1 ? sess_fix(data_cnt_next3, ca_t2_q3) : t2_fix(data_cnt_next3, ca_t2_q3);

wire [7:0] cd_astat_dout       = cd_astat_byte(data_cnt);
wire [7:0] cd_astat_dout_next  = cd_astat_byte(data_cnt_next);
wire [7:0] cd_astat_dout_next2 = cd_astat_byte(data_cnt_next2);
wire [7:0] cd_astat_dout_next3 = cd_astat_byte(data_cnt_next3);

// MODE SENSE(6): 4-byte header + 8-byte block descriptor = 12 bytes.
// Header byte 0 = mode data length = total-1 = 11, so a driver that trusts
// the length field reads exactly what we serve (it was 0, which told
// length-honoring drivers "nothing follows the header" while we kept
// serving — REQ-held wedge class).
// BlueSCSI Toolbox detection page (docs/BLUESCSI_HANDOFF.md §2): when the
// client requests vendor page 0x31 (CDB[2][5:0]==0x31) serve a 56-byte response
// carrying the magic string it matches on, instead of the 12-byte default.
// Page select is combinational on the latched CDB, stable through the data
// phase; data_len switches 12<->56 on the same select. Other pages unchanged.
// Gated on tb_ready: advertise the Toolbox detection page ONLY once the HPS
// handler has mounted the slot. On a stock Main (no handler) tb_ready=0, so a
// page-0x31 request falls through to the default mode page and the target looks
// like a plain disk -> the Mac client never engages -> no app-close hang (§4a).
wire       mode_sense_p31 = TOOLBOX_ENABLE && tb_ready && cmd_mode_sense && (cmd[2][5:0] == 6'h31);

// 56-byte page-0x31 response (self-contained; block-descriptor #blocks=0 per the
// spec example -- the client only validates the page string). 4 header + 8 block
// descriptor + 2 page header + 42 string. DBD ignored (descriptor always
// present, length byte = 8), matching the default response.
function [7:0] mode_sense_p31_byte;
	input [31:0] cnt;
	begin
		mode_sense_p31_byte =
			(cnt == 32'd0 )?8'd55:   // mode data length = 56 - 1
			(cnt == 32'd3 )?8'd8:    // block descriptor length
			(cnt == 32'd10)?8'd2:    // block length 0x000200 (512); #blocks = 0
			(cnt == 32'd12)?8'h31:   // page code 0x31
			(cnt == 32'd13)?8'h2a:   // page length = 42
			(cnt == 32'd14)?"B":(cnt == 32'd15)?"l":(cnt == 32'd16)?"u":(cnt == 32'd17)?"e":
			(cnt == 32'd18)?"S":(cnt == 32'd19)?"C":(cnt == 32'd20)?"S":(cnt == 32'd21)?"I":
			(cnt == 32'd22)?" ":(cnt == 32'd23)?"i":(cnt == 32'd24)?"s":(cnt == 32'd25)?" ":
			(cnt == 32'd26)?"t":(cnt == 32'd27)?"h":(cnt == 32'd28)?"e":(cnt == 32'd29)?" ":
			(cnt == 32'd30)?"B":(cnt == 32'd31)?"E":(cnt == 32'd32)?"S":(cnt == 32'd33)?"T":
			(cnt == 32'd34)?" ":(cnt == 32'd35)?"S":(cnt == 32'd36)?"T":(cnt == 32'd37)?"O":
			(cnt == 32'd38)?"L":(cnt == 32'd39)?"E":(cnt == 32'd40)?"N":(cnt == 32'd41)?" ":
			(cnt == 32'd42)?"F":(cnt == 32'd43)?"R":(cnt == 32'd44)?"O":(cnt == 32'd45)?"M":
			(cnt == 32'd46)?" ":(cnt == 32'd47)?"B":(cnt == 32'd48)?"L":(cnt == 32'd49)?"U":
			(cnt == 32'd50)?"E":(cnt == 32'd51)?"S":(cnt == 32'd52)?"C":(cnt == 32'd53)?"S":
			(cnt == 32'd54)?"I":     // byte 55 = NUL (falls through); rest = 0
			8'h00;
	end
endfunction

// CDROM MODE SENSE(6). Header + 8-byte block descriptor (12 bytes): device-
// specific byte = 0x80 (write-protected), block length 0x000800 (2048),
// #blocks = capacity (2048-block last LBA, same byte slots as the disk
// response). Page 0x30 appends the 24-byte "magic Apple page" (0x30, 0x00,
// "APPLE COMPUTER, INC   ") — byte-exact from MAME apple_magic, which some
// Apple drivers/utilities probe even on CD drives. Other pages: header+desc
// only (proven pattern of the disk response).
function [7:0] cd_mode_sense_byte;
	input [31:0] cnt;
	begin
		cd_mode_sense_byte =
			(cnt == 32'd0 )?(cd_ms30 ? 8'd35 : 8'd11):  // mode data length = total-1
			(cnt == 32'd2 )?8'h80:                      // WP (read-only medium)
			(cnt == 32'd3 )?8'd8:                       // block descriptor length
			(cnt == 32'd5 )?capacity[23:16]:
			(cnt == 32'd6 )?capacity[15:8]:
			(cnt == 32'd7 )?capacity[7:0]:
			(cnt == 32'd10)?8'h08:                      // block length 0x000800 = 2048
			(cnt == 32'd12)?8'h30:                      // page code (0x30 request only)
			(cnt == 32'd14)?"A":(cnt == 32'd15)?"P":
			(cnt == 32'd16)?"P":(cnt == 32'd17)?"L":
			(cnt == 32'd18)?"E":(cnt == 32'd19)?" ":
			(cnt == 32'd20)?"C":(cnt == 32'd21)?"O":
			(cnt == 32'd22)?"M":(cnt == 32'd23)?"P":
			(cnt == 32'd24)?"U":(cnt == 32'd25)?"T":
			(cnt == 32'd26)?"E":(cnt == 32'd27)?"R":
			(cnt == 32'd28)?",":(cnt == 32'd29)?" ":
			(cnt == 32'd30)?"I":(cnt == 32'd31)?"N":
			(cnt == 32'd32)?"C":
			((cnt >= 32'd33) && (cnt <= 32'd35))?" ":
			8'h00;
	end
endfunction

// CDROM MODE SENSE(6) page 0x0E (CD Audio Control): the standard 12-byte
// header+descriptor, then {0x0E, len 14, IMMED, 0,0,0, 75, 75, four
// {channel, volume} pairs} — Snow's CDU-8004 layout. The port bytes echo
// the MODE SELECT-writable state above, so the AppleCD player's volume
// slider reads back its real position instead of snapping to default.
function [7:0] cd_ms0e_byte;
	input [31:0] cnt;
	begin
		cd_ms0e_byte =
			(cnt == 32'd0 )?8'd27:                      // mode data length = 28-1
			(cnt == 32'd2 )?8'h80:                      // WP (read-only medium)
			(cnt == 32'd3 )?8'd8:                       // block descriptor length
			(cnt == 32'd5 )?capacity[23:16]:
			(cnt == 32'd6 )?capacity[15:8]:
			(cnt == 32'd7 )?capacity[7:0]:
			(cnt == 32'd10)?8'h08:                      // block length 0x000800 = 2048
			(cnt == 32'd12)?8'h0E:                      // page code
			(cnt == 32'd13)?8'h0E:                      // page length = 14
			(cnt == 32'd14)?8'h04:                      // IMMED=1, SOTC=0
			(cnt == 32'd18)?8'd75:                      // obsolete (75, Snow)
			(cnt == 32'd19)?8'd75:
			(cnt == 32'd20)?cd_ap_ch0:
			(cnt == 32'd21)?cd_ap_vol0:
			(cnt == 32'd22)?cd_ap_ch1:
			(cnt == 32'd23)?cd_ap_vol1:
			(cnt == 32'd24)?cd_ap_ch2:
			(cnt == 32'd25)?cd_ap_vol2:
			(cnt == 32'd26)?cd_ap_ch3:
			(cnt == 32'd27)?cd_ap_vol3:
			8'h00;
	end
endfunction

// CDROM MODE SENSE(6) page 0x2A (MM Capabilities and Mechanical Status): the
// standard 12-byte header+descriptor, then {0x2A, len 0x18, 24 payload bytes}
// = 38 total. Payload bytes are Snow's (mod.rs 0x2A), which is [MMC4] E.3.3
// truncated at byte 26 as a non-CD-R drive should:
//   [2] 0x71 multi-session | Mode 2 Form 2 | Mode 2 Form 1 | audio play
//   [4] 0x28 tray loading mechanism | eject
//   [5] 0x03 separate channel mute | separate volume levels
//   [8:9] 256 volume levels supported (matches the page 0x0E port range)
function [7:0] cd_ms2a_byte;
	input [31:0] cnt;
	begin
		cd_ms2a_byte =
			(cnt == 32'd0 )?8'd37:                      // mode data length = 38-1
			(cnt == 32'd2 )?8'h80:                      // WP (read-only medium)
			(cnt == 32'd3 )?8'd8:                       // block descriptor length
			(cnt == 32'd5 )?capacity[23:16]:
			(cnt == 32'd6 )?capacity[15:8]:
			(cnt == 32'd7 )?capacity[7:0]:
			(cnt == 32'd10)?8'h08:                      // block length 0x000800 = 2048
			(cnt == 32'd12)?8'h2A:                      // page code
			(cnt == 32'd13)?8'h18:                      // page length = 24
			(cnt == 32'd16)?8'h71:                      // payload[2]
			(cnt == 32'd18)?8'h28:                      // payload[4]
			(cnt == 32'd19)?8'h03:                      // payload[5]
			(cnt == 32'd22)?8'h01:                      // payload[8]  256 volume
			(cnt == 32'd23)?8'h00:                      // payload[9]  levels
			8'h00;
	end
endfunction

// Page select: CDROM response, else 0x31 detection page vs. the default.
wire [7:0] mode_sense_dout       = (CDROM != 0)   ? (cd_ms0e ? cd_ms0e_byte(data_cnt) : cd_ms2a ? cd_ms2a_byte(data_cnt)       : cd_ms31 ? mode_sense_p31_byte(data_cnt)       : cd_mode_sense_byte(data_cnt))
                                 : mode_sense_p31 ? mode_sense_p31_byte(data_cnt)       : mode_sense_def_dout;
wire [7:0] mode_sense_dout_next  = (CDROM != 0)   ? (cd_ms0e ? cd_ms0e_byte(data_cnt_next) : cd_ms2a ? cd_ms2a_byte(data_cnt_next)  : cd_ms31 ? mode_sense_p31_byte(data_cnt_next)  : cd_mode_sense_byte(data_cnt_next))
                                 : mode_sense_p31 ? mode_sense_p31_byte(data_cnt_next)  : mode_sense_def_dout_next;
wire [7:0] mode_sense_dout_next2 = (CDROM != 0)   ? (cd_ms0e ? cd_ms0e_byte(data_cnt_next2) : cd_ms2a ? cd_ms2a_byte(data_cnt_next2) : cd_ms31 ? mode_sense_p31_byte(data_cnt_next2) : cd_mode_sense_byte(data_cnt_next2))
                                 : mode_sense_p31 ? mode_sense_p31_byte(data_cnt_next2) : mode_sense_def_dout_next2;
wire [7:0] mode_sense_dout_next3 = (CDROM != 0)   ? (cd_ms0e ? cd_ms0e_byte(data_cnt_next3) : cd_ms2a ? cd_ms2a_byte(data_cnt_next3) : cd_ms31 ? mode_sense_p31_byte(data_cnt_next3) : cd_mode_sense_byte(data_cnt_next3))
                                 : mode_sense_p31 ? mode_sense_p31_byte(data_cnt_next3) : mode_sense_def_dout_next3;

// Default MODE SENSE(6) response (unchanged; served for every page except 0x31).
wire [7:0] mode_sense_def_dout =
		(data_cnt == 32'd0 )?8'd11:
		(data_cnt == 32'd3 )?8'd8:
		(data_cnt == 32'd5 )?capacity[23:16]:
		(data_cnt == 32'd6 )?capacity[15:8]:
		(data_cnt == 32'd7 )?capacity[7:0]:
		(data_cnt == 32'd10 )?8'd2:
		8'h00;
wire [7:0] mode_sense_def_dout_next =
		(data_cnt_next == 32'd0 )?8'd11:
		(data_cnt_next == 32'd3 )?8'd8:
		(data_cnt_next == 32'd5 )?capacity[23:16]:
		(data_cnt_next == 32'd6 )?capacity[15:8]:
		(data_cnt_next == 32'd7 )?capacity[7:0]:
		(data_cnt_next == 32'd10 )?8'd2:
		8'h00;
wire [7:0] mode_sense_def_dout_next2 =
		(data_cnt_next2 == 32'd0 )?8'd11:
		(data_cnt_next2 == 32'd3 )?8'd8:
		(data_cnt_next2 == 32'd5 )?capacity[23:16]:
		(data_cnt_next2 == 32'd6 )?capacity[15:8]:
		(data_cnt_next2 == 32'd7 )?capacity[7:0]:
		(data_cnt_next2 == 32'd10 )?8'd2:
		8'h00;
wire [7:0] mode_sense_def_dout_next3 =
		(data_cnt_next3 == 32'd0 )?8'd11:
		(data_cnt_next3 == 32'd3 )?8'd8:
		(data_cnt_next3 == 32'd5 )?capacity[23:16]:
		(data_cnt_next3 == 32'd6 )?capacity[15:8]:
		(data_cnt_next3 == 32'd7 )?capacity[7:0]:
		(data_cnt_next3 == 32'd10 )?8'd2:
		8'h00;

// buffer to store incoming commands
reg [3:0]  cmd_cnt;
reg [7:0]  cmd [9:0];

// ========================================================================
// BlueSCSI Toolbox transport (TOOLBOX_ENABLE) — dedicated-slot HPS round-trip
// for the DataIn filesystem ops 0xD0 LIST / 0xD1 GET / 0xD2 COUNT.
// docs/BLUESCSI_CORE_HPS_CONTRACT.md. The disk read/write path is untouched.
//
//   [SEND DATA only] collect the 512-byte DataOut payload at buffer byte 16,
//                    then tb_wr @LBA1 (its 16-byte tail, buffer sector 1) ->
//   load CDB into tb buffer -> tb_wr @LBA0 (HPS runs the handler) ->
//   tb_rd @LBA0 (status + 0xB5 signature + length) ->
//   tb_rd @LBA1+k (ceil(len/512) data blocks) -> serve via PHASE_DATA_OUT.
//
// The round-trip handshake, the buffer byte-lane order and the status-latch
// settle are modelled on the proven disk path; the SERVE reuses the disk buffer
// machinery verbatim so its timing is inherited. Desk coverage:
// `verilator/scsi_bench --mode toolbox` (COUNT/LIST/SEND/GET round trips
// against a mirror of Main's handler).
// ========================================================================
// 4 bits since the streaming work (2026-07-31): the original 8 codes were all
// taken, and TBS_STREAM / TBS_COLL / TBS_COLLW are what let a transfer be
// larger than the buffer that carries it.
localparam TBS_IDLE=4'd0, TBS_LOAD=4'd1, TBS_REQ=4'd2, TBS_STAT=4'd3,
           TBS_LATCH=4'd4, TBS_DATA=4'd5, TBS_RDY=4'd6, TBS_REQ2=4'd7,
           TBS_STREAM=4'd8,   // GET: keep fetching while the Mac is served
           TBS_COLL=4'd9,     // SEND: watch the DataOut phase fill sectors
           TBS_COLLW=4'd10,   // SEND: a streamed sector write is in flight
           TBS_LATCH2=4'd11;  // status block: settle + read the length's bit 16
reg [3:0]  tb_state = TBS_IDLE;
reg        tb_rd_r, tb_wr_r;
reg [31:0] tb_lba_r;
reg [7:0]  tb_status;
// 17 bits (2026-07-31). The status block's BE16 length field cannot express
// 65536, and that is exactly what a CDB[6]=16 GET asks for -- the official
// client zero-fills whatever it does not receive and advances by the full
// request, so a 16-bit length costs one corrupted byte per 64 KB chunk and
// fails an md5 round trip. Status-block byte 4 (reserved-zero until now)
// carries bit 16. Found by the HPS session, 2026-07-31.
reg [16:0] tb_len;
reg [3:0]  tb_load_w;
reg [3:0]  tb_settle;   // status-latch settle for the registered port-B (q_b) reads
                        // of the status block (word 0 = status/sig, word 1 = length).
reg [17:0] tb_to;       // tb read-completion watchdog (~8-17 ms); see TBS_STAT.
reg        old_tb_ack;
reg [7:0]  tb_fetch_sec;    // which 512B sector the HPS transfer is landing on / reading from.
                            // 8 bits since streaming: this is now the RING SLOT for a
                            // response/chunk of up to 128 sectors, not a buffer index --
                            // tb_hps_addr13 slices it back down to the buffer's 16 slots.
// ---- streaming state (2026-07-31) ---------------------------------------
// GET: sectors of the current response that are fully in the buffer. The serve
// stalls when it reaches this; the fetch stalls when it is TB_MAXSEC ahead of
// the serve (it would otherwise overwrite bytes the Mac has not taken yet).
reg [8:0]  tb_sec_done;
reg        tb_fetch_busy;   // a streamed sector read is outstanding
// SEND: the ring slot being filled and the LOGICAL sector it maps to. Slot 0 is
// reserved for the CDB block (it must ship LAST, because LBA 0 is what runs the
// HPS handler), so the payload ring is slots 1..TB_MAXSEC-1.
reg [4:0]  tb_col_slot;
reg [7:0]  tb_col_lba;
reg [7:0]  tb_ship_done;    // logical sectors handed to the HPS so far
// A payload sector that exhausted its ship retries. Main cannot detect a
// missing tail block (its tb_tail[] is static and never cleared, so the
// previous chunk's bytes stand in for it), so the CORE has to be the one that
// refuses to call the chunk good -- see TBS_COLLW and the override in
// TBS_LATCH. (2026-08-01, after HW-confirmed silent upload corruption.)
reg        tb_send_fault;
reg [4:0]  tb_ship_slot;    // rotating ring slot of the NEXT sector to ship (1..TB_MAXSEC-1)
// SEND write position, in 512-byte blocks, accumulated across the session.
// HW 2026-08-01: with block-encoded chunks the official client advances
// CDB[3..5] by ONE PER CHUNK -- a chunk index, not the 512-block offset the
// HPS seeks with. Every 65024-byte chunk therefore landed 512 bytes past the
// previous one and a 2 MB upload collapsed to 80,896 bytes (= 31*512 + 65024,
// measured exactly; confirmed by content -- the slot at k*512 held chunk k's
// first 512 bytes, for all 32 chunks). We substitute our own running position
// when writing the CDB, so the HPS contract stays 'offset in 512-blocks' and
// needs no change. v0 512-byte sends reproduce the client's own numbering.
reg [23:0] tb_send_pos = 24'd0;
reg  [9:0] tb_retry;        // status-block re-looks / data-fetch re-arms / ship re-arms (per sector)
// A slow HPS answer must not read as "no handler". The SD is mounted
// sync,dirsync, so one SEND chunk is a synchronous card write; when the card
// hits an erase cycle it stalls far past one watchdog period. Re-look up to
// TB_RETRY_MAX times (~0.8 s total) before giving up. (2026-07-31)
localparam [9:0] TB_RETRY_MAX = 10'd96;
// DATA-TRANSFER re-arms (SEND ships AND GET fetches) get a much larger budget
// than the ~0.8 s used above, and
// the reason is measured, not guessed: the HPS blocks its own poll loop on
// unrelated work (a screenshot encode, an md5 of a file on the same card, any
// OSD/file I/O), and 0.8 s is well inside that. HW 2026-08-02: with the ship
// budget at 96 an upload aborted mid-file with CHECK whenever such a stall
// landed — visibly, but a failed 2 MB upload all the same. 4.2 s rides those
// out while staying bounded, and the guest waits happily (the data phase is
// PIO; only a genuinely dead HPS reaches the cap, and then CHECK is right).
// Pre-fix builds did not "survive" these stalls -- they silently corrupted the
// file, which is the whole defect this path exists to end.
//
// Applied to the GET fetch retries too (2026-08-02): TBS_DATA/TBS_STREAM had
// the same 0.8 s cap, so the identical stall would have aborted a DOWNLOAD via
// tb_get_fault. Never observed in the field -- downloads survived every stall
// this session -- but it is the same latent failure as the one measured on the
// SEND side, and there is no reason for the two directions to differ.
// The status-block re-looks above keep TB_RETRY_MAX: that path is HW-proven at
// 96 and its stall (a synchronous card write) is bounded differently.
localparam [9:0] TB_STALL_RETRY_MAX = 10'd512;
// GET data-fetch retry budget exhausted while the serve was mid-phase: force
// the data phase closed (data_done) and turn the status byte into CHECK — see
// TBS_STREAM. One-shot per round trip, cleared in TBS_IDLE.
reg        tb_get_fault = 1'b0;

// Shared-folder availability: latches when the HPS mounts the Toolbox slot.
// Until then (incl. a stock Main with no handler) fs ops return CHECK (§4a).
reg tb_ready = 1'b0;
always @(posedge clk) if ((TOOLBOX_ENABLE || CDCHANGER_ENABLE) && tb_mounted) tb_ready <= 1'b1;

// Toolbox buffer: one 512-byte sector, byte-split (even->buf0, odd->buf1) with
// the SAME HPS lane mapping as the disk buffer so bytes arrive in order.
wire [7:0] tb_buf0_qa, tb_buf1_qa;     // HPS read-back (the CDB, during request)
`ifdef VERILATOR
wire [7:0] tb_buf0_da = sd_buff_dout[15:8];
wire [7:0] tb_buf1_da = sd_buff_dout[7:0];
assign tb_buff_din = {tb_buf0_qa, tb_buf1_qa};
`else
wire [7:0] tb_buf0_da = sd_buff_dout[7:0];
wire [7:0] tb_buf1_da = sd_buff_dout[15:8];
assign tb_buff_din = {tb_buf1_qa, tb_buf0_qa};
`endif

wire       tb_hps_wr  = sd_buff_wr & tb_ack;            // HPS fills the slot
// SEND (upload) payload collection: during the DataOut phase the Mac's bytes are
// written into the toolbox buffer at WORD offset 8 (byte 16), leaving words 0..4
// (bytes 0..9) for the CDB that TBS_LOAD writes -- so one round-trip block carries
// both (the contract's "payload at buffer[16..]" single-block layout). Even byte
// -> buf0, odd -> buf1, mirroring the CDB/serve byte split.
wire       tb_collect = (phase == PHASE_DATA_IN) && cmd_tb_send;
wire       tb_col_wr0 = tb_collect && stb_ack && ~data_cnt[0];
wire       tb_col_wr1 = tb_collect && stb_ack &&  data_cnt[0];
// tb buffer word address, computed at 11b (max = 8 sectors) then sliced to
// TB_ADDRW. On single-sector targets (TB_ADDRW=8) the high bits are always 0
// (tb_fetch_sec=0, data_cnt<512), so the slice reproduces the old data_cnt[8:1].
// 13 bits so a multi-block SEND fits: a 4 KB chunk sits at bytes 16..4111, i.e.
// words 8..2055, which overflows the old 11-bit form (and the old collect slice
// data_cnt[8:1] wrapped the payload back onto itself at 512 bytes).
// Collect addressing (streaming, 2026-07-31). The payload still starts at block
// byte 16 -- the HPS contract is unchanged -- so payload byte P sits at LINEAR
// block byte 16+P. What changed is that the linear byte no longer indexes the
// buffer directly: it is split into (logical sector, word-in-sector), and the
// sector is replaced by the ring slot tb_col_slot. That is what decouples the
// chunk size from the buffer size. Slot 0 holds the CDB + payload bytes 0..495
// and is never recycled; slots 1..TB_MAXSEC-1 rotate.
wire [16:0] tb_col_lin  = {1'b0, data_cnt[15:0]} + 17'd16;   // linear block byte
wire [7:0]  tb_col_word = tb_col_lin[8:1];                   // word within the sector
wire [12:0] tb_b_addr13 = (tb_state == TBS_LOAD)   ? {9'd0, tb_load_w}
                        : (tb_state == TBS_LATCH2) ? 13'd2   // status bytes 4,5
                        : tb_collect               ? {tb_col_slot, tb_col_word}
                        :                             data_cnt[13:1];
// A sector is complete when the Mac acks the byte at offset 511 of it. The
// serve side needs no equivalent: its address is data_cnt[13:1] sliced to
// TB_ADDRW, which is already (byte/2) mod 4096 -- a 16-sector ring by
// construction, which is why the GET side needs no new addressing at all.
wire tb_col_sec_full = tb_collect && stb_ack && (tb_col_lin[8:0] == 9'h1ff);
// SEND back-pressure: the collect is about to reuse a ring slot whose previous
// occupant has not shipped yet. Defined HERE rather than with the other stalls
// because the 0xD4 inter-byte watchdog below must be able to see it.
wire tb_col_stall = tb_collect && ((tb_col_lba - tb_ship_done) >= (TB_MAXSEC - 5'd1));
// Sectors 1..tb_col_lba-1 are complete; anything past tb_ship_done is waiting to
// go. tb_col_lba == 0 means the collect has not produced a full sector yet (or
// the final short one was already handed over), so nothing is pending.
wire tb_ship_pending = (tb_col_lba != 8'd0) && (tb_ship_done < (tb_col_lba - 8'd1));
wire [TB_ADDRW-1:0] tb_b_addr = tb_b_addr13[TB_ADDRW-1:0];
// HPS fill address: sector tb_fetch_sec at word offset tb_fetch_sec*256, so a
// multi-sector LIST lands contiguously (LBA 1+k -> words k*256..k*256+255).
wire [12:0] tb_hps_addr13 = {tb_fetch_sec[4:0], sd_buff_addr[7:0]};
wire [TB_ADDRW-1:0] tb_hps_addr = tb_hps_addr13[TB_ADDRW-1:0];
wire       tb_b_wr0   = (tb_state == TBS_LOAD) || tb_col_wr0;
wire       tb_b_wr1   = (tb_state == TBS_LOAD) || tb_col_wr1;
// Block-encoded 0xD4 only: byte3 = word1 lane1, byte4/5 = word2 lane0/1.
wire       tb_send_fixoff = cmd_tb_send_data && (cmd[6] > 8'd1);
wire [7:0] tb_load_b0 = (tb_send_fixoff && (tb_load_w == 4'd2)) ? tb_send_pos[15:8]
                      : cmd[{tb_load_w[2:0], 1'b0}];   // even CDB byte
wire [7:0] tb_load_b1 = (tb_send_fixoff && (tb_load_w == 4'd1)) ? tb_send_pos[23:16]
                      : (tb_send_fixoff && (tb_load_w == 4'd2)) ? tb_send_pos[7:0]
                      : cmd[{tb_load_w[2:0], 1'b1}];   // odd  CDB byte
wire [7:0] tb_b_d0    = (tb_state == TBS_LOAD) ? tb_load_b0 : din;   // CDB even byte, else payload byte
wire [7:0] tb_b_d1    = (tb_state == TBS_LOAD) ? tb_load_b1 : din;   // CDB odd  byte, else payload byte

wire [7:0] tb0_dout, tb0_dout_next, tb0_dout_next2;
wire [7:0] tb1_dout, tb1_dout_next, tb1_dout_next2;
scsi_dpram #(.ADDRWIDTH(TB_ADDRW)) tb_buf0 (
	.clock(clk),
	.address_a(tb_hps_addr), .data_a(tb_buf0_da), .wren_a(tb_hps_wr), .q_a(tb_buf0_qa),
	.address_b(tb_b_addr), .data_b(tb_b_d0), .wren_b(tb_b_wr0), .q_b(tb0_dout),
	.address_c(tb_b_addr + 1'b1), .q_c(tb0_dout_next),
	.address_d(tb_b_addr + 2'd2), .q_d(tb0_dout_next2)
);
scsi_dpram #(.ADDRWIDTH(TB_ADDRW)) tb_buf1 (
	.clock(clk),
	.address_a(tb_hps_addr), .data_a(tb_buf1_da), .wren_a(tb_hps_wr), .q_a(tb_buf1_qa),
	.address_b(tb_b_addr), .data_b(tb_b_d1), .wren_b(tb_b_wr1), .q_b(tb1_dout),
	.address_c(tb_b_addr + 1'b1), .q_c(tb1_dout_next),
	.address_d(tb_b_addr + 2'd2), .q_d(tb1_dout_next2)
);

// Serve sources (mirror the disk read: even byte from buf0, odd from buf1).
wire  [7:0] tb_serve           = data_cnt[0] ? tb1_dout : tb0_dout;
wire [15:0] tb_serve_pair      = data_cnt[0] ? {tb1_dout, tb0_dout_next} : {tb0_dout, tb1_dout};
wire [15:0] tb_serve_pair_next = data_cnt[0] ? {tb1_dout_next, tb0_dout_next2} : {tb0_dout_next, tb1_dout_next};

// Multi-sector LIST fetch (TB_ADDRW>8): the HPS returns tb_len bytes across
// ceil(tb_len/512) sectors (LBA 1..N). TB_MAXSEC bounds it to the buffer; with
// TB_ADDRW=8 => TB_MAXSEC=1 => single-block (file Toolbox behaviour preserved).
localparam [4:0] TB_MAXSEC = 1 << (TB_ADDRW - 8);   // buffer RING slots: TB_ADDRW=12 => 16
// Sectors a single response/chunk may span. No longer bounded by the buffer:
// the serve streams through the ring (TBS_STREAM), so this is bounded by the
// wire protocol instead -- 128 sectors = 64 KB, which covers the official
// client's 16-block (65536 B) GET and 127-block (65024 B) SEND.
localparam [8:0] TB_SEC_MAX = 9'd128;
wire [8:0] tb_nsec_raw = {1'd0, tb_len[16:9]} + {8'd0, |tb_len[8:0]};  // ceil(tb_len/512)
wire [8:0] tb_nsec = (tb_nsec_raw == 9'd0)          ? 9'd1
                   : (tb_nsec_raw > TB_SEC_MAX)     ? TB_SEC_MAX
                   :                                  tb_nsec_raw;
// The served length is now bounded by TB_SEC_MAX, not by the buffer: the ring
// refills behind the serve. The clamp still matters -- an HPS response longer
// than we will ever fetch must not be served from stale words (the
// alloc-overserve wedge class) -- it just sits 8x higher than before.
localparam [16:0] TB_SRV_MAX = {TB_SEC_MAX, 8'd0} << 1;        // TB_SEC_MAX * 512 = 64 KB
wire [16:0] tb_srv_len = (tb_len > TB_SRV_MAX) ? TB_SRV_MAX : tb_len;
// Where the serve has got to, in sectors, and where a longword pseudo-DMA read
// can reach (it captures data_cnt..+3 in one bus cycle, so the sector holding
// +3 must be resident too -- the same look-ahead the disk read path needs, and
// the same class of bug as the 2026-07-29 rd_ahead_blk defect).
wire [8:0]  tb_srv_sec       = {1'b0, data_cnt[16:9]};
wire [16:0] tb_srv_byte_ah   = data_cnt[16:0] + 17'd3;
wire [8:0]  tb_srv_sec_ahead = {1'b0, tb_srv_byte_ah[16:9]};

// Round-trip FSM. Drives tb_state / tb_rd / tb_wr / tb_lba; the MAIN phase FSM
// moves `phase` (CMD_IN -> PHASE_TB -> DATA_OUT/STATUS_OUT) by watching tb_state.
always @(posedge clk) begin
	old_tb_ack <= tb_ack;
	if (rst) begin
		tb_state <= TBS_IDLE; tb_rd_r <= 1'b0; tb_wr_r <= 1'b0; tb_lba_r <= 32'd0;
		tb_status <= 8'h02; tb_len <= 17'd0; tb_load_w <= 4'd0; tb_settle <= 4'd0; tb_to <= 18'd0;
		tb_fetch_sec <= 8'd0; tb_retry <= 10'd0; tb_get_fault <= 1'b0;
		tb_sec_done <= 9'd0; tb_fetch_busy <= 1'b0; tb_col_slot <= 5'd0; tb_col_lba <= 8'd0;
		tb_ship_done <= 8'd0; tb_ship_slot <= 5'd1;
		tb_send_fault <= 1'b0;
	end else if (TOOLBOX_ENABLE || CDCHANGER_ENABLE) begin
		// NOTE (2026-08-01): there used to be a one-deep ship mailbox here
		// (tb_ship_req/slot/lba latched on every completed sector). It silently
		// DROPPED sectors: while one ship is outstanding the collect keeps
		// running -- tb_col_stall only bites 15 sectors ahead -- so a second
		// sector completing before the FSM consumed the first simply overwrote
		// it, and that sector was never sent. Invisible while ships took ~600
		// cycles; a stalled HPS (or the retry below, which legitimately holds a
		// ship for up to a watchdog period) makes it fire. The queue is now
		// implicit and cannot overflow: sectors ship strictly in order, the next
		// one is always tb_ship_done+1, and tb_ship_slot rotates with it.
		if (tb_col_sec_full) begin
			// slot 0 is the CDB block and is never recycled; the payload ring is
			// slots 1..TB_MAXSEC-1.
			tb_col_slot <= (tb_col_slot >= (TB_MAXSEC - 5'd1)) ? 5'd1 : (tb_col_slot + 5'd1);
			tb_col_lba  <= tb_col_lba + 8'd1;
		end
		case (tb_state)
		TBS_IDLE: begin
			tb_load_w <= 4'd0;
			tb_fetch_sec <= 8'd0;   // sector-0 addressing for the next LOAD/REQ/STAT
			tb_retry <= 10'd0;                    // per-round-trip
			tb_get_fault <= 1'b0;                // consumed by the phase FSM by now
			// NOTE: tb_sec_done is deliberately NOT cleared here. TBS_RDY drops
			// through to IDLE the moment the main FSM leaves PHASE_TB -- i.e.
			// while the Mac is still being served -- so clearing it here stalls
			// the serve forever (caught by scsi_bench: "COUNT DataIn stalled at
			// 0 of 1"). It is armed in TBS_LATCH, where a fetch actually starts.
			if (phase == PHASE_TB) tb_state <= TBS_LOAD;
			else if ((phase == PHASE_DATA_IN) && cmd_tb_send_pay) begin
				// SEND payload starting: arm the collect ring. Slot 0 takes the CDB
				// block (payload bytes 0..495 land in it too); it ships LAST.
				tb_col_slot <= 5'd0; tb_col_lba <= 8'd0;
				tb_ship_done <= 8'd0; tb_ship_slot <= 5'd1;
				tb_send_fault <= 1'b0;   // per-chunk
				tb_state <= TBS_COLL;
			end
		end
		// SEND streaming: hand each completed payload sector to the HPS while the
		// Mac is still filling the next one. This is what decouples the chunk size
		// from the buffer: without it a 64 KB chunk would have to be resident, and
		// the buffer is 8 KB. Ordering is unchanged from the old collect-then-ship
		// path -- payload sectors go out as LBA 1..N and the CDB block (LBA 0,
		// which is what runs the handler) still goes last, from TBS_REQ.
		TBS_COLL: begin
			if (tb_ship_pending) begin
				tb_fetch_sec <= {3'd0, tb_ship_slot};
				tb_lba_r     <= {24'd0, tb_ship_done + 8'd1};   // strictly in order
				tb_wr_r      <= 1'b1;
				tb_to        <= 18'd0;
				tb_retry     <= 10'd0;   // per-sector ship budget
				tb_state     <= TBS_COLLW;
			end else if (phase == PHASE_TB) begin
				// Phase over. Anything still in the current slot is a short final
				// sector; ship it, then the CDB block closes the round trip.
				if ((tb_col_lba != 8'd0) && (tb_col_lin[8:0] != 9'd0)) begin
					tb_fetch_sec <= {3'd0, tb_col_slot};
					tb_lba_r     <= {24'd0, tb_col_lba};
					tb_wr_r      <= 1'b1;
					tb_to        <= 18'd0;
					tb_retry     <= 10'd0;
					tb_col_lba   <= 8'd0;   // one-shot: do not ship it twice
					tb_state     <= TBS_COLLW;
				end else begin
					tb_fetch_sec <= 8'd0;
					tb_state     <= TBS_LOAD;
				end
			end else if (phase != PHASE_DATA_IN) tb_state <= TBS_IDLE;  // aborted
		end
		// The ship watchdog is a RETRY, not a completion (2026-08-01) — the SEND
		// twin of the TBS_DATA fix, and the cause of a CONFIRMED HW corruption:
		// the official client's 65024-byte chunks lost 4594 bytes per 2 MB, every
		// corrupt region carrying data from exactly one CHUNK (-127 sectors) back,
		// first bad byte at payload offset 496. Main's tb_tail[] is static and
		// never cleared between chunks (mac_toolbox.cpp copies from it
		// unconditionally), so a tail block that never lands leaves the PREVIOUS
		// chunk's bytes at that offset. It never landed because this state used to
		// count a timed-out ship as delivered: tb_ship_done advanced, TBS_COLL
		// retargeted tb_fetch_sec/tb_lba_r, and an HPS descheduled past one
		// watchdog period woke to the ADVANCED request (the write line stays up),
		// so the stalled sector was never re-sent. Now a timeout re-arms the SAME
		// ship with slot and LBA pinned, bounded by TB_RETRY_MAX; the collect
		// keeps back-pressuring via tb_col_stall meanwhile. Ack-fall completion is
		// untouched — on HW it is the primary path for uploads.
		// Bench: scsi_bench --mode toolboxsend part B (deferred-latch WRITE model)
		// fails on the old RTL with the exact HW signature (offset%512 == 496).
		TBS_COLLW: begin
			if (tb_ack) tb_wr_r <= 1'b0;
			tb_to <= tb_to + 1'b1;
			if (old_tb_ack & ~tb_ack) begin
				tb_ship_done <= tb_ship_done + 8'd1;
				tb_ship_slot <= (tb_ship_slot >= (TB_MAXSEC - 5'd1)) ? 5'd1 : (tb_ship_slot + 5'd1);
				tb_retry     <= 10'd0;
				tb_state     <= TBS_COLL;
			end else if (&tb_to) begin
				if (tb_retry != TB_STALL_RETRY_MAX) begin
					tb_retry <= tb_retry + 1'b1;
					tb_to    <= 18'd0;
					// Re-arm unless a transfer is in flight (ack high): re-raising
					// then would blip the wire as a second request.
					if (!tb_ack) tb_wr_r <= 1'b1;
				end else begin
					// ~0.8-1.6 s of re-ships and still nothing. Let the phase
					// finish rather than wedge the bus, but latch a fault so the
					// chunk reports CHECK: a lost tail block would otherwise be
					// invisible (Main writes whatever tb_tail still holds), which
					// is exactly the silent corruption this fix exists to end.
					// tb_ship_done still advances here -- the ring must keep
					// draining or tb_col_stall deadlocks the DataOut phase.
					tb_send_fault <= 1'b1;
					tb_ship_done  <= tb_ship_done + 8'd1;
					tb_ship_slot  <= (tb_ship_slot >= (TB_MAXSEC - 5'd1)) ? 5'd1 : (tb_ship_slot + 5'd1);
					tb_wr_r       <= 1'b0;
					tb_state      <= TBS_COLL;
				end
			end
		end
		// write the 10-byte CDB as 5 words (0..4) into the tb buffer
		// Every payload sector has already been shipped by TBS_COLL/TBS_COLLW by
		// the time we get here, so the CDB block always goes straight out. (This
		// used to detour through TBS_REQ2 to push the tail sectors first; that is
		// now done during the data phase, which is the whole point of streaming.)
		TBS_LOAD:
			if (tb_load_w == 4'd4) begin
				tb_fetch_sec <= 8'd0;   // the CDB block is ring slot 0
				// 0xD3 starts a new file; each 0xD4 advances by the chunk it carried.
				if (cmd_tb_send_prep)      tb_send_pos <= 24'd0;
				else if (cmd_tb_send_data) tb_send_pos <= tb_send_pos + tb_send_len[24:9];
				tb_wr_r <= 1'b1; tb_lba_r <= 32'd0; tb_state <= TBS_REQ;
			end else tb_load_w <= tb_load_w + 1'b1;
		// tail block written; fall through to the CDB request block. Same ~8 ms
		// watchdog as TBS_STAT/TBS_DATA: this is the one NEW transfer in the
		// round-trip, and a missed ack here would wedge the SCSI bus rather than
		// just corrupt 16 bytes.
		// Ships tail sectors 1..tb_tail_last, one per pass, then falls through to
		// the CDB block. A 512-byte chunk has one tail sector (the classic
		// 16-byte remainder); a 4 KB chunk has eight, which is exactly the
		// LBA 1..TB_TAIL_BLKS range Main's handler flattens into tb_tail.
		TBS_REQ2: begin
			if (tb_ack) tb_wr_r <= 1'b0;
			tb_to <= tb_to + 1'b1;
			if ((old_tb_ack & ~tb_ack) || (&tb_to)) begin
				if (tb_fetch_sec < tb_tail_last) begin
					tb_fetch_sec <= tb_fetch_sec + 5'd1;
					tb_wr_r <= 1'b1; tb_lba_r <= tb_lba_r + 32'd1; tb_to <= 18'd0;
				end else begin
					tb_fetch_sec <= 5'd0;   // sector-0 addressing for the CDB/status block
					tb_wr_r <= 1'b1; tb_lba_r <= 32'd0; tb_to <= 18'd0; tb_state <= TBS_REQ;
				end
			end
		end
		// request: HPS reads the CDB and runs the handler
		TBS_REQ: begin
			if (tb_ack) tb_wr_r <= 1'b0;
			if (old_tb_ack & ~tb_ack) begin
				tb_rd_r <= 1'b1; tb_lba_r <= 32'd0; tb_to <= 18'd0; tb_state <= TBS_STAT;
			end
		end
		// status: HPS returns {status, 0xB5, len_hi, len_lo} at buffer words 0/1.
		// Proceed on the read-completion ack-fall OR a watchdog timeout: on HW the
		// tb READ ack is not observed by the core (the write ack is, with identical
		// code; and the file-Toolbox transport this rides on was never HW-validated).
		// The HPS has already filled the buffer by the timeout, so force-latch the
		// status block. Same watchdog on TBS_DATA. (2026-07-21)
		//
		// The watchdog counts UNCONDITIONALLY. A 2026-07-31 attempt to hold it in
		// reset while tb_ack was high broke every Toolbox command on HW.
		//
		// Note on the 2026-07-21 claim above that the READ ack "is not observed"
		// on HW: taken literally that is wrong. `scsi_bench --mode toolboxwdog`
		// holds tb_ack high past the force-latch, and under that model even the
		// silicon-proven pre-fix RTL fails (TBS_DATA clears tb_rd_r on the stale
		// ack, so the fetch never issues and the status block is served as data).
		// Since LIST demonstrably works on HW, the ack fall must normally BE
		// caught; the watchdog covers occasional misses. Do not gate it, and do
		// not assume the ack can be ignored.
		TBS_STAT: begin
			if (tb_ack) tb_rd_r <= 1'b0;
			tb_to <= tb_to + 1'b1;
			if ((old_tb_ack & ~tb_ack) || (&tb_to)) begin
				tb_settle <= 4'd8; tb_state <= TBS_LATCH;
			end
		end
		// buffer reads for addr 0/1 are registered; let them settle after the
		// force-latch, then read the status block: word 0 = {status, 0xB5 sig},
		// word 1 = {len_hi, len_lo}. Signature present -> adopt status+length and
		// (if length>0) fetch the data sector(s); absent -> no handler, CHECK.
		TBS_LATCH:
			if (tb_settle != 4'd0) tb_settle <= tb_settle - 1'b1;
			else if (tb1_dout == 8'hb5) begin            // signature ok (byte 1)
				// A ship that exhausted its retries makes this chunk bad no matter
				// what the HPS says: it wrote the file from a tail buffer holding
				// the previous chunk's bytes and reported GOOD in good faith.
				tb_status <= tb_send_fault ? 8'h02 : tb0_dout;   // byte 0 = SCSI status
				// bytes 2,3 = length[15:0]; byte 4 bit 0 = length[16]. Byte 4 was
				// reserved-zero, so an HPS that does not set it reads back exactly
				// as before. The status-only test below MUST look at all 17 bits:
				// a 65536-byte response has bytes 2,3 == 0 and would otherwise be
				// mistaken for "no data".
				tb_len[15:0] <= {tb0_dout_next, tb1_dout_next};
				// Bit 16 lives in byte 4, which is NOT reachable from this address:
				// q_c/q_d are the prefetch controller's holding registers, valid on
				// the pseudo-DMA path's schedule, not this one (bench: byte 4 read
				// back 0, so a 65536 response looked like "no data"). Re-point the
				// PRIMARY port at word 2 and give it the same settle.
				tb_settle <= 4'd8;
				tb_state  <= TBS_LATCH2;
			end else if (tb_retry != TB_RETRY_MAX) begin
				// No signature: the buffer still holds the CDB we wrote, so the HPS
				// has not answered YET — a SEND chunk is a synchronous write to a
				// sync,dirsync-mounted SD, and a card erase cycle stalls it well
				// past one watchdog period. Re-ISSUE the read and look again.
				//
				// Re-issuing is the whole point: TBS_STAT clears tb_rd_r as soon as
				// tb_ack is seen (and it always is — tb_hps_wr = sd_buff_wr & tb_ack
				// is what fills the buffer), so by here no request is outstanding.
				// A retry that only re-armed the timer would re-read the same stale
				// bytes every time and still end in CHECK. (2026-07-31)
				tb_retry <= tb_retry + 1'b1;
				tb_rd_r  <= 1'b1;
				tb_lba_r <= 32'd0;
				tb_to    <= 18'd0;
				tb_state <= TBS_STAT;
			end else begin                               // no real handler -> CHECK
				tb_status <= 8'h02; tb_len <= 17'd0; tb_state <= TBS_RDY;
			end
		// Length bit 16 (see TBS_LATCH). tb_len[15:0] is already latched, so the
		// full 17-bit value is known once byte 4 has settled on the primary port.
		TBS_LATCH2:
			if (tb_settle != 4'd0) tb_settle <= tb_settle - 1'b1;
			// !tb_ack: never arm a data fetch into a LIVE ack. A stalled status
			// read force-latched mid-stream leaves tb_ack high here; the old code
			// issued anyway, TBS_DATA's ack-clear killed the never-seen request,
			// and the status stream's own fall then counted as sector 0's
			// completion — first sector served stale with no fetch ever leaving
			// the core (toolboxslow SLOW GET, 510/4096). Waiting cannot deadlock:
			// a stuck-high ack already parks TBS_REQ unbounded today.
			else if (!tb_ack) begin
				tb_len[16] <= tb0_dout[0];
				if ({tb0_dout[0], tb_len[15:0]} != 17'd0) begin
					tb_rd_r <= 1'b1; tb_lba_r <= 32'd1; tb_fetch_sec <= 8'd0; tb_to <= 18'd0;
					// Arm the streaming accounting HERE -- a fetch is starting, and this
					// is the only point where "no sector is resident yet" is true.
					// tb_retry restarts too: whatever the status re-looks consumed
					// must not shrink the data path's per-sector budget.
					tb_sec_done <= 9'd0; tb_fetch_busy <= 1'b1; tb_retry <= 10'd0;
					tb_state <= TBS_DATA;
				end else tb_state <= TBS_RDY;                // status-only
			end
		// data: HPS returns tb_len bytes across ceil(tb_len/512) sectors, one per
		// LBA (1..N). Each lands at buffer offset tb_fetch_sec*256; fetch the next
		// until all N are in, then serve linearly.
		//
		// The watchdog here is a RETRY, not a completion (2026-08-01). It used to
		// count a timed-out fetch as resident, which is the stale-sector race
		// measured on HW: an HPS descheduled past one watchdog period had not
		// even LATCHED the request, the fetch advanced to the next LBA anyway
		// (the request line stays up, so the late HPS served the ADVANCED lba),
		// and the skipped sector's ring slot served its previous occupant — one
		// full ring cycle stale, silently. Now a timeout re-arms the SAME fetch
		// (tb_lba_r/tb_fetch_sec pinned, tb_sec_done NOT advanced; the serve
		// keeps stalling on tb_get_stall), bounded by TB_RETRY_MAX like the
		// status-block re-looks. The ack-fall completion path is untouched — on
		// HW it is the primary path (upload ships complete at ~4 ms cadence
		// through the identical edge), the watchdog only covers late fills.
		// This is NOT the reverted "positive fill evidence" scheme: nothing here
		// gates on observing the fill; a resident-but-unacked sector is simply
		// re-served by the HPS on the re-look and completes on that ack.
		// Bench: scsi_bench --mode toolboxget (deferred-latch stall model) fails
		// on the old watchdog-as-completion RTL with the exact HW signature
		// (delta -16 sectors) and is byte-exact with the retry.
		TBS_DATA: begin
			if (tb_ack) tb_rd_r <= 1'b0;
			tb_to <= tb_to + 1'b1;
			if (old_tb_ack & ~tb_ack) begin
				tb_retry    <= 10'd0;                       // per-sector budget
				tb_sec_done <= tb_sec_done + 9'd1;         // this sector is resident
				if (({1'd0, tb_fetch_sec} + 9'd1) >= tb_nsec) begin
					tb_fetch_busy <= 1'b0;
					tb_state <= TBS_RDY;
				end else begin
					// Hand over to TBS_STREAM as soon as the FIRST sector is in: the
					// Mac can start taking bytes now, and the rest of the response
					// arrives behind it. Waiting for all N (the old behaviour) is
					// what capped a response at the buffer size.
					tb_fetch_sec  <= tb_fetch_sec + 8'd1;
					tb_lba_r      <= tb_lba_r + 32'd1;
					tb_rd_r       <= 1'b1;
					tb_to         <= 18'd0;
					tb_fetch_busy <= 1'b1;
					tb_state      <= TBS_STREAM;
				end
			end else if (&tb_to) begin
				if (tb_retry != TB_STALL_RETRY_MAX) begin
					tb_retry <= tb_retry + 1'b1;
					tb_to    <= 18'd0;
					// Re-arm the request line unless a fill is in flight (ack
					// high): re-raising then would put a one-cycle blip on the
					// wire the HPS could take as a second request.
					if (!tb_ack) tb_rd_r <= 1'b1;
				end else begin
					// ~4.2 s of re-looks and still nothing: the HPS is gone.
					// The serve has not started (main FSM still in PHASE_TB), so
					// fail loud as status-only CHECK, like the TBS_LATCH give-up.
					tb_status <= 8'h02; tb_len <= 17'd0;
					tb_rd_r <= 1'b0; tb_fetch_busy <= 1'b0;
					tb_state <= TBS_RDY;
				end
			end
		end
		// GET streaming: same fetch loop as TBS_DATA, but the main FSM has already
		// left PHASE_TB and the serve is running. Two rules keep the ring honest:
		// the serve stalls on tb_sec_done (REQ gating, see tb_srv_stall) and the
		// fetch stalls here when it is TB_MAXSEC ahead of the byte being served,
		// which is the slot it would otherwise overwrite.
		// tb_fetch_busy (not tb_rd_r) is what says a read is outstanding: tb_rd_r
		// is cleared the moment tb_ack rises, so testing it here would miss the
		// completion entirely and the sector count would never advance.
		// Same watchdog-is-a-retry rule as TBS_DATA (see the block comment
		// there); this state is where the HW stale-sector serve actually fired.
		TBS_STREAM: begin
			if (tb_ack) tb_rd_r <= 1'b0;
			tb_to <= tb_to + 1'b1;
			if (tb_fetch_busy) begin
				if (old_tb_ack & ~tb_ack) begin
					tb_retry      <= 10'd0;                 // per-sector budget
					tb_fetch_busy <= 1'b0;
					tb_sec_done   <= tb_sec_done + 9'd1;
					if (({1'd0, tb_fetch_sec} + 9'd1) >= tb_nsec) tb_state <= TBS_RDY;
				end else if (&tb_to) begin
					if (tb_retry != TB_STALL_RETRY_MAX) begin
						tb_retry <= tb_retry + 1'b1;
						tb_to    <= 18'd0;
						if (!tb_ack) tb_rd_r <= 1'b1;      // re-arm (see TBS_DATA)
					end else begin
						// The serve is mid-phase, so a status-only bail is not
						// enough: flag the fault, which force-completes the data
						// phase (data_done) and turns the already-latched GOOD
						// status into CHECK — a loud short transfer instead of a
						// silent stale one. tb_len stays untouched: the serve
						// wires (tb_nsec / tb_get_stall) still derive from it
						// during the abort cycle.
						tb_get_fault  <= 1'b1;
						tb_rd_r       <= 1'b0;
						tb_fetch_busy <= 1'b0;
						tb_state      <= TBS_RDY;
					end
				end
			end else if (({1'd0, tb_fetch_sec} + 9'd1) >= tb_nsec) tb_state <= TBS_RDY;
			// Throttle: never fetch into a ring slot whose bytes the Mac has not
			// taken yet. TB_MAXSEC slots separate the fetch from the serve.
			// !tb_ack for the same reason as the TBS_LATCH2 arm: an issue into a
			// live ack is killed unseen and the stale fall completes a phantom.
			else if (!tb_ack &&
			         (({1'd0, tb_fetch_sec} + 9'd1) < (tb_srv_sec + {4'd0, TB_MAXSEC}))) begin
				tb_fetch_sec  <= tb_fetch_sec + 8'd1;
				tb_lba_r      <= tb_lba_r + 32'd1;
				tb_rd_r       <= 1'b1;
				tb_to         <= 18'd0;
				tb_fetch_busy <= 1'b1;
			end
		end
		// round-trip done; the main FSM consumes tb_status/tb_len and leaves
		TBS_RDY: if (phase != PHASE_TB) tb_state <= TBS_IDLE;
		default: tb_state <= TBS_IDLE;
		endcase
	end
end

`ifdef SIMULATION
// Toolbox round-trip trace: run the bench with +tb_debug.
reg [3:0] tb_state_dbg;
always @(posedge clk) begin
	tb_state_dbg <= tb_state;
	if ((tb_state != tb_state_dbg) && $test$plusargs("tb_debug"))
		$display("TB ID=%0d %0d->%0d lba=%0d rd=%b wr=%b ack=%b to=%0d retry=%0d len=%0d sec=%0d nsec=%0d",
		         ID, tb_state_dbg, tb_state, tb_lba_r, tb_rd_r, tb_wr_r, tb_ack,
		         tb_to, tb_retry, tb_len, tb_fetch_sec, tb_nsec);
end
`endif

/* ----------------------- request data from/to io controller ----------------------- */

// CD-audio/TOC fetches own the address bus while their request is live
assign io_lba = ca_io_active ? ca_io_lba : lba;

// READ prefetch (ring): keep issuing sequential sector fetches while sectors
// remain (rd_hps_blk < tlen) and the ring has space (fetched no more than
// RING_BLOCKS ahead of the Mac). This is a LEVEL signal — the fetch engine below
// pumps one sector per io_ack until the ring is full, hiding per-sector HPS
// latency (vs. the old 1-deep "fetch next at byte 20" which stalled the CPU at
// every 512-byte boundary). rd_hps_blk >= rd_cur_blk is invariant (the Mac
// stalls via io_busy before it can pass the fetch frontier), so the subtraction
// never underflows.
wire [22:0] rd_blk_total  = {7'd0, tlen};
wire        rd_blk_remain = (rd_hps_blk < rd_blk_total);
wire        rd_ring_space = ((rd_hps_blk - rd_cur_blk) < RING_BLOCKS);
wire req_rd = (phase == PHASE_DATA_OUT) && cmd_read && (data_len != 32'd0) &&
              !data_complete && rd_blk_remain && rd_ring_space;

// generate an io_wr signal whenever a 512 byte block has been received or when the status
// phase of a write command has been reached.
// data_len != 0 guard: a zero-length WRITE reaches STATUS_OUT without any
// data phase; without the guard the STATUS_OUT clause would flush a stale
// sector-buffer block (the previous READ's data) to the command's LBA.
wire req_wr = ((((phase == PHASE_DATA_IN) && (data_cnt[8:0] == 0) && (data_cnt != 0)) || (phase == PHASE_STATUS_OUT)) && cmd_write && (data_len != 32'd0));

// Data-path io_rd (the ring engine's own request). The module output is the
// OR with the CD-audio engine's request; the engine only runs while the
// target is bus-idle with no data io pending (ca_grant below), so the two
// requestors never overlap — and a pending req_rd naturally waits for the
// audio block in flight via the !io_rd guard on the shared wire.
reg io_rd_d;
assign io_rd = io_rd_d | ca_io_rd_w;

always @(posedge clk) begin
	reg old_wr;
	reg rd_busy;            // a read-prefetch sector fetch is outstanding

	// A SCSI bus reset aborts any in-flight/queued disk IO.  Without this,
	// io_rd/io_wr (and the pending latches) survive the reset; if the Mac
	// re-selects before the stale io_rd clears via io_ack, the next CMD_IN
	// phase sees io_busy=1 (phase!=DATA && io_rd) which suppresses REQ, the
	// command never transfers, the Mac times out and resets again -> the
	// intermittent reset/re-scan loop observed on hardware.
	if(rst) begin
		io_rd_d <= 1'b0;
		io_wr <= 1'b0;
		wr_pending <= 0;
		old_wr <= 0;
		rd_busy <= 0;
	end else begin
		old_wr <= req_wr;
		if(~old_wr & req_wr) wr_pending <= 1;

		// READ prefetch engine: while req_rd (sectors remain AND ring has
		// space), issue back-to-back sector fetches — one per io_ack — to keep
		// the ring filled ahead of the Mac. rd_busy holds across a fetch until
		// rd_hps_blk advances on the io_ack falling edge, so exactly one fetch
		// is issued per sector and the next can start immediately after.
		// (io_rd in the guard is the shared wire: a CD-audio block in flight
		// defers the ring's next fetch by one HPS block, nothing more.)
		if(io_ack) io_rd_d <= 1'b0;
		else if(req_rd && !io_rd && !rd_busy) begin io_rd_d <= 1'b1; rd_busy <= 1'b1; end
		if(old_io_ack & ~io_ack) rd_busy <= 1'b0;

		// WRITE flush engine — unchanged two-slot double-buffer behavior.
		if(io_ack) io_wr <= 1'b0;
		else if(wr_pending && !io_wr) begin io_wr <= 1'b1; wr_pending <= 0; end
	end
end

// =====================================================================
// CD audio engine (CDROM targets only; every ca_* wire folds to a constant
// on disks). Owns the AppleCD playback state machine, the real TOC, and
// the audio-frame streaming from the HPS windows. It may use the io
// channel only while the target is bus-idle with no data io pending.
// =====================================================================
// CA grant: the audio/TOC engine's fetches are HPS-channel-only (they never
// touch the SCSI bus), so they may interleave with an ACTIVE READ command's
// serving phase — requiring full bus-idle starved the frame stream to ~42
// of the required 75 frames/s whenever the guest streamed game data from
// the same disc (HW capture 2026-07-18: pstate=PLAY, fetch delta 17/400ms,
// audible crackle = sample-hold at every late frame). The io-free terms
// still serialize the channel per-op, and the ~ca_io_active scoping keeps
// CA acks out of the data-path accounting (that isolation was built for
// exactly this concurrency). DATA_IN (writes) stays excluded: the CD is
// read-only, so it never occurs; all other phases remain excluded.
wire ca_grant = (phase == PHASE_IDLE || (cmd_read && phase == PHASE_DATA_OUT))
                && !io_rd_d && !io_wr && !io_ack && mounted;

generate if (CDROM != 0) begin : g_cd_audio
	cd_audio #(.CLK_HZ(32'd32_500_000)) cd_audio_i (   // clk_sys rate; audio pitch verifies it
		.clk(clk), .rst(sys_rst), .bus_rst(rst),
		.mounted(mounted), .img_mounted(img_mounted), .img_blocks(img_blocks),
		.cmd_stb(ca_cmd_stb), .cmd_op(cmd[0]),
		.cdb1(cmd[1]), .cdb2(cmd[2]), .cdb3(cmd[3]), .cdb4(cmd[4]),
		.cdb5(cmd[5]), .cdb6(cmd[6]), .cdb7(cmd[7]), .cdb8(cmd[8]), .cdb9(cmd[9]),
		.read_stb(ca_read_stb), .eject_stb(ca_eject_stb),
		.ap_ch0(cd_ap_ch0), .ap_vol0(cd_ap_vol0),   // page 0x0E audio ports
		.ap_ch1(cd_ap_ch1), .ap_vol1(cd_ap_vol1),   // (the volume slider)
		.ch_grant(ca_grant),
		.ca_io_active(ca_io_active), .ca_io_rd(ca_io_rd_w), .ca_io_lba(ca_io_lba),
		.io_ack(io_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_addr_hi(sd_buff_addr_hi),
		.sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
		.ast_code(ca_ast_code), .cur_ctrl(ca_cur_ctrl), .cur_trk(ca_cur_trk),
		.abs_m(ca_abs_m), .abs_s(ca_abs_s), .abs_f(ca_abs_f),
		.rel_m(ca_rel_m), .rel_s(ca_rel_s), .rel_f(ca_rel_f),
		.toc_base(ca_toc_addr),
		.toc_q0(ca_toc_q0), .toc_q1(ca_toc_q1), .toc_q2(ca_toc_q2), .toc_q3(ca_toc_q3),
		.toc_ready(ca_toc_ready),
		.toc43_base(ca_t43_addr),
		.toc43_q0(ca_t43_q0), .toc43_q1(ca_t43_q1),
		.toc43_q2(ca_t43_q2), .toc43_q3(ca_t43_q3),
		.toc43_len(ca_t43_len),
		.toc2_base(ca_t2_addr),
		.toc2_q0(ca_t2_q0), .toc2_q1(ca_t2_q1),
		.toc2_q2(ca_t2_q2), .toc2_q3(ca_t2_q3),
		.toc2_len(ca_t2_len),
		.disc_audio(ca_disc_audio),
		.snd_l(cd_snd_l), .snd_r(cd_snd_r),
		.dbg_cda0(dbg_cda0),
		.dbg_cdur(dbg_cdur)
	);
end else begin : g_no_cd_audio
	assign ca_io_active = 1'b0;
	assign ca_io_rd_w   = 1'b0;
	assign ca_io_lba    = 32'd0;
	assign ca_ast_code  = 8'h05;
	assign ca_cur_ctrl  = 8'h14;
	assign ca_cur_trk   = 8'h01;
	assign ca_abs_m = 8'h00; assign ca_abs_s = 8'h00; assign ca_abs_f = 8'h00;
	assign ca_rel_m = 8'h00; assign ca_rel_s = 8'h00; assign ca_rel_f = 8'h00;
	assign ca_toc_q0 = 8'h00; assign ca_toc_q1 = 8'h00;
	assign ca_toc_q2 = 8'h00; assign ca_toc_q3 = 8'h00;
	assign ca_t43_q0 = 8'h00; assign ca_t43_q1 = 8'h00;
	assign ca_t43_q2 = 8'h00; assign ca_t43_q3 = 8'h00;
	assign ca_t43_len = 10'd0;
	assign ca_t2_q0 = 8'h00; assign ca_t2_q1 = 8'h00;
	assign ca_t2_q2 = 8'h00; assign ca_t2_q3 = 8'h00;
	assign ca_t2_len = 10'd0;
	assign ca_disc_audio = 1'b0;
	assign ca_toc_ready = 1'b0;
	assign cd_snd_l = 16'sd0;
	assign cd_snd_r = 16'sd0;
	assign dbg_cda0 = 32'd0;
	assign dbg_cdur = 32'd0;
end endgenerate

reg  stb_ack;
reg  stb_adv;
always @(posedge clk) begin
	reg old_ack;
	
	old_ack <= ack;
	stb_ack <= (~old_ack & ack); // on rising edge
	stb_adv <= (old_ack & ~ack); // on falling edge
end

reg buffer0_wr, buffer1_wr;

// store data on rising edge of ack, ...
always @(posedge clk) begin
	buffer0_wr <= 0;
	buffer1_wr <= 0;
	if(stb_ack) begin
		if(phase == PHASE_CMD_IN)  cmd[cmd_cnt] <= din;
		if(phase == PHASE_DATA_IN) begin
			buffer0_wr <= ~data_cnt[0];
			buffer1_wr <=  data_cnt[0];
		end
	end
end

// ... advance counter on falling edge
always @(posedge clk) begin
	if(phase == PHASE_IDLE) cmd_cnt <= 4'd0;
	else if(stb_adv && (phase == PHASE_CMD_IN) && (cmd_cnt != 15)) cmd_cnt <= cmd_cnt + 4'd1;
end

// count data bytes. don't increase counter while we are waiting for data from
// the io controller
reg [31:0] data_cnt;
reg        data_complete;

// For block transfers tlen contains the number of 512 bytes blocks to transfer.
// Most other commands have the bytes length stored in the transfer length field.
// And some have a fixed length idependent from any header field.
// The data transfer has finished once the data counter reaches this
// number.
//
// Allocation-length clamping (2026-06-10, SCSI corruption root cause):
// tlen6's 0->256 mapping is the READ/WRITE(6) block-count convention and does
// NOT apply to allocation lengths — for INQUIRY alloc 0 means "no data", for
// REQUEST SENSE it means 4 bytes (pre-SCSI-2 convention). Undo it here.
wire [31:0] alloc_len = (tlen == 16'd256) ? 32'd0 : {16'd0, tlen};
wire [31:0] sense_len = (tlen == 16'd256) ? 32'd4 : {16'd0, tlen};
// CDROM response sizes. INQUIRY = 54 (5 + additional-length 0x31). Apple READ
// TOC (0xC1): ops 00/01 return a fixed 4 bytes; op 10 (track range) returns
// floor(alloc/4) four-byte descriptors = alloc & ~3 (MAME: num_trks = size/4).
// tlen here is the RAW 10-byte-CDB allocation ({cmd[7],cmd[8]}) — only READs
// are <<2-scaled at latch time.
localparam [31:0] INQUIRY_LEN = (CDROM != 0) ? 32'd54 : 32'd36;
wire        cd_ms30    = (CDROM != 0) && cmd_mode_sense && (cmd[2][5:0] == 6'h30);
// Page 0x0E (CD Audio Control) asks get the audio-port page; 0x3F ("all
// pages") keeps today's header-only default — the AppleCD driver asks for
// 0x0E directly (Snow dispatch) and changing 0x3F would touch proven paths.
wire        cd_ms0e    = (CDROM != 0) && cmd_mode_sense && (cmd[2][5:0] == 6'h0E);
// Page 0x2A (MM Capabilities & Mechanical Status): advertises what this drive
// can actually do — audio play, multi-session, Mode 2 Form 1/2, tray load with
// eject, separate channel mute AND separate volume levels, 256 volume steps.
// The volume claims are the ones that matter: they are exactly what the page
// 0x0E audio-port path implements, so a utility that probes 0x2A before
// showing volume controls now gets a truthful yes. Snow layout (mod.rs 0x2A).
wire        cd_ms2a    = (CDROM != 0) && cmd_mode_sense && (cmd[2][5:0] == 6'h2A);
// CD-changer detection: serve the BlueSCSI Toolbox page-0x31 magic on the CD
// target so a Toolbox client (MacAtrium) recognizes it as a CD changer (its probe
// = MODE SENSE page 0x31 magic + INQUIRY CD-ROM). UNGATED (CDCHANGER_ENABLE, not
// tb_ready): detection works standalone before the HPS handler lands; MacAtrium
// tolerates the follow-up LIST/SET CHECK gracefully. Only the explicit page-0x31
// request is affected — the AppleCD driver's page 0x30 / default MODE SENSE is
// untouched. docs/BLUESCSI_CD_CHANGER_CONTRACT.md
wire        cd_ms31    = CDCHANGER_ENABLE && cmd_mode_sense && (cmd[2][5:0] == 6'h31);
// ops 00/01: MAME serves a fixed 4; clamp to the allocation as well so a
// short alloc can never leave unserved bytes holding REQ (the 2026-06-10
// alloc-overserve wedge class). Identical to MAME for the observed alloc=4.
wire [31:0] cd_toc_len = (cmd[9][7:6] == 2'b10) ? {16'd0, tlen[15:2], 2'b00}
                       : (tlen < 16'd4)         ? {16'd0, tlen}
                       :                          32'd4;
// A real target returns min(allocation length, actual response size) and then
// switches to STATUS; the initiator detects the early phase change via the
// BSR phase-mismatch bit. Serving the raw allocation length (previous
// behavior) DEADLOCKS the bus whenever the initiator transfers fewer bytes
// than it asked for: the target holds REQ with leftover bytes while the Mac
// polls BSR for a phase change that never comes (the 2026-06-10 Welcome
// hang). Actual sizes: INQUIRY = 5 + additional-length(31) = 36 bytes — the
// STANDARD response size (matches real drives and Snow; serving 37 left one
// unread byte for drivers that read the standard 36 -> 2026-06-10c wedge);
// MODE SENSE(6) = 12 bytes (4 header + 8 block descriptor, header says 11);
// REQUEST SENSE = 8 + additional-length(0x0a) = 18 bytes.
wire [31:0] data_len =
		 cmd_read_capacity?32'd8:
		 cmd_read?{ 7'd0, tlen, 9'd0 }:   // read command length is in 512 bytes blocks
		 cmd_write?{ 7'd0, tlen, 9'd0 }:  // write command length is in 512 bytes blocks
		 cmd_cd_toc?cd_toc_len:           // Apple READ TOC (see cd_toc_len)
		 // 0x43/0x42 serve EXACTLY the allocation length (zero-filled past the
		 // real payload; header length fields still carry the true size). The
		 // under-serve direction deadlocks too (2026-07-19, deterministic at
		 // boot): the Mac's blind-transfer primitive arms the FULL allocation
		 // and pumps DACK for it; a target that goes early-STATUS after
		 // min(alloc,actual) leaves the host armed with no DREQ ever coming —
		 // 250 ms BERR beats, SCSI Mgr retry, boot wedge ("host-armed/
		 // target-idle"). Discovered via the 0x43 start-track filter: it was
		 // the first command whose actual size (20 B for the {start=22,
		 // alloc=48} duration ask) dropped BELOW the allocation. Caps: 512 =
		 // T43 plane, 64 > the 16-byte 0x42 payload (its serve function
		 // zero-fills past byte 15 by construction).
		 cmd_cd_toc43?(({16'd0, cmd[7], cmd[8]} < 32'd512) ?
		               {16'd0, cmd[7], cmd[8]} : 32'd512):   // all formats: f0/f2 tables + f1 page
		 cmd_cd_subq43?(({16'd0, cmd[7], cmd[8]} < 32'd64) ?
		                {16'd0, cmd[7], cmd[8]} : 32'd64):
		 cmd_cd_subq?32'd9:               // READ Q SUBCODE: fixed 9 bytes
		 cmd_cd_astat?32'd6:              // AUDIO STATUS: fixed 6 bytes
		 cmd_cd_hdr?(({16'd0, cmd[7], cmd[8]} < 32'd16) ?
		             {16'd0, cmd[7], cmd[8]} : 32'd16):  // READ HEADER: exact alloc, cap 16 (8 real, zero-filled)
		 cmd_cd_actl?{24'd0, cmd[8]}:     // AUDIO CONTROL: DataOut of CDB[8] bytes (discarded)
		 cmd_inquiry?((alloc_len < INQUIRY_LEN) ? alloc_len : INQUIRY_LEN):
		 cmd_mode_sense?((CDROM != 0) ? (cd_ms0e ? ((alloc_len < 32'd28) ? alloc_len : 32'd28)
		                               : cd_ms2a ? ((alloc_len < 32'd38) ? alloc_len : 32'd38)
		                               : cd_ms31 ? ((alloc_len < 32'd56) ? alloc_len : 32'd56)
		                               : cd_ms30 ? ((alloc_len < 32'd36) ? alloc_len : 32'd36)
		                                         : ((alloc_len < 32'd12) ? alloc_len : 32'd12))
		                              : (mode_sense_p31 ? ((alloc_len < 32'd56) ? alloc_len : 32'd56)
		                                                : ((alloc_len < 32'd12) ? alloc_len : 32'd12))):
		 ((CDROM != 0) && cmd_mode_select)?alloc_len:  // MODE SELECT alloc 0 = no data (not 256)
		 cmd_request_sense?((sense_len < 32'd18) ? sense_len : 32'd18):
		 cmd_tb_devinfo?tb_devinfo_len:                       // 0xD9 DEVICE INFO
		 cmd_tb_debug_get?32'd1:                              // 0xD6 get = one flag byte
		 (cmd_tb_fs_in || cmd_cdc_in)?{15'd0, tb_srv_len}:    // 0xD0/D1/D2 fs + 0xD7/DA CD-changer DataIn (HPS length)
		 cmd_tb_send_prep?32'd33:                             // 0xD3 SEND PREP: 33-byte filename
		 // 0xD4 SEND DATA: the DataOut phase is ALWAYS one full 512-byte block.
		 // CDB[6] (512-blocks) / CDB[1..2] (legacy byte count) say how many of
		 // those bytes are VALID — they are not the transfer size. Deriving the
		 // phase length from them made the target end the data phase early on the
		 // short final chunk of every file whose size is not a multiple of 512,
		 // which the Mac client reports as a failed copy ("errors copying from
		 // the Mac to the SD card", HW 2026-07-30; scsi_bench --mode toolbox
		 // stalls at byte 386 of 512 without this). The HPS trims to the CDB
		 // count when it writes.
		 cmd_tb_send_data?tb_send_len:
		 { 16'd0, tlen };                 // mode select etc have length in bytes

always @(posedge clk) begin
	if((phase != PHASE_DATA_OUT) && (phase != PHASE_DATA_IN) && (phase != PHASE_STATUS_OUT) && (phase != PHASE_MESSAGE_OUT)) begin
		data_cnt <= 0;
		data_complete <= 0;
	end else begin	
		if(stb_adv)begin	
			if(!data_complete) data_cnt <= data_cnt + 1'd1;
			data_complete <= (data_len - 1'd1) == data_cnt;
		end
	end
end

`ifdef SIMULATION
// No-progress watchdog: in a data phase, if data_cnt has not advanced for a
// long time, dump the FULL handshake state — independent of REQ level — so a
// deadlock where REQ is held LOW (io_busy / data_phase_complete)
// is visible, not just a REQ-high host stall.  Also logs every phase change.
reg [31:0] stall_cnt;
reg [31:0] data_cnt_seen;
reg  [2:0] phase_d;
always @(posedge clk) begin
	phase_d <= phase;
	if (phase != phase_d && $test$plusargs("scsi_stall_debug"))
		$display("SCSI_PHASE ID=%0d %0d->%0d data_cnt=%0d data_len=%0d complete=%0d cmd=%02h tlen=%0d lba=%0d",
		         ID, phase_d, phase, data_cnt, data_len, data_complete, cmd[0], tlen, lba);
	if (phase == PHASE_DATA_OUT || phase == PHASE_DATA_IN) begin
		if (data_cnt != data_cnt_seen) begin
			data_cnt_seen <= data_cnt;
			stall_cnt <= 0;
		end else begin
			stall_cnt <= stall_cnt + 1'd1;
			if (stall_cnt == 32'd300000 && $test$plusargs("scsi_stall_debug"))
				$display("SCSI_STALL ID=%0d phase=%0d data_cnt=%0d/%0d cmpl=%b req=%b ack=%b io_busy=%b io_rd=%b io_ack=%b sel=%b dc9=%b sd_sel=%b dpc=%b cmd=%02h tlen=%0d lba=%0d",
				         ID, phase, data_cnt, data_len, data_complete, req, ack, io_busy, io_rd, io_ack,
				         sel, data_cnt[9], sd_buff_sel, data_phase_complete, cmd[0], tlen, lba);
		end
	end else begin
		stall_cnt <= 0;
		data_cnt_seen <= 0;
	end
end

// Write-path byte-slip instrumentation (2026-06-10 forensics: a 6-sector
// WRITE landed on disk with ONE foreign byte inserted at payload offset 1
// and the rest of the command's data shifted +1, last byte dropped — see
// docs/scsi_byteslip_2026-06-10.md). Hooks:
//   * SCSI_WR_OVERRUN: an ACK beat in a write data phase after
//     data_complete — the host still has bytes after we counted data_len,
//     i.e. a phantom byte was consumed earlier in the phase.
//   * +scsi_wr_trace: per-beat log of every stored byte for offline diff
//     against the expected payload (find WHERE the foreign byte enters).
always @(posedge clk) begin
	if (stb_ack && (phase == PHASE_DATA_IN) && data_complete)
		$display("SCSI_WR_OVERRUN ID=%0d data_cnt=%0d data_len=%0d din=%02x lba=%0d cmd=%02h",
		         ID, data_cnt, data_len, din, lba, cmd[0]);
	if (stb_ack && (phase == PHASE_DATA_IN) && $test$plusargs("scsi_wr_trace"))
		$display("SCSI_WR_BEAT ID=%0d cnt=%0d din=%02x lba=%0d", ID, data_cnt, din, lba);
end

// Stuck-flush watchdog: io_wr pending while the bus is idle means the
// final-block flush ack raced the BSY drop (io_ack is masked by
// target_bsy upstream in ncr5380) — recovery then relies on the Mac's
// timeout + bus reset (the documented reset/re-scan loop). Candidate
// mechanism for the forensically-observed LOST write commands.
reg [31:0] idle_flush_cnt;
always @(posedge clk) begin
	if (io_wr && (phase == PHASE_IDLE)) begin
		idle_flush_cnt <= idle_flush_cnt + 1'd1;
		if (idle_flush_cnt == 32'd100000)
			$display("SCSI_FLUSH_STUCK ID=%0d io_wr pending while bus idle (io_ack masked by !bsy?) lba=%0d",
			         ID, lba);
	end else
		idle_flush_cnt <= 0;
end
`endif

// check whether status byte has been sent
reg status_sent;
always @(posedge clk) begin
	if(phase != PHASE_STATUS_OUT) status_sent <= 0;
	else if(stb_adv) status_sent <= 1;
end

// check whether message byte has been sent
reg message_sent;
always @(posedge clk) begin
	if(phase != PHASE_MESSAGE_OUT) message_sent <= 0;
	else if(stb_adv) message_sent <= 1;
end

/* ----------------------- command decoding ------------------------------- */


// parse commands
wire [7:0] op_code = cmd[0];
wire [2:0] cmd_group = op_code[7:5];

// check if a complete command has been received
wire       cmd_cpl = cmd6_cpl || cmd10_cpl || cmd12_cpl;
wire       cmd6_cpl = (cmd_group == 3'b000) && (cmd_cnt == 6);
// BlueSCSI Toolbox vendor commands (0xD0-0xDA, group 110) are 10-byte CDBs.
// Decode ONLY this exact range as 10-byte (not the whole vendor group 110) so
// other group-110 opcodes aren't mis-lengthed (0xC0 EJECT is a 6-byte CDB).
// 0xDA (CD-changer COUNT CDS) extends the file Toolbox's 0xD0-0xD9 range.
// docs/BLUESCSI_MISTER_MAIN_PLAN.md, docs/BLUESCSI_HANDOFF.md §1,
// docs/BLUESCSI_CD_CHANGER_CONTRACT.md §2.
wire       cmd_toolbox_op = (op_code >= 8'hd0) && (op_code <= 8'hda);
// Apple CD vendor commands 0xC0-0xCE are ALL 10-byte CDBs (MAME
// nscsi_cdrom_apple_device::scsi_command_done: command&0xf0==0xc0 -> 10).
wire       cmd_apple_cd_op = (CDROM != 0) && (op_code[7:4] == 4'hc);
wire       cmd10_cpl = (((cmd_group == 3'b010) || (cmd_group == 3'b001)) && (cmd_cnt == 10))
                       || (cmd_toolbox_op && (cmd_cnt == 10))
                       || (cmd_apple_cd_op && (cmd_cnt == 10));
// Group 5 (0xA0-0xBF) = 12-byte CDBs. Until now NOTHING completed them: the
// target sat in PHASE_CMD_IN forever, so any 12-byte command from any
// initiator WEDGED the bus (latent, never hit because MacOS sends none).
// Completing them makes unknown group-5 opcodes CHECK with invalid-op — the
// correct SCSI answer — and makes the already-decoded 0xA5 PLAY AUDIO(12)
// actually reachable. Only cmd[0..9] are stored (the array is 10 deep and
// out-of-range writes are discarded); every group-5 command we serve keeps
// its operands inside that window, and bytes 10-11 are reserved + CONTROL.
wire       cmd12_cpl = (cmd_group == 3'b101) && (cmd_cnt == 12);

// https://en.wikipedia.org/wiki/SCSI_command
wire       cmd_read = cmd_read6 || cmd_read10;
wire       cmd_read6 = (op_code == 8'h08);
wire       cmd_read10 = (op_code == 8'h28);
wire       cmd_write = cmd_write6 || cmd_write10;
wire       cmd_write6 = (op_code == 8'h0a);
wire       cmd_write10 = (op_code == 8'h2a);
wire       cmd_inquiry = (op_code == 8'h12);
wire       cmd_format = (op_code == 8'h04);
wire       cmd_mode_select = (op_code == 8'h15);
wire       cmd_mode_sense = (op_code == 8'h1a);
wire       cmd_test_unit_ready = (op_code == 8'h00);
wire       cmd_read_capacity = (op_code == 8'h25);
wire       cmd_read_buffer = (op_code == 8'h3b);  // fake
wire       cmd_write_buffer = (op_code == 8'h3c); // fake
wire       cmd_verify6 = (op_code == 8'h13); // fake
wire       cmd_verify10 = (op_code == 8'h2f); // fake
// REQUEST SENSE (0x03) is MANDATORY: after any CHECK CONDITION the initiator
// issues it to recover the sense data.  The target previously rejected it
// (cmd_ok=0 -> CHECK CONDITION), so on hardware -- where a transient error
// triggers the recovery path -- the Mac could never clear the condition and
// wedged.  Support it and return a clean "NO SENSE" block.
wire       cmd_request_sense = (op_code == 8'h03);

// ----- Apple CD-ROM command set (CDROM targets only; all fold to 0 on disks).
// Oracle: MAME nscsi_cdrom_apple_device (docs/plan_scsi_cdrom.md Appendix A).
wire       cmd_cd_eject     = (CDROM != 0) && (op_code == 8'hc0);  // EJECT DISC
wire       cmd_cd_toc       = (CDROM != 0) && (op_code == 8'hc1);  // READ TOC (BCD/MSF)
wire       cmd_cd_subq      = (CDROM != 0) && (op_code == 8'hc2);  // READ Q SUBCODE (9 B)
wire       cmd_cd_astat     = (CDROM != 0) && (op_code == 8'hcc);  // AUDIO STATUS (6 B)
wire       cmd_cd_actl      = (CDROM != 0) && (op_code == 8'hce);  // AUDIO CONTROL (DataOut cmd[8] B, discarded)
// Audio transport commands: v1 = data CDs only, accept as no-op GOOD (deferred
// per plan §5.1; they only matter for CD-DA which has no PCM path yet).
wire       cmd_cd_audio_nop = (CDROM != 0) && ((op_code == 8'hc8) || (op_code == 8'hc9) ||
                                               (op_code == 8'hca) || (op_code == 8'hcb) ||
                                               (op_code == 8'hcd) ||
                                               // standard set (dialect switch):
                                               (op_code == 8'h47) || (op_code == 8'h48) ||
                                               (op_code == 8'h4b) || (op_code == 8'h4e) ||
                                               // 0x01 REZERO = the AppleCD player's
                                               // STOP button ("nonstandard stop audio
                                               // playback", BlueSCSI) — rejecting it
                                               // raised the error dialog with music
                                               // still playing (sense 5/0x20 latched,
                                               // 2026-07-20). SEEK(6)/(10) carry the
                                               // same Annex-C stop-audio semantics.
                                               (op_code == 8'h01) ||
                                               (op_code == 8'h0b) || (op_code == 8'h2b) ||
                                               // PLAY AUDIO(10)/(12) LBA forms (gap
                                               // pass 2026-07-29; BlueSCSI 2379/2393)
                                               (op_code == 8'h45) || (op_code == 8'ha5));
wire       cmd_cd_toc43  = (CDROM != 0) && (op_code == 8'h43);  // standard READ TOC (any format)
// old-style format select in the CONTROL byte (cmd[9][7:6]) — the AppleCD
// driver's actual dialect on the 8004 identity (2026-07-19 capture: 0x80).
// Oracles: BlueSCSI apple-quirks (0x80=full TOC, 0x40=session info) + Snow.
// Unknown format 2'b11 falls back to format 0 (benign, never observed).
wire       cmd_cd_t43f2  = cmd_cd_toc43 && (cmd[9][7:6] == 2'b10);  // FULL TOC (format 2)
wire       cmd_cd_t43f1  = cmd_cd_toc43 && (cmd[9][7:6] == 2'b01);  // SESSION INFO (format 1)
wire       cmd_cd_t43f0  = cmd_cd_toc43 && !cmd_cd_t43f2 && !cmd_cd_t43f1;
wire       cmd_cd_subq43 = (CDROM != 0) && (op_code == 8'h42);  // standard READ SUB-CHANNEL
wire       cmd_cd_prevent   = (CDROM != 0) && (op_code == 8'h1e);  // PREVENT/ALLOW MEDIUM REMOVAL
wire       cmd_cd_startstop = (CDROM != 0) && (op_code == 8'h1b);  // START/STOP UNIT
// SET CD SPEED (0xBB, 12-byte CDB — needs cmd12_cpl above). Accept-noop: the
// requested read/write speeds are advisory and our serve rate is fixed by the
// HPS ring, so GOOD with no state change is the honest answer (BlueSCSI 2451
// treats it the same way). Rejecting it would make speed-setting utilities
// report a drive fault for a request that costs us nothing to honour.
wire       cmd_cd_setspeed  = (CDROM != 0) && (op_code == 8'hbb);
// READ HEADER (0x44, gap pass 2026-07-29): 8 bytes {mode, 0,0,0, address}.
// LBA form only — the MSF form needs an LBA→MSF divide the serve path does
// not have, so MSF-bit asks CHECK with ILLEGAL REQUEST/invalid field (clean
// rejection beats wrong data; zero observed askers, BlueSCSI 2327 is the
// oracle). Mode: 0 for a pure-audio disc, else 1 — per-LBA track typing
// needs a TOC walk the serve path doesn't have; documented limitation for
// mixed-mode discs in docs/SCSI_CMD_GAPS.md.
wire       cmd_cd_hdr       = (CDROM != 0) && (op_code == 8'h44);
wire       cd_hdr_msf_rej   = cmd_cd_hdr && cmd[1][1];
function [7:0] cd_hdr_byte;
	input [31:0] cnt;
	begin
		cd_hdr_byte = (cnt == 32'd0) ? (ca_disc_audio ? 8'h00 : 8'h01) :
		              (cnt == 32'd4) ? cmd[2] :
		              (cnt == 32'd5) ? cmd[3] :
		              (cnt == 32'd6) ? cmd[4] :
		              (cnt == 32'd7) ? cmd[5] : 8'h00;
	end
endfunction
wire [7:0] cd_hdr_dout       = cd_hdr_byte(data_cnt);
wire [7:0] cd_hdr_dout_next  = cd_hdr_byte(data_cnt_next);
wire [7:0] cd_hdr_dout_next2 = cd_hdr_byte(data_cnt_next2);
wire [7:0] cd_hdr_dout_next3 = cd_hdr_byte(data_cnt_next3);

// ----- BlueSCSI Toolbox vendor commands (0xD0-0xD9) ----------------------
// M0 = the RTL-serviceable subset that needs NO host filesystem, so the Mac
// "BlueSCSI SD Transfer" client can DETECT the device:
//   * 0xD9 DEVICE INFO  - static device-list / capabilities (like INQUIRY)
//   * 0xD6 TOGGLE DEBUG - a stored flag (get/set), no side effects
// Detection (MODE SENSE page 0x31 + 0xD9/0xD6) AND the filesystem opcodes
// (0xD0/D1/D2) are ALL gated on tb_ready, so the target advertises Toolbox
// capability only when the HPS handler is present and the slot is mounted. On a
// stock Main (no handler) tb_ready=0: every Toolbox response degrades to a plain
// disk, so the Mac client never engages. (The earlier "detection works
// standalone, fs ops degrade to empty folder" plan hung the client on app-close
// -- the page-0x31 advert is what makes it engage, so it must be gated too.)
// docs/BLUESCSI_MISTER_MAIN_PLAN.md
wire       cmd_tb_devinfo   = TOOLBOX_ENABLE && tb_ready && (op_code == 8'hd9);      // DEVICE INFO
wire       cmd_tb_fs_in     = TOOLBOX_ENABLE && (op_code == 8'hd0 || op_code == 8'hd1 || op_code == 8'hd2); // LIST/GET/COUNT (HPS round-trip, DataIn)
// SEND/upload (Mac -> host), DataOut. The CDB and the payload ride the round-trip
// block layout CDB at [0..9], payload at [16..] — so a full 512-byte SEND DATA
// chunk runs to buffer byte 527 and its last 16 bytes land in buffer SECTOR 1,
// shipped as a second request block (TBS_REQ2). That needs TB_ADDRW > 8; on a
// 512-byte buffer the payload wraps onto the CDB words instead and those 16
// bytes are lost (holes every 512 B in the uploaded file, HW 2026-07-30).
// 0xD5 has no data phase.
wire       cmd_tb_send_prep = TOOLBOX_ENABLE && (op_code == 8'hd3);   // SEND FILE PREP (33-B name)
wire       cmd_tb_send_data = TOOLBOX_ENABLE && (op_code == 8'hd4);   // SEND FILE DATA (chunk)
wire       cmd_tb_send_end  = TOOLBOX_ENABLE && (op_code == 8'hd5);   // SEND FILE END (no payload)
wire       cmd_tb_send      = cmd_tb_send_prep || cmd_tb_send_data || cmd_tb_send_end;
wire       cmd_tb_send_pay  = cmd_tb_send_prep || cmd_tb_send_data;   // has a DataOut payload
wire       tb_send_tail     = cmd_tb_send_data && (TB_ADDRW > 8);     // ship buffer sector 1.. too
// SEND chunk size. The DataOut phase is ALWAYS a whole number of 512-byte
// blocks: CDB[6] gives the block count (large-send encoding), and when it is
// zero the client is a v0 legacy sender that still pushes one full block and
// puts the VALID byte count in CDB[1..2]. Deriving the phase length from the
// valid count is what broke every short final chunk (see data_len) — the count
// only tells the HPS how much of the block to write.
//
// Clamped to TB_SEND_CAP so a client that ignores our advertised capability
// cannot overrun the buffer: the payload sits at byte 16, so 16 + N must fit in
// 2 * 2^TB_ADDRW bytes. TB_ADDRW=12 (8 KB) holds 4 KB comfortably.
// Streaming (2026-07-31) decouples this from the buffer: a chunk is collected
// through the ring, so the cap is the protocol's, not the RAM's. 64 KB covers
// the official client's 127-block (65024 B) chunk. It stays a CLAMP -- a client
// that asks for more than we will collect must not overrun the ring.
localparam [31:0] TB_SEND_CAP = (TB_ADDRW >= 12) ? 32'd65536 : 32'd512;
wire [31:0] tb_send_raw = (cmd[6] != 8'd0) ? {15'd0, cmd[6], 9'd0} : 32'd512;
wire [31:0] tb_send_len = (tb_send_raw > TB_SEND_CAP) ? TB_SEND_CAP : tb_send_raw;
// Last buffer sector the payload touches = (16 + N - 1) >> 9. Sector 0 is the
// CDB block, so sectors 1..tb_tail_last are the tail blocks to ship first.
wire [8:0]  tb_tail_last = ({1'b0,tb_send_len[15:0]} + 17'd15) >> 9;
wire       cmd_tb_debug     = TOOLBOX_ENABLE && tb_ready && (op_code == 8'hd6);      // TOGGLE DEBUG
wire       cmd_tb_debug_get = cmd_tb_debug && (cmd[1] != 8'd0);    // CDB[1]!=0 -> read flag
wire       tb_devinfo_caps  = cmd_tb_devinfo && (cmd[1] == 8'h01); // subcmd 1 = capabilities
// 0xD9 allocation length is CDB[8] (0 -> 8 bytes; otherwise min(CDB[8],8)).
wire [31:0] tb_devinfo_alloc = (cmd[8] == 8'd0) ? 32'd8 : {24'd0, cmd[8]};
wire [31:0] tb_devinfo_len   = (tb_devinfo_alloc < 32'd8) ? tb_devinfo_alloc : 32'd8;

// 0xD4 SEND DATA inter-byte watchdog. The DataOut phase is a fixed 512-byte
// block (see data_len). If a client ever transferred only the CDB's valid-byte
// count instead, the phase would never complete and the target would hold REQ
// until the Mac reset the bus — so close the phase after ~2 ms of no ACK and
// let the HPS write the count the CDB gave it. Never fires on a client that
// sends the full block.
wire      tb_out_active = (phase == PHASE_DATA_IN) && cmd_tb_send_data;
reg [15:0] tb_out_to    = 16'd0;
reg        tb_out_stall_r = 1'b0;
always @(posedge clk) begin
	if (!tb_out_active)     begin tb_out_to <= 16'd0; tb_out_stall_r <= 1'b0; end
	// tb_col_stall: WE are holding REQ down to drain the streaming ring, so the
	// absence of ACKs is our own flow control, not a stalled client. Inert while
	// TB_CAPS=0x00 (a 512-byte chunk never fills the ring); it matters once large
	// sends are advertised, where a slow HPS block write could otherwise let a
	// full ring exceed the 2.02 ms timeout and truncate the phase.
	else if (stb_adv || tb_col_stall) tb_out_to <= 16'd0;
	else if (!(&tb_out_to))       tb_out_to <= tb_out_to + 1'b1;
	else                          tb_out_stall_r <= 1'b1;
end
assign tb_out_stalled = tb_out_active && tb_out_stall_r;

// Toolbox DataIn serve-settle. These responses come straight out of the tb
// dpram, whose port-B read register (q_b) is time-shared with the look-ahead
// prefetch controller: for ~3 cycles after every word-address change q_b holds
// ram[addr+1]/ram[addr+2] instead of ram[addr]. The pseudo-DMA read path covers
// that with ncr5380's dma_settle; the Toolbox path is PIO byte-at-a-time and had
// no equivalent — a host that samples CDR within a few cycles of REQ rising gets
// the byte from two words ahead on every EVEN byte (the word address only
// changes on even->odd boundaries). Real Mac PIO is slow enough to have hidden
// this; scsi_bench --mode toolbox hits it on every LIST/GET. Hold REQ down for
// a few cycles after each advance. Scoped to the tb serve: tb_srv_hold is 0
// everywhere else regardless of the counter.
wire      tb_srv_active = (phase == PHASE_DATA_OUT) && (cmd_tb_fs_in || cmd_cdc_in);
// Mid-serve fetch abort (see tb_get_fault / TBS_STREAM). Scoped to the tb
// serve so the flag can never touch a disk/CD data phase.
assign tb_get_abort = tb_srv_active && tb_get_fault;
reg [3:0] tb_srv_settle = 4'd0;
always @(posedge clk) begin
	if (!tb_srv_active)                tb_srv_settle <= 4'd12;  // armed for the first byte
	else if (stb_adv)                  tb_srv_settle <= 4'd8;
	else if (tb_srv_settle != 4'd0)    tb_srv_settle <= tb_srv_settle - 1'b1;
end
assign tb_srv_hold = tb_srv_active && (tb_srv_settle != 4'd0);

// ---- streaming back-pressure (see the tb_stream_stall declaration) --------
// GET: stall while the byte being served -- or the +3 a longword read grabs
// with it -- lives in a sector the HPS has not delivered yet. tb_sec_done only
// advances on a completed fetch, so this can never hand out a stale word.
// The ahead term is clamped at the response tail (the same clamp rd_ahead_needed
// applies on the disk path): past the last sector no fetch will ever arrive and
// the host never consumes those bytes, so waiting for them would deadlock.
wire tb_get_stall = tb_srv_active &&
                    ((tb_srv_sec >= tb_sec_done) ||
                     ((tb_srv_sec_ahead < tb_nsec) && (tb_srv_sec_ahead >= tb_sec_done)));
// SEND: stall when the collect is about to reuse a ring slot whose previous
// occupant has not been shipped. The ring is TB_MAXSEC-1 payload slots, so the
// collect may run that far ahead of tb_ship_done and no further. In practice
// this never fires -- the Mac needs ~2.2 ms to fill a sector and the HPS takes
// ~0.5 ms to take one -- but it is what makes the design correct rather than
// merely fast enough.
// (tb_col_stall is defined with the collect logic -- the 0xD4 watchdog needs it)
assign tb_stream_stall = tb_get_stall || tb_col_stall;

// DEVICE INFO data (docs/BLUESCSI_HANDOFF.md §4.8): subcmd 0x00 LIST DEVICES ->
// 8 bytes; this target's own ID = 0x00 (fixed disk present), every other ID =
// 0xFF (absent). subcmd 0x01 GET CAPABILITIES -> API version 0 + cap flags; M0
// has no host transfer path so advertise 0x00 (force v0 paths) -> all zero.
// Bump caps when the HPS round trip lands (M2/M3).
// GET CAPABILITIES payload: byte 0 = API version (0), byte 1 = capability
// flags. 0x02 = CAP_LARGE_SEND, advertised only when the buffer can actually
// stage a 4 KB chunk — a client that sees the flag WILL send block-encoded
// chunks, so never advertise ahead of TB_ADDRW. 0x01 CAP_LARGE_TRANSFERS
// (multi-block 0xD1 GET) stays off until its read path has bench coverage.
//
// FORCED TO 0x00 (2026-07-31, HW-measured). CAP_LARGE_SEND means 32 KB sends
// in the BlueSCSI spec, but this core caps a 0xD4 chunk at TB_SEND_CAP (4 KB)
// and Main caps the write at TB_CHUNK_MAX (4 KB). JTAG CDB capture on the
// official BlueSCSI SD Transfer app: with 0x02 advertised it sends CDB[6]=127
// (65024-byte chunks) and advances its offset by the whole chunk, so ~94% of
// every upload was silently dropped -- a 2 MB file landed as 20480 bytes with
// 512 valid. With 0x00 the same app falls back to CDB[6]=1 (512-byte v0
// chunks) and a 2 MB upload round-trips BYTE-EXACT. Slower, but correct.
// Do not re-enable without honouring the full chunk end to end (core + HPS).
//
// NOTE: this does NOT fix downloads. The same capture shows the app issues
// 0xD1 with CDB[6]=16 (65536 B) regardless of what we advertise, while Main
// returns 4096 -- so exactly 1 block in 16 arrives (proven: a 2 MB download
// round-trips as 32 correct 4 KB blocks spaced 16 apart, 480 zero blocks, 0
// wrong). Fixing reads needs a streaming serve, not a capability flag.
// 2026-07-31 STAGE 2: flipped to 0x02 now that the core streams a full 64 KB
// chunk (TBS_COLL ships each payload sector as the Mac fills it, so the chunk
// size no longer has to fit the buffer). The client answers this advert by
// switching from 512-byte v0 sends to CDB[6]=127 (65024 B), which is ~8x fewer
// command round trips: 28 KiB/s measured -> ~220 KiB/s projected, against a
// 230 KiB/s data-phase ceiling.
//
// DEPLOY GATE: this is only safe once the RUNNING HPS accepts a 64 KB 0xD4
// chunk (TB_CHUNK_MAX 65536). Do not infer that from the Main source tree --
// on 2026-07-31 the deployed binary was a build that PREDATED its own commit
// and still truncated GET at 4096, proving source and binary had diverged.
// Verify against the box, not the repo. If the running HPS still caps at 4096,
// this advert costs ~94% of every upload (the 6ded62d regression).
// Clients gate each DIRECTION on a different bit: bit 1 (CAP_LARGE_SEND)
// sizes uploads (~120 KB/s vs 39 measured), bit 0 (CAP_LARGE_TRANSFERS)
// sizes downloads. 0x02 was the shipped value while bit 0 hid the GET race
// below.
//
// ★ BIT 0 (CAP_LARGE_TRANSFERS) STAYS OFF — it CRASHES the official client.
// The core-side stale-sector race that first blocked it IS fixed (see TBS_DATA:
// bounded retry, !tb_ack issue gates, loud CHECK on exhaustion; bench gate
// `scsi_bench --mode toolboxget`), and with bit 0 set MacAtrium downloads run
// 33 -> 91 KB/s byte-exact, 4x 2 MB round trips incl. one under an SD write
// storm. But advertising it makes the official BlueSCSI SD Transfer app
// (1.1.0b5) bomb the guest with "bad F-Line instruction" — a 68020
// unimplemented-instruction trap, i.e. the app jumping into garbage — at 0%,
// before any data moves and often before its own overwrite prompt, so the
// crash is in ITS capability-dependent setup path, not in our serve.
//
// HW A/B, 2026-08-01 PM, same app / file / procedure, each on a fresh boot:
//   0x03, race fix  (5a181d40): 3 of 4 runs bombed; the one survivor ran
//                               SLOWER (99 KB/s) and hung the machine after.
//   0x02, no fix    (914e07cc): 2 of 2 clean, 122-123 KB/s.
//   0x02, race fix  (3aaf1ed1): 2 of 2 clean, 121-123 KB/s.  <-- discriminator
// The last row is what pins the blame: same RTL fix, only the caps byte
// differs, and the app is clean. So bit 0 alone is the trigger and the fetch
// retry is exonerated (MacAtrium also ran the fixed multi-block GET path
// flawlessly). Do NOT re-enable bit 0 to chase MacAtrium download speed
// without a client that survives it -- it trades a working third-party app
// for one app's throughput.
//
// (The app's own pre-existing defect is unrelated and still present at 0x02:
// downloads >64 KB lose one byte per 64 KiB chunk. See the note below.)
//
// 2026-08-02: bit 7 is a VENDOR bit — "multi-block GET is safe" — so MacAtrium
// can size 32 KB GETs WITHOUT bit 0 (its read path passes LARGE_XFER|0x80; see
// MacAtrium toolbox.h TB_CAP_MISTER_XFER). Bit 7 is unallocated in the BlueSCSI
// caps byte as far as we know, so the official app should ignore it — that is
// an ASSUMPTION until the §4 gate test in
// the vendor-bit gate passes on hardware. If the
// official app bombs on 0x82 too, revert this line to 8'h02 (the fallback is
// MacAtrium detecting the core by INQUIRY instead — §7). Bit 0 stays CLEAR.
localparam [7:0] TB_CAPS = 8'h82;   // bit 7 = vendor multi-block GET; bit 1 = CAP_LARGE_SEND
function [7:0] tb_caps_byte;
	input [31:0] cnt;
	begin
		tb_caps_byte = (cnt == 32'd1) ? TB_CAPS : 8'h00;
	end
endfunction
wire [7:0] tb_devinfo_dout       = tb_devinfo_caps ? tb_caps_byte(data_cnt)       : (data_cnt       == {29'd0, ID}) ? 8'h00 : 8'hff;
wire [7:0] tb_devinfo_dout_next  = tb_devinfo_caps ? tb_caps_byte(data_cnt_next)  : (data_cnt_next  == {29'd0, ID}) ? 8'h00 : 8'hff;
wire [7:0] tb_devinfo_dout_next2 = tb_devinfo_caps ? tb_caps_byte(data_cnt_next2) : (data_cnt_next2 == {29'd0, ID}) ? 8'h00 : 8'hff;
wire [7:0] tb_devinfo_dout_next3 = tb_devinfo_caps ? tb_caps_byte(data_cnt_next3) : (data_cnt_next3 == {29'd0, ID}) ? 8'h00 : 8'hff;

// TOGGLE DEBUG (0xD6): a stored flag with no side effects, so the client's
// get/set round-trips succeed. get (CDB[1]!=0) returns the flag byte.
reg        tb_debug_flag;
wire [7:0] tb_debug_dout       = (data_cnt       == 32'd0) ? {7'd0, tb_debug_flag} : 8'h00;
wire [7:0] tb_debug_dout_next  = (data_cnt_next  == 32'd0) ? {7'd0, tb_debug_flag} : 8'h00;
wire [7:0] tb_debug_dout_next2 = (data_cnt_next2 == 32'd0) ? {7'd0, tb_debug_flag} : 8'h00;
wire [7:0] tb_debug_dout_next3 = (data_cnt_next3 == 32'd0) ? {7'd0, tb_debug_flag} : 8'h00;

// set (CDB[1]==0): latch CDB[2]!=0 at command completion. Single-driver always
// block (Quartus-clean); the flag is observable only via the 0xD6 get path.
always @(posedge clk) begin
	if (rst) tb_debug_flag <= 1'b0;
	else if (cmd_cpl && (phase == PHASE_CMD_IN) && cmd_tb_debug && (cmd[1] == 8'd0))
		tb_debug_flag <= (cmd[2] != 8'd0);
end

// ----- BlueSCSI Toolbox CD Changer (CDCHANGER_ENABLE; CD target / ID 3) ------
// 0xD7 LIST CDS + 0xDA COUNT CDS are DataIn HPS round-trips (serve the staged
// list/count exactly like the file-Toolbox 0xD0/D1/D2). 0xD8 SET NEXT CD is a
// status-only round-trip: the HPS remaps the CD image slot (VD_CDROM), whose
// img_mounted pulse drives the SAME media-change the OSD swap uses -- no extra
// RTL here. All gated on tb_ready so a stock Main (no CD-folder handler mounted
// on the changer slot) leaves them CHECK. docs/BLUESCSI_CD_CHANGER_CONTRACT.md
wire       cmd_cdc_list  = CDCHANGER_ENABLE && tb_ready && (op_code == 8'hd7);
wire       cmd_cdc_count = CDCHANGER_ENABLE && tb_ready && (op_code == 8'hda);
wire       cmd_cdc_set   = CDCHANGER_ENABLE && tb_ready && (op_code == 8'hd8);
wire       cmd_cdc_in    = cmd_cdc_list || cmd_cdc_count; // DataIn: serve HPS list/count
wire       cmd_cdc_tb    = cmd_cdc_in   || cmd_cdc_set;    // any changer op -> HPS round-trip

// valid command in buffer? TODO: check for valid command parameters
wire  cmd_ok_hd = cmd_read || cmd_write || cmd_inquiry || cmd_test_unit_ready ||
		  cmd_read_capacity || cmd_mode_select || cmd_format || cmd_mode_sense ||
		  cmd_read_buffer || cmd_write_buffer || cmd_verify6 || cmd_verify10 ||
		  cmd_request_sense || cmd_tb_devinfo || cmd_tb_debug ||
		  (cmd_tb_fs_in && tb_ready) ||  // fs DataIn ops valid only with a shared folder (else CHECK)
		  (cmd_tb_send  && tb_ready);    // fs DataOut (upload) ops, likewise

// CD-ROM command set: read-only — WRITE/FORMAT/buffer/verify are NOT accepted
// (CHECK CONDITION + ILLEGAL REQUEST), matching a real AppleCD drive.
wire  cmd_ok_cd = cmd_read || cmd_inquiry || cmd_test_unit_ready ||
		  cmd_read_capacity || cmd_mode_select || cmd_mode_sense ||
		  cmd_request_sense || cmd_cd_eject || cmd_cd_toc || cmd_cd_subq ||
		  cmd_cd_astat || cmd_cd_actl || cmd_cd_audio_nop ||
		  cmd_cd_toc43 || cmd_cd_subq43 || cmd_cd_hdr ||
		  cmd_cd_prevent || cmd_cd_startstop || cmd_cd_setspeed || cmd_cdc_tb;

wire  cmd_ok = (CDROM != 0) ? cmd_ok_cd : cmd_ok_hd;

// Media-dependent commands fail with the AppleCD no-disc sense while no image
// is mounted (MAME return_no_cd: SK_NOT_READY + vendor ASC 0xB0 — 0x3A makes
// MacOS "hammer the drive asking the user to format it", cd.cpp:1214).
wire  cd_needs_media = cmd_test_unit_ready || cmd_read || cmd_read_capacity ||
		  cmd_cd_toc || cmd_cd_subq || cmd_cd_astat || cmd_cd_actl ||
		  cmd_cd_toc43 || cmd_cd_subq43 || cmd_cd_hdr ||
		  cmd_cd_audio_nop;
wire  cd_no_media = (CDROM != 0) && !mounted && cd_needs_media;

// Data READs against a disc with no data track (pure audio CD) must CHECK
// with ILLEGAL REQUEST + ASC 0x64 "illegal mode for this track" — real
// AppleCD behavior (BlueSCSI/Snow). The Audio CD Access extension RELIES on
// this failure to classify the disc; serving audio bytes as data sends the
// Finder through garbage (2026-07-20 system error 10 at desktop mount).
wire  cd_audio_read_rej = (CDROM != 0) && mounted && cmd_read && ca_disc_audio;

// New-command strobe (one clk on the CDB completing). Used by the CD sense /
// eject logic; folds away on disk targets.
reg   cd_cpl_d = 1'b0;
always @(posedge clk) cd_cpl_d <= (phase == PHASE_CMD_IN) && cmd_cpl;
wire  cd_new_cmd = (phase == PHASE_CMD_IN) && cmd_cpl && !cd_cpl_d;
// BOTH eject forms, one wire: Apple vendor EJECT (0xC0) AND the standard SCSI
// START/STOP UNIT (0x1B) with LoEj=1/Start=0. The System 7.1 AppleCD driver
// ejects via the 0x1B form (HW watch 2026-07-27: Finder Put Away returned GOOD
// but `mounted` never dropped, so the driver's no-media insertion poll saw
// READY and silently REMOUNTED the volume ~10 s later — the guest could never
// empty the drive, which is also why a BlueSCSI-changer disc-to-disc swap was
// invisible: no media-change edge ever existed). The audio engine already
// treated 0x1B-LoEj as an eject (ca_eject_stb below); the MEDIA state must too.
wire  cmd_cd_eject_any = cmd_cd_eject ||
                         (cmd_cd_startstop && cmd[4][1] && !cmd[4][0]);
wire  cd_eject_pulse = cd_new_cmd && cmd_cd_eject_any && !cd_prevent;

// REQUEST SENSE state (CDROM only): key/ASC latched when a command CHECKs,
// cleared by the next successful non-REQUEST-SENSE command (SCSI-1 semantics).
reg [3:0] cd_sense_key = 4'd0;
reg [7:0] cd_sense_asc = 8'd0;
// JTAG CDA1 probe regs: every dispatched command latches its opcode; the
// accept/reject flag tells whether cmd_ok took it (a rejected PLAY is the
// interesting datum). Driven from the main phase FSM block only.
reg [7:0] dbg_last_op = 8'd0;
// CDA2: the exact 0xC1 READ TOC request the guest last issued —
// {cdb9 (operation bits), cdb5 (start track BCD), cdb7:cdb8 (allocation)}.
// The served bytes are fully determined by these + the resp plane, so this
// pins down the "player shows 2 tracks" divergence (2026-07-18).
reg [31:0] dbg_toc_cdb = 32'd0;
// CDA3/CDA4: full CDB of the last PLAY-CLASS command (0x47/48/4B/4E and the
// vendor C8..CD set) — the 0x42 position-poll flood (4/s during playback)
// overwrites dbg_last_op within 250 ms, so the skip-failure ask (2026-07-20:
// skip during playback lands the engine idle, player shows track 0) is
// unrecoverable from CDA1 alone. {op,cdb3,cdb4,cdb5} + {cdb1,cdb6,cdb7,cdb8}
// reconstruct every play form (MSF, TRACK/INDEX, pause/resume flag).
reg [31:0] dbg_play_cdb  = 32'd0;
reg [31:0] dbg_play_cdb2 = 32'd0;
wire cmd_play_class = (op_code == 8'h47) || (op_code == 8'h48) ||
                      (op_code == 8'h4b) || (op_code == 8'h4e) ||
                      (op_code == 8'h45) || (op_code == 8'ha5) ||
                      (op_code == 8'hc8) || (op_code == 8'hc9) ||
                      (op_code == 8'hca) || (op_code == 8'hcb) ||
                      (op_code == 8'hcd) ||
                      (op_code == 8'h01) ||
                      (op_code == 8'h0b) || (op_code == 8'h2b);
reg [7:0] dbg_cmd_cnt = 8'd0;
reg       dbg_last_ok = 1'b0;
assign dbg_cda2 = dbg_toc_cdb;
assign dbg_cda3 = dbg_play_cdb;
assign dbg_cda4 = dbg_play_cdb2;
assign dbg_cda1 = { ca_toc_ready, cd_no_media, mounted, dbg_last_ok,
                    cd_sense_asc, cd_sense_key, dbg_cmd_cnt, dbg_last_op };
reg       cd_prevent   = 1'b0;
always @(posedge clk) begin
	if (rst) begin
		cd_sense_key <= 4'd0;
		cd_sense_asc <= 8'd0;
		cd_prevent   <= 1'b0;
	end else if ((CDROM != 0) && cd_new_cmd) begin
		if (cmd_play_class) begin
			dbg_play_cdb  <= {op_code, cmd[3], cmd[4], cmd[5]};
			dbg_play_cdb2 <= {cmd[1], cmd[6], cmd[7], cmd[8]};
		end
		if (!cmd_ok) begin
			cd_sense_key <= 4'h5;  // ILLEGAL REQUEST
			cd_sense_asc <= 8'h20; // invalid operation code
		end else if (cd_no_media) begin
			cd_sense_key <= 4'h2;  // NOT READY
			cd_sense_asc <= 8'hb0; // AppleCD vendor "no disc"
		end else if (cd_audio_read_rej) begin
			cd_sense_key <= 4'h5;  // ILLEGAL REQUEST
			cd_sense_asc <= 8'h64; // illegal mode for this track
		end else if (cd_hdr_msf_rej) begin
			cd_sense_key <= 4'h5;  // ILLEGAL REQUEST
			cd_sense_asc <= 8'h24; // invalid field in CDB (READ HEADER MSF form)
		end else if (cmd_cd_eject_any) begin
			if (cd_prevent) begin
				cd_sense_key <= 4'h5; // ILLEGAL REQUEST
				cd_sense_asc <= 8'h80; // "prevent bit is set" (MAME)
			end else begin
				cd_sense_key <= 4'h2;  // NOT READY
				cd_sense_asc <= 8'h3a; // medium not present (post-eject, MAME)
			end
		end else if (cmd_cd_prevent) begin
			cd_prevent   <= cmd[4][0];
			cd_sense_key <= 4'd0;
			cd_sense_asc <= 8'd0;
		end else if (!cmd_request_sense) begin
			cd_sense_key <= 4'd0;
			cd_sense_asc <= 8'd0;
		end
	end
end

// latch parameters once command is complete
reg [31:0] lba;
reg [15:0] tlen;

always @(posedge clk) begin
	if (old_io_ack & ~io_ack) lba <= lba + 1'd1;
	if(cmd_cpl && (phase == PHASE_CMD_IN)) begin
		// CDROM READs address 2048-byte logical blocks; the HPS block device
		// is 512-byte sectors, so scale lba/tlen by 4 AT LATCH TIME and the
		// whole downstream ring/flush/data_len machinery runs unmodified in
		// 512-byte units. Non-READ commands keep raw CDB values (their
		// lengths are byte counts, e.g. MODE SELECT / AUDIO CONTROL).
		if ((CDROM != 0) && cmd_read) begin
			lba  <= (cmd6_cpl?{11'd0, lba6}:lba10) << 2;
			tlen <= (cmd6_cpl?{7'd0, tlen6}:tlen10) << 2;
		end else begin
			lba <= cmd6_cpl?{11'd0, lba6}:lba10;
			tlen <= cmd6_cpl?{7'd0, tlen6}:tlen10;
		end
	end
end
   
// logical block address
wire [7:0] cmd1 = cmd[1];
wire [20:0] lba6 = { cmd1[4:0], cmd[2], cmd[3] };
wire [31:0] lba10 = { cmd[2], cmd[3], cmd[4], cmd[5] };

// transfer length
wire [8:0]  tlen6 = (cmd[4] == 0)?9'd256:{1'b0,cmd[4]};
wire [15:0] tlen10 = { cmd[7], cmd[8] };


// the 5380 changes phase in the falling edge, thus we monitor it
// on the rising edge
//
always @(posedge clk) begin
	if(rst) begin
		phase <= PHASE_IDLE;
		ca_cmd_stb <= 1'b0; ca_read_stb <= 1'b0; ca_eject_stb <= 1'b0;
	end else begin
		// CD-audio engine strobes: 1-clk pulses on command acceptance below
		ca_cmd_stb <= 1'b0; ca_read_stb <= 1'b0; ca_eject_stb <= 1'b0;
		if(phase == PHASE_IDLE) begin
			// Own id on bus during selection? Real SCSI selection requires a
			// FREE bus (SEL asserted, BSY false): while another device holds
			// BSY its dout is wired-ORed onto the data bus, so a stray bit in
			// that byte could otherwise "select" this target mid-dialog and
			// two targets would then consume the shared ACK stream in
			// parallel (command/LBA corruption -> misdirected writes).
			// A CD-ROM drive is present on the bus even with no disc inserted
			// (the AppleCD driver polls TEST UNIT READY to detect insertion),
			// so the CDROM target selects on cd_enable instead of mounted.
			if(sel && din[ID] && ((CDROM != 0) ? cd_enable : mounted) && !bus_busy)
				phase <= PHASE_CMD_IN;
		end

		else if(phase == PHASE_CMD_IN) begin
			// check if a full command is in the buffer
			if(cmd_cpl) begin
				$display("New command on target %d: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x", ID, cmd[0], cmd[1], cmd[2], cmd[3], cmd[4], cmd[5], cmd[6], cmd[7], cmd[8], cmd[9]);
				// is this a supported and valid command?
				// (CDROM: media-dependent commands CHECK with the no-disc
				// sense while unmounted; a prevent-blocked EJECT CHECKs too.)
				if(cmd_ok && !cd_no_media && !cd_audio_read_rej && !cd_hdr_msf_rej) begin
					// yes, continue
					status <= (cmd_cd_eject_any && cd_prevent) ? `STATUS_CHECK_CONDITION : `STATUS_OK;

					// notify the CD-audio engine (all constant 0 on disks)
					ca_cmd_stb   <= cmd_cd_audio_nop;
					dbg_last_op <= op_code;
					// latch ONLY op-0x80 (per-track descriptor) asks: the player's
					// launch-time track walk is the datum; the periodic op00/op40
					// refresh was overwriting it before we could read (2026-07-19).
					if (cmd_cd_toc43) dbg_toc_cdb <= {cmd[9], cmd[6], cmd[7], cmd[8]};
					dbg_cmd_cnt <= dbg_cmd_cnt + 8'd1;
					dbg_last_ok <= 1'b1;
					ca_read_stb  <= cmd_read && (CDROM != 0);
					ca_eject_stb <= cmd_cd_eject_any && !cd_prevent;

					// continue according to command

					// these commands return data
					if(cmd_tb_fs_in || cmd_cdc_tb) phase <= PHASE_TB;   // toolbox fs DataIn OR CD-changer (list/count DataIn + set status-only): HPS round-trip
						else if(cmd_tb_send_end) phase <= PHASE_TB;       // SEND END: no payload, straight to round-trip
						else if(cmd_tb_send_pay) phase <= PHASE_DATA_IN;  // SEND PREP/DATA: collect the DataOut payload first
						else if(cmd_read || cmd_inquiry || cmd_read_capacity || cmd_mode_sense || cmd_read_buffer || cmd_request_sense || cmd_tb_devinfo || cmd_tb_debug_get || cmd_cd_toc || cmd_cd_subq || cmd_cd_astat || cmd_cd_toc43 || cmd_cd_subq43 || cmd_cd_hdr) phase <= PHASE_DATA_OUT;
					// these commands receive dataa
					else if(cmd_write || cmd_mode_select || cmd_write_buffer || cmd_cd_actl) phase <= PHASE_DATA_IN;
					// and all other valid commands are just "ok"
					else phase <= PHASE_STATUS_OUT;
				end else begin
					// no, report failure
					dbg_last_op <= op_code;
					dbg_cmd_cnt <= dbg_cmd_cnt + 8'd1;
					dbg_last_ok <= 1'b0;
					status <= `STATUS_CHECK_CONDITION;
					phase <= PHASE_STATUS_OUT;
				end
			end
		end

		else if(phase == PHASE_TB) begin
			// round-trip done: adopt the HPS status, then serve DataIn or finish.
			// TBS_STREAM counts as ready: the status block and the first data
			// sector are in, and the remaining sectors arrive behind the serve.
			if((tb_state == TBS_RDY) || (tb_state == TBS_STREAM)) begin
				status <= tb_status;
				phase  <= (tb_len != 17'd0) ? PHASE_DATA_OUT : PHASE_STATUS_OUT;
			end
		end

		else if(phase == PHASE_DATA_OUT) begin
			if(data_done) begin
				phase <= PHASE_STATUS_OUT;
				// GET fetch abort mid-serve: the GOOD status latched at the
				// PHASE_TB handoff must not survive a short transfer — the
				// initiator gets CHECK, not silence (tb_get_fault, TBS_STREAM).
				if(tb_get_abort) status <= `STATUS_CHECK_CONDITION;
			end
		end

		else if(phase == PHASE_DATA_IN) begin
			// SEND (upload): once the DataOut payload has landed in the toolbox
			// buffer, run the HPS round-trip (write CDB+payload, read status).
			// Disk writes still go straight to STATUS.
			if(data_done) phase <= cmd_tb_send ? PHASE_TB : PHASE_STATUS_OUT;
		end

		else if(phase == PHASE_STATUS_OUT) begin
			if(status_sent) phase <= PHASE_MESSAGE_OUT;
		end

		else if(phase == PHASE_MESSAGE_OUT) begin
			if(message_sent) phase <= PHASE_IDLE;
		end
		
		else
			phase <= PHASE_IDLE;  // should never happen
	end
end

// ----------------------------------------------------------------------
// JTAG debug: REQ/ACK handshake observations (sticky since reset).
//   [7:4] max command bytes received (cmd_cnt high-water)
//   [3]   cmd_cpl seen (a full command was assembled)
//   [2]   Mac ACKed a command byte  (stb_adv in CMD_IN)
//   [1]   target asserted REQ in STATUS_OUT
//   [0]   Mac ACKed the status byte (stb_adv in STATUS_OUT)
// ----------------------------------------------------------------------
reg [3:0] dbg_max_cmd_cnt;
reg       dbg_cmd_cpl, dbg_ack_in_cmd, dbg_req_in_status, dbg_ack_in_status;
always @(posedge clk) begin
	if(rst) begin
		dbg_max_cmd_cnt   <= 4'd0;
		dbg_cmd_cpl       <= 1'b0;
		dbg_ack_in_cmd    <= 1'b0;
		dbg_req_in_status <= 1'b0;
		dbg_ack_in_status <= 1'b0;
	end else begin
		if((phase == PHASE_CMD_IN) && (cmd_cnt > dbg_max_cmd_cnt)) dbg_max_cmd_cnt <= cmd_cnt;
		if((phase == PHASE_CMD_IN) && cmd_cpl)  dbg_cmd_cpl       <= 1'b1;
		if((phase == PHASE_CMD_IN) && stb_adv)  dbg_ack_in_cmd    <= 1'b1;
		if((phase == PHASE_STATUS_OUT) && req)  dbg_req_in_status <= 1'b1;
		if((phase == PHASE_STATUS_OUT) && stb_adv) dbg_ack_in_status <= 1'b1;
	end
end
assign dbg_hs = { dbg_max_cmd_cnt, dbg_cmd_cpl, dbg_ack_in_cmd,
                  dbg_req_in_status, dbg_ack_in_status };

// Completion-phase flags that DELIBERATELY survive a SCSI bus reset (no rst
// clause), so they accumulate the truth across the Mac's reset/retry cycles:
//   [3] status byte was ACKed (status_sent fired) in STATUS_OUT
//   [2] target ever reached MSG_OUT
//   [1] Mac re-asserted SEL while we were in STATUS_OUT (mid-command select)
//   [0] Mac ever ACKed a MESSAGE byte (stb_adv in MSG_OUT)
reg dbg_status_sent_ever, dbg_reached_msg_ever, dbg_sel_in_status_ever, dbg_ack_in_msg_ever;
always @(posedge clk) begin
	if((phase == PHASE_STATUS_OUT) && stb_adv) dbg_status_sent_ever  <= 1'b1;
	if(phase == PHASE_MESSAGE_OUT)             dbg_reached_msg_ever   <= 1'b1;
	if((phase == PHASE_STATUS_OUT) && sel)     dbg_sel_in_status_ever <= 1'b1;
	if((phase == PHASE_MESSAGE_OUT) && stb_adv) dbg_ack_in_msg_ever   <= 1'b1;
end
assign dbg_hs2 = { dbg_status_sent_ever, dbg_reached_msg_ever,
                   dbg_sel_in_status_ever, dbg_ack_in_msg_ever };

// Sticky bitmap of which command types the initiator issued to this target.
// Survives bus reset so it shows everything the Mac tried across retries.
//   [7]=READ [6]=WRITE [5]=INQUIRY [4]=TEST_UNIT_READY
//   [3]=READ_CAPACITY [2]=MODE_SENSE [1]=unsupported(cmd_ok=0) [0]=REQUEST_SENSE
// Repurposed: capture the LAST opcode the initiator sent to this target
// (any command, not just unsupported -- unsupported was always 0x00).
// Survives bus reset so it shows the most recent command the Mac issued
// before it gave up and re-scanned, revealing the boot-logic reject point.
reg [7:0] dbg_unsup_op;
reg       cmd_cpl_d2;
always @(posedge clk) begin
	cmd_cpl_d2 <= (phase == PHASE_CMD_IN) && cmd_cpl;
	if((phase == PHASE_CMD_IN) && cmd_cpl && !cmd_cpl_d2)
		dbg_unsup_op <= op_code;
end
assign dbg_cmd = dbg_unsup_op;

// JTAG debug: capture byte0 and byte1 of the FIRST word write exactly as the
// target latches them (din at buffer0[0] / buffer1[0]), plus the ncr5380's
// intended odd byte and word/longword flags at that moment. Sticky.
//   If dbg_b1 == dbg_b0 (and != dbg_low_l) the low byte never reached the
//   target (the serialization drops it); dbg_word_l shows whether the
//   word-write path was even engaged.
reg [7:0] dbg_b0, dbg_b1;
reg       dbg_b0_seen, dbg_b1_seen;
reg [7:0] dbg_low_l;
reg       dbg_word_l, dbg_long_l;
// Trigger on the first MULTI-BLOCK write (tlen >= 2) so the captured bytes
// carry the bench's full non-zero pattern (e.g. 1KB test: byte0=2, byte1=3).
// The 1B/512B tests (tlen==1) and the tiny JSONL result writes are skipped —
// their first word is all-zero/stale and can't distinguish the bug.
wire dbg_capture_ok = (phase == PHASE_DATA_IN) && (|tlen[15:1]);
always @(posedge clk) begin
	if (buffer0_wr && dbg_capture_ok && (data_cnt[9:1] == 9'd0) && !dbg_b0_seen) begin
		dbg_b0      <= din;
		dbg_low_l   <= dbg_dma_lowbyte;
		dbg_word_l  <= dbg_dma_word;
		dbg_long_l  <= dbg_dma_long;
		dbg_b0_seen <= 1'b1;
	end
	if (buffer1_wr && dbg_capture_ok && (data_cnt[9:1] == 9'd0) && !dbg_b1_seen) begin
		dbg_b1      <= din;
		dbg_b1_seen <= 1'b1;
	end
end
assign dbg_wrsnap = { 4'd0, dbg_b1_seen, dbg_b0_seen, dbg_long_l, dbg_word_l,
                      dbg_low_l, dbg_b1, dbg_b0 };

// ---- Bus-reset snapshot (PSCW probe, repurposed for selection/reset forensics) ----
// The read-abort probe returned valid=0 — reads do NOT die mid-transfer; the wedge
// and the bus resets cluster in the selection/scan path. So capture, at the FIRST
// SCSI bus reset (rst = the Mac asserting ICR.RST), HOW FAR the transaction that
// triggered it actually got: the high-water phase this window (IDLE => target never
// left IDLE = selection never succeeded; CMD_IN => command failed; DATA/STATUS/MSG
// => transaction progressed), whether a cmd_read COMPLETED, whether SEL was ever
// asserted, and the last full command opcode. win_* accumulate per window (since the
// previous reset) and snapshot into the sticky brst_* at the reset edge. brst_*
// survive rst (initial only). Phase encoding is monotonic with progress (IDLE0 <
// CMD_IN1 < DATA2/3 < STATUS4 < MSG5), so the numeric max IS the furthest phase.
reg  [2:0] win_maxphase;   // high-water phase since the last bus reset
reg        win_read_done;  // a cmd_read DATA_OUT reached data_complete this window
reg  [7:0] win_lastop;     // last full command opcode assembled
reg        win_sel_seen;   // SEL asserted this window
reg        brst_rst_d;
reg        brst_valid;
reg  [2:0] brst_maxphase;
reg        brst_read_done;
reg        brst_sel_seen;
reg  [6:0] brst_count;
reg  [7:0] brst_lastop;
initial begin
	win_maxphase = 0; win_read_done = 0; win_lastop = 0; win_sel_seen = 0;
	brst_rst_d = 0; brst_valid = 0; brst_maxphase = 0; brst_read_done = 0;
	brst_sel_seen = 0; brst_count = 0; brst_lastop = 0;
end
always @(posedge clk) begin
	brst_rst_d <= rst;
	// per-window accumulation
	if (phase > win_maxphase)                                   win_maxphase  <= phase;
	if (cmd_read && (phase == PHASE_DATA_OUT) && data_complete) win_read_done <= 1'b1;
	if (cmd_cpl && (phase == PHASE_CMD_IN))                     win_lastop    <= cmd[0];
	if (sel)                                                    win_sel_seen  <= 1'b1;
	// bus-reset rising edge: snapshot this window, then clear for the next
	if (rst && !brst_rst_d) begin
		if (brst_count != 7'h7F) brst_count <= brst_count + 7'd1;
		if (!brst_valid) begin
			brst_valid     <= 1'b1;
			brst_maxphase  <= win_maxphase;
			brst_read_done <= win_read_done;
			brst_sel_seen  <= win_sel_seen;
			brst_lastop    <= win_lastop;
		end
		win_maxphase  <= 3'd0;
		win_read_done <= 1'b0;
		win_sel_seen  <= 1'b0;
	end
end
//  PSCW layout: [31]=valid [30:28]=brst_maxphase [27]=read_done [26]=sel_seen
//               [25:19]=reset_count(7) [18:11]=last_opcode(8)
//               [10:8]=live win_maxphase [7]=live win_read_done [6:0]=0
assign dbg_wrstall = { brst_valid, brst_maxphase, brst_read_done, brst_sel_seen,
                       brst_count, brst_lastop, win_maxphase, win_read_done, 7'd0 };

// ---- WRFB: write-data-phase first-beat forensics (2026-07-28) -------------
// For the one-inserted-byte-per-64KB-unit corruption hunt: if a WRITE
// command's first data beat ever arrives with data_cnt[0]=1, or the
// byte/word pseudo-DMA mode flips mid-phase, the odd_byte_r lane pairing
// slips one byte for the rest of the command — exactly the observed
// signature. Latched per DATA_IN phase of a block-write command; read live
// while an install runs and correlate against the corrupt 64 KB spans.
//   [31:24]=write-phase serial (wraps)  [23:16]=mode flips this phase (sat)
//   [15:8]=first beat's din  [7:2]=CUMULATIVE count of write phases whose
//   FIRST word-mode beat arrived at odd data_cnt (sat 63 — the direct
//   slip-trigger counter; with the beat-role fix in, nonzero here plus a
//   clean extract diff = trigger occurred AND was handled)
//   [1]=first-beat dbg_dma_word
//   [0]=first-beat data_cnt[0] (law: 0; 1 = the smoking gun)
reg  [7:0] wrfb_cmds  = 8'd0;
reg  [7:0] wrfb_flips = 8'd0;
reg  [7:0] wrfb_byte0 = 8'd0;
reg  [5:0] wrfb_oddw  = 6'd0;
reg        wrfb_par0  = 1'b0;
reg        wrfb_word0 = 1'b0;
reg        wrfb_armed = 1'b0;
reg        wrfb_wmseen= 1'b0;
reg        wrfb_dma_d = 1'b0;
always @(posedge clk) begin
	wrfb_dma_d <= dbg_dma_word;
	if (phase != PHASE_DATA_IN || !cmd_write) begin
		wrfb_armed  <= 1'b1;
		wrfb_wmseen <= 1'b0;
	end else begin
		if (stb_ack && wrfb_armed) begin
			wrfb_armed <= 1'b0;
			wrfb_cmds  <= wrfb_cmds + 8'd1;
			wrfb_byte0 <= din;
			wrfb_par0  <= data_cnt[0];
			wrfb_word0 <= dbg_dma_word;
			wrfb_flips <= 8'd0;
		end
		else if (!wrfb_armed && (dbg_dma_word != wrfb_dma_d) && (wrfb_flips != 8'hFF))
			wrfb_flips <= wrfb_flips + 8'd1;
		// first word-mode beat of this write phase: odd parity = the slip trigger
		if (stb_ack && dbg_dma_word && !wrfb_wmseen) begin
			wrfb_wmseen <= 1'b1;
			if (data_cnt[0] && wrfb_oddw != 6'h3F)
				wrfb_oddw <= wrfb_oddw + 6'd1;
		end
	end
end
assign dbg_wrfb = { wrfb_cmds, wrfb_flips, wrfb_byte0, wrfb_oddw, wrfb_word0, wrfb_par0 };

// ---- Selection/command handshake observability (PSEL probe) -----------
// Live state {phase,sel,bsy,req,ack} plus sticky high-water/counters that
// SURVIVE bus reset (no rst clause) so they accumulate across the
// reset/reselect retry loop. Key indicators for the REQ-vs-SEL fix:
//   reached_data : did a transfer ever get past CMD_IN to a DATA phase?
//   req_while_sel: REQ rising edges observed while SEL was still asserted
//                  (was impossible with the old !sel gate; nonzero => fix live)
//   cmd_bytes    : command bytes ACKed in CMD_IN (does the command advance?)
//   max_phase    : highest target phase reached.
reg [2:0] dbg_max_phase;
reg       dbg_reached_data;
reg [7:0] dbg_req_while_sel;
reg [7:0] dbg_cmd_bytes;
reg       dbg_req_d;
initial begin
	dbg_max_phase = 0; dbg_reached_data = 0; dbg_req_while_sel = 0;
	dbg_cmd_bytes = 0; dbg_req_d = 0;
end
always @(posedge clk) begin
	dbg_req_d <= req;
	if (phase > dbg_max_phase) dbg_max_phase <= phase;
	if (phase == PHASE_DATA_OUT || phase == PHASE_DATA_IN) dbg_reached_data <= 1'b1;
	if (req && sel && !dbg_req_d && dbg_req_while_sel != 8'hFF)
		dbg_req_while_sel <= dbg_req_while_sel + 8'd1;
	if (phase == PHASE_CMD_IN && stb_adv && dbg_cmd_bytes != 8'hFF)
		dbg_cmd_bytes <= dbg_cmd_bytes + 8'd1;
end
assign dbg_selsnap = { 5'd0, dbg_cmd_bytes, dbg_req_while_sel, dbg_reached_data,
                       ack, req, bsy, sel, dbg_max_phase, phase };

endmodule

module scsi_dpram #(parameter DATAWIDTH=8, ADDRWIDTH=9)
(
	input	                clock,

	input	[ADDRWIDTH-1:0] address_a,
	input	[DATAWIDTH-1:0] data_a,
	input	                wren_a,
	output reg [DATAWIDTH-1:0] q_a,

	input	[ADDRWIDTH-1:0] address_b,
	input	[DATAWIDTH-1:0] data_b,
	input	                wren_b,
	output reg [DATAWIDTH-1:0] q_b,

	input	[ADDRWIDTH-1:0] address_c,
	output reg [DATAWIDTH-1:0] q_c,

	input	[ADDRWIDTH-1:0] address_d,
	output reg [DATAWIDTH-1:0] q_d
);

// ram_ab is the ONLY storage array (pdma-prefetch redesign, 2026-07-17).
// The former ram_c/ram_d arrays were full mirror COPIES of the buffer whose
// only job was serving same-cycle look-ahead reads at address_c/address_d
// (mac_addr+1/+2 for the pseudo-DMA word/longword assembly). Across the six
// ring instances they cost ~48 M10K blocks and drove the device to 553/553
// saturation. They are replaced by a prefetch controller that reads the
// look-ahead bytes through IDLE port-B cycles into q_c/q_d holding registers.
//
// TIMING CONTRACT (what makes this legal): ncr5380 samples dout/dout_pair/
// dout_pair_next ONLY at DREQ-gated instants, and holds DREQ down for
// dma_settle cycles after every ACK train (= after every data_cnt advance).
// The controller needs at most 3 port-B cycles after an address change
// (read addr_c, read addr_d, restore address_b) — q_b/q_c/q_d are all
// consistent no later than 7 clocks after the advance; dma_settle is
// widened to 8 in ncr5380.sv to cover it. Port-B WRITES always win
// arbitration (the controller defers and retries), so write cycles are
// never disturbed and never mis-addressed.
//
// COHERENCY: a write on either port that lands on a prefetched (or
// in-flight) look-ahead address marks the prefetch stale; the controller
// refetches, and the post-write read returns the fresh data. No forwarding
// paths — the RAM is always the single source of truth.
// M10K pin per the migrating fabric-fallback law (bae8fd8 on add-cd-audio;
// this redesign was authored from master and the 2544a1f merge took it
// wholesale, silently dropping the pin — found 2026-07-18 by the MacIIvi
// port review). ram_ab has never flipped (TDP shape infers reliably), so
// this is insurance, not a bug fix; expect zero delta in the map audit.
(* ramstyle = "M10K,no_rw_check" *) reg [DATAWIDTH-1:0] ram_ab[0:(1<<ADDRWIDTH)-1];

// ---- port A: HPS side (behavior unchanged) -------------------------------
always @(posedge clock) begin
	if(wren_a) begin
		ram_ab[address_a] <= data_a;
		q_a <= data_a;
	end else begin
		q_a <= ram_ab[address_a];
	end
end

// ---- look-ahead prefetch controller --------------------------------------
localparam PF_IDLE = 2'd0, PF_RDC = 2'd1, PF_RDD = 2'd2;
reg [1:0]           pf_st      = PF_IDLE;
reg [ADDRWIDTH-1:0] pf_c_addr  = {ADDRWIDTH{1'b1}}; // addresses q_c/q_d hold
reg [ADDRWIDTH-1:0] pf_d_addr  = {ADDRWIDTH{1'b1}};
reg [ADDRWIDTH-1:0] pf_c_tgt, pf_d_tgt;             // addresses in flight
reg                 pf_valid   = 1'b0;
reg                 pf_snooped = 1'b0;

wire pf_snoop_hit =
	(wren_a && (address_a == pf_c_addr || address_a == pf_d_addr ||
	            (pf_st != PF_IDLE && (address_a == pf_c_tgt || address_a == pf_d_tgt)) ||
	            // (2026-07-29) steal-LAUNCH cycle: the address_c read issues
	            // THIS cycle (pf_st still PF_IDLE, targets not latched yet),
	            // so the in-flight clause above cannot see a same-cycle
	            // port-A write to it; no_rw_check M10K returns OLD data on
	            // the cross-port collision and the stale byte would commit
	            // to q_c. (address_d needs no term: its read issues NEXT
	            // cycle, after such a write has landed.)
	            (pf_steal_c && address_a == address_c))) ||
	(wren_b && (address_b == pf_c_addr || address_b == pf_d_addr ||
	            (pf_st != PF_IDLE && (address_b == pf_c_tgt || address_b == pf_d_tgt))));

wire pf_stale = !pf_valid || pf_snooped ||
                (address_c != pf_c_addr) || (address_d != pf_d_addr);

// Port-B address mux: a stolen read presents the look-ahead address for one
// cycle; its result lands in q_b (port B's read register) and is copied into
// q_c/q_d in the following state. Writes always use the real address_b.
wire pf_steal_c = (pf_st == PF_IDLE) && pf_stale && !wren_b;
wire pf_steal_d = (pf_st == PF_RDC)  && !wren_b;
wire [ADDRWIDTH-1:0] address_b_eff =
	pf_steal_c ? address_c :
	pf_steal_d ? pf_d_tgt  :
	             address_b;

// ---- port B: Mac side + stolen prefetch reads ----------------------------
// Single-address TDP port: write and read MUST share one address or Quartus
// refuses RAM inference (Error 276003, all rings -> ~300K registers). The
// steal mux guarantees address_b_eff == address_b whenever wren_b is high
// (both steal conditions carry !wren_b), so writing at address_b_eff is
// bit-identical to writing at address_b.
always @(posedge clock) begin
	if(wren_b) begin
		ram_ab[address_b_eff] <= data_b;
		q_b <= data_b;
	end else begin
		q_b <= ram_ab[address_b_eff];
	end
end

// ---- controller sequencing + q_c/q_d capture -----------------------------
always @(posedge clock) begin
	case (pf_st)
		PF_IDLE: begin
			if (pf_snoop_hit) pf_snooped <= 1'b1;
			if (pf_steal_c) begin
				pf_c_tgt <= address_c;
				pf_d_tgt <= address_d;
				pf_st    <= PF_RDC;
			end
		end
		PF_RDC: begin
			if (pf_snoop_hit) pf_snooped <= 1'b1;
			q_c <= q_b;                    // ram[pf_c_tgt], read during PF_IDLE steal
			pf_st <= pf_steal_d ? PF_RDD : PF_IDLE; // wren_b stole the D cycle: abort+retry
		end
		PF_RDD: begin
			q_d <= q_b;                    // ram[pf_d_tgt], read during PF_RDC steal
			if (!pf_snooped && !pf_snoop_hit) begin
				pf_c_addr <= pf_c_tgt;
				pf_d_addr <= pf_d_tgt;
				pf_valid  <= 1'b1;
			end else begin
				// (2026-08-14) A snooped fetch may have CAPTURED COLLIDED
				// DATA: the port-B read of pf_c_tgt (steal-launch cycle) or
				// pf_d_tgt (PF_RDC cycle) can issue in the same cycle a
				// port-A write lands on that address, and the no_rw_check
				// M10K returns the PRE-write byte into q_b -> q_c/q_d.
				// Declining to publish is NOT an invalidation: if an earlier
				// fetch already published these same addresses, pf_valid is
				// still 1 and the addresses still compare equal, so pf_stale
				// stays false and no refetch ever launches — the stale byte
				// is served as valid PERMANENTLY. Every virgin-slot
				// sequential HPS fill hits this (q_d holds $00 for the real
				// byte); consumed only by the odd-data_cnt arm of
				// din_pair_next, which is why word-aligned transfers never
				// saw it. Found by the MacLC_pocket fork (their
				// docs/mystery_b_root_cause.md: a compressed CODE resource
				// lost $2C00, desync'd the instruction stream, and returned
				// into the boot blocks' 'LK' signature -> deterministic
				// Sad-Mac ~15-20 s into boot). The discard must INVALIDATE
				// so pf_stale forces the refetch the COHERENCY note above
				// already promises. pf_snooped is cleared this same cycle
				// and nothing else remembers the poisoning — do NOT fold
				// this into the publish condition or into pf_stale.
				// Guarded by verilator/tb_scsi_pf.v (fails without this).
				pf_valid <= 1'b0;
			end
			pf_snooped <= 1'b0;
			pf_st      <= PF_IDLE;
		end
		default: pf_st <= PF_IDLE;
	endcase
end

endmodule
