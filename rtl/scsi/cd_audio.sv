//============================================================================
//  cd_audio - a stub. There is no CD audio in this core, deliberately.
//
//  WHY THIS FILE EXISTS AT ALL. `scsi.v` reaches a CD-ROM's data path and its
//  audio path through the same switch:
//
//      generate if (CDROM != 0) begin : g_cd_audio
//          cd_audio #(...) cd_audio_i ( ... );
//      end else begin : g_no_cd_audio
//          assign ca_ast_code = 8'h05; ... (every ca_* tied off)
//      end endgenerate
//
//  so `CDROM(1)` - which is what makes the target answer INQUIRY as a CD-ROM,
//  address 2048-byte logical blocks and report capacity in them - also demands
//  a `cd_audio` module. The real one is in the MacLC core and is deliberately
//  NOT vendored here: `rtl/scsi/README.md` records that it pulls in a volume
//  lookup table this core has no use for, and there is no audio path in this
//  machine for it to feed anyway (HAL2 answers its revision register and
//  nothing else - see `rtl/sgi/sgi_hpc3.sv`).
//
//  So this is the `g_no_cd_audio` branch wearing the `g_cd_audio` branch's
//  port list. Every output carries the same constant that branch assigns, and
//  every input is ignored. **`scsi.v` is not modified**, which is the point:
//  it is vendored, and a data-only CD-ROM should not cost a fork of it.
//
//  THE CONSTANTS ARE COPIED, NOT INVENTED. They are exactly what
//  `g_no_cd_audio` in scsi.v assigns, and they are what a drive with a data
//  disc in it should report:
//
//    ast_code 0x05  audio status "no audio status to return"
//    cur_ctrl 0x14  Q-channel control: data track, digital copy prohibited
//    cur_trk  0x01  track 1
//    disc_audio 0   the disc is not an audio disc, so scsi.v's
//                   `cd_audio_read_rej` never rejects a READ
//    toc_ready 0    no TOC. READ TOC answers zeroes.
//
//  WHAT THIS COSTS. READ TOC returns zeroes, PLAY/PAUSE/audio-status commands
//  answer as no-ops with nothing behind them, and there is no sound. Reading
//  data blocks off an ISO is unaffected, which is the whole use for a CD-ROM
//  here: `hinv` listing it and, later, booting from it.
//
//  Replacing this with the real engine is a vendoring job, not a rewrite - the
//  port list below is the contract. See docs/FEATURES_EVALUATE.md.
//============================================================================

module cd_audio #(
    parameter [31:0] CLK_HZ = 32'd32_500_000
)(
    input               clk,
    input               rst,        // bus reset from the initiator
    input               bus_rst,
    input               mounted,
    input               img_mounted,
    input        [31:0] img_blocks,

    // Command hand-off from scsi.v's phase machine.
    input               cmd_stb,
    input         [7:0] cmd_op,
    input         [7:0] cdb1, cdb2, cdb3, cdb4, cdb5,
    input         [7:0] cdb6, cdb7, cdb8, cdb9,
    input               read_stb,
    input               eject_stb,

    // MODE SENSE page 0x0E audio port routing and the volume slider.
    input         [7:0] ap_ch0, ap_vol0, ap_ch1, ap_vol1,

    // The block-device channel the real engine uses to fetch audio frames.
    // Held inactive here, so scsi.v's arbitration never grants it and the data
    // path owns the block device outright.
    input               ch_grant,
    output              ca_io_active,
    output              ca_io_rd,
    output       [31:0] ca_io_lba,
    input               io_ack,
    input         [7:0] sd_buff_addr,
    input         [4:0] sd_buff_addr_hi,
    input        [15:0] sd_buff_dout,
    input               sd_buff_wr,

    // READ SUB-CHANNEL / audio status.
    output        [7:0] ast_code,
    output        [7:0] cur_ctrl,
    output        [7:0] cur_trk,
    output        [7:0] abs_m, abs_s, abs_f,
    output        [7:0] rel_m, rel_s, rel_f,

    // The three TOC windows scsi.v reads through.
    input         [8:0] toc_base,
    output        [7:0] toc_q0, toc_q1, toc_q2, toc_q3,
    output              toc_ready,
    input         [8:0] toc43_base,
    output        [7:0] toc43_q0, toc43_q1, toc43_q2, toc43_q3,
    output        [9:0] toc43_len,
    input         [8:0] toc2_base,
    output        [7:0] toc2_q0, toc2_q1, toc2_q2, toc2_q3,
    output        [9:0] toc2_len,

    output              disc_audio,
    output signed [15:0] snd_l,
    output signed [15:0] snd_r,
    output       [31:0] dbg_cda0,
    output       [31:0] dbg_cdur
);

    assign ca_io_active = 1'b0;
    assign ca_io_rd     = 1'b0;
    assign ca_io_lba    = 32'd0;

    assign ast_code     = 8'h05;
    assign cur_ctrl     = 8'h14;
    assign cur_trk      = 8'h01;
    assign abs_m = 8'h00; assign abs_s = 8'h00; assign abs_f = 8'h00;
    assign rel_m = 8'h00; assign rel_s = 8'h00; assign rel_f = 8'h00;

    assign toc_q0 = 8'h00; assign toc_q1 = 8'h00;
    assign toc_q2 = 8'h00; assign toc_q3 = 8'h00;
    assign toc_ready = 1'b0;

    assign toc43_q0 = 8'h00; assign toc43_q1 = 8'h00;
    assign toc43_q2 = 8'h00; assign toc43_q3 = 8'h00;
    assign toc43_len = 10'd0;

    assign toc2_q0 = 8'h00; assign toc2_q1 = 8'h00;
    assign toc2_q2 = 8'h00; assign toc2_q3 = 8'h00;
    assign toc2_len = 10'd0;

    assign disc_audio = 1'b0;
    assign snd_l = 16'sd0;
    assign snd_r = 16'sd0;
    assign dbg_cda0 = 32'd0;
    assign dbg_cdur = 32'd0;

endmodule
