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
# STATUS 2026-09-01: THIS DOES NOT RUN YET, and it is one linker-script detail
# away. The .S assembles and links, and the snippet disassembles correctly -
# `jal` encodes target field 0x140000, which resolves to 0x00500000 once the
# code executes in region 0. What fails is the load:
#
#   ELF load failed: segment 2 at vaddr 00400000 -> phys 00400000 (232 bytes)
#   is outside RAM [08000000, 0c000000)
#
# ld emits a SECOND PT_LOAD covering the ELF headers at its default text
# address, and the harness's loader rejects any segment outside RAM. Adding
# PHDRS did not suppress it. The likely fixes, untried: `-N` (omagic), or
# giving the headers to the text segment explicitly with
# `. = 0x88001000 + SIZEOF_HEADERS;` and `:text FILEHDR PHDRS`. Note the
# toolchain needs its env.sh sourced for LD_LIBRARY_PATH before ld will run.
#
# It is worth finishing: it turns a 25-minute IRIX boot into a one-second
# check, and cpu-tests cannot host this case at all (that suite runs unmapped
# from KSEG0, so its fetches never miss the TLB).
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
sed 's/\r$//' "$ROOT/tests/tlborder/tlborder.S" > "$OUT/tlborder.S"

# 0x88001000 is KSEG0 -> physical 0x08001000, inside RAM and clear of the
# 0x08040000 page the test maps. The loader rejects anything below the RAM
# base, which is why the exception handler is installed at run time instead.
# gcc, not as: the source uses cpp #defines for the CP0 register numbers and
# the page-table arithmetic, and only gcc runs the preprocessor on a .S.
# -mno-abicalls/-fno-pic: the snippet does an absolute `jal` to a fixed
# address, which PIC forbids ("unsupported constant in relocation").
"${CROSS}gcc" -EB -mips3 -mno-abicalls -fno-pic -c -nostdlib -o "$OUT/tlborder.o" "$OUT/tlborder.S" || exit 2
"${CROSS}ld" -EB -Ttext 0x88001000 -e _start \
    -o "$OUT/tlborder.elf" "$OUT/tlborder.o" || exit 2

echo "built $OUT/tlborder.elf"
"${CROSS}objdump" -d "$OUT/tlborder.elf" | sed -n '/<snippet>:/,/<snippet_end>/p'
