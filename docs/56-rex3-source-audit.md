# 56. REX3 against its sources, and the plan to make it right

Written 2026-09-17 (evening), after docs/55 and the build 43b board runs.
GL programs on the board drew nothing recognisable, and Dani's reading was
the right one - "the implementation is just ENTIRELY WRONG. It's drawing
things it shouldn't be" - so before any more code, every source there is
was mined for how Newport really behaves, and compared with the core.

**Status of this document: the audit is in progress.** Section 3 holds what
has been verified so far; the per-area findings (section 4) and the
implementation plan (section 5) are added as each part is checked.

## 1. The sources, most authoritative first

| # | Source | Where | Used for |
|---|---|---|---|
| 1 | SGI's own chip specifications: REX3 (rev 1.0, Aug 1993, ~146 pp), RB2 (RAM Buffer), RO1 (ReOrganizer), XMAP9, VC2, the MUX gate array, GIO64 bus 1.1, MC, Virtual DMA; SGI's `IP22.c` | `../SGI_Indy_Core_DE1/SGI Indy Hardware Docs/` | ground truth for behaviour and bit layouts |
| 2 | The guest's own binaries: `/unix` (the Newport driver, unstripped ECOFF), `/usr/gfx/arch/IP22NG1/libgl.so` (IRIS GL) and `libGLcore.so` (OpenGL, both unstripped), `Xsgi`, the IP24 PROM | off the IRIX image with `efsread.py` | what IRIX actually depends on |
| 3 | IRIS: `rex3.rs`, `rex3_generic.rs`, `compositor.rs`, `xmap9.rs`, `vc2.rs`, `cmap.rs`, `bt445.rs`, 5,529 lines of `rex3_tests.rs`, the 462-shape corpus | `../iris/src/` | the oracle the core was transcribed from |
| 4 | MAME `newport.cpp` (4,500 lines, with its own RB2 model) | `../mame/src/devices/bus/gio64/` | a second, independent oracle |

The PDFs come out as text with Git Bash's xpdf `pdftotext` 4.00 (`-layout`
for prose, `-table` for the register and format tables, which `-layout`
interleaves). The `IRIS/` tarballs in the docs folder are 1991 demos and
diagnostics for older machines and were not used.

IRIS and MAME are oracles, not ground truth: the core's equivalence bench
(`verilator/tb_rex3draw.cpp`) compares np_rex3 with a transcription of IRIS,
and a transcription slip shared by the two passes it (3.2). Where an
emulator and the spec disagree, the spec wins unless the guest's binaries
show IRIX relies on the emulator's behaviour.

## 2. What the board shows, build 43b

* The PROM console, the X desktop and X's lines draw correctly: `xclock`,
  and `xlock -mode qix -nolock` full screen in the right colours
  (`tests/out/hw/saver-evidence/b43-xlock-qix.png`).
* GL programs draw nothing into the frame buffer. ElectroPaint's grabs
  alternate between buffer 1 (the login screen, stale in the upper planes)
  and buffer 0 (`b43-ep-buffer1.png`, `b43-ep-buffer0.png`): swapbuffers
  works, and neither buffer receives a pixel of the demo. buttonfly shows
  both buffers in one frame (`b43-buttonfly-torn-swap.png`).
* The board regression passes (`tests/out/hw/regression-b43.txt`): cpu-tests
  2415/0, DISKCHECK PASS, X up at +79 s as with build 42.

## 3. Verified findings so far

**3.1 GL's register pairs lose their second half (breaks GL).** GL writes
REX3 registers two at a time with 64-bit `sdc1` stores: IRIS GL's
`__line_shade` does `sdc1 $f2, 0x138($t0)`, XSTARTF and YSTARTF in one
transfer, and the same for XENDF+YENDF, COLORGREEN+COLORBLUE and
SLOPEGREEN+SLOPEBLUE. There are 172 such stores at offsets >= 0x100 in
libGLcore.so and 43 in libgl.so, and none in Xsgi - which is why X draws and
GL does not. `newport.sv` keeps the first register of a doubleword and
drops the second, so every Y, blue and alpha GL sends is lost, and a pair
written to the GO alias loses its GO. The spec's GIO interface puts a whole
transfer in one GFIFO entry (`GF_DATA(63:0)`, `GF_D32` flags 32-bit
transfers, one `GF_GO` decoded from the address; §5.1, §5.3.1); IRIS's
`write64` (high word without GO, then the low word with the address's GO)
and MAME's `rex3_w` (bits 63:32 to the even register, 31:0 to the odd, then
the command if GO) agree. The kernel is not involved: its context switch,
`newportPcxSwap`, saves and restores every register with 32-bit `lw`/`sw`.

**3.2 12-bit reads from the second buffer read the first.** Spec §3.7:
"Double-buffered reads are explicitly specified by DRAWMODE1 bit DBLSRC.
Buffer0 ... is the lower significant pixel". IRIS (`rex3_generic.rs:603`,
shift 12) and MAME (`s_store_shift`, 12) read bits 23:12 at 12 bpp with
DBLSRC; np_rex3's `plane_of` ignores DBLSRC at 12 bpp - and so does
`tb_rex3draw.cpp`'s `plane_shift_mask`, which is why the bench never saw it.
Reached by blends, logic ops that read the destination, screen-to-screen
copies and host read-back in a 12-bit back buffer.

**3.3 TOPSCAN is applied to drawing instead of display.** np_rex3 subtracts
TOPSCAN+1 from the row of every drawn pixel and the display ignores it; the
spec's VRAM controller starts each frame's scan at TOPSCAN (`VC_SET_TSC
resets the line counter to the value in TOPSCAN(9:0)`, §5.4.0.1), and
IRIS's compositor scrolls the display by TOPSCAN+1 while drawing at the raw
row. Identical for new drawing; different the moment TOPSCAN changes.

**3.4 XMAP9 mode-table writes take effect mid-frame.** The XMAP9 spec:
"Writes to the Mode Register are fifoed so that the register is only
updated during blanking." np_xmap9 applies them at once - the tear in
buttonfly's grab.

**3.5 RGB windows bypass the colour maps.** XMAP9's pixel mode selects CI
or one of three RGB Maps in CMAP (gamma); newport.sv (and IRIS) send
packed RGB straight to the DAC. Colour fidelity only.

**3.6 The active video line is ~1318 pixels, and the scaler squeezes it
into 1280 - the "damaged glyph" bug.** Read straight out of DDR3
(`tools/misterdeploy/fbgrab32.py`, `tests/out/hw/textprobe.sh`), 1,673
Console text cells were all exact copies of their glyphs; the scaler's
screen skips one frame buffer column every ~33.7 pixels (fb_x = screen_x x
1.030), so strokes on a dropped column vanish ("echo" -> "ecro").
`b43-fb-vs-screen-columns.png`. It is the display timing, not REX3.

**3.7 Speed.** The spec's REX3 (§1.6): shaded spans 50 Mpix/s, flat spans
100, fast clear 400, screen-to-screen 40, lines 20. np_rex3 issues one
write a clock only for a plain painted block with a byte-aligned write mask
(DR_FILL); everything else is read-modify-write, a DDR3 round trip per
pixel, about 25 clocks - ~2 Mpix/s. GL's 12-bit windows use masks 0xFFF and
0xFFF000, which are not byte-aligned, so their clears and spans all take
the slow path.

## 4. Findings by area

(in progress)

## 5. Implementation plan

(after section 4)
