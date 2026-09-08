//============================================================================
//  scsi_cache -- a per-target block cache between the SCSI engine and the
//  MiSTer HPS block-device channel (hps_io).
//
//  SGI: PORTED FROM MacQuadra800_MiSTer rtl/scsi_cache.sv (tip 40c3f13,
//  2026-09-08; docs/scsi-block-cache.md there is the design note, and the
//  bench in this repo's verilator/tb_scsi_cache.sv came with it). It sits in
//  rtl/scsi/sgi_scsi.sv between the scsi.v targets and the sd_* ports; the
//  engine-side contract below is the one hps_io offers, which is why scsi.v
//  did not change. The initiator over there is a 53C96 and here a WD33C93,
//  and neither side of this module can tell.
//
//  What differs from the Mac file, all marked `SGI:`:
//    * `img_blocks` (the 32-bit block count sgi_scsi already carries) is the
//      mount-size tag, in place of hps_io's 64-bit img_size;
//    * `stat_hits` / `stat_misses` are 32 bits and `stat_writes` counts the
//      sectors accepted from the engine, for the DDR3 beacon (docs/49);
//    * `bypass`: an OSD switch that turns every request into a passthrough.
//      A bypassed request on a slot holding dirty sectors flushes them first
//      (the guest is about to read the image directly), and drops the slot's
//      window (what the guest then writes past the cache must not be served
//      stale when the switch is turned back). It exists so one bitstream
//      measures the cache against no cache on the same image, and so a user
//      can switch it off if it ever misbehaves.
//    * FLUSH_IDLE is the same 4096 cycles, which at this core's 50 MHz is
//      ~82 us rather than ~120.
//
//  The engine (ncr53c96 behind iosb) moves one 512-byte sector at a time and
//  waits for the HPS on every one; a MiSTer Main round trip is ~100 us for a
//  read served from its read-ahead buffer and, for writes, whatever the SD
//  card takes -- images are opened O_SYNC, so a housekeeping pause on the
//  card (100s of ms) lands on every guest write.  This module sits on the
//  engine's block port and:
//
//    reads  - answers hits from block RAM at FPGA speed, fetches misses on
//             demand and then prefetches the following sectors while the
//             channel is otherwise idle (sequential I/O, which is what an
//             install or a file copy is, runs from the cache);
//    writes - accepts the sector into block RAM immediately (the engine sees
//             its ack in ~25 us) and flushes dirty sectors to the HPS in the
//             background, in order, whenever the channel is idle.
//
//  Each target owns one contiguous LBA window of N sectors (a ring with a
//  base LBA and valid/dirty bitmaps).  A request outside the window flushes
//  whatever is dirty and re-bases the window on the new LBA.  That is a
//  read-ahead / write-behind buffer around the current position rather than
//  a general cache, which is cheap in logic and exactly what the traffic
//  looks like; random access degrades to today's behaviour (one HPS round
//  trip per sector).
//
//  Platform-side transactions are serialized (hps_io serves one slot at a
//  time anyway): demand (an engine miss or an uncacheable request) first,
//  then dirty flushes, then prefetch.  The CD-ROM's TOC blob and CD-DA frame
//  windows (LBA >= 0x40000000, served by the Main fork with its own block
//  sizes) pass straight through, bus and all.
//
//  Coherency rules that matter:
//    - a read of a dirty sector is a hit and returns the new data;
//    - a window re-base waits for the channel to be idle and for every
//      dirty sector to be flushed, so a fetch never lands in a stale window;
//    - an engine write to the sector being flushed right now waits;
//    - a mount pulse for a slot whose image size changed invalidates the
//      slot (dirty data belonged to the old image); a pulse with the same
//      size is the top level's post-reset replay and keeps everything, so a
//      guest restart cannot lose the last writes;
//    - nreset only aborts an engine-side transaction in progress; tags,
//      dirty bits and the background flusher survive a machine reset.
//
//  One true dual-port M10K array of SECT0+SECT1+SECT2 sectors: port A is
//  the engine side, port B the HPS side.  Word addressing throughout (the
//  buses are 16 bits wide, big-endian byte pairs as hps_io delivers them).
//============================================================================

module scsi_cache
#(
	parameter SECT0    = 64,             // hard disk 0: 32 KB
	parameter SECT1    = 64,             // hard disk 1: 32 KB
	parameter SECT2    = 16,             // CD-ROM: 8 KB (2048-byte blocks = 4 sectors)
	parameter PF_DEPTH = 8,              // (kept for the bench; the prefetcher now works in groups)
	parameter CACHE_CD = 1,              // 0: the CD-ROM slot passes straight through (saves its tags)
	parameter MB_CD    = 1               // 1: the CD slot fetches its data window in 8-sector groups too. Needs the Main fork from 4857af1 (mac_cdrom_fill serves a 4 KB run; the older fork zero-fills anything but 512/2352 bytes, so CUE/CHD discs would read as zeros on it); flat ISOs go through the generic sd_image path either way
)
(
	input         clk,
	input         nreset,

	// ---- engine side (ncr53c96's block port, via iosb)
	input  [31:0] e_lba,
	input   [2:0] e_rd,
	input   [2:0] e_wr,
	output reg [2:0] e_ack,
	output reg [12:0] e_buff_addr,
	output reg [15:0] e_buff_dout,
	input  [15:0] e_buff_din,
	output reg    e_buff_wr,

	// ---- platform side (hps_io)
	output reg [31:0] p_lba,
	output reg  [5:0] p_blk_cnt,         // hps_io sd_blk_cnt: blocks - 1 for this transaction
	output reg  [2:0] p_rd,
	output reg  [2:0] p_wr,
	input   [2:0] p_ack,
	input  [12:0] p_buff_addr,
	input  [15:0] p_buff_dout,
	output [15:0] p_buff_din,
	input         p_buff_wr,

	// ---- mounts, as the engine sees them (one bit at a time, size valid then)
	input   [2:0] img_mounted,
	input  [31:0] img_blocks,            // SGI: 512-byte blocks, not bytes

	// SGI: every request passes through (see the header)
	input         bypass,

	// ---- statistics for the bring-up taps (SGI: 32 bits, plus the writes)
	output reg [31:0] stat_hits,
	output reg [31:0] stat_misses,
	output reg [31:0] stat_writes
);

localparam integer NSECT = SECT0 + SECT1 + SECT2;
localparam integer NS    = CACHE_CD ? 3 : 2;         // cached slots; the rest pass through
localparam integer MAXS  = (SECT0 > SECT1) ? ((SECT0 > SECT2) ? SECT0 : SECT2) : ((SECT1 > SECT2) ? SECT1 : SECT2);
                                                     // tag bitmap width: the largest slot (8..64)
localparam integer AW    = $clog2(NSECT*256);        // NSECT*256 <= 65536 words

// slot geometry
function [7:0] slot_base(input [1:0] s);
	slot_base = (s == 2'd0) ? 8'd0 : (s == 2'd1) ? SECT0[7:0] : (SECT0 + SECT1);
endfunction
function [7:0] slot_size(input [1:0] s);
	slot_size = (s == 2'd0) ? SECT0[7:0] : (s == 2'd1) ? SECT1[7:0] : SECT2[7:0];
endfunction

//----------------------------------------------------------------------------
// tags: one window per slot
//----------------------------------------------------------------------------
reg [31:0] win_base [0:2];
reg        win_ok   [0:2];
reg  [3:0] grp_lim  [0:2];                          // groups of the window that lie inside the image (0..8)
reg [MAXS-1:0] valid [0:2];
reg [MAXS-1:0] dirty [0:2];
reg [31:0] size_r   [0:2];                          // image size (in 512-byte blocks) the slot was mounted with
reg  [2:0] mounted;                                  // slot has an image (size != 0)

//----------------------------------------------------------------------------
// the sector store
//----------------------------------------------------------------------------
reg  [AW-1:0] addr_a;
reg  [15:0]   din_a;
reg           we_a;
wire [15:0]   q_a,    q_b;
// port B is the HPS side: address it combinationally from the platform bus so
// the store behaves like the real ncr_sbuf (a single read register).  During
// a fetch the platform's incoming word is written; during a flush the word is
// read out; passthrough does not touch the store.
// a multi-block transaction streams p_buff_addr 0..N*256-1: block index in
// [12:8], word in [7:0]; the group's sectors are consecutive in the store
wire [15:0]   addr_b_full = {c_sect + {3'd0, p_buff_addr[12:8]}, p_buff_addr[7:0]};
wire [AW-1:0] addr_b = addr_b_full[AW-1:0];
wire [15:0]   din_b  = p_buff_dout;
// SGI: the transaction is live from the cycle the ack rises, not from the
// cycle after (when cst has moved to C_XFER). hps_io delivers its first word
// an SPI strobe after the ack, and the Mac bench's device a cycle after, so
// neither ever presented a word in the ack's own cycle - the harness here
// (verilator/sim_scsi.h) does, and lost word 0 of every group until this.
wire          c_live = (cst == C_XFER) || ((cst == C_REQ) && p_ack[c_slot]);
wire          we_b   = c_live && !c_pt && !c_is_wr && p_buff_wr;

`ifdef VERILATOR
	reg [15:0] mem [0:NSECT*256-1];
	reg [15:0] q_a_r, q_b_r;
	always @(posedge clk) begin
		if (we_a) mem[addr_a] <= din_a;
		if (we_b) mem[addr_b] <= din_b;
		q_a_r <= mem[addr_a];
		q_b_r <= mem[addr_b];
	end
	assign q_a = q_a_r;
	assign q_b = q_b_r;
`else
	altsyncram ram
	(
		.clock0    (clk),
		.address_a (addr_a),
		.data_a    (din_a),
		.wren_a    (we_a),
		.q_a       (q_a),
		.address_b (addr_b),
		.data_b    (din_b),
		.wren_b    (we_b),
		.q_b       (q_b),
		.aclr0(1'b0), .aclr1(1'b0),
		.addressstall_a(1'b0), .addressstall_b(1'b0),
		.byteena_a(1'b1), .byteena_b(1'b1),
		.clock1(1'b1),
		.clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
		.eccstatus(),
		.rden_a(1'b1), .rden_b(1'b1)
	);
	defparam
		ram.numwords_a = NSECT*256,
		ram.widthad_a  = AW,
		ram.width_a    = 16,
		ram.width_byteena_a = 1,
		ram.numwords_b = NSECT*256,
		ram.widthad_b  = AW,
		ram.width_b    = 16,
		ram.width_byteena_b = 1,
		ram.address_reg_b = "CLOCK0",
		ram.clock_enable_input_a = "BYPASS",
		ram.clock_enable_input_b = "BYPASS",
		ram.clock_enable_output_a = "BYPASS",
		ram.clock_enable_output_b = "BYPASS",
		ram.indata_reg_b = "CLOCK0",
		ram.intended_device_family = "Cyclone V",
		ram.lpm_type = "altsyncram",
		ram.operation_mode = "BIDIR_DUAL_PORT",
		ram.outdata_aclr_a = "NONE",
		ram.outdata_aclr_b = "NONE",
		ram.outdata_reg_a = "UNREGISTERED",
		ram.outdata_reg_b = "UNREGISTERED",
		ram.power_up_uninitialized = "FALSE",
		ram.ram_block_type = "M10K",
		ram.read_during_write_mode_mixed_ports = "DONT_CARE",
		ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
		ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
		ram.wrcontrol_wraddress_reg_b = "CLOCK0";
`endif

//----------------------------------------------------------------------------
// platform channel: one transaction at a time
//----------------------------------------------------------------------------
localparam [2:0] C_IDLE = 3'd0, C_REQ = 3'd1, C_XFER = 3'd2, C_PT = 3'd3;
reg  [2:0] cst;
reg        c_is_wr;                  // FLUSH (or passthrough write)
reg        c_pt;                     // passthrough: buses forwarded to the engine
reg  [1:0] c_slot;
reg  [7:0] c_sect;                   // store sector index (slot base + window index)
reg  [5:0] c_idx;                    // window index of the first sector
reg        c_grp;                    // 1: an aligned 8-sector group, 0: a single sector
reg [31:0] c_base;                   // window base this transaction was issued for
// per-sector completion of a fetch: the last word of block k lands -> sector
// c_idx+k is valid at once, so the engine's first sector is served while the
// rest of the group is still streaming
wire       blk_last_word = we_b && (p_buff_addr[7:0] == 8'hFF);
wire [5:0] blk_idx       = c_idx + {3'd0, p_buff_addr[12:8]};
reg  [2:0] p_ack_d;
wire [2:0] p_ack_fall = p_ack_d & ~p_ack;
wire       ch_idle  = (cst == C_IDLE);
wire       ch_flush = (cst != C_IDLE) && c_is_wr && !c_pt;

// platform-side buffer bus: flush data comes from port B, passthrough from the engine
reg [15:0] pt_din;
assign p_buff_din = c_pt ? e_buff_din : q_b;

//----------------------------------------------------------------------------
// engine side
//----------------------------------------------------------------------------
localparam [3:0] E_IDLE = 4'd0, E_DECIDE = 4'd1, E_FLUSHALL = 4'd2, E_REBASE = 4'd3,
                 E_FETCH = 4'd4, E_RD_A = 4'd5, E_RD_B = 4'd6, E_WR_A = 4'd7,
                 E_WR_B = 4'd8, E_WR_C = 4'd9, E_DONE = 4'd10, E_PT = 4'd11,
                 E_RD_C = 4'd12;
reg  [3:0] est;
reg  [1:0] r_slot;
reg [31:0] r_lba;
reg        r_wr;
reg  [7:0] r_word;                   // 0..255 (bit 8 = done)
reg        r_word_done;
wire [31:0] r_off = r_lba - win_base[r_slot];
wire        r_inwin = win_ok[r_slot] && (r_off < {24'd0, slot_size(r_slot)});
wire  [5:0] r_idx = r_off[5:0];
wire        r_pt = bypass ||                                                     // SGI: the OSD switch
                   ((r_slot == 2'd2) && (!CACHE_CD || r_lba[31:30] != 2'b00));  // TOC blob / CD-DA windows, or the whole CD
wire        r_hit = r_inwin && valid[r_slot][r_idx];
wire        r_dirty_any = |dirty[r_slot];
// Same-sector hazards between the two sides.  Both decisions are taken from
// registered state so they can never disagree within a cycle: the engine
// will not write a sector the channel is fetching or flushing, and the
// channel will not start a flush or a prefetch of a sector the engine is
// writing (est says so from E_DECIDE until the last word is stored).
wire        ch_busy_me = (cst != C_IDLE) && !c_pt && (c_slot == r_slot) &&
                         (c_grp ? (c_idx[5:3] == r_idx[5:3]) : (c_idx == r_idx));
wire        ch_fetching_me = ch_busy_me && !c_is_wr;    // my sector is on its way already
wire        e_writing  = ((est == E_DECIDE) && r_wr && r_inwin && !r_pt) ||
                         (est == E_WR_A) || (est == E_WR_B) || (est == E_WR_C);

// Aligned 8-sector groups (relative to the window base) are the unit of a
// multi-block transaction: a fetch takes a whole group when none of it is
// present, a flush takes a whole group when all of it is dirty; anything
// partial goes sector by sector.  8-bit slices keep the logic small.
function [7:0] slice(input [63:0] bm, input [2:0] g);
	slice = bm[g*8 +: 8];
endfunction
function [63:0] ext(input [MAXS-1:0] bm);              // zero-extend a bitmap for slice()
	ext = {{(64-MAXS){1'b0}}, bm};
endfunction
function slot_mb(input [1:0] sl);           // may this slot use multi-block?
	slot_mb = (sl != 2'd2) || (MB_CD != 0);
endfunction
function grp_in(input [1:0] sl, input [2:0] g);   // whole group inside the window?
	grp_in = ({g, 3'b111} < slot_size(sl));
endfunction
wire [2:0] r_grp = r_idx[5:3];
wire       r_grp_absent = (slice(ext(valid[r_slot]), r_grp) == 8'd0) && (slice(ext(dirty[r_slot]), r_grp) == 8'd0);
wire       dem_grp = slot_mb(r_slot) && grp_in(r_slot, r_grp) && r_grp_absent &&
                     ({1'b0, r_grp} < grp_lim[r_slot]);                // stays inside the image
// groups that fit between the new window base and the end of the image,
// capped at the window's own size: one 32-bit subtraction, at re-base only
wire [31:0] room      = size_r[r_slot] - r_lba;
wire [3:0]  room_grps = (size_r[r_slot] < r_lba) ? 4'd0 :
                        (room[31:6] != 0)        ? 4'd8 : room[5:3];   // >= 64 sectors: all 8 groups
wire [7:0]  r_size    = slot_size(r_slot);
wire [3:0]  win_grps  = {1'b0, r_size[6:3]};                          // 8, 6 or 2
wire [3:0]  new_lim   = (room_grps < win_grps) ? room_grps : win_grps;

// demand for the channel from the engine side
reg        dem_req;                  // engine wants a platform transaction now
reg        dem_wr;                   // ...a flush-all step is a write
reg        dem_pt;
reg  [5:0] dem_idx;
reg        dem_grp_r;

// prefetch bookkeeping: whole groups, two ahead
reg  [1:0] pf_slot;
reg  [2:0] pf_grp;
reg  [1:0] pf_left;
wire       pf_ok = win_ok[pf_slot] && mounted[pf_slot] && grp_in(pf_slot, pf_grp) &&
                   (slice(ext(valid[pf_slot]), pf_grp) == 8'd0) && (slice(ext(dirty[pf_slot]), pf_grp) == 8'd0) &&
                   ({1'b0, pf_grp} < grp_lim[pf_slot]) &&
                   !(e_writing && (pf_slot == r_slot));
// single-sector prefetch for a slot without multi-block: the first sector of
// the group that is neither valid nor dirty
wire [7:0] pf_present = slice(ext(valid[pf_slot]), pf_grp) | slice(ext(dirty[pf_slot]), pf_grp);
reg  [2:0] pf_first; reg pf_any;
integer pfi;
always @(*) begin
	pf_first = 3'd0; pf_any = 1'b0;
	for (pfi = 7; pfi >= 0; pfi = pfi - 1)
		if (!pf_present[pfi]) begin pf_first = pfi[2:0]; pf_any = 1'b1; end
end
wire       pf1_ok = win_ok[pf_slot] && mounted[pf_slot] && grp_in(pf_slot, pf_grp) && pf_any &&
                    ({1'b0, pf_grp} < grp_lim[pf_slot]) &&
                    !(e_writing && (pf_slot == r_slot) && (r_idx == {pf_grp, pf_first}));

// flush scan.  A whole dirty group goes out as one 8-block write at once; a
// partly dirty group waits for the engine to go quiet (no write accepted for
// FLUSH_IDLE cycles) or for a re-base, so a sequential burst is not chopped
// into single-sector writes before its groups can fill.
localparam integer FLUSH_IDLE = 4096;                    // ~82 us at this core's 50 MHz (~120 us at the Mac's 33)
reg [12:0] idle_ctr;
wire       eng_quiet = (idle_ctr == 13'd4095) || (est == E_FLUSHALL);
reg  [1:0] fl_slot;
reg  [5:0] fl_idx;
// a wholly dirty group goes out as one write from its base wherever the
// scan pointer happens to stand inside it (a pointer left mid-group turned
// such a group into eight singles, tb "small" + CD groups, 2026-09-08)
wire [5:0] fl_gbase = {fl_idx[5:3], 3'd0};
wire       fl_grp = slot_mb(fl_slot) && grp_in(fl_slot, fl_idx[5:3]) &&
                    (slice(ext(dirty[fl_slot]), fl_idx[5:3]) == 8'hFF) &&
                    !(e_writing && (fl_slot == r_slot) && (r_idx[5:3] == fl_idx[5:3]));

integer i;

always @(posedge clk) begin
	p_ack_d <= p_ack;
	we_a <= 0;
	e_buff_wr <= 0;
	if (est == E_WR_A || est == E_WR_B || est == E_WR_C) idle_ctr <= 0;
	else if (idle_ctr != 13'd4095) idle_ctr <= idle_ctr + 1'b1;

	//------------------------------------------------ mounts
	for (i = 0; i < NS; i = i + 1)
		if (img_mounted[i]) begin
			if (img_blocks != size_r[i]) begin       // a different image: forget everything
				valid[i]  <= {MAXS{1'b0}};
				dirty[i]  <= {MAXS{1'b0}};
				win_ok[i] <= 1'b0;
				size_r[i] <= img_blocks;
			end
		end

	//------------------------------------------------ platform channel
	case (cst)
	C_IDLE: begin
		p_rd <= 3'b000; p_wr <= 3'b000; c_pt <= 0;
		if (dem_req) begin
			dem_req <= 0;                            // accepted: drop the level
			c_slot <= r_slot; c_is_wr <= dem_wr; c_pt <= dem_pt;
			c_grp  <= dem_grp_r;
			c_idx  <= dem_grp_r ? {dem_idx[5:3], 3'd0} : dem_idx;
			c_base <= win_base[r_slot];
			c_sect <= slot_base(r_slot) + {2'd0, (dem_grp_r ? {dem_idx[5:3], 3'd0} : dem_idx)};
			p_lba  <= dem_pt ? r_lba : (win_base[r_slot] + {26'd0, (dem_grp_r ? {dem_idx[5:3], 3'd0} : dem_idx)});
			p_blk_cnt <= dem_grp_r ? 6'd7 : 6'd0;
			if (dem_wr) p_wr[r_slot] <= 1; else p_rd[r_slot] <= 1;
			cst <= C_REQ;
		end
		else if (|dirty[fl_slot]) begin              // background flush, in order
			if (fl_grp) begin                        // a whole dirty group: one 8-block write from its base
				c_slot <= fl_slot; c_is_wr <= 1; c_pt <= 0; c_grp <= 1;
				c_idx  <= fl_gbase;
				c_base <= win_base[fl_slot];
				c_sect <= slot_base(fl_slot) + {2'd0, fl_gbase};
				p_lba  <= win_base[fl_slot] + {26'd0, fl_gbase};
				p_blk_cnt <= 6'd7;
				p_wr[fl_slot] <= 1;
				cst <= C_REQ;
			end
			else if (dirty[fl_slot][fl_idx] && (eng_quiet || !slot_mb(fl_slot)) &&
			    !(e_writing && (fl_slot == r_slot) && (fl_idx == r_idx))) begin
				c_slot <= fl_slot; c_is_wr <= 1; c_pt <= 0; c_grp <= 0;
				c_idx  <= fl_idx;
				c_base <= win_base[fl_slot];
				c_sect <= slot_base(fl_slot) + {2'd0, fl_idx};
				p_lba  <= win_base[fl_slot] + {26'd0, fl_idx};
				p_blk_cnt <= 6'd0;
				p_wr[fl_slot] <= 1;
				cst <= C_REQ;
			end
			else fl_idx <= (fl_idx + 1'b1 == slot_size(fl_slot)) ? 6'd0 : fl_idx + 1'b1;   // scan on, wrapping at the slot's size
			// (a 6-bit index running past a smaller bitmap aliases onto its low
			// bits: with 32-sector slots index 46 read bit 14 and flushed the
			// wrong store sector to the wrong LBA, tb_scsi_cache "small" 2026-09-08)
		end
		else if (|dirty[0] | |dirty[1] | (CACHE_CD && |dirty[2])) begin
			fl_slot <= (fl_slot + 1'b1 == NS[1:0]) ? 2'd0 : fl_slot + 1'b1;   // another slot has the dirt
			fl_idx  <= 0;
		end
		else if (pf_left != 0 && bypass) pf_left <= 0;   // SGI: bypassed - nothing speculative on the channel
		else if (pf_left != 0 && pf_ok && slot_mb(pf_slot)) begin
			// prefetch: the next wholly absent group, as one 8-block read
			c_slot <= pf_slot; c_is_wr <= 0; c_pt <= 0; c_grp <= 1;
			c_idx  <= {pf_grp, 3'd0};
			c_base <= win_base[pf_slot];
			c_sect <= slot_base(pf_slot) + {2'd0, pf_grp, 3'd0};
			p_lba  <= win_base[pf_slot] + {26'd0, pf_grp, 3'd0};
			p_blk_cnt <= 6'd7;
			p_rd[pf_slot] <= 1;
			pf_grp  <= pf_grp + 1'b1;
			pf_left <= pf_left - 1'b1;
			cst <= C_REQ;
		end
		else if (pf_left != 0 && !slot_mb(pf_slot) && pf1_ok) begin
			// no multi-block on this slot: one absent sector of the group
			c_slot <= pf_slot; c_is_wr <= 0; c_pt <= 0; c_grp <= 0;
			c_idx  <= {pf_grp, pf_first};
			c_base <= win_base[pf_slot];
			c_sect <= slot_base(pf_slot) + {2'd0, pf_grp, pf_first};
			p_lba  <= win_base[pf_slot] + {26'd0, pf_grp, pf_first};
			p_blk_cnt <= 6'd0;
			p_rd[pf_slot] <= 1;
			cst <= C_REQ;
		end
		else if (pf_left != 0) begin
			// the group is already (partly) present, outside the window, or
			// not prefetchable: step over it, stop at the window edge
			if (win_ok[pf_slot] && mounted[pf_slot] && grp_in(pf_slot, pf_grp) &&
			    !(e_writing && (pf_slot == r_slot))) begin
				pf_grp  <= pf_grp + 1'b1;
				pf_left <= pf_left - 1'b1;
			end
			else pf_left <= 0;
		end
	end
	C_REQ: begin
		if (p_ack[c_slot]) begin
			p_rd <= 3'b000; p_wr <= 3'b000;
			cst <= C_XFER;
		end
	end
	C_XFER: begin
		// port B (addr_b/din_b/we_b) is driven combinationally above; a fetch
		// writes the incoming word, a flush reads q_b out to p_buff_din.
		// A fetched sector becomes valid the moment its last word lands.
		if (!c_pt && !c_is_wr && blk_last_word && c_slot < NS &&
		    win_ok[c_slot] && (c_base == win_base[c_slot]))
			valid[c_slot][blk_idx] <= 1'b1;           // still the window it was fetched for
		if (p_ack_fall[c_slot]) begin
			if (!c_pt && c_slot < NS && c_is_wr) begin
				if (c_grp) dirty[c_slot][c_idx[5:3]*8 +: 8] <= 8'd0;
				else       dirty[c_slot][c_idx] <= 1'b0;
			end
			cst <= C_IDLE;
		end
	end
	default: cst <= C_IDLE;
	endcase

	//------------------------------------------------ engine side
	case (est)
	E_IDLE: begin
		e_ack <= 3'b000;
		if (e_rd[0] | e_wr[0]) begin r_slot <= 2'd0; r_wr <= e_wr[0]; r_lba <= e_lba; est <= E_DECIDE; end
		else if (e_rd[1] | e_wr[1]) begin r_slot <= 2'd1; r_wr <= e_wr[1]; r_lba <= e_lba; est <= E_DECIDE; end
		else if (e_rd[2] | e_wr[2]) begin r_slot <= 2'd2; r_wr <= e_wr[2]; r_lba <= e_lba; est <= E_DECIDE; end
	end
	E_DECIDE: begin
		if (r_pt) begin                              // uncacheable: hand the buses over
			// SGI: bypassed, with dirty sectors on this slot - settle them
			// first, exactly like a re-base (E_FLUSHALL -> E_REBASE -> back
			// here, clean), so the image the guest is about to read directly
			// holds its last writes.
			if (bypass && r_dirty_any) begin
				pf_left <= 0;
				est <= E_FLUSHALL;
			end
			else if (!dem_req) begin
				// SGI: bypassed - drop the slot's window. What the guest writes
				// past the cache from now on would otherwise sit behind a
				// valid bit and be served stale once the cache is back on;
				// win_ok low also keeps a prefetch still in flight from
				// marking anything valid when it lands.
				if (bypass && r_slot < NS) begin
					valid[r_slot]  <= {MAXS{1'b0}};
					win_ok[r_slot] <= 1'b0;
				end
				dem_req <= 1; dem_wr <= r_wr; dem_pt <= 1; dem_idx <= 0; dem_grp_r <= 0;
				est <= E_PT;
			end
		end
		else if (!r_inwin) begin
			// outside the window: stop prefetching (it was for the old window),
			// settle the dirt and let the channel drain, then re-base on this LBA
			pf_left <= 0;
			est <= E_FLUSHALL;
		end
		else if (r_wr) begin
			if (!ch_busy_me) begin
				e_ack[r_slot] <= 1;
				r_word <= 0;
				e_buff_addr <= 13'd0;
				est <= E_WR_A;
			end
		end
		else if (r_hit) begin
			stat_hits <= stat_hits + 1'b1;
			e_ack[r_slot] <= 1;
			r_word <= 0;
			addr_a <= {slot_base(r_slot) + {2'd0, r_idx}, 8'd0};
			est <= E_RD_A;
		end
		else if (ch_fetching_me) ;                   // a prefetch is bringing it: wait for the hit
		else if (!dem_req) begin                     // miss: fetch on demand, then serve
			stat_misses <= stat_misses + 1'b1;
			dem_req <= 1; dem_wr <= 0; dem_pt <= 0; dem_idx <= r_idx;
			dem_grp_r <= dem_grp;                    // the whole group when none of it is here
			est <= E_FETCH;
		end
	end
	E_FLUSHALL: begin
		// the background flusher does the work; wait until this slot is clean
		// and the channel has nothing of ours in flight (pf_left is 0, dirty is
		// 0 and dem_req is 0, so nothing new for this slot can start now)
		if (!r_dirty_any && ch_idle && !dem_req) est <= E_REBASE;
	end
	E_REBASE: begin
		if (r_slot < NS) begin
			win_base[r_slot] <= r_lba;
			grp_lim[r_slot]  <= new_lim;
			win_ok[r_slot]   <= 1'b1;
			valid[r_slot]    <= {MAXS{1'b0}};
			dirty[r_slot]    <= {MAXS{1'b0}};
		end
		est <= E_DECIDE;
	end
	E_FETCH: begin
		// the demand fetch is a held level until the channel takes it; when the
		// sector is valid it is a hit and we serve it.  If the window was
		// dropped meanwhile (a mount pulse), go back and re-base once the
		// channel is quiet.
		if (r_hit) est <= E_DECIDE;
		else if (!win_ok[r_slot] && ch_idle && !dem_req) est <= E_DECIDE;
	end
	// ---- read hit: three cycles per word -- port A address, the RAM's
	// registered read, then the word onto the engine's bus
	E_RD_A: begin
		addr_a <= {slot_base(r_slot) + {2'd0, r_idx}, r_word};
		est <= E_RD_B;
	end
	E_RD_B: est <= E_RD_C;
	E_RD_C: begin
		e_buff_addr <= {5'd0, r_word};
		e_buff_dout <= q_a;
		e_buff_wr   <= 1;
		if (r_word == 8'd255) est <= E_DONE;
		else begin r_word <= r_word + 1'b1; est <= E_RD_A; end
	end
	// ---- write accept: address, let the engine's registered read settle, sample
	E_WR_A: begin
		e_buff_addr <= {5'd0, r_word};
		est <= E_WR_B;
	end
	E_WR_B: est <= E_WR_C;
	E_WR_C: begin
		addr_a <= {slot_base(r_slot) + {2'd0, r_idx}, r_word};
		din_a  <= e_buff_din;
		we_a   <= 1;
		if (r_word == 8'd255) begin
			if (r_slot < NS) begin
				valid[r_slot][r_idx] <= 1'b1;
				dirty[r_slot][r_idx] <= 1'b1;
			end
			stat_writes <= stat_writes + 1'b1;       // SGI
			est <= E_DONE;
		end
		else begin r_word <= r_word + 1'b1; est <= E_WR_A; end
	end
	E_DONE: begin
		e_ack <= 3'b000;
		if (!r_wr) begin                             // arm the prefetcher: this group's rest, then two more
			pf_slot <= r_slot;
			pf_grp  <= r_grp;
			pf_left <= 2'd3;
		end
		est <= E_IDLE;
	end
	E_PT: begin
		// wait until the channel is actually running THIS passthrough, then
		// forward the buses; complete when its ack falls
		if (c_live && c_pt) begin                    // SGI: c_live, see we_b
			e_ack[r_slot] <= p_ack[r_slot];
			e_buff_addr   <= p_buff_addr;
			e_buff_dout   <= p_buff_dout;
			e_buff_wr     <= p_buff_wr;
			if (p_ack_fall[r_slot]) begin
				e_ack <= 3'b000;
				est <= E_IDLE;
			end
		end
	end
	default: est <= E_IDLE;
	endcase

	//------------------------------------------------ reset: engine side only
	if (!nreset) begin
		est <= E_IDLE; e_ack <= 3'b000;
		pf_left <= 0;
	end
end

// mount state and power-up values
initial begin
	cst = C_IDLE; est = E_IDLE; e_ack = 0; p_rd = 0; p_wr = 0; c_pt = 0; c_grp = 0; p_blk_cnt = 0;
	dem_req = 0; dem_grp_r = 0; pf_left = 0; pf_slot = 0; pf_grp = 0; fl_slot = 0; fl_idx = 0; idle_ctr = 0;
	stat_hits = 0; stat_misses = 0; stat_writes = 0; mounted = 0; e_buff_wr = 0; we_a = 0;
	for (i = 0; i < 3; i = i + 1) begin
		win_base[i] = 0; win_ok[i] = 0; valid[i] = 0; dirty[i] = 0; size_r[i] = 0;
	end
end
always @(posedge clk)
	for (i = 0; i < 3; i = i + 1)
		if (img_mounted[i]) mounted[i] <= (img_blocks != 0);

endmodule
