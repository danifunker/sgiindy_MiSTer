#!/usr/bin/env python3
"""Write games/<core>/boot1.rom: this machine's Ethernet address. ON THE DEVICE.

WHY A FILE AND WHY THAT NAME. The core needs a MAC address at RUN TIME - it
cannot be a parameter, because it has to differ per board - and MiSTer's
framework already has a channel that delivers a file to a core at every start
with no OSD interaction: it uploads games/<core>/boot0.rom .. boot3.rom at
ioctl index `i << 6` (Main_MiSTer user_io.cpp:1629). boot.rom itself arrives
the same way at index 0. So boot1.rom lands at index 0x40, which sgiindy.sv
decodes as the Ethernet address and nothing else.

THE LAST OCTET COMES FROM THE MISTER so two boards on one network differ. The
first five bytes are fixed - 08:00:69 is SGI's OUI, and 12:34 keeps the rest
recognisable - and only the final byte is inherited, which is what was asked
for. If no interface can be read the file is still written, with a fallback
octet, because a machine with no eaddr at all panics the IRIX installer.

The file is exactly six bytes, most significant first.
"""
import os
import sys

FIXED = [0x08, 0x00, 0x69, 0x12, 0x34]
FALLBACK = 0x56


def host_octet():
    """The last byte of the first real interface's MAC."""
    base = "/sys/class/net"
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return None, "no /sys/class/net"
    # eth0 first if it is there, then anything that is not loopback.
    order = ([n for n in names if n == "eth0"] +
             [n for n in names if n != "eth0" and n != "lo"])
    for n in order:
        try:
            with open(os.path.join(base, n, "address")) as fh:
                addr = fh.read().strip()
        except OSError:
            continue
        parts = addr.split(":")
        if len(parts) != 6:
            continue
        if all(p == "00" for p in parts):
            continue          # an interface that is down often reads all zeros
        return int(parts[5], 16), "%s %s" % (n, addr)
    return None, "no interface with a usable address"


def main():
    path = sys.argv[1]
    octet, why = host_octet()
    if octet is None:
        octet = FALLBACK
        note = "fallback 0x%02x (%s)" % (octet, why)
    else:
        note = "from %s" % why
    mac = bytes(FIXED + [octet])
    with open(path, "wb") as fh:
        fh.write(mac)
    print("%s: %s  [%s]"
          % (path, ":".join("%02x" % b for b in mac), note))


main()
