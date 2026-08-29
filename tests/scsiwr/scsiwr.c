/*
 * scsiwr - send a byte OUT through the SCSI data path, which nothing in this
 * project had ever done.
 *
 * WHY THIS EXISTS. DATA IN is exercised by every boot: the PROM's INQUIRY and
 * its volume-header read both come back through the WD33C93B and the HPC3's
 * SCSI DMA channel, so tests/run-scsi.sh covers it end to end. DATA OUT had
 * nothing. The descriptor side of the engine is tested by tests/run-dma.sh and
 * the initiator has had a memory-to-device path in it since the engine was
 * built, but no byte had ever gone out through it, because **nothing in a PROM
 * boot writes to a disk**. An untested direction in a bus master is not a
 * small gap; it is half the engine.
 *
 * The gap turned out to be real, and it was not in either of the two places
 * that were being maintained. `scsi.v` assembles a written block correctly and
 * offers it on `sd_buff_din`; `wd33c93.sv` and `hpc3_scsi_dma.sv` both carry
 * the memory-to-device path. In between, `rtl/scsi/sgi_scsi.sv` left the
 * target's `sd_buff_din` unconnected and tied the module's own output to
 * `16'h0000`. Every byte written to a disk would have arrived as zero, and the
 * only way to see it was to write one and read it back - which is this file.
 *
 * WHAT IT DOES, in six phases, each one a thing that had never been done:
 *
 *   1. one WRITE(6) of a 512-byte block, read back with READ(6);
 *   2. a MULTI-BLOCK WRITE(6) - four blocks in one command - read back the
 *      same way;
 *   3. WRITE(10) and READ(10), which is a ten-byte CDB and therefore a
 *      different path through the WD33C93B's CDB register file and a
 *      different length decode in the target;
 *   4. the same four blocks through a DESCRIPTOR CHAIN of three data
 *      descriptors of unequal size, read back through a chain of two. The
 *      splits differ deliberately on the two sides, so a chaining bug in one
 *      direction cannot be cancelled by the same bug in the other;
 *   5. a READ(10) off the CD-ROM on ID 6, which addresses 2048-byte logical
 *      blocks. Nothing in this project had ever read a byte off a CD.
 *
 * Phases 2-5 exist because of a real failure: the IRIX 5.3 installer copies
 * itself from the CD to the disk, prints "Copy complete", and then panics on a
 * load from address zero. The copy is the first substantial write this core
 * has ever done and the first bulk read off a CD, and before this file was
 * widened the whole of that path was covered by exactly one WRITE(6) of one
 * block. See docs/13-scsi-dma-plan.md.
 *
 * The pattern is deliberately not constant and not byte-symmetric: a path that
 * drops the low half of every 16-bit unit, or swaps the two halves, or shifts
 * the block by one byte, all pass a test written with 0xFF and all fail this
 * one. Each phase uses a different seed, so a phase that moves no data at all
 * cannot pass on the previous phase's bytes still sitting in the buffer. See
 * `pat()`.
 *
 * IT WRITES TO A SCRATCH IMAGE, not to tests/disks/blank8m.img.
 * The harness commits writes to its in-memory copy only and never back to the
 * file, but the run script still points this at its own image: a test that
 * depends on the harness's discretion to avoid rewriting a checked-in fixture
 * is one refactor away from destroying it.
 *
 * EVERY BUFFER HERE IS UNCACHED, for the reason tests/dma/dmatest.c gives at
 * length: the image runs from KSEG0, the engine reads main memory, and nothing
 * in this core snoops. The read-back buffer matters as much as the write one -
 * a stale cache line there would compare equal to whatever was written into it
 * through KSEG0 and prove nothing.
 *
 * Freestanding and self-contained: no libc, no PROM, one file plus start.S.
 */

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned int   u32;

/* ---- the machine ------------------------------------------------------- */

#define IOC          0xBFBD9800u
#define SCC_B_CMD    (IOC + 0x30 + 3)
#define SCC_B_DATA   (IOC + 0x34 + 3)

/* HPC3 SCSI channel 0, KSEG1. Same six registers as tests/dma. */
#define HD0_CBP      0xBFB90000u
#define HD0_NBDP     0xBFB90004u
#define HD0_BC       0xBFB91000u
#define HD0_CTRL     0xBFB91004u
#define HD0_DMACFG   0xBFB91010u

#define CTRL_INT     0x01u
#define CTRL_DIR     0x04u
#define CTRL_FLUSH   0x08u
#define CTRL_ACTIVE  0x10u
#define CTRL_RESET   0x40u

#define DESC_EOX     0x80000000u

/* The WD33C93B's two ports, in IOC's HD0 window. */
#define WD_ADDR      0xBFBC0003u
#define WD_DATA      0xBFBC0007u

/* Registers, by index into the chip's own address latch. */
#define WD_OWN_ID     0x00u
#define WD_CONTROL    0x01u
#define WD_TIMEOUT    0x02u
#define WD_CDB1       0x03u
#define WD_TARGET_LUN 0x0Fu
#define WD_CMD_PHASE  0x10u
#define WD_COUNT_MSB  0x12u
#define WD_COUNT_2ND  0x13u
#define WD_COUNT_LSB  0x14u
#define WD_DEST_ID    0x15u
#define WD_STATUS     0x17u
#define WD_COMMAND    0x18u

#define WD_C_RESET        0x00u
#define WD_C_SEL_ATN_XFER 0x08u

/* Auxiliary Status Register bits. */
#define ASR_DBR      0x01u
#define ASR_CIP      0x10u
#define ASR_LCI      0x40u
#define ASR_INT      0x80u

/* SCSI Status Register values this image expects to see. */
#define WD_S_RESET          0x00u
#define WD_S_SELECT_XFER_OK 0x16u

/* Test device, for the exit code. */
#define TD_SIGNATURE 0xBF400000u
#define TD_EXIT      0xBF40000Cu
#define TD_MAGIC     0x49524953u

#define RD8(a)     (*(volatile u8  *)(unsigned long)(a))
#define WR8(a, v)  (*(volatile u8  *)(unsigned long)(a) = (u8)(v))
#define RD32(a)    (*(volatile u32 *)(unsigned long)(a))
#define WR32(a, v) (*(volatile u32 *)(unsigned long)(a) = (u32)(v))

/* The targets this image talks to. Must match the run script's --disk flags,
 * and both IDs must be in sgi_scsi.sv's TARGET_EN. ID 6 elaborates as a CD-ROM
 * because it is in CDROM_IDS, which is an elaboration-time choice: a drive is
 * a different device from a disk, not a disk with a different file in it. */
#define TARGET_ID    1
#define CDROM_ID     6

#define BLOCK_BYTES  512
#define CD_BLOCK     2048           /* the CD-ROM's logical block, from scsi.v */

/* Four blocks is the smallest multi-block transfer that can show a chaining
 * bug in more than one way, and 2048 bytes is also exactly one CD-ROM logical
 * block. BIG_BLOCKS is the phase that answers "does this hold up at a size
 * anything real would ask for": 32 blocks is 16 KB, which is bigger than every
 * buffer in the path and is the size at which a byte counter that is one bit
 * too narrow, or a descriptor whose length field wraps, stops being invisible.
 * The IRIX installer's copy is megabytes; this is the largest transfer that
 * still leaves the test under a minute. */
#define BLOCKS       4
#define BIG_BLOCKS   32
#define CD_BLOCKS    4
#define BUF_BYTES    (BIG_BLOCKS * BLOCK_BYTES)

/* ---- console ----------------------------------------------------------- */

#define RR0_TX_EMPTY 0x04u

static void pause(void)
{
    int i;
    for (i = 0; i < 8; i++) __asm__ __volatile__("" ::: "memory");
}

static void wr(int reg, u8 val)
{
    WR8(SCC_B_CMD, (u8)reg);
    pause();
    WR8(SCC_B_CMD, val);
    pause();
}

/* Identical to tests/dma/dmatest.c's, and for the same reason: with no PROM
 * the transmitter comes up disabled and the image prints nothing. */
static void scc_init(void)
{
    wr(9, 0x40);
    pause(); pause();
    wr(4, 0x44);
    wr(1, 0x00);
    wr(3, 0xC0);
    wr(5, 0x60);
    wr(9, 0x00);
    wr(10, 0x00);
    wr(11, 0x56);
    wr(12, 0x00);
    wr(13, 0x00);
    wr(14, 0x03);
    wr(3, 0xC1);
    wr(5, 0x68);
}

static void putc_scc(int c)
{
    int spins = 0;
    while (!(RD8(SCC_B_CMD) & RR0_TX_EMPTY))
        if (++spins > 200000) return;
    WR8(SCC_B_DATA, (u8)c);
}

static void puts_scc(const char *s)
{
    while (*s) putc_scc(*s++);
}

static void puthex(u32 v)
{
    static const char d[] = "0123456789abcdef";
    int i;
    for (i = 28; i >= 0; i -= 4) putc_scc(d[(v >> i) & 0xF]);
}

/* ---- the harness ------------------------------------------------------- */

static int failures;

static void check(int ok, const char *what)
{
    puts_scc(ok ? "  ok   " : "  FAIL ");
    puts_scc(what);
    putc_scc('\n');
    if (!ok) failures++;
}

static void check_eq(u32 got, u32 want, const char *what)
{
    int ok = (got == want);
    puts_scc(ok ? "  ok   " : "  FAIL ");
    puts_scc(what);
    if (!ok) {
        puts_scc("  want ");
        puthex(want);
        puts_scc(" got ");
        puthex(got);
    }
    putc_scc('\n');
    if (!ok) failures++;
}

/* ---- memory ------------------------------------------------------------ */

/* Room for four data descriptors and the EOX marker, and two multi-block
 * buffers. Aligned to 16 because the spec requires descriptors to be quadword
 * aligned. */
static u32 pool[32]              __attribute__((aligned(16)));
static u8  wbuf[BUF_BYTES]       __attribute__((aligned(16)));
static u8  rbuf[BUF_BYTES]       __attribute__((aligned(16)));

static u32 phys(const void *p)
{
    return (u32)(unsigned long)p & 0x1FFFFFFFu;
}

static u32 uncached(u32 pa)
{
    return pa | 0xA0000000u;
}

static void desc(int n, u32 bp, u32 cnt_flags, u32 next)
{
    u32 at = uncached(phys(pool) + (u32)n * 16u);
    WR32(at + 0, bp);
    WR32(at + 4, cnt_flags);
    WR32(at + 8, next);
    WR32(at + 12, 0);
}

/* The pattern. Every byte is distinct from its neighbours in both halves of
 * its 16-bit unit, so the three failures this path can plausibly have - a
 * dropped half, a swapped pair, a one-byte shift - each change the compare.
 * `i * 7` walks the whole byte range without repeating within a pair, and the
 * `>> 8` and `>> 16` terms keep any block of a multi-block transfer from being
 * a copy of another, which is what a chaining bug that repeats a descriptor
 * would otherwise look like.
 *
 * `seed` is per phase. Without it a phase whose transfer moved nothing would
 * compare the previous phase's bytes, still in the buffer, against the
 * previous phase's expectation and pass. */
static u8 pat(u32 i, u32 seed)
{
    return (u8)((i * 7u) ^ (i >> 8) ^ (i >> 16) ^ seed);
}

/* The CD-ROM image's pattern, which is built by tests/run-scsiwr.sh and has to
 * agree with it byte for byte. Deliberately a different shape from pat() - a
 * test that computed the disc's contents with the same function it uses for
 * the disk could pass on a path that had confused the two. */
static u8 cd_pat(u32 i)
{
    return (u8)((i * 7u) ^ (i >> 11) ^ 0x5Au);
}

static void fill(u8 *p, u32 n, u32 seed)
{
    u32 i;
    for (i = 0; i < n; i++) p[i] = pat(i, seed);
}

/* Read and write through KSEG1, so nothing here is answered by a cache line
 * the engine cannot see. */
static u8 rd_buf(const u8 *base, int i)
{
    return RD8(uncached(phys(base)) + (u32)i);
}

static void wr_buf(u8 *base, int i, u8 v)
{
    WR8(uncached(phys(base)) + (u32)i, v);
}

/* ---- the WD33C93B ------------------------------------------------------ */

static u8 asr(void)
{
    return RD8(WD_ADDR);
}

static void wd_wr(u8 reg, u8 val)
{
    WR8(WD_ADDR, reg);
    WR8(WD_DATA, val);
}

static u8 wd_rd(u8 reg)
{
    WR8(WD_ADDR, reg);
    return RD8(WD_DATA);
}

/* Wait for the chip to raise INT, then read the status register - which is
 * both the answer and what clears the interrupt. Returns 0xFF if it never
 * came, which no real status is. */
static u8 wait_int(void)
{
    int i;
    for (i = 0; i < 400000; i++)
        if (asr() & ASR_INT) return wd_rd(WD_STATUS);
    return 0xFFu;
}

/* Issue a command, honouring the one rule of the part that this project has
 * already got wrong once: a command written while an interrupt is still
 * pending bounces off LCI and has to be retried after the stale interrupt is
 * cleared. docs/12-chipset.md has the diagnosis; the PROM's own command-issue
 * routine at 0xBFC1F64C is built around exactly this. */
static int wd_command(u8 cmd)
{
    int tries;
    for (tries = 0; tries < 8; tries++) {
        int i;
        for (i = 0; i < 100000; i++)
            if (!(asr() & ASR_CIP)) break;
        wd_wr(WD_COMMAND, cmd);
        if (!(asr() & ASR_LCI)) return 1;
        (void)wd_rd(WD_STATUS);         /* clear the stale interrupt, retry */
    }
    return 0;
}

/* ---- one Select-and-Transfer ------------------------------------------- */

/* Run a CDB of `cdb_len` bytes against `target`, moving `bytes` of data
 * through the DMA channel over a chain of `ndesc` data descriptors: the n'th
 * covers `len[n]` bytes at physical address `bp[n]`. Direction comes from the
 * command itself - the engine takes it from the SCSI phase, not from the
 * driver's `dir` bit - so `dir_out` here only sets the channel's control bit,
 * which is checked for readback rather than obeyed. Returns the chip's SCSI
 * status.
 *
 * THE CHAIN IS THE POINT OF THE `bp`/`len` ARRAYS. A driver that hands the
 * engine one descriptor per transfer never finds out whether the engine
 * fetches the next one, and the PROM's own reads are single-descriptor. IRIX
 * scatter-gathers, so this is the shape the machine will actually be asked
 * for. */
static u8 run_cdb(const u8 *cdb, int cdb_len, u8 target,
                  const u32 *bp, const u32 *len, int ndesc,
                  u32 bytes, int dir_out)
{
    int i;

    /* The chain, then the zero-count EOX marker the HPC3 spec's "**** BUG ****"
     * note tells every driver to append. The PROM appends one too. */
    for (i = 0; i < ndesc; i++)
        desc(i, bp[i], len[i], phys(pool) + (u32)(i + 1) * 16u);
    desc(ndesc, 0, DESC_EOX, 0);

    /* NO ch_reset HERE. The channel's reset bit is wired to the WD33C93B's
     * chip_reset as well as to the engine - `ch_reset` in the HPC3 spec
     * "resets both external controller and this DMA channel" - so writing it
     * between two commands would throw away the CONTROL register that puts
     * the chip in DMA mode, and assert RST on the bus while a target is still
     * finishing with the last one. It is done once, in main(), before the
     * chip is configured. */
    WR32(HD0_CTRL, 0);

    /* THE CHANNEL STARTS FROM NBDP, NOT CBP. `cbp` is where the engine is,
     * and it is an output of the fetch; `nbdp` is where it goes next, and
     * that is the one a driver seeds. Priming cbp with descriptor 0 and nbdp
     * with the EOX marker - which reads like "here is the chain, here is its
     * end" - starts the channel on the marker instead: it retires an empty
     * descriptor, reports the chain finished without moving a byte, and the
     * WD33C93B then waits forever for a handshake from an engine that has
     * already stopped. tests/dma/dmatest.c's start() has always done this
     * correctly and is the reference. */
    WR32(HD0_NBDP, phys(pool));

    /* Load the CDB, the transfer count and the target. The chip works out the
     * CDB's length for itself from the group code in the top three bits of
     * CDB[0] - group 0 is six bytes, groups 1 and 2 are ten - so `cdb_len`
     * here only says how many registers to load, and a disagreement between
     * the two is exactly the kind of thing phase 3 is for. */
    for (i = 0; i < cdb_len; i++) wd_wr((u8)(WD_CDB1 + i), cdb[i]);
    wd_wr(WD_COUNT_MSB, (u8)((bytes >> 16) & 0xFF));
    wd_wr(WD_COUNT_2ND, (u8)((bytes >> 8) & 0xFF));
    wd_wr(WD_COUNT_LSB, (u8)(bytes & 0xFF));
    wd_wr(WD_DEST_ID, target);
    wd_wr(WD_TARGET_LUN, 0x00);
    wd_wr(WD_CMD_PHASE, 0x00);

    /* Arm the channel, then select. Order matters: the engine has to be able
     * to answer the first byte the moment the data phase opens, and a channel
     * started after the phase is already up loses the race on hardware even
     * when it wins it in simulation. */
    WR32(HD0_CTRL, CTRL_ACTIVE | (dir_out ? 0 : CTRL_DIR));

    if (!wd_command(WD_C_SEL_ATN_XFER)) return 0xFEu;
    return wait_int();
}

/* ---- CDBs -------------------------------------------------------------- */

static void cdb6(u8 *c, u8 op, u32 lba, u8 blocks)
{
    c[0] = op;
    c[1] = (u8)((lba >> 16) & 0x1F);
    c[2] = (u8)((lba >> 8) & 0xFF);
    c[3] = (u8)(lba & 0xFF);
    c[4] = blocks;
    c[5] = 0;
}

static void cdb10(u8 *c, u8 op, u32 lba, u16 blocks)
{
    c[0] = op;
    c[1] = 0;
    c[2] = (u8)((lba >> 24) & 0xFF);
    c[3] = (u8)((lba >> 16) & 0xFF);
    c[4] = (u8)((lba >> 8) & 0xFF);
    c[5] = (u8)(lba & 0xFF);
    c[6] = 0;
    c[7] = (u8)((blocks >> 8) & 0xFF);
    c[8] = (u8)(blocks & 0xFF);
    c[9] = 0;
}

/* A written block is not on the medium when the status byte lands: scsi.v has
 * only assembled it at that point, and then raises io_wr and waits for the
 * block device to take it. Selecting the target again inside that window is
 * what a real driver must not do either. */
static void settle(void)
{
    int i;
    for (i = 0; i < 200000; i++) __asm__ __volatile__("" ::: "memory");
}

/* Which logical block of the disc to read. NOT ZERO, deliberately: scsi.v
 * multiplies a CD-ROM LBA by four to reach the 512-byte host blocks behind it,
 * and at LBA 0 a missing multiply and a correct one give the same answer. */
#define CD_LBA       5u

/* Split `bytes` at `base` into `n` deliberately unequal descriptors. Equal
 * halves are the one split that cannot show a length mix-up between two
 * descriptors, so this never produces them. */
static void split(u32 *bp, u32 *ln, u32 base, u32 bytes, int n)
{
    switch (n) {
    case 1:
        bp[0] = base;              ln[0] = bytes;
        break;
    case 2:
        ln[0] = (bytes / 4) * 3;   ln[1] = bytes - ln[0];
        bp[0] = base;              bp[1] = base + ln[0];
        break;
    case 3:
        ln[0] = bytes / 4;
        ln[1] = bytes / 2;
        ln[2] = bytes - ln[0] - ln[1];
        bp[0] = base;
        bp[1] = base + ln[0];
        bp[2] = base + ln[0] + ln[1];
        break;
    default:
        ln[0] = bytes / 8;
        ln[1] = bytes / 4;
        ln[2] = bytes / 2;
        ln[3] = bytes - ln[0] - ln[1] - ln[2];
        bp[0] = base;
        bp[1] = bp[0] + ln[0];
        bp[2] = bp[1] + ln[1];
        bp[3] = bp[2] + ln[2];
        break;
    }
}

/* The first few mismatches, with their offsets. A count on its own says the
 * transfer was wrong; the offsets say how - a run starting at one descriptor
 * boundary is a chaining bug, every other byte is a byte-lane bug, and
 * everything shifted by one is the REQ-as-a-level race this path has already
 * had twice. */
static void report(u32 bytes, u32 seed, int is_cd)
{
    u32 i;
    int shown = 0;
    puts_scc("  first mismatches:\n");
    for (i = 0; i < bytes && shown < 8; i++) {
        u8 got  = rd_buf(rbuf, (int)i);
        u8 want = is_cd ? cd_pat(CD_LBA * CD_BLOCK + i) : pat(i, seed);
        if (got != want) {
            puts_scc("    [");
            puthex(i);
            puts_scc("] want ");
            puthex(want);
            puts_scc(" got ");
            puthex(got);
            putc_scc('\n');
            shown++;
        }
    }
}

/* ---- one round trip ----------------------------------------------------- */

/* Write `bytes` of pattern `seed` at `lba` through `wsplit` descriptors, read
 * it back through `rsplit`, and compare. `wsplit`/`rsplit` of one is a plain
 * transfer; anything more is a scatter-gather chain, and the two are given
 * different splits on purpose so that a chaining bug on the write side cannot
 * be cancelled by the same bug on the read side.
 *
 * `ten` picks WRITE(10)/READ(10) over WRITE(6)/READ(6): a ten-byte CDB is a
 * different length decode in both the WD33C93B and the target, and a driver
 * that only ever issues six-byte commands never finds out whether the other
 * path exists.
 */
static void round_trip(const char *what, u32 lba, u32 blocks, u32 seed,
                       int ten, int wsplit, int rsplit)
{
    u8  cdb[12];
    u8  status;
    u32 bytes = blocks * BLOCK_BYTES;
    u32 bp[4], ln[4];
    u32 i;
    u32 diffs, nonzero;

    puts_scc("  -- ");
    puts_scc(what);
    putc_scc('\n');

    fill(wbuf, bytes, seed);
    for (i = 0; i < bytes; i++) wr_buf(wbuf, (int)i, wbuf[i]);

    if (ten) cdb10(cdb, 0x2A, lba, (u16)blocks);
    else     cdb6 (cdb, 0x0A, lba, (u8)blocks);

    split(bp, ln, phys(wbuf), bytes, wsplit);
    status = run_cdb(cdb, ten ? 10 : 6, TARGET_ID, bp, ln, wsplit, bytes, 1);
    check_eq(status, WD_S_SELECT_XFER_OK, ten ? "WRITE(10) completes"
                                              : "WRITE(6) completes");
    check_eq(RD32(HD0_BC) & 0x3FFFu, 0, "the channel drained its byte count");

    settle();

    for (i = 0; i < bytes; i++) wr_buf(rbuf, (int)i, 0x00);

    if (ten) cdb10(cdb, 0x28, lba, (u16)blocks);
    else     cdb6 (cdb, 0x08, lba, (u8)blocks);

    split(bp, ln, phys(rbuf), bytes, rsplit);
    status = run_cdb(cdb, ten ? 10 : 6, TARGET_ID, bp, ln, rsplit, bytes, 0);
    check_eq(status, WD_S_SELECT_XFER_OK, ten ? "READ(10) completes"
                                              : "READ(6) completes");

    /* Two separate questions, because they fail differently. "All zero" is the
     * signature of a write path that never delivered anything - which is what
     * a tied-off sd_buff_din produced - and it is worth naming, because a
     * plain compare would report it as N wrong bytes and say nothing about
     * which end was wrong. */
    nonzero = 0;
    diffs   = 0;
    for (i = 0; i < bytes; i++) {
        u8 got = rd_buf(rbuf, (int)i);
        if (got) nonzero++;
        if (got != pat(i, seed)) diffs++;
    }
    check(nonzero != 0, "the data read back is not all zero");
    check_eq(diffs, 0, "every byte survived the round trip");
    if (diffs) report(bytes, seed, 0);
}

/* ---- main -------------------------------------------------------------- */

void main(void)
{
    u8 cdb[12];
    u8 status;
    u32 i, diffs;

    scc_init();
    puts_scc("\nSCSI DATA PATH\n");

    /* Reset the channel and the chip behind it, once, before anything is
     * configured - see run_cdb() on why this cannot live per-command. */
    WR32(HD0_CTRL, CTRL_RESET);
    WR32(HD0_CTRL, 0);

    /* Reset the chip and check it says so. This is also what puts the SCSI
     * bus into a known free state before the first selection. */
    wd_wr(WD_OWN_ID, 0x00);
    if (!wd_command(WD_C_RESET)) {
        check(0, "reset command accepted");
    } else {
        status = wait_int();
        check_eq(status, WD_S_RESET, "reset reports 0x00");
    }

    /* DMA mode. Control[7:5] non-zero is what hands every data byte to the
     * HPC3 channel instead of leaving it in the DATA register behind DBR; the
     * PROM writes 0x8D here and this is the same field. */
    wd_wr(WD_CONTROL, 0x80);
    wd_wr(WD_TIMEOUT, 0x40);
    check_eq(wd_rd(WD_CONTROL), 0x80, "control reads back in DMA mode");

    /* 1. The original: one block, one descriptor, six-byte CDB. */
    round_trip("one block, WRITE(6)", 0, 1, 0x5Au, 0, 1, 1);

    /* 2. Four blocks in one command. The target has to advance its own LBA
     *    across the transfer and the engine has to keep handing it bytes past
     *    the first block boundary, neither of which one block can show. */
    round_trip("four blocks, WRITE(6)", 8, BLOCKS, 0xA5u, 0, 1, 1);

    /* 3. The ten-byte CDB. Same four blocks, at an LBA a six-byte command
     *    could also reach - the point here is the CDB, not the address. */
    round_trip("four blocks, WRITE(10)", 12000, BLOCKS, 0x3Cu, 1, 1, 1);

    /* 4. Scatter-gather. Three descriptors out, two back, so the split is
     *    never the same on both sides of the round trip. */
    round_trip("four blocks over a descriptor chain", 40, BLOCKS, 0x77u, 0, 3, 2);

    /* 5. Sixteen kilobytes in one command, over four descriptors each way.
     *    Everything above fits inside a buffer somewhere in the path; this
     *    does not, and it is the size at which a byte counter one bit too
     *    narrow stops being invisible. */
    round_trip("thirty-two blocks, WRITE(10), four descriptors",
               200, BIG_BLOCKS, 0xE1u, 1, 4, 4);

    /* 6. The CD-ROM, which is read-only and addresses 2048-byte logical
     *    blocks. `--disk 6=` mounts an image whose contents cd_pat() knows, so
     *    this is the first time anything in this project has compared a byte
     *    that came off a disc against what was supposed to be on it.
     *
     *    ONE LOGICAL BLOCK IS FOUR HOST BLOCKS. scsi.v serves a CD-ROM read as
     *    four consecutive 512-byte host blocks and multiplies the LBA by four
     *    at latch time. A scaling bug there puts the right *kind* of data at
     *    the wrong offset, which is why this reads from a non-zero LBA: at LBA
     *    0 a missing multiply and a correct one give the same answer. */
    puts_scc("  -- four logical blocks off the CD-ROM, READ(10)\n");
    {
        u32 cdbytes = CD_BLOCKS * CD_BLOCK;
        u32 bp[4], ln[4];
        for (i = 0; i < cdbytes; i++) wr_buf(rbuf, (int)i, 0x00);
        cdb10(cdb, 0x28, CD_LBA, CD_BLOCKS);
        /* Over a chain as well, because the installer reads the disc into
         * scattered pages and this is the only place that shape is exercised
         * on the read side of a CD. */
        split(bp, ln, phys(rbuf), cdbytes, 3);
        status = run_cdb(cdb, 10, CDROM_ID, bp, ln, 3, cdbytes, 0);
        check_eq(status, WD_S_SELECT_XFER_OK, "READ(10) on the CD-ROM completes");

        diffs = 0;
        for (i = 0; i < cdbytes; i++)
            if (rd_buf(rbuf, (int)i) != cd_pat(CD_LBA * CD_BLOCK + i)) diffs++;
        check_eq(diffs, 0, "the disc's bytes are the bytes that were on it");
        if (diffs) report(cdbytes, 0, 1);
    }

    puts_scc(failures ? "SCSIWR: FAILURES " : "SCSIWR: ALL PASS ");
    puthex((u32)failures);
    putc_scc('\n');

    {
        int spins = 0;
        while (!(RD8(SCC_B_CMD) & RR0_TX_EMPTY) && ++spins < 200000) { }
        for (spins = 0; spins < 200000; spins++) __asm__ __volatile__("" ::: "memory");
    }

    if (RD32(TD_SIGNATURE) == TD_MAGIC)
        WR32(TD_EXIT, failures ? 1 : 0);

    for (;;) { }
}
