# misterdeploy

Two kinds of tool live here. `launch_unstable_core.py` and `ws_send.py` push,
launch and drive a [MiSTer](https://mister-devel.github.io/MkDocs_MiSTer/) core
through the **MiSTer Remote** web UI (the [mrext](https://github.com/wizzomafizzo/mrext)
HTTP/websocket API on port `8182`); they were adapted from the MacLC core's
copies and nothing in them is specific to this project — host, port, ssh key,
core filename and folder are all flags or environment variables. Everything
else is this project's board instrumentation: scripts that run on the MiSTer's
ARM and read the core's DDR3 directly, and readers for what they capture and
for the SGI disk images the machine writes.

`scripts/deploy.sh` and the other scripts in `scripts/` are the wrappers that
use these, with all machine configuration in the gitignored
`scripts/local.env`; [deploy-and-debug.md](../../docs/reference/deploy-and-debug.md)
is how they fit together.

## `launch_unstable_core.py`

Pushes a core (optional), reboots the MiSTer for a clean menu, then drives the
**main-menu OSD** with generated keystrokes to select the core, and verifies
what launched.

The keystroke sequence is **generated at run time from the live menu listing**
(`POST /api/menu/view`), so a core dropped into the folder under any new
filename is found correctly — just pass `--core <filename>`. No menu position
is hard-coded.

> The on-screen OSD orders entries **case-insensitively**; the API returns them
> case-*sensitively*, so the script re-sorts the filenames itself. A subfolder
> opens with the cursor on its `<UP-DIR>` row, so the core's row is its index +
> 1 (auto-derived from the `up` field).

The screenshot API does not capture the OSD, so the navigation is blind. That
is why the script verifies afterwards against the `coreRunning` broadcast and
retries: a missed keystroke selects the *adjacent* core, which is a far more
confusing failure than launching nothing.

**`MISTER_RBF_PATH` skips all of that.** When it is set in the environment and
this is not a `--dry-run`, the script loads that file from wherever it is on
the device — in practice `/tmp`, which is RAM — by writing `load_core <path>`
to `/dev/MiSTer_cmd` over ssh: no push, no reboot (a reboot empties `/tmp`) and
no OSD walk, then the same `coreRunning` check against the file's base name.
It is how a bitstream is tested without writing it to the card, and every
script that launches through this file picks it up.

### Usage

```bash
# Push a fresh build, then launch it (host/key/folder from scripts/local.env):
bash scripts/deploy.sh

# Or drive the launcher directly, for a core already on the device:
python tools/misterdeploy/launch_unstable_core.py --core SGIIndy.rbf --folder _Computer

# Preview the generated keystrokes without touching anything:
python tools/misterdeploy/launch_unstable_core.py --core SGIIndy.rbf --dry-run

# Load a bitstream staged in RAM on the device:
MISTER_RBF_PATH=/tmp/SGIIndy.rbf python tools/misterdeploy/launch_unstable_core.py --core SGIIndy.rbf
```

`--core` defaults to `RBF_NAME`, which in `scripts/local.env` is Quartus's
output name (`sgiindy.rbf`), not the name `deploy.sh` files the core under on
the device (`RBF_REMOTE`, `SGIIndy.rbf`) — so pass `--core` when running it by
hand.

### Options

| flag | env | default | purpose |
|------|-----|---------|---------|
| `--host` | `MISTER_HOST` | `MiSTer.local` | hostname / IP |
| `--port` | `MISTER_HTTP_PORT` | `8182` | MiSTer Remote port |
| `--core` | `RBF_NAME` | — (required) | core filename to launch |
| `--folder` | `MISTER_CORE_FOLDER` | `_Unstable` | top-level `_` folder holding the core |
| `--push FILE` | — | off | scp `FILE` into the folder (md5-verified) first |
| `--ssh-key` | `MISTER_SSH_KEY` | — | ssh identity for `--push` and `MISTER_RBF_PATH` |
| `--ssh-user` | `MISTER_SSH_USER` | `root` | ssh user for the same |
| `--no-reboot` | — | reboots | skip the clean-menu reboot |
| `--reboot-wait` | — | `180` | seconds to wait for the web service after reboot |
| `--delay` | — | `0.3` | seconds between key presses |
| `--updir-rows` | `MISTER_OSD_UPDIR_ROWS` | auto | override the `<UP-DIR>` row offset |
| `--no-verify` | — | verifies | skip the post-launch `coreRunning` check |
| `--max-tries` | — | `2` | reboot+select attempts; blind OSD navigation is timing-sensitive |
| `--dry-run` | — | off | print keystrokes; push/reboot/send nothing |
| `--seed-file FILE` | — | off | local file to seed a save image, **create-only-if-missing** |
| `--seed-remote PATH` | — | — | absolute remote path for `--seed-file` |
| `--seed-mount-cfg PATH` | — | — | absolute remote `.s<N>` mount-memory file to create-if-missing |
| `--seed-mount-rel REL` | — | — | relative path stored in the `.s<N>` file |
| `--seed-mount-size N` | — | `1024` | size of the `.s<N>` file (NUL-padded; MiSTer uses 1024) |
| — | `MISTER_RBF_PATH` | unset | load this file on the device through `/dev/MiSTer_cmd` instead (above) |

The `--seed-*` flags are not used by this core: they drop a default save image
and pre-write MiSTer's per-slot mount memory (`config/<core>.s<N>`) so it is
auto-mounted from the first boot, both create-only-if-missing so saved data is
never overwritten. This core has no save image — its NVRAM is volatile
([nvram.md](../../docs/reference/nvram.md)) — and **`boot.rom` is not seeded
this way**: it is firmware rather than state, `scripts/deploy.sh` pushes it on
every run, and the framework uploads it with no mount at all.
`scripts/mount.sh` writes this core's SCSI mount records itself.

Under Git Bash, set `MSYS_NO_PATHCONV=1` so absolute `/media/fat/...`
arguments are not rewritten into Windows paths. Requires `scp`/`ssh` on `PATH`
and the `websockets` Python package.

## `ws_send.py`

Sends raw keystroke, mouse and sleep sequences over the same websocket, for
driving the core's own OSD or typing at the machine once it is running:

```bash
python tools/misterdeploy/ws_send.py "text:root" "sleep:0.3" "kbdRaw:28"
```

The steps are `kbd:<name>` (a named key — `osd`, `up`, `down`, `confirm` and
so on), `kbdRaw:<n>` (a Linux input event code; `kbdRawDown:`/`kbdRawUp:` hold
and release one), `text:<string>` (typed a character at a time, capitals and
shifted symbols with Shift held around the key), `mouseMove:<dx>,<dy>` (a
*relative* move — there is no absolute positioning a guest honours),
`mouseBtn:<left|right|middle>` and `sleep:<seconds>`. `--host` and `--port`
default to `MISTER_HOST` and `MISTER_HTTP_PORT`. The docstring has the full key
vocabulary.

## Board instruments — they run on the MiSTer

The FPGA and the HPS share one DDR3, and a core's `DDRAM` port uses the same
physical addresses Linux does, so everything the machine stores can be read
from the ARM with an mmap of `/dev/mem` — busybox `devmem` reads zeros from
this window and is not a substitute. Addresses are ARM physical: main memory at
`0x30000000`, the frame buffer's drawing planes at `0x34000000` and auxiliary
planes at `0x34800000`, the PROM at `0x35000000`, the debug beacon at
`0x35800000` ([mister-integration.md](../../docs/reference/mister-integration.md#memory-everything-is-in-ddr3)).
The core numbers bytes big-endian within a 64-bit word and the ARM reads
little-endian, so raw dumps come back reversed in groups of eight.

These run under `python3` on the device from `/media/fat/sgidbg/`, where the
scripts copy them; most import `/media/fat/sgidbg/ddr3_peek.py`.

| tool | what it does |
|---|---|
| `ddr3_peek.py ADDR LEN [-o FILE] [--stats]` | the core's DDR3 window at ARM physical addresses: a hex dump, raw bytes to a file, or a count of the non-zero bytes |
| `guestmem.py ADDR [LEN] [-o FILE]` | the guest's memory by its own KSEG0/KSEG1 addresses, in its own byte order — for disassembling what a panic's EPC points at |
| `memclear.py [BYTE]` | fills main memory (`0x30000000`–`0x34000000`) with zeros, or `BYTE`, before a launch, so the previous run's state cannot be read as this one's |
| `fb_poke.py bars\|ramp\|fill N\|sig` | writes a test pattern into the drawing planes' colour index from the ARM, and zeroes the auxiliary region; `fill 0xE7` is the marker the scripts use for "not drawn by this boot" |
| `fbgrab.py [OUT]` | the 1280×1024 colour-index plane, one byte a pixel, to `/tmp/fb.raw` (or `OUT`) — the store, not the screen |
| `fbgrab32.py X0 Y0 W H OUT` | whole 32-bit slots of both plane sets for a rectangle, for a pixel that is wrong in a way an index cannot show |
| `alive.py [BASE [SPAN [GAP]]]` | is the guest CPU executing: how many bytes of the PROM's stack changed between two samples a few seconds apart |
| `irixstate.py` | where an IRIX boot is, in one line: `PANIC` with the kernel's message (from `panicstr`), `X-UP` (from the frame buffer's index histogram), or still booting |
| `bcnread.py [--loop N] [--interval S] [--raw] [--stats] [--perf]` | decodes the debug beacon; `--stats` prints the SCSI disk-time counters as one line, `--perf` the performance counters as one line of integers for `perfdiff.py` |
| `prof.py --out FILE [--secs S] [--hz N] [--min S] [--until-idle S] [--idle RANGES]` | a statistical profiler over the beacon: samples words 0, 10, 13, 15 and 40 — the heartbeat, the PC entering decode with the stall vector, REX3's VDMA beats, the display's line-cache counters, register 31 and the PC last retired — at a steady rate, with a snapshot of every word at each end; `--until-idle` ends it once the kernel has been idle long enough |
| `hammer.py [SECONDS]` | reads the frame buffer region from the ARM continuously — a second heavy DDR3 reader, for `tests/run-cputest-hw.sh --load` |
| `mkmac.py PATH` | writes `boot1.rom`, the machine's Ethernet address: `08:00:69:12:34` and the MiSTer's own last octet |
| `sumcheck.py IMAGE SUMS SRC COPY FILE...` | checks the checksums IRIX computed, and the copy it made, against the bytes in the image itself (`scripts/diskcheck.sh`) |
| `efsdiff.py USED PRISTINE [--part N] [--src PATH ...] [--max N]` | every EFS block that differs between a used image and the pristine one it was restored from, and whose it is — a block of a file whose inode did not change is a write that went to the wrong place (`scripts/diskstress.sh`) |

## Readers — anywhere a Python runs, most of them on the host

A SCSI image mounted on this core is an ordinary file on the SD card, so what
the guest wrote can be examined with the core out of the loop; that is what
separates a write fault from a read fault.

| tool | what it does |
|---|---|
| `efsread.py IMAGE ls\|cat\|get\|find PATH [OUT]` | files out of an EFS file system in an SGI disk image, read-only — `/var/adm/SYSLOG`, crash reports, the kernel. The partition comes from the volume header (`--part` to choose). Also runs on the device |
| `sgivh.py IMAGE` | parses and checksums an SGI volume header |
| `efspeek.py IMAGE PART_FIRST_LBN [NAME]` | walks an EFS partition by hand and finds a file's first bytes |
| `efsfsck.py IMAGE [--part N] [--who BLOCK...]` | a read-only consistency check: blocks claimed by an inode but free in the bitmap, blocks claimed twice, the free count. **Host only** — it needs about 400 MB for a 2 GB image |
| `imgdiff.py SRC DST DST_OFF LEN [--sig N] [--max-report N]` | finds where a run the guest wrote came from in its source file (an ISO, say) and diffs it byte for byte |
| `firstbyte.py SRC SRC_OFF DST DST_OFF LEN` | for blocks whose only difference is their first byte, which byte landed there instead |
| `fbpng.py RAW OUT [--mode text\|grey\|index] [--crop X,Y,W,H] [--scale S]` | renders a `fbgrab.py` plane as a PNG; `text` inks the PROM console's index 7 black on white, the rendering you can read (needs Pillow) |
| `disbin.py BLOB BASE [--mark ADDR] [--from ADDR] [--to ADDR]` | disassembles a big-endian MIPS blob at a base address (needs capstone) |
| `ecoffsyms.py UNIX syms\|lsyms [REGEX]`, `ecoffsyms.py UNIX dump ADDR LEN OUT` | symbols and code out of IRIX's ECOFF kernel, which no modern binutils reads — turns a beacon PC into a function name |
| `profan.py CAPTURE [--unix UNIX] [--so SO_LOCATIONS] [--top N] [--series N]` | reads a `prof.py` capture: where the time went (idle, a kernel function, a user library) and how (advancing, or held on a fetch or a data access) |
| `perfdiff.py BEFORE AFTER` | two `bcnread.py --perf` readings a workload apart, turned into where the clocks went, clocks per instruction, fills and TLB walks per thousand instructions, and the DDR3 port's shares |
| `simprof.py PROF [--unix UNIX] [--top N]` | the simulator's `--prof` output folded through the kernel's procedures, as `profan.py` folds the board's |
