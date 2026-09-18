#!/usr/bin/env python3
"""Two performance-counter readings -> what the machine did between them.

The counters are beacon words 21-34 (ver 10, docs/design/cpu-speed-tlb-icache.md), 35 (ver 11) and 36-39
(ver 12, build 37): sgi_indy.sv counts the CPU's clocks and events, sgiindy.sv
and ddr3_mux.sv the DDR3 port's. `bcnread.py --perf` on the board prints one
reading as a line of 28 integers (30 from ver 11, 38 from ver 12); give this
two of them
(or two files holding one each, or a file holding many - the first and last
are used).

    python perfdiff.py "perf 1726... beat=... 1 2 3 ..." "perf ..."
    python perfdiff.py before.txt after.txt
    python perfdiff.py polls.log            # first and last perf line in it

What comes out, and what it means:
  * where the clocks went: advancing, fetch stage held, execute held, in a
    TLB walk - as shares of the wall clock;
  * the instruction count and clocks per instruction;
  * per event: I-cache fills and D-cache fills per thousand instructions and
    the clocks each spent ON THE BUS (from the issue to mem_done), TLB walks
    per thousand instructions and clocks per walk, writeback beats;
  * the DDR3 port: the share of the wall clock each master held it, how long
    RAM and rasteriser requests waited unserved per transaction, the bridge's
    latency from a read's issue to its first word.
"""
import re
import sys

CLK_HZ = 50_000_000
X64 = 64

NAMES = [
    "retired_x64", "run_x64",
    "st1_x64", "st3_x64",
    "st4_x64", "tlb_x64",
    "ifillbus_x64", "dfillbus_x64",
    "ifills", "dfills",
    "wbbeats", "ufetch",
    "tlbi_walks", "tlbd_walks",
    "memreq", "bus_x64",
    "own_fbr_x64", "own_ram_x64",
    "own_fbw_x64", "own_oth_x64",
    "q_ram_x64", "q_fbw_x64",
    "n_ram", "n_fbw",
    "lat_x64", "n_rd",
    "bsy_x64", "n_fbr",
    "irefills", "icached",   # ver 11
    "latram_x64", "n_ramrd",       # ver 12: w36 ddr3_mux dbg_rdlat[0]
    "ahead_x64", "gapram_x64",     #         w37 dbg_rdlat[1]
    "latclean_x64", "n_clean",     #         w38 dbg_rdlat[2]
    "arbwait_x64", "n_dma",        #         w39 sgi_indy dbg_perf_bcn[9]
]


def parse_line(line):
    m = re.search(r"perf\s+([\d.]+)\s+beat=(\d+)\s+((?:\d+\s*){28,38})", line)
    if not m:
        return None
    vals = [int(x) for x in m.group(3).split()]
    d = dict(zip(NAMES, vals))
    d["has_w35"] = len(vals) >= 30
    d["has_w36"] = len(vals) >= 38
    for k in NAMES[len(vals):]:
        d[k] = 0
    d["t"] = float(m.group(1))
    d["beat"] = int(m.group(2))
    return d


def readings(arg):
    try:
        text = open(arg).read()
    except OSError:
        text = arg
    out = [r for r in (parse_line(l) for l in text.splitlines()) if r]
    return out


def report(a, b):
    """Lines describing what happened between readings a and b."""
    out = []
    d = {}
    for k in NAMES:
        d[k] = (b[k] - a[k]) & 0xFFFFFFFF
    wall_s = b["t"] - a["t"]
    wall_cyc = wall_s * CLK_HZ
    x = lambda k: d[k] * X64   # a /64 counter back in clocks
    pct = lambda c: 100.0 * c / wall_cyc if wall_cyc else 0.0
    instr = x("retired_x64")
    per_k = lambda n: 1000.0 * n / instr if instr else 0.0
    per = lambda c, n: c / n if n else 0.0

    out.append("window %.1f s wall (%.0f clocks at 50 MHz), beacon beats %d"
               % (wall_s, wall_cyc, (b["beat"] - a["beat"]) & 0xFFFFFFFF))
    out.append("CPU: %.2f M instructions, %.2f clocks/instruction, %.2f MIPS"
               % (instr / 1e6, per(wall_cyc, instr), instr / 1e6 / wall_s if wall_s else 0))
    out.append("  clocks: advancing %.1f %%, fetch held %.1f %%, execute held %.1f %%, "
               "writeback held %.1f %%, in a TLB walk %.1f %%"
               % (pct(x("run_x64")), pct(x("st1_x64")), pct(x("st3_x64")),
                  pct(x("st4_x64")), pct(x("tlb_x64"))))
    out.append("  I-cache fills %d (%.2f per 1000 instructions), %.1f clocks each on the bus"
               % (d["ifills"], per_k(d["ifills"]), per(x("ifillbus_x64"), d["ifills"])))
    out.append("  D-cache fills %d (%.2f per 1000), %.1f clocks each on the bus; "
               "writeback beats %d (%.1f lines)"
               % (d["dfills"], per_k(d["dfills"]), per(x("dfillbus_x64"), d["dfills"]),
                  d["wbbeats"], d["wbbeats"] / 4.0))
    if a.get("has_w35") and b.get("has_w35"):
        out.append("  I-cache fills asked for after an instruction TLB walk %d (%.2f per 1000), "
                   "answered from a line already held %d (%.1f %%) - no DDR3 trip"
                   % (d["irefills"], per_k(d["irefills"]), d["icached"],
                      100.0 * per(d["icached"], d["irefills"])))
    out.append("  TLB walks: instruction %d (%.2f per 1000), data %d (%.2f per 1000), "
               "%.1f clocks per walk"
               % (d["tlbi_walks"], per_k(d["tlbi_walks"]), d["tlbd_walks"],
                  per_k(d["tlbd_walks"]), per(x("tlb_x64"), d["tlbi_walks"] + d["tlbd_walks"])))
    out.append("  uncached fetches %d; bus transactions %d, %.1f clocks each on the bus"
               % (d["ufetch"], d["memreq"], per(x("bus_x64"), d["memreq"])))
    out.append("DDR3 port: display held it %.1f %%, RAM %.1f %%, rasteriser %.1f %%, others %.1f %%"
               % (pct(x("own_fbr_x64")), pct(x("own_ram_x64")), pct(x("own_fbw_x64")),
                  pct(x("own_oth_x64"))))
    out.append("  RAM: %d transactions, %.1f clocks held and %.1f clocks queued per transaction"
               % (d["n_ram"], per(x("own_ram_x64"), d["n_ram"]), per(x("q_ram_x64"), d["n_ram"])))
    out.append("  rasteriser: %d transactions, %.1f clocks held and %.1f clocks queued each"
               % (d["n_fbw"], per(x("own_fbw_x64"), d["n_fbw"]), per(x("q_fbw_x64"), d["n_fbw"])))
    if a.get("has_w36") and b.get("has_w36"):
        out.append("  RAM reads: %d, %.1f clocks from the bridge taking one to its first word, "
                   "behind %.1f words owed to earlier reads; %.2f clocks of gaps inside a burst"
                   % (d["n_ramrd"], per(x("latram_x64"), d["n_ramrd"]),
                      per(x("ahead_x64"), d["n_ramrd"]), per(x("gapram_x64"), d["n_ramrd"])))
        out.append("  the bridge alone (reads taken with nothing owed): %d reads, %.1f clocks to the first word"
                   % (d["n_clean"], per(x("latclean_x64"), d["n_clean"])))
        out.append("  CPU accesses held behind a DMA transaction: %.2f s in all; DMA transactions %d"
                   % (x("arbwait_x64") / CLK_HZ, d["n_dma"]))
    out.append("  reads: %d, %.1f clocks from issue to the first word; display bursts %d; "
               "%.1f clocks waiting on DDRAM_BUSY per transaction"
               % (d["n_rd"], per(x("lat_x64"), d["n_rd"]), d["n_fbr"],
                  per(x("bsy_x64"), d["n_ram"] + d["n_fbw"] + d["n_fbr"])))
    return out


def main():
    rs = []
    for a in sys.argv[1:]:
        rs += readings(a)
    if len(rs) < 2:
        sys.exit("need two perf readings")
    for line in report(rs[0], rs[-1]):
        print(line)


if __name__ == "__main__":
    main()
