# Work item: FULL RE-VENDOR of the CPU onto the Killer Instinct R4600 base (the user's explicit choice) - do this WITH FABLE

Paste everything below the line as the opening message of a fresh **Fable**
session. The user wants this task done with Fable, not Opus (Opus is for board
control). This follows [42](42-resume-merge-fit-board.md): that session settled
the docs/41 boot question (the post-init sim wedge is pre-existing, the 16 KB
physical D-cache passes), merged the 16 KB cache to `main`, launched the build-22
fit - and then the user directed a NEW primary task: **swap our CPU from the
vendored N64_MiSTer base to the Killer Instinct R4600 base.** Written 2026-09-07.

---

## THE DECISION (read first, it is settled)

The user chose, informed of the trade-off, a **full re-vendor** of the CPU onto
`MiSTer-devel/Arcade-KillerInstinct_MiSTer`'s R4600 - NOT a cherry-pick of KI's
improvements onto our N64 base. Rationale: KI is actively timing-tuned for
100 MHz, carries the `FetchIndex` I-cache critical-path optimization, presents
natively as R4600 (a real Indy CPU IRIX 5.3 supports), and gives us a live
upstream to track. See auto-memory `ki-cpu-revendor-decision`. Do not re-open the
cherry-pick-vs-swap question; execute the swap.

## STATE AT HANDOFF

* **`main` is at `e1c04f8`** (this session): our N64-based CPU with the 16 KB
  physically-indexed D-cache, merged from the branch. cpu-tests 2160/3,
  cpuonly 728/0, IRIX init survives in sim. The **build-22 fit** (SEED=2,
  N64 base) was launched via a detached orchestrator that waits for the
  MacQuadra800 session's Quartus to free; check `b22.status` / `b22.console` and
  `output_files/sgiindy.rbf`. **This N64-base build is the pre-swap board
  BASELINE / fallback - keep it; the KI swap is a parallel new line, ideally on
  a fresh branch.**
* **Our current CPU** = `MiSTer-devel/N64_MiSTer` `rtl/` @ `adbf9b5` (2026-08-15),
  vendored into `rtl/cpu/r4300/`, with **78 `-- SGI:` marks** and the docs/40-42
  D-cache changes. `rtl/cpu/r4300/UPSTREAM.md` is the authoritative list of every
  deviation and WHY; `tools/diff_upstream.sh <N64checkout>` prints the live delta.
* **The KI CPU** = `/c/Temp/mistercore/Arcade-KillerInstinct_MiSTer/rtl/cpu/`
  (git, HEAD `5c443bd` 2026-09-05). Files: `cpu.vhd` (5193 lines vs our 3840 -
  KI adds a debug-trace system + FetchIndex), `cpu_cop0.vhd`, `cpu_datacache.vhd`,
  `cpu_instrcache.vhd`, `cpu_FPU.vhd`, `cpu_FPU_sqrt.vhd`, `cpu_mul.vhd` (SEPARATE
  file, instantiated in cpu.vhd), `cpu_TLB_data.vhd`, `cpu_TLB_instr.vhd`,
  `divider.vhd`, `functions.vhd`, `export.vhd`, `dpram.vhd`, `RamMLAB.vhd`,
  `SyncFifoFallThroughMLAB.vhd`.

## THE LOAD-BEARING TRAP (verified this session, do not rediscover)

**KI's `cpu_datacache.vhd` IS the init-killer.** It is 16 KB / 32-byte,
direct-mapped, VIRTUALLY indexed on bits 13:5 (`tag_address_b <= tag_addr(13
downto 5)`, `read_hit` compares `tag_compare(19 downto 2)` vs `RW_addr(31 downto
14)`). That is exactly "Killer Instinct's 16 KB of 32-byte lines" that
UPSTREAM.md and auto-memory `irix-hardcodes-dcache-line` record as KILLING IRIX
init via the bit-13 virtual-index alias (deterministic panic ~188M cycles). KI
runs a game that never hits the alias; IRIX does. So a naive re-vendor REGRESSES
the D-cache to the init-killer. **You MUST carry the docs/40-42 physical-index
fix onto the KI cache** (override cache index bits 13:12 from the data mini-TLB's
`TLB_dataAddrOutLookup`, and bits 11:3 too on the `TLB_dataUnStall` clock; add
the `tlb_unstall` port + fold it into `ce_fetch`). Under R4600 identity IRIX uses
a 32-byte D-cache line (hard-coded from PRId, NOT `Config.DB`), which MATCHES
KI's 32-byte geometry - so on the KI base the physical-index fix targets 32-byte
lines, not the 16-byte lines our R4400 build used. Our D-cache work transfers.

## THE PLAN (phased; validate at each gate before the next)

Work on a fresh branch (a `git worktree` as now). Keep `main`'s N64 build 22.

### Phase 0 - snapshot the delta to re-apply
Get a clean N64_MiSTer checkout at `adbf9b5` (or `~/repos/N64_MiSTer`) and run
`tools/diff_upstream.sh` to capture EVERY current `-- SGI:` hunk - this is the
patch set to re-apply onto KI. Read UPSTREAM.md end to end; its tables ARE the
work list.

### Phase 1 - drop in the KI base
Copy KI's `rtl/cpu/*.vhd` over `rtl/cpu/r4300/` (mind the file-set delta:
`cpu_mul.vhd` is new-and-separate; reconcile `dpram.vhd` / `RamMLAB.vhd` / the
`rtl/cpu/prim/` megafunction shims). Rewrite UPSTREAM.md provenance to KI @
`5c443bd`. Do NOT keep KI's arcade debug-trace bus unless it is free - it is
~900 wires that anchor Fmax (KI gated it behind `DEBUG_TRACE`); set that false.

### Phase 2 - re-apply the SGI changes, in dependency order
From UPSTREAM.md, grouped (78 marks today):
1. **Identity** - DECIDE R4400 vs R4600. Recommend **R4600** (KI is natively
   R4600 imp 0x20; matches KI's 32-byte cache line for IRIX; a valid Indy CPU).
   That flips `PRESENT_AS_R4400` across cpu_cop0 / cpu / cpu_FPU (PRId, FIR,
   Config geometry to 16 KB/32-byte, COP2-unusable). Confirm 48 TLB entries
   (both parts have 48) survive.
2. **Address widening** - KI truncates physical addresses to 29 bits everywhere
   (`"000" & mem1_address(28 downto 0)`, `PC(63 downto 29) & (PC(28 downto 0)+4)`).
   IP24 high memory is at `0x20000000`; the PROM `szmem` needs the full width.
   Re-apply the cop0 `TLB_fetchAddrOutMasked` pass-through and the cpu.vhd
   kseg0/kseg1-strip relocation (UPSTREAM "Machine size").
3. **KSEG0 / Config.K0 cacheability** gate (the PROM resets K0=2 uncached).
4. **Five interrupt lines** - `irqLines(4 downto 0)` replacing irqRequest /
   irqCartRequest; `Cause.IP(6:2)` assigned every cycle; `preNMI` tied low.
5. **R4000-manual bug corrections** - exl-preserves-epc; LWC1/etc alignment;
   byte-store AdEL-by-DIRECTION (the Int-vs-AdES bug); 0x33->PREF; FPU NaN /
   signed-zero / div-by-zero polarity (9 marks). Re-verify each against its named
   cpu-test.
6. **The physical-index D-cache fix** (the trap above), on KI's 32-byte cache.
7. **Memory-path integration** to `rtl/cpu/r4300_bus.sv` + `ram_arb.sv` (burst
   fills). KI's mem port is the same Robert Peip port plus a `mem_size(2:0)` and
   CDC `ram_*` signals - reconcile against our arbiter; do not adopt KI's CDC
   mailbox wholesale unless it maps cleanly.

### Phase 3 - lowering + wrapper
Update `tools/gen_r4300_verilog.sh` and `rtl/cpu/r4300_wrap.vhd` to KI's port
list (the new `cpu_mul`, `mem_size`, the renamed I-cache `read_index1/2`). Regen
on the NATIVE WSL FS (40 s - see `local-toolchain`) and confirm the timestamp
beats the VHDL; watch for the `signed shift_right lowered ... 1 rewritten` line.

### Phase 4 - validate (the gates, in order)
1. `make -C verilator cpuonly` green.
2. cpu-tests **2160/3** (bar; only `fpu/vec_cvt_from_l` may fail).
3. **IRIX sim boot: init SURVIVES** (no PANIC past ~190M) - the real gate; use
   the docs/42 whole-machine recipe, `--no-dcache` as a control if it dies. The
   post-init livelock at ~192.6M is pre-existing (`irix-sim-postinit-livelock`),
   not a regression - do not chase it.
4. Fit SEED=2 and check the CORE clock now makes timing with headroom (the point
   of the swap); register guard ~39k, refuses >60k.

## Instruments / recipes (self-contained)
* **Native-FS build** (40 s not 14 min): `rsync -a --exclude '.ghdl' --exclude
  'obj_*' --exclude '*.log' $WT/rtl $WT/tools $WT/verilator ~/kicpu/`, de-CRLF
  the Makefile + `tools/gen_r4300_verilog.sh`, delete the copied generated
  verilog, regen, `make -C ~/kicpu/verilator wholemachine2`. Run the sim from
  that copy with absolute `/mnt/c/...` `--prom` / `--disk`. See `local-toolchain`.
* **GHDL shim** every session: `mkdir -p /tmp/llvmshim && ln -sf
  /usr/lib/llvm-18/lib/libLLVM.so.18.1 /tmp/llvmshim/libLLVM-18.so.18.1 &&
  export LD_LIBRARY_PATH=/tmp/llvmshim`.
* **IRIX boot**: `obj_wm2/Vsim_top --prom roms/IP24_Indy/ip24prom.070-9101-011.bin
  --no-gfx --disk 1=/mnt/c/Temp/mistercore/iris/SGIIndy53-master.img
  --max-cycles 450000000 --type-on 'Option?' '1\r' --stop-on PANIC
  --console F --ramdump 0x88000000:0x4000000:F` (~50 min; init ~190M). Launch
  detached from a script FILE (`nohup ... & disown`), never `setsid` in a
  `wsl -lc` string; `$vars` in a `wsl -- bash -c '...'` string are eaten even
  single-quoted - always use a script file.
* **cpu-tests**: `obj_dir/Vsim_top --elf ~/cputests/build/cputest.elf --testdev
  --no-gfx --console tests/out/r4300.log --stuck 20000000`; read the `RESULT:`
  line. `~/cputests` is a CR-stripped copy of `iris/cpu-tests`.
* **Fit** (do NOT launch while the MacQuadra800 session's quartus is listed):
  `SEED=2 bash scripts/build.sh --log b.log`, launched detached via
  `Invoke-CimMethod Win32_Process Create` with `</dev/null >console 2>&1` inside
  the bash `-c` string (Start-Process fails silently). `git checkout -- sgiindy.qsf`
  after (Quartus rewrites SEED + LAST_QUARTUS_VERSION).
* **Guest binaries** (free instruments): `efsread.py IMAGE get /unix|/sbin/init|
  /usr/lib/libgen.so`, then `ecoffsyms.py` (kernel) / mips-objdump (the .so's,
  which are ELF). libgen text base 0x0f990000, libc 0x5ff20000, rld 0x0ff60000.

## Read the auto-memory first
`ki-cpu-revendor-decision` (this decision + the full re-apply list),
`irix-hardcodes-dcache-line` (the D-cache trap), `irix-sim-postinit-livelock`
(the pre-existing wedge - not a regression), `ki-r4600-core-assessed`,
`local-toolchain`, `verilator-whole-machine`, `quartus-ram-inference`,
`hardware-bug-instrument-first`, `iris-oracle-local`.

## Traps paid for (do not re-pay)
* Everything in docs/38-42. Specific to this task:
  - **KI's D-cache is the init-killer** - carry the physical-index fix (above).
  - **KI truncates to 29 bits** - re-apply the IP24 address widening or POST
    reports "No usable memory found".
  - **Build on the native WSL FS**, not /mnt/c (40 s vs 14 min).
  - **A `wsl -- bash -c '...'` string eats `$vars`** even single-quoted; run WSL
    work from a script file. `tasklist` is NOT on PATH inside WSL - use PowerShell
    `Get-Process` to check for quartus, not `tasklist` piped through WSL.
  - Keep `main`'s N64 build 22 as the fallback; do the swap on a branch.
