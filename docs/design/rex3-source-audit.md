# REX3 against its sources, and the plan to make it right

Written 2026-09-17 (evening), after docs/design/rex3-rendering.md and the build 43b board runs.
GL programs on the board drew nothing recognisable, and Dani's reading was
the right one - "the implementation is just ENTIRELY WRONG. It's drawing
things it shouldn't be" - so before any more code, every source there is
was mined for how Newport really behaves, and compared with the core.

**Status: complete, 2026-09-17.** Section 3 holds what
was verified first, section 4 the six audited areas, and section 5 the
implementation plan built from them.

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

**3.4 XMAP9 mode-table writes take effect at once** where the chip holds
them to blanking ("Writes to the Mode Register are fifoed so that the
register is only updated during blanking"). CORRECTED by the display audit
(4.5): that is not what tore buttonfly's frame. The chip's blanking window
includes every line's horizontal blank, and the kernel writes the new mode
word from the retrace interrupt; a swap stays whole on real hardware only
because that interrupt runs inside the 41-line vertical blank. The tear
says the core's write landed after line 40 - to be measured, not
"fixed" by deferring it.

**3.5 RGB windows bypass the colour maps.** XMAP9's pixel mode selects CI
or one of three RGB Maps in CMAP (gamma); newport.sv (and IRIS) send
packed RGB straight to the DAC. Colour fidelity only.

**3.6 The active video line is ~1318 pixels, and the scaler squeezes it
into 1280 - the "damaged glyph" bug.** Read straight out of DDR3
(`tools/misterdeploy/fbgrab32.py`, `tests/out/hw/textprobe.sh`), 1,673
Console text cells were all exact copies of their glyphs; the scaler's
screen skips one frame buffer column every ~33.7 pixels (fb_x = screen_x x
1.030), so strokes on a dropped column vanish ("echo" -> "ecro").
`b43-fb-vs-screen-columns.png`. It is the display timing, not REX3. The
display audit (4.5) found the cause (re-checked): `np_vc2.sv:375` drives
`de` from DSPLY_EN_RO_N, RO1's pixel-pipeline enable, 1318 pixels a line on
this timing table; the visible window is VIS_LN_VC_N, "the active portion
of the frame ... essentially the inverse of composite blanking" (VC2 §5.7),
1296 pixels - which IRIS and MAME both use.

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
pass. (More in 4.2.)

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

### 4.2 The walker: address modes, lines, patterns

**0x14C is XENDF1, a GL float, and IRIS GL fills polygons through it -
BREAKS GL.** Every IRIS GL polygon span (`__subtri`, `__subtri_rgb`,
`__subtri_sh` and the z-buffered variants) is ONE 64-bit store to 0x948:
XSTARTI plus XENDF1, with GO. So GL's polygons need the doubleword split
(3.1), the 12.4(7) decode for XENDF1 (it holds `4096 + x` as a float), and
the core's bench copied the integer reading (`tb_rex3draw.cpp:825`).

**SETUP is also what IRIS GL's lrectwrite and both libraries'
depth-buffered lines rely on** (`_mem32_to_fb`/`_mem8_to_fb`: SETUP, then
one HOSTRW0|GO per word; `__glNptDepthLine`: SETUP, then ZPATTERN|GO per
segment). **STEPZ** (0x0034) - "Enables ZPATTERN (Z test fail) for one
iteration" - is only latched; IRIS GL's textured spans use it for z-failed
texels, which the core draws.

**LENGTH32 line segments.** "Segments II" lines end a GO after 32 pixels
with the iterators on the next pixel; the core (after IRIS) never steps
after a GO's last pixel, so each later segment redraws the previous one's
last pixel, the per-segment z mask drifts a pixel per segment, and the
colour DDAs double-step at every boundary. GL's depth lines use it.

**Pattern iterators.** On the part the pattern registers themselves
rotate, a host write restarts them at the msb, and neither DOSETUP nor a
row end resets them; the core's separate cursors reset at DOSETUP and row
ends and not on a register write. GL stippled polylines restart the dash at
each vertex; GL depth lines start mid-word after an earlier line.

**BRESROUND is ignored.** OpenGL programs BRESRNDINC2's octant rounding
bits to 0x96 so lines are identical in both directions; the core always
takes the diagonal on a tie. X programs 0xFF, which matches the core.

**Line setup fidelity.** The F_LINE start-point E-test was deleted in REX3
Rev 1 (§6) yet IRIS, MAME and the core all still do it; the F_LINE deltas
are truncated; anti-aliased lines, the AWEIGHT table and the endpoint
filter are not modelled (GL loads 0xFEDCBA98/0x87654321, which has no zero
nibble, so the core's filter never fires). **LRONLY on a BLOCK** walks the
rejected row stepping the DDAs where the chip aborts it. Reset octant,
SPAN end state and point-mode SKIPFIRST differ in ways nothing observed
depends on.

**The glyph damage is not the walker**: X's glyph loop (Xsgi 0x100fa75c,
dm0 0x9106, one ZPATTERN|GO per row) matches the spec's LENGTH32 BLOCK walk
exactly - consistent with 3.6.

### 4.3 The pixel path: colour, blend, formats, write masks

**GL's colour masks are in the chip's physical bit layout (re-checked).**
Spec §3.3: WRMASK "must match the bit positioning as described in Section
3.9", whose Table 22 interleaves B/R/G bits across the 24 planes. OpenGL's
`__glNptSwizzleRGB` builds glColorMask masks from 0x492492 (R), 0x249249
(G) and 0x924924 (B); IRIS GL's `_swizz_wmask` interleaves bit by bit.
The core stores R, G, B in whole bytes and applies WRMASK raw, so a
per-channel mask writes the wrong planes. Buffer-select masks (0xFFF /
0xFFF000, 0xF / 0xF0, 0xFF, 0xFFFFFF) and the PROM's aux masks (0x33, 0xCC,
0xFFFF00) are identical in both layouts, which is why ordinary drawing and
double buffering work. Fix without changing the frame buffer: permute
WRMASK from physical to logical per (PLANES, DRAWDEPTH, RGBMODE) when a
primitive starts - a few dozen ALMs.

**BLENDALPHA gates the alpha channel only (re-checked against the spec
text).** §3.8.5: "When BLENDALPHA is set to 0, the source multiplier for
blending ALPHA is one instead of source alpha and destination multiplier is
defined by DFACTOR." np_rex3 (`sa_src`, line 1286), IRIS and MAME all
substitute 1.0 for the source factor of R, G and B too, which turns GL's
standard SRC_ALPHA / ONE_MINUS_SRC_ALPHA blend additive - and both SGI
libraries map GL_SRC_ALPHA to SFACTOR=4 without ever setting BLENDALPHA,
as do all 46 blend shapes in the corpus. SGI's shipping GL would not have
worked if the emulators' reading were right. IRIS's own note
(`rules/rex3/blendalpha-and-alpha-blending.md`) records a visible haze
from its reading and attributes it elsewhere. Best settled on real
hardware; the spec and the binaries agree.

**Host alpha below 32 bpp.** With ALPHAHOST and not COLORHOST the host
field supplies alpha (IRIS GL's anti-aliased points put coverage in
HOSTRW0[31:24] at HOSTDEPTH 0); the core, like IRIS, reads alpha 0.

**COLORVRAM formatting.** "loading of COLORVRAM must be performed after
DRAWMODE1 fields RGBMODE and DRAWDEPTH have been set" (§3.5.5): REX3 formats
it. GL supplies BGR888 at every RGB depth and a pre-swizzled pattern for
the overlay; the core is right at 24/12-bit RGB and CI and wrong at 8-bit
RGB (a clear to red becomes white), 4-bit RGB and the overlay.

**Rounding and CI dither.** With DITHER off REX3 rounds to nearest (§3.8.3;
GL's own fast-clear tables reproduce the rule bit for bit); the core
truncates, so a cleared area and a drawn area of the same colour differ by
a step. CI dither and CI rounding are missing (12 corpus shapes shade CI
with dither and come out banded). CICLAMP at 12 bpp tests the wrong bit.

**Smaller:** blend arithmetic divides by 255 where the chip adds the MSB
and divides by 256 (1 LSB on ~8 % of values); overlay nibble write masks and
the 4+4 overlay; RGBA formats (video only); a blended SCR2SCR does not
replicate; cross-depth views of the same planes scramble colour (the price
of the logical layout). Colour compare in CI mode is missing and unused.

### 4.4 The bus, host pixel I/O, the Display Control Bus and VDMA

**The doubleword rule, specified.** The Indy really does send 64-bit
transfers to Newport: the kernel sets the MC's GRX_SIZE_64 through
`setgioconfig` in `newportProbe` and CONFIG.BUSWIDTH=1
(`rex3_config_default` = 0x230C2), and the spec's own example is "A
monochrome shape ... can be written using 64b writes as XYENDI#XYSTARTI"
(§3.5.3.3). It is worse than a lost word: newport.sv's register offset
keeps address bit 11, so the GO fires with the EVEN write and the odd
register stale - XYSTARTI+XYENDI|GO draws to the old end point. Correct
behaviour for a store with bytes in both words: R(A&~7) <- data[63:32],
then R((A&~7)+4) <- data[31:0], then one GO if bit 11 was set, nothing in
between (no GO after the first half, no VDMA beat between the halves), the
CPU acknowledged after the second. Word and narrower stores unchanged.
Doubleword loads should return {even, odd} with one GO after both, but no
software issues one and the bus does not carry the load size today.

**Reads are not ordered behind the drawing engine - BREAKS X's GetImage and
GL's read-back.** On the chip a read is a GFIFO entry (GF_READ) and stalls
the bus until its data exists; np_rex3 answers every read at once ("A READ
IS NEVER HELD"). Xsgi's PIO GetImage primes HOSTRW0|GO, waits for GFXBUSY
once, then loops `lw HOSTRW0|GO` with no wait between words (Xsgi
0x100fe484-6fc and two more); IRIS GL's `_fb_to_mem32` and libGLcore's
CopyPixels do the same. In the core every word after the first is the
previous one, and back-to-back GOs merge into the single `go_pending` bit.
Correct: every read except STATUS, USER_STATUS and CONFIG waits until all
earlier writes and GOs have taken effect (IRIS's `busy_or_val` does this);
DCB-class reads wait for the DCB side only. This also removes a latent
hang (a DCB read issued while a DCB write runs loses its start pulse).

**VDMA drops every beat for a buffer at 4-7 mod 8 (re-checked).**
`Ng1PixelDma` builds the GIO address as (phys & ~7) | (memaddr & 7)
(/unix 0x88190440-4c) - the start byte; np_rex3 keeps bit 2 of it
(`nd_reg`, line 1642), so such a beat decodes as HOSTRW1 and is dropped:
PutImage draws nothing, GetImage returns zeros. IRIS masks the low bits
(mc.rs:575). The beacon's `nd_drops` counts them.

**Packed reads are misaligned at a row's end.** "the leftmost field is the
first one to be used ... undefined values ... for unused, trailing fields"
(§3.10): a partial last word must have its pixels at the top. np_rex3 leaves
them at the bottom with stale bits above; Xsgi keeps the TOP bytes of the
last word, and the kernel's frame buffer depth probe tests bits 31:24. The
non-packed read (RWPACKED=0) places its pixel at the bottom too, where the
packing table puts it in the leftmost field.

**The Display Control Bus never reports busy.** BACKBUSY is hard 0; an
access to an absent device with an acknowledge enabled should hold
BACKBUSY until DCBRESET, which must act at once. The kernel's
`ng1_i2cProbe` polls exactly that for the Presenter flat-panel adapter -
the core's answer is the `hinv` "Presenter adapter board" false positive
(docs/48). DCB writes wait behind running draws (on the chip they go
through their own FIFO); the CRS auto-increment is per transfer for VC2
where the spec says per byte; DCBDATA1 does not start a transfer.

**Smaller:** SWAPENDIAN on host data is missing (libGLcore sets and clears
it); VERSION reads 1 where IRIS and MAME answer 3 (the kernel copies it to
the board info user space sees); CONFIG resets to 0 instead of 0x230C4; the
µTLB tag uses VPN[31:22] where the spec says [31:21] (IRIX 5.3's 4-byte
PTEs make it moot); the CPU bus is held for a whole running primitive, so
interrupts wait behind a long fill (the chip's GFIFO absorbs 32 entries).

**The kernel's context switch round-trips through the core's formats**
(48 registers, 32-bit only; COLORRED restored under RGBMODE for 12-bit CI,
XSAVE after XSTART, all four slopes converted back to sign-magnitude). The
pattern cursors are not in any register, so a context switch loses the
stipple phase (4.2).

### 4.5 The display: VC2, XMAP9, CMAP, BT445

**The display enable (re-checked).** The PROM picks the timing table from
the board and RAMDAC revisions the core reports (board 4, BT445 nibble 0):
1680 x 1065 pixels a frame, visible lines 41-1064. On a visible line
DSPLY_EN spans 1318 pixels and VIS_LN 1296; IRIX draws the desktop in
columns 8-1287 (`bt445_bug_xbias` = 8 from the table's flags, applied by
`newportValidateClip` to the window origin and screen masks - which is
also why frame buffer columns 0-7 are empty). DE must be VIS_LN, with
`pix_x` 0 at its leading edge (already so). For an unscaled 1280-wide
picture the core may crop the 8-pixel margins; the real part shows them.

**The cursor is drawn 10 pixels left of its hot spot** (derived from the
VC2 spec's pipeline delays and IRIX's constants; needs one board check).
The spec puts cursor column 0 at CUR_X + (HPOS - VIS_LN) + 7; np_vc2
hard-codes CUR_X - 31, right only when HPOS leads VIS_LN by 38 pixels - on
this table it is 28.

**The BT445 gamma table is never applied, and its register map is not
IRIX's.** IRIX loads a gamma ramp (Xsgi mentions a 1.7 default) through
CRS1 palette writes; the core's BT445 decodes CRS0 as command and never
looks up the table, so every pixel shows as if gamma bypass were set. The
XMAP9 RGB maps (CMAP 0x1E00/0x1F00, used by X's DID 10) are bypassed too.

**XMAP9 overlay/underlay modes 1, 6, 7 and OVL_Buf_Sel are misdecoded**
(X uses mode 2 only; GL overlay/underlay windows would use the others).
Smaller: VC2 Blackout ignored; VINTR enable not gated; the DID entry
pointer and cursor X not latched to vertical blanking; DID runs under 3
pixels; crosshair cursor; CMAP writes immediate (as the XMAP9's).

X's own mode table (Xsgi .sdata, via ioctl 0x520e) - DIDs 0-10 carry an
8-bit overlay on CMAP page 27: 0 4-bit CI, 1 4-bit RGB, 2-5 8-bit CI pages
17-20, 6 8-bit RGB, 7 12-bit CI, 8 12-bit RGB, 9 24-bit RGB map 0, 10 24-bit
RGB map 1; DID 11 is 8-bit CI page 21 with gamma bypass (the desktop).

### 4.6 What the guest software actually uses

A dataflow census of every load and store through each binary's REX3
pointer (libGLcore `gc->[0x6e74]`, IRIS GL `gc->[0x1f0]`, Xsgi's screen
private, the kernel's `info->[0x60]`): PROM 592 accesses in 26 functions,
kernel 984 in 36, Xsgi 1,188 in 60, IRIS GL 977 in 149, OpenGL 1,241 in 190.
It reproduces the raw doubleword scan exactly (43 of 43, 172 of 172).

* **215 doubleword stores, all in GL; no doubleword LOADS anywhere; none at
  0x00-0x3C.** IRIS GL's bias for window coordinates is 5472.0 and the
  kernel sets a GL window's XYWIN to origin + 0xAA0 on both axes, so the
  chip's truncation of the float's top bits is relied on. GL's clear
  (`gl_czclear`) writes nothing but the GL-format coordinates - with 32-bit
  stores - so 4.1's mask defect blanks GL on its own.
* **The X server writes WRMASK in the physical layout too**: `rex3RGBMask`
  turns a GC planemask into interleaved plane bits at 4/8/12/24 bpp. The
  WRMASK permutation of 4.3 fixes X's partial planemasks as well as GL's
  colour masks. (IRIS carries a commented-out hack forcing 0x6DB6DB to
  0xFFFFFF - it met these masks and papered over them.)
* **SWAPENDIAN is used by OpenGL (re-checked)**: `__glNptPickTextureProcs`
  ORs 0xB00 into DRAWMODE1 (32-bit host depth plus SWAPENDIAN) for ordinary
  RGBA texture spans, and the DrawPixels fast paths set it from a flag.
  np_rex3 ignores the bit, so those spans swap R with A and G with B.
* **LSREPEAT**: every writer (IRIS GL, OpenGL, X) programs factor - 1; the
  core, like IRIS, reloads REPEAT - 1, so a stipple factor n draws n pixels
  for the first bit and n - 1 after. Reload REPEAT.
* **YSTRIDE** is used by IRIS GL's image writes (conditionally) - built,
  untested. **DCB devices 10, 11 and 12** are programmed by the PROM and
  kernel (device 10 is read back at init; 11 by `initClock`; 12 is the
  flat-panel I2C) - the core answers 0 for 8-15.
* **Unused by any binary**: YFLIP, XYOFFSET, SKIPFIRST, LSADVLAST,
  BACKBLEND, BLENDALPHA, PLANES 0/2/3/7, STALL0/1, DCBDATA1, SLOPERED1,
  ENDATAPACK, doubleword loads, GO reads of anything but HOSTRW0.
* **Used only by GL, never by X** - which is why the board shows a working
  desktop and broken GL: the doubleword pairs, the GL-format coordinates,
  float colours and slopes, SHADE, F_LINE, A_LINE with the endpoint filter,
  LRONLY, CICLAMP, blending, the alpha test, ALPHAHOST, RWDOUBLE,
  SWAPENDIAN, YSTRIDE, STEPZ, LSREPEAT > 0, LSSAVE/LSRESTORE, per-span
  ZPATTERN software-z, CID clipping with a GL window's XYWIN, and every
  DBLSRC-dependent read, blend and logic op.

## 5. Implementation plan

**Principles.** Correctness before speed, and GL-blocking first. One change
per build ([one-change-per-build]): a fit is the last tested build plus one
coherent change, then a board run, then the results, before the next RTL
edit - with one exception proposed below where three defects must all be
fixed before anything can be observed. Every change carries its own test,
and where IRIS is wrong the bench's oracle changes with the RTL, marked as
a deliberate divergence and pinned by a hand-computed spec vector (the
bench already shared one transcription slip with the RTL, 3.2). Commit and
push after every gate.

**Phase 0 - test infrastructure (no fit).**
* A newport-level bench: drive `newport.sv`'s GIO slave with the CPU's real
  transaction shapes (32- and 64-bit stores, GO aliases, loads during a
  running primitive) and the VDMA port with start bytes; check registers
  and the frame buffer. No bench reaches newport.sv's bus handling today.
* Bench cases the audit showed missing: GL-format coordinate writes as
  floats, XENDF1, SETUP then GO, STEPZ, LSSAVE/LSRESTORE, non-zero XYMOVE,
  LENGTH32 lines, BRESROUND, multi-GO text; and IRIS's own `rex3_tests.rs`
  vectors the core's benches never ported (SCR2SCR with XYMOVE, I_LINE in
  all octants against an independent Bresenham, stipple continuation,
  SKIPLAST polylines).
* Recommended, optional: capture the REX3 register stream (with widths)
  from IRIS running ep, bongo and buttonfly and replay it through
  newport.sv in Verilator against IRIS's frame buffer - the only gate that
  exercises GL's real command mix. Needs a small logging change in IRIS, on
  a branch there.

**Phase 1 - make GL draw.**

| build | change | why | gate |
|---|---|---|---|
| 44 | Display window: DE from VIS_LN, cropped to the desktop's 1280 columns (frame buffer 8-1287) | Every screen: the scaler drops a column every 34 pixels today, and every screenshot used to judge the GL work passes through it (3.6, 4.5) | textprobe: zero dropped columns; PROM console and X intact |
| 45 | GL's register interface: doubleword stores split into two register writes with one GO after both; GL-format coordinates (0x138-0x144) masked 0x007FFF80 and 0x14C decoded as XENDF1; a write to SETUP runs the setup without drawing | Each alone blanks GL (3.1, 4.1, 4.2); none can be seen working until all three are in | new bus bench + float/SETUP bench cases; saverprobe: ep, bongo, buttonfly draw; regression |
| 46 | Host read path: graphics-class reads wait until earlier writes and GOs have taken effect (not STATUS/USER_STATUS/CONFIG), GOs queued rather than merged; packed reads left-justified at a row's end | X's GetImage and GL read-back return stale words (4.4) | bus bench read-while-busy; `xwd -root` and a GL ReadPixels round trip on the board |
| 47 | VDMA start byte: ignore the GIO address's low three bits at REX3 | PutImage/GetImage of a buffer at 4-7 mod 8 draw nothing / read zeros (4.4) | bus bench; beacon `nd_drops` stays 0 under X image traffic |

**Phase 2 - make GL look right.**

| build | change | why |
|---|---|---|
| 48 | BLENDALPHA gates the alpha channel only; host alpha from the host field below 32 bpp | every GL alpha blend is additive today (4.3) |
| 49 | WRMASK permuted from the physical to the logical layout when a primitive starts (RGB at every depth, the overlay's nibble buffers) | GL colour masks and X planemasks write the wrong planes (4.3, 4.6) |
| 50 | SWAPENDIAN on host data (per field) | OpenGL texture spans swap channels (4.6) |
| 51 | COLORVRAM formatting at 8/4-bit RGB and for the overlay; 12-bit DBLSRC reads | wrong clear colours; blends and copies in a 12-bit back buffer read the front (3.2, 4.3) |
| 52 | Rounding with dither off; CI dither and CI rounding; CICLAMP's 12-bit bit | one-step colour errors, banded CI shading (4.3) |
| 53 | Line stipple and patterns: LSREPEAT reload, the pattern registers as the live iterators (a write restarts, DOSETUP and row ends do not), LSSAVE/LSRESTORE | GL stipple, wide lines (4.2, 4.6) |
| 54 | Lines: LENGTH32 segments step after their 32nd pixel, BRESROUND, the Rev-1 F_LINE setup (no E-test), STEPZ | GL depth lines, line symmetry, textured z-fail (4.2) |
| 55 | Vertical sector clip (1344 x 1024); the screen masks under XYMOVE after a board test | off-screen drawing wraps onto the screen (4.1) |
| 56 | Anti-aliased lines: A_LINE coverage from AWEIGHT, blended | GL smooth lines (4.2, 4.3) |

**Phase 3 - display and bus fidelity.** Cursor X offset taken from the
timing table (after one board check of the 10-pixel error); TOPSCAN applied
to the display rather than to drawing; the BT445 gamma table with IRIX's
register map, the XMAP9 RGB maps in CMAP and the gamma-bypass bit; XMAP9
overlay/underlay modes 1, 6, 7; the Display Control Bus's BACKBUSY, the
absent-device timeout, an immediate DCBRESET (the `hinv` Presenter false
positive) and answers for devices 10-12; DCB writes no longer queued behind
draws; the retrace interrupt's XMAP9 write measured with a beacon
instrument before deciding anything about the tear; VERSION, CONFIG's reset
value and read-back widths.

**Phase 4 - speed.** Only once the picture is right: pipelined
read-modify-write for spans (read ahead while writing - ~25 clocks a pixel
today against the chip's 50-100 Mpix/s), 12-bit fills without a per-pixel
read, and a real 32-entry graphics FIFO so the CPU is not held for a whole
primitive. The display's ~27 Hz refresh is its own later project.

**Budget.** 35,481 ALMs used of 41,910 (84.7 %), core slack +0.506 ns. Phases
1-3 are mostly decode and small datapath changes - estimated 1,500-2,500
ALMs and one or two M10K for the gamma table; the timing margin, not area,
is the constraint, and every build checks it (`tests/out/hw/worstpaths.tcl`
finds the offender from a finished compile without a refit).

**Settled by evidence rather than by an emulator** (no real Indy here): the
BLENDALPHA reading (spec text plus both SGI libraries), LSREPEAT (every
writer), the XSTARTF truncation (spec, IRIS, MAME, the kernel's 0xAA0
bias). **Still needing a board experiment**: XYMOVE in the screen masks,
the cursor offset, where the retrace interrupt's XMAP9 write lands.
