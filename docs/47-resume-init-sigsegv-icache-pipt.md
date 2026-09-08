# Work item: build 24 still panics INTERMITTENTLY with `init died (why = 2, what = 0xb)` on the board - make the I-cache physically indexed (PIPT), measure the boot rate, then the follow-ups

Paste everything below the line as the opening message of a fresh session.
This continues [46](46-resume-hdmi-black-and-followups.md) (the black
picture: a MiSTer wedge, cured by a shell `reboot`) and [45](45-resume-ki-
revendor-board.md) (the KI R4600 re-vendor, merged as build 24). Written
2026-09-08 09:30.

---

## STATE AT HANDOFF (read this first)

* **`main` is at `eca5a85`** (docs/46). The CPU is the Killer Instinct R4600
  re-vendor (`rtl/cpu/r4300/UPSTREAM.md` is the authority): D-cache 16 KB
  physically indexed, **I-cache 8 KB direct-mapped, index bits 12:5 (bit 12
  VIRTUAL), tag bits 31:12** - "one R4600 way". **Build 24** =
  `output_files/sgiindy-b24-seed2.rbf` (md5 `ab3ae66db0604ccfa466224785e2cdf5`;
  rbfs are gitignored), core clock slack +1.697 ns.
* **Build 24 on the board so far: 2 clean boots to the desktop, then 1
  PANIC.** The Opus session's two boots (07:03 and 07:36 on 2026-09-08) ran
  fsck -> "The system is coming up" -> X -> login -> desktop with zero crash
  messages; hardware cpu-tests 2165/3, bench identical to build 23. The
  user's own boot at ~09:17 (build 24 deployed 09:15 after the MiSTer
  `reboot` that fixed the video) died with

      PANIC: init died (why = 2, what = 0xb)
      Dumping to dev 0x2000011 at block 0, space: 0x27de pages
      ...
      Dump complete.
      [Press reset to restart the machine.]

  (`tests/out/hw/dumps-hdmi.png` in the worktree). `what = 0xb` is signal 11,
  SIGSEGV, in init. **That is the docs/08/09/21 signature** ("init dies with
  signal 11, and it is THE INSTRUCTION CACHE", intermittent, "about one boot
  in three") - the class fixed in docs/21 by the I-cache's dropped-command
  latch, back under a new identity. Build 22 (N64 base, R4400 identity) does
  not do this on the same image (two clean boots yesterday and this morning).
  The board is sitting at that panic screen; the disk image
  `/media/fat/games/SGIIndy/SGIIndy53.img` has the dump on its swap and will
  fsck on the next boot.
* **Why it is the I-cache, mechanically.** IRIX colours user pages for the
  part PRId names: `cachecolormask` = 3 as an R4400 (virtual == physical on
  bits 13:12) but **1 as an R4600** (bit 12 only; auto-memory
  `irix-r4600-colours-one-bit`, read from the kernel's data at 0x881B9680).
  Build 23's 16 KB virtually indexed I-cache with an 18-bit tag therefore hit
  WRONG pages (the rc2 crash storm). Build 24's 8 KB cache with the full tag
  cannot hit a wrong page, but its index bit 12 is still virtual, so a page
  mapped UNCOLOURED (virtual bit 12 /= physical bit 12 - IRIX does this on
  some paths, see auto-memory `irix-hardcodes-dcache-line` for the data-side
  proof) can sit in set(V) while the kernel's `Hit_Invalidate_I` by its K0
  address (physical) looks in set(P): a STALE line survives a page's reuse,
  and the next program mapped over that page executes old code -> SIGSEGV.
  A real R4600 has the same VIPT bit 12 but IRIX's R4600 code was written
  against IT - and the R4600's hit ops search both ways of a set; we have no
  second way. Rate: intermittent, like docs/08's one-in-three, because it
  needs an uncoloured mapping to land on a reused page.
  The simulator cannot show it (deterministic allocation, never aliases: the
  sim boot of build 24 was clean to 230M cycles) - the BOARD is the gate.
* Everything else from docs/45-46 stands: the black-picture wedge is an
  HPS/framework thing cured by `ssh root@192.168.99.92 reboot`; MiSTer.ini
  is untouched and right; build 22 (md5 `bd342f18e6be032fee53bfdc07fae3aa`)
  is the fallback.

## The fix: a PIPT I-cache - no virtual index bit at all

Mirror what docs/40 did for the D-cache. In `cpu.vhd` the fetch-side index
is `FetchIndex1/2(13 downto 2)`, KI's timing-optimised flat mux over
PC/PCnext/branch targets (`cpu.vhd` ~3376-3392; KI's assertion that they equal
`FetchAddr1/2(13 downto 2)` is `translate_off`), and the I-cache takes
`read_index1/2` for the index and `read_addrCompare1/2` = `FetchAddrTLBMuxed1/2`
(`TLB_instrAddrOutFound` when mapped, else the virtual address) for the
compare. Only bit 12 matters now (index 12:5):

1. `read_index1/2(12)` <= `FetchAddrTLBMuxed1/2(12)` - the translated bit
   when the fetch is mapped, the virtual one (== physical) when not. On a
   mini-TLB MISS `TLB_instrAddrOutFound` is stale, but that path stalls and
   re-issues the fetch as a FILL after the walk, so a wrong index there is a
   harmless false miss - the full tag compare makes a false HIT impossible.
2. The FILL index must be physical too: `fill_addrTag <= FetchAddr(31 downto
   0)` at `cpu.vhd` ~2261/2270 becomes the physical address (`mem1_addrCompare`
   is exactly that: `TLB_instrAddrOutFound`/`Lookup` when mapped, `FetchAddr`
   when not); the cache uses `fill_addrTag(12 downto 5)` for the line and
   `fill_addrData(31 downto 12)` for the tag.
3. `Hit_Invalidate_I` (0x10) must be TRANSLATED now (it is in the
   `decodeCacheTLBTranslate <= '0'` list at `cpu.vhd` ~3117 precisely because
   the cache was virtually indexed; the D-cache's hit ops already translate).
   Index ops 0x00/0x08 stay untranslated.
4. Gates: `make -C verilator cpuonly` (728/0), cpu-tests (2161/3 - the
   `cache/` group's self-modifying-code test is the one that matters), the
   IRIX sim boot (init survives, docs/45 recipe), fit (`scripts/
   fit_when_free.sh`), then **the board boot RATE, not one boot**:
   `scripts/bootrate.sh` measures panics over N launches (read its header -
   it classifies out of the frame buffer; it is for the PROM-prompt boot, so
   for IRIX either extend its classifier to spot "PANIC: init died" /
   "The system is coming up" in the frame buffer, or launch N times by hand
   with `scripts/mount.sh` and `scripts/screen.sh`). Ten boots each of build
   22 and the new build on the same freshly-fsck'd image is the number.
   Timing: bit 12 of the index now comes through the instruction mini-TLB
   compare - the D-cache pays the same and fits; if the core clock fails,
   the 4 KB fallback (index 11:5, no virtual bit, PIPT for free) is one
   constant away, at a cache-size cost.
5. If the PIPT cache still panics at the same rate, the I-cache is
   exonerated and the suspects are the other KI-core differences the sim
   cannot time: `chainedDelaySlot`, `kusegUnmapped`, the four-beat writeback
   staging under real DDR3 latency, the FetchIndex path. Instrument first
   (`hardware-bug-instrument-first`): the beacon has the CPU PC/EXL; add the
   last exception code/EPC/BadVAddr (they are on `dbg_exc_*` already) so the
   panic's fault address is readable off the beacon after the dump.

## Follow-ups (unchanged from docs/46)
* 16 KB as two 8 KB ways with the way picked by physical bit 13 (needs the
  PIPT bit-12 work above first - then it is the natural extension).
* `hinv` on build 24/25 (docs/45 pointer recipe). Commit the R4600 patch in
  `C:\Temp\mistercore\iris\cpu-tests` (uncommitted there). `ld_miss` +7 %
  is the 32-byte fill, expected.

## Recipes (self-contained)
* Board: `scripts/local.env` (`192.168.99.92`); `scripts/deploy.sh --rbf F`
  (pushes + API-reboots + launches; the API reboot kept video alive this
  morning), `scripts/mount.sh --disk1 /media/fat/games/SGIIndy/SGIIndy53.img`
  (launch without a reboot), `scripts/screen.sh NAME --mode text` (frame
  buffer), `scripts/grab.sh F.png` (HDMI capture; STALE = no frame),
  `python3 /media/fat/sgidbg/bcnread.py` on the device (beacon). Never
  `scripts/bootok.sh` for an IRIX boot. Black picture + OSD visible ->
  `ssh root@192.168.99.92 reboot`. A fresh image is
  `C:\Temp\mistercore\iris\SGIIndy53-master.img` (2 GB).
* Sim (WSL, native FS `~/kicpu`): rsync `rtl tools verilator`, de-CRLF, GHDL
  shim `/tmp/llvmshim`, `tools/gen_r4300_verilog.sh`, `make -C verilator
  cpuonly`, `cputest` (obj_dir/Vsim_top); cpu-tests from `~/cputests`
  (already R4600-aware); the IRIX boot: `--prom .../ip24prom.070-9101-011.bin
  --no-gfx --disk 1=/mnt/c/Temp/mistercore/iris/SGIIndy53-master.img
  --max-cycles 230000000 --stuck 250000000 --type-on 'Option?' '1\r'
  --stop-on PANIC --console F --exc --exc-count 2000 --pc-user F`, ~35 min,
  under `nohup ... & disown` from a script file.
* Fit: `SEED=2 bash scripts/fit_when_free.sh bNN` via `Invoke-CimMethod`;
  waits for the other session's Quartus (ask the user before fitting
  concurrently). Register guard ~43k; `git checkout -- sgiindy.qsf` after.
* Read the auto-memory first: `irix-r4600-colours-one-bit`,
  `ki-revendor-wip`, `irix-hardcodes-dcache-line`, `prom-config-ec-per-
  family`, `hardware-bug-instrument-first`, `indy-desktop-input-recipe`,
  `local-toolchain`, `verilator-whole-machine`, `quartus-ram-inference`.
