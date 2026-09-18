# Documentation

The project's [README](../README.md) covers installing the core, the OSD and
building it. This folder has the rest.

## Using the core

- [Installing IRIX](installing-irix.md) - IRIX 5.3 onto a disk image, from the
  CD in the core's CD-ROM drive (SCSI ID 6) or from an existing installation.

## Reference

How the machine is put together, as it is now.

| | |
|---|---|
| [Address map](reference/address-map.md) | the IP22/IP24 physical address map and the registers the PROM and IRIX use |
| [Chipset](reference/chipset.md) | MC, HPC3, IOC, the interrupt controller, SCSI, the clock, the EEPROM, HAL2 - what each is in this core |
| [CPU](reference/cpu.md) | the R4600 core, how it is attached to the machine, and what was changed in it |
| [CPU validation](reference/cpu-validation.md) | the bare-metal MIPS test suite, in simulation |
| [CPU tests on hardware](reference/cpu-tests-on-hardware.md) | the same suite run as the boot PROM on a DE10-Nano |
| [Boot PROM](reference/boot-prom.md) | the IP24 PROM: images, reset flow, what it expects of the hardware |
| [PROM analysis](reference/prom/README.md) | a teardown of the PROM image: its hardware map, strings, tables |
| [NVRAM and the clock](reference/nvram.md) | where the PROM environment lives, and what survives a reset or a reload |
| [MiSTer integration](reference/mister-integration.md) | the top level: hps_io, DDR3, the frame buffer, video out |
| [Simulation](reference/simulation.md) | the Verilator harness and how to use it |
| [Deploying and debugging](reference/deploy-and-debug.md) | getting a build onto a MiSTer, and the ways to look inside a running one |

## Design notes

Dated engineering records of how particular parts were built, measured and
verified. They explain why the core is the way it is; where a note and the
reference disagree, the reference is current.

| | |
|---|---|
| [Newport pixel DMA](design/newport-vdma.md) | the MC's VDMA engine, and why X drew a black screen without it |
| [SCSI fit and frame buffer layout](design/scsi-fit-and-framebuffer-layout.md) | fitting the SCSI subsystem, and the frame buffer at four bytes a pixel |
| [SCSI block cache](design/scsi-block-cache.md) | the per-target read-ahead/write-behind cache between the SCSI targets and the SD card |
| [SCSI synchronous negotiation](design/scsi-sync-negotiation.md) | a fifth of the boot lost to a failing negotiation, and the fix |
| [Speed: TLB, instruction cache, counters](design/cpu-speed-tlb-icache.md) | where an IRIX session's time goes, measured |
| [Cache fill latency](design/cache-fill-latency.md) | a line fill's clocks accounted for, and line writes |
| [R4600 accuracy, the clock, the disk path](design/r4600-accuracy-clock-disk.md) | the CPU against real Indys, the DS1386, the disk byte path |
| [HPC3's register file](design/hpc3-register-file.md) | moving HPC3's storage into block RAM |
| [REX3 rendering](design/rex3-rendering.md) | the graphics engine's full command set, and the bench that checks it against IRIS |
| [REX3 source audit](design/rex3-source-audit.md) | REX3 against SGI's specs, the guest's own GL libraries, IRIS and MAME, and the plan that followed |

## History

[history.md](history.md) lists the numbered engineering notes this folder grew
from. Comments in the source still cite them as `docs/NN`; the ones not kept
here can be read from git with the command given there.
