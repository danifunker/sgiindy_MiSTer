#!/usr/bin/env python3
"""Send raw MiSTer Remote keystroke/sleep sequences over the ws API.

Usage:
  python tools/misterdeploy/ws_send.py [--host 192.168.99.143] [--port 8182] \
         "kbd:osd" "sleep:0.8" "kbd:down" "kbd:confirm" "kbdRaw:32" ...

Steps:
  kbd:<name>    named key (keyboard.go): up down left right menu back confirm
                cancel osd screenshot core_select user reset console
                exit_console computer_osd change_background
                (osd = F12 opens the core OSD; API names case-SENSITIVE)
  kbdRaw:<n>    raw uinput code (F12=88; letters jump the file browser:
                D=32, S=31, I=23 ...)
  text:<string> type a string at the guest, one keystroke per character, using
                the ASCII table below. "hinv\\r" rather than four kbdRaw steps
                and an enter. Capitals and shifted symbols are typed with
                LEFTSHIFT held around the key (kbdRawDown:42 .. kbdRawUp:42).
  mouseMove:<dx>,<dy>   RELATIVE mouse move (the guest sees a mouse delta)
  mouseBtn:<name>       mouse button: left / right / middle
  sleep:<sec>   pause between steps (OSD needs ~0.3-0.8 s to redraw)

The mouse matters less here than it did on the Mac that this tool came from --
nothing on the PROM's path moves a pointer -- but the same relative-delta rule
applies: there is no absolute positioning a guest honours, so park the cursor by
slamming it to a corner with a large negative move and step out from there.

For this core the useful sequences are OSD ones. "Graphics board: None" puts the
console back on the UART, which is the configuration to bring the machine up in:
  kbd:osd sleep:0.8 kbd:down ... kbd:right sleep:0.3 kbd:osd
Read /api/menu/view first if the OSD layout has changed under you.
"""
import argparse
import asyncio
import os
import sys

import websockets


# ---- ASCII -> raw Linux uinput key codes ----------------------------------
# THE PROM'S CONSOLE IS THE ONLY WAY TO DRIVE THIS MACHINE and it wants
# characters, not key codes. Hand-assembling them works for `hinv` and does not
# work for an installer, so the table lives here. These are Linux input event
# codes (include/uapi/linux/input-event-codes.h), which is what the MiSTer
# Remote ws API forwards to uinput - NOT PS/2 scan codes and not ASCII.
KEYCODE = {
    "a": 30, "b": 48, "c": 46, "d": 32, "e": 18, "f": 33, "g": 34, "h": 35,
    "i": 23, "j": 36, "k": 37, "l": 38, "m": 50, "n": 49, "o": 24, "p": 25,
    "q": 16, "r": 19, "s": 31, "t": 20, "u": 22, "v": 47, "w": 17, "x": 45,
    "y": 21, "z": 44,
    "1": 2, "2": 3, "3": 4, "4": 5, "5": 6,
    "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
    "-": 12, "=": 13, "[": 26, "]": 27, ";": 39, "'": 40, "`": 41,
    "\\": 43, ",": 51, ".": 52, "/": 53, " ": 57,
    "\n": 28, "\r": 28, "\t": 15,
}
# The shifted twin of each unshifted symbol. A capital letter is its own
# lowercase key plus SHIFT; these are the symbols that need the same.
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]",
    ":": ";", '"': "'", "~": "`", "|": "\\", "<": ",", ">": ".", "?": "/",
}
KEY_LEFTSHIFT = 42


def expand_text(text):
    """A `text:` step becomes one kbdRaw step per character.

    A capital letter or a shifted symbol becomes SHIFT-down, key, SHIFT-up: the
    guest sees a real shifted keystroke, which is what a shell needs for /CDROM
    or a pipe. Anything outside the two tables is refused rather than silently
    typed as something else - a command that quietly loses a character is
    worse than one that will not run.
    """
    # A shell cannot easily hand this an actual carriage return, so the
    # two-character forms are taken as the real thing - `text:hinv\r` is the
    # shape every caller actually wants to write.
    text = (text.replace("\\r", "\r").replace("\\n", "\n").replace("\\t", "\t"))
    steps = []
    for ch in text:
        shifted = (ch.isalpha() and ch != ch.lower()) or ch in SHIFTED
        base = ch.lower() if ch.isalpha() else SHIFTED.get(ch, ch)
        code = KEYCODE.get(base)
        if code is None:
            raise SystemExit("ws_send: cannot type %r - not in the key table" % ch)
        if shifted:
            steps += ["kbdRawDown:%d" % KEY_LEFTSHIFT, "kbdRaw:%d" % code,
                      "kbdRawUp:%d" % KEY_LEFTSHIFT]
        else:
            steps.append("kbdRaw:%d" % code)
    return steps


async def run(host, port, steps):
    url = f"ws://{host}:{port}/api/ws"
    async with websockets.connect(url) as ws:
        # drain the state the server pushes on connect
        try:
            while True:
                await asyncio.wait_for(ws.recv(), timeout=0.5)
        except asyncio.TimeoutError:
            pass
        expanded = []
        for step in steps:
            if step.startswith("text:"):
                expanded += expand_text(step[5:])
            else:
                expanded.append(step)
        for step in expanded:
            if step.startswith("sleep:"):
                await asyncio.sleep(float(step.split(":", 1)[1]))
            elif step.startswith(("kbd:", "kbdRaw:", "kbdRawDown:", "kbdRawUp:",
                                  "mouseMove:", "mouseBtn:", "mousePos:")):
                await ws.send(step)
                print(f"sent {step}")
                await asyncio.sleep(0.12)  # let the remote coalesce events
            else:
                sys.exit(f"unknown step '{step}' "
                         "(want kbd:/kbdRaw:/mouseMove:/mouseBtn:/sleep:)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=os.environ.get("MISTER_HOST", "MiSTer.local"),
                    help="MiSTer hostname/IP (env MISTER_HOST)")
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("MISTER_HTTP_PORT", "8182")),
                    help="MiSTer Remote port (env MISTER_HTTP_PORT)")
    ap.add_argument("steps", nargs="+")
    args = ap.parse_args()
    asyncio.run(run(args.host, args.port, args.steps))


if __name__ == "__main__":
    main()
