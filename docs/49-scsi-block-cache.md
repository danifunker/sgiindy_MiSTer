# Work item: the SCSI block cache - build 26

Paste everything below the line as the opening message of a fresh session.
This continues [48](48-resume-missing-hardware-scsi-cache.md) §3 (the
MacQuadra800 SCSI work and what transfers). Written 2026-09-08.

---

## STATE AT HANDOFF (read this first)

* **What was built:** `rtl/scsi/scsi_cache.sv`, the MacQuadra800 per-target
  read-ahead / write-behind block cache, ported nearly verbatim and wired
  into `rtl/scsi/sgi_scsi.sv` between the three scsi.v targets (IDs 1, 2, 6)
  and the `sd_*` ports. scsi.v is untouched. Every hps_io transaction is now
  an aligned 8-sector group (`sd_blk_cnt = 7`, 4 KB through the 13-bit
  `sd_buff_addr`) for a miss, a prefetch or a wholly dirty flush; the
  guest's writes are acked from block RAM (768 clocks) and flushed behind
  its back. The CD slot passes straight through (`CACHE_CD = 0`) and reads
  through scsi.v's own 32-sector ring as before. Cost: 64 M10Ks for the
  store plus the two state machines (§4 has the fit numbers).
* **The OSD switch:** `O[17] SCSI cache: On / Off` (`scripts/setopt.sh
  scsicache=off`). Off = every request a single-sector passthrough, the
  pre-build-26 path, on the same bitstream: that is how the cache is
  measured against no cache, and the user's way out if it ever misbehaves.
  The bypass flushes a slot's dirt before its first bypassed request and
  drops the slot's window so nothing written past the cache is ever served
  stale once it is back on (`tb_scsi_cache` T10).
* **The instrument:** `sgi_scsi.sv` counts hps_io transactions by direction,
  cycles with one outstanding, cycles a target spent waiting on its block
  port, cycles the SCSI bus was busy and in a DATA phase, bytes across it,
  and the cache's hits / misses / writes; beacon words 16-20 (ver 9), read
  as one line by `bcnread.py --stats`, logged at every poll by
  `scripts/irixrate.sh --stats`. Two readings a boot apart are the boot's
  disk time - the ceiling of any further disk work, and the number docs/48
  said to measure before promising one.
* **Gates passed before the fit (all on 2026-09-08):** `tb_scsi_cache`
  285,472 checks / 0 failures in both shapes (the Mac's, and ours with no CD
  store); PROM-level `tests/run-scsi.sh`, `run-scsiwr.sh` (five phases,
  writes read back through the cache), `run-cdrom.sh`, and `run-scsi` again
  with `--scsi-nocache`; the whole-machine IRIX 5.3 sim boot to 230M cycles.
  Results in §3.
* **Board:** §4.
* **Still open from docs/46-48, unchanged:** the R4600 patch to the
  cpu-tests suite is UNCOMMITTED in `C:\Temp\mistercore\iris\cpu-tests`; the
  16 KB two-way I-cache is a performance follow-up; the sim never reaches
  "The system is coming up"; the missing-hardware list in docs/48 §2.

## 1. What the cache is, in this core's terms

`rtl/scsi/README.md` has the working description; the Mac's
`docs/scsi-block-cache.md` (MacQuadra800_MiSTer, tip `40c3f13`) the design
note and its coherency rules. The points that matter for anyone touching it:

* **Where it sits.** The targets' `io_rd/io_wr/io_ack/sd_buff_*` are the
  cache's engine side (`e_*`, slot 0/1/2 = ID 1/2/6, `SLOT*_ID` in
  sgi_scsi.sv); the cache's platform side (`p_*`) is what sgi_indy and
  sgiindy.sv now carry to hps_io: `scsi_sd_blk_cnt` (one value, every menu
  slot gets it - hps_io reads the one whose request line is up), the full
  13-bit `sd_buff_addr`, and `scsi_cache_bypass` from `status[17]`.
  `sd_lba[k]` and `sd_buff_din[k]` are the cache's one live transaction on
  every ID's line, which is correct by construction (one transaction at a
  time) and retires the docs/29 per-slot mux.
* **What changed in the ported file, all marked `SGI:`:** `img_blocks` (the
  32-bit block count) is the mount-size tag instead of hps_io's 64-bit
  `img_size`; the stats are 32 bits plus `stat_writes`; `bypass`; the
  prefetcher stops while bypassed; `FLUSH_IDLE` is the same 4096 cycles,
  82 us at 50 MHz. `SECT2` is 0 when the CD slot passes through, so the
  store is 128 sectors = 64 M10Ks, not the Mac's 144.
* **Timing contract the harness had to learn.** A flush answers one cycle
  behind `sd_buff_addr` (the store's registered read); a *passthrough write*
  answers two (the cache's address register in front of the target's
  registered read). hps_io samples a whole SPI word after it advances the
  address, so both are fine on hardware; `verilator/sim_scsi.h` used to
  sample exactly one cycle behind and now holds each write address for four
  (`WR_HOLD`), and the bench's device model does the same. The Mac bench
  never wrote through the passthrough (its CD is read-only), which is why
  it never noticed.
* **What does not transfer** is unchanged from docs/48 §3: the 53C96 PDMA
  fixes, the Mac ROM behaviours, the Main fork's CD paths (`MB_CD = 0`).

## 2. Files

| | |
|---|---|
| `rtl/scsi/scsi_cache.sv` | the cache (ported) |
| `rtl/scsi/sgi_scsi.sv` | the wiring, the slot map, the counters, beacon words |
| `rtl/sgi/sgi_indy.sv`, `sgiindy.sv` | the new ports; `O[17]`; `sd_blk_cnt` to hps_io; beacon words 16-20, ver 9, `BCN_WORDS = 21` |
| `files.qip` | the new file |
| `verilator/tb_scsi_cache.sv`, `Makefile` (`tb_scsi_cache`, `tb_scsi_cache_nocd`) | the bench, ported, plus T10 (bypass) |
| `verilator/sim_scsi.h`, `sim_top.sv`, `sim_cputest.cpp` | multi-block harness, `--scsi-nocache` |
| `tools/misterdeploy/bcnread.py` | words 16-20, `--stats` |
| `scripts/irixrate.sh --stats`, `scripts/setopt.sh scsicache=`, `scripts/diskpair.sh` | the board measurement (deploy, boot with the cache on, boot with it off) |
| `rtl/scsi/README.md` | the description |

## 3. Simulation results

All on 2026-09-08 in `~/kicpu` (WSL, native FS), Verilator 5.020, on the
committed RTL (`02265d3`, with `c_live`):

| Gate | Result |
|---|---|
| `make tb_scsi_cache` (the Mac's shape: CD slot cached, 64/64/16) | 285,472 checks, 0 failures; T1 prefetch 24 hits / 1 miss / 5 device reads, T9 32 sequential reads in 7 transactions, 64 writes in 8, T10 bypass clean |
| `make tb_scsi_cache_nocd` (ours: CD passes through, no CD store) | 285,472 checks, 0 failures |
| `tests/run-scsi.sh` (PROM boot, disk on ID 1, hinv) | PASS, no forbidden line |
| `tests/run-scsiwr.sh` (five phases: WRITE/READ 6 and 10, 4 blocks, descriptor chains, a 2 KB CD block) | PASS - every write read back through the cache byte for byte |
| `tests/run-cdrom.sh` | PASS |
| `run-scsi` again with `--scsi-nocache` | dks0d1s0 / SCSI Disk / SCSI CDROM all present, 0 forbidden lines |
| IRIX 5.3 whole-machine boot, 230M cycles (`gate4.sh irix7`) | init survives; console IDENTICAL to build 25's run (`irix6`), stdout identical with cycle numbers stripped (same exception trace, same exit device table, last new peripheral HPC3-PBUS-PIO at 182.17M vs 182.12M) |

What the harness found on the way (both fixed before the fit of record):
the passthrough write's two-cycle read-back (§1), and **word 0 lost when the
first word arrives with the ack** - the PROM printed "dks0d1s0: volume
header not valid" on the IRIX master image because the header's magic
lives in bytes 0-3, and a bench whose device waits a cycle can never see
it. `c_live` in scsi_cache.sv, and the bench's device now presents word 0
with the ack.

## 4. Fit and board

**Fit A** (`output_files/sgiindy-b26a-seed2.rbf`, md5
`7b0beaf166e6f994ea541bc87f2c2d39`, SEED=2, 13:18-13:55 on 2026-09-08): the
cache as ported, BEFORE the `c_live` line (§1, the harness's word-0 finding
landed while this fit ran; hps_io never presents a word in the ack's own
cycle, so the two are identical on the board). 36,369 ALMs (87 %, build 25
was 34,637), 44,224 registers, **443 / 553 M10K** (build 25: 379 - the
store's 64 exactly), core clock setup slack **+3.261 ns** (build 25:
+1.981). The framework's HDMI PLL domain came out at -0.029 ns (TNS -0.052)
where builds 24/25 had +0.276: placement, not the cache (`scripts/build.sh`
says a different seed is the remedy).

**Fit B** (`output_files/sgiindy-b26b-seed2.rbf`, md5
`4e1cd4ea4d37ae42da9b0b17fb02ebe2`, SEED=2, 14:01-14:23, run as
`scripts/build.sh` directly because the Quartus GUI left open on this box
makes `fit_when_free.sh` wait forever): the committed source (`02265d3`,
with `c_live`), the release candidate. 36,296 ALMs (87 %), 44,117
registers, 443 / 553 M10K, core clock setup slack **+2.875 ns**, and every
domain met - the HDMI PLL domain at +0.214 ns this time. Board results:
`scripts/diskpair.sh output_files/sgiindy-b26b-seed2.rbf --tag b26b`
(14:24 on 2026-09-08, logs `tests/out/hw/irixrate-b26b-on.log` / `-off.log`):
cache ON, fresh image, **X-UP at 257 s, no panic**, at X-UP target wait
9.2 s, hps_io 8,485 + 4,797 transactions, 45,649 hits / 1,644 misses /
7,108 sectors written, bus busy 26.8 s, DATA 20.2 s for 27.0 MB (1.34
MB/s) - the same picture as fit A. Cache OFF: X-UP at 258 s, no panic, target wait 20.2 s, hps_io 41,302 + 6,665 transactions, bus busy 32.6 s, DATA 27.2 s for 24.6 MB (0.90 MB/s) - the bypass on the release bitstream.
Released as `releases/SGIIndy_20260908.rbf` (docs/20).

**Board, fit A** (`scripts/diskpair.sh output_files/sgiindy-b26a-seed2.rbf
--tag b26a`, 13:56-14:14 on 2026-09-08: one fresh boot from the pristine
image with the cache on, one with it off, the counters read every ~22 s,
logs `tests/out/hw/irixrate-b26a-on.log` / `-off.log`). Both boots reached
X-UP with no panic. The readings at X-UP:

| | cache ON | cache OFF | build 25 (docs/47) |
|---|---|---|---|
| to X-UP (the poll that saw it) | 258 s | 259 s | 270-272 s |
| **target wait** (the guest's disk time) | **8.6 s** | **21.3 s** | - |
| hps_io transactions, read + write | 8,313 + 4,691 | 45,312 + 7,055 | - |
| hps_io channel busy | 19.6 s | 21.3 s | - |
| SCSI bus busy / in DATA phases | 26.1 s / 21.9 s | 34.8 s / 28.7 s | - |
| bytes in DATA phases, and the rate | 26.55 MB, 1.21 MB/s | 26.81 MB, 0.93 MB/s | - |
| cache hits / misses / sectors written | 45,144 / 1,606 / 6,701 | - | - |

What it says:

* **The guest's disk wait fell from 21.3 s to 8.6 s** (-60 %) over the same
  boot: 96.6 % of the targets' sector reads were hits, and every write was
  acked from block RAM. The channel moved the same bytes in a quarter of the
  transactions (13,004 vs 52,367), and was busy for about the same time -
  which is now mostly prefetch and flush behind the guest's back rather
  than the guest waiting.
* **The boot did not get measurably shorter, and the poll cannot tell**: a
  22 s poll period puts both X-UPs in the same window, and build 25's
  270-272 s are within one period too. The ceiling was known before the
  fit: 21.3 s of disk wait in a 259 s boot is 8 %, so a perfect cache is
  worth at most that. To resolve it, poll every 5 s (irixrate.sh's `sleep
  20` and the ssh round trip) or time the boot from the beacon's heartbeat.
* **The next disk cost is the SCSI byte path, not the HPS.** With the cache
  the DATA phases run at the WD33C93 -> HPC3 DMA -> memory rate, 1.2-1.6
  MB/s (~35 core clocks a byte); 22 s of a 258 s boot is spent there. A
  real Indy moves 5-10 MB/s. Cache off, that path also waits for sectors
  (0.93 MB/s). Where the 35 clocks go - the REQ/ACK handshake in scsi.v,
  the byte-at-a-time initiator (`wd33c93.sv`), or `hpc3_scsi_dma.sv`'s
  memory writes - is the next measurement (docs/48 §3's "measure, then
  change" applies again: a beacon word with cycles per byte in each stage).
* The early readings are in the logs too (every ~22 s from 61 s): the
  first 105 s of the boot is where the disk is busiest (12.3 s of DATA
  phase by then, cache off); after ~190 s reads stop and rc2/X are CPU.

## 5. Recipes (self-contained)

* Bench: WSL, native FS: `rsync` `rtl tools verilator` into `~/kicpu`
  (exclude `generated`), de-CRLF, `make -C ~/kicpu/verilator tb_scsi_cache`
  and `tb_scsi_cache_nocd` (a few seconds each). `~/kicpu/gate3.sh
  bench|build|tests` does the sync and each step; `chain3.sh` runs build,
  then the PROM tests and the IRIX boot (`gate4.sh irix7`) side by side.
  `make` here refuses `-j 0` (it is Verilator's flag, inside the target).
  Variables inside a `wsl -- bash -c '...'` string are eaten: literal paths.
* Board measurement: `scripts/deploy.sh --rbf output_files/sgiindy.rbf
  --no-launch`, then `bash scripts/setopt.sh scsicache=on` (all other
  options default) and `bash scripts/irixrate.sh 1 --tag b26-on --fresh
  /media/fat/games/SGIIndy/SGIIndy53-pristine.img --stats`; then
  `scsicache=off` and the same with `--tag b26-off`. The stats line at X-UP
  is the boot's disk time; the elapsed column is the boot. One boot each is
  a comparison of the disk path, not a crash rate (docs/47: five fresh boots
  for a rate).
* Fit: `SEED=2 bash scripts/fit_when_free.sh b26` detached (docs/48 §4);
  `git checkout -- sgiindy.qsf` after.
* Auto-memory to read first: `hardware-bug-instrument-first`,
  `scsi-fsck-transfer-count-livelock`, `ki-revendor-wip`, `local-toolchain`,
  `github-push-https`.
