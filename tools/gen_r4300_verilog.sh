#!/usr/bin/env bash
#
# gen_r4300_verilog.sh - lower the vendored R4300i VHDL to Verilog for Verilator.
#
# Quartus compiles the VHDL directly, so this is a simulation-only step and its
# output is generated, never committed (see .gitignore). GHDL 6's built-in
# synthesis backend does the whole job; no Yosys, no ghdl-yosys-plugin, and no
# hand-edited 5 MB netlist to keep in sync with upstream.
#
#   brew install ghdl
#   tools/gen_r4300_verilog.sh
#
# Writes rtl/cpu/generated/r4300_wrap.v.
#
# -frelaxed is needed because the vendored SyncFifo/dpram sources use plain
# (non-protected) shared variables, which VHDL-2008 downgrades to an error.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/rtl/cpu/generated"
WORKDIR="$OUT/.ghdl"
SRC="$WORKDIR/src"
CPU="$SRC"
PRIM="$SRC"

command -v ghdl >/dev/null || { echo "error: ghdl not found (brew install ghdl)" >&2; exit 1; }

# AND CHECK THAT IT ACTUALLY RUNS, not just that it is on PATH. The Debian
# ghdl-llvm package links its backend against a libLLVM soname that the distro
# does not ship, so `ghdl` exists, `ghdl --version` dies with
#   ghdl1-llvm: error while loading shared libraries: libLLVM-18.so.18.1
# and the fix is a one-line shim:
#   mkdir -p /tmp/llvmshim
#   ln -sf /usr/lib/llvm-18/lib/libLLVM.so.18.1 /tmp/llvmshim/libLLVM-18.so.18.1
#   export LD_LIBRARY_PATH=/tmp/llvmshim
# Without this check the failure is five minutes late and looks like nothing:
# the generated file keeps its old timestamp, Verilator reports "Nothing to be
# done", and the model you then measure is the one from BEFORE your change.
# That has now cost this project a full verification cycle - see docs/25.
ghdl --version >/dev/null 2>&1 || {
    echo "error: ghdl is on PATH but will not run. Try:" >&2
    echo "  mkdir -p /tmp/llvmshim && ln -sf /usr/lib/llvm-18/lib/libLLVM.so.18.1 \\" >&2
    echo "      /tmp/llvmshim/libLLVM-18.so.18.1 && export LD_LIBRARY_PATH=/tmp/llvmshim" >&2
    echo "  ghdl --version    # says what is actually wrong" >&2
    exit 1; }

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/work" "$WORKDIR/mem" "$SRC" "$OUT"

# Work on a copy: rtl/cpu/r4300/ stays byte-identical to upstream so it can be
# diffed against a newer N64 core, and Quartus compiles it unpatched.
cp "$ROOT/rtl/cpu/r4300"/*.vhd "$ROOT/rtl/cpu/prim"/*.vhd "$ROOT/rtl/cpu/r4300_wrap.vhd" "$SRC/"

# GHDL 6.0.0 workaround. Its synthesis backend raises
#   TYPES.INTERNAL_ERROR : netlists-utils.adb:166
# on a numeric_std comparison whose operands differ in width, e.g.
#   signal v : unsigned(63 downto 0);  ...  if (v <= x"FFFFFFFFFF")
# which is legal VHDL (numeric_std zero-extends the shorter side) and which
# cpu.vhd uses exactly once, in the 64-bit supervisor-mode region decode.
# Widening the literal to 64 bits is semantically identical and lets the
# whole CPU synthesise. Analysis and Quartus are both unaffected, so this
# lives here rather than in the vendored source.
perl -pi -e 's/x"FFFFFFFFFF"/x"000000FFFFFFFFFF"/' "$SRC/cpu.vhd"
grep -q 'x"000000FFFFFFFFFF"' "$SRC/cpu.vhd" || {
    echo "error: the GHDL width-mismatch workaround no longer applies -" >&2
    echo "       check whether upstream cpu.vhd still has the short literal." >&2
    exit 1; }

GHDL_FLAGS=(-a --std=08 -frelaxed)

# The CPU instantiates RamMLAB, dpram and SyncFifoFallThroughMLAB out of a
# library called `mem`, and dpram/dpram_dif out of `work` as well - so the
# primitive sources are analysed into both.
ghdl "${GHDL_FLAGS[@]}" --work=mem --workdir="$WORKDIR/mem" \
    "$PRIM/RamMLAB.vhd" \
    "$PRIM/dpram.vhd" \
    "$CPU/SyncFifoFallThroughMLAB.vhd"

ghdl "${GHDL_FLAGS[@]}" --workdir="$WORKDIR/work" -P"$WORKDIR/mem" \
    "$PRIM/dpram.vhd" \
    "$PRIM/RamMLAB.vhd" \
    "$PRIM/cpu_mul.vhd" \
    "$CPU/functions.vhd" \
    "$CPU/export.vhd" \
    "$CPU/divider.vhd" \
    "$CPU/cpu_instrcache.vhd" \
    "$CPU/cpu_datacache.vhd" \
    "$CPU/cpu_TLB_instr.vhd" \
    "$CPU/cpu_TLB_data.vhd" \
    "$CPU/cpu_cop0.vhd" \
    "$CPU/cpu_FPU_sqrt.vhd" \
    "$CPU/cpu_FPU.vhd" \
    "$CPU/cpu.vhd" \
    "$SRC/r4300_wrap.vhd"

ghdl synth --std=08 -frelaxed --workdir="$WORKDIR/work" -P"$WORKDIR/mem" \
    --out=verilog r4300_wrap > "$OUT/r4300_wrap.v.tmp"

# GHDL 4.1.0 (the Ubuntu 24.04 package) lowers numeric_std's shift_right on a
# SIGNED operand to Verilog's `$signed(x) >> n`, which is a LOGICAL shift -
# only `>>>` fills with the sign. The one place cpu.vhd does this is the
# shifter's calcResult_shiftR (a 65-bit signed carrying the sign in bit 64),
# so under Verilator DSRA/DSRA32/DSRAV returned a single sign bit at
# position 64-n instead of a fill: `dsra 0x8000000000000000, 4` read
# 0x1800000000000000, and alu/dsll_dsrl_dsra + alu/dshift32_variants failed
# in the suite while Quartus, which compiles the VHDL, was right all along.
# Found 2026-09-02 (docs/39). Rewriting the operator is exactly the lowering
# a later GHDL emits; the count is checked so a GHDL that gets it right, or
# a cpu.vhd that grows a second one, does not go unnoticed.
n=$(grep -c '\$signed([a-z0-9_]*) >> ' "$OUT/r4300_wrap.v.tmp" || true)
perl -pi -e 's/\$signed\((\w+)\) >> /\$signed($1) >>> /' "$OUT/r4300_wrap.v.tmp"
echo "signed shift_right lowered as logical >>: $n rewritten to >>>"

mv "$OUT/r4300_wrap.v.tmp" "$OUT/r4300_wrap.v"
rm -rf "$WORKDIR"

echo "generated $OUT/r4300_wrap.v ($(wc -l < "$OUT/r4300_wrap.v") lines)"
