#!/usr/bin/env bash
#
# build.sh - assemble tests/tlborder/tlborder.S into an ELF the harness can
# boot with --elf. See the comment at the top of the .S for what it proves.
#
#   tests/tlborder/build.sh
#   ./verilator/obj_wm/Vsim_top --elf tests/out/tlborder/tlborder.elf \
#        --no-gfx --exc --exc-count 8 --epc --epc-count 8 --max-cycles 300000
#
# CROSS defaults to the rootless toolchain docs/local-toolchain describes.
#
# STATUS 2026-09-01: WORKS, and it reproduces the defect at cycle 2043 instead
# of 207,884,339. Two things were wrong and neither was the PHDRS the previous
# note suspected:
#
#  1. tlborder.ld was never PASSED to ld - the link used `-Ttext 0x88001000`
#     and the default script, which is what emitted the second PT_LOAD:
#       ELF load failed: segment 2 at vaddr 00400000 -> phys 00400000
#       (232 bytes) is outside RAM [08000000, 0c000000)
#     Those 232 bytes are the ELF headers plus .MIPS.abiflags and .reginfo.
#     With `-T tlborder.ld` there is exactly one PT_LOAD, at 0x88001000.
#     (`-N` also works and is not needed.)
#  2. tlborder.ld said OUTPUT_FORMAT("elf32-bigmips"), which binutils 2.42
#     rejects outright - "target elf32-bigmips not found". The name this
#     toolchain uses is `elf32-tradbigmips`. That error is almost certainly
#     why the script was abandoned for -Ttext in the first place.
#
# A third bug was in the test itself and had nothing to do with linking: the
# snippet was copied to PA_CODE through KSEG0, so it sat in the D-cache while
# the I-cache fetched the stale zeroes underneath it. See tlborder.S.
#
# The toolchain needs its env.sh sourced for LD_LIBRARY_PATH before ld runs.
# cpu-tests cannot host this case at all (that suite runs unmapped from KSEG0,
# so its fetches never miss the TLB), which is why it lives here.
# `set -u` off around the toolchain env: its env.sh appends to
# LD_LIBRARY_PATH without a default and dies under nounset.
set -o pipefail
# Respect an inherited ROOT: this file is checked out CRLF, so it is often
# run from a de-CRLF'd copy elsewhere, and $BASH_SOURCE then points at the
# copy. gen_r4300_verilog.sh has the same trap.
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
OUT="${OUT:-$ROOT/tests/out/tlborder}"
CROSS="${CROSS:-mips-linux-gnu-}"

if ! command -v "${CROSS}gcc" >/dev/null; then
    export PATH="$HOME/.local/opt/mips-linux-gnu/usr/bin:$PATH"
    [ -r "$HOME/.local/opt/mips-linux-gnu/env.sh" ] && . "$HOME/.local/opt/mips-linux-gnu/env.sh"
fi
command -v "${CROSS}gcc" >/dev/null || {
    echo "error: no ${CROSS}as - see cpu-tests/docs/toolchain.md" >&2; exit 2; }

mkdir -p "$OUT"

# Everything is checked out CRLF on the Windows box this project lives on, and
# the assembler chokes on the stray carriage returns. Work on a clean copy.
sed 's/\r$//' "$ROOT/tests/tlborder/tlborder.S"  > "$OUT/tlborder.S"
sed 's/\r$//' "$ROOT/tests/tlborder/tlborder.ld" > "$OUT/tlborder.ld"

# 0x88001000 is KSEG0 -> physical 0x08001000, inside RAM and clear of the
# 0x08040000 page the test maps. The loader rejects anything below the RAM
# base, which is why the exception handler is installed at run time instead.
# gcc, not as: the source uses cpp #defines for the CP0 register numbers and
# the page-table arithmetic, and only gcc runs the preprocessor on a .S.
# -mno-abicalls/-fno-pic: the snippet does an absolute `jal` to a fixed
# address, which PIC forbids ("unsupported constant in relocation").
"${CROSS}gcc" -EB -mips3 -mno-abicalls -fno-pic -c -nostdlib -o "$OUT/tlborder.o" "$OUT/tlborder.S" || exit 2
# -T, not -Ttext: the whole point of tlborder.ld is to keep the ELF headers
# and .MIPS.abiflags/.reginfo out of a loadable segment. Linking with the
# default script put them in a second PT_LOAD at 0x00400000 and the harness
# rejected the file.
"${CROSS}ld" -EB -T "$OUT/tlborder.ld" -e _start \
    -o "$OUT/tlborder.elf" "$OUT/tlborder.o" || exit 2

echo "built $OUT/tlborder.elf"
"${CROSS}objdump" -d "$OUT/tlborder.elf" | sed -n '/<snippet>:/,/<snippet_end>/p'
