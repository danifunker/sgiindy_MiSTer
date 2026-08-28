# SCSI

Three pieces, only one of which is written here:

| | What | Where from |
|---|---|---|
| **Target** | `scsi.v` — a target-only SCSI device: the bus phase machine, REQ/ACK, and the disk command set (TEST UNIT READY, INQUIRY, READ CAPACITY, MODE SENSE/SELECT, REQUEST SENSE, READ/WRITE 6 and 10, FORMAT). Reads and writes blocks through MiSTer's `sd_lba`/`sd_buff_*` interface. | Vendored from the MacLC MiSTer core |
| **Initiator** | `wd33c93.sv` — the WD33C93B the Indy actually has | Written here |
| **DMA** | the HPC3 SCSI DMA engine | `sgi_hpc3.sv` |

## Why a Mac core's SCSI target works on an SGI

A SCSI target does not know or care what kind of machine is driving it. It sees
selection, then REQ/ACK byte handshakes through COMMAND, DATA, STATUS and
MESSAGE phases, and it answers with the standard command set. `scsi.v` is
written as a target only — the Mac-specific parts of that core live in its
initiator (`ncr5380.sv`), which is exactly the piece being replaced here.

Everything Mac-flavoured in `scsi.v` is behind a parameter that defaults off:
`TOOLBOX_ENABLE` (BlueSCSI Toolbox), `CDROM` and `CDCHANGER_ENABLE` (AppleCD
command set and CD audio, which pulls in `cd_audio.sv` through a
`generate`). A plain disk target needs none of them.

`scsi_vendor.vh` sets the 8-byte INQUIRY vendor string. It is deliberately a
separate file so a build can change it without touching tracked source.

## Phase encoding

`scsi.v` names its phases from the target's point of view, which reads
backwards from the initiator's. The `msg`/`cd`/`io` outputs are standard, so
decode those rather than the names:

| `scsi.v` phase | msg,cd,io | SCSI phase | Direction |
|---|---|---|---|
| `PHASE_CMD_IN` | 0,1,0 | COMMAND | initiator → target |
| `PHASE_DATA_IN` | 0,0,0 | DATA OUT | initiator → target |
| `PHASE_DATA_OUT` | 0,0,1 | DATA IN | target → initiator |
| `PHASE_STATUS_OUT` | 0,1,1 | STATUS | target → initiator |
| `PHASE_MESSAGE_OUT` | 1,1,1 | MESSAGE IN | target → initiator |

## Provenance

`scsi.v`, `scsi_vendor.vh` and `cd_audio.sv` are taken from the MacLC MiSTer
core, which carries no per-file licence header. They are used here on the
understanding that both cores are the same author's work. Anyone republishing
this repository should confirm that before shipping.
