// sim_scsi.h - the harness end of the SCSI block device.
//
// Stands in for what hps_io does on hardware: watch each target's sd_rd/sd_wr
// request line, move one 512-byte block through the shared sector buffer, and
// answer with sd_ack. Requests are levels, not pulses, and the ack is what
// releases them.
//
// The transfer deliberately takes a few hundred cycles rather than completing
// in one. A real HPS session is far slower than that, and an instant ack hides
// every ordering bug in the target's double-buffer handling - the kind that
// then only appears on hardware.
#pragma once
#include <cstdint>
#include "sim_devices.h"

class ScsiBlockDev {
public:
    // Cycles a block transfer takes. Must exceed the 256 words a 512-byte
    // block needs, with room to spare so the ack outlives the last write.
    static constexpr int XFER_CYCLES = 300;

    template <typename TOP>
    void step(TOP *top)
    {
        using namespace sgisim;

        uint8_t rd = top->scsi_sd_rd;
        uint8_t wr = top->scsi_sd_wr;
        uint8_t ack = 0;

        // Cleared every cycle; only a live block transfer raises it.
        top->scsi_sd_buff_wr = 0;

        // hps_io presents one mounted flag and one size per slot; the targets
        // latch them. Held rather than pulsed, which is what scsi.v's
        // `mounted` latch expects to see.
        uint8_t mounted = 0;
        for (int i = 0; i < 7; i++) if (g_dev.scsi[i].mounted) mounted |= (1u << i);
        top->scsi_img_mounted = mounted;
        top->scsi_img_blocks  = (uint32_t)(g_dev.scsi[0].blocks());

        for (int i = 0; i < 7; i++) {
            ScsiDisk &d = g_dev.scsi[i];
            bool want_rd = (rd >> i) & 1;
            bool want_wr = (wr >> i) & 1;

            if (!d.busy) {
                if ((want_rd || want_wr) && d.mounted) {
                    d.busy      = true;
                    d.writing   = want_wr;
                    d.lba       = top->scsi_sd_lba;
                    d.countdown = XFER_CYCLES;
                    if (!d.writing) {
                        size_t off = (size_t)d.lba * 512;
                        for (int b = 0; b < 512; b++)
                            d.sector[b] = (off + b < d.image.size()) ? d.image[off + b] : 0;
                    }
                }
                continue;
            }

            // ACK is a level held for the whole session, not a pulse: scsi.v
            // flips its double-buffer on the FALLING edge of io_ack, so a
            // one-cycle ack would flip it without ever having filled the half
            // it is flipping away from.
            ack |= (1u << i);

            // A read streams the block into the target's buffer, one 16-bit
            // word per cycle - 256 words for a 512-byte block. A write is
            // consumed but not stored yet; nothing writes to a disk before
            // there is a filesystem on one.
            if (!d.writing) {
                int idx = XFER_CYCLES - d.countdown;
                if (idx >= 0 && idx < 256) {
                    top->scsi_sd_buff_addr = (uint8_t)idx;
                    // Byte 0 of the pair in the high half - the "sim packs
                    // byte0 in high half" branch in scsi.v's unpacking.
                    top->scsi_sd_buff_dout =
                        (uint16_t)((d.sector[idx * 2] << 8) | d.sector[idx * 2 + 1]);
                    top->scsi_sd_buff_wr = 1;
                }
            }

            if (--d.countdown <= 0) d.busy = false;
        }

        top->scsi_sd_ack = ack;
    }
};
