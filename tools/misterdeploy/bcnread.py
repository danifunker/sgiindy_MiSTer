#!/usr/bin/env python3
"""Read the SCSI debug beacon out of DDR3. RUNS ON THE DEVICE.

The other end of the beacon writer in sgiindy.sv (docs/28): the core streams
eight 64-bit SCSI status words into the otherwise-unused DDR3 window at ARM
physical 0x35800000, refreshed completely every ~16 us. This decodes them.

Word map (see sgiindy.sv / sgi_scsi.sv / scsi.v / wd33c93.sv for the source
of each field - the bit maps live next to the assemblies):

  w0  {BEC0, version, 00, heartbeat32}      - liveness; magic proves the fit
  w1  bus/HPS: sd_rd/sd_wr/sd_ack/t_bsy (7b each), b_rst/sel/atn/ack,
      bus bsy/msg/cd/io/req, sd_lba[26:0]
  w2  wd33c93: chip_reset / rst_load / C_RESET / SEL_XFER / LCI counters,
      R_COMMAND, R_CMD_PHASE, cip/int_pending/lci, state
  w3  target 1 live A   w4  target 1 live B
  w5  target 6 live A   w6  target 6 live B
  w7  target 1 sticky first-stall snapshot (reason 1 = REQ suppressed,
      reason 2 = REQ up but never answered), latched until core reload

The heartbeat moving proves the writer is alive; the counters moving tell
which recovery events actually happen during the 60 s retry loop; the sticky
word names the first parked state outright.

Usage (on the MiSTer):
    bcnread.py                one decoded sample
    bcnread.py --loop 30 --interval 2      sample for a minute
    bcnread.py --raw          just the eight hex words
"""
import argparse
import importlib.util
import struct
import time

spec = importlib.util.spec_from_file_location("p", "/media/fat/sgidbg/ddr3_peek.py")
_m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(_m)

BASE = 0x35800000
NWORDS = 16
PHASES = ["IDLE", "CMD_IN", "DATA_OUT", "DATA_IN", "STATUS", "MSG_IN", "TB", "MSG_OUT"]
DSTATES = ["IDLE", "FETCH_LO", "FETCH_LO_W", "FETCH_HI", "FETCH_HI_W", "EVAL",
           "RUN", "MEM_RD", "MEM_RD_W", "MEM_WR", "MEM_WR_W", "ADVANCE",
           "DESC_END", "COMPLETE", "?14", "?15"]


def rdwords():
    raw = _m.read_phys(BASE, NWORDS * 8)
    return struct.unpack("<%dQ" % NWORDS, raw)


def bits(w, hi, lo):
    return (w >> lo) & ((1 << (hi - lo + 1)) - 1)


def dec_target(a, b, name):
    phase = bits(a, 55, 53)
    flags = []
    for bit, label in ((52, "bsy"), (51, "req"), (50, "ack"), (49, "io_rd_d"),
                       (48, "io_wr"), (47, "wr_pend"), (46, "io_ack"),
                       (45, "ca_act"), (44, "dpc"), (43, "mnt"), (42, "sel"),
                       (41, "atn"), (40, "sbsel")):
        if bits(a, bit, bit):
            flags.append(label)
    return ("%s op=%02x phase=%s cmd_cnt=%d data_cnt=%d tlen=%d lba=%d "
            "data_len=%d rdblk=%d [%s]"
            % (name, bits(a, 63, 56), PHASES[phase], bits(a, 39, 36),
               bits(a, 35, 18), bits(a, 15, 0), bits(b, 63, 32),
               bits(b, 31, 8), bits(b, 7, 0), " ".join(flags) or "-"))


def dec_hpc3(w):
    flags = []
    for bit, label in ((59, "active"), (58, "INT"), (57, "dir_in"),
                       (56, "eox"), (55, "xie"), (54, "dev_req"),
                       (53, "dev_ack"), (52, "dev_dirin"), (51, "dev_eop"),
                       (50, "dma_req"), (49, "dma_ack"), (48, "dma_we")):
        if bits(w, bit, bit):
            flags.append(label)
    return ("hpc3-dma: dstate=%s bc=%d cbp=0x%08x [%s]"
            % (DSTATES[bits(w, 63, 60)], bits(w, 47, 32), bits(w, 31, 0),
               " ".join(flags) or "-"))


def dec_int(w9, w10):
    # w9: [55]scsi_irq [54]scsi_dma_irq [53:49]irq_lines(IP6..IP2) [39:0]int2_state
    # int2_state: [7:0]l0_stat [15:8]L0_MASK [23:16]l1_stat [31:24]L1_MASK [39:32]map_stat
    i2 = bits(w9, 39, 0)
    l0_stat = bits(i2, 7, 0)
    l0_mask = bits(i2, 15, 8)
    ip = bits(w9, 53, 49)  # {IP6,IP5,IP4,IP3,IP2}
    scsi_src = bits(l0_stat, 1, 1)
    scsi_msk = bits(l0_mask, 1, 1)
    ip2 = bits(ip, 0, 0)
    # w10: [63:32]dbg_pc [31:0]dbg_cop0
    pc = bits(w10, 63, 32)
    cop0 = bits(w10, 31, 0)
    excl = bits(cop0, 3, 3)
    execng = bits(cop0, 12, 12)
    stall = bits(cop0, 17, 13)
    lines = []
    lines.append("int: scsi_irq=%d scsi_dma_irq=%d | L0_stat=%02x L0_MASK=%02x "
                 "(scsi src=%d msk=%d) IP2=%d ip=%s"
                 % (bits(w9, 55, 55), bits(w9, 54, 54), l0_stat, l0_mask,
                    scsi_src, scsi_msk, ip2, format(ip, "05b")))
    lines.append("cpu: pc=0x%08x EXL=%d exec=%d stall=%d cop0=0x%08x"
                 % (pc, excl, execng, stall, cop0))
    return lines


VDMA_STATES = ["IDLE", "CHECK", "BEAT", "MEMA", "MEMB", "GIO", "PTE", "STEP",
               "DONE", "?9", "?10", "?11", "?12", "?13", "?14", "?15"]


def dec_vdma(w11, w12, w13):
    # w11 (sgi_mc dma_dbg): [63:56]mode [55]XLATE [52]IE [51:48]cause
    #   [47:24]engine{state[3:0],fault[2:0],skip,beats[15:0]}
    #   [23]int level [19:0]gio_adr[19:0]
    # w12: [63:32]memadr [31:0]gio_adr  (the live descriptor registers)
    # w13: [63:48]magic 4E44 [33]vblank [32]mc_dma_int, np dbg in [31:0]:
    #   [31:16]wr_beats [15:8]rd_beats [7:4]drops
    #   [3]rd_wait [2]engine_busy [1]go_pending [0]wr_held
    lines = []
    eng = bits(w11, 47, 24)
    lines.append("vdma: mode=%02x xlate=%d ie=%d cause=%x int=%d "
                 "eng=%s fault=%x skip=%d beats=%d gio_lo=%05x"
                 % (bits(w11, 63, 56), bits(w11, 55, 55), bits(w11, 52, 52),
                    bits(w11, 51, 48), bits(w11, 23, 23),
                    VDMA_STATES[bits(eng, 23, 20)], bits(eng, 19, 17),
                    bits(eng, 16, 16), bits(eng, 15, 0), bits(w11, 19, 0)))
    lines.append("vdma: memadr=0x%08x gio_adr=0x%08x"
                 % (bits(w12, 63, 32), bits(w12, 31, 0)))
    np = bits(w13, 31, 0)
    lines.append("rex3: wr_beats=%d rd_beats=%d drops=%d rd_wait=%d busy=%d "
                 "go=%d held=%d | vblank=%d mc_int=%d"
                 % (bits(np, 31, 16), bits(np, 15, 8), bits(np, 7, 4),
                    bits(np, 3, 3), bits(np, 2, 2), bits(np, 1, 1),
                    bits(np, 0, 0), bits(w13, 33, 33), bits(w13, 32, 32)))
    return lines


DID_STATES = ["IDLE", "LPTR", "E0", "E1", "RUN", "NEXT", "?6", "?7"]


def dec_disp(w14):
    # w14 (newport dbg_disp): [63:56]=4D [55]=DID_EN [54:52]=walker state
    #   [51:47]=did in use [46:23]=xmap mode entry [22:21]=pup [20]=ovl_on
    #   [19]=direct [18:6]=cmap index
    mode = bits(w14, 46, 23)
    return ["disp: did_en=%d walk=%s did=%d | mode=%06x (bufsel=%d ovlbsel=%d "
            "cmap_pg=%d pixmode=%d pixsize=%d auxmode=%d auxpg=%d) | "
            "pup=%d ovl=%d direct=%d cidx=0x%04x"
            % (bits(w14, 55, 55), DID_STATES[bits(w14, 54, 52)],
               bits(w14, 51, 47), mode,
               bits(mode, 0, 0), bits(mode, 1, 1), bits(mode, 7, 3),
               bits(mode, 9, 8), bits(mode, 11, 10), bits(mode, 18, 16),
               bits(mode, 23, 19),
               bits(w14, 22, 21), bits(w14, 20, 20), bits(w14, 19, 19),
               bits(w14, 18, 6))]


def dec(ws):
    w0, w1, w2, w3, w4, w5, w6, w7 = ws[:8]
    w8 = ws[8] if len(ws) > 8 else 0
    w9 = ws[9] if len(ws) > 9 else 0
    w10 = ws[10] if len(ws) > 10 else 0
    out = []
    magic = bits(w0, 63, 48)
    if magic != 0xBEC0:
        return ["NO BEACON: w0=%016x (magic %04x, want BEC0) - old fit?" % (w0, magic)]
    out.append("beat=%d ver=%d" % (bits(w0, 31, 0), bits(w0, 47, 40)))
    out.append("bus: sd_rd=%02x sd_wr=%02x sd_ack=%02x t_bsy=%02x "
               "rst=%d sel=%d atn=%d ack=%d | bsy=%d msg=%d cd=%d io=%d req=%d "
               "sd_lba=%d"
               % (bits(w1, 63, 57), bits(w1, 56, 50), bits(w1, 49, 43),
                  bits(w1, 42, 36), bits(w1, 35, 35), bits(w1, 34, 34),
                  bits(w1, 33, 33), bits(w1, 32, 32), bits(w1, 31, 31),
                  bits(w1, 30, 30), bits(w1, 29, 29), bits(w1, 28, 28),
                  bits(w1, 27, 27), bits(w1, 26, 0)))
    out.append("wd:  chip_rst=%d rst_load=%d c_reset=%d sel_xfer=%d lci=%d "
               "R_CMD=%02x R_CMDPH=%02x cip=%d intp=%d lcif=%d state=%d"
               % (bits(w2, 63, 56), bits(w2, 55, 48), bits(w2, 47, 40),
                  bits(w2, 39, 32), bits(w2, 31, 24), bits(w2, 23, 16),
                  bits(w2, 15, 8), bits(w2, 7, 7), bits(w2, 6, 6),
                  bits(w2, 5, 5), bits(w2, 4, 0)))
    out.append(dec_target(w3, w4, "id1:"))
    out.append(dec_target(w5, w6, "id6:"))
    out.append(dec_hpc3(w8))
    if len(ws) > 10:
        out.extend(dec_int(w9, w10))
    if len(ws) > 13 and bits(w0, 47, 40) >= 6:
        out.extend(dec_vdma(ws[11], ws[12], ws[13]))
    if len(ws) > 14 and bits(w0, 47, 40) >= 7:
        out.extend(dec_disp(ws[14]))
    if len(ws) > 15 and bits(w0, 47, 40) >= 8:
        # w15: the display line caches (docs/36). rgb_miss and aux_miss are
        # pixels served black because the line was not resident; aux_skips
        # is lines the auxiliary cache published as zeros without a fetch.
        w15 = ws[15]
        out.append("lcache: rgb_miss=%d aux_miss=%d aux_skips=%d"
                   % (bits(w15, 63, 48), bits(w15, 47, 32), bits(w15, 31, 0)))
    reason = bits(w7, 63, 62)
    if reason:
        why = {1: "REQ-SUPPRESSED (io_busy/dpc class)",
               2: "REQ-UNANSWERED (initiator absent class)"}[reason] \
              if reason in (1, 2) else str(reason)
        # The sticky holds A[59:0]: rebuild an A-shaped word for the decoder;
        # the opcode's top nibble is the one field the latch does not keep.
        a = bits(w7, 59, 0)
        out.append("STICKY %s:" % why)
        out.append("  " + dec_target(a, 0, "id1@latch:"))
    else:
        out.append("sticky: clean")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--loop", type=int, default=1)
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--raw", action="store_true")
    a = ap.parse_args()
    for i in range(a.loop):
        ws = rdwords()
        if a.raw:
            print(" ".join("%016x" % w for w in ws))
        else:
            stamp = time.strftime("%H:%M:%S")
            print("---- %s" % stamp)
            for line in dec(ws):
                print(line)
        if i + 1 < a.loop:
            time.sleep(a.interval)


if __name__ == "__main__":
    main()
