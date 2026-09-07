# Work item: the 16 KB physical D-cache PASSES the boot gate (the post-init sim wedge is pre-existing) - merge done, fit + board next

Paste everything below the line as the opening message of a fresh session.
This follows [41](41-resume-dcache-boot-wedge.md). That session's first job was
the build-21 (8 KB) control IRIX boot; this session ran it, SETTLED the boot
question (the wedge is pre-existing, NOT the 16 KB cache), merged the branch to
`main`, and launched the build-22 fit. Written 2026-09-07.

---

## STATE AT HANDOFF (read this first)

* **The boot question from docs/41 is SETTLED: the post-init sim wedge is
  PRE-EXISTING and cache-size-independent.** Two whole-machine Verilator IRIX
  boots to 450M cycles, `--stop-on 'coming up'`, trace armed at libgen
  `__execute` PC `0f996510`:
  - 16 KB physical D-cache (branch): last NEW peripheral HPC3-PBUS-PIO at
    192,501,440, then a userspace regex/loader spin to 450M, never "coming up".
  - 8 KB cache (= `main`, the BOARD-VERIFIED build 21): last new peripheral
    HPC3-PBUS-PIO at 192,648,918 (within 0.07%), the SAME 24-entry unclaimed-bus
    table, the same userspace spin, the same no-coming-up.
  The board boots the 8 KB cache all the way to the desktop, so the sim's
  inability to pass ~192.6M is a SIM-ONLY peripheral/environment issue, not the
  cache. docs/40's "console begins The system is coming up" criterion is
  unreachable in the sim; the real gate is "init survives" (no PANIC past
  ~190M), which BOTH caches meet. See auto-memory `irix-sim-postinit-livelock`.
* **cpu-tests: 2160/3** on the worktree 16 KB model (both tlb tests pass; only
  `fpu/vec_cvt_from_l` fails, matching the 8 KB baseline). `cpuonly` 728/0.
* **The merge is DONE** (this session): `main` now carries the 16 KB physically
  indexed D-cache (was `d514feb` docs/40; now includes `67c31ee` +
  the docs/41/42 commits, fast-forwarded). Verify with `git -C
  C:/Temp/mistercore/sgiindy_MiSTer log --oneline -3`.
* **The build-22 fit was LAUNCHED** (SEED=2) from the worktree. Check
  `output_files/sgiindy.rbf` timestamp + `b22.log`/`b22.console`, and the
  register-count guard (~39k right, refuses >60k). See "The queue".
* **The board is UNCHANGED:** build 21 (`62be253`, rbf md5
  `5f02393b96f9e1361d5b6da6ed7b2a93`) is on it, HALTED ("Okay to power off"),
  `SGIIndy53-wedged-fsck.img` in slot 1. Build 19 is the fallback. Never deploy
  `output_files/sgiindy-b20-seed2.rbf` (the dead 32-byte cut).
* Read auto-memory first: `irix-sim-postinit-livelock` (this session's finding),
  `irix-hardcodes-dcache-line`, `ki-r4600-core-assessed`, `local-toolchain`
  (now with the NATIVE-FS build trick: 40 s not 14 min), `verilator-whole-machine`,
  `quartus-ram-inference` (fit register guard), `hardware-bug-instrument-first`,
  `indy-desktop-input-recipe`, `shutdown-hang-kdsp-audio`, `iris-oracle-local`.

You are working on an **SGI Indy (IP24) core** for MiSTer FPGA at
`C:\Temp\mistercore\sgiindy_MiSTer`, a session probably starting in the worktree
`.claude\worktrees\modest-robinson-cad59e`. The reference emulator IRIS is
`C:\Temp\mistercore\iris`. A fit is 20-40 minutes. Another Claude session on this
box fits `MacQuadra800`; no fit launch while its quartus is listed.

## How the boot question was settled (so you can redo it)

Build both models on the NATIVE WSL FS (40 s, not 14 min on /mnt/c - see
`local-toolchain`): `rsync -a --exclude '.ghdl' --exclude 'obj_*' --exclude
'*.log' $WT/rtl $WT/tools $WT/verilator ~/br16k/`, de-CRLF the Makefile +
`tools/gen_r4300_verilog.sh`, delete the copied generated verilog, regen, then
`make -C ~/br16k/verilator wholemachine2`. A second copy `~/ctrl8k` with
`main`'s three cache files (`cpu.vhd`, `cpu_datacache.vhd`, `r4300_wrap.vhd`)
dropped in is the 8 KB control - no checkout dance in the worktree. Run each:

    ./obj_wm2/Vsim_top --prom $WT/roms/IP24_Indy/ip24prom.070-9101-011.bin \
        --no-gfx --disk 1=/mnt/c/Temp/mistercore/iris/SGIIndy53-master.img \
        --max-cycles 450000000 --type-on 'Option?' '1\r' --stop-on 'coming up' \
        --console R/console.log --pc-from 0 --pc-count 4000000 \
        --trace-from-pc 0f996510 --exc --exc-count 200000 --trace-count 20000 \
        --ramdump 0x88000000:0x4000000:R/ram.bin > R/stdout.log 2> R/stderr.log

Compare the exit summaries' "unclaimed bus" tables and the last-new-peripheral
cycle; they match to <0.1%. ~50 min wall each with two boots contending on the
20-core box.

## The queue

### 1. Confirm the build-22 fit (in progress)

Watch `b22.console`/`b22.log`. On success `output_files/sgiindy.rbf` is build 22.
Quartus rewrites `SEED` + `LAST_QUARTUS_VERSION` into `sgiindy.qsf` - `git
checkout -- sgiindy.qsf` after and discard the version line. Watch the CORE
clock slack: the mini-TLB compare + two muxes sit in front of the tag RAM
address (build 21 had +2.772 ns; the new 11:3 mux is on the shorter path). If it
fails timing, try another seed before touching RTL. Commit the rbf with the
`-- SGI:` markers and a row in `rtl/cpu/r4300/UPSTREAM.md`.

### 2. The board: `tests/run-cputest-hw.sh --no-build` (bench group - `ld_miss`
should stay ~13 ticks, `i_cached`/`st_cached` 1.0 CPI), then IRIX to the desktop,
toolchest, `init 0`. Before ANY redeploy of the halted board: pointer onto the
Console, `init 0`, Enter, wait for the power-off screen. (Spin an Opus session
for the board control - keep Fable for intelligence tasks.)

### 3. The sim post-init livelock (separate, sim-only, LOW priority - the board
boots fine). If ever chased: the machine is single-user, just past fsck, spinning
in libgen regex + libc + the main exe at 0x0041xxxx; last live peripheral is
HPC3-PBUS-PIO at ~192.6M. Suspect an incompletely modelled PBUS PIO probe or the
RTC date path ("clock gained 11158 days"). Disassemble with the guest binaries
(`efsread.py` + `ecoffsyms.py`/mips-objdump).

### 4-7. Unchanged from docs/40/41: CD-ROM attach, a burst-WRITE rasteriser path,
Ethernet, audio.

## Traps paid for (do not re-pay)

* Everything in docs/38-41's lists. New this session:
  - **Build on the native WSL FS, not /mnt/c** - regen+build is 40 s vs 14 min.
    The generated verilog is byte-identical bar path comments.
  - **A `wsl -- bash -c '...'` string eats `$vars` even single-quoted here**
    (Git Bash mangling); always run WSL work from a script FILE.
  - `grep -c` with `|| echo 0` can yield a two-line "0\n0" that `[ "$x" != 0 ]`
    reads as true - a monitor false-positived on it. Coerce with `| head -1`.
  - The docs/41 "post-init wedge at 192.5M" is real but PRE-EXISTING; the 200M
    `--max-cycles` run that looked wedged was just the cap landing on a timer
    interrupt (`active_timer_switch`), still executing.
