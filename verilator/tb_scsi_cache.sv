//============================================================================
//  tb_scsi_cache -- the block cache between an engine-like requester and a
//  slow hps_io-like device.
//
//  SGI: ported with rtl/scsi/scsi_cache.sv from MacQuadra800_MiSTer
//  (verilator/tb_scsi_cache.sv there, tip 40c3f13). The mount tag is the
//  block count rather than hps_io's byte size, the statistics are 32 bits,
//  and T10 is new: the OSD bypass - dirt is flushed before a bypassed
//  request, a bypassed write is never served stale afterwards, and every
//  bypassed request is one device transaction. `make -C verilator
//  tb_scsi_cache`.  The device holds 128 sectors per slot with a
//  known pattern; the "engine" issues reads and writes the way ncr53c96 does
//  (strobe until ack rises, stream while ack is high, done at ack fall) and
//  checks every byte.  Checks: hits/misses, prefetch, write-behind data
//  landing on the device intact and in order, window re-base, passthrough
//  for the CD's high windows, slot interleave, mount invalidation, and a
//  randomized mix.
//============================================================================
`timescale 1ns/1ps
module tb_scsi_cache;

reg clk = 0, nreset = 0;
always #5 clk = ~clk;

reg  [31:0] e_lba = 0;
reg   [2:0] e_rd = 0, e_wr = 0;
wire  [2:0] e_ack;
wire [12:0] e_buff_addr;
wire [15:0] e_buff_dout;
wire        e_buff_wr;
reg  [15:0] e_buff_din;
wire [31:0] p_lba;
wire  [5:0] p_blk_cnt;
wire  [2:0] p_rd, p_wr;
reg   [2:0] p_ack = 0;
reg  [12:0] p_buff_addr = 0;
reg  [15:0] p_buff_dout = 0;
wire [15:0] p_buff_din;
reg         p_buff_wr = 0;
reg   [2:0] img_mounted = 0;
reg  [31:0] img_blocks = 0;
reg         bypass = 0;
wire [31:0] stat_hits, stat_misses, stat_writes;

`ifndef CACHE_CD_TB
`define CACHE_CD_TB 1
`endif
`ifndef MB_CD_TB
`define MB_CD_TB 0
`endif
`ifndef CACHE_S0_TB
`define CACHE_S0_TB 64
`define CACHE_S1_TB 64
`endif
`ifndef CACHE_S2_TB
`define CACHE_S2_TB 16
`endif
scsi_cache #(.SECT0(`CACHE_S0_TB), .SECT1(`CACHE_S1_TB), .SECT2(`CACHE_S2_TB), .PF_DEPTH(8), .CACHE_CD(`CACHE_CD_TB), .MB_CD(`MB_CD_TB)) dut (
	.clk(clk), .nreset(nreset),
	.e_lba(e_lba), .e_rd(e_rd), .e_wr(e_wr), .e_ack(e_ack),
	.e_buff_addr(e_buff_addr), .e_buff_dout(e_buff_dout), .e_buff_din(e_buff_din), .e_buff_wr(e_buff_wr),
	.p_lba(p_lba), .p_blk_cnt(p_blk_cnt), .p_rd(p_rd), .p_wr(p_wr), .p_ack(p_ack),
	.p_buff_addr(p_buff_addr), .p_buff_dout(p_buff_dout), .p_buff_din(p_buff_din), .p_buff_wr(p_buff_wr),
	.img_mounted(img_mounted), .img_blocks(img_blocks), .bypass(bypass),
	.stat_hits(stat_hits), .stat_misses(stat_misses), .stat_writes(stat_writes)
);

integer fails = 0, checks = 0;

//----------------------------------------------------------------------------
// engine-side sector buffer: what ncr53c96's sbuf port S looks like to the
// platform -- a registered read at e_buff_addr, writes land on e_buff_wr
//----------------------------------------------------------------------------
reg [15:0] esbuf [0:255];
always @(posedge clk) begin
	if (e_buff_wr) esbuf[e_buff_addr[7:0]] <= e_buff_dout;
	e_buff_din <= esbuf[e_buff_addr[7:0]];
end

//----------------------------------------------------------------------------
// the device: 3 slots x 128 sectors, byte b of sector n on slot s = (n*7+b+s*3) & 255
// (big-endian byte pairs per word, as hps_io streams them)
//----------------------------------------------------------------------------
reg [7:0] dev [0:3*128*512-1];
reg [7:0] mir [0:3*128*512-1];
integer dev_lat = 40;
integer d_state = 0, d_lat = 0, d_i = 0, d_slot = 0;
integer d_lba = 0, d_n = 1;
integer dev_reads = 0, dev_writes = 0, pt_reads = 0;
integer i;
initial for (i = 0; i < 3*128*512; i = i + 1) dev[i] = (((i/512)%128)*7 + (i%512) + (i/(128*512))*3) & 8'hFF;

function integer dbase(input integer slot, input integer lba);
	dbase = slot*128*512 + (lba % 128)*512;
endfunction

always @(posedge clk) begin
	p_buff_wr <= 0;
	case (d_state)
	0: begin
		if (p_rd != 0 || p_wr != 0) begin
			d_slot <= (p_rd[0] | p_wr[0]) ? 0 : (p_rd[1] | p_wr[1]) ? 1 : 2;
			d_lba  <= p_lba;
			d_n    <= p_blk_cnt + 1;
			d_lat  <= dev_lat;
			d_state <= (p_rd != 0) ? 1 : 3;
			if (p_rd != 0 && p_lba >= 32'h40000000) pt_reads <= pt_reads + 1;
		end
	end
	1: begin
		// SGI: word 0 goes out in the same cycle the ack rises, as the sim
		// harness does (hps_io and the Mac's model wait a cycle or more; a
		// cache that needs that lost word 0 of every group, 2026-09-08)
		if (d_lat != 0) d_lat <= d_lat - 1;
		else begin
			p_ack[d_slot] <= 1; d_state <= 2; dev_reads <= dev_reads + 1;
			p_buff_addr <= 13'd0;
			p_buff_dout <= (d_lba >= 32'h40000000) ? {8'hA5, 8'h00} :
			               {dev[dbase(d_slot, d_lba)], dev[dbase(d_slot, d_lba) + 1]};
			p_buff_wr   <= 1;
			d_i <= 1;
		end
	end
	2: begin
		if (d_i < 256*d_n) begin
			p_buff_addr <= d_i[12:0];
			// passthrough windows return a marker pattern
			p_buff_dout <= (d_lba >= 32'h40000000) ? {8'hA5, d_i[7:0]} :
			               {dev[dbase(d_slot, d_lba + d_i/256) + (d_i%256)*2], dev[dbase(d_slot, d_lba + d_i/256) + (d_i%256)*2 + 1]};
			p_buff_wr   <= 1;
			d_i         <= d_i + 1;
		end
		else begin p_ack[d_slot] <= 0; d_state <= 0; end
	end
	3: begin
		if (d_lat != 0) d_lat <= d_lat - 1;
		else begin p_ack[d_slot] <= 1; d_i <= 1; p_buff_addr <= 13'd0; d_state <= 4; dev_writes <= dev_writes + 1;   // SGI: address 0 with the ack
`ifdef TB_DEBUG
			$display("      dev WRITE slot %0d lba %0d blocks %0d", d_slot, d_lba, d_n);
`endif
		end
	end
	4: begin
		// SGI: each address is held for four cycles and the word sampled on
		// the last of them. A flush answers one cycle behind the address (the
		// store's registered read); a passthrough write answers two (its
		// address register in front of the engine's registered read), and
		// the Mac bench never wrote through the passthrough. hps_io samples a
		// whole SPI word after it advances the address, so both are fine on
		// hardware; this is the same shape as verilator/sim_scsi.h's WR_HOLD.
		if (d_i < 256*d_n*4) begin
			p_buff_addr <= (d_i/4);
			if (d_i % 4 == 3) begin
				dev[dbase(d_slot, d_lba + (d_i/4)/256) + ((d_i/4)%256)*2]     <= p_buff_din[15:8];
				dev[dbase(d_slot, d_lba + (d_i/4)/256) + ((d_i/4)%256)*2 + 1] <= p_buff_din[7:0];
			end
			d_i <= d_i + 1;
		end
		else begin p_ack[d_slot] <= 0; d_state <= 0; end
	end
	endcase
end

//----------------------------------------------------------------------------
// engine-side helpers
//----------------------------------------------------------------------------
task chk(input [8*32:1] what, input integer got, input integer want);
	begin
		checks = checks + 1;
		if (got !== want) begin
			fails = fails + 1;
			$display("  FAIL %0s: got %0d want %0d", what, got, want);
		end
	end
endtask

// read one sector on slot s at lba; verify against the device image or a marker
task eread(input integer s, input integer lba, input integer marker);
	integer g, w, b0, b1;
	begin
		@(negedge clk); e_lba = lba; e_rd = 3'b001 << s;
		g = 0; while (!e_ack[s] && g < 2000000) begin @(negedge clk); g = g + 1; end
		if (!e_ack[s]) begin fails = fails + 1; $display("  FAIL eread slot %0d lba %0d: no ack", s, lba); e_rd = 0; end
		else begin
			e_rd = 0;
			g = 0; while (e_ack[s] && g < 2000000) begin @(negedge clk); g = g + 1; end
			if (e_ack[s]) begin fails = fails + 1; $display("  FAIL eread slot %0d lba %0d: ack stuck", s, lba); end
			@(negedge clk);
			for (w = 0; w < 256 && marker != 2; w = w + 1) begin
				if (marker) begin b0 = 8'hA5; b1 = w & 8'hFF; end
				else begin b0 = ((lba%128)*7 + w*2 + s*3) & 8'hFF; b1 = ((lba%128)*7 + w*2 + 1 + s*3) & 8'hFF; end
				checks = checks + 1;
				if (esbuf[w] !== {b0[7:0], b1[7:0]}) begin
					fails = fails + 1;
					if (fails < 40) $display("  FAIL eread slot %0d lba %0d word %0d: got %04X want %02X%02X", s, lba, w, esbuf[w], b0[7:0], b1[7:0]);
				end
			end
		end
	end
endtask

// write one sector on slot s at lba with pattern (w*3 + tag) per byte
task ewrite(input integer s, input integer lba, input integer tag);
	integer g, w, pb0, pb1;
	begin
		for (w = 0; w < 256; w = w + 1) begin
			pb0 = (w*2)*3 + tag; pb1 = (w*2+1)*3 + tag;
			esbuf[w] = {pb0[7:0], pb1[7:0]};
		end
		@(negedge clk); e_lba = lba; e_wr = 3'b001 << s;
		g = 0; while (!e_ack[s] && g < 2000000) begin @(negedge clk); g = g + 1; end
		if (!e_ack[s]) begin fails = fails + 1; $display("  FAIL ewrite slot %0d lba %0d: no ack", s, lba); e_wr = 0; end
		else begin
			e_wr = 0;
			g = 0; while (e_ack[s] && g < 2000000) begin @(negedge clk); g = g + 1; end
			if (e_ack[s]) begin fails = fails + 1; $display("  FAIL ewrite slot %0d lba %0d: ack stuck", s, lba); end
			@(negedge clk);
		end
	end
endtask

// read one sector and verify every byte against the mirror
task mread(input integer s, input integer lba);
	integer g, w, e0, e1;
	begin
		@(negedge clk); e_lba = lba; e_rd = 3'b001 << s;
		g = 0; while (!e_ack[s] && g < 2000000) begin @(negedge clk); g = g + 1; end
		if (!e_ack[s]) begin fails = fails + 1; $display("  FAIL mread s%0d lba%0d: no ack", s, lba); e_rd = 0; end
		else begin
			e_rd = 0;
			g = 0; while (e_ack[s] && g < 2000000) begin @(negedge clk); g = g + 1; end
			@(negedge clk);
			for (w = 0; w < 256; w = w + 1) begin
				e0 = mir[s*128*512 + (lba%128)*512 + w*2];
				e1 = mir[s*128*512 + (lba%128)*512 + w*2 + 1];
				checks = checks + 1;
				if (esbuf[w] !== {e0[7:0], e1[7:0]}) begin
					fails = fails + 1;
					if (fails < 40 && w == 0) $display("  FAIL mread s%0d lba%0d word0: got %04X want %02X%02X  [win_base=%0d win_ok=%b valid=%b]", s, lba, esbuf[0], e0[7:0], e1[7:0], dut.win_base[s], dut.win_ok[s], dut.valid[s][15:0]);
				end
			end
		end
	end
endtask

// wait until the cache has no dirty sectors and the channel is idle
task settle;
	integer g;
	begin
		g = 0;
		while ((dut.dirty[0] != 0 || dut.dirty[1] != 0 || dut.dirty[2] != 0 || dut.cst != 0) && g < 4000000) begin @(negedge clk); g = g + 1; end
		chk("settle: clean and idle", (dut.dirty[0] == 0 && dut.dirty[1] == 0 && dut.dirty[2] == 0 && dut.cst == 0) ? 1 : 0, 1);
		repeat (20) @(negedge clk);
	end
endtask

// check a device sector holds the ewrite pattern
task dcheck(input integer s, input integer lba, input integer tag);
	integer b;
	begin
		for (b = 0; b < 512; b = b + 1) begin
			checks = checks + 1;
			if (dev[dbase(s, lba) + b] !== ((b*3 + tag) & 8'hFF)) begin
				fails = fails + 1;
				if (fails < 40) $display("  FAIL device slot %0d lba %0d byte %0d: got %02X want %02X", s, lba, b, dev[dbase(s, lba) + b], (b*3 + tag) & 8'hFF);
			end
		end
	end
endtask

task mount(input integer s, input [31:0] blocks);
	begin
		@(negedge clk); img_blocks = blocks; img_mounted = 3'b001 << s;
		@(negedge clk); img_mounted = 0;
		repeat (4) @(negedge clk);
	end
endtask

integer k, r0, m0, rd0, seed, n, lba, s, tag, t3a, t3b;
initial begin
	repeat (5) @(negedge clk);
	nreset = 1;
	mount(0, 128); mount(1, 128); mount(2, 128);
	// seed the mirror from the (known) device init pattern
	for (s = 0; s < 3; s = s + 1)
		for (lba = 0; lba < 128; lba = lba + 1)
			for (k = 0; k < 512; k = k + 1)
				mir[s*128*512 + lba*512 + k] = (lba*7 + k + s*3) & 8'hFF;

	$display("-- T1 sequential reads on slot 0: first is a miss, the prefetch turns the rest into hits");
	r0 = stat_hits; m0 = stat_misses; rd0 = dev_reads;
	for (k = 0; k < 24; k = k + 1) begin eread(0, 10 + k, 0); repeat (400) @(negedge clk); end
	settle;
	$display("   hits=%0d misses=%0d device reads=%0d", stat_hits - r0, stat_misses - m0, dev_reads - rd0);
	chk("T1 misses <= 8", (stat_misses - m0) <= 8 ? 1 : 0, 1);
	chk("T1 hits >= 20", (stat_hits - r0) >= 20 ? 1 : 0, 1);

	$display("   fails so far: %0d", fails);
	$display("-- T2 write-behind: 12 sequential writes on slot 0 are acked fast and land on the device in full");
	for (k = 0; k < 12; k = k + 1) ewrite(0, 20 + k, 40 + k);
	settle;
	for (k = 0; k < 12; k = k + 1) dcheck(0, 20 + k, 40 + k);

	$display("   fails so far: %0d", fails);
	$display("-- T3 read of a just-written sector is a hit and returns the new data (before/after flush)");
	ewrite(0, 33, 99);
	@(negedge clk); e_lba = 33; e_rd = 3'b001;
	k = 0; while (!e_ack[0] && k < 200000) begin @(negedge clk); k = k + 1; end
	e_rd = 0;
	k = 0; while (e_ack[0] && k < 200000) begin @(negedge clk); k = k + 1; end
	@(negedge clk);
	for (k = 0; k < 256; k = k + 1) begin
		t3a = (k*2)*3 + 99; t3b = (k*2+1)*3 + 99;
		checks = checks + 1;
		if (esbuf[k] !== {t3a[7:0], t3b[7:0]}) begin fails = fails + 1; if (fails < 12) $display("  FAIL T3 word %0d: got %04X want %02X%02X", k, esbuf[k], t3a[7:0], t3b[7:0]); end
	end
	settle;
	dcheck(0, 33, 99);

	$display("   fails so far: %0d", fails);
	$display("-- T4 window re-base with dirty data: writes at 20.., then a read far away flushes first");
`ifdef TB_DEBUG
	$display("   T4 before: base=%0d lim=%0d valid=%h dirty=%h cst=%0d est=%0d", dut.win_base[0], dut.grp_lim[0], dut.valid[0], dut.dirty[0], dut.cst, dut.est);
`endif
	ewrite(0, 24, 7);
`ifdef TB_DEBUG
	$display("   T4 store sector 14 word0=%04x word255=%04x (want 0007/...)", dut.mem[14*256], dut.mem[14*256+255]);
`endif
	ewrite(0, 25, 8);
`ifdef TB_DEBUG
	$display("   T4 after writes: base=%0d valid=%h dirty=%h cst=%0d c_idx=%0d c_grp=%0d c_is_wr=%0d", dut.win_base[0], dut.valid[0], dut.dirty[0], dut.cst, dut.c_idx, dut.c_grp, dut.c_is_wr);
`endif
	eread(0, 100, 0);                                // outside [10,74): forces flush + re-base
`ifdef TB_DEBUG
	$display("   T4 after re-base read: base=%0d valid=%h dirty=%h dev_writes=%0d", dut.win_base[0], dut.valid[0], dut.dirty[0], dev_writes);
`endif
	settle;
	dcheck(0, 24, 7); dcheck(0, 25, 8);
	eread(0, 101, 0); eread(0, 102, 0);

	$display("   fails so far: %0d", fails);
	$display("-- T5 slot 1 and slot 2 have their own windows; the CD's high windows pass through");
	eread(1, 5, 0); eread(1, 6, 0); eread(1, 7, 0);
	eread(2, 8, 0); eread(2, 9, 0); eread(2, 10, 0); eread(2, 11, 0);
	k = pt_reads;
	eread(2, 32'h7FFF0000, 1);                       // TOC blob window: marker pattern straight from the device
	$display("   T5 after passthrough: pt_reads=%0d est=%0d cst=%0d fails=%0d", pt_reads, dut.est, dut.cst, fails);
	chk("T5 passthrough hit the device", pt_reads - k, 1);
	eread(2, 12, 0);                                 // and the cache still works afterwards
	eread(1, 8, 0);
	settle;

	$display("   fails so far: %0d", fails);
	$display("-- T6 mount pulse with a new size invalidates slot 1; same size keeps it");
	ewrite(1, 9, 5);
	settle;
	m0 = stat_misses;
	mount(1, 128);                                   // same size: replay, keep
	eread(1, 9, 2);                                  // must be a hit: still cached
	chk("T6 same-size mount kept the window", stat_misses - m0, 0);
	mount(1, 64);                                    // different size: drop
	chk("T6 new-size mount invalidated", dut.win_ok[1] ? 1 : 0, 0);
	mount(1, 128);

	$display("   fails so far: %0d", fails);
	$display("-- T6b CD (slot 2, 16-sector window): sequential reads, then reads that force re-base");
	m0 = stat_misses;
	for (k = 0; k < 40; k = k + 1) begin mread(2, k % 32); repeat (200) @(negedge clk); end
	// the CD slot prefetches too: 40 sequential reads must not all miss
	// (a 2-bit "mounted" vector once made slot 2 look unmounted -- Verilator
	// read the out-of-range bit as 0, Quartus refused it)
	$display("   T6b CD misses over 40 sequential reads: %0d", stat_misses - m0);
	chk("T6b CD prefetch keeps ahead (misses < 8)", (stat_misses - m0) < 8 ? 1 : 0, 1);
	// jump around to force re-bases of the small window
	mread(2, 30); mread(2, 2); mread(2, 20); mread(2, 5); mread(2, 31); mread(2, 0);
	$display("   fails after T6b: %0d", fails);
	settle;

	$display("   fails so far: %0d", fails);
	$display("-- T7 random mix on all slots, random latency; a mirror of expected device contents is checked");
	// T2..T6 wrote sectors the mirror never saw: it is clean and settled, so
	// start T7 from what the device actually holds
	for (k = 0; k < 3*128*512; k = k + 1) mir[k] = dev[k];
	seed = 32'h13572468;
	for (n = 0; n < 200; n = n + 1) begin
		seed = seed * 1103515245 + 12345; s = (seed >> 16) % 3;
		seed = seed * 1103515245 + 12345; lba = (seed >> 16) % ((s == 2) ? 32 : 100);
		seed = seed * 1103515245 + 12345; dev_lat = 20 + ((seed >> 16) % 1500);
		seed = seed * 1103515245 + 12345;
		if (s != 2 && ((seed >> 16) % 3) == 0) begin
			tag = (n & 8'h7F);
			ewrite(s, lba, tag);
			for (k = 0; k < 512; k = k + 1) mir[s*128*512 + (lba%128)*512 + k] = (k*3 + tag) & 8'hFF;
		end
		else mread(s, lba);           // read: verify against the mirror
	end
	settle;
	// every sector on the device must now match the mirror
	for (s = 0; s < 3; s = s + 1)
		for (lba = 0; lba < ((s == 2) ? 32 : 100); lba = lba + 1)
			for (k = 0; k < 512; k = k + 1) begin
				checks = checks + 1;
				if (dev[s*128*512 + (lba%128)*512 + k] !== mir[s*128*512 + (lba%128)*512 + k]) begin
					fails = fails + 1;
					if (fails < 40) $display("  FAIL T7 device s%0d lba%0d byte%0d: got %02X want %02X", s, lba, k, dev[s*128*512 + (lba%128)*512 + k], mir[s*128*512 + (lba%128)*512 + k]);
				end
			end
	$display("   fails after T7: %0d", fails);
	settle;

	$display("-- T8 the installer's pattern: a long sequential write burst on slot 1 crossing the window, then CD reads at once, slow device");
	dev_lat = 1200;
	for (k = 0; k < 100; k = k + 1) begin
		ewrite(1, 10 + k, (k + 3) & 8'h7F);
		for (n = 0; n < 512; n = n + 1) mir[1*128*512 + ((10 + k) % 128)*512 + n] = (n*3 + ((k + 3) & 8'h7F)) & 8'hFF;
	end
	// the CD is selected while slot 1 is still flushing behind the engine
	for (k = 0; k < 8; k = k + 1) mread(2, 40 + k);
	mread(1, 60); mread(1, 109);                     // and reads of the burst hit the right data
	settle;
	for (k = 0; k < 100; k = k + 1) dcheck(1, 10 + k, (k + 3) & 8'h7F);
	$display("   fails after T8: %0d", fails);

	$display("-- T9 multi-block: 32 sequential reads and a 64-sector write burst take few platform transactions");
	dev_lat = 40;
	rd0 = dev_reads;
	for (k = 0; k < 32; k = k + 1) begin mread(0, 60 + k); repeat (300) @(negedge clk); end
	$display("   T9 device read transactions for 32 sequential reads: %0d", dev_reads - rd0);
	chk("T9 reads <= 8 transactions (4 groups + 2 ahead)", (dev_reads - rd0) <= 8 ? 1 : 0, 1);
	m0 = dev_writes;
	for (k = 0; k < 64; k = k + 1) begin
		ewrite(1, 30 + k, (k * 5 + 1) & 8'h7F);
		for (n = 0; n < 512; n = n + 1) mir[1*128*512 + ((30 + k) % 128)*512 + n] = (n*3 + ((k * 5 + 1) & 8'h7F)) & 8'hFF;
	end
	settle;
	$display("   T9 device write transactions for 64 sequential writes: %0d", dev_writes - m0);
	chk("T9 writes <= 12 transactions", (dev_writes - m0) <= 12 ? 1 : 0, 1);
	for (k = 0; k < 64; k = k + 1) dcheck(1, 30 + k, (k * 5 + 1) & 8'h7F);
	mread(1, 45); mread(1, 93); mread(0, 75);
	$display("   fails after T9: %0d", fails);

	$display("-- T10 the OSD bypass: dirt settles before a bypassed request, a bypassed write is not served stale after, every request hits the device");
	dev_lat = 40;
	settle;
	// (a) cached: two dirty sectors on slot 0, then bypass - the first
	// bypassed read must see the flush land first and come from the device
	ewrite(0, 80, 21); ewrite(0, 81, 22);
	for (n = 0; n < 512; n = n + 1) begin
		mir[0*128*512 + 80*512 + n] = (n*3 + 21) & 8'hFF;
		mir[0*128*512 + 81*512 + n] = (n*3 + 22) & 8'hFF;
	end
	chk("T10a dirt pending before bypass", (dut.dirty[0] != 0) ? 1 : 0, 1);
	bypass = 1;
	rd0 = dev_reads; m0 = dev_writes;
	mread(0, 80);
	chk("T10a bypassed read hit device", dev_reads - rd0, 1);
	chk("T10a dirt flushed first", (dut.dirty[0] == 0) ? 1 : 0, 1);
	chk("T10a window dropped", dut.win_ok[0] ? 1 : 0, 0);
	dcheck(0, 80, 21); dcheck(0, 81, 22);
	// (b) bypassed writes go straight to the device, one transaction each
	m0 = dev_writes;
	ewrite(0, 82, 23); ewrite(0, 83, 24);
	for (n = 0; n < 512; n = n + 1) begin
		mir[0*128*512 + 82*512 + n] = (n*3 + 23) & 8'hFF;
		mir[0*128*512 + 83*512 + n] = (n*3 + 24) & 8'hFF;
	end
	chk("T10b 2 bypassed writes = 2 dev", dev_writes - m0, 2);
	dcheck(0, 82, 23); dcheck(0, 83, 24);
	chk("T10b no dirt after bypassed wr", (dut.dirty[0] == 0) ? 1 : 0, 1);
	// (c) cache on, sector cached and valid; bypass; write it past the cache;
	// cache on again: the read must return the new data, not the stale line
	bypass = 0;
	mread(1, 90); mread(1, 91);
	chk("T10c slot 1 window valid", dut.win_ok[1] ? 1 : 0, 1);
	bypass = 1;
	ewrite(1, 90, 25);
	for (n = 0; n < 512; n = n + 1) mir[1*128*512 + 90*512 + n] = (n*3 + 25) & 8'hFF;
	chk("T10c bypassed wr dropped window", dut.win_ok[1] ? 1 : 0, 0);
	bypass = 0;
	m0 = stat_misses;
	mread(1, 90);                                    // must miss and fetch the new data
	chk("T10c read after bypass = miss", stat_misses - m0, 1);
	mread(1, 91);
	// (d) with the bypass on, reads and writes on every slot are one
	// transaction each and the mirror stays right
	bypass = 1;
	rd0 = dev_reads; m0 = dev_writes;
	for (k = 0; k < 6; k = k + 1) mread(k % 3, 100 + k);
	ewrite(0, 106, 26); for (n = 0; n < 512; n = n + 1) mir[0*128*512 + 106*512 + n] = (n*3 + 26) & 8'hFF;
	ewrite(1, 107, 27); for (n = 0; n < 512; n = n + 1) mir[1*128*512 + 107*512 + n] = (n*3 + 27) & 8'hFF;
	mread(0, 106); mread(1, 107);
	chk("T10d 8 reads = 8 device reads", dev_reads - rd0, 8);
	chk("T10d 2 writes = 2 device writes", dev_writes - m0, 2);
	bypass = 0;
	settle;
	mread(0, 106); mread(1, 107); mread(0, 80);
	$display("   fails after T10: %0d", fails);

	$display("== tb_scsi_cache: %0d checks, %0d failures (device reads %0d, writes %0d, engine writes %0d) ==", checks, fails, dev_reads, dev_writes, stat_writes);
	if (fails != 0) $display("RESULT: FAIL"); else $display("RESULT: PASS");
	$finish;
end

initial begin
	#400_000_000;
	$display("== tb_scsi_cache: TIMEOUT ==");
	$display("RESULT: FAIL");
	$finish;
end

endmodule
