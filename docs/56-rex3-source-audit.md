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

Each area was audited against the spec, IRIS, MAME and the guest's
binaries. Items marked **(re-checked)** were verified a second time against
the sources before being written here; the rest carry the audit's own
evidence (spec page, file:line, guest address).

### 4.1 The register file, control bits, coordinates and clipping

Table 7's register types, recovered from the PDF's Symbol-font codes (the
text extractions drop them): **stall until the pipeline is idle** -
DRAWMODE1, COLORBACK, COLORVRAM, ALPHAREF, STALL0, XYMOVE, WRMASK, SMASK1-4,
CLIPMODE, STALL1; **display-bus FIFO** - DCBMODE, DCBDATA0, DCBDATA1;
**immediate** - CONFIG, STATUS, USER_STATUS, DCBRESET. The core's
hold-every-write-while-busy model is a superset of the stall rule and keeps
program order, so it is correct if slow.

**GL-format coordinates keep four float exponent bits - BREAKS GL
(re-checked).** XSTARTF/YSTARTF/XENDF/YENDF (0x138-0x144) and XENDF1 (0x14C)
are "12.4(7) GL version of XSTART, (zeros 4 msbs)" (p21). GL stores the raw
bits of the float `4096 + x`, whose mantissa is exactly x in 12.11 fixed
point and whose exponent (139) puts 0xB in bits 26:23. IRIS
(`rex3.rs:695`, "hardware masks off bits 31:23") and MAME (`newport.cpp:4043`)
mask with 0x007FFF80; np_rex3 masks with M_COORD = 0x07FFFF80 (line 225,
1822-1829), so the coordinate becomes x - 20480 and every pixel is culled.
Every GL line and point, including the ones GL writes with 32-bit stores.
0x14C is also decoded as an integer "XENDI" rather than XENDF1.

**SETUP (0x0030) does nothing - BREAKS GL (re-checked).** "Performs
line/span setup without iteration (ignore DOSETUP)" (p21), and "The host
must, in advance, issue a write to address=SETUP in order to have REX
calculate quadrant" (§3.5, repeatedly). IRIS runs `setup()` on the write
(`rex3.rs:3145`); np_rex3 stores the value (line 1814). GL's
`__glNptRenderBitmap` writes XYSTARTI, XYENDI, DRAWMODE0 = block without
DOSETUP, then SETUP (`sw $zero, 0x30`), then ZPATTERN|GO per row - so GL
text, CopyPixels and GL's point-at-a-time lines use a stale octant.

**Line stipple state.** LSPATTERN and LSMODE's repeat counter are the live
iterator on the part ("recirculating iterators", §3.4); LSSAVE/LSRESTORE
copy them to and from the save fields. np_rex3 keeps LSPATTERN fixed, indexes
it with a hidden counter reset at every DOSETUP and row, and ignores
LSSAVE/LSRESTORE, so dashes restart at every polyline vertex and wide
stippled lines lose their phase. IRIS simplifies the same way, so it cannot
be the oracle here; GL's wide-line code does LSSAVE once and LSRESTORE per
pass.

**No vertical sector clip.** Writes outside the 1344 x 1024 drawing area are
culled (§3.3); np_rex3 wraps y modulo 1024, so anything drawn above or below
the screen reappears at the opposite edge.

**XYMOVE in the screen-mask tests.** np_rex3 tests SMASK0 without XYMOVE and
SMASK1-4 with it; IRIS and MAME add it to all, the errata (p147) to none.
Needs a board test before choosing.

**Minor:** STATUS VERSION reads 1 (IRIS and MAME answer 3); reset values of
DRAWMODE1 (0x3002F001) and CONFIG (0x230C4) are zero here; read-back widths
of DRAWMODE0, the colour registers, DCBMODE and CONFIG exceed the spec's;
COLORX is stored but never reaches the DDA; PLANES 0/3/7 draw; YFLIP and
SWAPENDIAN are missing (no corpus shape uses either); the colour-index
clamp and the COMPARE field in CI mode differ from the spec in ways no
corpus shape reaches.

The kernel's context switch saves exactly the registers with a read format
and converts all four slopes back to sign-magnitude; every one round-trips
in the core. `tb_rex3draw.cpp` never writes the GL-format coordinates,
SETUP, LSSAVE/LSRESTORE or a non-zero XYMOVE - which is where these hid.

## 5. Implementation plan

(after section 4)
