// sim_scsi.h - the harness end of the SCSI block device.
//
// Stands in for what hps_io does on hardware: watch each target's sd_rd/sd_wr
// request line, move a run of 512-byte blocks through the shared sector
// buffer, and answer with sd_ack. Requests are levels, not pulses, and the
// ack is what releases them.
//
// The transfer deliberately takes a few hundred cycles per block rather than
// completing in one. A real HPS session is far slower than that, and an
// instant ack hides every ordering bug in the requester's buffer handling -
// the kind that then only appears on hardware.
//
// MULTI-BLOCK (docs/49). The block cache in rtl/scsi/sgi_scsi.sv asks for up
// to eight sectors at a time: scsi_sd_blk_cnt is blocks minus one, and the
// run streams through the 13-bit scsi_sd_buff_addr as (n+1)*256 consecutive
// words from sd_lba upward - exactly what hps_io does when Main honours
// sd_blk_cnt (user_io.cpp: blks = ((c >> 9) & 0x3F) + 1). One ack session
// covers the whole run.
#pragma once
#include <cstdint>
#include <cstring>
#include "sim_devices.h"

class ScsiBlockDev {
public:
    // Cycles a one-block transfer takes beyond the words themselves, so the
    // ack outlives the last write with room to spare.
    static constexpr int XFER_SLACK = 44;

    // Cycles each word is held on the bus during a WRITE (core -> harness).
    // hps_io advances sd_buff_addr and samples sd_buff_din one SPI word
    // apart, which is many core clocks; the requester's read-back is a
    // registered RAM read one clock behind the address (scsi.v), and the
    // cache's passthrough puts a second register in that path. Holding the
    // address for four clocks and sampling on the last covers both, without
    // being as slow as the real thing.
    static constexpr int WR_HOLD = 4;

    // Cycles each slot's mount flag is held while its size is on the bus. Only
    // has to outlast one clock edge in the target; a few is cheap insurance
    // against the harness and the RTL disagreeing about which edge counts.
    static constexpr int MOUNT_HOLD = 8;

private:
    uint8_t mount_set  = 0;     // which slots the walk below is announcing
    int     mount_step = 0;     // position in the walk; >= 7*MOUNT_HOLD is done

    // The run in flight per slot: how many blocks, and the whole run's bytes.
    struct Run {
        int      nblk  = 1;
        int      total = 0;     // cycles the session lasts
        uint8_t  data[8 * 512];
    } run[7];

public:
    // Restart the mount walk. The GUI rebuilds the whole design on reset, so
    // the targets forget they were mounted and have to be told again.
    void reset() { mount_set = 0; mount_step = 0; }

    template <typename TOP>
    void step(TOP *top)
    {
        using namespace sgisim;

        uint8_t rd = top->scsi_sd_rd;
        uint8_t wr = top->scsi_sd_wr;
        uint8_t ack = 0;

        // Cleared every cycle; only a live block transfer raises it.
        top->scsi_sd_buff_wr = 0;

        // Mount the images, ONE SLOT AT A TIME.
        //
        // `img_blocks` is a single 32-bit bus shared by all seven targets
        // (sgi_scsi.sv wires the same wire to every one), exactly as hps_io
        // does on hardware: a mount is an *event*, and the size on the bus
        // belongs to whichever slot's flag is up at that moment. Each target
        // latches it in scsi.v:
        //
        //     if (img_mounted) begin
        //         if (|img_blocks) begin ... mounted <= 1; end
        //         else                       mounted <= 0;
        //
        // so a slot whose flag is high while the bus carries somebody else's
        // size latches that size - and a slot that sees zero unmounts itself.
        // This used to raise every flag at once against slot 0's size, which
        // meant `--disk 1=...` presented a mounted flag with `img_blocks` = 0
        // and the target quietly took it as "no medium". It never answered a
        // selection, and the only symptom was the PROM's bus scan finding
        // nothing - identical to having attached no disk at all.
        //
        // So walk the slots: hold one flag with its own size for a window,
        // drop it, move on. The walk restarts if the set of mounted images
        // ever changes, which is what an OSD mount looks like from here.
        {
            uint8_t want = 0;
            for (int i = 0; i < 7; i++) if (g_dev.scsi[i].mounted) want |= (1u << i);
            if (want != mount_set) { mount_set = want; mount_step = 0; }

            uint8_t flag  = 0;
            uint32_t size = 0;
            int slot = mount_step / MOUNT_HOLD;
            if (slot < 7) {
                if (mount_set & (1u << slot)) {
                    flag = (uint8_t)(1u << slot);
                    size = (uint32_t)g_dev.scsi[slot].blocks();
                }
                mount_step++;
            }
            top->scsi_img_mounted = flag;
            top->scsi_img_blocks  = size;
        }

        for (int i = 0; i < 7; i++) {
            ScsiDisk &d = g_dev.scsi[i];
            Run &r = run[i];
            bool want_rd = (rd >> i) & 1;
            bool want_wr = (wr >> i) & 1;

            if (!d.busy) {
                if ((want_rd || want_wr) && d.mounted) {
                    d.busy      = true;
                    d.writing   = want_wr;
                    // Per-slot, like hps_io: the LBA of THIS target, not a
                    // shared mux another requester could have overwritten.
                    // The port is a flat 224-bit vector (see sim_top.sv), but
                    // each LBA is one aligned 32-bit word of it, so word i of
                    // the VlWide IS target i.
                    d.lba       = top->scsi_sd_lba[i];
                    r.nblk      = (int)top->scsi_sd_blk_cnt + 1;
                    if (r.nblk > 8) r.nblk = 8;
                    r.total     = (d.writing ? WR_HOLD : 1) * 256 * r.nblk + XFER_SLACK;
                    d.countdown = r.total;
                    if (!d.writing)
                        for (int b = 0; b < r.nblk; b++)
                            d.read_block(d.lba + b, r.data + b * 512);
                }
                continue;
            }

            // ACK is a level held for the whole session, not a pulse: scsi.v
            // flips its double-buffer on the FALLING edge of io_ack, so a
            // one-cycle ack would flip it without ever having filled the half
            // it is flipping away from.
            ack |= (1u << i);

            int words = 256 * r.nblk;
            if (!d.writing) {
                // A read streams the run into the requester, one 16-bit word
                // per cycle - 256 words per 512-byte block.
                int idx = r.total - d.countdown;
                if (idx >= 0 && idx < words) {
                    top->scsi_sd_buff_addr = (uint16_t)idx;
                    // Byte 0 of the pair in the high half - the "sim packs
                    // byte0 in high half" branch in scsi.v's unpacking.
                    top->scsi_sd_buff_dout =
                        (uint16_t)((r.data[idx * 2] << 8) | r.data[idx * 2 + 1]);
                    top->scsi_sd_buff_wr = 1;
                }
            } else {
                // A write runs the same walk in reverse, holding each address
                // for WR_HOLD cycles and sampling on the last of them. The
                // requester's `sd_buff_din` is a registered RAM read (one
                // clock behind the address), and through the cache's
                // passthrough two - sampling in the address's own cycle read
                // the previous byte pair and shifted the whole block by two
                // bytes, which looks exactly like an endianness bug and is
                // not one.
                //
                // No sd_buff_wr here: that line is the HPS *writing into* the
                // requester, and raising it during a flush would overwrite
                // the block being read out.
                int t = r.total - d.countdown;
                int idx = t / WR_HOLD;
                if (idx >= 0 && idx < words) {
                    top->scsi_sd_buff_addr = (uint16_t)idx;
                    if (t % WR_HOLD == WR_HOLD - 1) {
                        // Flat 112-bit port: target i's 16 bits sit at
                        // [16*i +: 16], two lanes to a 32-bit VlWide word.
                        uint16_t w = (uint16_t)(top->scsi_sd_buff_din[i >> 1]
                                                >> ((i & 1) * 16));
                        r.data[idx * 2]     = (uint8_t)(w >> 8);
                        r.data[idx * 2 + 1] = (uint8_t)(w & 0xff);
                    }
                }
            }

            if (--d.countdown <= 0) {
                // Commit the run. Only the in-memory image is updated: the
                // file on disk is left alone, because every disk this harness
                // is pointed at is a checked-in fixture and a test that
                // rewrites its own fixture stops being a test the second time
                // it runs. A write followed by a read in the same run sees the
                // new data, which is what proves the path.
                if (d.writing)
                    for (int b = 0; b < r.nblk; b++)
                        d.write_block(d.lba + b, r.data + b * 512);
                d.busy = false;
            }
        }

        top->scsi_sd_ack = ack;
    }
};
