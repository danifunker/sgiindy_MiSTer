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
 * WHAT IT DOES. One WRITE(6) of a 512-byte block through Select-and-Transfer
 * with the DMA channel, then one READ(6) of the same block into a different
 * buffer, then a compare. The pattern is deliberately not constant and not
 * byte-symmetric: a path that drops the low half of every 16-bit unit, or
 * swaps the two halves, or shifts the block by one byte, all pass a test
 * written with 0xFF and all fail this one. See `fill()`.
 *
 * IT WRITES TO BLOCK 0 OF A SCRATCH IMAGE, not to tests/disks/blank8m.img.
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

/* The target this image talks to. Must match the run script's --disk. */
#define TARGET_ID    1
#define BLOCK_LBA    0
#define BLOCK_BYTES  512

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

/* Two descriptors' worth of pool, and two 512-byte block buffers. Aligned to
 * 16 because the spec requires descriptors to be quadword aligned. */
static u32 pool[16]              __attribute__((aligned(16)));
static u8  wbuf[BLOCK_BYTES]     __attribute__((aligned(16)));
static u8  rbuf[BLOCK_BYTES]     __attribute__((aligned(16)));

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

/* The pattern. Every byte of a block is distinct from its neighbours in both
 * halves of its 16-bit unit, so the three failures this path can plausibly
 * have - a dropped half, a swapped pair, a one-byte shift - each change the
 * compare. `i * 7` walks the whole byte range over 512 bytes without ever
 * repeating within a pair, and the `^ (i >> 8)` term keeps the second half of
 * the block from being a copy of the first. */
static void fill(u8 *p)
{
    int i;
    for (i = 0; i < BLOCK_BYTES; i++)
        p[i] = (u8)((i * 7) ^ (i >> 8) ^ 0x5Au);
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

/* Run a six-byte CDB against TARGET_ID with `bytes` of data moving through
 * the DMA channel out of / into the block at `pa`. Direction comes from the
 * command itself - the engine takes it from the SCSI phase, not from the
 * driver's `dir` bit - so `dir_out` here only sets the channel's control bit,
 * which is checked for readback rather than obeyed. Returns the chip's SCSI
 * status. */
static u8 run_cdb(const u8 *cdb, u32 pa, u32 bytes, int dir_out)
{
    int i;

    /* The descriptor: one data descriptor for the whole block, then the
     * zero-count EOX marker the HPC3 spec's "**** BUG ****" note tells every
     * driver to append. The PROM appends one too. */
    desc(0, pa, bytes, phys(pool) + 16u);
    desc(1, 0, DESC_EOX, 0);

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

    /* Load the CDB, the transfer count and the target. */
    for (i = 0; i < 6; i++) wd_wr((u8)(WD_CDB1 + i), cdb[i]);
    wd_wr(WD_COUNT_MSB, (u8)((bytes >> 16) & 0xFF));
    wd_wr(WD_COUNT_2ND, (u8)((bytes >> 8) & 0xFF));
    wd_wr(WD_COUNT_LSB, (u8)(bytes & 0xFF));
    wd_wr(WD_DEST_ID, TARGET_ID);
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

/* ---- main -------------------------------------------------------------- */

void main(void)
{
    u8 cdb[6];
    u8 status;
    int i, diffs, nonzero;

    scc_init();
    puts_scc("\nSCSI DATA OUT\n");

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

    /* ---- the write ----------------------------------------------------- */

    fill(wbuf);
    for (i = 0; i < BLOCK_BYTES; i++) wr_buf(wbuf, i, wbuf[i]);

    cdb[0] = 0x0A;                      /* WRITE(6) */
    cdb[1] = (u8)((BLOCK_LBA >> 16) & 0x1F);
    cdb[2] = (u8)((BLOCK_LBA >> 8) & 0xFF);
    cdb[3] = (u8)(BLOCK_LBA & 0xFF);
    cdb[4] = 1;                         /* one block */
    cdb[5] = 0;

    status = run_cdb(cdb, phys(wbuf), BLOCK_BYTES, 1);
    check_eq(status, WD_S_SELECT_XFER_OK, "WRITE(6) completes");
    check_eq(RD32(HD0_BC) & 0x3FFFu, 0, "the channel drained its byte count");

    /* ---- and the read back --------------------------------------------- */

    /* Let the target finish flushing. A WRITE(6) is complete from the
     * initiator's side the moment the status byte lands, but scsi.v has only
     * assembled the block at that point: it then raises io_wr and waits for
     * the block device to take it, which is hundreds of cycles in this harness
     * and far longer on hardware. Selecting the target again inside that
     * window is what a real driver must not do either. */
    for (i = 0; i < 200000; i++) __asm__ __volatile__("" ::: "memory");

    for (i = 0; i < BLOCK_BYTES; i++) wr_buf(rbuf, i, 0x00);

    cdb[0] = 0x08;                      /* READ(6) */
    status = run_cdb(cdb, phys(rbuf), BLOCK_BYTES, 0);
    check_eq(status, WD_S_SELECT_XFER_OK, "READ(6) completes");

    /* Two separate questions, because they fail differently. "All zero" is
     * the signature of a write path that never delivered anything - which is
     * what a tied-off sd_buff_din produced - and it is worth naming, because
     * a plain compare would report it as 512 wrong bytes and say nothing
     * about which end was wrong. */
    nonzero = 0;
    diffs   = 0;
    for (i = 0; i < BLOCK_BYTES; i++) {
        u8 got = rd_buf(rbuf, i);
        if (got) nonzero++;
        if (got != (u8)((i * 7) ^ (i >> 8) ^ 0x5Au)) diffs++;
    }
    check(nonzero != 0, "the block read back is not all zero");
    check_eq((u32)diffs, 0, "every byte survived the round trip");

    if (diffs) {
        puts_scc("  first mismatches:\n");
        {
            int shown = 0;
            for (i = 0; i < BLOCK_BYTES && shown < 8; i++) {
                u8 got = rd_buf(rbuf, i);
                u8 want = (u8)((i * 7) ^ (i >> 8) ^ 0x5Au);
                if (got != want) {
                    puts_scc("    [");
                    puthex((u32)i);
                    puts_scc("] want ");
                    puthex(want);
                    puts_scc(" got ");
                    puthex(got);
                    putc_scc('\n');
                    shown++;
                }
            }
        }
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
