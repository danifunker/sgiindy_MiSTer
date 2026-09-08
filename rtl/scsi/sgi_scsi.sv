//============================================================================
//  sgi_scsi - the SGI side of the WD33C93B, plus the targets behind it.
//
//  Three jobs: decode the two byte-wide ports out of a 64-bit big-endian bus
//  access, wire the initiator to an array of scsi.v targets, and do the bus
//  arbitration between them. Since docs/49 a fourth: the block cache between
//  the targets and hps_io (rtl/scsi/scsi_cache.sv, ported from
//  MacQuadra800_MiSTer), which answers the targets' sector reads from block
//  RAM, prefetches behind them, accepts their writes at RAM speed and
//  flushes in the background - in 8-sector transactions on the HPS side.
//  scsi.v is unchanged: the cache offers it exactly the io_rd/io_wr/io_ack/
//  sd_buff_* contract hps_io did.
//
//  ARBITRATION. Every target drives bsy/msg/cd/io/req/dout, and exactly one
//  should be answering at a time - the one that won selection. They are
//  combined by OR, which is what a real open-collector SCSI bus does and what
//  the MacLC core's initiator does with the same targets. The `bus_busy` input
//  each target gets is the OR of every *other* target's BSY, so a second
//  selection cannot create two active targets sharing one broadcast ACK.
//
//  ONE CONTROLLER. The PROM's descriptor table describes two WD33C93Bs, at
//  0x1FBC0000 and 0x1FBC8000. Only controller 0 is fitted; the window for
//  controller 1 stays unclaimed, and the PROM reports it absent and carries
//  on, which is what it does for a machine with one SCSI bus.
//============================================================================

module sgi_scsi #(
    parameter int NUM_TARGETS = 7,      // IDs 0..6; 7 is the host adapter
    parameter logic [2:0] HOST_ID = 3'd0,
    // WHICH IDS ARE CD-ROM DRIVES, one bit per target, LSB = ID 0.
    //
    // This has to be settled at elaboration and cannot be a mount-time choice:
    // `CDROM` changes what the target answers to INQUIRY (device type 0x05,
    // removable, "SONY CD-ROM"), the size of a logical block (2048, served as
    // four consecutive 512-byte host blocks), what READ CAPACITY reports, and
    // which MODE SENSE pages exist. A drive is a different device from a disk,
    // not a disk with a different file in it.
    //
    // ID 6 by default, which is where SGI put the internal CD-ROM and what
    // every `dksc(0,6,8)` boot line in the world assumes.
    parameter logic [6:0] CDROM_IDS = 7'b100_0000,

    // WHICH IDS ARE ACTUALLY BUILT, one bit per target, LSB = ID 0.
    //
    // Every ID used to get a full target - its own WD33C93B-facing state
    // machine and two 512-byte sector buffers - because in simulation that
    // was free. On the device it is not: seven of them are ~7,900 ALUTs and
    // 917,504 bits of M10K, and nothing uses more than a few. IDs are not
    // interchangeable, though, so this is a mask and not a count: ID 6 is the
    // CD-ROM (see CDROM_IDS) and ID 1 is where tests/run-scsi.sh and
    // tests/run-cdrom.sh put the disk, so lowering NUM_TARGETS to 3 would
    // build IDs 0..2 and delete the CD-ROM. The mask keeps the ID space at
    // 0..6 and just does not build the targets nobody addresses.
    //
    // ID 0 is HOST_ID, the initiator's own address, so it was never usable.
    // The default below is a disk on 1, a spare disk on 2, and the CD-ROM on
    // 6. Set a bit to add a target back; the port widths do not change.
    //
    // THE BLOCK CACHE HAS THREE SLOTS, AND THEY ARE THESE THREE IDS
    // (SLOT0_ID..SLOT2_ID below, in the order sgiindy.sv's menu slots 1..3
    // take them). A target enabled on any other ID would elaborate but never
    // reach hps_io: its io_ack is tied low and its request lines go nowhere.
    // Add a slot to the cache before adding a fourth target.
    parameter logic [6:0] TARGET_EN = 7'b100_0110,

    // Cache geometry, in 512-byte sectors per slot: two disks and the CD-ROM.
    // 64 + 64 + 16 sectors = 72 KB of M10K if the CD slot is cached; with
    // CACHE_CD = 0 (the default: the CD reads through scsi.v's own 32-sector
    // ring and passes straight through the cache) the CD slot has no store
    // and it is 64 KB, 64 M10Ks. Fits after build 25's 379/553. The bench
    // runs this exact shape as `make -C verilator tb_scsi_cache_nocd`.
    parameter int CACHE_SECT0 = 64,
    parameter int CACHE_SECT1 = 64,
    parameter int CACHE_SECT2 = 16,
    parameter int CACHE_CD    = 0
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,

    // ---- bus, from sgi_indy ----------------------------------------------
    input  logic        sel,            // one-cycle pulse, address in window
    input  logic        we,
    input  logic  [2:0] aoff,           // byte offset of the access
    input  logic [63:0] wdata,
    output logic [63:0] rdata,
    output logic        ack,
    output logic        irq,

    // The HPC3 channel's ch_reset, on to the controller and the bus.
    input  logic        chip_reset,

    // ---- the HPC3 SCSI DMA channel ---------------------------------------
    // Straight through to the initiator; the targets never see it.
    output logic        dma_req,
    output logic        dma_dir_in,
    output logic  [7:0] dma_wdata,
    output logic        dma_eop,
    input  logic        dma_ack,
    input  logic  [7:0] dma_rdata,

    // ---- block device, from hps_io / the harness -------------------------
    // Per SCSI ID, as before; what changed with the cache is that a
    // transaction can now be up to eight sectors (sd_blk_cnt = 7), streamed
    // through the 13-bit sd_buff_addr, and that sd_lba / sd_buff_din carry
    // the cache's one live transaction rather than each target's own.
    input  logic [NUM_TARGETS-1:0]  img_mounted,
    input  logic [31:0]             img_blocks,
    output logic [31:0]             sd_lba      [NUM_TARGETS],
    output logic  [5:0]             sd_blk_cnt,             // blocks - 1, one value: one transaction at a time
    output logic [NUM_TARGETS-1:0]  sd_rd,
    output logic [NUM_TARGETS-1:0]  sd_wr,
    input  logic [NUM_TARGETS-1:0]  sd_ack,
    input  logic [12:0]             sd_buff_addr,
    input  logic [15:0]             sd_buff_dout,
    output logic [15:0]             sd_buff_din [NUM_TARGETS],
    input  logic                    sd_buff_wr,

    // The OSD's "SCSI cache: Off": every request passes straight through to
    // hps_io, one sector per transaction, as before docs/49.
    input  logic                    cache_bypass,

    // SGI: DDR3 debug beacon words (docs/28). [0] bus/HPS live, [1] wd33c93,
    // [2]/[3] target 1 live A/B, [4]/[5] target 6 live A/B, [6] target 1
    // sticky first-stall snapshot. Pure observation.
    output logic [63:0]             dbg_bcn [7],
    // SGI: the disk-time counters (docs/49), five more beacon words: how many
    // HPS transactions, how long the HPS channel and the targets' block ports
    // were busy, how long the SCSI bus was, how many bytes crossed it in DATA
    // phases, and the cache's hits / misses / writes. Counters, not state:
    // read twice, subtract, and the difference is the boot's disk seconds.
    output logic [63:0]             dbg_stat [5]
);

    // ---- port decode -------------------------------------------------------
    // 0x1FBC0000 word -> address port / ASR, 0x1FBC0004 word -> data port.
    // On a big-endian 64-bit bus the word at +0 is the high half, so the
    // access is to the data port exactly when it is in the low half.
    wire       is_data = aoff[2];
    wire [7:0] wr_byte = is_data ? wdata[7:0] : wdata[39:32];
    wire [7:0] rd_byte;

    // Both words carry the answer in their low byte, so either a word read of
    // +0 or of +4 finds it - the same thing sgi_ioc does.
    assign rdata = {24'h0, rd_byte, 24'h0, rd_byte};

    always_ff @(posedge clk) ack <= reset ? 1'b0 : sel;

    // ---- the SCSI bus ------------------------------------------------------
    wire        b_sel, b_atn, b_ack, b_rst;
    wire [7:0]  b_dout_init;

    wire [NUM_TARGETS-1:0] t_bsy, t_msg, t_cd, t_io, t_req;
    wire [7:0]             t_dout [NUM_TARGETS];
    // Hoisted out of the generate: a runtime index into a generate block is
    // not a constant expression, so the per-target LBA has to live in an
    // array at module scope for the mux below to select from it.
    wire [31:0]            t_lba  [NUM_TARGETS];
    wire [15:0]            t_din  [NUM_TARGETS];
    // The targets' block-port request lines and the ack each one gets back,
    // at module scope for the same reason: the cache's three slots pick them
    // out by ID below.
    wire [NUM_TARGETS-1:0] t_rd, t_wr, t_ack;
    // Per-target beacon taps (docs/28); zeros for targets not built.
    wire [63:0]            t_bcn_a [NUM_TARGETS];
    wire [63:0]            t_bcn_b [NUM_TARGETS];
    wire [63:0]            t_bcn_s [NUM_TARGETS];
    wire [63:0]            wd_bcn;

    // Open-collector OR. Only the selected target drives anything.
    wire bus_bsy = |t_bsy;
    wire bus_msg = |t_msg;
    wire bus_cd  = |t_cd;
    wire bus_io  = |t_io;
    wire bus_req = |t_req;

    logic [7:0] bus_din;
    always_comb begin
        bus_din = 8'h00;
        for (int t = 0; t < NUM_TARGETS; t++)
            if (t_bsy[t]) bus_din = t_dout[t];
    end

    wd33c93 #(.HOST_ID(HOST_ID)) u_wd33c93 (
        .clk       (clk),
        .reset     (reset),
        .ce        (ce),
        .chip_reset(chip_reset),
        .sel       (sel),
        .we        (we),
        .is_data   (is_data),
        .din       (wr_byte),
        .dout      (rd_byte),
        .scsi_rst  (b_rst),
        .scsi_sel  (b_sel),
        .scsi_atn  (b_atn),
        .scsi_ack  (b_ack),
        .scsi_dout (b_dout_init),
        .scsi_bsy  (bus_bsy),
        .scsi_msg  (bus_msg),
        .scsi_cd   (bus_cd),
        .scsi_io   (bus_io),
        .scsi_req  (bus_req),
        .scsi_din  (bus_din),
        .dma_req   (dma_req),
        .dma_dir_in(dma_dir_in),
        .dma_wdata (dma_wdata),
        .dma_eop   (dma_eop),
        .dma_ack   (dma_ack),
        .dma_rdata (dma_rdata),
        .irq       (irq),
        .dbg_bcn   (wd_bcn)
    );

    // ---- the block cache ---------------------------------------------------
    // The three cache slots and the IDs they serve. sgiindy.sv maps hps_io's
    // menu slots 1, 2, 3 onto IDs 1, 2, 6 in this same order.
    localparam int SLOT0_ID = 1;
    localparam int SLOT1_ID = 2;
    localparam int SLOT2_ID = 6;

    // The engine side of the cache: what the targets used to get from hps_io.
    // One transaction at a time, so the buffer buses are shared and the ack
    // says whose it is.
    wire [31:0] e_lba;
    wire  [2:0] e_rd, e_wr, e_ack;
    wire [12:0] e_buff_addr;
    wire [15:0] e_buff_dout, e_buff_din;
    wire        e_buff_wr;
    // The platform side: what hps_io now sees.
    wire [31:0] p_lba;
    wire  [5:0] p_blk_cnt;
    wire  [2:0] p_rd, p_wr, p_ack;
    wire [15:0] p_buff_din;
    wire [31:0] cache_hits, cache_misses, cache_writes;

    assign e_rd = { t_rd[SLOT2_ID], t_rd[SLOT1_ID], t_rd[SLOT0_ID] };
    assign e_wr = { t_wr[SLOT2_ID], t_wr[SLOT1_ID], t_wr[SLOT0_ID] };
    // The cache takes slot 0's request before slot 1's before slot 2's, and
    // samples e_lba in the same cycle, so the LBA has to be chosen by the
    // same priority.
    assign e_lba = (e_rd[0] | e_wr[0]) ? t_lba[SLOT0_ID] :
                   (e_rd[1] | e_wr[1]) ? t_lba[SLOT1_ID] : t_lba[SLOT2_ID];
    // A write is read out of the target the cache is acking. `sd_buff_din` is
    // the port-A read of a registered dual-port RAM inside the target, so it
    // carries the pair for whatever address was presented ONE clock earlier -
    // the cache's E_WR_A/B/C sequence samples with exactly that delay, as the
    // harness did before it (verilator/sim_scsi.h).
    assign e_buff_din = e_ack[0] ? t_din[SLOT0_ID] :
                        e_ack[1] ? t_din[SLOT1_ID] : t_din[SLOT2_ID];
    assign p_ack = { sd_ack[SLOT2_ID], sd_ack[SLOT1_ID], sd_ack[SLOT0_ID] };

    scsi_cache #(
        .SECT0   (CACHE_SECT0),
        .SECT1   (CACHE_SECT1),
        // A slot that passes through needs no store: the Mac build keeps the
        // CD's 16 sectors allocated with CACHE_CD = 0, this one does not.
        .SECT2   (CACHE_CD ? CACHE_SECT2 : 0),
        .PF_DEPTH(8),
        .CACHE_CD(CACHE_CD),
        // The CD's multi-block path over there needs the Mac's Main fork; the
        // CD slot here passes through anyway (CACHE_CD = 0), so this only
        // matters if that is ever turned on - and then stock Main serves a
        // flat ISO in 8-sector runs like any other image.
        .MB_CD   (0)
    ) u_cache (
        .clk        (clk),
        .nreset     (~reset),
        .e_lba      (e_lba),
        .e_rd       (e_rd),
        .e_wr       (e_wr),
        .e_ack      (e_ack),
        .e_buff_addr(e_buff_addr),
        .e_buff_dout(e_buff_dout),
        .e_buff_din (e_buff_din),
        .e_buff_wr  (e_buff_wr),
        .p_lba      (p_lba),
        .p_blk_cnt  (p_blk_cnt),
        .p_rd       (p_rd),
        .p_wr       (p_wr),
        .p_ack      (p_ack),
        .p_buff_addr(sd_buff_addr),
        .p_buff_dout(sd_buff_dout),
        .p_buff_din (p_buff_din),
        .p_buff_wr  (sd_buff_wr),
        .img_mounted({ img_mounted[SLOT2_ID], img_mounted[SLOT1_ID], img_mounted[SLOT0_ID] }),
        .img_blocks (img_blocks),
        .bypass     (cache_bypass),
        .stat_hits  (cache_hits),
        .stat_misses(cache_misses),
        .stat_writes(cache_writes)
    );

    // ---- the targets -------------------------------------------------------
    // Disks everywhere except the IDs named by CDROM_IDS, which get CD-ROM
    // drives. No Toolbox on either.
    //
    // A CD-ROM elaborates rtl/scsi/cd_audio.sv, which is a STUB - the real
    // engine is not vendored and there is no audio path in this machine for it
    // to feed. See that file and docs/FEATURES_EVALUATE.md. The data path is
    // unaffected: it is scsi.v's own, and it is what reads an ISO.
    genvar t;
    generate
        for (t = 0; t < NUM_TARGETS; t++) begin : g_target
            if (TARGET_EN[t]) begin : g_live
                wire [15:0] unused_snd_l, unused_snd_r;
                // Which cache slot serves this ID, or 3 for none. A localparam
                // per generate iteration rather than a constant function or
                // an unpacked-array parameter: the one shape every tool here
                // agrees is a constant.
                localparam int SLOT = (t == SLOT0_ID) ? 0 :
                                      (t == SLOT1_ID) ? 1 :
                                      (t == SLOT2_ID) ? 2 : 3;

                scsi #(.ID(t[2:0]), .CDROM(CDROM_IDS[t] ? 1 : 0),
                       .TOOLBOX_ENABLE(0)) u_target (
                    .clk            (clk),
                    .rst            (b_rst),
                    .sys_rst        (reset),
                    .sel            (b_sel),
                    // Every other target's BSY: a wedged one must not let a second
                    // selection put two targets on the bus at once.
                    .bus_busy       (|(t_bsy & ~(1 << t))),
                    .atn            (b_atn),
                    // A CD-ROM DRIVE IS PRESENT WHETHER OR NOT A DISC IS IN IT,
                    // and scsi.v takes that from here rather than from `mounted`:
                    //
                    //   if(sel && din[ID] && ((CDROM != 0) ? cd_enable : mounted)
                    //
                    // so a CD-ROM target with this tied low never answers a
                    // selection at all - the image mounts, the PROM scans the bus,
                    // and not one command is ever addressed to it. A disk keys off
                    // `mounted` and is unaffected, which is why this was invisible
                    // for as long as every target was a disk.
                    .cd_enable      (CDROM_IDS[t] ? 1'b1 : 1'b0),
                    .bsy            (t_bsy[t]),
                    .msg            (t_msg[t]),
                    .cd             (t_cd[t]),
                    .io             (t_io[t]),
                    .req            (t_req[t]),
                    .req_bus        (),
                    .ack            (b_ack),
                    // Initiator-side hints the MacLC core's NCR5380 uses to
                    // prefetch. This initiator is byte-at-a-time and asks for
                    // nothing early, so both stay low.
                    .host_csr_rd    (1'b0),
                    .host_data_rd   (1'b0),
                    .din            (b_dout_init),
                    .dout           (t_dout[t]),
                    .dout_pair      (),
                    .dout_pair_next (),
                    .cd_snd_l       (unused_snd_l),
                    .cd_snd_r       (unused_snd_r),
                    .img_mounted    (img_mounted[t]),
                    .img_blocks     (img_blocks),
                    // The block port, on the cache's engine side. The buffer
                    // buses are the cache's, shared; only the ack is this
                    // target's own. A target with no cache slot gets no ack, ever
                    // (see TARGET_EN).
                    .io_lba         (t_lba[t]),
                    .io_rd          (t_rd[t]),
                    .io_wr          (t_wr[t]),
                    .io_ack         (t_ack[t]),
                    .sd_buff_addr   (e_buff_addr[7:0]),
                    .sd_buff_addr_hi(5'd0),
                    .sd_buff_dout   (e_buff_dout),
                    .sd_buff_din    (t_din[t]),
                    .sd_buff_wr     (e_buff_wr),
                    .dbg_bcn_a      (t_bcn_a[t]),
                    .dbg_bcn_b      (t_bcn_b[t]),
                    .dbg_bcn_stk    (t_bcn_s[t]),
                    .dbg_mounted    (),
                    .dbg_phase      (),
                    .dbg_hs         (),
                    .dbg_hs2        (),
                    .dbg_cmd        (),
                    .dbg_dma_word   (1'b0),
                    .dbg_dma_long   (1'b0),
                    .dbg_dma_lowbyte(8'h00),
                    .dbg_wrsnap     (),
                    .dbg_selsnap    (),
                    .dbg_wrstall    (),
                    .dbg_wrfb       (),
                    .dbg_ring       (),
                    // CD audio and BlueSCSI Toolbox: both compiled out by CDROM(0)
                    // and TOOLBOX_ENABLE(0), but the ports still exist. Listed
                    // rather than left to -Wno-PINMISSING, so a genuinely
                    // forgotten connection stays an error.
                    .dbg_cda0       (),
                    .dbg_cda1       (),
                    .dbg_cda2       (),
                    .dbg_cda3       (),
                    .dbg_cda4       (),
                    .dbg_cdur       (),
                    .tb_mounted     (1'b0),
                    .tb_lba         (),
                    .tb_rd          (),
                    .tb_wr          (),
                    .tb_ack         (1'b0),
                    .tb_buff_din    ()
                );

                if (SLOT < 3) begin : g_slot
                    assign t_ack[t] = e_ack[SLOT];
                    assign sd_rd[t] = p_rd[SLOT];
                    assign sd_wr[t] = p_wr[SLOT];
                end else begin : g_noslot
                    assign t_ack[t] = 1'b0;
                    assign sd_rd[t] = 1'b0;
                    assign sd_wr[t] = 1'b0;
                end
            end else begin : g_absent
                // Not built. Everything this target would have driven is an
                // open-collector line the muxes below still read, so tie it off
                // rather than leave it floating.
                assign t_bsy[t]  = 1'b0;
                assign t_msg[t]  = 1'b0;
                assign t_cd[t]   = 1'b0;
                assign t_io[t]   = 1'b0;
                assign t_req[t]  = 1'b0;
                assign t_dout[t] = 8'h00;
                assign t_lba[t]  = 32'h0;
                assign t_din[t]  = 16'h0;
                assign t_rd[t]   = 1'b0;
                assign t_wr[t]   = 1'b0;
                assign t_ack[t]  = 1'b0;
                assign sd_rd[t]  = 1'b0;
                assign sd_wr[t]  = 1'b0;
                assign t_bcn_a[t] = 64'h0;
                assign t_bcn_b[t] = 64'h0;
                assign t_bcn_s[t] = 64'h0;
            end
        end
    endgenerate

    // PER SLOT, NOT MUXED - still. This used to be a last-match-wins mux over
    // every requesting target ("only the target currently on the bus has an
    // outstanding block request" - docs/29 showed that is a hope, not an
    // invariant): with the disk and the CD requesting together, the
    // higher-numbered target's LBA won for BOTH, and the disk's block was
    // served from the CD's address. hps_io reads sd_lba[slot] for the slot it
    // is servicing. With the cache in between there is exactly one platform
    // transaction at a time, its LBA and read-back word are the cache's, and
    // the same value on every ID's line is correct by construction: hps_io
    // only ever looks at the one whose request line is up.
    //
    // The write flush was tied to zero for as long as SCSI was first fitted,
    // which is why the DATA OUT path could look finished from the initiator's
    // end and still put 512 zero bytes on the disk; it is the cache's port-B
    // read now, registered one clock behind sd_buff_addr like the target's
    // was, and the reader on the other side samples with that delay
    // (verilator/sim_scsi.h; hps_io reads a whole SPI word later).
    always_comb
        for (int k = 0; k < NUM_TARGETS; k++) begin
            sd_lba[k]      = p_lba;
            sd_buff_din[k] = p_buff_din;
        end
    assign sd_blk_cnt = p_blk_cnt;

    // The live-request view of the same thing, for the beacon word only: the
    // encoding predates the per-slot split and the decoder expects one LBA.
    wire [31:0] lba_live = (|sd_rd | |sd_wr) ? p_lba : 32'h0;

    // ---- the disk-time counters (docs/49) ----------------------------------
    // Cycle counters are 38 bits and the beacon carries bits [37:6]: one unit
    // is 64 cycles = 1.28 us at 50 MHz, and 2^32 of them is 5,500 s.
    wire hps_busy  = |sd_rd | |sd_wr | |sd_ack;              // an HPS transaction outstanding
    wire eng_busy  = |e_rd | |e_wr | |e_ack;                 // a target waiting on its block port
    wire data_ph   = bus_bsy && !bus_cd && !bus_msg;         // DATA IN or DATA OUT
    reg  [31:0] st_xact_rd, st_xact_wr, st_data_bytes;
    reg  [37:0] st_hps_cyc, st_eng_cyc, st_bsy_cyc, st_data_cyc;
    reg         ack_d, b_ack_d;
    always_ff @(posedge clk) begin
        ack_d   <= |sd_ack;
        b_ack_d <= b_ack;
        if (reset) begin
            st_xact_rd <= 32'd0; st_xact_wr <= 32'd0; st_data_bytes <= 32'd0;
            st_hps_cyc <= 38'd0; st_eng_cyc <= 38'd0; st_bsy_cyc <= 38'd0; st_data_cyc <= 38'd0;
        end else begin
            // At the rising edge of the ack the request line is still up
            // (the cache drops it on seeing the ack), so the direction is
            // readable there.
            if (|sd_ack && !ack_d) begin
                if (|sd_wr) st_xact_wr <= st_xact_wr + 32'd1;
                else        st_xact_rd <= st_xact_rd + 32'd1;
            end
            if (hps_busy) st_hps_cyc  <= st_hps_cyc + 38'd1;
            if (eng_busy) st_eng_cyc  <= st_eng_cyc + 38'd1;
            if (bus_bsy)  st_bsy_cyc  <= st_bsy_cyc + 38'd1;
            if (data_ph)  st_data_cyc <= st_data_cyc + 38'd1;
            // One initiator ACK per byte on an 8-bit bus.
            if (data_ph && b_ack && !b_ack_d) st_data_bytes <= st_data_bytes + 32'd1;
        end
    end
    assign dbg_stat[0] = { st_xact_rd, st_xact_wr };
    assign dbg_stat[1] = { st_hps_cyc[37:6], st_eng_cyc[37:6] };
    assign dbg_stat[2] = { cache_hits, cache_misses };
    assign dbg_stat[3] = { st_data_bytes, st_bsy_cyc[37:6] };
    assign dbg_stat[4] = { st_data_cyc[37:6], cache_writes };

    // SGI: DDR3 debug beacon assembly (docs/28).
    // [0]: {sd_rd, sd_wr, sd_ack, t_bsy (7 bits each),
    //       b_rst, b_sel, b_atn, b_ack, bus_bsy, bus_msg, bus_cd, bus_io,
    //       bus_req, sd_lba[26:0]}
    assign dbg_bcn[0] = { sd_rd, sd_wr, sd_ack, t_bsy,
                          b_rst, b_sel, b_atn, b_ack,
                          bus_bsy, bus_msg, bus_cd, bus_io, bus_req,
                          lba_live[26:0] };
    assign dbg_bcn[1] = wd_bcn;
    assign dbg_bcn[2] = t_bcn_a[1];
    assign dbg_bcn[3] = t_bcn_b[1];
    assign dbg_bcn[4] = t_bcn_a[6];
    assign dbg_bcn[5] = t_bcn_b[6];
    assign dbg_bcn[6] = t_bcn_s[1];

endmodule
