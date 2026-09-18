#!/usr/bin/env python3
"""fit_report.py - turn a finished Quartus compile into the reviewable build
report kept in reports/.

Quartus's own reports are 7 MB and live in output_files/, which is not
committed. This pulls out what a reviewer needs to see for a bitstream -
device use, the timing slack of every clock in every check, and where the
logic went - into three small text files that GitHub renders and diffs:

  reports/summary.md              the bitstream (md5, size, date, seed), the
                                  fitter summary, per-clock slack for setup,
                                  hold, recovery, removal and minimum pulse
                                  width, and a per-block breakdown of the SGI
                                  machine
  reports/resources-by-entity.txt Quartus's "Fitter Resource Utilization by
                                  Entity" table, the whole hierarchy
  reports/timing.txt              Quartus's timing summary tables as printed

scripts/build.sh runs it after every successful compile, so the reports always
describe output_files/<project>.rbf; commit them with the release bitstream
they belong to.

  python tools/fit_report.py                         # output_files/sgiindy.* -> reports/
  python tools/fit_report.py --fit X.fit.rpt --sta X.sta.rpt --rbf X.rbf --seed 2
"""
import argparse
import datetime
import hashlib
import os
import re
import sys


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def section(lines, title):
    """The rows of a report table titled `title` (between its +---+ rules)."""
    for i, l in enumerate(lines):
        if l.startswith("; " + title) and l.rstrip().endswith(";"):
            out, rules = [], 0
            for m in lines[i + 1:]:
                if m.startswith("+"):
                    rules += 1
                    out.append(m)
                    if rules >= 3:
                        break
                    continue
                if not m.startswith(";"):
                    break
                out.append(m)
            return [lines[i - 1], lines[i]] + out if i else [lines[i]] + out
    return []


def rows(table):
    """Cells of a table's data rows (skipping the header row)."""
    out, seen_header = [], False
    for l in table:
        if not l.startswith(";"):
            continue
        cells = [c.strip() for c in l.strip().strip(";").split(";")]
        if not seen_header and len(table) > 2 and l is not table[1]:
            seen_header = True
            continue
        out.append(cells)
    return out


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


CLOCK_NAMES = [
    (r"^emu\|pll\|", "core clock (clk_sys, 50 MHz)"),
    (r"^pll_hdmi\|", "HDMI pixel clock"),
    (r"^pll_audio\|", "audio clock"),
    (r"^sysmem\|", "HPS bridge clock"),
    (r"^spi_sck$", "SPI (HPS link)"),
    (r"^FPGA_CLK1_50$", "FPGA_CLK1_50"),
    (r"^FPGA_CLK2_50$", "FPGA_CLK2_50"),
]


def clock_label(name):
    for pat, lab in CLOCK_NAMES:
        if re.search(pat, name):
            return lab
    return name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default="sgiindy")
    ap.add_argument("--fit")
    ap.add_argument("--sta")
    ap.add_argument("--rbf")
    ap.add_argument("--seed", default=os.environ.get("SEED", ""))
    ap.add_argument("--out", default="reports")
    a = ap.parse_args()
    fit = a.fit or "output_files/%s.fit.rpt" % a.project
    sta = a.sta or "output_files/%s.sta.rpt" % a.project
    rbf = a.rbf or "output_files/%s.rbf" % a.project
    for p in (fit, sta, rbf):
        if not os.path.exists(p):
            sys.exit("fit_report: %s not found - run after a successful compile" % p)
    F, S = read(fit), read(sta)
    os.makedirs(a.out, exist_ok=True)

    # ---- the whole per-entity table, as Quartus printed it -------------------
    ent = section(F, "Fitter Resource Utilization by Entity")
    with open(os.path.join(a.out, "resources-by-entity.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("Fitter Resource Utilization by Entity - %s\n" % os.path.basename(fit))
        f.write("(numbers in parentheses are the entity's own, outside its children)\n\n")
        f.write("\n".join(ent) + "\n")

    # ---- timing tables, as printed -------------------------------------------
    checks = ["Setup Summary", "Hold Summary", "Recovery Summary", "Removal Summary",
              "Minimum Pulse Width Summary"]
    with open(os.path.join(a.out, "timing.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("TimeQuest timing summaries - %s (slow 1100mV 100C model unless stated)\n\n"
                % os.path.basename(sta))
        for c in checks:
            f.write("\n".join(section(S, c)) + "\n\n")

    # ---- summary.md ------------------------------------------------------------
    fsum = section(F, "Fitter Summary")
    fitkv = {}
    for l in fsum:
        m = re.match(r"^; ([^;]+?)\s*; (.*?)\s*;$", l)
        if m:
            fitkv[m.group(1)] = m.group(2)
    worst = {}
    for c in checks:
        for cells in rows(section(S, c)):
            if len(cells) >= 2 and re.match(r"^-?\d", cells[1]):
                worst.setdefault(cells[0], {})[c.split()[0]] = cells[1]
    # the SGI machine's blocks: children of the core instance, two levels down
    blocks = []
    in_core, core_indent = False, None
    for l in ent:
        m = re.match(r"^;(\s*)\|([^;]+?)\s*;\s*([\d.]+) \(([\d.]+)\)\s*;", l)
        if not m:
            continue
        indent, node = len(m.group(1)), m.group(2)
        if node.startswith("sgi_indy:"):
            in_core, core_indent = True, indent
            blocks.append((node, m.group(3), l))
            continue
        if in_core:
            if indent <= core_indent:
                in_core = False
            elif indent == core_indent + 3:
                blocks.append((node, m.group(3), l))
    hdr = [c.strip() for c in ent[3].strip().strip(";").split(";")] if len(ent) > 3 else []

    def col(line, name):
        cells = [c.strip() for c in line.strip().strip(";").split(";")]
        if name in hdr:
            v = cells[hdr.index(name)]
            return v.split(" (")[0]
        return ""

    st = os.stat(rbf)
    L = ["# Build report", "",
         "Generated by `tools/fit_report.py` from the Quartus reports of the bitstream below.",
         "`resources-by-entity.txt` and `timing.txt` beside this file are Quartus's own",
         "tables; the full reports stay in `output_files/`.", "",
         "| | |", "|---|---|",
         "| bitstream | `%s`, %d bytes, md5 `%s` |" % (os.path.basename(rbf), st.st_size, md5(rbf)),
         "| built | %s |" % datetime.datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M"),
         "| fitter seed | %s |" % (a.seed or "(the project's, sgiindy.qsf)"),
         "| Quartus | %s |" % fitkv.get("Quartus Prime Version", "?"),
         "| device | %s (%s) |" % (fitkv.get("Device", "?"), fitkv.get("Family", "?")),
         "", "## Device use", "", "| resource | used |", "|---|---|"]
    for k in ("Logic utilization (in ALMs)", "Total registers", "Total block memory bits",
              "Total RAM Blocks", "Total DSP Blocks", "Total PLLs", "Total pins"):
        if k in fitkv:
            L.append("| %s | %s |" % (k, fitkv[k]))
    L += ["", "## Timing", "",
          "Worst slack per clock, in ns, over all corners Quartus analysed. Every number",
          "must be positive; a negative one is a failed timing check.", "",
          "| clock | setup | hold | recovery | removal | min pulse width |",
          "|---|---:|---:|---:|---:|---:|"]
    neg = any(v.startswith("-") for w in worst.values() for v in w.values())
    # One row per clock that is timed for setup; the minimum-pulse-width check
    # also lists PLL internals (VCO phases), which stay in timing.txt.
    for clk in sorted((c for c in worst if "Setup" in worst[c]),
                      key=lambda c: float(worst[c]["Setup"])):
        w = worst[clk]
        L.append("| %s | %s | %s | %s | %s | %s |" % (
            clock_label(clk), w.get("Setup", ""), w.get("Hold", ""), w.get("Recovery", ""),
            w.get("Removal", ""), w.get("Minimum", "")))
    L += ["", "**Timing %s.**" % ("FAILED - see timing.txt" if neg else "met in every check"), ""]
    if blocks:
        L += ["## Where the logic went", "",
              "The SGI machine (`sgi_indy`) and its blocks, from `resources-by-entity.txt`.",
              "The rest of the device is MiSTer's framework (`sys/`): the scaler, HDMI, the",
              "HPS bridges.", "",
              "| block | instance | ALMs | registers | M10K | DSP |", "|---|---|---:|---:|---:|---:|"]
        for i, (node, alms, line) in enumerate(blocks):
            ent_name, _, inst = node.rstrip("|").partition(":")
            row = "| %s | `%s` | %s | %s | %s | %s |" % (
                "**the whole machine**" if i == 0 else ent_name, inst, alms,
                col(line, "Dedicated Logic Registers"), col(line, "M10Ks"), col(line, "DSP Blocks"))
            L.append(row)
        L.append("")
    with open(os.path.join(a.out, "summary.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")
    print("fit_report: wrote %s/summary.md, resources-by-entity.txt, timing.txt%s"
          % (a.out, " - TIMING FAILED" if neg else ""))
    return 1 if neg else 0


if __name__ == "__main__":
    sys.exit(main())
