//============================================================================
//  tb_hal2.cpp - HAL2's register file against IRIS's src/hal2.rs.
//
//  The IAR decode is a type/number/parameter split that no datasheet in
//  reference/specs/ covers, so the only way to be right about it is to agree
//  with IRIS - and the only way to know you agree is to write every case out
//  and check the value comes back. That is what this does: for each indirect
//  register, write a distinctive value through IDR/IAR and read it back the
//  other way.
//
//  ONE CHECK HERE IS A BOOT-STOPPER RATHER THAN A WRONG NOTE. ISR bit 0 is
//  TSTATUS and the PROM's audio init at 0xBFC00BD0 spins on it three times.
//  It has to read zero always. `isr_tstatus_stays_clear` is that check, and if
//  it ever fails the machine will appear to hang in POST with nothing to say
//  it was the audio chip.
//
//  Build:  make -C verilator hal2test
//============================================================================

#include <cstdio>
#include <cstdint>
#include <vector>
#include <string>
#include "Vhal2.h"
#include "verilated.h"

static const int R_ISR = 1, R_REV = 2, R_IAR = 3, R_IDR0 = 4, R_IDR1 = 5;

// IAR fields, from IRIS.
static uint16_t iar(int type, int num, int param, bool read)
{
    return (uint16_t)((type << 12) | (num << 8) | (param << 2) | (read ? 0x80 : 0));
}
static const int T_DMA = 0x1, T_BRES = 0x2, T_GLOBAL = 0x9;
static const int N_AES_RX = 2, N_AES_TX = 3, N_CODECA = 4, N_CODECB = 5;

class Dut {
public:
    Vhal2 *t;
    Dut() : t(new Vhal2) {}
    ~Dut() { delete t; }
    void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
    void reset() {
        t->reset = 1; t->sel = 0; t->we = 0;
        for (int i = 0; i < 3; i++) tick();
        t->reset = 0; tick();
    }
    void wr(int reg, uint16_t v) {
        t->sel = 1; t->we = 1; t->regsel = reg; t->wdata = v;
        tick();
        t->sel = 0; t->we = 0;
    }
    uint16_t rd(int reg) {
        t->sel = 1; t->we = 0; t->regsel = reg; t->eval();
        uint16_t v = t->rdata;
        t->sel = 0;
        return v;
    }
    // Write an indirect register: value into IDR, then IAR with the write bit.
    void ind_wr(int type, int num, int param, uint16_t v0, uint16_t v1 = 0) {
        wr(R_IDR0, v0);
        wr(R_IDR1, v1);
        wr(R_IAR, iar(type, num, param, false));
    }
    // Read it back: IAR with the read bit loads IDR, then read IDR.
    void ind_rd(int type, int num, int param, uint16_t &v0, uint16_t &v1) {
        wr(R_IDR0, 0xDEAD);          // poison, so a no-op decode is visible
        wr(R_IDR1, 0xBEEF);
        wr(R_IAR, iar(type, num, param, true));
        v0 = rd(R_IDR0);
        v1 = rd(R_IDR1);
    }
};

static int fails = 0;
static void check(const char *what, uint32_t got, uint32_t want)
{
    bool ok = (got == want);
    if (!ok) fails++;
    printf("  %-46s %s  got 0x%04x want 0x%04x\n", what, ok ? "ok  " : "FAIL", got, want);
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Dut d;
    d.reset();

    printf("HAL2 register file vs IRIS src/hal2.rs\n\n");

    check("REV reads 0x4010 (audio present, bit 15 clear)", d.rd(R_REV), 0x4010);

    // The one that stops a boot if it breaks.
    check("isr_tstatus_stays_clear (PROM spins on it)", d.rd(R_ISR) & 1, 0);
    d.wr(R_ISR, 0xFFFF);
    check("isr_tstatus_stays_clear after writing all ones", d.rd(R_ISR) & 1, 0);
    check("ISR USTATUS also read-only zero", (d.rd(R_ISR) >> 1) & 1, 0);
    check("ISR writable bits 4:2 read back", (d.rd(R_ISR) >> 2) & 7, 7);
    d.wr(R_ISR, 0x0000);
    check("ISR writable bits clear again", (d.rd(R_ISR) >> 2) & 7, 0);

    d.wr(R_IDR0, 0x1234);
    check("IDR0 reads back", d.rd(R_IDR0), 0x1234);
    d.wr(R_IDR1, 0x5678);
    check("IDR1 reads back", d.rd(R_IDR1), 0x5678);

    // Reset values IRIS gives the Bresenham clocks.
    d.reset();
    uint16_t a, b;
    for (int clk = 1; clk <= 3; clk++) {
        char n[64];
        d.ind_rd(T_BRES, clk, 1, a, b);
        snprintf(n, sizeof n, "bres%d sel reset value", clk);   check(n, a, 0x0001);
        d.ind_rd(T_BRES, clk, 2, a, b);
        snprintf(n, sizeof n, "bres%d inc reset value", clk);   check(n, a, 0x0001);
        d.ind_rd(T_BRES, clk, 3, a, b);
        snprintf(n, sizeof n, "bres%d modctrl reset value", clk); check(n, a, 0xFFFF);
    }

    // Global DMA: four single-word parameters.
    static const char *gname[4] = { "relay", "enable", "endian", "drive" };
    for (int p = 0; p < 4; p++) {
        uint16_t v = 0xA000 | (uint16_t)p;
        d.ind_wr(T_GLOBAL, 0, p, v);
        d.ind_rd(T_GLOBAL, 0, p, a, b);
        char n[64]; snprintf(n, sizeof n, "global dma %s round-trips", gname[p]);
        check(n, a, v);
    }

    // Codec / AES: CTRL1 is one word at param 1, CTRL2 is two at param 2.
    struct { int num; const char *name; } chans[] = {
        { N_CODECA, "codecA" }, { N_CODECB, "codecB" },
        { N_AES_TX, "aesTX"  }, { N_AES_RX, "aesRX"  },
    };
    for (auto &c : chans) {
        char n[80];
        uint16_t c1 = (uint16_t)(0x1100 + c.num);
        d.ind_wr(T_DMA, c.num, 1, c1);
        d.ind_rd(T_DMA, c.num, 1, a, b);
        snprintf(n, sizeof n, "%s CTRL1 round-trips", c.name); check(n, a, c1);

        uint16_t w0 = (uint16_t)(0x2200 + c.num), w1 = (uint16_t)(0x3300 + c.num);
        d.ind_wr(T_DMA, c.num, 2, w0, w1);
        d.ind_rd(T_DMA, c.num, 2, a, b);
        snprintf(n, sizeof n, "%s CTRL2 word 0 round-trips", c.name); check(n, a, w0);
        snprintf(n, sizeof n, "%s CTRL2 word 1 round-trips", c.name); check(n, b, w1);

        // CTRL1 must not have been disturbed by the CTRL2 write.
        d.ind_rd(T_DMA, c.num, 1, a, b);
        snprintf(n, sizeof n, "%s CTRL1 survives a CTRL2 write", c.name); check(n, a, c1);
    }

    // Bresenham clocks: three parameters on each of three generators, and each
    // generator has to be independent of the others.
    for (int clk = 1; clk <= 3; clk++) {
        for (int p = 1; p <= 3; p++) {
            uint16_t v = (uint16_t)(0x4000 | (clk << 8) | p);
            d.ind_wr(T_BRES, clk, p, v);
        }
    }
    for (int clk = 1; clk <= 3; clk++) {
        for (int p = 1; p <= 3; p++) {
            uint16_t v = (uint16_t)(0x4000 | (clk << 8) | p);
            d.ind_rd(T_BRES, clk, p, a, b);
            char n[64]; snprintf(n, sizeof n, "bres%d param%d independent", clk, p);
            check(n, a, v);
        }
    }

    // A number the chip does not implement must not alias onto one it does.
    d.ind_wr(T_DMA, 6, 1, 0x9999);
    d.ind_rd(T_DMA, N_CODECA, 1, a, b);
    check("unknown DMA number does not clobber codecA", a, (uint16_t)(0x1100 + N_CODECA));

    printf("\n%s\n", fails ? "FAILURES ABOVE" : "all checks passed");
    return fails ? 1 : 0;
}
