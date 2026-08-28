//============================================================================
//  sgi_scsi - the SGI side of the WD33C93B, plus the targets behind it.
//
//  Three jobs: decode the two byte-wide ports out of a 64-bit big-endian bus
//  access, wire the initiator to an array of scsi.v targets, and do the bus
//  arbitration between them.
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
    parameter logic [6:0] TARGET_EN = 7'b100_0110
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
    input  logic [NUM_TARGETS-1:0]  img_mounted,
    input  logic [31:0]             img_blocks,
    output logic [31:0]             sd_lba,
    output logic [NUM_TARGETS-1:0]  sd_rd,
    output logic [NUM_TARGETS-1:0]  sd_wr,
    input  logic [NUM_TARGETS-1:0]  sd_ack,
    input  logic  [7:0]             sd_buff_addr,
    input  logic [15:0]             sd_buff_dout,
    output logic [15:0]             sd_buff_din,
    input  logic                    sd_buff_wr
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
        .irq       (irq)
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
                wire        t_rd, t_wr;

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
                    .io_lba         (t_lba[t]),
                    .io_rd          (t_rd),
                    .io_wr          (t_wr),
                    .io_ack         (sd_ack[t]),
                    .sd_buff_addr   (sd_buff_addr),
                    .sd_buff_addr_hi(5'd0),
                    .sd_buff_dout   (sd_buff_dout),
                    .sd_buff_din    (t_din[t]),
                    .sd_buff_wr     (sd_buff_wr),
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

                assign sd_rd[t] = t_rd;
                assign sd_wr[t] = t_wr;
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
                assign sd_rd[t]  = 1'b0;
                assign sd_wr[t]  = 1'b0;
            end
        end
    endgenerate

    // Only the target currently on the bus has an outstanding block request.
    always_comb begin
        sd_lba = 32'h0;
        for (int k = 0; k < NUM_TARGETS; k++)
            if (sd_rd[k] || sd_wr[k]) sd_lba = t_lba[k];
    end

    // The write flush, muxed the same way and off the same request lines. This
    // was tied to zero for as long as SCSI has been fitted, which is why the
    // DATA OUT path could look finished from the initiator's end and still put
    // 512 zero bytes on the disk: scsi.v assembles the block correctly and the
    // wrapper then threw it away. `sd_buff_din` is the port-A read of a
    // registered dual-port RAM inside the target, so it carries the pair for
    // whatever `sd_buff_addr` was presented ONE clock earlier - the reader on
    // the other side has to sample with that delay, and verilator/sim_scsi.h
    // does.
    //
    // SELECTED BY THE ACK, NOT BY THE REQUEST. sd_wr is the request line and
    // scsi.v drops it the moment the ack arrives (`if(io_ack) io_wr <= 0`),
    // but the flush that follows runs for the whole ack session - hundreds of
    // cycles. Muxing on sd_wr therefore selects the right target for the first
    // cycle or two and then feeds zeros to the rest of the block, which reads
    // back as a disk full of zeros with the first word or two correct: the
    // same symptom as this output being tied off, and the reason to say out
    // loud which line holds for the length of a session. sd_ack is that line.
    always_comb begin
        sd_buff_din = 16'h0000;
        for (int k = 0; k < NUM_TARGETS; k++)
            if (sd_wr[k] || sd_ack[k]) sd_buff_din = t_din[k];
    end

endmodule
