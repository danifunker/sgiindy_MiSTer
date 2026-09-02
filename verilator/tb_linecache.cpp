//============================================================================
//  tb_linecache - the scanline cache, against the display's real pattern.
//
//  THE ACCESS PATTERN IS NOT RANDOM AND MUST NOT BE TESTED AS IF IT WERE. The
//  whole design rests on the display never skipping a line, so a test that
//  poked it with random addresses would be testing a cache this is not. What
//  is driven here is exactly what VC2 produces with the timing table the PROM
//  loads - n1280_r3, measured out of a real boot in tests/run-newport.sh:
//
//      1318 visible pixels of a 1680-pixel line
//      1024 visible lines of a 1065-line frame
//
//  including the horizontal blanking between lines, the vertical blanking
//  between frames, and the vsync pulse in the middle of it. A pixel is asked
//  for every PIX_DIV clocks and never waits for an answer, because on this
//  path there is nothing to wait with.
//
//  The memory is deliberately slow: a burst is accepted after a delay, the
//  words come back after another one, and there are gaps in the stream - which
//  is what having four other masters behind the same arbiter looks like.
//
//  WHAT IS CHECKED. Every pixel of every frame after the first is the word
//  that was in memory at that address. Misses are counted and are only
//  tolerated in the first frame, where nothing has been fetched yet. And the
//  cache must not read outside the line it was asked for, which is what would
//  happen if the fill and the display disagreed about which buffer is which.
//
//  AND THE FLAG TABLE, which is built with TRACK_ZERO=1 here (the Makefile
//  passes -G). The memory holds something under ZERO_MASK on one line in
//  eight. Frame 0 must fetch every line - the flags reset to set - and return
//  it verbatim; from frame 1 the empty lines must come back as zeros WITHOUT
//  being fetched (the burst count says whether they were), the others
//  verbatim. Before frame 2 a `mark` names one empty line; that frame must
//  fetch it again and, finding it still empty, drop the flag so frame 3 skips
//  it once more.
//============================================================================

#include "Vfb_linecache.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <deque>
#include <map>
#include <random>

// n1280_r3, the table this machine actually runs.
static const int H_VIS = 1318, H_TOTAL = 1680;
static const int V_VIS = 1024, V_TOTAL = 1065;
static const int V_SYNC_AT = 1030;       // a few lines into the blanking
static const int STRIDE = 2048;          // pixels per frame buffer line
static const int BPP = 4;                // bytes per pixel in one plane set
// CORE CLOCKS PER PIXEL, AND IT MUST MATCH newport.sv's PARAMETER OF THE SAME
// NAME. NOTHING ENFORCES THAT AND IT HAS ALREADY BEEN WRONG ONCE: the RTL went
// to 1 to double the frame rate and this stayed at 2, so the fill engine was
// handed exactly twice the time it had on hardware. The test passed with zero
// misses while a real DE10-Nano missed the first 710 pixels of every line and
// showed a black screen. A model kinder than the hardware is not a test of the
// hardware - it is a reason to trust a design that does not work.
//
// If you change one, change the other, and re-run this. At eight bytes a
// pixel and PIX_DIV=1 this test reported about 1.25 million misses a frame,
// which is what the hardware was doing; at four bytes a pixel it reports none.
static const int PIX_DIV = 1;            // core clocks per pixel
// fb_linecache's ZERO_MASK: the bits of a word the display can see.
static const uint64_t ZERO_MASK = 0x00FFFF0C00FFFF0Cull;

static Vfb_linecache *dut;
static std::mt19937 rng(9876);
static std::map<uint32_t, uint64_t> mem;    // keyed by 8-byte word address

static uint64_t cell(uint32_t byteaddr)
{
    // Distinct per address, and not a function of the offset alone - a cache
    // that served the right column of the wrong line would pass that.
    uint32_t w = byteaddr >> 3;
    return (uint64_t)w * 0x9E3779B97F4A7C15ull ^ 0xA5A5A5A5ull;
}

// Lines that hold something the display can see. Everything else has bits
// only OUTSIDE the mask - not all-zero, so that a cache which fetched them
// anyway would be caught returning them.
static bool line_visible(int y) { return (y % 8) == 0; }

// ---- the mux's burst read port, modelled unhelpfully ----------------------
struct Burst { int delay; uint32_t addr; int left; };
static std::deque<Burst> inflight;
static int accept_delay = 0;
static uint64_t bursts_taken = 0;

// EVERYTHING THE CACHE SEES MUST BE SETTLED BEFORE THE EDGE. Presenting
// `fbr_taken` after it and clearing it before the next one means the RTL never
// sees it at all - which is the same mistake tb_ddr3.cpp made, and it produces
// the same reading: a module that looks completely dead. `fbr_req` is a
// registered output, so its value from the last edge is available now.
static void bridge(void)
{
    dut->fbr_taken = 0;
    dut->fbr_dout_valid = 0;
    dut->fbr_dout = ((uint64_t)rng() << 32) ^ rng();   // garbage unless valid

    // A burst in flight streams its words back, with gaps.
    if (!inflight.empty()) {
        Burst &b = inflight.front();
        if (b.delay > 0) {
            b.delay--;
        } else if ((rng() % 100) < 70) {
            dut->fbr_dout = mem.count(b.addr) ? mem[b.addr] : 0;
            dut->fbr_dout_valid = 1;
            b.addr += 8;
            if (--b.left == 0) inflight.pop_front();
        }
    } else if (dut->fbr_req) {
        // Accept the request being presented, after a variable delay.
        if (accept_delay > 0) accept_delay--;
        else {
            inflight.push_back({4 + (int)(rng() % 12), (uint32_t)dut->fbr_addr,
                                (int)dut->fbr_burst});
            dut->fbr_taken = 1;
            bursts_taken++;
            accept_delay = (int)(rng() % 20);
        }
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
    dut = new Vfb_linecache;

    // A frame buffer's worth of distinct values, one 64-bit word per pair of
    // pixels; lines the display cannot see anything on keep only bits outside
    // the mask.
    for (int y = 0; y < V_VIS; y++)
        for (int x = 0; x < H_VIS; x += 2) {
            uint32_t a = ((uint32_t)y * STRIDE + x) * BPP;
            uint64_t v = cell(a);
            if (!line_visible(y)) v &= ~ZERO_MASK;
            if (v == 0) v = 0xFF000000FF000000ull;     // never all-zero
            mem[a] = v;
        }

    dut->reset = 1; dut->clk = 0;
    dut->px_req = 0; dut->px_addr = 0; dut->vs = 0;
    dut->mark = 0; dut->mark_line = 0;
    dut->fbr_taken = 0; dut->fbr_dout_valid = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    tick();

    const int FRAMES = 4;
    const int MARKED_LINE = 5;               // an empty line, marked before frame 2
    uint64_t checked = 0, wrong = 0, misses[FRAMES] = {0}, bursts[FRAMES] = {0};
    uint64_t shown = 0;
    int frame_now = 0;

    // px_ack lands the cycle AFTER the request, so what is in flight has to be
    // remembered rather than looked at in the same breath. The first version
    // of this file checked it one tick too late and measured nothing at all -
    // zero pixels checked and zero misses, which reads like a pass.
    struct Expect { uint32_t addr; int y; bool visible; int frame; };
    std::deque<Expect> inflight_px;

    auto sample = [&]() {
        if (!dut->px_ack) return;
        if (inflight_px.empty()) { printf("  FAILED ack with nothing asked for\n"); wrong++; return; }
        Expect e = inflight_px.front(); inflight_px.pop_front();
        if (dut->miss) { misses[e.frame]++; return; }
        if (!e.visible) return;
        checked++;
        // Frame 0 fetches everything; afterwards an empty line comes back as
        // zeros, except the marked one in the frame it was marked for.
        uint32_t wa = e.addr & ~7u;
        bool fetched = (e.frame == 0) || line_visible(e.y)
                    || (e.frame == 2 && e.y == MARKED_LINE);
        uint64_t want = fetched ? mem[wa] : 0;
        if (dut->px_rdata != want) {
            wrong++;
            if (shown < 8) {
                printf("  FAILED frame %d line %d addr %08x: want %016llx got %016llx\n",
                       e.frame, e.y, e.addr, (unsigned long long)want,
                       (unsigned long long)dut->px_rdata);
                shown++;
            }
        }
    };

    for (int f = 0; f < FRAMES; f++) {
        frame_now = f;
        uint64_t bursts_before = bursts_taken;
        if (f == 2) {
            // The rasteriser wrote something visible into an empty line.
            dut->mark = 1; dut->mark_line = MARKED_LINE;
            tick(); sample();
            dut->mark = 0;
        }
        for (int y = 0; y < V_TOTAL; y++) {
            dut->vs = (y == V_SYNC_AT || y == V_SYNC_AT + 1 || y == V_SYNC_AT + 2);
            for (int x = 0; x < H_TOTAL; x++) {
                bool visible = (y < V_VIS) && (x < H_VIS);
                uint32_t a = ((uint32_t)y * STRIDE + x) * BPP;

                // px_addr tracks VC2's counters whether or not a pixel is
                // being asked for, which is what newport.sv does.
                dut->px_addr = visible ? a : ((uint32_t)y * STRIDE) * BPP;
                dut->px_req = visible;
                if (visible) inflight_px.push_back({a, y, true, f});
                tick();
                sample();
                dut->px_req = 0;
                for (int k = 1; k < PIX_DIV; k++) { tick(); sample(); }
            }
        }
        bursts[f] = bursts_taken - bursts_before;
        printf("frame %d: %llu misses, %llu bursts\n", f,
               (unsigned long long)misses[f], (unsigned long long)bursts[f]);
    }

    printf("\n%llu pixels checked over %d frames, %llu clocks, %u lines skipped\n",
           (unsigned long long)checked, FRAMES, (unsigned long long)clks,
           (unsigned)dut->dbg_skips);

    int fail = 0;
    auto check = [&](const char *what, bool ok) {
        printf("  %s %s\n", ok ? "ok     " : "FAILED ", what);
        if (!ok) fail = 1;
    };
    check("every pixel came back as the word in memory, or zeros for an empty line", wrong == 0);
    check("enough pixels were actually checked to mean something",
          checked > (uint64_t)H_VIS * V_VIS);
    // The first frame has nothing prefetched, so its first line or two are
    // legitimately black. Every frame after it must be complete.
    check("no misses after the first frame",
          misses[1] == 0 && misses[2] == 0 && misses[3] == 0);
    check("the first frame recovered within a few lines",
          misses[0] <= (uint64_t)H_VIS * 3);
    // Seven lines in eight are empty, so once the flags have settled the
    // fetch traffic must drop to a fraction of frame 0's.
    check("empty lines were not fetched once their flags cleared",
          bursts[1] * 4 < bursts[0] && bursts[3] * 4 < bursts[0]);
    check("a marked line was fetched again, then dropped again",
          bursts[2] > bursts[3]);

    printf(fail ? "\nLINECACHE: FAIL\n" : "\nLINECACHE: PASS\n");
    delete dut;
    return fail;
}
