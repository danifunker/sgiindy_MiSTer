//============================================================================
//  tb_mcdma.cpp - the MC's GIO64 DMA fill engine against IRIS's own loop.
//
//  THE REFERENCE HERE IS A TRANSCRIPTION, NOT AN OPINION. `reference()` below
//  is IRIS's `dma_worker` inner loops from src/mc.rs written out in C++, and
//  the test compares the bytes the RTL actually puts on the bus against the
//  bytes that produces. That matters more than usual for this engine: its
//  register layout is three nested counts with a reload rule that is easy to
//  get subtly wrong, and the descriptor the PROM uses exercises exactly one
//  corner of it. A test written from my reading of the RTL would agree with
//  the RTL and prove nothing.
//
//  It also covers the cases the PROM never generates - zero lines, zero-length
//  lines, a negative stride, zoom repeats, fills running downwards - because
//  IRIX does use this engine and the next person should not have to find out
//  which corners were only ever guessed at.
//
//  Build:  make -C verilator mcdmatest
//============================================================================

#include <cstdio>
#include <cstring>
#include <cstdint>
#include <map>
#include <vector>
#include "Vmc_gio_dma.h"
#include "verilated.h"

struct Desc {
    const char *name;
    uint32_t memadr, size, stride, gio_adr, mode, count, ctl;
};

// Mode/ctl bits, from IRIS's mc.rs.
static const uint32_t MODE_TO_HOST = 1u << 1;
static const uint32_t MODE_FILL    = 1u << 3;
static const uint32_t MODE_DIR     = 1u << 4;
static const uint32_t CTL_XLATE    = 1u << 8;

// ---- IRIS's loop, transcribed ---------------------------------------------
// mc.rs `dma_worker`, the to_host && fill arm of the general path. Writes are
// recorded in order, because "the right bytes eventually" and "the right bytes
// in the right order" are different claims and a DMA engine owes the second.
static void reference(const Desc &d, std::vector<std::pair<uint32_t,uint32_t>> &out)
{
    if (!((d.mode & MODE_FILL) && (d.mode & MODE_TO_HOST)) || (d.ctl & CTL_XLATE))
        return;                                   // modes this engine skips

    uint32_t line_count = (d.size >> 16) & 0xFFFF;
    uint32_t line_width =  d.size        & 0xFFFF;
    uint32_t line_zoom  = (d.stride >> 16) & 0x3FF;
    int32_t  stride     = (int16_t)(d.stride & 0xFFFF);
    uint32_t zoom_count = (d.count >> 16) & 0x3FF;
    uint32_t byte_count =  d.count        & 0xFFFF;
    uint32_t gio        =  d.gio_adr & ~7u;
    uint32_t mem        =  d.memadr;
    bool     dir_up     = (d.mode & MODE_DIR) != 0;

    while (line_count > 0) {
        line_count--;
        while (zoom_count > 0) {
            zoom_count--;
            while (byte_count > 0) {
                out.push_back({mem, gio});
                mem = dir_up ? mem + 4 : mem - 4;
                byte_count = byte_count >= 4 ? byte_count - 4 : 0;
            }
            byte_count = line_width;
            if (zoom_count > 0)
                mem = dir_up ? mem - line_width : mem + line_width;
        }
        zoom_count = line_zoom;
        mem = (uint32_t)((int32_t)mem + stride);
    }
}

// ---- the RTL ---------------------------------------------------------------
class Dut {
public:
    Vmc_gio_dma *t;
    Dut() : t(new Vmc_gio_dma) {}
    ~Dut() { delete t; }
    void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
};

// `ack_delay` models an arbiter that is not always ready. The CPU wins every
// tie in sgi_indy.sv, so this engine can and will be held off, and an engine
// that only works against an instant ack would pass here and stall on silicon.
static bool run_rtl(Dut &dut, const Desc &d, int ack_delay,
                    std::vector<std::pair<uint32_t,uint32_t>> &out,
                    bool &skipped, long &cycles)
{
    dut.t->reset = 1; dut.t->start = 0; dut.t->m_ack = 0;
    for (int i = 0; i < 4; i++) dut.tick();
    dut.t->reset = 0;

    dut.t->d_memadr = d.memadr; dut.t->d_size  = d.size;
    dut.t->d_stride = d.stride; dut.t->d_gio_adr = d.gio_adr;
    dut.t->d_mode   = d.mode;   dut.t->d_count = d.count;
    dut.t->d_ctl    = d.ctl;
    dut.t->start = 1; dut.tick(); dut.t->start = 0;

    skipped = false;
    int wait = 0;
    for (cycles = 0; cycles < 8000000; cycles++) {
        // Acknowledge a held request after ack_delay idle cycles.
        if (dut.t->m_req) {
            if (wait >= ack_delay) {
                // Recover the 32-bit word and its address from the 64-bit lane.
                uint64_t wd = dut.t->m_wdata;
                uint8_t  be = dut.t->m_be;
                uint32_t a  = dut.t->m_addr;
                if (be == 0xF0)      out.push_back({a,     (uint32_t)(wd >> 32)});
                else if (be == 0x0F) out.push_back({a + 4, (uint32_t)(wd & 0xFFFFFFFFu)});
                else { printf("      bad byte enables 0x%02x\n", be); return false; }
                dut.t->m_ack = 1;
                wait = 0;
            } else { dut.t->m_ack = 0; wait++; }
        } else { dut.t->m_ack = 0; wait = 0; }

        dut.tick();
        dut.t->m_ack = 0;
        if (dut.t->done) { skipped = dut.t->mode_unsupported; return true; }
    }
    printf("      never finished\n");
    return false;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);

    const std::vector<Desc> cases = {
        // The PROM's own default descriptor, from REG_DMA_MEMADRD.
        { "PROM default (1 line, 12 bytes)",
          0x08001000, 0x0001000C, 0x00010000, 0xDEADBEEF, MODE_FILL|MODE_TO_HOST, 0x0001000C, 0 },
        // A flat clear of the shape a boot memory clear wants.
        { "flat 4 KB clear",
          0x08010000, 0x00010000 | 0x1000, 0x00010000, 0x00000000, MODE_FILL|MODE_TO_HOST, 0x00010000 | 0x1000, 0 },
        { "four lines, positive stride",
          0x08020000, 0x00040020, 0x00010100, 0x5A5A5A5A, MODE_FILL|MODE_TO_HOST, 0x00010020, 0 },
        { "four lines, NEGATIVE stride",
          0x08030000, 0x00040020, 0x0001FF00, 0xA5A5A5A5, MODE_FILL|MODE_TO_HOST, 0x00010020, 0 },
        { "zoom x3 over two lines",
          0x08040000, 0x00020010, 0x00030040, 0x11223344, MODE_FILL|MODE_TO_HOST, 0x00030010, 0 },
        { "first line shorter than the rest",
          0x08050000, 0x00030020, 0x00010000, 0x0F0F0F0F, MODE_FILL|MODE_TO_HOST, 0x00010008, 0 },
        { "downwards (DIR set)",
          0x08061000, 0x00020010, 0x00010000, 0xCAFEBABE, MODE_FILL|MODE_TO_HOST|MODE_DIR, 0x00010010, 0 },
        { "byte count not a multiple of four",
          0x08070000, 0x0001000A, 0x00010000, 0x12345678, MODE_FILL|MODE_TO_HOST, 0x0001000A, 0 },
        // Degenerate descriptors: these must terminate and write nothing.
        { "zero lines",
          0x08080000, 0x0000000C, 0x00010000, 0x1, MODE_FILL|MODE_TO_HOST, 0x0001000C, 0 },
        { "zero-length line",
          0x08090000, 0x00010000, 0x00010000, 0x1, MODE_FILL|MODE_TO_HOST, 0x00010000, 0 },
        // Modes the engine deliberately does not perform.
        { "not fill (mem->gio)",
          0x080A0000, 0x0001000C, 0x00010000, 0x1, MODE_TO_HOST, 0x0001000C, 0 },
        { "fill but not to_host",
          0x080B0000, 0x0001000C, 0x00010000, 0x1, MODE_FILL, 0x0001000C, 0 },
        { "translated (XLATE)",
          0x080C0000, 0x0001000C, 0x00010000, 0x1, MODE_FILL|MODE_TO_HOST, 0x0001000C, CTL_XLATE },
    };

    Dut dut;
    int fails = 0, runs = 0;
    printf("MC GIO64 DMA fill engine vs IRIS mc.rs\n\n");

    for (const Desc &d : cases) {
        std::vector<std::pair<uint32_t,uint32_t>> want;
        reference(d, want);
        bool bad = false;
        // Two ack delays: an arbiter that is always ready, and one that makes
        // the engine wait. The second is the real one.
        for (int ack_delay : {0, 3}) {
            std::vector<std::pair<uint32_t,uint32_t>> got;
            bool skipped = false; long cycles = 0;
            runs++;
            if (!run_rtl(dut, d, ack_delay, got, skipped, cycles)) { bad = true; continue; }
            bool want_skip = !((d.mode & MODE_FILL) && (d.mode & MODE_TO_HOST))
                             || (d.ctl & CTL_XLATE);
            if (skipped != want_skip) {
                printf("      ack=%d: mode_unsupported=%d, expected %d\n",
                       ack_delay, skipped, want_skip);
                bad = true;
            }
            if (got.size() != want.size()) {
                printf("      ack=%d: %zu writes, expected %zu\n",
                       ack_delay, got.size(), want.size());
                bad = true;
            } else {
                for (size_t i = 0; i < got.size(); i++) {
                    if (got[i] != want[i]) {
                        printf("      ack=%d: write %zu was 0x%08x<-0x%08x, "
                               "expected 0x%08x<-0x%08x\n", ack_delay, i,
                               got[i].first, got[i].second,
                               want[i].first, want[i].second);
                        bad = true;
                        break;
                    }
                }
            }
        }
        if (bad) fails++;
        printf("  %-38s %s  (%zu writes)\n", d.name, bad ? "FAIL" : "ok", want.size());
    }

    printf("\n%d descriptors x 2 ack delays = %d runs, %d descriptors failed\n",
           (int)cases.size(), runs, fails);
    return fails ? 1 : 0;
}
