//============================================================================
//  tb_newport - newport.sv driven the way the machine drives it: the CPU's
//  32- and 64-bit loads and stores, GO aliases, reads behind a running
//  primitive, and the MC's VDMA beats with the host buffer's start byte in
//  the address. See tb_newport.h for the bus contract and the frame buffer.
//
//  docs/design/rex3-source-audit.md is why. GL draws nothing on the board because of three defects no
//  bench could see - each sits upstream of np_rex3's own register port, or
//  in a register decode no bench wrote: GL's 64-bit register pairs lose
//  their second word (3.1, 4.4), GL's float coordinates keep four exponent
//  bits (4.1), and a write to SETUP does nothing (4.1, 4.2). Reads are not
//  ordered behind the drawing engine and VDMA drops buffers at 4 mod 8
//  (4.4). The tests below state the correct behaviour. They were written
//  against the build 43b RTL, on which 2b, 3a, 3b, 4b, 5d, 5f, 6b, 7a-7d, 8a,
//  8b and 9 failed; those failures defined the fixes of docs/design/rex3-source-audit.md section 5's
//  phase 1, and build 44 passes all of them. Every check is must-pass.
//
//    1  32-bit register writes read back through both word lanes
//    2  XYSTARTI + XYENDI in one 64-bit store with GO
//    3  COLORRED+COLORALPHA, COLORGRN+COLORBLUE as 64-bit stores
//    4  HOSTRW0 + HOSTRW1 in one 64-bit store with GO
//    5  reads behind a running primitive; STATUS must not wait
//    6  VDMA beats with the start byte in nd_addr[2:0]
//    7  GL-format float coordinates, XENDF1
//    8  SETUP (0x0030) without DOSETUP
//    9  display column alignment: VC2, XMAP9 and CMAP programmed over the
//       DCB as the PROM does, markers in the frame buffer, the pins watched:
//       pixel N of the 1280-pixel window is column 8 + N
//
//  Every test starts from a reset and a cleared frame buffer, and a draw
//  check is a whole-frame-buffer difference against a snapshot taken just
//  before the primitive: the rectangle must have changed to the expected
//  values, and nothing else anywhere may have changed.
//
//  Exit status: 0 when every check expected to pass does. A check written
//  ahead of its fix can pass report() an expected-failure reason; with
//  --strict (or NEWPORT_STRICT=1) those failures count too. None is marked.
//
//    make -C verilator newporttest
//    ./obj_dir_newport/Vnewport_test [--fb-lat N] [--strict] [test numbers]
//============================================================================
#include "tb_newport.h"

#include <cctype>
#include <climits>
#include <functional>
#include <map>
#include <set>
#include <utility>

using namespace np;

static Harness *H = nullptr;
static bool     g_hung = false;

//============================================================================
//  Reporting
//============================================================================
static const char *XFAIL_LABEL = "expected to fail on this RTL";

// What the build 43b RTL got wrong, per test group - the defects build 44
// fixed (docs/design/rex3-source-audit.md section 5, phase 1), kept here because a failure of the
// matching check most likely means one of them is back:
//   2b 3a 3b 4b 7c  newport.sv kept the first register of a doubleword store
//                   and dropped the second; its GO fired with the first
//                   (docs/design/rex3-source-audit.md 3.1 + 4.4)
//   5d 5f           np_rex3 answered every read at once, not after the earlier
//                   writes and GOs had taken effect, and merged back-to-back
//                   GOs (4.4)
//   6b              np_rex3 kept bit 2 of the start byte, so the beat decoded
//                   as HOSTRW1 and was acknowledged and dropped (4.4)
//   7a-7d           GL-format coordinates were masked 0x07FFFF80 where the
//                   chip keeps float bits 22:7 (0x007FFF80), and 0x14C was
//                   decoded as an integer XENDI instead of XENDF1 (4.1 + 4.2)
//   8a 8b           a write to SETUP was stored, not run (4.1)
//   9               the display window: display enable from VIS_LN, cropped
//                   to columns 8..1287, and ce_pix and the syncs delayed by
//                   the colour path's three CLOCKS - three ce_pix stages slip
//                   at VC2's table-fetch stalls (3.6 + 4.5)

struct Tally { int pass = 0, fail = 0, xfail = 0, xpass = 0; };
static Tally                    T;
static std::vector<std::string> g_unexpected, g_xpassed;

static void report(const char *id, const std::string &what, bool pass,
                   const char *xfail_why, const std::vector<std::string> &detail)
{
    printf("[%s] %-3s %s\n", pass ? "PASS" : "FAIL", id, what.c_str());
    if (xfail_why) {
        if (pass)
            printf("         (was %s: %s. It passes now - flip the expectation)\n",
                   XFAIL_LABEL, xfail_why);
        else
            printf("         (%s: %s)\n", XFAIL_LABEL, xfail_why);
    }
    for (auto &d : detail) printf("         %s\n", d.c_str());
    if (pass && !xfail_why)       T.pass++;
    else if (pass)                { T.xpass++; g_xpassed.push_back(id); }
    else if (xfail_why)           T.xfail++;
    else                          { T.fail++; g_unexpected.push_back(id); }
    fflush(stdout);
}

//============================================================================
//  Bus shorthands. A transaction that is never acknowledged is reported once
//  and the rest of the test's transactions are skipped - the next test
//  starts from a reset.
//============================================================================
static void hang(const std::string &what)
{
    if (!g_hung)
        printf("         BUS HANG: %s was not acknowledged in %llu clocks\n",
               what.c_str(), (unsigned long long)H->timeout);
    g_hung = true;
}
static void W(uint32_t off, uint32_t v)
{
    if (!g_hung && !H->wr32(off, v))
        hang(strf("32-bit store to %s (0x%04x)", reg_name(off), off));
}
static void W64(uint32_t off, uint64_t v)
{
    if (!g_hung && !H->wr64(off, v))
        hang(strf("64-bit store to %s (0x%04x)", reg_name(off), off));
}
static uint32_t R(uint32_t off)
{
    uint32_t v = 0;
    if (!g_hung && !H->rd32(off, v))
        hang(strf("32-bit load from %s (0x%04x)", reg_name(off), off));
    return v;
}
static bool DMAW(uint32_t off, uint64_t v)
{
    if (g_hung) return false;
    if (!H->dma_wr(off, v)) { hang(strf("VDMA write beat to 0x%04x", off)); return false; }
    return true;
}
// Wait for the engine the way software does (REX3WAIT on USER_STATUS), then
// let np_rex3's own pending/held flags (its dbg_nd port) clear as well. The
// second wait is advisory: a later build may lay dbg_nd out differently, and
// REX3WAIT is the architected answer.
static void settle()
{
    static bool warned = false;
    if (g_hung) return;
    if (!H->rex3wait(2000000)) { hang("REX3WAIT (USER_STATUS never went idle)"); return; }
    if (!H->wait_idle(2000000) && !warned) {
        printf("         note: dbg_nd[3:0] still non-zero 2M clocks after REX3WAIT said idle - "
               "has its layout changed? Carrying on.\n");
        warned = true;
    }
}

static uint32_t XY(int x, int y) { return ((uint32_t)(x & 0xFFFF) << 16) | (uint32_t)(y & 0xFFFF); }
static uint32_t fbits(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
// What GL writes for coordinate x: the raw bits of the float 4096 + x, whose
// mantissa is x in 12.11 fixed point (docs/design/rex3-source-audit.md 4.1).
static uint32_t glc(int x) { return fbits(4096.0f + (float)x); }

// Colour index, 8 bits, the drawing planes, logic op SRC, alpha test off.
static const uint32_t CI8 = DM1_LO_SRC | DM1_COMPARE_OFF | DM1_DEPTH8 | DM1_PLANES_RGB;

// A reset, a clear frame buffer, and the state every test draws in.
static void fresh()
{
    H->reset();
    H->clear_fb();
    g_hung = false;
    W(R_XYWIN,    0x10001000);   // the identity window: coordinates carry a 4096 bias
    W(R_CLIPMODE, 0x00001E00);   // scissors off, CIDMATCH 0xF: every window ID allowed
    W(R_TOPSCAN,  0x000003FF);   // drawing's identity today (np_rex3 fb_row) and after docs/design/rex3-source-audit.md 3.3
    W(R_XYMOVE,   0);
    W(R_WRMASK,   0x00FFFFFF);
    W(R_ZPATTERN, 0xFFFFFFFF);
    W(R_DRAWMODE1, CI8);
    W(R_BRESOCTINC1, 0);         // octant 0: x and y increasing
}

//============================================================================
//  Frame buffer checks
//============================================================================
struct Change { int x, y; uint32_t before, after; };

// Every drawing-plane slot that differs from `before`; auxiliary slots are
// only counted - nothing here draws into them.
static std::vector<Change> changes(const std::vector<uint64_t> &before, int *aux_changed)
{
    std::vector<Change> out;
    int ac = 0;
    for (uint32_t w = 0; w < Harness::FB_WORDS; w++) {
        if (before[w] == H->fb[w]) continue;
        for (int h = 0; h < 2; h++) {
            uint32_t b = (uint32_t)(before[w] >> (32 * h));
            uint32_t a = (uint32_t)(H->fb[w] >> (32 * h));
            if (a == b) continue;
            if (w < Harness::PLANE_WORDS) {
                uint32_t s = (w << 1) | (uint32_t)h;     // y * 2048 + x
                out.push_back({(int)(s & 2047), (int)(s >> 11), b, a});
            } else {
                ac++;
            }
        }
    }
    if (aux_changed) *aux_changed = ac;
    return out;
}

struct DrawResult {
    bool ok = false;
    std::string summary;
    std::vector<std::string> detail;
};

// The drawing planes changed at exactly the pixels of the rectangle, each to
// want(x, y) in its low byte (buffer 0 of an 8-bit colour index).
static DrawResult check_draw(const std::vector<uint64_t> &before, int x0, int y0,
                             int x1, int y1, const std::function<int(int, int)> &want)
{
    DrawResult r;
    int aux = 0;
    auto ch = changes(before, &aux);
    const int w = x1 - x0 + 1, h = y1 - y0 + 1;
    std::vector<char> hit((size_t)w * h, 0);
    int missing = 0, wrong = 0, extra = 0;
    int bx0 = INT_MAX, by0 = INT_MAX, bx1 = INT_MIN, by1 = INT_MIN;
    std::vector<std::string> samples;
    for (auto &c : ch) {
        bx0 = std::min(bx0, c.x); bx1 = std::max(bx1, c.x);
        by0 = std::min(by0, c.y); by1 = std::max(by1, c.y);
        bool in = c.x >= x0 && c.x <= x1 && c.y >= y0 && c.y <= y1;
        if (!in) {
            extra++;
            if (samples.size() < 6)
                samples.push_back(strf("drawn outside: (%d,%d) %08x -> %08x",
                                       c.x, c.y, c.before, c.after));
            continue;
        }
        hit[(size_t)(c.y - y0) * w + (c.x - x0)] = 1;
        if ((int)(c.after & 0xFF) != want(c.x, c.y)) {
            wrong++;
            if (samples.size() < 6)
                samples.push_back(strf("wrong value: (%d,%d) %08x, expected low byte %02x",
                                       c.x, c.y, c.after, want(c.x, c.y)));
        }
    }
    for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++) {
            if (hit[(size_t)(y - y0) * w + (x - x0)]) continue;
            if ((int)(H->slot(x, y, false) & 0xFF) == want(x, y)) continue;
            missing++;
            if (samples.size() < 6)
                samples.push_back(strf("never drawn: (%d,%d) still %08x, expected low byte %02x",
                                       x, y, H->slot(x, y, false), want(x, y)));
        }
    r.ok = !g_hung && missing == 0 && wrong == 0 && extra == 0 && aux == 0;
    r.summary = strf("%d x %d = %d pixels at (%d,%d)-(%d,%d): %d never drawn, %d wrong value, "
                     "%d drawn outside it, %d auxiliary slots changed",
                     w, h, w * h, x0, y0, x1, y1, missing, wrong, extra, aux);
    r.detail.push_back(r.summary);
    if (ch.empty())
        r.detail.push_back("nothing at all changed in the frame buffer");
    else if (!r.ok)
        r.detail.push_back(strf("everything that changed lies in x %d..%d, y %d..%d (%zu slots)",
                                bx0, bx1, by0, by1, ch.size()));
    if (!r.ok)
        for (auto &s : samples) r.detail.push_back(s);
    return r;
}

static std::vector<uint64_t> snap() { return H->fb; }

static void heading(const char *s) { printf("\n-- %s --\n", s); fflush(stdout); }

//============================================================================
//  1. 32-bit register writes read back
//============================================================================
static void t1_registers()
{
    heading("1. 32-bit register writes, read back with 32-bit loads (both word lanes)");
    fresh();
    struct RB { uint32_t reg, want; };
    auto run = [&](const char *id, const std::string &what,
                   std::vector<std::pair<uint32_t, uint32_t>> writes, std::vector<RB> reads) {
        for (auto &w : writes) W(w.first, w.second);
        std::vector<std::string> d;
        bool ok = !g_hung;
        for (auto &r : reads) {
            uint32_t v = R(r.reg);
            if (v != r.want) {
                ok = false;
                d.push_back(strf("%s (0x%04x) read %08x, expected %08x",
                                 reg_name(r.reg), r.reg, v, r.want));
            }
        }
        report(id, what, ok, nullptr, d);
    };

    // np_rex3's header: "write 0x12348765 to xstarti at 0x0148" - the
    // integer registers are views onto the 21.11 coordinate, and XSTART
    // reads it as 16.4(7): the value shifted left by 11 and masked 0x07FFFF80
    // (IRIS's to16_4_7). Writing XSTARTI writes XSAVE too.
    run("1a", "XSTARTI 0x12348765: XSTART reads 0x043B2800, XSTARTI and XSAVE 0x8765",
        {{R_XSTARTI, 0x12348765}},
        {{R_XSTART, 0x043B2800}, {R_XSTARTI, 0x00008765}, {R_XSAVE, 0x00008765}});
    run("1b", "XYSTARTI / XYENDI read back, and as XSTART, YSTART, XEND, YEND",
        {{R_XYSTARTI, 0x01230456}, {R_XYENDI, 0x02340567}},
        {{R_XYSTARTI, 0x01230456}, {R_XSTART, 0x123u << 11}, {R_YSTART, 0x456u << 11},
         {R_XYENDI, 0x02340567}, {R_XEND, 0x234u << 11}, {R_YEND, 0x567u << 11}});
    run("1c", "WRMASK keeps its 24 bits",
        {{R_WRMASK, 0x12345678}}, {{R_WRMASK, 0x00345678}});
    run("1d", "full-width registers in the high and the low word: COLORBACK, COLORVRAM, "
              "ZPATTERN, XYMOVE, SMASK0X, HOSTRW0, HOSTRW1",
        {{R_COLORBACK, 0xDEADBEEF}, {R_COLORVRAM, 0xA5ABCDEF}, {R_ZPATTERN, 0xF0F0A5A5},
         {R_XYMOVE, 0x00050007}, {R_SMASK0X, 0x10201FFF},
         {R_HOSTRW0, 0x11223344}, {R_HOSTRW1, 0x55667788}},
        {{R_COLORBACK, 0xDEADBEEF}, {R_COLORVRAM, 0xA5ABCDEF}, {R_ZPATTERN, 0xF0F0A5A5},
         {R_XYMOVE, 0x00050007}, {R_SMASK0X, 0x10201FFF},
         {R_HOSTRW0, 0x11223344}, {R_HOSTRW1, 0x55667788}});
    W(R_XYMOVE, 0);
    run("1e", "DRAWMODE1 and DRAWMODE0",
        {{R_DRAWMODE1, 0x3000F00A}, {R_DRAWMODE0, 0x00012346}},
        {{R_DRAWMODE1, 0x3000F00A}, {R_DRAWMODE0, 0x00012346}});
    W(R_DRAWMODE1, CI8);
    // The control for test 3: the same four colour registers one at a time.
    run("1f", "COLORRED, COLORALPHA, COLORGRN, COLORBLUE as four 32-bit stores",
        {{R_COLORRED, 0x000A5A5A}, {R_COLORALPHA, 0x000C3C3C},
         {R_COLORGRN, 0x00012345}, {R_COLORBLUE, 0x00067890}},
        {{R_COLORRED, 0x000A5A5A}, {R_COLORALPHA, 0x000C3C3C},
         {R_COLORGRN, 0x00012345}, {R_COLORBLUE, 0x00067890}});
}

//============================================================================
//  2. XYSTARTI + XYENDI in one 64-bit store with GO
//============================================================================
static void t2_xy64()
{
    heading("2. XYSTARTI + XYENDI in one 64-bit store with GO (docs/design/rex3-source-audit.md 4.4, the spec's own example)");
    fresh();
    const uint32_t blk = DM0_DRAW | DM0_BLOCK | DM0_DOSETUP | DM0_STOPONX | DM0_STOPONY;
    W(R_DRAWMODE0, blk);

    W(R_COLORI, 0x5A);
    auto s = snap();
    W(R_XYSTARTI, XY(20, 20));
    W(R_XYENDI | GO, XY(59, 27));
    settle();
    auto r = check_draw(s, 20, 20, 59, 27, [](int, int) { return 0x5A; });
    report("2a", "control: XYSTARTI, then XYENDI|GO, as two 32-bit stores draw the block",
           r.ok, nullptr, r.detail);

    // A stale end point outside the rectangle, so a GO that fires before
    // the second word lands draws somewhere visible.
    W(R_COLORI, 0x3C);
    W(R_XYENDI, XY(90, 45));
    s = snap();
    W64(R_XYSTARTI | GO, ((uint64_t)XY(100, 50) << 32) | XY(139, 57));
    settle();
    r = check_draw(s, 100, 50, 139, 57, [](int, int) { return 0x3C; });
    report("2b", "one 64-bit store to 0x950 = {XYSTARTI, XYENDI} with GO draws XYSTARTI..XYENDI",
           r.ok, nullptr, r.detail);
}

//============================================================================
//  3. COLORRED+COLORALPHA and COLORGRN+COLORBLUE as 64-bit stores
//============================================================================
static void t3_color64()
{
    heading("3. colour register pairs as 64-bit stores (GL's sdc1, docs/design/rex3-source-audit.md 3.1)");
    fresh();
    // Something else in all four first, so a dropped half is visible.
    W(R_COLORRED, 0x00011111); W(R_COLORALPHA, 0x00022222);
    W(R_COLORGRN, 0x00033333); W(R_COLORBLUE, 0x00044444);

    auto pair = [&](const char *id, uint32_t reg, uint32_t hi, uint32_t lo) {
        W64(reg, ((uint64_t)hi << 32) | lo);
        uint32_t a = R(reg), b = R(reg + 4);
        std::vector<std::string> d;
        d.push_back(strf("%s read %08x (expected %08x), %s read %08x (expected %08x)",
                         reg_name(reg), a, hi, reg_name(reg + 4), b, lo));
        report(id, strf("one 64-bit store to 0x%03x = {%s, %s}: both read back with 32-bit loads",
                        reg, reg_name(reg), reg_name(reg + 4)),
               !g_hung && a == hi && b == lo, nullptr, d);
    };
    pair("3a", R_COLORRED, 0x000A5A5A, 0x000C3C3C);
    pair("3b", R_COLORGRN, 0x00012345, 0x00067890);
}

//============================================================================
//  4. HOSTRW0 + HOSTRW1 in one 64-bit store with GO
//============================================================================
static void t4_host64()
{
    heading("4. HOSTRW0 + HOSTRW1 in one 64-bit store with GO (host-data DRAW, RWDOUBLE)");
    fresh();
    // 8-bit host pixels, packed, doubled: a 64-bit host word is eight pixels.
    W(R_DRAWMODE1, CI8 | DM1_RWPACKED | DM1_HD8 | DM1_RWDOUBLE);
    W(R_DRAWMODE0, DM0_DRAW | DM0_BLOCK | DM0_COLORHOST | DM0_STOPONX | DM0_STOPONY);

    W(R_XYSTARTI, XY(620, 230));
    W(R_XYENDI,   XY(627, 230));
    auto s = snap();
    W(R_HOSTRW1, 0x05060708);
    W(R_HOSTRW0 | GO, 0x01020304);
    settle();
    auto r = check_draw(s, 620, 230, 627, 230, [](int x, int) { return 0x01 + (x - 620); });
    report("4a", "control: HOSTRW1, then HOSTRW0|GO, as two 32-bit stores draw all eight pixels",
           r.ok, nullptr, r.detail);

    W(R_XYSTARTI, XY(620, 232));
    W(R_XYENDI,   XY(627, 232));
    W(R_HOSTRW1, 0x5A5A5A5A);          // a stale second word
    s = snap();
    W64(R_HOSTRW0 | GO, 0x1112131415161718ull);
    settle();
    r = check_draw(s, 620, 232, 627, 232, [](int x, int) { return 0x11 + (x - 620); });
    report("4b", "one 64-bit store to HOSTRW0|GO (0xA30): the pixels of both words appear",
           r.ok, nullptr, r.detail);
}

//============================================================================
//  5. Reads behind a running primitive
//============================================================================
static void t5_reads()
{
    heading("5. reads behind a running primitive (docs/design/rex3-source-audit.md 4.4)");
    fresh();
    const uint32_t blk = DM0_DRAW | DM0_BLOCK | DM0_DOSETUP | DM0_STOPONX | DM0_STOPONY;
    const int X0 = 0, Y0 = 700, X1 = 255, Y1 = 763;
    W(R_DRAWMODE0, blk);
    W(R_COLORI, 0x77);

    // The values the fill leaves behind, read after waiting for it.
    W(R_XYSTARTI, XY(X0, Y0));
    W(R_XYENDI | GO, XY(X1, Y1));
    uint64_t t0 = H->cyc;
    settle();
    uint64_t fill_clocks = H->cyc - t0;
    uint32_t xs_settled = R(R_XSTART), ys_settled = R(R_YSTART);

    // The same fill again, in another colour, and the reads straight after
    // its GO. Whether it was still running when a read was answered is told
    // by the frame buffer: its last pixel has or has not changed colour yet.
    struct Q { uint32_t v; uint64_t lat; bool running; };
    auto q = [&](uint32_t reg) {
        Q r;
        r.v = R(reg);
        r.lat = H->last_lat;
        r.running = (H->slot(X1, Y1, false) & 0xFF) != 0x78;
        return r;
    };
    W(R_COLORI, 0x78);
    W(R_XYSTARTI, XY(X0, Y0));
    W(R_XYENDI | GO, XY(X1, Y1));
    Q us = q(R_USERSTATUS), st = q(R_STATUS), cf = q(R_CONFIG);
    Q xs = q(R_XSTART), ys = q(R_YSTART);
    settle();

    auto run_word = [](bool r) { return r ? "still running" : "finished"; };
    const uint64_t LIM = 8;
    report("5a", "USER_STATUS (0x133C) read during a 256 x 64 fill answers at once, GFXBUSY set",
           !g_hung && us.lat <= LIM && (us.v & ST_GFXBUSY) && us.running, nullptr,
           {strf("answered in %llu clocks (limit %llu) with %08x, the fill %s (it takes %llu clocks)",
                 (unsigned long long)us.lat, (unsigned long long)LIM, us.v,
                 run_word(us.running), (unsigned long long)fill_clocks)});
    report("5b", "STATUS (0x1338) read during the fill answers at once, GFXBUSY set",
           !g_hung && st.lat <= LIM && (st.v & ST_GFXBUSY) && st.running, nullptr,
           {strf("answered in %llu clocks with %08x, the fill %s",
                 (unsigned long long)st.lat, st.v, run_word(st.running))});
    report("5c", "CONFIG (0x1330) read during the fill answers at once (docs/design/rex3-source-audit.md: immediate class)",
           !g_hung && cf.lat <= LIM && cf.running, nullptr,
           {strf("answered in %llu clocks with %08x, the fill %s",
                 (unsigned long long)cf.lat, cf.v, run_word(cf.running))});
    report("5d", "XSTART and YSTART read straight after the GO return what the fill leaves behind",
           !g_hung && xs.v == xs_settled && ys.v == ys_settled, nullptr,
           {strf("XSTART read %08x after %llu clocks (the fill %s); after the fill it is %08x",
                 xs.v, (unsigned long long)xs.lat, run_word(xs.running), xs_settled),
            strf("YSTART read %08x after %llu clocks (the fill %s); after the fill it is %08x",
                 ys.v, (unsigned long long)ys.lat, run_word(ys.running), ys_settled)});

    // ---- the PIO read loop: Xsgi's GetImage, IRIS GL's _fb_to_mem32 ---------
    // 32 pixels of 8-bit colour index at (0..31, 900), buffer 0 holding
    // 0x40 + x and decoys in the planes above it; READ packs four to a word,
    // the first pixel in the top byte. One GO per word: read-then-advance, so
    // the first GO read is a primer whose data is thrown away.
    fresh();
    for (int x = 0; x < 32; x++) H->set_slot(x, 900, false, 0x00C3C300u | (uint32_t)(0x40 + x));
    W(R_DRAWMODE1, CI8 | DM1_RWPACKED | DM1_HD8);
    W(R_DRAWMODE0, DM0_READ | DM0_BLOCK | DM0_STOPONX | DM0_STOPONY);
    auto word = [](int k) -> uint32_t {         // k = 1..8
        uint32_t p = 0x40 + 4 * (k - 1);
        return (p << 24) | ((p + 1) << 16) | ((p + 2) << 8) | (p + 3);
    };
    auto loop = [&](bool wait_each, std::vector<std::string> &d) {
        W(R_XYSTARTI, XY(0, 900));
        W(R_XYENDI,   XY(31, 900));
        R(R_HOSTRW0 | GO);                       // the primer
        if (!wait_each && !g_hung && !H->rex3wait(2000000)) hang("REX3WAIT");
        bool ok = !g_hung;
        std::string got = "read:", want = "want:";
        for (int k = 1; k <= 8; k++) {
            if (wait_each && !g_hung && !H->rex3wait(2000000)) hang("REX3WAIT");
            uint32_t v = R(k < 8 ? (R_HOSTRW0 | GO) : R_HOSTRW0);
            got  += strf(" %08x", v);
            want += strf(" %08x", word(k));
            if (v != word(k)) ok = false;
        }
        d.push_back(got);
        d.push_back(want);
        settle();
        return ok && !g_hung;
    };
    std::vector<std::string> de, df;
    bool ok_e = loop(true, de);
    report("5e", "control: PIO read loop with REX3WAIT before every HOSTRW0 read returns the 8 words",
           ok_e, nullptr, de);
    bool ok_f = loop(false, df);
    report("5f", "PIO read loop, one REX3WAIT then back-to-back HOSTRW0|GO reads (Xsgi GetImage), "
                 "returns the 8 words", ok_f, nullptr, df);
}

//============================================================================
//  6. VDMA write beats with the start byte in nd_addr[2:0]
//============================================================================
static void t6_vdma()
{
    heading("6. VDMA write beats with the host buffer's start byte in nd_addr[2:0] (docs/design/rex3-source-audit.md 4.4)");
    fresh();
    W(R_DRAWMODE1, CI8 | DM1_RWPACKED | DM1_HD8 | DM1_RWDOUBLE);
    W(R_DRAWMODE0, DM0_DRAW | DM0_BLOCK | DM0_COLORHOST | DM0_STOPONX | DM0_STOPONY);
    bool ok_lo = true, ok_hi = true;
    std::vector<std::string> d_lo, d_hi;
    for (int k = 0; k < 8; k++) {
        const int y = 200 + 2 * k;
        W(R_XYSTARTI, XY(600, y));
        W(R_XYENDI,   XY(607, y));
        auto s = snap();
        uint64_t beat = 0;
        for (int j = 0; j < 8; j++) beat |= (uint64_t)(0x10 * (k + 1) + j) << (56 - 8 * j);
        uint32_t drops0 = (H->dbg_nd() >> 4) & 0xF;
        uint32_t off = (R_HOSTRW0 | GO) + (uint32_t)k;
        bool acked = DMAW(off, beat);
        settle();
        uint32_t drops1 = (H->dbg_nd() >> 4) & 0xF;
        auto r = check_draw(s, 600, y, 607, y,
                            [k](int x, int) { return 0x10 * (k + 1) + (x - 600); });
        std::string line = strf("start byte %d, nd_addr 0x%05x: %s", k, REX3_BASE + off,
                                !acked ? "NEVER ACKNOWLEDGED" : r.ok ? "all 8 pixels drawn"
                                                                     : r.summary.c_str());
        if (drops1 != drops0) line += " - np_rex3 counted it in nd_drops";
        (k < 4 ? d_lo : d_hi).push_back(line);
        if (!(acked && r.ok)) (k < 4 ? ok_lo : ok_hi) = false;
    }
    report("6a", "VDMA write beats to HOSTRW0|GO with start byte 0..3 are drawn",
           ok_lo && !g_hung, nullptr, d_lo);
    report("6b", "VDMA write beats to HOSTRW0|GO with start byte 4..7 (a buffer at 4 mod 8) "
                 "are drawn, not dropped", ok_hi && !g_hung, nullptr, d_hi);
}

//============================================================================
//  7. GL-format float coordinates
//============================================================================
static void t7_glcoords()
{
    heading("7. GL-format coordinates: the raw bits of the float 4096 + x (docs/design/rex3-source-audit.md 4.1, 4.2)");
    fresh();
    const uint32_t blk = DM0_DRAW | DM0_BLOCK | DM0_DOSETUP | DM0_STOPONX | DM0_STOPONY;
    W(R_DRAWMODE0, blk);

    W(R_COLORI, 0x21);
    auto s = snap();
    W(R_XSTARTF, glc(300));
    W(R_YSTARTF, glc(60));
    W(R_XENDF,   glc(323));
    W(R_YENDF | GO, glc(65));
    settle();
    auto r = check_draw(s, 300, 60, 323, 65, [](int, int) { return 0x21; });
    r.detail.insert(r.detail.begin(), strf("XSTARTF %08x (4396.0f), YSTARTF %08x, XENDF %08x, YENDF|GO %08x",
                                           glc(300), glc(60), glc(323), glc(65)));
    report("7a", "a block from XSTARTF/YSTARTF/XENDF/YENDF|GO (32-bit stores) lands at x, y",
           r.ok, nullptr, r.detail);

    W(R_COLORI, 0x22);
    W(R_XYSTARTI, XY(330, 60));
    W(R_XYENDI,   XY(330, 65));
    s = snap();
    W(R_XENDF1 | GO, glc(353));
    settle();
    r = check_draw(s, 330, 60, 353, 65, [](int, int) { return 0x22; });
    report("7b", "XYSTARTI, XYENDI, then XENDF1|GO (0x94C) as a float: the block ends at XENDF1",
           r.ok, nullptr, r.detail);

    // IRIS GL's polygon span (__subtri): ONE 64-bit store to 0x948, XSTARTI
    // plus XENDF1, with GO.
    W(R_DRAWMODE0, DM0_DRAW | DM0_SPAN | DM0_DOSETUP | DM0_STOPONX);
    W(R_COLORI, 0x23);
    W(R_XYSTARTI, XY(0, 70));
    W(R_XYENDI,   XY(0, 70));
    s = snap();
    W64(R_XSTARTI | GO, ((uint64_t)360 << 32) | glc(391));
    settle();
    r = check_draw(s, 360, 70, 391, 70, [](int, int) { return 0x23; });
    report("7c", "GL's polygon span: one 64-bit store to 0x948 = {XSTARTI 360, XENDF1 391.0} "
                 "with GO draws 360..391", r.ok, nullptr, r.detail);

    // The float registers read back in the 12.4(7) form (IRIS's to12_4_7),
    // and XSTART/XSTARTI see the integer x.
    W(R_XSTARTF, glc(123));
    uint32_t f = R(R_XSTARTF), xs = R(R_XSTART), xi = R(R_XSTARTI);
    const uint32_t want = 123u << 11;
    report("7d", "XSTARTF written as 4219.0f reads back 0x0003D800; XSTART too, XSTARTI 123",
           !g_hung && f == want && xs == want && xi == 123, nullptr,
           {strf("XSTARTF %08x, XSTART %08x, XSTARTI %08x (expected %08x, %08x, %08x)",
                 f, xs, xi, want, want, 123u)});
}

//============================================================================
//  8. SETUP without DOSETUP
//============================================================================
static std::set<std::pair<int, int>> pixels_at(const std::vector<Change> &ch, int ox, int oy)
{
    std::set<std::pair<int, int>> p;
    for (auto &c : ch) p.insert({c.x - ox, c.y - oy});
    return p;
}

static void t8_setup()
{
    heading("8. SETUP (0x0030): the line/span setup without iteration (docs/design/rex3-source-audit.md 4.1, 4.2)");
    fresh();

    // ---- 8a: a block ----------------------------------------------------------
    // The previous primitive runs right to left and bottom to top, and leaves
    // that octant in BRESOCTINC1.
    W(R_COLORI, 0x31);
    W(R_DRAWMODE0, DM0_DRAW | DM0_BLOCK | DM0_DOSETUP | DM0_STOPONX | DM0_STOPONY);
    auto s = snap();
    W(R_XYSTARTI, XY(420, 120));
    W(R_XYENDI | GO, XY(410, 112));
    settle();
    auto pre = check_draw(s, 410, 112, 420, 120, [](int, int) { return 0x31; });
    uint32_t oct_before = R(R_BRESOCTINC1);

    const uint32_t blk = DM0_DRAW | DM0_BLOCK | DM0_STOPONX | DM0_STOPONY;   // no DOSETUP
    W(R_COLORI, 0x32);
    W(R_DRAWMODE0, blk);
    W(R_XYSTARTI, XY(360, 100));
    W(R_XYENDI,   XY(375, 105));
    s = snap();
    W(R_SETUP, 0);                        // GL: sw $zero, 0x30 - and no wait before the GO
    W(R_DRAWMODE0 | GO, blk);
    settle();
    auto r = check_draw(s, 360, 100, 375, 105, [](int, int) { return 0x32; });
    // 16 x 6, x major, x and y increasing: octant field [26:24] = 4. A walk
    // without DOSETUP leaves the field alone, so it can be read afterwards.
    uint32_t oct_after = R(R_BRESOCTINC1);
    bool oct_ok = ((oct_after >> 24) & 7) == 4;
    std::vector<std::string> d;
    d.push_back(strf("the previous block (DOSETUP, (420,120) to (410,112)) %s; it left BRESOCTINC1 %08x",
                     pre.ok ? "drew correctly" : "DID NOT DRAW CORRECTLY", oct_before));
    d.push_back(strf("BRESOCTINC1 after SETUP and the walk %08x: octant %u, expected 4 (x major, x and y increasing)",
                     oct_after, (oct_after >> 24) & 7));
    d.insert(d.end(), r.detail.begin(), r.detail.end());
    report("8a", "BLOCK without DOSETUP: SETUP, then GO walks the octant SETUP derived",
           pre.ok && oct_ok && r.ok, nullptr, d);

    // ---- 8b: a line -----------------------------------------------------------
    // The same line with DOSETUP is the control; the SETUP line must draw
    // exactly its pixels, translated. The line in between leaves an octant
    // with the same major axis and both directions reversed, so the core's
    // own "re-derive when the axes disagree" rule cannot rescue it.
    const uint32_t ln = DM0_DRAW | DM0_ILINE | DM0_STOPONX | DM0_STOPONY;
    W(R_COLORI, 0x41);
    W(R_DRAWMODE0, ln | DM0_DOSETUP);
    s = snap();
    W(R_XYSTARTI, XY(440, 180));
    W(R_XYENDI | GO, XY(470, 195));
    settle();
    int aux = 0;
    auto ctrl = pixels_at(changes(s, &aux), 440, 180);

    W(R_COLORI, 0x42);
    s = snap();
    W(R_XYSTARTI, XY(500, 150));
    W(R_XYENDI | GO, XY(470, 140));
    settle();
    size_t prev_n = changes(s, &aux).size();
    uint32_t oct_prev = R(R_BRESOCTINC1);

    W(R_COLORI, 0x43);
    W(R_DRAWMODE0, ln);
    W(R_XYSTARTI, XY(440, 150));
    W(R_XYENDI,   XY(470, 165));
    s = snap();
    W(R_SETUP, 0);
    W(R_DRAWMODE0 | GO, ln);
    settle();
    uint32_t oct_line = R(R_BRESOCTINC1);
    auto tch = changes(s, &aux);
    auto test = pixels_at(tch, 440, 150);
    int wrongval = 0;
    for (auto &c : tch) if ((c.after & 0xFF) != 0x43) wrongval++;
    size_t common = 0;
    for (auto &p : test) common += ctrl.count(p);
    bool ok = !g_hung && ctrl.size() == 31 && test == ctrl && wrongval == 0 && aux == 0
              && ((oct_line >> 24) & 7) == 4;
    std::vector<std::string> d2;
    d2.push_back(strf("control (DOSETUP) (440,180)-(470,195) drew %zu pixels; the line after it "
                      "(500,150)-(470,140) drew %zu and left BRESOCTINC1 %08x",
                      ctrl.size(), prev_n, oct_prev));
    d2.push_back(strf("BRESOCTINC1 after SETUP and the walk %08x: octant %u, expected 4",
                      oct_line, (oct_line >> 24) & 7));
    d2.push_back(strf("SETUP line (440,150)-(470,165) drew %zu pixels, %zu of them where the "
                      "control's are, %d with the wrong value",
                      test.size(), common, wrongval));
    if (!ok && !tch.empty()) {
        int bx0 = INT_MAX, by0 = INT_MAX, bx1 = INT_MIN, by1 = INT_MIN;
        for (auto &c : tch) {
            bx0 = std::min(bx0, c.x); bx1 = std::max(bx1, c.x);
            by0 = std::min(by0, c.y); by1 = std::max(by1, c.y);
        }
        d2.push_back(strf("what it drew lies in x %d..%d, y %d..%d", bx0, bx1, by0, by1));
    }
    report("8b", "I_LINE without DOSETUP: SETUP, then GO draws the same pixels as the line with DOSETUP",
           ok, nullptr, d2);
}

//============================================================================
//  9. Display column alignment
//============================================================================
// Everything but REX3 hangs off the Display Control Bus, and the display is
// programmed through it exactly as the PROM does it: DCBMODE names the chip
// ([10:7]), the register select ([6:4]) and the width ([1:0], 0 = the whole
// word as one transfer), and a DCBDATA0 store runs the transfer. A byte-wide
// chip takes its bytes from the top of DCBDATA0 (np_rex3.sv's dcb_align).
static uint32_t dcbmode(int chip, int crs, int width)
{
    return (uint32_t)(width & 3) | ((uint32_t)(crs & 7) << 4) | ((uint32_t)(chip & 15) << 7);
}
static void vc2_reg(int idx, uint16_t v)          // VC2: index [28:24], data [23:8]
{
    W(R_DCBMODE, dcbmode(0, 0, 0));
    W(R_DCBDATA0, ((uint32_t)idx << 24) | ((uint32_t)v << 8));
}
static void vc2_ram(uint16_t addr, const std::vector<uint16_t> &words)
{
    vc2_reg(0x07, addr);                           // RAM_ADDR
    W(R_DCBMODE, dcbmode(0, 3, 2));                // CRS 3, the SRAM, 16 bits
    for (uint16_t w : words) W(R_DCBDATA0, (uint32_t)w << 16);
}
// Palette entries from `first` on, both CMAPs (chip 1): the address a byte at
// a time, then red, green, blue as one three-byte transfer each.
static void cmap_load(int first, const std::vector<uint32_t> &rgb)
{
    W(R_DCBMODE, dcbmode(1, 0, 1));
    W(R_DCBDATA0, (uint32_t)(first & 0xFF) << 24);
    W(R_DCBMODE, dcbmode(1, 1, 1));
    W(R_DCBDATA0, (uint32_t)((first >> 8) & 0x1F) << 24);
    W(R_DCBMODE, dcbmode(1, 2, 3));
    for (uint32_t c : rgb) W(R_DCBDATA0, c << 8);  // 0xRRGGBB00
}
static void xmap_mode(int entry, uint32_t mode)  // both XMAP9s (chip 4), CRS 5
{
    W(R_DCBMODE, dcbmode(4, 5, 0));
    W(R_DCBDATA0, ((uint32_t)entry << 24) | (mode & 0xFFFFFF));
}

// A timing table with the shape of np_timing.h's 1280 x 1024 ones: 1680 x
// 1065 pixels a frame; on a visible line VIS_LN (state A bit 0) lasts 1296
// pixels and DSPLY_EN (state A bit 2) starts with it and runs 22 further, to
// 1318 (docs/design/rex3-source-audit.md 3.6, 4.5). Durations are in two-pixel units, the channels
// active low; see tb_vc2.cpp for the format.
static void vc2_load_1280x1024()
{
    auto w0 = [](int dur, int a, bool has_bc, bool eol) {
        return (uint16_t)((eol ? 0x8000 : 0) | ((dur & 0x7F) << 8) | (has_bc ? 0 : 0x80) | (a & 0x7F));
    };
    auto w1 = [](int b, int c, bool eol) {
        return (uint16_t)((eol ? 0x8000 : 0) | ((b & 0x7F) << 8) | 0x80 | (c & 0x7F));
    };
    const int IDLE = 0x7F;
    const int A_VIS = IDLE & ~(1 << 0) & ~(1 << 2);   // VIS_LN and DSPLY_EN
    const int A_EN  = IDLE & ~(1 << 2);                // DSPLY_EN alone
    const int C_HS = IDLE & ~(1 << 2), C_VS = IDLE & ~(1 << 1), C_HSVS = C_HS & ~(1 << 1);
    auto line = [&](bool vis, int c_sync, int c_rest) {
        std::vector<uint16_t> v = {
            w0(12, IDLE, true, false), w1(IDLE, c_rest, false),
            w0(57, IDLE, true, false), w1(IDLE, c_sync, false),
            w0(112, IDLE, true, false), w1(IDLE, c_rest, false)};
        const int runs[6] = {127, 127, 127, 127, 127, 13};   // 648 units: 1296 pixels
        for (int d : runs) v.push_back(w0(d, vis ? A_VIS : IDLE, false, false));
        v.push_back(w0(11, vis ? A_EN : IDLE, true, true));    // 22 more: 1318
        v.push_back(w1(IDLE, c_rest, true));
        return v;
    };
    std::vector<std::vector<uint16_t>> seqs = {
        line(false, C_HS, IDLE), line(false, C_HSVS, C_VS),
        line(false, C_HS, IDLE), line(true, C_HS, IDLE)};
    uint16_t addr = 0;
    std::vector<uint16_t> starts;
    for (auto &s : seqs) {                             // each line points at itself
        starts.push_back(addr);
        auto w = s;
        w.push_back(addr);
        vc2_ram(addr, w);
        addr = (uint16_t)(addr + w.size());
    }
    vc2_ram(0x0400, {starts[0], 2, starts[1], 3, starts[2], 36, starts[3], 1024, 0, 0});
    vc2_reg(0x00, 0x0400);                             // VIDEO_ENTRY: the frame table
    vc2_reg(0x1F, 0x0001);                             // CONFIG: release soft reset
    vc2_reg(0x10, 0x0004);                             // DC_CONTROL: timing on; DID and cursor off
}

static void t9_display()
{
    heading("9. display column alignment: pixel N of a line's display window is frame buffer column 8 + N");
    fresh();
    // Index i shows as red i, so every colour on the pins names its index.
    auto colour = [](int i) -> uint32_t {
        return ((uint32_t)i << 16) | ((uint32_t)((i * 37 + 11) & 0xFF) << 8) | (uint32_t)(0x80 ^ i);
    };
    std::vector<uint32_t> pal(256);
    for (int i = 0; i < 256; i++) pal[i] = colour(i);
    cmap_load(0, pal);
    xmap_mode(0, 0x000400);            // DID 0: 8-bit colour index, buffer 0, CMAP page 0

    // Rows 0-9 are index 0 but for a 40-column tag naming the row (0xA0 + r
    // at columns 480-519, wide enough to find the row whatever the column
    // alignment). Row 5 carries single-pixel markers - either side of the
    // window's edges too - and row 4 marks the columns a previous line's last
    // fetch could come from.
    // Rows 6-9 are a ramp, index = column & 0xFF, so a slip of one column
    // anywhere along the line shows (a slip across a flat background does not).
    const int FIRST = 8, WIDTH = 1280, ROW = 5;
    for (int r = 6; r < 10; r++)
        for (int x = 0; x < 1400; x++) H->set_slot(x, r, false, (uint32_t)(x & 0xFF));
    for (int r = 0; r < 10; r++)
        for (int x = 480; x < 520; x++) H->set_slot(x, r, false, 0xA0u + r);
    const std::pair<int, int> marks[] = {{7, 0x66}, {8, 0x11}, {9, 0x22}, {100, 0x33},
                                         {1287, 0x44}, {1288, 0x77}};
    for (auto &m : marks) H->set_slot(m.first, ROW, false, (uint32_t)m.second);
    H->set_slot(1287, ROW - 1, false, 0x55);
    H->set_slot(1295, ROW - 1, false, 0x56);
    H->set_slot(1317, ROW - 1, false, 0x57);
    auto idx_at = [](int x, int y) { return (int)(H->slot(x, y, false) & 0xFF); };

    vc2_load_1280x1024();
    settle();

    // Watch the pins the way MiSTer's video path does: a pixel is whatever
    // is on them in a clock with ce_pix high. ce_pix is not always high even
    // at PIX_DIV 1 - np_vc2 stops pixel time while it fetches a timing-table
    // word (`vtg_stalled`), which happens at run boundaries inside the window.
    // Each run of the display enable is one line; its row is read off the tag.
    std::map<int, std::vector<uint32_t>> rows;
    std::vector<uint32_t> cur;
    bool in = false;
    uint64_t lines_seen = 0, stalls_in_window = 0;
    const uint64_t limit = H->cyc + 2ull * 1680 * 1065 + 100000;
    while (!g_hung && H->cyc < limit && rows.size() < 9) {
        H->tick();
        if (!H->dut->ce_pix) {
            if (in) stalls_in_window++;
            continue;
        }
        if (H->dut->de) {
            if (!in) { cur.clear(); in = true; }
            cur.push_back(((uint32_t)H->dut->vid_r << 16) | ((uint32_t)H->dut->vid_g << 8)
                          | (uint32_t)H->dut->vid_b);
        } else if (in) {
            in = false;
            lines_seen++;
            size_t probe = 500 - FIRST;
            if (cur.size() > probe) {
                int tag = (int)(cur[probe] >> 16);
                int r = tag - 0xA0;
                if (r >= 1 && r <= 9 && !rows.count(r)) rows[r] = cur;
            }
        }
    }

    std::vector<std::string> d;
    bool ok = !g_hung && rows.size() == 9;
    d.push_back(strf("%llu display-enable lines seen, rows 1-9 found by their tags: %zu; "
                     "%llu clocks inside those windows had ce_pix low (VC2 table fetches)",
                     (unsigned long long)lines_seen, rows.size(),
                     (unsigned long long)stalls_in_window));
    int good_rows = 0, bad_total = 0, bad_right = 0;
    for (auto &kv : rows) {
        const int r = kv.first;
        const auto &px = kv.second;
        int bad = 0, first_bad = -1;
        std::vector<std::string> samples;
        std::string cols;
        for (int n = 0; n < (int)px.size(); n++) {
            int x = FIRST + n;
            uint32_t want = (x < Harness::FB_W) ? colour(idx_at(x, r)) : 0xFFFFFFFFu;
            if (px[n] == want) continue;
            bad++;
            if (bad <= 16) cols += strf(" %d", x);
            if (first_bad < 0) first_bad = n;
            if (r >= 6) {                  // the ramp rows: is it the right-hand neighbour?
                bad_total++;
                if (x + 1 < Harness::FB_W && px[n] == colour(idx_at(x + 1, r))) bad_right++;
            }
            if (samples.size() < 4) {
                // Which nearby column's colour it is showing.
                int g = (int)(px[n] >> 16), from = INT_MIN;
                for (int k = 0; k <= 8 && from == INT_MIN; k++) {
                    if (x - k >= 0 && idx_at(x - k, r) == g) from = x - k;
                    else if (x + k < Harness::FB_W && idx_at(x + k, r) == g) from = x + k;
                }
                samples.push_back(from == INT_MIN
                    ? strf("pixel %d (column %d, index %02x) shows index %02x", n, x, idx_at(x, r), g)
                    : strf("pixel %d (column %d, index %02x) shows column %d's colour (%+d)",
                           n, x, idx_at(x, r), from, from - x));
            }
        }
        if ((int)px.size() == WIDTH && bad == 0) { good_rows++; continue; }
        ok = false;
        std::string s = strf("row %d%s: display window %zu pixels (expected %d); %d not column "
                             "8 + N's colour, the first at pixel %d:", r, r >= 6 ? " (ramp)" : "",
                             px.size(), WIDTH, bad, first_bad);
        for (auto &t : samples) s += " " + t + ";";
        s += " wrong at columns" + cols + (bad > 16 ? " ..." : "");
        d.push_back(s);
    }
    d.push_back(strf("%d of %zu rows show exactly columns 8..1287", good_rows, rows.size()));
    if (bad_total > 0 && bad_total == bad_right && bad_total < 64)
        d.push_back("every wrong ramp pixel shows its right-hand neighbour, in pairs just "
                    "before VC2's table-fetch stalls (ce_pix low): the colour path is timed in "
                    "clocks (answer, slot_rgb, CMAP's registered read) and the sync/de delay in "
                    "ce_pix stages, so a stall slips them apart");
    if (rows.count(ROW)) {
        const auto &px = rows[ROW];
        // Where each of row 5's markers actually landed.
        for (auto &m : marks) {
            std::string at;
            for (int n = 0; n < (int)px.size(); n++)
                if ((int)(px[n] >> 16) == m.second) at += strf(" %d", n);
            int want = m.first - FIRST;
            bool inside = want >= 0 && want < WIDTH;
            d.push_back(strf("row %d column %4d (index %02x): expected at window pixel %s, seen at%s",
                             ROW, m.first, m.second,
                             inside ? strf("%d", want).c_str() : "none (outside the window)",
                             at.empty() ? " none" : at.c_str()));
        }
        if (!px.empty()) {
            int i0 = (int)(px[0] >> 16);
            std::string what = strf("index %02x", i0);
            if (i0 == idx_at(FIRST, ROW)) what += " - its own column 8, as it should be";
            else if (i0 == 0x55 || i0 == 0x56 || i0 == 0x57) what += " - the PREVIOUS line's last fetch";
            else if (i0 == idx_at(FIRST - 1, ROW)) what += " - column 7, one to the left";
            d.push_back(strf("row %d's first window pixel shows %s", ROW, what.c_str()));
        }
    }
    report("9", "display column alignment: every pixel of a line's 1280-pixel display window "
                "is frame buffer column 8 + N, the first one included", ok, nullptr, d);
}

//============================================================================
int main(int argc, char **argv)
{
    int fb_lat = 4;
    bool strict = false;
    std::set<int> only;
    if (const char *e = getenv("NEWPORT_FB_LAT")) fb_lat = atoi(e);
    if (const char *e = getenv("NEWPORT_STRICT")) strict = atoi(e) != 0;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--fb-lat" && i + 1 < argc)       fb_lat = atoi(argv[++i]);
        else if (a == "--strict")                  strict = true;
        else if (a == "-h" || a == "--help") {
            printf("usage: %s [--fb-lat N] [--strict] [test numbers 1-9]\n", argv[0]);
            return 0;
        } else if (a[0] != '+' && isdigit((unsigned char)a[0])) only.insert(atoi(a.c_str()));
    }

    H = new Harness(argc, argv);
    H->fb_lat  = fb_lat;
    H->timeout = 20000000ull;
    printf("newporttest: newport.sv behind the CPU's bus and the MC's VDMA port\n");
    printf("frame buffer random port: %d clock%s a transaction, one at a time\n",
           fb_lat, fb_lat == 1 ? "" : "s");

    struct { int n; void (*fn)(); } tests[] = {
        {1, t1_registers}, {2, t2_xy64}, {3, t3_color64}, {4, t4_host64},
        {5, t5_reads}, {6, t6_vdma}, {7, t7_glcoords}, {8, t8_setup},
        {9, t9_display},
    };
    for (auto &t : tests)
        if (only.empty() || only.count(t.n)) t.fn();

    int total = T.pass + T.fail + T.xfail + T.xpass;
    printf("\n== newporttest: %d checks - %d passed, %d failed", total,
           T.pass + T.xpass, T.fail + T.xfail);
    printf(" (%d of the failures %s, %d unexpected)\n", T.xfail, XFAIL_LABEL, T.fail);
    if (!g_unexpected.empty()) {
        printf("   UNEXPECTED FAILURES:");
        for (auto &s : g_unexpected) printf(" %s", s.c_str());
        printf("\n");
    }
    if (!g_xpassed.empty()) {
        printf("   now passing although %s:", XFAIL_LABEL);
        for (auto &s : g_xpassed) printf(" %s", s.c_str());
        printf("\n");
    }
    printf("   %llu clocks simulated; frame buffer: %llu reads, %llu writes, %llu protocol errors, "
           "%llu out of range\n",
           (unsigned long long)H->cyc, (unsigned long long)H->fbw_reads,
           (unsigned long long)H->fbw_writes, (unsigned long long)H->fbw_proto,
           (unsigned long long)H->fb_oob);
    bool fail = T.fail > 0 || (strict && T.xfail > 0) || H->fbw_proto > 0;
    printf(fail ? "NEWPORTTEST: FAIL%s\n" : "NEWPORTTEST: PASS%s\n",
           strict ? " (strict: expected failures count)"
                  : T.xfail + T.xpass ? " (--strict counts the expected failures too)" : "");
    delete H;
    return fail ? 1 : 0;
}
