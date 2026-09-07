# Work item: FINISH the KI R4600 re-vendor - the 3-way merge is committed, 34 conflicts remain to resolve - WITH FABLE

Paste everything below the line as the opening message of a fresh **Fable**
session. This continues [43](43-resume-ki-cpu-revendor.md) (the plan) and the
work done 2026-09-07: the three-way merge of the KI base + our SGI changes is
done and committed WITH conflict markers; the job now is to resolve the 34
conflicts, reconcile the data cache, wire the lowering, and validate. Fable, not
Opus. Written 2026-09-07.

---

## STATE AT HANDOFF (read first)

* **Branch `claude/ki-revendor`, tip `e825e18`** (in the worktree
  `.claude/worktrees/modest-robinson-cad59e`). This is a WIP commit that DOES
  NOT BUILD - `rtl/cpu/r4300/*.vhd` carry `<<<<<<<` conflict markers.
* **`main` is safe at `08d13e6`** - the N64-based build 22 (16 KB physical
  D-cache), verified in sim + timing. `output_files/sgiindy-b22-seed2.rbf`
  (md5 `BD342F18E6BE032FEE53BFDC07FAE3AA`) is the pre-swap board baseline. Do
  the KI work on the branch; do not break main.
* **The three inputs (all durable):**
  - base = N64_MiSTer @ `adbf9b5` cloned to `~/repos/N64_MiSTer` (WSL home).
  - theirs = KI = `/c/Temp/mistercore/Arcade-KillerInstinct_MiSTer/rtl/cpu/`
    (git @ `5c443bd`, R4600).
  - ours = our N64+SGI tree, in git history (`main` / this branch's parent
    `08d13e6`), 78 `-- SGI:` marks across 7 files.
* **How the merge was produced (reproducible; RUN IT IN GIT BASH, NOT WSL -
  WSL's git merge-file silently wrote empty files):**
  ```
  git merge-file -p -L KI -L N64base -L OURS <KI/f> <N64base/f> <ours/f> > merged/f
  ```
  De-CRLF all three inputs first (`tr -d '\r'`). This yields KI base + our
  (ours-minus-base) SGI changes, with `<<<<<<<` where KI and we edited the same
  base region.

## THE 34 CONFLICTS TO RESOLVE (the core work)

Conflict-start line numbers in the committed files (they shift as you edit -
re-grep `^<<<<<<<` after each fix):

| File | # | conflict-start lines (at commit) |
|---|---|---|
| `cpu.vhd` | 12 | 77 92 199 1020 1904 1930 2359 2473 3344 3844 3900 5168 |
| `cpu_datacache.vhd` | 11 | 93 102 153 178 194 225 263 412 423 458 470 |
| `cpu_cop0.vhd` | 8 | 53 204 521 652 895 969 1636 1783 |
| `cpu_instrcache.vhd` | 3 | 100 188 333 |

`cpu_FPU.vhd`, `cpu_FPU_sqrt.vhd`, `cpu_TLB_data.vhd`, `cpu_TLB_instr.vhd`,
`divider.vhd`, `functions.vhd`, `export.vhd` merged CLEAN (0 conflicts) and
already carry KI base + our SGI changes. `cpu_mul.vhd` was added from KI.

At each conflict the three sections are KI / N64base / OURS. Decide per hunk:
keep KI's line (a KI improvement in a region we did not touch - rare, since
those merged clean), keep OURS (our SGI change in a region KI also touched),
or COMBINE (both changes needed - e.g. KI's FetchIndex timing rework AND our
physical-index override both live in the fetch/cache-index code). Every kept
SGI hunk must still carry its `-- SGI:` comment; UPSTREAM.md explains each.

## THE DATA CACHE IS THE HARD ONE (11 of the 34 conflicts + cpu.vhd cache hunks)

This is a SEMANTIC clash, not a textual one - do not just pick a side:
* **OURS** = 16 KB, **16-byte** lines, direct-mapped, **physically indexed**
  (docs/40-42): tag RAM `addr_width` 10, data 11, index 13:4, the physical-
  index override lives in `cpu.vhd` (`EXECacheAddr(13 downto 12)` and
  `(11 downto 3)` from `TLB_dataAddrOutLookup` on `TLB_dataUnStall`) + the
  `tlb_unstall` port folded into `ce_fetch`.
* **KI** = 16 KB, **32-byte** lines, direct-mapped, **virtually indexed** on
  13:5 (`read_hit` compares `tag(19:2)` vs `RW_addr(31:14)`) - this is the
  init-KILLER (bit-13 VIPT alias, `irix-hardcodes-dcache-line`).
* **Target** = KI's 32-byte geometry (R4600 IRIX hard-codes a 32-byte D-cache
  line) made PHYSICALLY INDEXED by carrying our override onto it. So: keep KI's
  32-byte line structure, and re-apply our physical-index approach (override the
  page-colour index bits from the data mini-TLB, re-read tags on the unstall).
  The index math differs from our 16-byte version - work it through for 32-byte
  lines. **Gate it on the IRIX sim boot: init must survive** (both dead 16 KB
  attempts are in `irix-hardcodes-dcache-line`; do the boot before any fit).

## OTHER KNOWN ITEMS

1. **Identity - go R4600.** KI is natively R4600 (PRId imp 0x20, "IDT79R4600").
   Our `PRESENT_AS_R4400` layer is 28 `-- SGI:` marks in cpu_cop0 + cpu + cpu_FPU
   (PRId 0x0440, FIR rev 5, Config, COP2-unusable). For R4600, most of that
   goes AWAY (KI already is R4600) - keep only what IRIX needs: 48 TLB entries
   (KI has 32! `TLB_fetchSource` is 4:0 in KI, 5:0 in ours - RE-APPLY the
   widening, it is in the cop0/TLB conflicts), and the R4600 D-cache 32-byte
   line (native). Verify PRId 0x2000-ish is what an R4600 Indy reports and IRIX
   keys off it (auto-memory `irix-hardcodes-dcache-line` has the R4600 path).
2. **Address widening (29 -> 32 bit).** KI truncates to 29 bits everywhere
   (`"000" & mem1_address(28 downto 0)`, `PC(63 downto 29) & ...`). IP24 high
   memory is at `0x20000000`; re-apply the cop0 `TLB_fetchAddrOutMasked`
   pass-through and the cpu.vhd kseg0/kseg1-strip relocation (UPSTREAM "Machine
   size"). These are among the cpu/cop0 conflicts.
3. **Five interrupt lines** (`irqLines(4:0)`), **KSEG0/Config.K0 cacheability**,
   the **R4000-manual bug fixes** (FPU is a clean merge; the cpu ones are in the
   conflicts) - all from UPSTREAM.md.
4. **`cpu_mul.vhd`**: N64's is 271 lines, KI's is 29, and our r4300/ had NONE
   (our build gets `cpu_mul` from somewhere - CHECK: does our `cpu.vhd` inline
   it, or does `tools/gen_r4300_verilog.sh` pull it? the generated verilog has a
   `cpu_mul` module). Reconcile before trusting KI's 29-line file.
5. **prim/mem shims**: KI ships `dpram.vhd`/`RamMLAB.vhd` in `rtl/cpu/`; we use
   `rtl/cpu/prim/` + `entity mem.*`. Keep OUR shims; make the KI files reference
   `entity mem.dpram`/`mem.RamMLAB` as ours do (check the entity library names).

## THEN: lowering + validate (the gates, in order)
1. Update `tools/gen_r4300_verilog.sh` + `rtl/cpu/r4300_wrap.vhd` for the KI port
   list (new `cpu_mul`, `mem_size`, the I-cache `read_index1/2`). Regen on the
   NATIVE WSL FS (40 s - `local-toolchain`); check the timestamp beats the VHDL.
2. `make -C verilator cpuonly` green.
3. cpu-tests **2160/3** (`~/cputests`, `--testdev`). Bar.
4. **IRIX sim boot: init SURVIVES** past ~190M (docs/42 recipe; `--no-dcache`
   control). The post-init livelock at ~192.6M is PRE-EXISTING
   (`irix-sim-postinit-livelock`), not a regression.
5. Fit SEED=2; the CORE clock should now have MORE headroom than build 22's
   +2.459 ns (the point of the swap - KI's FetchIndex + 100 MHz tuning). Register
   guard ~39k, refuses >60k. Do NOT fit while the MacQuadra800 session's quartus
   is listed (use PowerShell `Get-Process`, NOT `tasklist` under WSL).

## Recipes / traps (self-contained)
* **GHDL shim** every session; **native-FS build** (40 s); **IRIX boot**;
  **cpu-tests**; **fit via `Invoke-CimMethod`** - all exactly as in docs/43.
* **A `wsl -- bash -c '...'` string eats `$vars`** even single-quoted - run WSL
  work from a script FILE. **git merge-file must run in GIT BASH, not WSL**
  (WSL wrote empty output). `tasklist` is not on PATH in WSL.
* Read auto-memory first: `ki-cpu-revendor-decision`, `ki-revendor-wip`,
  `irix-hardcodes-dcache-line`, `irix-sim-postinit-livelock`, `local-toolchain`,
  `verilator-whole-machine`, `quartus-ram-inference`, `hardware-bug-instrument-first`.
* To re-see any conflict's three sides cleanly: the inputs are reproducible -
  `~/repos/N64_MiSTer/rtl/<f>` (base), KI repo (theirs), `git show 08d13e6:rtl/cpu/r4300/<f>`
  (ours).
