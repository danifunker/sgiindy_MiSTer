# The rest of REX3's command set, and the corpus that named it

Written 2026-09-17, after docs/design/hpc3-register-file.md. The question was "what do we need to add to
get the 3D and the rendering working, and is it REX3?". It is REX3: the Indy's
Newport board has no geometry engine, so every triangle a GL program draws
arrives at this chip as spans and lines with its colour already interpolated
into the DDA registers. Everything below is `rtl/newport/np_rex3.sv`.

## 1. What was missing, counted rather than guessed

`iris/src/rex3_shaders.rs` is generated from a profile file IRIS collects by
running a real IRIX desktop: one entry per distinct `(DRAWMODE0, DRAWMODE1,
CLIPMODE)` triple the emulated REX3 was actually asked for. **462 draw shapes,
and they are a far better statement of what the rasteriser has to get right
than anything anyone would think to write down** - it is what Xsgi, the Motif
toolkit, the window manager and libgl between them really use.
`tools/rex3_corpus.py` decodes it; the counts of what build 42's engine could
not do:

| missing feature | shapes needing it |
|---|---:|
| dither | 197 |
| I_LINE address mode | 85 |
| the colour DDAs (SHADE) | 85 |
| LRONLY | 57 |
| the line stipple (ENLSPATTERN) | 49 |
| alpha blending | 46 |
| CICLAMP | 46 |
| F_LINE address mode | 40 |
| ALPHAHOST | 15 |
| A_LINE address mode | 12 |
| the alpha compare | 8 |
| LSOPAQUE | 8 |
| ENDPTFILTER | 7 |

By address mode the corpus is 202 BLOCK draws, 86 SPAN, 85 I_LINE, 40 F_LINE,
24 SCR2SCR, 13 READ and 12 A_LINE. **137 of the 462 are lines**, and the
engine had no line walker at all: it drew the two endpoints' bounding row and
stopped. By plane depth it is 244 shapes at 12 bits, 110 at 24 and 108 at 8 -
and 12-bit double-buffered RGB is exactly what a GL window is, which is the
other half of why nothing 3D drew: **in RGB mode the pipeline carries 24-bit
colour and the planes do not**, so without the compression step an 8-bit plane
took the red channel and called it the pixel.

That is the screen saver, concretely. `/usr/lib/X11/savers/defaults` on the
disk image lists fourteen: `blank`, `bongo`, `ep`, `flame`, `hop`, `image`,
`life`, `pop`, `pyro`, `qix`, `random`, `rotor`, `swarm`. The xlock ones
(`qix`, `swarm`, `rotor`, `pyro`, ...) draw X lines and points - I_LINE and
F_LINE. The two GL ones run `/usr/sbin/haven` over `/usr/demos/bin/ep`
(ElectroPaint) and `/usr/demos/bin/bongo` (Octahedra) - shaded, dithered,
blended spans. `buttonfly` is in the same directory and is the same shape of
work.

## 2. What was added

The pixel pipeline, in the order IRIS's `rex3_generic.rs` runs it:

* **the colour DDAs.** `COLORRED/GRN/BLUE/ALPHA` step by their slopes once per
  pixel, drawn or not. The slopes are sign-magnitude on the bus and two's
  complement in the chip - the same bits, which is why the register test never
  noticed there was a conversion. RGB mode clamps every component in the
  accumulator; colour-index mode iterates the red DDA alone and clamps it only
  under CICLAMP, by watching one bit above the index's own width.
* **COLORI became a window onto those DDAs rather than a register.** It has to
  be: a colour-index shade leaves the iterated index in the red DDA and the
  driver reads it back from COLORI. A separate store would have held the
  un-shaded colour and every Gouraud span would have come out flat.
* **compression and expansion between 24-bit colour and the plane depth** -
  1-2-1 at four bits, 3-3-2 at eight, 4-4-4 at twelve - with the 4x4 Bayer
  dither, whose cell is indexed by the walker's own coordinate so that a window
  that moves by an odd number of pixels takes its dither pattern with it.
* **alpha blending**, both factor selectors, BLENDALPHA and BACKBLEND. The
  divide by 255 is exact: `(n * 131587) >> 25` equals `n / 255` for every `n` a
  channel can produce, and 131587 is `0x20203`, three shifts and two adds. A
  plain `>> 8` would darken every blended pixel by a part in 256, which over a
  screen of translucent windows is visible.
* **the alpha function** against ALPHAREF, and **ALPHAHOST** for the source
  alpha.
* **the line stipple**: LSPATTERN with LSMODE's repeat counter and pattern
  length, LSOPAQUE, LSADVLAST.

The address generator:

* **SPAN as a mode distinct from BLOCK.** A span that reaches its right-hand
  end is over; a block wraps x back to XSAVE and drops to the next row. The
  engine used to treat every primitive as a block.
* **I_LINE, F_LINE and A_LINE**, with the Bresenham state in the registers
  where a continuation GO can find it, the fractional-endpoint correction for
  the two fractional modes, and A_LINE's endpoint filter.
* **LRONLY**, which a polygon rasteriser needs: it hands the chip both edges of
  every span and expects the one running against the fill to be dropped.

## 3. What the bench is, and what it found

`verilator/tb_rex3draw.cpp` is a transcription of `iris/src/rex3_generic.rs` -
the same functions under the same names - driving `np_rex3` through its own
register bus and comparing every pixel either side wrote. It runs all 426
non-host shapes of the corpus (`verilator/rex3_corpus.h`, generated) and then a
field-level random walk over the mode bits, which reaches combinations no IRIX
program has happened to ask for.

    make -C verilator rex3draw
    REX3D_SEED=7 REX3D_CASES=20000 ./obj_dir_rex3draw/Vnp_rex3draw

**It found nine defects that the picture on a monitor would not have shown**,
and that is the argument for having written it:

1. **The Bresenham deltas come from the fixed-point difference shifted down,
   not from the difference of the integer parts.** A line from x=123.875 to
   x=145.625 has a fixed-point difference of 21.75, which truncates to 21,
   while its integer endpoints are 22 apart. Every parameter follows from that
   one number, so a fractional line stepped its minor axis in the wrong places
   along its whole length. The pixel count, the continuation test and the
   fractional correction all use the *integer* difference instead - IRIS is
   inconsistent here in exactly this way and the hardware it was written
   against evidently is too.
2. **Both pattern cursors obey LSADVLAST, not just the stipple's.** IRIS
   advances the pair behind one `!is_last || lsadvlast` test. Advancing the z
   pattern on a line's last pixel and the stipple not left the two a step apart
   for the rest of the primitive's life, and the next continuation GO painted a
   different set of pixels - one position out, with the right colours.
3. **The line pixel count is taken after the fractional correction**, which can
   move the start a whole pixel along the major axis. Counting before it drew
   one pixel past the end of every line whose endpoints happened to step.
4. **The AWEIGHT index wraps at eight entries.** Two four-bit fractions add to
   thirty, clamped to fifteen, and a 32-bit register holds eight nibbles.
5. **A_LINE's first-endpoint filter never fires behind a DOSETUP**, because the
   setup spends XSTART's fraction before the filter reads it.
6. **The patterns and the alpha function are the DRAW opcode's alone.** A
   screen-to-screen copy under a live ZPATTERN copies every pixel, not a
   stippled subset. The cursors still advance.
7. **Four-bit planes have two buffers like every other depth**, and DBLSRC
   picks between them; the extraction ignored it.
8. **FASTCLEAR at four bits** replicates COLORVRAM into the slots at 0, 4, 8
   and 16, not 0, 4 and 12.
9. **LRONLY is the span and block walkers' bit**; IRIS's line walker does not
   look at it.

Three more came out of reading rather than from the bench, and each was a live
bug in build 42's engine:

* **CLIPMODE's CIDMATCH is a mask of permitted window IDs, not an ID to equal.**
  The two-bit CID in the auxiliary planes indexes a bit of it. Read as an
  equality it let a draw through on exactly the windows it should have clipped.
* **LENGTH32 is a pause, not a row end**: it stops the primitive where it
  stands for the next GO rather than wrapping x and advancing y.
* **The end of a row is the end of a row whatever STOPONX says.** The flag
  decides whether the primitive carries on, not whether the row ended - and the
  row's end is what SKIPLAST names.

State of the bench at the end: **426 corpus shapes and six runs of 20,426
random cases each, about 6.6 million pixel writes compared, zero differences**,
at memory acknowledgement delays of 0, 2 and 25 cycles.

## 4. The three places this deliberately differs from IRIS

Each is commented at its site in both the RTL and the bench.

* **Plane selections 0, 3 and 7** draw into the drawing planes here; IRIS maps
  only 1 (RGB) and 2 (RGBA) and drops a write through any other selection. The
  PROM's console path and `verilator/tb_rex3.cpp` both draw through planes 0.
  No corpus shape uses one.
* **SKIPFIRST on a BLOCK means the first pixel of each row.** IRIS's block
  walker sets its `first` flag at every row and never clears it, so under
  SKIPFIRST it draws nothing at all - while its span and line walkers both
  clear the flag after the first pixel. No shape in the corpus sets SKIPFIRST
  at any address mode, so that arm of IRIS has never run against real software.
  The bench leaves the combination out and says so.
* **The write-side x clip is the 2048-pixel stride**, not IRIS's 1344-pixel
  screen, and the frame buffer row wraps rather than clipping. Both are
  pre-existing and neither is reachable from a coordinate the bench generates.

Still not built, and still accepted and read back and ignored: YFLIP,
SWAPENDIAN (no corpus shape sets either), the anti-aliased line's per-pixel
coverage weighting (A_LINE draws as a fractional line; the AWEIGHT tables are
read for the endpoint filter and nothing else).

## 5. What it costs

`quartus_map` on the module alone, `tests/out/hw/maprex3.sh`:

| | build 42 | this |
|---|---:|---:|
| ALMs (estimate) | 2,026 | **3,336** |
| combinational ALUTs | 2,983 | 5,302 |
| dedicated registers | 2,161 | 2,209 |
| DSP blocks | 0 | **8** |

+1,310 ALMs on a device where build 42 left 8,140 free, and eight DSP blocks
for the blend's multiplies. The register count barely moves: almost all of this
is combinational - one more pipeline through the same walkers.

## 6. The other tests

`tests/rex3_replay.py` had to move with the engine. Its model of the walk was
the old one - end test on the pre-step position, STOPONX folded into the row
end - so it now steps first and tests where it landed, treats LENGTH32 as a
pause, and resets `first` at each row. The comparison it makes is unchanged: it
replays the PROM's own command trace into a model frame buffer and diffs it
against the one the run dumped.
