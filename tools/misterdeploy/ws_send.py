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


async def run(host, port, steps):
    url = f"ws://{host}:{port}/api/ws"
    async with websockets.connect(url) as ws:
        # drain the state the server pushes on connect
        try:
            while True:
                await asyncio.wait_for(ws.recv(), timeout=0.5)
        except asyncio.TimeoutError:
            pass
        for step in steps:
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
