//============================================================================
//  tb_mcdma.cpp - the MC's GIO64 DMA engine against IRIS's own loops.
//
//  THE REFERENCE HERE IS A TRANSCRIPTION, NOT AN OPINION. `reference()` below
//  is IRIS's `dma_worker` and `translate_addr` from src/mc.rs written out in
//  C++, byte for byte: the fill arm, both copy directions, and the µTLB walk
//  with its PTE fetch and its three fault causes. The test compares what the
//  RTL actually puts on its two buses - final memory contents, the ordered
//  stream of 64-bit GIO beats, the fault bits, and the written-back end
//  address - against what that transcription produces. A test written from a
//  reading of the RTL would agree with the RTL and prove nothing.
//
//  The copy modes are the ones IRIX's ng1 driver uses for every pixel X
//  draws (docs/33): mode 0x50 mem->GIO with XLATE for writes, 0x52 for
//  reads. The cases below include the exact shapes Ng1PixelDma programs -
//  translated, unaligned, multi-line with stride - and the fault paths.
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
static const uint32_t CTL_PTE8     = 1u << 0;
static const uint32_t CTL_PG16K    = 1u << 1;
static const uint32_t CTL_XLATE    = 1u << 8;

// Fault bits as the engine reports them (DMA_CAUSE bits 0..2).
static const uint32_t F_FAULT    = 1;
static const uint32_t F_TLB_MISS = 2;
static const uint32_t F_CLEAN    = 4;

// ---- byte-addressed sparse memory ------------------------------------------
struct Mem {
    std::map<uint32_t, uint8_t> b;
    uint8_t  rd8(uint32_t a) const { auto it = b.find(a); return it == b.end() ? 0 : it->second; }
    void     wr8(uint32_t a, uint8_t v) { b[a] = v; }
    uint32_t rd32(uint32_t a) const {
        return ((uint32_t)rd8(a) << 24) | ((uint32_t)rd8(a+1) << 16)
             | ((uint32_t)rd8(a+2) << 8) | rd8(a+3);
    }
    void     wr32(uint32_t a, uint32_t v) {
        wr8(a, v >> 24); wr8(a+1, v >> 16); wr8(a+2, v >> 8); wr8(a+3, v);
    }
    uint64_t rd64(uint32_t a) const {
        return ((uint64_t)rd32(a) << 32) | rd32(a + 4);
    }
    bool operator==(const Mem &o) const { return b == o.b; }
};

// The deterministic values a GIO read beat returns, so both sides agree.
static uint64_t gio_read_val(int i)
{
    return 0x9E3779B97F4A7C15ull * (uint64_t)(i + 1) ^ 0x0123456789ABCDEFull;
}

// ---- IRIS's translate_addr, transcribed ------------------------------------
// Returns true and fills `phys` on success; false with `fault` set otherwise.
static bool xl_ref(const Desc &d, const uint32_t tlb[8], Mem &m,
                   uint32_t vaddr, bool writing, uint32_t &phys, uint32_t &fault)
{
    if (!(d.ctl & CTL_XLATE)) { phys = vaddr; return true; }
    bool     pg16k = (d.ctl & CTL_PG16K) != 0;
    bool     pte8  = (d.ctl & CTL_PTE8) != 0;
    uint32_t page_shift = pg16k ? 14 : 12;
    uint32_t page_mask  = pg16k ? 0x3FFF : 0xFFF;

    for (int i = 0; i < 4; i++) {
        uint32_t hi = tlb[2*i], lo = tlb[2*i + 1];
        if ((vaddr & 0xFFC00000u) != (hi & 0xFFC00000u)) continue;
        if (!(lo & 2)) { fault = F_TLB_MISS; return false; }
        uint32_t pte_base = (lo & 0x03FFFFC0u) << 6;
        uint32_t vpn_lo   = (vaddr & 0x003FFFFFu) >> page_shift;
        uint32_t pte_addr = pte_base + (vpn_lo << (pte8 ? 3 : 2));
        // 8-byte PTEs take the LOW word of the qword (IRIS reads 64 bits and
        // keeps the bottom).
        uint32_t pte = pte8 ? (uint32_t)(m.rd64(pte_addr & ~7u) & 0xFFFFFFFFu)
                            : m.rd32(pte_addr);
        if (!(pte & 2))            { fault = F_FAULT; return false; }
        if (writing && !(pte & 4)) { fault = F_CLEAN; return false; }
        phys = ((pte & 0x03FFFFC0u) << 6) | (vaddr & page_mask);
        return true;
    }
    fault = F_TLB_MISS;
    return false;
}

// ---- IRIS's dma_worker, transcribed ----------------------------------------
struct RefOut {
    Mem mem;                       // final memory
    std::vector<uint64_t> beats;   // mem->gio, in order
    uint32_t fault = 0;
    uint32_t end_memadr = 0;
    bool     skipped = false;
    int      gio_reads = 0;
};

static void reference(const Desc &d, const uint32_t tlb[8], const Mem &init,
                      RefOut &o)
{
    o.mem = init;

    bool to_host = (d.mode & MODE_TO_HOST) != 0;
    bool fill    = (d.mode & MODE_FILL) != 0;
    bool dir_up  = (d.mode & MODE_DIR) != 0;

    bool is_fill = fill && to_host;
    bool is_m2g  = !fill && !to_host && dir_up;
    bool is_g2m  = !fill &&  to_host && dir_up;
    if (!(is_fill || is_m2g || is_g2m)) { o.skipped = true; return; }

    uint32_t line_count = (d.size >> 16) & 0xFFFF;
    uint32_t line_width =  d.size        & 0xFFFF;
    uint32_t line_zoom  = (d.stride >> 16) & 0x3FF;
    int32_t  stride     = (int16_t)(d.stride & 0xFFFF);
    uint32_t zoom_count = (d.count >> 16) & 0x3FF;
    uint32_t byte_count =  d.count        & 0xFFFF;
    uint32_t fill_val   =  d.gio_adr & ~7u;
    uint32_t mem        =  d.memadr;

    while (line_count > 0) {
        line_count--;
        while (zoom_count > 0) {
            zoom_count--;
            while (byte_count > 0) {
                if (is_fill) {
                    uint32_t phys;
                    if (!xl_ref(d, tlb, o.mem, mem, true, phys, o.fault))
                        goto out;
                    o.mem.wr32(phys, fill_val);
                    mem = dir_up ? mem + 4 : mem - 4;
                    byte_count = byte_count >= 4 ? byte_count - 4 : 0;
                } else if (is_m2g) {
                    uint32_t len = byte_count < 8 ? byte_count : 8;
                    uint64_t data = 0;
                    for (uint32_t j = 0; j < len; j++) {
                        uint32_t phys;
                        if (!xl_ref(d, tlb, o.mem, mem, false, phys, o.fault))
                            goto out;
                        data |= (uint64_t)o.mem.rd8(phys) << (56 - 8*j);
                        mem++;
                    }
                    o.beats.push_back(data);
                    byte_count -= len;
                } else {
                    uint32_t len = byte_count < 8 ? byte_count : 8;
                    uint64_t data = gio_read_val(o.gio_reads++);
                    for (uint32_t j = 0; j < len; j++) {
                        uint32_t phys;
                        if (!xl_ref(d, tlb, o.mem, mem, true, phys, o.fault))
                            goto out;
                        o.mem.wr8(phys, (uint8_t)(data >> (56 - 8*j)));
                        mem++;
                    }
                    byte_count -= len;
                }
            }
            byte_count = line_width;
            if (zoom_count > 0)
                mem = dir_up ? mem - line_width : mem + line_width;
        }
        zoom_count = line_zoom;
        mem = (uint32_t)((int32_t)mem + stride);
    }
out:
    o.end_memadr = mem;
}

// ---- the RTL ---------------------------------------------------------------
class Dut {
public:
    Vmc_gio_dma *t;
    Dut() : t(new Vmc_gio_dma) {}
    ~Dut() { delete t; }
    void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
};

struct RtlOut {
    Mem mem;
    std::vector<uint64_t> beats;
    uint32_t fault = 0;
    uint32_t end_memadr = 0;
    bool     wb_valid = false;
    bool     skipped = false;
    int      gio_reads = 0;
};

// `ack_delay` models an arbiter that is not always ready. The CPU wins every
// tie in sgi_indy.sv, so this engine can and will be held off, and an engine
// that only works against an instant ack would pass here and stall on silicon.
static bool run_rtl(Dut &dut, const Desc &d, const uint32_t tlb[8],
                    const Mem &init, int ack_delay, RtlOut &o, long &cycles)
{
    o.mem = init;

    dut.t->reset = 1; dut.t->start = 0; dut.t->m_ack = 0; dut.t->g_ack = 0;
    for (int i = 0; i < 4; i++) dut.tick();
    dut.t->reset = 0;

    dut.t->d_memadr = d.memadr; dut.t->d_size  = d.size;
    dut.t->d_stride = d.stride; dut.t->d_gio_adr = d.gio_adr;
    dut.t->d_mode   = d.mode;   dut.t->d_count = d.count;
    dut.t->d_ctl    = d.ctl;
    for (int i = 0; i < 8; i++) dut.t->tlb_flat[i] = tlb[i];
    dut.t->start = 1; dut.tick(); dut.t->start = 0;

    int mwait = 0, gwait = 0;
    for (cycles = 0; cycles < 8000000; cycles++) {
        dut.t->m_ack = 0; dut.t->g_ack = 0;

        if (dut.t->m_req) {
            if (mwait >= ack_delay) {
                uint32_t a = dut.t->m_addr;
                if (a & 7) { printf("      unaligned m_addr 0x%08x\n", a); return false; }
                if (dut.t->m_we) {
                    uint64_t wd = dut.t->m_wdata;
                    uint8_t  be = dut.t->m_be;
                    for (int i = 0; i < 8; i++)
                        if (be & (0x80u >> i))
                            o.mem.wr8(a + i, (uint8_t)(wd >> (56 - 8*i)));
                } else {
                    dut.t->m_rdata = o.mem.rd64(a);
                }
                dut.t->m_ack = 1;
                mwait = 0;
            } else mwait++;
        } else mwait = 0;

        if (dut.t->g_req) {
            if (gwait >= ack_delay) {
                if (dut.t->g_addr != d.gio_adr) {
                    printf("      g_addr 0x%08x, expected 0x%08x\n",
                           (uint32_t)dut.t->g_addr, d.gio_adr);
                    return false;
                }
                if (dut.t->g_we) o.beats.push_back(dut.t->g_wdata);
                else             dut.t->g_rdata = gio_read_val(o.gio_reads++);
                dut.t->g_ack = 1;
                gwait = 0;
            } else gwait++;
        } else gwait = 0;

        dut.tick();
        if (dut.t->done) {
            o.skipped    = dut.t->mode_unsupported;
            o.fault      = dut.t->fault;
            o.wb_valid   = dut.t->wb_valid;
            o.end_memadr = dut.t->wb_memadr;
            return true;
        }
    }
    printf("      never finished\n");
    return false;
}

// ---- scenario helpers -------------------------------------------------------
// A page table for the XLATE cases: virtual 0x00400000.. maps through µTLB
// entry 0. `vpage_to_ppage[i]` places virtual page i (4 KB) of that segment;
// perm bits come with it. PTEs live at 0x08100000.
static const uint32_t PT_BASE  = 0x08100000;
static const uint32_t VSEG     = 0x00400000;

static void setup_pt(uint32_t tlb[8], Mem &m,
                     const std::vector<std::pair<uint32_t,uint32_t>> &pages,
                     bool pte8 = false)
{
    for (int i = 0; i < 8; i++) tlb[i] = 0;
    tlb[0] = VSEG;                                // hi: tag = vaddr[31:22]
    tlb[1] = ((PT_BASE >> 12) << 6) | 2;          // lo: PTE base, valid
    for (size_t i = 0; i < pages.size(); i++) {
        uint32_t pte = ((pages[i].first >> 12) << 6) | pages[i].second;
        if (pte8) { m.wr32(PT_BASE + 8*i, 0); m.wr32(PT_BASE + 8*i + 4, pte); }
        else      m.wr32(PT_BASE + 4*i, pte);
    }
}

static void fill_pattern(Mem &m, uint32_t base, uint32_t len, uint32_t seed)
{
    for (uint32_t i = 0; i < len; i++)
        m.wr8(base + i, (uint8_t)(seed + i * 7 + (i >> 5)));
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);

    struct Case {
        Desc d;
        uint32_t tlb[8] = {0,0,0,0,0,0,0,0};
        Mem init;
    };
    std::vector<Case> cases;

    auto add = [&](const Desc &d) -> Case & {
        cases.push_back(Case{d});
        return cases.back();
    };

    // ---- the original fill suite, unchanged semantics ----
    add({ "PROM default (1 line, 12 bytes)",
          0x08001000, 0x0001000C, 0x00010000, 0xDEADBEEF, MODE_FILL|MODE_TO_HOST, 0x0001000C, 0 });
    add({ "flat 4 KB clear",
          0x08010000, 0x00011000, 0x00010000, 0x00000000, MODE_FILL|MODE_TO_HOST, 0x00011000, 0 });
    add({ "four lines, positive stride",
          0x08020000, 0x00040020, 0x00010100, 0x5A5A5A5A, MODE_FILL|MODE_TO_HOST, 0x00010020, 0 });
    add({ "four lines, NEGATIVE stride",
          0x08030000, 0x00040020, 0x0001FF00, 0xA5A5A5A5, MODE_FILL|MODE_TO_HOST, 0x00010020, 0 });
    add({ "zoom x3 over two lines",
          0x08040000, 0x00020010, 0x00030040, 0x11223344, MODE_FILL|MODE_TO_HOST, 0x00030010, 0 });
    add({ "first line shorter than the rest",
          0x08050000, 0x00030020, 0x00010000, 0x0F0F0F0F, MODE_FILL|MODE_TO_HOST, 0x00010008, 0 });
    add({ "downwards fill (DIR set)",
          0x08061000, 0x00020010, 0x00010000, 0xCAFEBABE, MODE_FILL|MODE_TO_HOST|MODE_DIR, 0x00010010, 0 });
    add({ "byte count not a multiple of four",
          0x08070000, 0x0001000A, 0x00010000, 0x12345678, MODE_FILL|MODE_TO_HOST, 0x0001000A, 0 });
    add({ "zero lines",
          0x08080000, 0x0000000C, 0x00010000, 0x1, MODE_FILL|MODE_TO_HOST, 0x0001000C, 0 });
    add({ "zero-length line",
          0x08090000, 0x00010000, 0x00010000, 0x1, MODE_FILL|MODE_TO_HOST, 0x00010000, 0 });

    // ---- modes the engine still skips ----
    add({ "mem->gio without DIR: skipped",
          0x080A0000, 0x0001000C, 0x00010000, 0x1F0F0A30, 0, 0x0001000C, 0 });
    add({ "fill but not to_host: skipped",
          0x080B0000, 0x0001000C, 0x00010000, 0x1, MODE_FILL, 0x0001000C, 0 });

    // ---- MEM->GIO, the X pixel-write path (mode 0x50 shape) ----
    {
        auto &c = add({ "m2g aligned, one line of 64",
            0x08200000, 0x00010040, 0x00010000, 0x1F0F0A30, MODE_DIR|0x40, 0x00010040, 0 });
        fill_pattern(c.init, 0x08200000, 0x40, 0x30);
    }
    {
        auto &c = add({ "m2g unaligned start, odd length",
            0x08200003, 0x0001001E, 0x00010000, 0x1F0F0A34, MODE_DIR|0x40, 0x0001001E, 0 });
        fill_pattern(c.init, 0x08200000, 0x40, 0x51);
    }
    {
        auto &c = add({ "m2g four lines with stride (a blit)",
            0x08201000, 0x00040018, 0x00010020, 0x1F0F0A30, MODE_DIR|0x40, 0x00010018, 0 });
        fill_pattern(c.init, 0x08201000, 0x100, 0x77);
    }
    {
        auto &c = add({ "m2g translated across a page boundary",
            VSEG + 0xFE9, 0x00010030, 0x00010000, 0x1F0F0A30,
            MODE_DIR|0x40, 0x00010030, CTL_XLATE });
        setup_pt(c.tlb, c.init, {{0x08300000, 6}, {0x08280000, 6}});
        fill_pattern(c.init, 0x08300F00, 0x100, 0x10);
        fill_pattern(c.init, 0x08280000, 0x100, 0x90);
    }
    {
        auto &c = add({ "m2g translated, 8-byte PTEs",
            VSEG + 0x10, 0x00010020, 0x00010000, 0x1F0F0A30,
            MODE_DIR|0x40, 0x00010020, CTL_XLATE|CTL_PTE8 });
        setup_pt(c.tlb, c.init, {{0x08300000, 6}}, true);
        fill_pattern(c.init, 0x08300000, 0x40, 0x21);
    }
    {
        auto &c = add({ "m2g TLB miss faults",
            0x00800000, 0x00010020, 0x00010000, 0x1F0F0A30,
            MODE_DIR|0x40, 0x00010020, CTL_XLATE });
        setup_pt(c.tlb, c.init, {{0x08300000, 6}});   // maps VSEG, not 0x00800000
    }
    {
        auto &c = add({ "m2g invalid PTE faults mid-run",
            VSEG + 0xFF0, 0x00010040, 0x00010000, 0x1F0F0A30,
            MODE_DIR|0x40, 0x00010040, CTL_XLATE });
        setup_pt(c.tlb, c.init, {{0x08300000, 6}, {0x08280000, 0}});
        fill_pattern(c.init, 0x08300F00, 0x100, 0x44);
    }

    // ---- GIO->MEM, the X readback path (mode 0x52 shape) ----
    {
        add({ "g2m aligned, one line of 32",
            0x08210000, 0x00010020, 0x00010000, 0x1F0F0A30,
            MODE_DIR|MODE_TO_HOST|0x40, 0x00010020, 0 });
    }
    {
        add({ "g2m unaligned, short tail",
            0x08210005, 0x00010013, 0x00010000, 0x1F0F0A30,
            MODE_DIR|MODE_TO_HOST|0x40, 0x00010013, 0 });
    }
    {
        auto &c = add({ "g2m translated",
            VSEG + 0x20, 0x00020010, 0x00010018, 0x1F0F0A30,
            MODE_DIR|MODE_TO_HOST|0x40, 0x00010010, CTL_XLATE });
        setup_pt(c.tlb, c.init, {{0x08310000, 6}});
    }
    {
        auto &c = add({ "g2m clean page faults",
            VSEG + 0x00, 0x00010010, 0x00010000, 0x1F0F0A30,
            MODE_DIR|MODE_TO_HOST|0x40, 0x00010010, CTL_XLATE });
        setup_pt(c.tlb, c.init, {{0x08310000, 2}});   // valid, NOT writable
    }

    // ---- fill through the µTLB, no longer skipped ----
    {
        auto &c = add({ "fill translated",
            VSEG + 0x40, 0x00010020, 0x00010000, 0xABCD0128,
            MODE_FILL|MODE_TO_HOST|MODE_DIR, 0x00010020, CTL_XLATE });
        setup_pt(c.tlb, c.init, {{0x08320000, 6}});
    }

    Dut dut;
    int fails = 0, runs = 0;
    printf("MC GIO64 DMA engine vs IRIS mc.rs (fill + copies + xlate)\n\n");

    for (const Case &c : cases) {
        RefOut want;
        reference(c.d, c.tlb, c.init, want);
        bool bad = false;
        for (int ack_delay : {0, 3}) {
            RtlOut got; long cycles = 0;
            runs++;
            if (!run_rtl(dut, c.d, c.tlb, c.init, ack_delay, got, cycles)) { bad = true; continue; }
            if (got.skipped != want.skipped) {
                printf("      ack=%d: mode_unsupported=%d, expected %d\n",
                       ack_delay, got.skipped, want.skipped);
                bad = true;
            }
            if (got.fault != want.fault) {
                printf("      ack=%d: fault=%u, expected %u\n",
                       ack_delay, got.fault, want.fault);
                bad = true;
            }
            if (!(got.mem == want.mem)) {
                printf("      ack=%d: final memory differs\n", ack_delay);
                for (auto &kv : want.mem.b)
                    if (got.mem.rd8(kv.first) != kv.second) {
                        printf("        first diff at 0x%08x: got 0x%02x want 0x%02x\n",
                               kv.first, got.mem.rd8(kv.first), kv.second);
                        break;
                    }
                bad = true;
            }
            if (got.beats != want.beats) {
                printf("      ack=%d: %zu beats, expected %zu\n",
                       ack_delay, got.beats.size(), want.beats.size());
                for (size_t i = 0; i < got.beats.size() && i < want.beats.size(); i++)
                    if (got.beats[i] != want.beats[i]) {
                        printf("        beat %zu: got %016llx want %016llx\n", i,
                               (unsigned long long)got.beats[i],
                               (unsigned long long)want.beats[i]);
                        break;
                    }
                bad = true;
            }
            if (!want.skipped && got.wb_valid
                && got.end_memadr != want.end_memadr) {
                printf("      ack=%d: end memadr 0x%08x, expected 0x%08x\n",
                       ack_delay, got.end_memadr, want.end_memadr);
                bad = true;
            }
        }
        if (bad) fails++;
        printf("  %-42s %s  (%zu beats, fault=%u)\n", c.d.name,
               bad ? "FAIL" : "ok", want.beats.size(), want.fault);
    }

    printf("\n%d descriptors x 2 ack delays = %d runs, %d descriptors failed\n",
           (int)cases.size(), runs, fails);
    return fails ? 1 : 0;
}
