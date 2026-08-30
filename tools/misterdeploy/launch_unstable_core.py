#!/usr/bin/env python3
"""Push (optional) and launch a MiSTer core by driving the main-menu OSD.

Reusable across cores and machines: every machine-specific value (host, port, ssh
key, core filename, folder) is a CLI flag or environment variable, so nothing
personal is baked into this file.

The OSD keystroke sequence is GENERATED at run time from the LIVE menu listing
(POST /api/menu/view), so a core dropped into the folder under ANY new filename is
found correctly -- just pass its filename via --core. No menu position is ever
hard-coded; adding/removing cores (e.g. the downloader re-populating _Unstable)
recomputes the row counts on the next run.

What it does (each step optional):
  1. --push FILE : scp FILE into the folder on the MiSTer (md5-verified).
  2. reboot      : POST /api/settings/system/reboot (clean core exit -> main menu),
                   then poll until the web service returns. --no-reboot to skip.
  3. select      : POST /api/menu/view to read root + the folder, compute
                   down*N/confirm keystrokes, send them over ws /api/ws.
  4. verify      : read the coreRunning broadcast to confirm what launched.

IMPORTANT -- sorting: /api/menu/view returns items in BYTE (case-SENSITIVE) order,
which does NOT match the on-screen OSD. The OSD is case-INSENSITIVE (verified on
hardware: "ao486" sorts among the "A"s; a core named "MacLC" is the first "M",
before "MSX"). So we ignore the API order and re-sort filenames ourselves. A fresh
subfolder opens with the cursor on its <UP-DIR> row, so the core's real row is its
index + 1 (auto-derived from the listing's `up` field; override --updir-rows).

The screenshot API does not capture the OSD, so this can't see the cursor; it
computes row counts from the live listing and verifies the result after launch.

Examples:
  # Launch a core already present (uses MISTER_HOST/MISTER_HTTP_PORT from env):
  python launch_unstable_core.py --core MacLC.rbf
  # Push a fresh build then launch it, explicit host + key:
  python launch_unstable_core.py --host 192.168.1.50 --ssh-key ~/.ssh/mister \
      --push ./output_files/MacLC.rbf --core MacLC.rbf
  # Preview the generated keystrokes without touching anything:
  python launch_unstable_core.py --core MacLC.rbf --dry-run
"""
import argparse
import asyncio
import hashlib
import json
import os
import posixpath
import shlex
import subprocess
import sys
import time
import urllib.request

import websockets


# --------------------------------------------------------------------------- API
def api_post(host, port, path, body, parse=True, timeout=10):
    url = f"http://{host}:{port}/api{path}"
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
    return json.loads(data) if parse else data.decode(errors="replace")


def osd_order(filenames):
    """Order entries the way the MiSTer OSD does: case-INSENSITIVE, raw bytes as the
    tie-break (matches how same-name/different-case cores fall out by date)."""
    return sorted(filenames, key=lambda n: (n.lower(), n))


def menu_view(host, port, path):
    return api_post(host, port, "/menu/view", {"path": path})


def folder_entry(host, port, folder):
    """Return the root menu entry (dict) for `folder`, or exit with a clear error.
    The main menu lists only the '_'-prefixed folders by their full filename."""
    view = menu_view(host, port, "")
    by_name = {it["filename"]: it for it in view["items"]}
    if folder not in by_name:
        sys.exit(f"ERROR: folder {folder!r} not in the main menu. Present: "
                 f"{sorted(by_name)}")
    return by_name[folder]


def plan(host, port, path, target):
    """(row, total, has_updir) of `target` within the menu folder at `path`."""
    view = menu_view(host, port, path)
    names = [it["filename"] for it in view["items"]]
    order = osd_order(names)
    if target not in order:
        sys.exit(f"ERROR: {target!r} not listed under menu path {path or '<root>'!r} "
                 f"({len(order)} entries present)")
    return order.index(target), len(order), bool(view.get("up"))


def updir_for(has_updir, override):
    if override is not None:
        return override
    return 1 if has_updir else 0


# -------------------------------------------------------------------------- push
def _md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _ssh_opts(key):
    opts = ["-o", "StrictHostKeyChecking=no"]
    if key:
        opts += ["-i", os.path.expanduser(key)]
    return opts


def push_rbf(local_path, host, user, key, remote_path):
    if not os.path.isfile(local_path):
        sys.exit(f"ERROR: --push file not found: {local_path}")
    target = f"{user}@{host}:{remote_path}"
    print(f"[push] scp {local_path} -> {target}")
    subprocess.run(["scp", "-q", *_ssh_opts(key), local_path, target], check=True)
    local = _md5(local_path)
    out = subprocess.run(
        ["ssh", *_ssh_opts(key), f"{user}@{host}", f"md5sum {shlex.quote(remote_path)}"],
        check=True, capture_output=True, text=True).stdout
    remote = out.split()[0] if out else ""
    if local != remote:
        sys.exit(f"ERROR: md5 mismatch after scp (local {local} != remote {remote})")
    print(f"[push] md5 verified: {local}")


# -------------------------------------------------------------------------- seed
def _remote_exists(host, user, key, path):
    r = subprocess.run(["ssh", *_ssh_opts(key), f"{user}@{host}",
                        f"test -e {shlex.quote(path)} && echo Y || echo N"],
                       capture_output=True, text=True)
    return r.stdout.strip() == "Y"


def _scp_file(local, host, user, key, remote):
    subprocess.run(["scp", "-q", *_ssh_opts(key), local, f"{user}@{host}:{remote}"], check=True)


def seed_nvram(args):
    """Seed a save image and its mount-memory file, CREATE-ONLY-IF-MISSING so an
    existing (saved) NVRAM and the user's mount are never overwritten."""
    if not args.seed_file:
        return
    if not os.path.isfile(args.seed_file):
        sys.exit(f"ERROR: --seed-file not found: {args.seed_file}")
    # 1. the data file (e.g. games/<core>/<name>.nvr)
    if args.seed_remote:
        if _remote_exists(args.host, args.ssh_user, args.ssh_key, args.seed_remote):
            print(f"[seed] {args.seed_remote} already present - leaving saved data intact")
        else:
            print(f"[seed] creating {args.seed_remote} from {args.seed_file}")
            _scp_file(args.seed_file, args.host, args.ssh_user, args.ssh_key, args.seed_remote)
    # 2. the MiSTer .s<N> mount-memory file (fixed-size, NUL-padded relative path)
    if args.seed_mount_cfg and args.seed_mount_rel:
        if _remote_exists(args.host, args.ssh_user, args.ssh_key, args.seed_mount_cfg):
            print(f"[seed] {args.seed_mount_cfg} already present - leaving mount intact")
        else:
            rel = args.seed_mount_rel.encode()
            if len(rel) > args.seed_mount_size:
                sys.exit("ERROR: --seed-mount-rel longer than --seed-mount-size")
            blob = rel + b"\x00" * (args.seed_mount_size - len(rel))
            import tempfile
            tf = tempfile.NamedTemporaryFile(delete=False)
            try:
                tf.write(blob)
                tf.close()
                print(f"[seed] writing mount memory {args.seed_mount_cfg} -> {args.seed_mount_rel}")
                _scp_file(tf.name, args.host, args.ssh_user, args.ssh_key, args.seed_mount_cfg)
            finally:
                os.unlink(tf.name)


# ------------------------------------------------------------------------ reboot
def _service_up(host, port):
    """True iff the MiSTer Remote web service answers a menu listing."""
    try:
        menu_view(host, port, "")
        return True
    except Exception:
        return False


def reboot_and_wait(host, port, wait, down_wait=60):
    """Reboot, then wait for the web service to cycle DOWN and back UP.

    The old version slept a fixed 12s and polled only for UP, so a slow reboot could
    let it drive the OSD of a menu that had not yet rebooted (this once mis-launched
    the wrong core). We now confirm the service goes DOWN first, so a stale-but-up
    menu can never be mistaken for the rebooted one, then wait for it to come back."""
    print("[reboot] POST /api/settings/system/reboot")
    try:
        api_post(host, port, "/settings/system/reboot", {}, parse=False, timeout=5)
    except Exception as e:
        print(f"[reboot] (request ended as expected while it reboots: {e})")
    deadline = time.time() + wait
    # Phase 1: confirm the service actually goes DOWN (reboot really started).
    print("[reboot] waiting for the web service to go DOWN...")
    went_down = False
    down_deadline = min(time.time() + down_wait, deadline)
    while time.time() < down_deadline:
        if not _service_up(host, port):
            went_down = True
            print("[reboot] service is down; reboot confirmed")
            break
        time.sleep(2)
    if not went_down:
        print(f"[reboot] WARN: never saw the service go down within {down_wait}s; "
              "the reboot may not have taken — proceeding to wait for UP anyway")
    # Phase 2: wait for it to come back UP, then let the menu settle.
    print("[reboot] polling for the web service to come back UP...")
    while time.time() < deadline:
        if _service_up(host, port):
            print("[reboot] web service back; letting the menu settle")
            time.sleep(6)
            return
        time.sleep(4)
    sys.exit(f"ERROR: MiSTer web service did not return within {wait}s")


# -------------------------------------------------------------------------- keys
async def _drain(ws, timeout):
    try:
        while True:
            await asyncio.wait_for(ws.recv(), timeout=timeout)
    except asyncio.TimeoutError:
        pass


async def _read_core_running(ws, total):
    loop = asyncio.get_event_loop()
    end = loop.time() + total
    last = None
    while loop.time() < end:
        try:
            msg = await asyncio.wait_for(ws.recv(), timeout=max(0.1, end - loop.time()))
        except asyncio.TimeoutError:
            break
        if isinstance(msg, bytes):
            msg = msg.decode(errors="replace")
        if msg.startswith("coreRunning:"):
            last = msg.split(":", 1)[1]
            if last:
                return last
    return last


async def send_keys(host, port, keys, delay):
    url = f"ws://{host}:{port}/api/ws"
    async with websockets.connect(url) as ws:
        await _drain(ws, 0.5)
        for k in keys:
            if k.startswith("sleep:"):
                await asyncio.sleep(float(k.split(":", 1)[1]))
                continue
            await ws.send(f"kbd:{k}")
            await asyncio.sleep(delay)


async def read_running(host, port):
    url = f"ws://{host}:{port}/api/ws"
    async with websockets.connect(url) as ws:   # fresh connect -> server pushes state
        return await _read_core_running(ws, 6.0)


def verify(host, port, expect):
    """Return True iff coreRunning confirms the expected core launched. None/no
    broadcast counts as True (can't tell — don't trigger a needless retry)."""
    print("[osd] keys sent; waiting for the core to come up...")
    time.sleep(7)
    try:
        running = asyncio.run(read_running(host, port))
    except Exception as e:
        print(f"[osd] WARN: could not reconnect to verify launch: {e}")
        return True
    if running is None:
        print("[osd] WARN: no coreRunning broadcast seen - could not verify launch")
        return True
    if running == "":
        print("[osd] MISS: coreRunning empty - still at the menu (selection missed)")
        return False
    exp, r = expect.lower(), running.lower()
    # Match exact, or one being the other's LEADING token at a non-alphanumeric
    # boundary (e.g. "Atari7800" vs "Atari7800_unstable_..."). Must NOT accept a
    # partial-word overlap like "MACLC" vs "MacLCii" -- the old `r in exp` here
    # rubber-stamped launching the wrong sibling core.
    lo, hi = sorted((exp, r), key=len)
    if exp == r or (hi.startswith(lo) and not hi[len(lo)].isalnum()):
        print(f"[osd] OK: coreRunning='{running}' - {expect} launched")
        return True
    print(f"[osd] MISS: launched coreRunning='{running}', expected '{expect}'")
    return False


# -------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(
        description="Push + launch a MiSTer core via the main-menu OSD (no hard-coded "
                    "positions; sequence generated from the live menu).")
    ap.add_argument("--host", default=os.environ.get("MISTER_HOST", "MiSTer.local"),
                    help="MiSTer hostname/IP (env MISTER_HOST; default MiSTer.local)")
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("MISTER_HTTP_PORT", "8182")),
                    help="MiSTer Remote port (env MISTER_HTTP_PORT; default 8182)")
    ap.add_argument("--core", default=os.environ.get("RBF_NAME"),
                    help="core filename to launch, e.g. MacLC.rbf (env RBF_NAME)")
    ap.add_argument("--folder", default=os.environ.get("MISTER_CORE_FOLDER", "_Unstable"),
                    help="top-level '_' folder holding the core (default _Unstable)")
    ap.add_argument("--push", metavar="FILE",
                    help="scp FILE into the folder (md5-verified) before launching")
    ap.add_argument("--ssh-key", default=os.environ.get("MISTER_SSH_KEY"),
                    help="ssh identity for --push (env MISTER_SSH_KEY)")
    ap.add_argument("--ssh-user", default=os.environ.get("MISTER_SSH_USER", "root"),
                    help="ssh user for --push (default root)")
    ap.add_argument("--seed-file",
                    help="local file to seed a save image (create-only-if-missing)")
    ap.add_argument("--seed-remote",
                    help="absolute remote path for --seed-file")
    ap.add_argument("--seed-mount-cfg",
                    help="absolute remote .s<N> mount-memory file to create-if-missing")
    ap.add_argument("--seed-mount-rel",
                    help="relative path stored in --seed-mount-cfg (e.g. games/MACLC/MacLC.nvr)")
    ap.add_argument("--seed-mount-size", type=int, default=1024,
                    help="size of the .s<N> mount file (NUL-padded; MiSTer uses 1024)")
    ap.add_argument("--no-reboot", action="store_true",
                    help="don't reboot first (default reboots for a clean menu state)")
    ap.add_argument("--reboot-wait", type=int, default=180,
                    help="seconds to wait for the web service after reboot")
    ap.add_argument("--delay", type=float, default=0.3, help="seconds between key presses")
    ap.add_argument("--updir-rows", type=int,
                    default=(int(os.environ["MISTER_OSD_UPDIR_ROWS"])
                             if os.environ.get("MISTER_OSD_UPDIR_ROWS") else None),
                    help="override the auto-derived <UP-DIR> row offset for subfolders")
    ap.add_argument("--no-verify", action="store_true",
                    help="skip the post-launch coreRunning check")
    ap.add_argument("--max-tries", type=int, default=2,
                    help="reboot+select attempts before giving up (blind OSD nav can miss)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the generated keystrokes; push/reboot/send nothing")
    args = ap.parse_args()

    if not args.core:
        ap.error("--core is required (or set RBF_NAME)")

    # Resolve the folder's real path on the device from the live menu (no /media/fat
    # assumption), used both for --push and for the folder listing.
    entry = folder_entry(args.host, args.port, args.folder)
    folder_path = entry["path"]

    # 0. seed NVRAM save image + mount memory (create-only-if-missing)
    if args.seed_file and not args.dry_run:
        seed_nvram(args)
    elif args.seed_file:
        print(f"[seed] (dry-run) would ensure {args.seed_remote} and "
              f"{args.seed_mount_cfg} exist (create-only-if-missing)")

    # 1. push (skipped on dry-run)
    if args.push and not args.dry_run:
        remote = posixpath.join(folder_path, args.core)
        push_rbf(args.push, args.host, args.ssh_user, args.ssh_key, remote)
    elif args.push:
        print(f"[push] (dry-run) would scp {args.push} -> "
              f"{args.ssh_user}@{args.host}:{posixpath.join(folder_path, args.core)}")

    # 2. plan the OSD keystrokes from the live menu listing
    f_row, f_total, f_updir = plan(args.host, args.port, "", args.folder)
    c_row, c_total, c_updir = plan(args.host, args.port, folder_path, args.core)
    f_steps = f_row + updir_for(f_updir, args.updir_rows)
    c_steps = c_row + updir_for(c_updir, args.updir_rows)
    # Keep each phase's keystrokes well under the menu's ~5s cursor-nav timeout,
    # which silently drops keys (a slow run lands one row short). Do NOT press
    # `osd` at the main menu -- that opens a settings overlay and the nav then
    # lands on nothing ("still at the menu").
    # The folder-open settle stays at 1.2s: LCII's 0.6s "fast" settle caused an
    # off-by-one on .143 (2026-07-02, larger/slower folder listing -- the first
    # `down` landed before the folder opened and was eaten, selecting the
    # adjacent stale MacLC rbf). The 5s-timeout concern is per-keystroke pacing,
    # not this one-time settle.
    keys = (["down"] * f_steps + ["confirm", "sleep:1.2"]
            + ["down"] * c_steps + ["confirm"])

    print(f"[osd] {args.folder}: OSD row {f_row}/{f_total} "
          f"(updir={'yes' if f_updir else 'no'}) -> down x{f_steps}, confirm")
    print(f"[osd] {args.core}: OSD row {c_row}/{c_total} "
          f"(updir={'yes' if c_updir else 'no'}) -> down x{c_steps}, confirm")
    print(f"[osd] sequence: {' '.join(keys)}")

    if args.dry_run:
        return 0

    # 3. reboot + select + verify, auto-retrying (blind OSD nav is timing-sensitive,
    # so the coreRunning check occasionally catches a missed selection)
    tries = args.max_tries if not args.no_reboot else 1
    for attempt in range(1, tries + 1):
        if not args.no_reboot:
            reboot_and_wait(args.host, args.port, args.reboot_wait)
        asyncio.run(send_keys(args.host, args.port, keys, args.delay))
        if args.no_verify:
            return 0
        if verify(args.host, args.port, os.path.splitext(args.core)[0]):
            return 0
        if attempt < tries:
            print(f"[osd] verification failed - retrying ({attempt}/{tries})")
    return 1


if __name__ == "__main__":
    sys.exit(main() or 0)
