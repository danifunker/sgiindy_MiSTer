#!/usr/bin/env bash
#
# build.sh - turn the IRIS CPU test suite into a boot.rom this core can run.
#
#   tests/hw-cputest/build.sh [OUT]        default OUT: tests/out/hw-cputest/boot.rom
#
# Needs a MIPS cross toolchain and a checkout of the suite. Both follow the
# same conventions as tests/run-cputest.sh:
#   CPUTESTS  where the suite is           (default ~/repos/iris/cpu-tests)
#   CROSS     cross tool prefix            (default mips-linux-gnu-)
#
# WHAT COMES OUT. A 512 KB image, which is what ddr3_mux gives the PROM region:
#
#   0x00000  promstub.S    - jump to 0x1000, and the four BEV=1 vectors
#   0x01000  the suite     - objcopy -O binary of cputest.elf
#   ...      zeroes        - harness/start.S copies [_ftext,_end) out of here,
#                            which runs past the image; .bss wants zeroes and
#                            this is where they come from
#
# THE SUITE IS PATCHED ON THE WAY THROUGH, into a scratch copy - the checkout is
# never touched. console-memlog.patch adds a third output sink that writes into
# main memory, because this machine's other two cannot be read: the SCC
# transmits nothing that reaches the HPS, and GIO slot 0 has no test device on
# it. See the patch for why the buffer is where it is.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/tests/hw-cputest"
CPUTESTS="${CPUTESTS:-$HOME/repos/iris/cpu-tests}"
CROSS="${CROSS:-mips-linux-gnu-}"
OUT="${1:-$ROOT/tests/out/hw-cputest/boot.rom}"
WORK="${WORK:-$ROOT/tests/out/hw-cputest/work}"

PROM_BYTES=$((512 * 1024))
IMAGE_OFF=$((0x1000))

command -v "${CROSS}gcc" >/dev/null || {
    echo "error: no ${CROSS}gcc - set CROSS, or see cpu-tests/docs/toolchain.md" >&2
    exit 2; }
[ -d "$CPUTESTS" ] || { echo "error: no suite at $CPUTESTS - set CPUTESTS" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK" "$(dirname "$OUT")"

echo "== copying the suite to $WORK/cpu-tests =="
# A copy, and with CRLF stripped: a Windows checkout makes GNU make append a
# carriage return to every recipe line, which the shell then tries to run.
cp -r "$CPUTESTS" "$WORK/cpu-tests" || exit 2
find "$WORK/cpu-tests" -type f \
     \( -name '*.mk' -o -name 'Makefile' -o -name '*.c' -o -name '*.h' \
        -o -name '*.S' -o -name '*.ld' \) -exec sed -i 's/\r$//' {} + 2>/dev/null

echo "== adding the memory log sink =="
( cd "$WORK/cpu-tests" && patch -p1 --forward < "$HERE/console-memlog.patch" ) || {
    echo "error: the console patch did not apply - the suite has moved on" >&2
    exit 2; }

echo "== adding the throughput benchmarks =="
# The docs/34 sluggishness instruments: cached/uncached loop IPC, load/store
# cost, the L1-miss DDR3 round trip, and Count vs the DS1386's wall clock.
# A patch for the same reason console-memlog is one: the suite checkout is an
# oracle shared with IRIS and stays unmodified.
( cd "$WORK/cpu-tests" && patch -p1 --forward < "$HERE/bench.patch" ) || {
    echo "error: bench.patch did not apply - the suite has moved on" >&2
    exit 2; }

echo "== building the suite =="
make -C "$WORK/cpu-tests" CROSS="$CROSS" -j8 >"$WORK/suite-build.log" 2>&1 || {
    tail -20 "$WORK/suite-build.log"; exit 2; }

ELF="$WORK/cpu-tests/build/cputest.elf"
"${CROSS}objcopy" -O binary "$ELF" "$WORK/cputest.bin" || exit 2

echo "== building the PROM stub =="
"${CROSS}gcc" -march=mips3 -mabi=n32 -EB -mno-abicalls -fno-pic -G0 \
      -nostdlib -c -o "$WORK/promstub.o" "$HERE/promstub.S" || exit 2
"${CROSS}ld" -EB -T "$HERE/promstub.ld" -nostdlib \
      -o "$WORK/promstub.elf" "$WORK/promstub.o" || exit 2
"${CROSS}objcopy" -O binary "$WORK/promstub.elf" "$WORK/promstub.bin" || exit 2

IMG=$(stat -c %s "$WORK/cputest.bin")
STUB=$(stat -c %s "$WORK/promstub.bin")

# start.S copies to _end, not to the end of the image, so the ROM has to hold
# every byte of that range. Check it rather than producing a rom that reads off
# the end of the region and copies whatever the next one holds into .bss.
SPAN=$(( $("${CROSS}nm" "$ELF" | awk '/ _end$/{print "0x"$1}') \
       - $("${CROSS}nm" "$ELF" | awk '/ _ftext$/{print "0x"$1}') ))
NEED=$(( IMAGE_OFF + SPAN ))
if [ "$NEED" -gt "$PROM_BYTES" ]; then
    echo "error: the suite spans $SPAN bytes to _end; $NEED > $PROM_BYTES in the PROM region" >&2
    exit 2
fi

python3 - "$WORK/promstub.bin" "$WORK/cputest.bin" "$OUT" "$IMAGE_OFF" "$PROM_BYTES" <<'PY'
import sys
stub, img, out, off, total = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
s = open(stub, "rb").read()
i = open(img, "rb").read()
assert len(s) <= off, "stub is %d bytes, does not fit below 0x%x" % (len(s), off)
rom = bytearray(total)
rom[0:len(s)] = s
rom[off:off + len(i)] = i
assert off + len(i) <= total
open(out, "wb").write(bytes(rom))
print("  stub %d B, suite %d B at 0x%x, padded to %d B" % (len(s), len(i), off, total))
PY
[ $? -eq 0 ] || exit 2

echo "== $OUT =="
ls -l "$OUT"
echo "  suite spans $SPAN bytes to _end, $((PROM_BYTES - NEED)) bytes of PROM left over"
echo "  md5 $(md5sum "$OUT" | awk '{print $1}')"
