/*
 * dmatest - prove that the HPC3's SCSI DMA channel is a bus master, and that
 * it reads a descriptor chain the way the chip specification says.
 *
 * WHY THIS EXISTS, given that the PROM now finds a disk. Because "the PROM
 * finds a disk" is one path through this engine and the engine has several,
 * and the ones the boot does not take are the ones that will be wrong when
 * something else needs them:
 *
 *   - The PROM's descriptors never set XIE, so the whole interrupt path can be
 *     broken without the boot noticing. docs/12-chipset.md records the last
 *     time this project concluded an interrupt worked because the thing behind
 *     it worked.
 *   - The PROM writes ch_active with a plain store, never with ch_active_mask,
 *     so the mask bit is untested by any boot.
 *   - The PROM never uses a link descriptor - a zero byte count without EOX -
 *     and getting that wrong hangs a chain on its first link.
 *   - Nothing in a boot points a descriptor at memory that is not there.
 *
 * It also exists as a bisection point. This image is the smallest thing that
 * says "the engine masters the bus and reads a descriptor"; if a disk stops
 * working, whether this still passes says which half of the machine to look
 * at.
 *
 * WHAT IT DOES NOT TEST: moving a byte. There is no device here - a data
 * descriptor with a real byte count fetches and then waits for a WD33C93B
 * handshake that never comes, which is exactly what is checked below. The
 * data path is tested by tests/run-scsi.sh, against a real disk image.
 *
 * EVERY BUFFER HERE IS UNCACHED, and that is not caution. The image runs from
 * KSEG0, which is cached; a descriptor written through KSEG0 can still be
 * sitting in the D-cache when the engine reads main memory, and nothing in
 * this core snoops. The PROM has the same problem and solves it the same way:
 * its whole SCSI buffer pool lives at 0xA874xxxx, which is KSEG1.
 *
 * Freestanding and self-contained: no libc, no PROM, one file plus start.S.
 */

typedef unsigned char  u8;
typedef unsigned int   u32;

/* ---- the machine ------------------------------------------------------- */

#define IOC          0xBFBD9800u
#define SCC_B_CMD    (IOC + 0x30 + 3)
#define SCC_B_DATA   (IOC + 0x34 + 3)

/* HPC3 SCSI channel 0, KSEG1. Offsets from the HPC3 spec's section 3 address
 * map; the PROM's own device table at 0xBFC7B410 lists the same six. */
#define HD0_CBP      0xBFB90000u
#define HD0_NBDP     0xBFB90004u
#define HD0_BC       0xBFB91000u
#define HD0_CTRL     0xBFB91004u
#define HD0_GIO      0xBFB91008u
#define HD0_DEV      0xBFB9100Cu
#define HD0_DMACFG   0xBFB91010u
#define HD0_PIOCFG   0xBFB91014u

#define CTRL_INT     0x01u
#define CTRL_ENDIAN  0x02u
#define CTRL_DIR     0x04u
#define CTRL_FLUSH   0x08u
#define CTRL_ACTIVE  0x10u
#define CTRL_AMASK   0x20u
#define CTRL_RESET   0x40u

#define DESC_EOX     0x80000000u
#define DESC_EOP     0x40000000u
#define DESC_XIE     0x20000000u

/* The WD33C93B's two byte-wide ports, low byte of the word. The controller is
 * here only because HPC3's ch_reset reaches it; nothing below issues a SCSI
 * command. */
#define WD_ADDR      0xBFBC0003u
#define WD_DATA      0xBFBC0007u
#define WD_R_STATUS  0x17u

/* INT2, to see the DMA interrupt arrive on the SCSI0 line. */
#define INT2_L0_STAT (IOC + 0x80 + 3)
#define L0_SCSI0     0x02u

/* IRIS test device in GIO64 slot 0 - how the run reports its verdict. */
#define TD_SIGNATURE 0xBF400000u
#define TD_EXIT      0xBF40000Cu
#define TD_MAGIC     0x49524953u

#define RD8(a)     (*(volatile u8  *)(unsigned long)(a))
#define WR8(a, v)  (*(volatile u8  *)(unsigned long)(a) = (u8)(v))
#define RD32(a)    (*(volatile u32 *)(unsigned long)(a))
#define WR32(a, v) (*(volatile u32 *)(unsigned long)(a) = (u32)(v))

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

/* Identical to tests/int/inttest.c's, and for the same reason: with no PROM
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

/* ---- descriptors ------------------------------------------------------- */

/* Room for eight descriptors and a data buffer. Aligned to 16 because the
 * spec requires descriptors to be quadword aligned and forbids them from
 * crossing a page boundary. */
static u32 pool[64] __attribute__((aligned(16)));
static u32 buf[64]  __attribute__((aligned(16)));

/* KSEG0 virtual to physical, and physical to a KSEG1 pointer. Everything the
 * engine touches is written through the second one - see the header. */
static u32 phys(const void *p)
{
    return (u32)(unsigned long)p & 0x1FFFFFFFu;
}

static u32 uncached(u32 pa)
{
    return pa | 0xA0000000u;
}

/* Write descriptor `n` of the pool: buffer, count-and-flags, next. */
static void desc(int n, u32 bp, u32 cnt_flags, u32 next)
{
    u32 at = uncached(phys(pool) + (u32)n * 16u);
    WR32(at + 0, bp);
    WR32(at + 4, cnt_flags);
    WR32(at + 8, next);
    WR32(at + 12, 0);
}

static u32 desc_pa(int n)
{
    return phys(pool) + (u32)n * 16u;
}

/* Let the engine run. Nothing here takes more than a handful of descriptor
 * fetches, and every wait below is bounded so a wedged engine fails the test
 * rather than hanging the run. */
static void settle(void)
{
    int i;
    for (i = 0; i < 2000; i++) __asm__ __volatile__("" ::: "memory");
}

/* Wait for ch_active to fall, and report whether it did. */
static int wait_idle(void)
{
    int i;
    for (i = 0; i < 4000; i++)
        if ((RD32(HD0_CTRL) & CTRL_ACTIVE) == 0) return 1;
    return 0;
}

/* Start the channel on descriptor `n`, with `extra` control bits. */
static void start(int n, u32 extra)
{
    WR32(HD0_NBDP, desc_pa(n));
    WR32(HD0_CTRL, CTRL_ACTIVE | extra);
}

int main(void)
{
    u32 c;

    scc_init();
    puts_scc("Udmatest: HPC3 SCSI DMA\n");

    /* ---- 1. the power-on state --------------------------------------- */
    /* "This bit is active (=1, channel is reset) upon power-on reset. This
     * must be programmed to a 0 before the ch_active bit becomes active."
     * Nothing has run yet, so this is the reset value as the spec states it. */
    c = RD32(HD0_CTRL);
    check_eq(c & (CTRL_RESET | CTRL_ACTIVE), CTRL_RESET,
             "ch_reset set and ch_active clear at power-on");
    /* dmacfg's high water mark comes up at "100" - bits 11:9. */
    check_eq(RD32(HD0_DMACFG), 0x00000800u, "dmacfg high water mark at power-on");

    /* ---- 2. ch_reset gates the go edge -------------------------------- */
    desc(0, phys(buf), DESC_EOX, 0);
    WR32(HD0_NBDP, desc_pa(0));
    WR32(HD0_CTRL, CTRL_ACTIVE | CTRL_RESET);
    settle();
    check_eq(RD32(HD0_CTRL) & CTRL_ACTIVE, 0,
             "ch_active refused while ch_reset is set");

    WR32(HD0_CTRL, 0);
    check_eq(RD32(HD0_CTRL) & CTRL_RESET, 0, "ch_reset clears");

    /* And on the way down it resets the WD33C93B - "resets both external
     * controller and this DMA channel". The controller comes out of a reset
     * with its interrupt pending, which is how a driver knows the reset
     * happened, and INT2's SCSI0 line is the OR of that and the channel's DMA
     * interrupt. It has to be acknowledged here or nothing below can tell the
     * two apart. Reading the SCSI status register is the acknowledgement. */
    settle();
    check_eq(RD8(INT2_L0_STAT) & L0_SCSI0, L0_SCSI0,
             "clearing ch_reset resets the controller");
    WR8(WD_ADDR, WD_R_STATUS);
    (void)RD8(WD_DATA);
    check_eq(RD8(INT2_L0_STAT) & L0_SCSI0, 0,
             "and reading its status register acknowledges that");

    /* ---- 3. the smallest chain: one zero-count EOX descriptor --------- */
    /* This is the shape every receive chain ends in. The spec's "**** BUG ****"
     * note tells drivers to always tack one onto the end of a receive chain,
     * and the IP24 PROM does. A zero count is not a transfer: with EOX it ends
     * the chain and the channel goes inactive without moving a byte. */
    desc(0, 0xDEADBEEFu, DESC_EOX, 0);
    start(0, 0);
    check(wait_idle(), "zero-count EOX descriptor ends the chain");
    check_eq(RD32(HD0_CTRL) & CTRL_INT, 0, "and raises no interrupt without XIE");

    /* ---- 4. XIE, and what clears it ----------------------------------- */
    /* NOTHING BELOW MAY POLL THE CONTROL REGISTER. The interrupt is cleared by
     * reading that port - "interrupt cleared on read of this port" - so a wait
     * loop watching ch_active there acknowledges the interrupt it is waiting
     * for and the test that follows finds nothing. That is not an artefact of
     * this model, it is the register, and a driver that spins on ch_active
     * loses its own interrupt the same way. INT2's status register is the
     * thing to watch instead: reading it has no side effect. */
    desc(0, 0, DESC_EOX | DESC_XIE, 0);
    start(0, 0);
    settle();
    check_eq(RD8(INT2_L0_STAT) & L0_SCSI0, L0_SCSI0,
             "XIE raises the interrupt, and it reaches INT2's SCSI0 line");

    /* The byte count sits in the doubleword beside the control register, so
     * one CPU cycle covers both and byte enables cannot say which was meant.
     * Reading the count must not acknowledge the interrupt. */
    (void)RD32(HD0_BC);
    check_eq(RD8(INT2_L0_STAT) & L0_SCSI0, L0_SCSI0,
             "reading the byte count does not clear it");

    /* One read of the control port, which is both the check and the ack. */
    c = RD32(HD0_CTRL);
    check_eq(c & CTRL_INT, CTRL_INT, "the control register reports the interrupt");
    check_eq(c & CTRL_ACTIVE, 0, "and the channel went inactive on EOX");
    check_eq(RD8(INT2_L0_STAT) & L0_SCSI0, 0, "reading the control port clears it");
    check_eq(RD32(HD0_CTRL) & CTRL_INT, 0, "and it stays clear");

    /* ---- 5. a descriptor with a real count, and no device ------------- */
    /* The engine fetches it, latches the buffer address and the count, and
     * then waits for a WD33C93B that is not going to ask for anything. That
     * wait is the point: the channel stays active and the registers read back
     * what was in main memory, which is what says the fetch was a real bus
     * master cycle. */
    desc(0, phys(buf), DESC_EOX | 0x40u, 0);
    start(0, 0);
    settle();
    c = RD32(HD0_CTRL);
    check_eq(c & CTRL_ACTIVE, CTRL_ACTIVE, "a data descriptor leaves the channel active");
    check_eq(RD32(HD0_CBP), phys(buf), "cbp is the descriptor's buffer address");
    check_eq(RD32(HD0_BC) & 0x3FFFu, 0x40u, "bc is the descriptor's byte count");
    check_eq(RD32(HD0_BC) & DESC_EOX, DESC_EOX, "and its flags came with it");

    /* Clearing ch_active aborts it. "Clearing this bit will cause the channel
     * to become inactive, effectively aborting the current operation." */
    WR32(HD0_CTRL, 0);
    check_eq(RD32(HD0_CTRL) & CTRL_ACTIVE, 0, "clearing ch_active aborts");

    /* ---- 6. ch_active_mask -------------------------------------------- */
    /* "When writing to the control port and ch_active_mask = '1', writes are
     * inhibited to ch_active." This is how a driver changes dir or endian
     * without disturbing a running channel, and no boot ever does it. */
    desc(0, phys(buf), DESC_EOX | 0x40u, 0);
    start(0, 0);
    settle();
    WR32(HD0_CTRL, CTRL_AMASK | CTRL_ENDIAN);   /* ch_active bit written as 0 */
    settle();
    c = RD32(HD0_CTRL);
    check_eq(c & CTRL_ACTIVE, CTRL_ACTIVE, "ch_active_mask leaves a running channel alone");
    check_eq(c & CTRL_ENDIAN, CTRL_ENDIAN, "and the masked write still lands elsewhere");
    WR32(HD0_CTRL, 0);

    /* ---- 7. link descriptors ------------------------------------------ */
    /* A zero byte count without EOX is a link: the engine fetches the next
     * descriptor immediately without moving a byte. Three of them in front of
     * a real one, so a fetch loop that only ran once would stop short. */
    desc(0, 0x11111111u, 0,                 desc_pa(1));
    desc(1, 0x22222222u, 0,                 desc_pa(2));
    desc(2, 0x33333333u, 0,                 desc_pa(3));
    desc(3, phys(buf),   DESC_EOX | 0x20u,  0);
    start(0, 0);
    settle();
    check_eq(RD32(HD0_CBP), phys(buf), "a chain of links reaches the data descriptor");
    check_eq(RD32(HD0_BC) & 0x3FFFu, 0x20u, "with its byte count");
    check_eq(RD32(HD0_CTRL) & CTRL_ACTIVE, CTRL_ACTIVE, "and the channel is still active");
    WR32(HD0_CTRL, 0);

    /* A link chain that ends in a zero-count EOX marker still ends. */
    desc(0, 0, 0,        desc_pa(1));
    desc(1, 0, DESC_EOX, 0);
    start(0, 0);
    check(wait_idle(), "a link chain ending in EOX ends");

    /* ---- 8. FLUSH must not raise an interrupt -------------------------- */
    /* "Note that an interrupt does not occur automatically when the flush is
     * complete." IRIX's SCSI teardown acks the real interrupt and then writes
     * FLUSH, so a model that interrupts again leaves the bit set and the line
     * in a storm - IRIS carries the scar in a comment. */
    desc(0, phys(buf), DESC_EOX | DESC_XIE | 0x40u, 0);
    start(0, 0);
    settle();
    WR32(HD0_CTRL, CTRL_FLUSH);
    settle();
    check_eq(RD32(HD0_CTRL) & CTRL_ACTIVE, 0, "FLUSH stops the channel");
    check_eq(RD32(HD0_CTRL) & CTRL_INT, 0, "and does NOT raise an interrupt");

    /* ---- 9. a chain that points at nothing ---------------------------- */
    /* 0x40000000 is outside every bank MEMCFG has, so the descriptor fetch
     * cannot be answered by memory. A real HPC3 would take a GIO64 timeout;
     * what must not happen is the engine waiting forever for an answer, which
     * in a simulation is a hang three layers from its cause. Reading zeros
     * makes it a chain of zero-count links, and the link limit ends it. */
    WR32(HD0_NBDP, 0x40000000u);
    WR32(HD0_CTRL, CTRL_ACTIVE);
    check(wait_idle(), "a descriptor chain in unmapped memory terminates");

    /* ---- 10. the registers that are only storage ---------------------- */
    /* The spec marks gio and dev read-only and says they should never be
     * written in normal operation. They are not read-only on the part: the
     * PROM walks a one-bit pattern through the ethernet channel's cbp and
     * requires it back. Same convention here. */
    WR32(HD0_GIO, 0x5A5A5A5Au);
    WR32(HD0_DEV, 0xA5A5A5A5u);
    WR32(HD0_PIOCFG, 0x00004288u);
    check_eq(RD32(HD0_GIO), 0x5A5A5A5Au, "gio fifo pointer reads back");
    check_eq(RD32(HD0_DEV), 0xA5A5A5A5u, "dev fifo pointer reads back");
    check_eq(RD32(HD0_PIOCFG), 0x00004288u, "piocfg reads back");

    puts_scc(failures ? "DMA: FAILURES " : "DMA: ALL PASS ");
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
