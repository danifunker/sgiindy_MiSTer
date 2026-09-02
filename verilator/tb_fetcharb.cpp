//============================================================================
//  tb_fetcharb - two line caches and the arbiter on one burst port, against
//  a bridge that behaves like ddr3_mux.
//
//  WHAT THE BRIDGE MODEL DOES THAT tb_linecache's DOES NOT: it LATCHES the
//  address and the burst count on the first cycle it sees fbr_req, and only
//  issues (asserts fbr_taken) some cycles later - exactly what ddr3_mux does.
//  An arbiter that keeps re-choosing its winner between those two moments
//  hands the burst to the wrong reader, waits for a word count the burst does
//  not deliver, and stalls both caches for ever. That is what build 17 did on
//  the board, and this is the test that would have caught it.
//
//  WHAT IS CHECKED: the display's real pattern (n1280_r3), both caches asked
//  for every visible pixel, every answer after the first frame the word in
//  memory (or zeros for an empty auxiliary line), no misses after frame 0,
//  and the auxiliary fetch traffic collapsing once its flags settle. The
//  auxiliary region is one line in eight visible, the rest empty, garbage
//  beyond the visible span on every line - the board's situation.
//============================================================================

#include "Vtb_fetcharb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <deque>
#include <map>
#include <random>

static const int H_VIS = 1318, H_TOTAL = 1680;
static const int V_VIS = 1024, V_TOTAL = 1065;
static const int V_SYNC_AT = 1030;
static const int STRIDE = 2048;
static const int BPP = 4;
static const int PIX_DIV = 1;
static const uint32_t AUX_OFF = 0x00800000u;
static const uint64_t ZERO_MASK = 0x00FFFF0C00FFFF0Cull;

static Vtb_fetcharb *dut;
static std::mt19937 rng(4321);
static std::map<uint32_t, uint64_t> mem;

static uint64_t cell(uint32_t byteaddr)
{
    uint32_t w = byteaddr >> 3;
    return (uint64_t)w * 0x9E3779B97F4A7C15ull ^ 0x5A5A5A5Aull;
}
static bool aux_visible(int y) { return (y % 8) == 3; }

// ---- the bridge, modelled like ddr3_mux ----------------------------------
// A request seen on fbr_req is latched at once (address + burst), issued
// after a delay (fbr_taken for one cycle), and its words stream back after
// another delay with gaps. While a burst is latched or streaming, a new
// fbr_req is NOT looked at - the mux's pend bit does the same.
struct Burst { int issue_delay; int data_delay; uint32_t addr; int left; bool issued; };
static std::deque<Burst> q;
static uint64_t bursts_taken = 0, words_delivered = 0;

static void bridge(void)
{
    dut->fbr_taken = 0;
    dut->fbr_dout_valid = 0;
    dut->fbr_dout = ((uint64_t)rng() << 32) ^ rng();

    if (!q.empty()) {
        Burst &b = q.front();
        if (!b.issued) {
            if (b.issue_delay > 0) b.issue_delay--;
            else { b.issued = true; dut->fbr_taken = 1; bursts_taken++; }
        } else if (b.data_delay > 0) {
            b.data_delay--;
        } else if ((rng() % 100) < 70) {
            dut->fbr_dout = mem.count(b.addr) ? mem[b.addr] : 0;
            dut->fbr_dout_valid = 1;
            words_delivered++;
            b.addr += 8;
            if (--b.left == 0) q.pop_front();
        }
    } else if (dut->fbr_req) {
        // Latched NOW, with whatever address and burst are presented NOW.
        q.push_back({1 + (int)(rng() % 6), 4 + (int)(rng() % 12),
                     (uint32_t)dut->fbr_addr, (int)dut->fbr_burst, false});
    }
}

static uint64_t clks = 0;
static void tick()
{
    bridge();
    dut->eval();
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
    clks++;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_fetcharb;

    for (int y = 0; y < V_VIS; y++)
        for (int x = 0; x < 1344; x += 2) {
            uint32_t a = ((uint32_t)y * STRIDE + x) * BPP;
            uint64_t v = cell(a);
            if (v == 0) v = 0xFF000000FF000000ull;
            mem[a] = v;                                  // drawing planes
            uint64_t w = cell(a + AUX_OFF);
            if (x < H_VIS && !aux_visible(y)) w &= ~ZERO_MASK;
            if (w == 0) w = 0xFF000000FF000000ull;
            mem[a + AUX_OFF] = w;                        // auxiliary planes
        }

    dut->reset = 1; dut->clk = 0;
    dut->px_req = 0; dut->px_addr_rgb = 0; dut->px_addr_aux = 0; dut->vs = 0;
    dut->mark = 0; dut->mark_line = 0;
    dut->fbr_taken = 0; dut->fbr_dout_valid = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    tick();

    // Flags reset clear: mark the visible auxiliary lines the way the
    // rasteriser marks a line it writes something visible into.
    for (int y = 0; y < V_VIS; y++)
        if (aux_visible(y)) { dut->mark = 1; dut->mark_line = y; tick(); }
    dut->mark = 0;
    // Then restart the frame, so that a line published before its mark
    // landed (it shows a frame later, as on the board) is refetched.
    dut->vs = 1; for (int i = 0; i < 3; i++) tick();
    dut->vs = 0;
    // ...and give it the vertical blanking a real frame starts with: 41
    // lines' worth, in which the prefetcher gets ahead.
    for (int i = 0; i < (V_TOTAL - V_VIS) * H_TOTAL; i++) tick();

    const int FRAMES = 4;
    const int MARKED_LINE = 5;
    uint64_t checked = 0, wrong = 0, rmiss[FRAMES] = {0}, amiss[FRAMES] = {0};
    uint64_t bursts[FRAMES] = {0};
    uint64_t shown = 0;

    struct Expect { uint32_t addr; int y; int frame; };
    std::deque<Expect> inflight;

    auto sample = [&]() {
        if (!dut->rgb_ack && !dut->aux_ack) return;
        if (dut->rgb_ack != dut->aux_ack) { printf("  FAILED the two caches answered out of step\n"); wrong++; }
        if (inflight.empty()) { printf("  FAILED ack with nothing asked for\n"); wrong++; return; }
        Expect e = inflight.front(); inflight.pop_front();
        if (dut->rgb_miss) rmiss[e.frame]++;
        if (dut->aux_miss) amiss[e.frame]++;
        if (dut->rgb_miss || dut->aux_miss) return;
        checked++;
        uint32_t wa = e.addr & ~7u;
        uint64_t want_rgb = mem[wa];
        bool aux_fetched = aux_visible(e.y)
                        || (e.frame == 2 && e.y == MARKED_LINE);
        uint64_t want_aux = aux_fetched ? mem[wa + AUX_OFF] : 0;
        if (dut->rgb_rdata != want_rgb || dut->aux_rdata != want_aux) {
            wrong++;
            if (shown < 8) {
                printf("  FAILED frame %d line %d addr %08x: rgb want %016llx got %016llx, aux want %016llx got %016llx\n",
                       e.frame, e.y, e.addr,
                       (unsigned long long)want_rgb, (unsigned long long)dut->rgb_rdata,
                       (unsigned long long)want_aux, (unsigned long long)dut->aux_rdata);
                shown++;
            }
        }
    };

    for (int f = 0; f < FRAMES; f++) {
        uint64_t before = bursts_taken;
        if (f == 2) { dut->mark = 1; dut->mark_line = MARKED_LINE; tick(); sample(); dut->mark = 0; }
        for (int y = 0; y < V_TOTAL; y++) {
            dut->vs = (y == V_SYNC_AT || y == V_SYNC_AT + 1 || y == V_SYNC_AT + 2);
            for (int x = 0; x < H_TOTAL; x++) {
                bool visible = (y < V_VIS) && (x < H_VIS);
                uint32_t a = ((uint32_t)y * STRIDE + x) * BPP;
                dut->px_addr_rgb = visible ? a : ((uint32_t)y * STRIDE) * BPP;
                dut->px_addr_aux = dut->px_addr_rgb + AUX_OFF;
                dut->px_req = visible;
                if (visible) inflight.push_back({a, y, f});
                tick();
                sample();
                dut->px_req = 0;
                for (int k = 1; k < PIX_DIV; k++) { tick(); sample(); }
            }
        }
        bursts[f] = bursts_taken - before;
        printf("frame %d: rgb misses %llu, aux misses %llu, bursts %llu\n", f,
               (unsigned long long)rmiss[f], (unsigned long long)amiss[f],
               (unsigned long long)bursts[f]);
    }

    printf("\n%llu pixels checked over %d frames, %llu clocks, %llu words delivered, %u aux lines skipped\n",
           (unsigned long long)checked, FRAMES, (unsigned long long)clks,
           (unsigned long long)words_delivered, (unsigned)dut->aux_skips);

    int fail = 0;
    auto check = [&](const char *what, bool ok) {
        printf("  %s %s\n", ok ? "ok     " : "FAILED ", what);
        if (!ok) fail = 1;
    };
    check("every pixel came back from both caches as memory has it", wrong == 0);
    check("enough pixels were actually checked to mean something",
          checked > (uint64_t)H_VIS * V_VIS);
    check("no drawing-plane misses after the first frame",
          rmiss[1] == 0 && rmiss[2] == 0 && rmiss[3] == 0);
    check("no auxiliary-plane misses after the first frame",
          amiss[1] == 0 && amiss[2] == 0 && amiss[3] == 0);
    check("the first frame recovered within a few lines",
          rmiss[0] <= (uint64_t)H_VIS * 3 && amiss[0] <= (uint64_t)H_VIS * 3);
    // 6 bursts a line for the drawing planes every frame (6144), plus the
    // 128 marked auxiliary lines (768): about 6912 a frame, never the
    // 12288 that fetching both plane sets everywhere would cost.
    check("unmarked auxiliary lines were never fetched",
          bursts[0] < 7200 && bursts[1] < 7200 && bursts[3] < 7200);
    check("a marked line was fetched again, then dropped again",
          bursts[2] > bursts[3]);

    printf(fail ? "\nFETCHARB: FAIL\n" : "\nFETCHARB: PASS\n");
    delete dut;
    return fail;
}
