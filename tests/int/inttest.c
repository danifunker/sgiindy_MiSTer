/*
 * inttest - prove that an INT2 source reaches the CPU as an exception.
 *
 * WHY THIS EXISTS. The interrupt path is the one part of the chipset that
 * cannot be tested by watching the PROM: the PROM masks LOCAL0 off entirely
 * and polls the WD33C93's AUX STATUS instead (FUN_bfc1c380 at 0xBFC1C380 reads
 * the address port and tests bit 7), so a boot to the Command Monitor proves
 * nothing at all about INT2. IRIX is the software that needs it, and IRIX does
 * not boot yet. Without this image the interrupt controller would be code
 * nothing had ever executed.
 *
 * WHAT IT PROVES, in the order the paths were built:
 *
 *   1. Nothing fires with everything masked. A test that only ever asserts
 *      "an exception happened" passes just as well on a core that takes a
 *      spurious interrupt every microsecond.
 *   2. 8254 counter 0 -> MAP_STAT bit 0 -> Cause.IP4 -> an Interrupt
 *      exception. This is the unmasked path: IRIS's Ioc::update_interrupts
 *      drives IP4 straight off the latch with no INT2 mask in the way, so the
 *      only mask involved is the CPU's own Status.IM4.
 *   3. Writing TMR_CLR clears the latch and the line drops. A level-sensitive
 *      interrupt that cannot be cleared wedges the machine in its handler, and
 *      that failure looks exactly like success from inside one.
 *   4. The same counter through MAP_MASK0 -> L0_STAT bit 7 -> L0_MASK -> IP2.
 *      This is the mappable path and the summary fold, which is what almost
 *      every real source on this machine goes through.
 *   5. The INT2 mask genuinely masks: with L0_MASK clear the status bit is set
 *      and no exception arrives.
 *
 * The 8254 is the only interrupt source this core has that software can arm
 * by itself. SCSI needs a target and a command, the SCC needs a byte in
 * flight, and neither is a good place to find out whether CP0 takes an
 * interrupt at all.
 *
 * Freestanding and self-contained: no libc, no PROM, one file plus start.S.
 */

typedef unsigned char  u8;
typedef unsigned int   u32;

/* ---- the machine ------------------------------------------------------- */

/* IOC2's window, KSEG1 so nothing is cached. Every register here is eight
 * bits in the LOW byte of its word - the byte at word + 3 - because the
 * machine is big-endian; see rtl/sgi/sgi_ioc.sv. */
#define IOC          0xBFBD9800u
#define SCC_B_CMD    (IOC + 0x30 + 3)
#define SCC_B_DATA   (IOC + 0x34 + 3)

#define INT2_L0_STAT   (IOC + 0x80 + 3)
#define INT2_L0_MASK   (IOC + 0x84 + 3)
#define INT2_L1_STAT   (IOC + 0x88 + 3)
#define INT2_L1_MASK   (IOC + 0x8C + 3)
#define INT2_MAP_STAT  (IOC + 0x90 + 3)
#define INT2_MAP_MASK0 (IOC + 0x94 + 3)
#define INT2_MAP_MASK1 (IOC + 0x98 + 3)
#define INT2_TMR_CLR   (IOC + 0xA0 + 3)

/* The 8254, four register slots at the top of the IOC window. */
#define PIT_C0       (IOC + 0xB0 + 3)
#define PIT_CTL      (IOC + 0xBC + 3)

/* L0_STAT bit 7 is MAP_INT0, the summary of MAP_STAT & MAP_MASK0. */
#define L0_MAP_INT0  0x80u
/* MAP_STAT bit 0 is 8254 counter 0. */
#define MAP_TIMER0   0x01u

/* IRIS test device in GIO64 slot 0 - how the run reports its verdict. */
#define TD_SIGNATURE 0xBF400000u
#define TD_EXIT      0xBF40000Cu
#define TD_MAGIC     0x49524953u

#define RD8(a)     (*(volatile u8  *)(unsigned long)(a))
#define WR8(a, v)  (*(volatile u8  *)(unsigned long)(a) = (u8)(v))
#define RD32(a)    (*(volatile u32 *)(unsigned long)(a))
#define WR32(a, v) (*(volatile u32 *)(unsigned long)(a) = (u32)(v))

/* ---- CP0 --------------------------------------------------------------- */

#define SR_IE   0x00000001u
#define SR_EXL  0x00000002u
/* Status.IM sits at bits 15:8, so IM[n] - the mask for Cause.IP[n] - is
 * bit 8 + n. IP2 is the first hardware line, IP7 the CP0 timer. */
#define SR_IM(n) (1u << (8 + (n)))

#define CAUSE_IP(n)   (1u << (8 + (n)))
#define CAUSE_EXCCODE(c) (((c) >> 2) & 0x1F)
#define EXC_INT  0

static u32 mfc0_status(void)
{
    u32 v;
    __asm__ __volatile__("mfc0 %0, $12; nop" : "=r"(v));
    return v;
}

static void mtc0_status(u32 v)
{
    __asm__ __volatile__("mtc0 %0, $12; nop; nop; nop" :: "r"(v));
}

static u32 mfc0_cause(void)
{
    u32 v;
    __asm__ __volatile__("mfc0 %0, $13; nop" : "=r"(v));
    return v;
}

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

/* Identical to tests/scc/scctest.c's, and for the same reason: with no PROM
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

/* What the handler saw. Volatile because main() reads them from a loop the
 * compiler can otherwise see nothing writing to. */
volatile u32 exc_count;
volatile u32 exc_cause;
volatile u32 exc_status;

/*
 * exc_handler - called from exc_entry in start.S.
 *
 * It has to make the interrupt go away before returning, because the line is a
 * level: eret clears EXL, the line is still up, and the exception is taken
 * again on the instruction after the one that was interrupted - forever.
 * Clearing it at the source is what a real handler does and is exactly the
 * behaviour test 3 is checking.
 */
void exc_handler(void);
void exc_handler(void)
{
    /* Only the first entry is recorded. A second entry is not a failure - the
     * counter is in mode 2 and reloads - but its Cause describes a different
     * interrupt, and overwriting the first one would report the state of the
     * machine after the handler rather than the state that entered it. */
    if (exc_count == 0) {
        exc_cause  = mfc0_cause();
        exc_status = mfc0_status();
    }
    exc_count++;

    /* Silence every source this image can raise, whichever one fired: the
     * counter latch, then the mask that let it through. Both, so that a
     * handler entered by the wrong line still terminates and the failure
     * shows up as a wrong Cause rather than as a hang. */
    WR8(INT2_TMR_CLR, 0x03);
    WR8(INT2_L0_MASK, 0x00);
    WR8(INT2_MAP_MASK0, 0x00);

    /*
     * Read one of them back before returning. This is not belt and braces: the
     * stores above go into the CPU's write FIFO, and `eret` does not wait for
     * it to drain. The line is a level, so an eret that lands before the write
     * does finds the interrupt still asserted and takes it again immediately -
     * which is how this handler was first seen running twice, the second entry
     * recording a Cause with IP4 already clear. A read to the same device is
     * ordered behind the writes and is what makes the clear stick.
     */
    (void)RD8(INT2_MAP_STAT);
}

/* Install the vector trampoline at 0x80000180.
 *
 * The copy goes through KSEG1 - uncached - rather than KSEG0. The stores would
 * otherwise sit in the data cache while the CPU fetched the vector through the
 * instruction cache, which is the classic way to install a handler that is
 * never there when it is needed. Writing uncached puts the words in memory,
 * and the instruction cache cannot hold a stale copy of an address nothing has
 * ever executed. */
extern u32 tramp_general[], tramp_general_end[];

static void exc_install(void)
{
    volatile u32 *dst = (volatile u32 *)0xA0000180u;
    unsigned n = (unsigned)(tramp_general_end - tramp_general);
    unsigned i;
    for (i = 0; i < n; i++) dst[i] = tramp_general[i];
    __asm__ __volatile__("sync" ::: "memory");
}

/*
 * Arm 8254 counter 0 in mode 2 with the given period, in microseconds - the
 * input clock is 1 MHz (pit8254.sv), so one count is one microsecond. Mode 2
 * reloads, so the counter keeps firing; that is deliberate, because a
 * one-shot would make "the interrupt did not come back after I cleared it"
 * indistinguishable from "the counter stopped".
 */
static void pit_arm(u32 period)
{
    WR8(PIT_CTL, 0x34);             /* counter 0, LSB then MSB, mode 2, binary */
    WR8(PIT_C0, period & 0xFF);
    WR8(PIT_C0, (period >> 8) & 0xFF);
}

static void pit_stop(void)
{
    WR8(PIT_CTL, 0x30);             /* mode 0, and no reload written: idle */
}

/* Spin until the handler has run, or give up. Returns the number of
 * exceptions seen. The bound matters: the whole point of test 1 and test 5 is
 * that nothing arrives, and an unbounded wait would hang rather than fail. */
static u32 wait_exc(u32 want, u32 spins)
{
    u32 i;
    for (i = 0; i < spins; i++) {
        if (exc_count >= want) break;
        __asm__ __volatile__("" ::: "memory");
    }
    return exc_count;
}

static void reset_int2(void)
{
    mtc0_status(0x30000000);        /* IE off, every IM clear */
    pit_stop();
    WR8(INT2_L0_MASK, 0x00);
    WR8(INT2_L1_MASK, 0x00);
    WR8(INT2_MAP_MASK0, 0x00);
    WR8(INT2_MAP_MASK1, 0x00);
    WR8(INT2_TMR_CLR, 0x03);
    exc_count = 0;
}

int main(void)
{
    u32 cause, seen;

    scc_init();
    exc_install();
    puts_scc("Uinttest: INT2 -> CPU\n");

    /* ---- 1. nothing fires with everything masked ---------------------- */
    reset_int2();
    pit_arm(200);
    mtc0_status(0x30000000 | SR_IE);        /* IE on, no IM bits */
    seen = wait_exc(1, 400000);
    mtc0_status(0x30000000);
    check(seen == 0, "no interrupt with Status.IM clear");
    check((RD8(INT2_MAP_STAT) & MAP_TIMER0) != 0,
          "MAP_STAT counter 0 latched anyway");

    /* ---- 2. counter 0 -> IP4 ------------------------------------------ */
    reset_int2();
    pit_arm(200);
    mtc0_status(0x30000000 | SR_IE | SR_IM(4));
    seen = wait_exc(1, 400000);
    mtc0_status(0x30000000);
    check(seen >= 1, "counter 0 raises an exception through IP4");
    cause = exc_cause;
    check(CAUSE_EXCCODE(cause) == EXC_INT, "ExcCode is Interrupt");
    check((cause & CAUSE_IP(4)) != 0, "Cause.IP4 set in the handler");
    check((cause & CAUSE_IP(2)) == 0, "Cause.IP2 clear - LOCAL0 has no source");
    check((exc_status & SR_EXL) != 0, "Status.EXL set in the handler");
    check(exc_count == 1, "the handler is entered once - the level really drops");

    /* ---- 3. TMR_CLR drops the line ------------------------------------ */
    /* The handler wrote TMR_CLR on its way out and the counter is stopped, so
     * the latch must now read clear and re-enabling IE must not re-enter. */
    reset_int2();
    check((RD8(INT2_MAP_STAT) & MAP_TIMER0) == 0, "TMR_CLR clears the latch");
    mtc0_status(0x30000000 | SR_IE | SR_IM(4));
    seen = wait_exc(1, 200000);
    mtc0_status(0x30000000);
    check(seen == 0, "and the line stays down with the counter stopped");

    /* ---- 4. the mappable path: MAP -> L0 bit 7 -> IP2 ------------------ */
    reset_int2();
    WR8(INT2_MAP_MASK0, MAP_TIMER0);        /* counter 0 summarises into L0.7 */
    WR8(INT2_L0_MASK, L0_MAP_INT0);         /* and L0.7 reaches the CPU       */
    pit_arm(200);
    mtc0_status(0x30000000 | SR_IE | SR_IM(2));
    seen = wait_exc(1, 400000);
    mtc0_status(0x30000000);
    check(seen >= 1, "the mappable path raises an exception through IP2");
    cause = exc_cause;
    check((cause & CAUSE_IP(2)) != 0, "Cause.IP2 set in the handler");

    /* ---- 5. the INT2 mask masks --------------------------------------- */
    reset_int2();
    WR8(INT2_MAP_MASK0, MAP_TIMER0);
    WR8(INT2_L0_MASK, 0x00);                /* the fold happens, the line does not */
    pit_arm(200);
    mtc0_status(0x30000000 | SR_IE | SR_IM(2));
    seen = wait_exc(1, 400000);
    mtc0_status(0x30000000);
    check(seen == 0, "L0_MASK clear blocks the line");
    check((RD8(INT2_L0_STAT) & L0_MAP_INT0) != 0,
          "and L0_STAT still reports the source");

    reset_int2();

    puts_scc(failures ? "INT: FAILURES " : "INT: ALL PASS ");
    puthex(failures);
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
