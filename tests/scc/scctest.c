/*
 * scctest - drive the Z8530 the way the IP24 PROM does, and prove it transmits.
 *
 * The cpu-tests suite deliberately does NOT program the SCC: it runs after the
 * PROM, so `con_init` is a no-op and it only polls RR0 and writes bytes
 * (cpu-tests/harness/console.c:28). That leaves the transmitter disabled on a
 * bare-metal run, which means the suite exercises almost none of the part.
 *
 * This does the initialisation instead, so the whole path runs: the CPU writes
 * a byte, it lands in the TX FIFO, the FIFO crosses into the serial clock
 * domain, the baud rate generator clocks the shift register, and the bits come
 * out of txdb. The harness checks the result two independent ways - the
 * byte-level tap at the FIFO pop, and a UART decode of the txdb line itself -
 * and they have to agree. A model that accepted the writes but never shifted
 * anything out would pass the first and fail the second.
 *
 * Freestanding and self-contained: no libc, no PROM, one file plus start.S.
 */

typedef unsigned char  u8;
typedef unsigned int   u32;

/* IOC2's SCC window, KSEG1 so nothing is cached. Channel B is tty1, the SGI
 * serial console; see rtl/sgi/sgi_scc.sv on the channel naming. */
#define SCC_B_CMD   0xBFBD9830u
#define SCC_B_DATA  0xBFBD9834u

#define RR0_TX_EMPTY 0x04u

/* IRIS test device in GIO64 slot 0 - how the run reports its verdict. */
#define TD_SIGNATURE 0xBF400000u
#define TD_EXIT      0xBF40000Cu
#define TD_MAGIC     0x49524953u

#define RD8(a)     (*(volatile u8  *)(unsigned long)(a))
#define WR8(a, v)  (*(volatile u8  *)(unsigned long)(a) = (u8)(v))
#define RD32(a)    (*(volatile u32 *)(unsigned long)(a))
#define WR32(a, v) (*(volatile u32 *)(unsigned long)(a) = (u32)(v))

/* The SCC needs a few bus cycles between accesses to the same channel. */
static void pause(void)
{
    int i;
    for (i = 0; i < 8; i++) __asm__ __volatile__("" ::: "memory");
}

/*
 * Write one SCC write-register. The part is two-cycle: the register number
 * goes to the command port, then the value to the same port.
 *
 * Registers 8..15 work with the plain number because 0x08..0x0F already has
 * WR0's command field [5:3] equal to 001 - "Point High" - with the low three
 * bits selecting within the bank. Anything that sets bit 3 without that exact
 * command field selects register 0..7 instead, which is the bug the vendored
 * model's WR0 comment records.
 */
static void wr(int reg, u8 val)
{
    WR8(SCC_B_CMD, (u8)reg);
    pause();
    WR8(SCC_B_CMD, val);
    pause();
}

static void scc_init(void)
{
    /* Channel reset. WR9[7:6] = 01 resets channel B only. */
    wr(9, 0x40);
    pause(); pause();

    wr(4, 0x44);   /* x16 clock, 1 stop bit, no parity - the console's 8N1 */
    wr(1, 0x00);   /* no interrupts: nothing is wired to INT2 yet          */
    wr(3, 0xC0);   /* Rx 8 bits/char, receiver still disabled              */
    wr(5, 0x60);   /* Tx 8 bits/char, transmitter still disabled           */
    wr(9, 0x00);   /* no master interrupt enable                           */
    wr(10, 0x00);  /* NRZ                                                  */
    wr(11, 0x56);  /* Rx clock = BRG, Tx clock = BRG, TRxC out = BRG       */
    wr(12, 0x00);  /* baud rate time constant, low byte                    */
    wr(13, 0x00);  /* ...and high. Zero is the fastest the BRG will go,    */
                   /* which keeps the simulated run short; the real PROM   */
                   /* programs 9600 baud here.                             */
    wr(14, 0x03);  /* BRG source = PCLK, BRG enable                        */
    wr(3, 0xC1);   /* receiver enable                                      */
    wr(5, 0x68);   /* transmitter enable - this is the bit whose absence   */
                   /* makes a bare-metal image print nothing               */
}

/* Bounded: a transmitter that never empties must not hang the test. */
static int putc_scc(int c)
{
    int spins = 0;
    while (!(RD8(SCC_B_CMD) & RR0_TX_EMPTY))
        if (++spins > 200000) return 0;
    WR8(SCC_B_DATA, (u8)c);
    return 1;
}

static int puts_scc(const char *s)
{
    int ok = 1;
    while (*s) ok &= putc_scc(*s++);
    return ok;
}

int main(void)
{
    int ok;

    scc_init();

    /*
     * 'U' first, deliberately. Its bit pattern alternates, so the start bit is
     * the only low bit before the first high one and the harness can measure
     * one bit time from it without being told the baud rate. Any character
     * with bit 0 clear would make that first low run two bits wide and the
     * auto-baud would come out half speed.
     */
    ok = puts_scc("U");
    ok &= puts_scc("SCC-TX-OK\n");

    /* Drain before stopping the machine, or the last byte is still in the
     * shift register when the test device pulls the plug. */
    {
        int spins = 0;
        while (!(RD8(SCC_B_CMD) & RR0_TX_EMPTY) && ++spins < 200000) { }
        for (spins = 0; spins < 200000; spins++) __asm__ __volatile__("" ::: "memory");
    }

    if (RD32(TD_SIGNATURE) == TD_MAGIC)
        WR32(TD_EXIT, ok ? 0 : 1);

    for (;;) { }
}
