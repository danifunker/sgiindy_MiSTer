#!/usr/bin/env bash
# diskio.sh [--seconds N] - is the core still asking the HPS for disk blocks?
#
# THIS IS THE CHECK THAT SEPARATES "THE GUEST IS BUSY" FROM "THE SCSI PATH IS
# WEDGED", and it needs no instrumentation in the core at all.
#
# The FPGA does not read the disk image. It raises sd_rd/sd_wr and MiSTer, on
# the ARM, does the read() and streams the sector back. So MiSTer's own I/O
# counters and the file offset of the fd it holds the image on are a direct,
# free readout of whether the core is still making requests:
#
#   * counters climbing        -> the core is asking, the disk path is alive
#   * counters frozen          -> the core has STOPPED asking. Whatever is
#                                 wrong is inside the SCSI RTL; the ARM side
#                                 is innocent and there is no point looking at
#                                 it, at hps_io, or at the image
#   * rchar climbing at a flat -> MiSTer's own input polling, NOT disk. Watch
#     rate with write_bytes       read_bytes/write_bytes, which only move for
#     and pos frozen              real block I/O. ~400 KB/min of rchar alone is
#                                 the idle rate on this box and means nothing
#
# That is how the 2026-09-01 wedge was localised: read_bytes, write_bytes and
# the file offset (pinned at LBA 5583) were all identical across 5 s while IRIX
# sat in a 60-second-timeout retry loop. See docs/27-multiuser-on-hardware.md.
#
# The fd number is found rather than assumed - it has been 5, but that is a
# function of how many images are mounted and in what order.
#
# Usage: bash scripts/diskio.sh [--seconds 10]
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?set MISTER_SSH_KEY in scripts/local.env}"
: "${MISTER_SSH_USER:=root}"
export MSYS_NO_PATHCONV=1

GAP=10
while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) GAP="$2"; shift ;;
        *) echo "usage: bash scripts/diskio.sh [--seconds N]" >&2; exit 2 ;;
    esac
    shift
done

SSH=(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$MISTER_SSH_KEY"
     "$MISTER_SSH_USER@$MISTER_HOST")

# One remote shell for the whole sample: two round trips would put ssh latency
# and the sleep in the same measurement.
timeout $((GAP + 60)) "${SSH[@]}" "
set -u
# Retry: a core relaunch leaves a window with no MiSTer process at all, and
# hitting it should not read as a failure.
PID=''
for i in 1 2 3 4 5; do
    PID=\$(ps w | grep '[M]iSTer' | grep -v grep | awk '{print \$1}' | head -1)
    [ -n \"\$PID\" ] && break
    sleep 2
done
if [ -z \"\$PID\" ]; then echo 'no MiSTer process after 10s - is a core loaded?'; exit 1; fi
echo \"MiSTer pid \$PID\"

# The image fd: whichever open fd points at something under games/.
FD=\$(for f in /proc/\$PID/fd/*; do
        t=\$(readlink \"\$f\" 2>/dev/null)
        case \"\$t\" in */games/*) basename \"\$f\"; break ;; esac
     done)
if [ -n \"\$FD\" ]; then
    echo \"image: \$(readlink /proc/\$PID/fd/\$FD)\"
fi

sample() {
    [ -n \"\$FD\" ] && grep '^pos:' /proc/\$PID/fdinfo/\$FD
    grep -E '^(rchar|read_bytes|write_bytes)' /proc/\$PID/io
}
sample > /tmp/diskio.a
sleep $GAP
sample > /tmp/diskio.b

echo '--- before ---'; cat /tmp/diskio.a
echo '--- after  ---'; cat /tmp/diskio.b
if cmp -s /tmp/diskio.a /tmp/diskio.b; then
    echo
    echo \"VERDICT: FROZEN over ${GAP}s - the core has stopped asking the HPS.\"
    echo '         The wedge is inside the SCSI RTL, not on the ARM side.'
    exit 3
fi
# Real block I/O is the discriminator; rchar alone is input polling.
A=\$(grep -E '^(read_bytes|write_bytes)' /tmp/diskio.a | md5sum)
B=\$(grep -E '^(read_bytes|write_bytes)' /tmp/diskio.b | md5sum)
echo
if [ \"\$A\" = \"\$B\" ]; then
    echo \"VERDICT: NO BLOCK I/O over ${GAP}s (rchar moved, but that is MiSTer's\"
    echo '         own input polling). Idle at a prompt, or wedged.'
else
    echo \"VERDICT: ALIVE - real block I/O over ${GAP}s.\"
fi
"
