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
    parameter logic [2:0] HOST_ID = 3'd0
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
        .irq       (irq)
    );

    // ---- the targets -------------------------------------------------------
    // Plain disks: no Toolbox, no CD-ROM, so cd_audio.sv is never elaborated.
    genvar t;
    generate
        for (t = 0; t < NUM_TARGETS; t++) begin : g_target
            wire [15:0] unused_snd_l, unused_snd_r;
            wire        t_rd, t_wr;

            scsi #(.ID(t[2:0]), .CDROM(0), .TOOLBOX_ENABLE(0)) u_target (
                .clk            (clk),
                .rst            (b_rst),
                .sys_rst        (reset),
                .sel            (b_sel),
                // Every other target's BSY: a wedged one must not let a second
                // selection put two targets on the bus at once.
                .bus_busy       (|(t_bsy & ~(1 << t))),
                .atn            (b_atn),
                .cd_enable      (1'b0),
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
                .sd_buff_din    (),
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
        end
    endgenerate

    // Only the target currently on the bus has an outstanding block request.
    always_comb begin
        sd_lba = 32'h0;
        for (int k = 0; k < NUM_TARGETS; k++)
            if (sd_rd[k] || sd_wr[k]) sd_lba = t_lba[k];
    end

    assign sd_buff_din = 16'h0000;

endmodule
