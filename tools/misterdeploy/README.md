# misterdeploy

Tooling to push and launch a [MiSTer](https://mister-devel.github.io/MkDocs_MiSTer/)
core through the **MiSTer Remote** web UI (the [mrext](https://github.com/wizzomafizzo/mrext)
HTTP/websocket API on port `8182`). Adapted from the MacLC core's copy of the same
two files; nothing in here is specific to this project — host, port, ssh key, core
filename and folder are all flags or environment variables.

`scripts/deploy.sh` is this repository's wrapper: it verifies the Quartus build,
creates `games/SGIIndy/`, drops `boot.rom` into it, and then hands off to
`launch_unstable_core.py` to push the bitstream and select it from the OSD. All
machine configuration lives in `scripts/local.env`, which is gitignored.

## `launch_unstable_core.py`

Pushes a core (optional), reboots the MiSTer for a clean menu, then drives the
**main-menu OSD** with generated keystrokes to select the core, and verifies what
launched.

The keystroke sequence is **generated at run time from the live menu listing**
(`POST /api/menu/view`), so a core dropped into the folder under any new filename is
found correctly — just pass `--core <filename>`. No menu position is hard-coded.

> The on-screen OSD orders entries **case-insensitively**; the API returns them
> case-*sensitively*, so the script re-sorts the filenames itself. A subfolder opens
> with the cursor on its `<UP-DIR>` row, so the core's row is its index + 1
> (auto-derived from the `up` field).

The screenshot API does not capture the OSD, so the navigation is blind. That is why
the script verifies afterwards against the `coreRunning` broadcast and retries: a
missed keystroke selects the *adjacent* core, which is a far more confusing failure
than launching nothing.

### Usage

```bash
# Push a fresh build, then launch it (host/key/folder from scripts/local.env):
bash scripts/deploy.sh

# Or drive the launcher directly:
python tools/misterdeploy/launch_unstable_core.py --core sgiindy.rbf --folder _Computer

# Preview the generated keystrokes without touching anything:
python tools/misterdeploy/launch_unstable_core.py --core sgiindy.rbf --dry-run
```

### Options (all machine config is a flag or env var)

| flag | env | default | purpose |
|------|-----|---------|---------|
| `--host` | `MISTER_HOST` | `MiSTer.local` | hostname / IP |
| `--port` | `MISTER_HTTP_PORT` | `8182` | MiSTer Remote port |
| `--core` | `RBF_NAME` | — (required) | core filename to launch |
| `--folder` | `MISTER_CORE_FOLDER` | `_Unstable` | top-level `_` folder holding the core |
| `--push FILE` | — | off | scp `FILE` into the folder (md5-verified) first |
| `--ssh-key` | `MISTER_SSH_KEY` | — | ssh identity for `--push` |
| `--ssh-user` | `MISTER_SSH_USER` | `root` | ssh user for `--push` |
| `--no-reboot` | — | reboots | skip the clean-menu reboot |
| `--reboot-wait` | — | `180` | seconds to wait for the web service after reboot |
| `--delay` | — | `0.3` | seconds between key presses |
| `--updir-rows` | `MISTER_OSD_UPDIR_ROWS` | auto | override the `<UP-DIR>` row offset |
| `--no-verify` | — | verifies | skip the post-launch `coreRunning` check |
| `--max-tries` | — | `2` | reboot+select attempts; blind OSD nav is timing-sensitive |
| `--dry-run` | — | off | print keystrokes; push/reboot/send nothing |
| `--seed-file FILE` | — | off | local file to seed a save image, **create-only-if-missing** |
| `--seed-remote PATH` | — | — | absolute remote path for `--seed-file` |
| `--seed-mount-cfg PATH` | — | — | absolute remote `.s<N>` mount-memory file to create-if-missing |
| `--seed-mount-rel REL` | — | — | relative path stored in the `.s<N>` file |
| `--seed-mount-size N` | — | `1024` | size of the `.s<N>` file (NUL-padded; MiSTer uses 1024) |

The `--seed-*` flags are unused by this core today. They exist for the moment
`docs/17-nvram-persistence.md` lands and a `setenv` has somewhere to survive: they
drop a default save image and pre-write MiSTer's per-slot mount memory
(`config/<core>.s<N>`) so it is auto-mounted from the first boot. Both are
create-only-if-missing, so saved data is never overwritten. **`boot.rom` is not
seeded this way** — it is firmware rather than state, `scripts/deploy.sh` pushes it
on every run, and the framework uploads it with no mount at all.

Under git-bash, set `MSYS_NO_PATHCONV=1` so absolute `/media/fat/...` arguments are
not rewritten into Windows paths.

Requires `scp`/`ssh` on `PATH` and the `websockets` Python package.

## `ws_send.py`

Sends raw keystroke / mouse / sleep sequences over the same websocket, for driving
the core's own OSD once it is running (changing the graphics-board option, typing at
the machine, mounting an image). See its docstring for the step vocabulary.
