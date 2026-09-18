# The numbered notes this documentation grew from

Until the 2026-09-18 cleanup the docs were a numbered series of engineering notes, 
written as the work happened - plans, bug hunts, build records and the
prompts that carried one working session into the next. Comments in the
RTL, the benches and the scripts still cite them by number ("docs/33",
"docs/56 3.1"). The ones that explain how the core works today were kept
and renamed; the rest are in the git history and can be read with the
command beside them.

| note | title | now |
|---|---|---|
| <a id="00"></a>00 | Overview — what `~/mistersgi` is | `git show 58268db:docs/00-overview.md` |
| <a id="01"></a>01 | Source inventory — `~/mistersgi` | `git show 58268db:docs/01-source-inventory.md` |
| <a id="02"></a>02 | IP22 / IP24 address map and registers | [`docs/reference/address-map.md`](reference/address-map.md) |
| <a id="03"></a>03 | Boot PROM — images, reset flow, NVRAM, bring-up checklist | [`docs/reference/boot-prom.md`](reference/boot-prom.md) |
| <a id="04"></a>04 | CPU options | `git show 58268db:docs/04-cpu.md` |
| <a id="05"></a>05 | How the existing RTL works (`DE1_TOP.v`) | `git show 58268db:docs/05-existing-rtl.md` |
| <a id="06"></a>06 | Simulation harness | [`docs/reference/simulation.md`](reference/simulation.md) |
| <a id="07"></a>07 | Porting plan | `git show 58268db:docs/07-mister-port-plan.md` |
| <a id="08"></a>08 | Resume prompt | `git show 58268db:docs/08-resume-prompt.md` |
| <a id="09"></a>09 | CPU validation: the IRIS bare-metal test suite | [`docs/reference/cpu-validation.md`](reference/cpu-validation.md) |
| <a id="10"></a>10 | The CPU in this core | [`docs/reference/cpu.md`](reference/cpu.md) |
| <a id="11"></a>11 | Running the CPU test suite on real hardware | [`docs/reference/cpu-tests-on-hardware.md`](reference/cpu-tests-on-hardware.md) |
| <a id="12"></a>12 | The IP24 chipset, as this core implements it | [`docs/reference/chipset.md`](reference/chipset.md) |
| <a id="13"></a>13 | The HPC3 SCSI DMA engine | `git show 58268db:docs/13-scsi-dma-plan.md` |
| <a id="14"></a>14 | Work item: the two devices `hinv` still does not list | `git show 58268db:docs/14-audio-and-graphics.md` |
| <a id="15"></a>15 | Work item: get `syn/` through Quartus and read the numbers | `git show 58268db:docs/15-synthesis-prompt.md` |
| <a id="16"></a>16 | Newport graphics — the subsystems, and the order they unblock each other | `git show 58268db:docs/16-newport-plan.md` |
| <a id="17"></a>17 | NVRAM persistence — where the environment lives, and how to keep it | [`docs/reference/nvram.md`](reference/nvram.md) |
| <a id="18"></a>18 | MiSTer integration — the top level, and what it cannot do yet | [`docs/reference/mister-integration.md`](reference/mister-integration.md) |
| <a id="19"></a>19 | Running it on a DE10-Nano — the build, the deploy, and the three ways to look | [`docs/reference/deploy-and-debug.md`](reference/deploy-and-debug.md) |
| <a id="20"></a>20 | Releases | `git show 58268db:docs/20-releases.md` |
| <a id="21"></a>21 | OPEN BUG: `init` dies, and on HARDWARE it is not the instruction cache | `git show 58268db:docs/21-icache-bug.md` |
| <a id="22"></a>22 | Work item: diff IRIX's initialisation against IRIS, instruction by instruction | `git show 58268db:docs/22-iris-init-diff-prompt.md` |
| <a id="23"></a>23 | Where IRIX's initialisation diverges: `init`'s table pointer is NULL | `git show 58268db:docs/23-init-divergence.md` |
| <a id="24"></a>24 | Work item: find and fix the lost store that kills `init` | `git show 58268db:docs/24-fix-lost-store-prompt.md` |
| <a id="25"></a>25 | The lost store: two TLB faults, taken in the wrong order | `git show 58268db:docs/25-lost-store-tlb-order.md` |
| <a id="26"></a>26 | Work item: finish the TLB/EPC fix and validate it on hardware | `git show 58268db:docs/26-resume-tlb-epc-fix.md` |
| <a id="27"></a>27 | IRIX 5.3 reaches multiuser on hardware | `git show 58268db:docs/27-multiuser-on-hardware.md` |
| <a id="28"></a>28 | Work item: the SCSI wedge that stops IRIX finishing fsck | `git show 58268db:docs/28-resume-scsi-wedge.md` |
| <a id="29"></a>29 | the fsck SCSI wedge - what code reading killed, and the DDR3 beacon | `git show 58268db:docs/29-scsi-wedge-beacon.md` |
| <a id="30"></a>30 | Work item: finish the fsck SCSI wedge fix — READ THE DIAGNOSTICS, STOP GUESSING | `git show 58268db:docs/30-scsi-wedge-resume.md` |
| <a id="31"></a>31 | the fsck wedge's real second half - the driver spins on ASR before it will listen | `git show 58268db:docs/31-scsi-wedge-asr.md` |
| <a id="32"></a>32 | Work item: the Newport pixel-DMA black screen (and two small SCSI bugs) | `git show 58268db:docs/32-resume-newport-dma.md` |
| <a id="33"></a>33 | The Newport pixel-DMA black screen: the MC's VDMA engine was never built | [`docs/design/newport-vdma.md`](design/newport-vdma.md) |
| <a id="34"></a>34 | Work item: Ethernet, CPU throughput, and the rest of the video stack | `git show 58268db:docs/34-resume-net-cpu-video.md` |
| <a id="35"></a>35 | Work item: land the SCSI fit, then video perf, desktop input, the R4600 CPU swap, and Ethernet | `git show 58268db:docs/35-resume-scsi-fit-video-cpu-r4600.md` |
| <a id="36"></a>36 | The SCSI fit lands; the frame buffer goes to four bytes a pixel | [`docs/design/scsi-fit-and-framebuffer-layout.md`](design/scsi-fit-and-framebuffer-layout.md) |
| <a id="37"></a>37 | Work item: verify build 18 on the board, then the CD-ROM attach, the burst fill path, the R4600 swap, Ethernet | `git show 58268db:docs/37-resume-cd-attach-fill-burst-cpu.md` |
| <a id="38"></a>38 | Work item: the R4600 CPU swap, then the CD-ROM attach, the burst fill path, Ethernet | `git show 58268db:docs/38-resume-r4600-cd-fill-net.md` |
| <a id="39"></a>39 | The R4600 swap, assessed; burst line fills instead, and why the data cache stayed 8 KB | `git show 58268db:docs/39-burst-fills-dcache.md` |
| <a id="40"></a>40 | Work item: a 16 KB data cache that IRIX survives - physically indexed first, two-way as the backup; then the CD-ROM attach, the burst-write path, Ethernet | `git show 58268db:docs/40-resume-bigger-dcache.md` |
| <a id="41"></a>41 | Work item: the 16 KB physically-indexed data cache BOOTS IRIX's init (fixed) - now settle the post-init boot wedge, then merge + fit + board | `git show 58268db:docs/41-resume-dcache-boot-wedge.md` |
| <a id="42"></a>42 | Work item: the 16 KB physical D-cache PASSES the boot gate (the post-init sim wedge is pre-existing) - merge done, fit + board next | `git show 58268db:docs/42-resume-merge-fit-board.md` |
| <a id="43"></a>43 | Work item: FULL RE-VENDOR of the CPU onto the Killer Instinct R4600 base (the user's explicit choice) - do this WITH FABLE | `git show 58268db:docs/43-resume-ki-cpu-revendor.md` |
| <a id="44"></a>44 | Work item: FINISH the KI R4600 re-vendor - the 3-way merge is committed, 34 conflicts remain to resolve - WITH FABLE | `git show 58268db:docs/44-resume-ki-revendor-conflicts.md` |
| <a id="45"></a>45 | Work item: the KI R4600 re-vendor is DONE in the tree and passes every sim gate - fit build 23, put it on the board, merge | `git show 58268db:docs/45-resume-ki-revendor-board.md` |
| <a id="46"></a>46 | Work item: the core's video no longer reaches the MiSTer scaler (black picture, OSD visible) on EVERY build - find it; then the KI R4600 follow-ups | `git show 58268db:docs/46-resume-hdmi-black-and-followups.md` |
| <a id="47"></a>47 | Work item: build 24 still panics INTERMITTENTLY with `init died (why = 2, what = 0xb)` on the board - make the I-cache physically indexed (PIPT), measure the boot rate, then the follow-ups | `git show 58268db:docs/47-resume-init-sigsegv-icache-pipt.md` |
| <a id="48"></a>48 | Work item: after release SGIIndy_20260907 - the hardware this core still lacks, and a SCSI block cache ported from MacQuadra800 | `git show 58268db:docs/48-resume-missing-hardware-scsi-cache.md` |
| <a id="49"></a>49 | Work item: the SCSI block cache - build 26 | [`docs/design/scsi-block-cache.md`](design/scsi-block-cache.md) |
| <a id="50"></a>50 | Speed: where an IRIX session's time goes, and builds 28-30 | [`docs/design/cpu-speed-tlb-icache.md`](design/cpu-speed-tlb-icache.md) |
| <a id="51"></a>51 | The CPU against real Indys, the clock, and the disk byte path | [`docs/design/r4600-accuracy-clock-disk.md`](design/r4600-accuracy-clock-disk.md) |
| <a id="52"></a>52 | Where a fill's clocks go, 3,000 ALMs back, and fewer trips to DDR3 | [`docs/design/cache-fill-latency.md`](design/cache-fill-latency.md) |
| <a id="53"></a>53 | The synchronous-transfer negotiation, failed in front of every command | [`docs/design/scsi-sync-negotiation.md`](design/scsi-sync-negotiation.md) |
| <a id="54"></a>54 | HPC3's register file, and what it cost to be flip-flops | [`docs/design/hpc3-register-file.md`](design/hpc3-register-file.md) |
| <a id="55"></a>55 | The rest of REX3's command set, and the corpus that named it | [`docs/design/rex3-rendering.md`](design/rex3-rendering.md) |
| <a id="56"></a>56 | REX3 against its sources, and the plan to make it right | [`docs/design/rex3-source-audit.md`](design/rex3-source-audit.md) |

`docs/FEATURES_EVALUATE.md` (a wish list from before the port) and
`docs/prom-reference/` (now [`docs/reference/prom/`](reference/prom/README.md)) were
outside the numbering. The old top-level `Readme.md` and the release history
`docs/20-releases.md` are in the same commit.
