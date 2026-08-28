# Features to evaluate

Things deliberately **not** being built yet, each with the evidence for why and
what it would cost. This is not a backlog — `docs/08-resume-prompt.md` has the
work queue. This is the list of things somebody has already looked at and
decided to leave alone, so the next session does not re-derive the decision.

Move an item out of here the moment it stops being true.

---

## CD audio — deferred

**Decision: build the CD-ROM as a data-only target. No CD audio.**

`scsi.v` already carries most of a CD-ROM: `cd_inquiry_byte` reports device
type `0x05`, removable, ANSI SCSI-2, "SONY CD-ROM"; READs address 2048-byte
logical blocks and are scaled ×4 at latch time so the whole 512-byte ring
machinery runs unmodified; READ CAPACITY reports `img_blocks/4 - 1`; MODE SENSE
pages 0x0E, 0x2A and 0x31 are there.

What is not here is `rtl/cd_audio.sv`. It is instantiated by
`generate if (CDROM != 0) begin : g_cd_audio` and was deliberately not vendored
from the MacLC core — `rtl/scsi/README.md` records why: it pulls in a volume
lookup table this core has no use for. So **`CDROM(1)` does not elaborate
today**.

The way out is already written. The `else begin : g_no_cd_audio` branch beside
it assigns every `ca_*` signal a static value — TOC, audio status, the block
fetch channel, the lot. A data-only CD-ROM needs exactly those tie-offs and
nothing from the audio engine.

**Why defer it:** IRIX install media is data. Nothing this machine is being
built to run needs Red Book audio off the CD, and the audio path it would feed
does not exist either — see HAL2 below.

**What it would cost to change the decision:** vendor `cd_audio.sv` and its
volume table, and confirm the licensing note in `rtl/scsi/README.md` still
covers it.

## Secondary cache — not needed, and faking it would break POST

**Decision: keep reporting no secondary cache.**

`hinv` on a real Indy prints `Secondary cache size: 1024 Kbytes`. This core does
not, and that is correct rather than missing.

`rtl/cpu/r4300/cpu_cop0.vhd` reports `Config` bits 23:16 as `"00000110"`, so
**`Config.SC` (bit 17) is 1 — no secondary cache** — and the comment beside
`PRESENT_AS_R4400` says so out loud: "Presenting as the PC variant: Config.SC
stays 1, no secondary cache."

**This is a real configuration, not a shortcut.** SGI shipped primary-cache-only
parts; an R4x00**PC** has no L2 and IRIX drives one. Reporting no L2 is honest,
and `hinv` omitting the line is what a PC part looks like.

**Faking it is worse than leaving it.** Clearing `Config.SC` is one bit, and it
would immediately be caught: the PROM has a *"Secondary and primary caches
address/data test"* (`0xBFC06B60`) and a `"Secondary cache size is 0x%x (%d
Kbytes)\r\n"` sizing routine, both of which would then run against a cache that
does not exist. It would also hand IRIX an L2 to flush and manage. One bit of
cosmetics, bought with a POST failure and a kernel that maintains imaginary
hardware.

**Revisit only if** something is found that requires an SC part specifically.
Nothing has been.

## "66 Mhz" — this is a measurement, and it is not a clock we can set

**Decision: leave it. Do not chase the number.**

A real Indy prints `Processor: 66 Mhz R4400`. This core prints `16 Mhz`. That
gap is real, and it is not a PLL setting.

The figure comes from `FUN_bfc0c5b8`, which combines two things:

* `FUN_bfc311e0` — a calibration of the CPU against the **DS1386 RTC**
  (`cpu_restart_rtc` at `0xBFC0DC14`, then polling `RTC_reg01`). This is the
  wall-clock reference, and its result is cached at `RAM+0x745DC0`.
* `FUN_bfc31594` — a fixed 512-iteration loop of two instructions
  (`bgtz` to itself with `addiu $t5,-1` in the delay slot) bracketed by two
  `mfc0 $Count` reads, returning the elapsed `Count`.

So what is reported is **how fast this core actually executes an uncached loop,
measured against a real time base**. `Count` itself is right: `cpu_cop0.vhd`
increments a 33-bit counter every cycle and reads back bits `[32:1]`, half the
pipeline clock, as an R4400 does.

The loop lives at `0xBFC3159C`, which is KSEG1 — architecturally uncached, and
the core correctly refuses to cache it. Every instruction is a bus round trip
of about nine cycles, so an iteration costs roughly 20 clocks against about two
on a real R4400. **That ratio is the 16.**

Three things are already ruled out by measurement rather than argument:

| Tried | Result |
|---|---|
| turning both primary caches on | still 16 — the loop is in KSEG1 and cannot be cached |
| doubling `PIT_TICK_DIV` | still 16 — it is not the 8254 |
| doubling `RTC_TICK_DIV` | still 16 |

**So the only honest way to raise it is to make uncached instruction fetch
genuinely faster** — fewer cycles per bus transaction — which is real memory
controller and pipeline work, not a constant. The dishonest way is to slow the
RTC reference until the arithmetic comes out at 66, which would make the number
right and every `delay()` IRIX derives from it wrong by the same factor.

**Worth knowing before anyone decides this matters:** nothing has been through
Quartus. `sgiindy.sv` is still the stock MiSTer template and no resource or
timing numbers exist, so there is no evidence about what this design closes at
on a DE10-Nano. The MiSTer N64 core runs this same CPU at 93.75 MHz, which is
the only data point available.

## Memory size — a flag, not a feature

A real Indy `hinv` shows `Memory size: 256 Mbytes`; this core shows 64. That is
`--ram-mb`, which defaults to 64 and already accepts other values. It is
mentioned here only so nobody files it as a gap.
