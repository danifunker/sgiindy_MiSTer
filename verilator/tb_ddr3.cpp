//============================================================================
//  tb_ddr3 - a unit test for the DDR3 mux.
//
//  THIS IS THE ONLY THING THAT CAN BE CHECKED ABOUT THE MISTER MEMORY PATH
//  WITHOUT A DE10-NANO. Everything else in the top level is wiring that
//  Quartus either accepts or does not; this module has behaviour, it has five
//  masters that can starve each other, and it is the one place where an
//  address can be wrong by a factor of eight and produce a machine that boots
//  and then quietly reads somebody else's memory.
//
//  The model of the bridge is deliberately unhelpful:
//
//    * BUSY is random, so a request has to be HELD until it is taken. A mux
//      that presents RD for one cycle and walks away passes against a bridge
//      that is never busy and loses transactions against a real one.
//    * read latency is random within a range, and never zero, so nothing can
//      accidentally depend on the answer arriving in a fixed number of cycles.
//    * DOUT is driven with garbage except on the cycle DOUT_READY is high,
//      so a mux that samples it at the wrong time fails rather than passing
//      by luck.
//
//  What is checked: every read returns the last thing written to that address,
//  every request is acknowledged exactly once, the three regions do not
//  overlap - a write to RAM offset X must not be visible at frame buffer
//  offset X - and the display port is not starved behind the rasteriser.
//============================================================================

#include "Vddr3_mux.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <map>
#include <deque>
#include <random>
#include <cstdlib>

static Vddr3_mux *dut;

// ---- the bridge model -----------------------------------------------------
static std::map<uint32_t, uint64_t> mem;      // word address -> data
static std::mt19937 rng(12345);

struct Pending { int delay; uint64_t data; };
static std::deque<Pending> read_pipe;
static uint64_t clk_count = 0;
static bool     s_fbr_valid = false;
static uint64_t s_fbr_dout  = 0;

static uint64_t garbage() { return ((uint64_t)rng() << 32) ^ rng(); }

// EVERYTHING THE BRIDGE SEES IS SAMPLED AT THE CLOCK EDGE, and modelling that
// wrongly is worse than not modelling it. The first version of this file
// decided whether a transaction had been taken AFTER the edge, by which time
// the mux had already seen BUSY go low and deasserted RD - so every request
// looked dropped and the mux looked broken when it was not. A real bridge
// latches RD/WE and the address on the edge where it is not busy, which is the
// same edge at which the mux learns it may stop driving them.
//
// So: present BUSY, DOUT and DOUT_READY for the cycle, settle, capture what
// the core is driving, clock, and only then decide.
struct Bus { bool rd, we; uint32_t addr; uint64_t din; uint8_t be; };

static void tick()
{
    dut->DDRAM_BUSY = (rng() % 100) < 35;

    // Retire at most one read per cycle, in order, BEFORE the edge - the core
    // has to see DOUT_READY at the edge it samples on.
    dut->DDRAM_DOUT_READY = 0;
    dut->DDRAM_DOUT = garbage();
    if (!read_pipe.empty()) {
        if (read_pipe.front().delay > 0) {
            read_pipe.front().delay--;
        } else {
            dut->DDRAM_DOUT = read_pipe.front().data;
            dut->DDRAM_DOUT_READY = 1;
            read_pipe.pop_front();
        }
    }
    dut->eval();

    Bus b{(bool)dut->DDRAM_RD, (bool)dut->DDRAM_WE, (uint32_t)dut->DDRAM_ADDR,
          dut->DDRAM_DIN, (uint8_t)dut->DDRAM_BE};
    bool busy = dut->DDRAM_BUSY;

    // THE DISPLAY'S DATA-VALID IS COMBINATIONAL, so it has to be sampled the
    // way a synchronous consumer does - at the edge, from the value that was
    // there before it. Reading it afterwards loses the last word of every
    // burst, because the state machine has already moved on by then, and the
    // burst therefore never completes. That is a testbench mistake and not a
    // design one, and it is the third time in this file's history that
    // sampling on the wrong side of the edge made working RTL look broken.
    s_fbr_valid = dut->fbr_dout_valid;
    s_fbr_dout  = dut->fbr_dout;

    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();

    if (!busy && (b.rd || b.we)) {
        if (b.we) {
            uint64_t old = mem.count(b.addr) ? mem[b.addr] : 0;
            uint64_t val = 0;
            for (int i = 0; i < 8; i++) {
                // be[7-i] guards byte i, and byte 0 is the most significant.
                int shift = 56 - 8 * i;
                bool en = (b.be >> (7 - i)) & 1;
                uint64_t by = en ? ((b.din >> shift) & 0xFF)
                                 : ((old   >> shift) & 0xFF);
                val |= by << shift;
            }
            mem[b.addr] = val;
        } else {
            int n = dut->DDRAM_BURSTCNT ? dut->DDRAM_BURSTCNT : 1;
            if (getenv("DDR3_DEBUG"))
                printf("      [bridge] read addr=%08x burst=%d\n", b.addr, n);
            for (int w = 0; w < n; w++)
                read_pipe.push_back({(w == 0 ? 2 + (int)(rng() % 6) : 0),
                                     mem.count(b.addr + w) ? mem[b.addr + w] : 0});
        }
    }
    clk_count++;
}

// ---- the masters ----------------------------------------------------------
// Each keeps a shadow of what it believes it wrote, per region, so a region
// overlap shows up as a read that returns another master's data.
struct Master {
    const char  *name;
    std::map<uint32_t, uint64_t> shadow;      // byte address -> data
    uint32_t addr = 0;
    bool     busy = false;
    bool     is_write = false;
    uint64_t expect = 0;
    uint64_t issued = 0, acked = 0;
    uint64_t wait_cycles = 0, worst_wait = 0;
    int      burst = 1, got = 0;      // the display's burst, and its progress
};

static Master m_fbr{"fbr"}, m_ram{"ram"}, m_prom{"prom"}, m_fbw{"fbw"};
static int failures = 0;

static void fail(const char *what, uint32_t a, uint64_t want, uint64_t got)
{
    if (failures < 10)
        printf("  FAILED %s at %08x: want %016llx got %016llx\n", what, a,
               (unsigned long long)want, (unsigned long long)got);
    failures++;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    dut = new Vddr3_mux;

    dut->reset = 1; dut->clk = 0;
    dut->fbr_req = dut->dl_req = dut->ram_req = dut->prom_req = dut->fbw_req = 0;
    dut->fbr_burst = 1;
    dut->ram_we = dut->fbw_we = 0;
    dut->DDRAM_BUSY = 0; dut->DDRAM_DOUT_READY = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    tick();

    // The PROM download first, because on hardware it is what happens first:
    // 512 KB written through the dl port while the CPU is held in reset.
    printf("downloading a PROM image ...\n");
    std::map<uint32_t, uint64_t> prom_shadow;
    for (uint32_t off = 0; off < 512 * 1024; off += 8) {
        uint64_t v = ((uint64_t)off << 32) ^ 0x5A5AA5A5ull ^ off;
        prom_shadow[off] = v;
        dut->dl_req = 1; dut->dl_addr = off; dut->dl_wdata = v; dut->dl_be = 0xFF;
        int spins = 0;
        while (!dut->dl_ack && ++spins < 500) tick();
        if (!dut->dl_ack) { printf("  FAILED download stalled at %08x\n", off); failures++; break; }
        dut->dl_req = 0;
        tick();
    }
    printf("  %zu doublewords written\n", prom_shadow.size());

    // Now random traffic from the other four at once, which is the case that
    // matters: they are only ever in each other's way here.
    const int ROUNDS = 60000;
    printf("running %d cycles of four-master traffic ...\n", ROUNDS);

    auto region_size = [](Master *m) -> uint32_t {
        if (m == &m_ram)  return 64u * 1024 * 1024;    // the OSD's largest
        if (m == &m_prom) return 512u * 1024;
        return 8u * 1024 * 1024;               // frame buffer, a slice of it
    };

    Master *all[4] = {&m_fbr, &m_ram, &m_prom, &m_fbw};
    // The frame buffer is one store with two ports, so its two masters share
    // one shadow - that is the point of them.
    std::map<uint32_t, uint64_t> fb_shadow;

    for (int c = 0; c < ROUNDS; c++) {
        // Issue for any idle master, sometimes.
        for (Master *m : all) {
            if (m->busy) { m->wait_cycles++; continue; }
            if ((rng() % 100) >= 25) continue;
            uint32_t a = (rng() % (region_size(m) / 8)) * 8;
            m->addr = a;
            m->issued++;
            if (m == &m_fbr) {
                // THE DISPLAY IS A BURST MASTER. It asks for a run of words
                // and takes them as they stream back, which is the only way a
                // scanline arrives inside a line time - see ddr3_mux.sv.
                m->is_write = false;
                m->burst = 1 + (int)(rng() % 16);
                m->got = 0;
                dut->fbr_addr = a; dut->fbr_burst = m->burst; dut->fbr_req = 1;
            } else if (m == &m_prom) {
                m->is_write = false;
                m->expect = prom_shadow.count(a) ? prom_shadow[a] : 0;
                dut->prom_addr = a; dut->prom_req = 1;
            } else if (m == &m_ram) {
                m->is_write = (rng() % 2) == 0;
                if (m->is_write) {
                    uint64_t v = garbage();
                    m->shadow[a] = v;
                    dut->ram_wdata = v; dut->ram_be = 0xFF;
                } else {
                    m->expect = m->shadow.count(a) ? m->shadow[a] : 0;
                }
                dut->ram_addr = a; dut->ram_we = m->is_write; dut->ram_req = 1;
            } else {
                m->is_write = (rng() % 2) == 0;
                if (m->is_write) {
                    uint64_t v = garbage();
                    fb_shadow[a] = v;
                    dut->fbw_wdata = v; dut->fbw_be = 0xFF;
                } else {
                    m->expect = fb_shadow.count(a) ? fb_shadow[a] : 0;
                }
                dut->fbw_addr = a; dut->fbw_we = m->is_write; dut->fbw_req = 1;
            }
            m->busy = true;
            m->wait_cycles = 0;
        }

        tick();
        // The burst request is HELD until the mux takes it; everything else
        // pulses. Both shapes have to be exercised, because the mux latches
        // one and streams the other.
        if (dut->fbr_taken) dut->fbr_req = 0;
        if (getenv("DDR3_DEBUG") && c < 40)
            printf("[%3d] req f=%d r=%d p=%d w=%d | RD=%d WE=%d ADDR=%08x BUSY=%d "
                   "RDY=%d | ack f=%d r=%d p=%d w=%d\n", c,
                   dut->fbr_req, dut->ram_req, dut->prom_req, dut->fbw_req,
                   dut->DDRAM_RD, dut->DDRAM_WE, dut->DDRAM_ADDR, dut->DDRAM_BUSY,
                   dut->DDRAM_DOUT_READY,
                   dut->fbr_taken * 2 + dut->fbr_dout_valid,
                   dut->ram_ack, dut->prom_ack, dut->fbw_ack);

        // THE REQUEST IS A PULSE. Dropping it here is the whole reason the mux
        // has to latch: this is what sgi_indy.sv's CPU port does.
        dut->ram_req = dut->prom_req = dut->fbw_req = 0;

        if (s_fbr_valid) {
            uint32_t a = m_fbr.addr + (uint32_t)m_fbr.got * 8;
            uint64_t want = fb_shadow.count(a) ? fb_shadow[a] : 0;
            if (s_fbr_dout != want) fail("fbr burst word", a, want, s_fbr_dout);
            if (++m_fbr.got >= m_fbr.burst) {
                m_fbr.busy = false; m_fbr.acked++;
                if (m_fbr.wait_cycles > m_fbr.worst_wait)
                    m_fbr.worst_wait = m_fbr.wait_cycles;
            }
        }
        if (dut->ram_ack) {
            if (!m_ram.is_write && dut->ram_rdata != m_ram.expect)
                fail("ram read", m_ram.addr, m_ram.expect, dut->ram_rdata);
            m_ram.busy = false; m_ram.acked++;
            if (m_ram.wait_cycles > m_ram.worst_wait) m_ram.worst_wait = m_ram.wait_cycles;
        }
        if (dut->prom_ack) {
            if (dut->prom_rdata != m_prom.expect)
                fail("prom read", m_prom.addr, m_prom.expect, dut->prom_rdata);
            m_prom.busy = false; m_prom.acked++;
            if (m_prom.wait_cycles > m_prom.worst_wait) m_prom.worst_wait = m_prom.wait_cycles;
        }
        if (dut->fbw_ack) {
            if (!m_fbw.is_write && dut->fbw_rdata != m_fbw.expect)
                fail("fbw read", m_fbw.addr, m_fbw.expect, dut->fbw_rdata);
            m_fbw.busy = false; m_fbw.acked++;
            if (m_fbw.wait_cycles > m_fbw.worst_wait) m_fbw.worst_wait = m_fbw.wait_cycles;
        }
    }

    printf("\n%-6s %10s %10s %12s\n", "master", "issued", "acked", "worst wait");
    for (Master *m : all)
        printf("%-6s %10llu %10llu %12llu\n", m->name,
               (unsigned long long)m->issued, (unsigned long long)m->acked,
               (unsigned long long)m->worst_wait);

    auto check = [&](const char *what, bool ok) {
        printf("  %s %s\n", ok ? "ok     " : "FAILED ", what);
        if (!ok) failures++;
    };
    printf("\n");
    check("every read returned what was last written to it", failures == 0);
    // At most one outstanding per master, so acked is issued or one behind.
    bool balanced = true;
    for (Master *m : all)
        if (m->issued - m->acked > 1) balanced = false;
    check("every request was acknowledged exactly once", balanced);
    check("all four masters made progress",
          m_fbr.acked > 100 && m_ram.acked > 100 &&
          m_prom.acked > 100 && m_fbw.acked > 100);
    // The display is first in the priority list, so it must never wait longer
    // than the rasteriser does. This is the property that stops a screen from
    // tearing whenever REX3 is busy.
    check("the display port is not starved behind the rasteriser",
          m_fbr.worst_wait <= m_fbw.worst_wait);
    // A region overlap shows up as one master reading another's data, which
    // the shadows above already catch - but only if the regions were actually
    // exercised far enough apart to alias. 64 MB of RAM against a 16 MB frame
    // buffer at a 64 MB offset aliases at once if the base is dropped.
    check("main memory and the frame buffer did not alias",
          m_ram.acked > 100 && failures == 0);

    printf(failures ? "\nDDR3MUX: FAIL\n" : "\nDDR3MUX: PASS\n");
    delete dut;
    return failures ? 1 : 0;
}
