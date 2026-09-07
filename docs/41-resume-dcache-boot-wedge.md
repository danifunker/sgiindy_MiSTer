# Work item: the 16 KB physically-indexed data cache BOOTS IRIX's init (fixed) - now settle the post-init boot wedge, then merge + fit + board

Paste everything below the line as the opening message of a fresh session.
This follows [40](40-resume-bigger-dcache.md), the session of 2026-09-03 that
implemented docs/40 Option 1 (a 16 KB direct-mapped, physically indexed data
cache), FOUND AND FIXED a real bug in the plan's own re-read sketch, got
run-cputest back to 2160/3, and proved IRIX 5.3's init survives - but the sim
boot then wedges after init, and the session ended on a power loss before the
control run that would say whether the wedge is the cache or a pre-existing
peripheral issue. Written 2026-09-03.

---

## STATE AT HANDOFF (read this first)

* **The work is on branch `claude/modest-robinson-cad59e`, NOT on `main`.**
  `main` is at `d514feb` (docs/40). The branch is two commits ahead:
  - `02dc509` WIP: the 16 KB physical cache, geometry only (regressed two tlb
    tests - that was the bug, now fixed by the next commit).
  - `67c31ee` the unstall-index fix (below). **This is the tip; the working
    tree is clean and matches it.** Do NOT merge to `main` until the boot
    question below is settled (docs/40's rule: no merge before the IRIX sim
    boot passes init - it now does, but the wedge wants understanding first).
* **Three files changed from `main`** (verify with `git diff main..HEAD --stat`):
  - `rtl/cpu/r4300/cpu_datacache.vhd` - 16 KB geometry: one more index bit
    everywhere (tag RAM `addr_width` 10, data RAM 11, index 13:4, dword 13:3,
    line 13:0), tag stored still 20 bits but COMPARED on `tag_compare(19 downto
    2)` vs `RW_addr(31 downto 14)`, fill/writeback from `RW_addr(13 downto 4)`,
    clear walks `10x"3FF"`, a new `tlb_unstall` port folded into `ce_fetch`.
  - `rtl/cpu/r4300/cpu.vhd` - the `EXECacheAddr` physical-index mux and the
    `tlb_unstall => TLB_dataUnStall` wiring, INCLUDING the fix (below).
  - `rtl/cpu/r4300_wrap.vhd` - `SETTLE_CLOCKS` 1024 -> 2048 for the 1024-entry
    clear.
* **VERIFIED GREEN on this box (WSL, before the power loss):**
  - `make -C verilator cpuonly` = **728/0** (78 burst fills).
  - `run-cputest` = **2160/3** (both `tlb/translation_works` and
    `tlb/readonly_page_mod` PASS; only `fpu/vec_cvt_from_l` fails). This exactly
    matches the build-21 (8 KB) baseline, which was re-measured on THIS box at
    2160/3 to confirm the regression was real and is now gone.
  - The four module ratchets `ddr3test`, `ramarbtest`, `fetcharbtest`,
    `linecachetest` all PASS (they never depended on the CPU; run once for form).
  - **The IRIX boot in the simulator: init SURVIVES.** The R4400-presented CPU
    boots the PROM, `--type-on 'Option?' '1\r'` picks Start System, the IRIX 5.3
    kernel banner prints, root mounts, and init runs with **no PANIC past
    ~190M cycles** - the exact cycle window where BOTH dead 16 KB caches died
    with `PANIC: init died (why = 2, what = 0x9)`. The bit-13 VIPT alias that
    docs/40 Option 1 exists to kill is dead. Active read+write SCSI traffic
    (init reading its files, writing logs) confirms init is executing, not
    running NOPs.
* **THE OPEN QUESTION - a post-init boot wedge.** After init, at ~192.5M cycles,
  the sim wedges: the CPU spins in a USER polling loop (PC bounces
  `0f996510 <-> 0f9977d0`, then parks on `0f996510`; the harness's last-64
  user-PC dump at max-cycles shows nothing but that). The last NEW device access
  is HPC3-PBUS-PIO at 192,501,440; after that the CPU makes no new bus addresses
  and just spins to the 450M limit. That is the shape of *software waiting on a
  peripheral that never answers*, NOT cache corruption (which crashes or
  miscomputes; it does not poll patiently). `instr(unimpl-cache-op)` fired 1030
  times but is INFORMATIONAL - it is the kernel's ~1000 secondary-cache / I-cache
  ops the core NO-OPs by design (cpu.vhd:2037), and build 21 raises the same.
* **Whether the wedge is the cache or pre-existing is UNRESOLVED.** A build-21
  control boot was launched to answer it and was killed by the power loss having
  only reached the PROM menu (`ctrl_console.log` = 396 B). **First job of the new
  session: run that control (below). If build 21's 8 KB cache wedges at the same
  user PC ~192.5M, the wedge is pre-existing (a peripheral/SCSI/RTC issue, not
  the cache) and docs/40's "console begins The system is coming up" criterion is
  simply unreachable in the sim - so the cache passes the real gate (init
  survives) and you proceed to merge + fit. If build 21 instead reaches "The
  system is coming up", the 16 KB cache caused the wedge and it must be chased.**
* **Quartus is FREE now** (the MacQuadra800 fit that was running is gone -
  `tasklist | grep -i quartus` is empty). A fit can launch once the boot
  question is settled.
* **The board is UNCHANGED from docs/40:** build 21 (`62be253`, rbf md5
  `5f02393b96f9e1361d5b6da6ed7b2a93`, `output_files/sgiindy-b21-seed2.rbf`) is on
  it and VERIFIED; the board was left HALTED ("Okay to power off"),
  `SGIIndy53-wedged-fsck.img` in slot 1. Build 19 is the fallback.
  `output_files/sgiindy-b20-seed2.rbf` is the DEAD 32-byte cut - never deploy it.
* Read the auto-memory notes first, especially `irix-hardcodes-dcache-line`,
  `ki-r4600-core-assessed`, `cpu-throughput-measured`, `local-toolchain`
  (GHDL shim + CRLF traps + the signed-shift rewrite), `verilator-whole-machine`
  (the IRIX-boot recipe), `scsi-fsck-transfer-count-livelock` (a candidate for
  the wedge), `shutdown-hang-kdsp-audio`, `hardware-bug-instrument-first`,
  `quartus-ram-inference` (the fit register-count guard), `iris-oracle-local`.

You are working on an **SGI Indy (IP24) core** for MiSTer FPGA at
`C:\Temp\mistercore\sgiindy_MiSTer`, a session probably starting in the worktree
`.claude\worktrees\modest-robinson-cad59e` on branch
`claude/modest-robinson-cad59e`. **Commit to that branch, then `git -C
C:/Temp/mistercore/sgiindy_MiSTer merge --ff-only claude/modest-robinson-cad59e`
once the boot question is settled.** The reference emulator IRIS is
`C:\Temp\mistercore\iris`. A fit is 20-40 minutes. Another Claude session on this
box fits `MacQuadra800`; no fit launch while its quartus is listed.

## The bug this session fixed (so you understand what `67c31ee` did)

docs/40 Option 1 makes the 16 KB cache physically indexed by overriding the two
page-colour index bits (13:12) with the data mini-TLB's translation, and - on a
mini-TLB MISS, where the combinational `Found` bits are stale - re-reading the
tag on the `TLB_dataUnStall` clock using the resolved `Lookup` address. That
sketch was scripted last session but never run, and it had a real hole: it
overrode ONLY `EXECacheAddr(13 downto 12)`. The low index bits
`EXECacheAddr(11 downto 3)` still came from `calcMemAddr`, and **`calcMemAddr`
has already advanced past this access by the unstall clock** - decode is not
frozen for it. A cross-module trace nailed it: at the unstall,
`look=0823c000` (right) but `eca=ffff803c` -> index 003, not 0 -> the tag
re-read landed on the wrong line -> `tlb/translation_works` read stale memory.

The fix (`67c31ee`, cpu.vhd) sources 11:3 from the physical address too, only at
the unstall (the page offset is identical virtual and physical, so this is
correct in every case):

    EXECacheAddr(11 downto 3) <= TLB_dataAddrOutLookup(11 downto 3)
                                   when (TLB_dataUnStall = '1')
                              else calcMemAddr(11 downto 3);

With that, `Lookup(11:3)=0` -> index 0 -> the re-read hits the store's line, and
run-cputest returns to 2160/3.

## The queue

### 1. Settle the boot wedge (do this first)

Run the build-21 control IRIX boot and compare its wedge to the 16 KB one. The
control has to build build 21, so it overwrites the generated verilog and
obj_dir with build 21's, then must restore the branch. In one detached script
(a bare `wsl -- bash -lc` string eats `$vars` and `setsid`; use a script file):

    git checkout main -- rtl/cpu/r4300/cpu.vhd rtl/cpu/r4300/cpu_datacache.vhd rtl/cpu/r4300_wrap.vhd
    <regen>            # see Instruments
    make -C verilator cputest
    ./verilator/obj_dir/Vsim_top --prom roms/IP24_Indy/ip24prom.070-9101-011.bin \
        --no-gfx --disk 1=/mnt/c/Temp/mistercore/iris/SGIIndy53-master.img \
        --max-cycles 450000000 --stuck 250000000 --type-on 'Option?' '1\r' \
        --stop-on PANIC --console ctrl.log
    git checkout 67c31ee -- rtl/cpu/r4300/cpu.vhd rtl/cpu/r4300/cpu_datacache.vhd rtl/cpu/r4300_wrap.vhd

**A control script that checks out `main`'s cache MUST restore the branch after,
and a power loss mid-run can strand the tree on `main`'s cache - always
`git status` and re-`git checkout 67c31ee -- <the three files>` if so** (this
session's tree survived clean, but verify).

- If build 21 wedges at the SAME user PC (~`0f996510`, ~192.5M cycles): the
  wedge is pre-existing, not the cache. Go to item 2.
- If build 21 reaches `The system is coming up`: the 16 KB cache caused the
  wedge. Chase it with `--ramdump 0x88000000:0x4000000:F --exc --exc-count 2000
  --pc-user F`; disassemble the loop at `0f996510` from the guest binary
  (`efsread.py` /sbin/init or the shell, `ecoffsyms.py unix.ecoff syms` +
  `disbin.py`); suspect a cache/DMA coherency corner the tlb tests miss during
  fsck's heavy DMA, or the RTC (the boot prints "clock gained 11158 days"; a
  DELAY() spun against a stuck clock looks exactly like this).

### 2. Merge, then fit (SEED=2)

`git -C C:/Temp/mistercore/sgiindy_MiSTer merge --ff-only
claude/modest-robinson-cad59e`, then fit from the worktree. Watch the CORE clock
slack: the mini-TLB compare and now two muxes sit in front of the tag RAM's
address; build 21 had +2.772 ns. The new 11:3 mux is on the shorter (non
mini-TLB-compare) path, so it should be cheap, but confirm. If it fails timing,
try another seed before touching the RTL. On success: `output_files/sgiindy.rbf`
is build 22; commit it with a `docs/42`, the `-- SGI:` markers already in the
tree, and a row in `rtl/cpu/r4300/UPSTREAM.md`.

### 3. The board: `tests/run-cputest-hw.sh --no-build` (bench group - `ld_miss`
should stay ~13 ticks, `i_cached`/`st_cached` 1.0 CPI), then IRIX to the
desktop, toolchest, `init 0`. Before ANY redeploy of the halted board: pointer
onto the Console, `init 0`, Enter, wait for the power-off screen.

### 4-7. Unchanged from docs/40: CD-ROM attach (item 3 there), a burst-WRITE
rasteriser path, Ethernet, audio.

## Instruments / recipes (self-contained - the scratchpad from the last session
is gone)

* **GHDL shim, every session** (`/tmp` is cleared):
  `mkdir -p /tmp/llvmshim && ln -sf /usr/lib/llvm-18/lib/libLLVM.so.18.1
  /tmp/llvmshim/libLLVM-18.so.18.1 && export LD_LIBRARY_PATH=/tmp/llvmshim`.
* **Regen** `rtl/cpu/generated/r4300_wrap.v` (gitignored, sim-only; Quartus uses
  the VHDL directly). `tools/gen_r4300_verilog.sh` is checked out CRLF - copy it
  de-CRLF'd inside `tools/` and run that (`sed 's/\r$//' tools/gen_r4300_verilog.sh
  > tools/.gen_lf.sh && bash tools/.gen_lf.sh && rm tools/.gen_lf.sh`). **6-9
  min, I/O-bound on the /mnt/c drvfs, longer when a fit runs.** It should print
  `signed shift_right lowered as logical >>: 1 rewritten` (if not 1, look). The
  current generated file already matches `67c31ee` (has the `tlb_unstall` port),
  but regen after any VHDL edit and check its timestamp beats the VHDL - a stale
  generated file cost this project whole cycles before.
* All builds/runs from `.../worktrees/modest-robinson-cad59e/verilator`:
  `make cputest` (~5 min) builds `obj_dir/Vsim_top` (the whole IP24 machine with
  sim_ram, WM_OPT). `make cpuonly` builds+runs `obj_dir_cpuonly/Vtb_cpuonly`.
* **run-cputest**: `./obj_dir/Vsim_top --elf ~/cputests/build/cputest.elf
  --testdev --no-gfx --console tests/out/r4300.log --stuck 20000000`; read the
  `RESULT:` line in `tests/out/r4300.log` (the committed baseline log is missing,
  so `compare.py` throws - ignore it). `~/cputests` is a CR-stripped copy of
  `C:/Temp/mistercore/iris/cpu-tests`; the MIPS toolchain is at
  `~/.local/opt/mips-linux-gnu` (`source .../env.sh`). Bar: 2160/3.
* **IRIX boot** (the GATE): the item-1 command; ~175k cyc/s solo, much slower
  under a concurrent Quartus fit, so budget wall time generously. init survives
  = no PANIC by ~200M cycles. The harness writes the console live, prints its
  summary (last 64 user + kernel PCs, the device-access table, cpu_error flags)
  only at exit. Launch detached from a script file (`nohup ... & disown`), NOT
  `setsid` in a `wsl -lc` string.
* **Fit**: `SEED=2 bash scripts/build.sh` from the worktree, launched detached -
  `Start-Process` fails silently here; use
  `Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments
  @{CommandLine='"C:\Program Files\Git\bin\bash.exe" -c "export SEED=2; exec bash
  scripts/build.sh --log b22.log </dev/null >b22.console 2>&1"';
  CurrentDirectory='C:\Temp\mistercore\sgiindy_MiSTer\.claude\worktrees\modest-robinson-cad59e'}`.
  Quartus 17.0.2 is at `C:\intelFPGA_lite\17.0\quartus\bin64`. `scripts/build.sh`
  guards the register count between synth and fit (~39k right; it refuses the fit
  above 60k = an array became flip-flops). Quartus rewrites `SEED` into
  `sgiindy.qsf` and `LAST_QUARTUS_VERSION` too - `git checkout -- sgiindy.qsf`
  after, discard the version line. A fit needs `build_id.v`, `roms/` and
  `tests/disks/` in the worktree (all present).

## Traps paid for (do not re-pay)

* Everything in docs/38-40's lists. New this session:
  - **The docs/40 re-read overrode only bits 13:12; the low index bits 11:3
    came from a stale `calcMemAddr` at the unstall.** Fixed in `67c31ee`. If you
    ever touch `EXECacheAddr`, keep the whole 13:3 index coming from `Lookup` on
    the unstall clock.
  - `unimpl-cache-op` in the sim summary is INFORMATIONAL (~1000/boot, both
    caches) - not a failure; only `--fatal-errors` bits (default 0x12) abort.
  - A background control-boot that checks out `main`'s cache can strand the
    working tree on the 8 KB cache if interrupted; verify `git status` and the
    datacache `addr_width` (10/11 = 16 KB, 9/10 = 8 KB) after any interruption.
  - `git status` in the worktree also lists loose `*.bin`/`*.txt`/`*.ecoff`
    artifacts from docs/39's analysis; they are untracked, ignore them, do not
    commit them.
