# Work item: the KI R4600 re-vendor is DONE in the tree and passes every sim gate - fit build 23, put it on the board, merge

Paste everything below the line as the opening message of a fresh session.
This continues [44](44-resume-ki-revendor-conflicts.md). That session (Fable,
2026-09-07 evening) resolved all 34 merge conflicts, took the decisions listed
below, and took the branch through GHDL, the CPU-only bench, the cpu-tests
suite and the IRIX simulator boot. What is left is the fit (launched, see
STATE), the board, and the merge to `main`. Written 2026-09-07.

---

## STATE AT HANDOFF (read this first)

* **Branch `claude/ki-revendor`** in the worktree
  `.claude/worktrees/modest-robinson-cad59e`. `main` is still the N64-base
  build 22 (`08d13e6`) and its rbf `output_files/sgiindy-b22-seed2.rbf`
  (md5 `BD342F18E6BE032FEE53BFDC07FAE3AA`) is the board fallback. The
  session that wrote this MERGED the branch into `main` (a merge commit -
  main had its own docs/44 commit, so no fast-forward) once all four
  simulation gates of docs/43 were green; if the board rejects build 23,
  `git revert -m 1 <that merge>` puts the N64 base back.
* **Every simulation gate is GREEN on the branch:**
  - GHDL lowers the whole CPU (54722 lines; the one signed-shift rewrite).
  - `make -C verilator cpuonly`: **728 runs / 0 against expectation**, 78
    burst fills - identical to build 22.
  - cpu-tests: **2161 checks passed / 3 failed**, the only failing test
    `fpu/vec_cvt_from_l` (the known limitation). The suite had to learn the
    R4600 - see "The cpu-tests suite" below.
  - **IRIX 5.3 sim boot: init SURVIVES** (300M cycles, no PANIC), after one
    PROM trap that the new identity trips was fixed (below). The exit device
    table is IDENTICAL to the docs/42 reference (24 unclaimed addresses, same
    counts), reached **~11M cycles sooner** (last new peripheral
    HPC3-PBUS-PIO at 181.46M vs 192.50M) - the KI core does the same boot
    faster. It went further than the reference's libgen regex spin (user PCs
    in 0x1000xxxx / 0x0fb6-8xxxx / libc) and then sat in KERNEL mode from
    281.36M to the 300M cap. A rerun traced at 281.3M (`~/kicpu/irix4`)
    names it with `/unix`'s own symbols (`ecoffsyms.py unix.ecoff syms`):
    at 281.30M the kernel is in EFS serving a user program's file I/O
    (`efs_findfree`, `efs_dirlookup`, `get_buf`, `read_buf`), and at the
    cap it is in `idle` / `wait_for_interrupt` - the idle loop, waiting for
    a device completion the simulator never delivers. That is the known
    sim-only peripheral wait (`irix-sim-postinit-livelock`,
    `scsi-fsck-transfer-count-livelock`), reached later than the reference
    because the KI core got further; not a CPU fault. The board judges it.
* **Build 23 is FITTED** (SEED=2, 19:28-19:51 on 2026-09-07, via the new
  `scripts/fit_when_free.sh b23`): `output_files/sgiindy-b23-seed2.rbf`,
  34,743 ALMs (83 %), 42,770 registers, block memory unchanged, every clock
  positive, and the CORE clock's setup slack **+2.904 ns vs build 22's
  +2.459 ns** - the swap bought 0.45 ns. Synthesis: 40,989 registers before
  the fitter (build 22: 40,548), 8 "uninferred RAM" notices of which the two
  new ones (the I-cache data slices) are bypass logic - the arrays themselves
  are altsyncram in the map report. `b23.log`/`b23.console` have the detail.
* **The Indy board is `192.168.99.94`** (`scripts/local.env`), and it is NOT
  shared: the other Claude session's ssh traffic goes to `192.168.99.143`, a
  different MiSTer (MacQuadra800). **At 20:05 on 2026-09-07 the Indy board
  was OFF THE NETWORK** - no ARP entry, ping unreachable, ssh timed out for
  five minutes - i.e. powered off or unplugged, not a crashed core (a
  MiSTer's Ethernet lives on the HPS and stays up while the board has
  power). The Opus board session could not deploy; nothing on the board was
  touched. It DID rebuild the hardware suite's boot ROM for the R4600
  identity: `tests/out/hw-cputest/boot.rom` (md5
  `964d3ce593631c526d8ac4d3f2536d91`, from the patched `~/cputests`; the
  one on disk was build-21-era and would have refused PRId 0x2020). Note
  `tests/hw-cputest/build.sh` must be copied to a native FS and de-CRLF'd
  to run. If the board's address changed, `.52` and `.188` on that subnet
  answered with the stock MiSTer host key. The board is otherwise where
  docs/42 left it - build 22 or 21 on it, halted. Board control is an
  **Opus** session's job (the user's rule); see "Board".
* Read the auto-memory first: `ki-revendor-wip` (this state),
  `prom-config-ec-per-family` (the PROM trap), `ki-cpu-revendor-decision`,
  `irix-hardcodes-dcache-line`, `irix-sim-postinit-livelock`,
  `local-toolchain`, `verilator-whole-machine`, `quartus-ram-inference`,
  `hardware-bug-instrument-first`, `indy-desktop-input-recipe`,
  `shutdown-hang-kdsp-audio`, `mister-main-death-instruments`.

You are working on an **SGI Indy (IP24) core** for MiSTer FPGA at
`C:\Temp\mistercore\sgiindy_MiSTer`. The reference emulator IRIS is
`C:\Temp\mistercore\iris`. A fit is 20-40 minutes. Another Claude session on
this box fits `MacQuadra800`; no fit launch while its quartus is listed (use
PowerShell `Get-Process`, not `tasklist` under WSL - or just use
`scripts/fit_when_free.sh`, which waits).

## What the re-vendor decided (all `-- SGI:` marked; `rtl/cpu/r4300/UPSTREAM.md` is the authority)

1. **Both caches are KI's files verbatim** plus our hunks: the D-cache's
   `tlb_unstall` port folded into `ce_fetch` (the physical-index re-read), and
   the I-cache's dropped-command latch. cpu.vhd's `EXECacheAddr` override
   (13:12 from the data mini-TLB, 11:3 on the unstall clock) transfers to
   KI's 32-byte lines unchanged - index bits 13:5 are physical. The merge had
   silently kept our 16-byte geometry in the D-cache's NON-conflicting hunks,
   which is why hunk-by-hunk resolution was abandoned for "KI verbatim + our
   two marks".
2. **KI's clk93<->clk1x CDC mailbox is REMOVED** from the memory path (its
   request/response mailboxes, the 8-bit sequence tag, the 16-entry
   scoreboard, and `read4_uncachedRot` - which would have double-shifted
   against `r4300_bus.sv`'s already-shifted read data). The N64 base's direct
   FIFO consumer is back (`writefifo_rd_1x/93`, the `mem_done_1` edge).
   **KI's scheduler above the FIFO is KEPT** (held payload, 4-entry writeback
   staging queue, retained refill/stage-1 requests, stage-4 ready/valid) - it
   is what makes a 32-byte line's four-beat writeback safe against FIFO
   pressure; the N64 base's blocking rule only guaranteed room for two beats.
3. **Identity R4600**: `PRESENT_AS_R4600` (renamed from `PRESENT_AS_R4400`) in
   cpu_cop0 / cpu / cpu_FPU. PRId = KI's `COP0_PRID_R4600` 0x2020, FIR 0x2020,
   **48 TLB entries re-applied** (KI has 32), Config 16K/16K with **32-byte
   lines on both** (`"11001001011"`, true for both caches now), COP2
   unusable, MIPS IV COP1 codes -> RI. KI's `kusegUnmapped` (ERL) and
   `chainedDelaySlot` fixes kept.
4. **Config.EC = 0 under R4600** - the PROM trap. Its clock-setup routine at
   0xBFC312F8 divides the measured MHz by a per-family table indexed by
   Config(30:28): R4000/R4400 {2,3,4,6,8,2,3,4}, R4600/R4700/R5000
   {2,3,4,5,6,7,8,0}. The N64 base's reset value 7 was "divide by 4" as an
   R4400 and a zero divisor as an R4600 -> `break 7` at 0xBFC313DC,
   "Breakpoint exception at address 0x0" before the diagnostics banner. An
   Indy R4600 runs SysAD at half the pipeline clock: EC = 0.
5. `DEBUG_TRACE => false` and every `debug_*` port open in `r4300_wrap.vhd`;
   `ALECK64 => '0'`; KI's `cpu_mul.vhd` (1-stage) dropped in favour of
   `rtl/cpu/prim/cpu_mul.vhd` (2-stage, the one that has been fitted);
   KI's `SyncFifoFallThroughMLAB.vhd` taken; `tools/diff_upstream.sh` diffs
   against the KI checkout (`/c/Temp/mistercore/Arcade-KillerInstinct_MiSTer`).

## The cpu-tests suite and the R4600

The suite selects every expectation by PRId and had no case for imp 0x20: it
refused to run (rc=127), and once taught, `identity/cache_geometry` and
`cache/geometry` failed on the 16-byte line size an R4400 has. Patched in
BOTH the build copy `~/cputests` (WSL) and the source `iris/cpu-tests`
(**uncommitted there** - `harness/testlib.c` maps IMP_R4600 -> CPU_R4400;
`tests/identity/identity.c` and `tests/cache/cache.c` expect PRId/FIR 0x2020
and 32-byte lines under imp 0x20). Commit that in the iris repo, or the next
refresh of `~/cputests` loses it.

## The queue

### 1. Confirm build 23 (in progress)

Read `b23.status`/`b23.console`. Register count ~39k; the CORE clock slack
(compare +2.459 ns). If it fails timing, try SEED=1/3 with
`SEED=n bash scripts/fit_when_free.sh b23s<n>` before touching RTL. Commit the
rbf as `output_files/sgiindy-b23-seed2.rbf` with a row in UPSTREAM.md's
Results.

### 2. Board (Opus session)

Deploy build 23
(`scripts/deploy.sh`, `scripts/mount.sh --disk1 <image>` - docs/42 had
`SGIIndy53-wedged-fsck.img` in slot 1 on the board; the master image is
`iris/SGIIndy53-master.img`), then in order:
* `tests/run-cputest-hw.sh --no-build` - the bench group: `ld_miss` should be
  ~13 ticks or better, `i_cached`/`st_cached` 1.0 CPI. **This is the number
  the swap was for**: KI's cache/fetch path vs build 22's.
* IRIX to the desktop, toolchest, `init 0` (`indy-desktop-input-recipe`,
  `shutdown-hang-kdsp-audio`). `hinv` should say R4600 / FPU R4600 / 16 KB
  caches. Before ANY redeploy of a halted board: pointer onto the Console,
  `init 0`, Enter, wait for "Okay to power off".
* If it fails where build 22 did not: the kernel-mode phase after 281M in the
  sim is the first suspect (`~/kicpu/irix4`), then the writeback staging
  queue / 4-beat writeback under real DDR3 latency (the sim never has a slow
  responder), then `chainedDelaySlot`. Instrument before guessing
  (`hardware-bug-instrument-first`); build 22 is the fallback.

### 3. Merge

`git -C C:/Temp/mistercore/sgiindy_MiSTer merge --ff-only claude/ki-revendor`
once the board boots to the desktop. Then a docs/46 that records the board
numbers, and update auto-memory `ki-revendor-wip` to "done".

### 4. Sim-only, low priority

The post-init phase: the reference spins in libgen regex from ~192.6M; the KI
run goes further and then idles in the kernel from 281.4M. The board boots
IRIX fine on the N64 base, so this is a sim/peripheral issue
(`irix-sim-postinit-livelock`), unless the board says otherwise.

## Recipes (self-contained; scripts in this session's scratchpad are NOT durable - recreate from these)

* **Native-FS build tree** `~/kicpu` (WSL): `rsync -a --delete --exclude
  '.ghdl' --exclude 'obj_*' --exclude '*.log' --exclude generated $WT/rtl
  $WT/tools $WT/verilator ~/kicpu/`, de-CRLF `verilator/Makefile`,
  `tools/*.sh` and every `rtl/**/*.vhd` (`sed -i 's/\r$//'`), GHDL shim
  (`mkdir -p /tmp/llvmshim && ln -sf /usr/lib/llvm-18/lib/libLLVM.so.18.1
  /tmp/llvmshim/libLLVM-18.so.18.1 && export LD_LIBRARY_PATH=/tmp/llvmshim`),
  `bash tools/gen_r4300_verilog.sh` (~10 s), `make -C verilator cpuonly`
  (runs the bench itself), `make -C verilator cputest` (obj_dir/Vsim_top).
* **cpu-tests**: `source ~/.local/opt/mips-linux-gnu/env.sh; export
  PATH=~/.local/opt/mips-linux-gnu/usr/bin:$PATH; make -C ~/cputests
  CROSS=mips-linux-gnu- -j8`, then `obj_dir/Vsim_top --elf
  ~/cputests/build/cputest.elf --testdev --no-gfx --console out/r4300.log
  --stuck 20000000`; read the `RESULT:` line. `set -e` in a wrapper kills the
  script on the sim's own failure count - don't.
* **IRIX boot**: `obj_dir/Vsim_top --prom /mnt/c/.../roms/IP24_Indy/
  ip24prom.070-9101-011.bin --no-gfx --disk 1=/mnt/c/Temp/mistercore/iris/
  SGIIndy53-master.img --max-cycles 300000000 --stuck 250000000 --type-on
  'Option?' '1\r' --stop-on PANIC --console F --ramdump 0x88000000:0x4000000:F
  --exc --exc-count 2000 --pc-user F` - ~40 min to 300M (~120k cycles/s).
  Launch from a script file under **`nohup ... & disown`** - a background
  subshell without nohup died silently when the `wsl` session closed.
  Milestones: PROM banner ~6 min, menu ~10, IRIX banner at ~144M cycles.
* **PROM disassembly**: `python3 tools/misterdeploy/disbin.py <prom.bin>
  0xbfc00000 --from 0xbfc31280 --to 0xbfc31420 --mark 0xbfc313dc` (capstone;
  the WSL cross objdump is missing a shared library).
* **Fit**: `SEED=2 bash scripts/fit_when_free.sh b23` launched detached via
  `Invoke-CimMethod Win32_Process Create` with `</dev/null >b23.console 2>&1`
  inside the bash `-c` string (Start-Process fails silently).
* Traps: a `wsl -- bash -c '...'` string eats `$vars` (script files only);
  a bash heredoc in the Bash tool with an unbalanced `'` inside a Python
  string fails to parse - put long Python in a file; Python on Windows
  writes CRLF (git normalises, WSL scripts need de-CRLF); backticks in a
  double-quoted `git commit -m` are command-substituted (use `-F -`).
