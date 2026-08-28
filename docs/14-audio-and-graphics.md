# Work item: the two devices `hinv` still does not list

Paste everything below the line as the opening message of a fresh session. This
is a **separate work item** from `docs/08-resume-prompt.md`'s queue; read that
file first for the state of the machine, then this one for the task.

---

You are continuing work on the **SGI Indy (IP24)** core in `~/repos/sgiindy_MiSTer`.
Read `docs/08-resume-prompt.md` first — it is the state of the machine and it is
kept honest. Then `docs/12-chipset.md` before touching `rtl/sgi/`.

## The target

`hinv` on a real Indy, against `hinv` on this core today:

```
                   System: IP22                     <- same
                Processor: 66 Mhz R4400, with FPU    <- see docs/FEATURES_EVALUATE.md
     Primary I-cache size: 16 Kbytes                 <- same
     Primary D-cache size: 16 Kbytes                 <- same
     Secondary cache size: 1024 Kbytes               <- see docs/FEATURES_EVALUATE.md
              Memory size: 256 Mbytes                <- --ram-mb
                 Graphics: Indy 24-bit               <- MISSING. This work item.
                SCSI Disk: scsi(0)disk(1)            <- done
                    Audio: Iris Audio Processor: version A2 revision 4.1.0
                                                     <- MISSING. This work item.
```

Two lines are genuinely missing. **They are wildly different sizes, and the
small one should be done first** — do not let the second swallow the first.

## 1. Audio — probably a small change, not an audio implementation

**`hinv` prints the audio line from a revision register, not from working
audio.** The format string is at `0xBFC54B14`:

```
"%*s: Iris Audio Processor: version %s revision %d.%d.%d\n"
```

referenced from `0xBFC41698`, inside the ARCS node printer's own family —
i.e. the same tree walk that now prints `SCSI Disk`, so the mechanism is
already proven.

`docs/02-address-map.md` has the HAL2 map, and it is already written down:

| Address | Register | Note |
|---|---|---|
| `0x1FBD8000` | HAL2 base | currently stubbed to `0xFFFFFFFF` |
| `+0x10` | `HAL2_ISR` | **bit 0 = busy**; the PROM spins on it after every indirect access |
| `+0x20` | `HAL2_REV` | **bit 15 set ⇒ audio not present**, and the whole audio path is skipped |
| `+0x30` | `HAL2_IAR` | writing latches the indirect access |
| `+0x40`…`+0x70` | `HAL2_IDR0`…`IDR3` | indirect data |

**That is why the line is missing.** The stub returns `0xFFFFFFFF`, bit 15 is
set, and the PROM concludes there is no audio and skips it. IRIS returns
`HAL2_REV = 0x4010` (`src/hal2.rs`, line 934), which has bit 15 clear.

So the first thing to try is small: return `0x4010` from `HAL2_REV`, implement
the `ISR` busy handshake the PROM spins on, and see whether `hinv` prints the
line. **Do that before planning anything larger.** If it works, the audio line
costs a register model and no audio path at all.

Be honest in the commit about what it is: reporting a device, not implementing
one. Anything that opens the audio device for real will find nothing behind it,
exactly as `docs/02-address-map.md` says.

**Verify the revision arithmetic rather than assuming it.** The string wants a
version string and three numbers, and `0x4010` has to produce `A2` and
`4.1.0`. Find the code that formats it — it is near `0xBFC41698` — and confirm
the field split before claiming a match. If `0x4010` produces something else,
that is a finding, not a failure.

## 2. Graphics — this is the rest of the machine

`Graphics: Indy 24-bit` means **Newport**: VC2, REX3 and XMAP9. This is not a
register model; it is the largest single device left, and `docs/08`'s milestone
list has always treated it as the end of the road rather than a step on it.

Do not start it as part of the audio change. Scope it separately, and expect the
first honest deliverable to be "the PROM stops printing `Cannot open video() for
output`", not a desktop.

What exists to work from:

* `~/repos/iris` has readable implementations: `rex3.rs`, `vc2.rs`, `xmap9.rs`.
  It boots IRIX 6.5 to a desktop, so it is the tiebreaker wherever the specs are
  silent about what software actually expects.
* `reference/specs/` has the GIO64 specification, which is how Newport is
  attached. The PDFs have no text layer but the streams are plain Flate; a dozen
  lines of Python pulls the register map out. Do that rather than guessing.
* `docs/02-address-map.md` records Newport as one of the two devices still
  answering as unclaimed cycles.

**Use the unclaimed-address summary.** It is printed on every exit of the
headless harness and it is the tool that built the entire chipset: the next
thing to build is nearly always the address at the top of a poll loop.

## How to work

`docs/09-cpu-validation.md` determines *how you work* and it has not changed.
The two rules that matter most here:

**Every claim about behaviour must be backed by a simulation run, not by
reading the RTL.** `docs/13-scsi-dma-plan.md` has the current cautionary tale:
the DATA IN path returned every byte one place late for months, every boot
looked fine, and no test could see it because everything being read was zeroes.

**Before explaining an absent line, prove the line is absent.** `--watch HEX`
reports every bus access to an address, and PROM text is uncached, so a watch
on a PROM address is a PC watch. One watch on the address of the `printf` that
would emit a line settles in a single run whether the machine is failing to
print it or the harness is failing to show it. This project has now spent two
separate investigations on lines that were never missing.

Add a ratchet for whatever you finish, in the shape of `tests/run-scsi.sh` —
and when a run is stopped on console text, stop on text that comes *after*
everything being asserted. `--stop-on` fires on the cycle its substring
completes, and a substring is not a line.
