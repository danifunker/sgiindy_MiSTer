//============================================================================
//  tb_vc2 - a unit test for VC2's video timing generator.
//
//  The generator is an interpreter for a program held in VC2's external SRAM,
//  and a boot is a terrible way to test an interpreter: the program comes from
//  the PROM through REX3's Display Control Bus, so a wrong picture could be the
//  walk, the bus, or the table never having arrived. This drives np_vc2's DCB
//  port directly with a table this file writes itself, of a geometry it picked,
//  and then measures what comes out of the timing pins.
//
//  THE TABLE IS SYNTHETIC ON PURPOSE. np_timing.h's real tables are SGI source
//  and are not copied into this repository; a made-up 100 x 12 frame exercises
//  every rule of the format - the frame table's line-sequence runs, the
//  terminating zero count, one- and two-word state runs, state B and C
//  carrying over, and the end-of-line pointer - which is what the test is for.
//  tests/run-newport.sh is what checks the real tables, on the real PROM.
//
//  Format, from vc2.pdf 3.4.1:
//    frame table: (line-sequence pointer, line count) pairs, zero count ends
//    line: state runs, then a pointer to the next line of the sequence
//    run word 0: [15] end of line, [14:8] duration in 2-pixel clocks,
//                [7] state B/C absent, [6:0] state A
//    run word 1: [15] end of line, [14:8] state B, [7] 1, [6:0] state C
//============================================================================

#include "Vnp_vc2.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

// Active-low channel positions, from vc2.pdf's pin list.
static const int A_DSPLY_EN = 2;   // state A bit 2
static const int C_VSYNC    = 1;   // state C bit 1
static const int C_HSYNC    = 2;   // state C bit 2

// The geometry this test asks for.
// Shaped like np_timing.h's real tables rather than like the simplest thing
// that parses. Three details there are load-bearing and a toy table misses all
// three: the visible span is longer than a duration field can hold, so it is
// several runs that carry state B and C over from the one before; the last run
// of a line is an end-of-line run that DOES carry a B/C word; and the visible
// lines are one frame-table entry with a count in the hundreds rather than a
// handful of lines.
static const int H_FRONT = 12, H_SYNC = 57, H_BACK = 40;   // 2-pixel units
static const int H_VIS_RUNS = 5;                           // visible span, in runs
static const int H_VIS_DUR  = 127;                         // duration of each
static const int H_VIS = H_VIS_RUNS * H_VIS_DUR;
static const int V_FRONT = 2, V_SYNC = 3, V_BACK = 36, V_VIS = 300; // lines
static const int H_TOTAL = H_FRONT + H_SYNC + H_BACK + H_VIS;
static const int V_TOTAL = V_FRONT + V_SYNC + V_BACK + V_VIS;

static const uint16_t VC2_RAM_ADDR_REG = 0x07;
static const uint16_t VC2_VIDEO_ENTRY  = 0x00;
static const uint16_t VC2_CURSOR_ENTRY = 0x01;
static const uint16_t VC2_CURSOR_X     = 0x02;
static const uint16_t VC2_CURSOR_Y     = 0x03;
static const uint16_t VC2_DC_CONTROL   = 0x10;
static const uint16_t VC2_CONFIG       = 0x1F;

static Vnp_vc2 *dut;
static uint64_t clk_count = 0;

static void tick()
{
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
    clk_count++;
}

// A 32-bit DCB write through CRS 0: index in [28:24], data in [23:8]. This is
// how vc2SetReg does it in one bus cycle.
static void set_reg(uint8_t idx, uint16_t val)
{
    dut->sel = 1; dut->we = 1; dut->crs = 0; dut->width = 0;
    dut->wdata = ((uint32_t)idx << 24) | ((uint32_t)val << 8);
    tick();
    dut->sel = 0;
    tick();
}

// A 16-bit DCB write through CRS 3 puts one word into the SRAM at RAM_ADDR and
// advances it, which is what vc2SetRam does.
static void set_ram(uint16_t val)
{
    dut->sel = 1; dut->we = 1; dut->crs = 3; dut->width = 2;
    dut->wdata = val;
    tick();
    dut->sel = 0;
    tick();
}

static void load_ram(uint16_t addr, const std::vector<uint16_t> &data)
{
    set_reg(VC2_RAM_ADDR_REG, addr);
    for (uint16_t w : data) set_ram(w);
}

// state A / B / C, all channels idle high except the ones named.
static uint16_t run_w0(int dur, int state_a, bool has_bc, bool eol)
{
    return (uint16_t)((eol ? 0x8000 : 0) | ((dur & 0x7F) << 8) |
                      (has_bc ? 0 : 0x80) | (state_a & 0x7F));
}
static uint16_t run_w1(int state_b, int state_c, bool eol)
{
    return (uint16_t)((eol ? 0x8000 : 0) | ((state_b & 0x7F) << 8) | 0x80 |
                      (state_c & 0x7F));
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    dut = new Vnp_vc2;

    dut->reset = 1; dut->clk = 0; dut->sel = 0; dut->we = 0;
    dut->crs = 0; dut->width = 0; dut->wdata = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    tick();

    // Every channel high (inactive) except where a run names one.
    const int A_IDLE = 0x7F, B_IDLE = 0x7F, C_IDLE = 0x7F;
    const int A_VIS  = A_IDLE & ~(1 << A_DSPLY_EN);
    const int C_HS   = C_IDLE & ~(1 << C_HSYNC);
    const int C_VS   = C_IDLE & ~(1 << C_VSYNC);
    const int C_HSVS = C_HS   & ~(1 << C_VSYNC);

    // Three kinds of line. A duration field of n lasts exactly n ticks - see
    // the header of np_vc2.sv for the measurement that settles that - so the
    // durations written here are the counts asked for.
    // A blank line is the same length as a visible one - every line of a
    // raster has to be, and a duration field only holds 127, so the span that
    // would be visible is the same several runs with the display enable left
    // inactive.
    auto blank_line = [&](int c_sync, int c_rest) {
        std::vector<uint16_t> v{
            run_w0(H_FRONT, A_IDLE, true,  false), run_w1(B_IDLE, c_rest, false),
            run_w0(H_SYNC,  A_IDLE, true,  false), run_w1(B_IDLE, c_sync, false),
            run_w0(H_BACK,  A_IDLE, true,  false), run_w1(B_IDLE, c_rest, false),
        };
        for (int i = 0; i < H_VIS_RUNS; i++) {
            bool last = (i == H_VIS_RUNS - 1);
            v.push_back(run_w0(H_VIS_DUR, A_IDLE, last, last));
            if (last) v.push_back(run_w1(B_IDLE, c_rest, true));
        }
        return v;
    };
    // The visible span is longer than a seven-bit duration, so it is several
    // runs. All but the first leave state B and C to carry over, which is the
    // case the format's "B/C absent" flag exists for, and the last one is the
    // end-of-line run and carries a B/C word of its own - which is what every
    // line in np_timing.h does.
    std::vector<uint16_t> vis_line = {
        run_w0(H_FRONT, A_IDLE, true,  false), run_w1(B_IDLE, C_IDLE, false),
        run_w0(H_SYNC,  A_IDLE, true,  false), run_w1(B_IDLE, C_HS,   false),
        run_w0(H_BACK,  A_IDLE, true,  false), run_w1(B_IDLE, C_IDLE, false),
    };
    for (int i = 0; i < H_VIS_RUNS; i++) {
        bool last = (i == H_VIS_RUNS - 1);
        vis_line.push_back(run_w0(H_VIS_DUR, A_VIS, last, last));
        if (last) vis_line.push_back(run_w1(B_IDLE, C_IDLE, true));
    }

    std::vector<uint16_t> front = blank_line(C_HS,   C_IDLE);
    std::vector<uint16_t> sync  = blank_line(C_HSVS, C_VS);
    std::vector<uint16_t> back  = blank_line(C_HS,   C_IDLE);

    // Four line sequences, each a line followed by a pointer to itself.
    uint16_t a_front = 0x0000;
    uint16_t a_sync  = a_front + (uint16_t)front.size() + 1;
    uint16_t a_back  = a_sync  + (uint16_t)sync.size()  + 1;
    uint16_t a_vis   = a_back  + (uint16_t)back.size()  + 1;
    uint16_t a_ftab  = 0x0400;

    auto with_next = [](std::vector<uint16_t> v, uint16_t self) {
        v.push_back(self); return v;
    };
    load_ram(a_front, with_next(front, a_front));
    load_ram(a_sync,  with_next(sync,  a_sync));
    load_ram(a_back,  with_next(back,  a_back));
    load_ram(a_vis,   with_next(vis_line, a_vis));

    load_ram(a_ftab, {a_front, V_FRONT, a_sync, V_SYNC,
                      a_back,  V_BACK,  a_vis,  V_VIS, 0, 0});

    // ---- the cursor ------------------------------------------------------
    // A solid 32x32 block in plane 0 and nothing in plane 1, so every pixel it
    // covers reads as value 1 and the shape is trivially checkable. Plane 1
    // lives sixty-four words after plane 0 whatever the row - that offset is
    // the part of the format most likely to be got wrong, so leaving it empty
    // and asserting the value is 1 rather than 3 is a test of it.
    const uint16_t CURS_AT = 0x2000;
    const int CURS_X = 100, CURS_Y = 40, CURS_SZ = 32, MARK_ROW = 7;
    {
        std::vector<uint16_t> plane0(CURS_SZ * 2, 0xFFFF);
        std::vector<uint16_t> plane1(CURS_SZ * 2, 0x0000);
        // ONE MARKED ROW, so that a row offset shows up wherever it happens.
        // A solid glyph hides one completely: every row looks like every other
        // and only the last one, reading off the end of the plane, goes blank.
        // With plane 1 set on exactly one row, that row reads 3 and the rest
        // read 1, and an off-by-one moves the mark.
        plane1[MARK_ROW * 2] = 0xFFFF;
        plane1[MARK_ROW * 2 + 1] = 0xFFFF;
        load_ram(CURS_AT, plane0);
        load_ram(CURS_AT + 64, plane1);
    }
    // The registers hold the hot spot plus 31, and CURSOR_X is latched into the
    // working copy by the write to CURSOR_Y - so the order of these two
    // matters and getting it backwards leaves the cursor at x = -31.
    set_reg(VC2_CURSOR_ENTRY, CURS_AT);
    set_reg(VC2_CURSOR_X, CURS_X + 31);
    set_reg(VC2_CURSOR_Y, CURS_Y + 31);

    // ---- the DID table ---------------------------------------------------
    // The per-window display-ID mechanism, exactly the shape IRIS's
    // decode_did walks: a per-line pointer table, each line a run list of
    // {x[10:0], did[4:0]} entries, 0x7FF ending a line and a line pointer of
    // 0xFFFF ending the table for the rest of the frame. The lines exercise
    // the corners: a ONE-PIXEL run (x=100 then x=101, the immediate-apply
    // path in the walker's lookahead), a mid-line switch, a single-run line,
    // and the table-end mark.
    const uint16_t DID_TAB = 0x3000, LIST_A = 0x3400, LIST_B = 0x3410,
                   LIST_C  = 0x3420;
    const uint16_t VC2_DID_ENTRY = 0x05;
    auto de_entry = [](int x, int d) {
        return (uint16_t)(((x & 0x7FF) << 5) | (d & 0x1F));
    };
    {
        std::vector<uint16_t> tab;
        for (int y = 0; y < V_VIS; y++)
            tab.push_back(y < 100 ? LIST_A : y < 200 ? LIST_B
                        : y < 250 ? LIST_C : 0xFFFF);
        load_ram(DID_TAB, tab);
        load_ram(LIST_A, {de_entry(0, 1), de_entry(100, 2), de_entry(101, 3),
                          de_entry(500, 4), de_entry(0x7FF, 0)});
        load_ram(LIST_B, {de_entry(0, 5), de_entry(0x7FF, 0)});
        load_ram(LIST_C, {de_entry(0, 6), de_entry(300, 7), de_entry(0x7FF, 0)});
    }
    set_reg(VC2_DID_ENTRY, DID_TAB);

    // The reference: IRIS's decode_did, transcribed. Fills the DID every
    // displayed pixel must carry.
    auto ref_did = [&](int y, int x) -> int {
        if (y >= 250) return 0;                    // past the 0xFFFF mark
        struct Run { int x, d; };
        std::vector<Run> runs;
        if (y < 100)      runs = {{100, 1}, {101, 2}, {500, 3}, {1 << 20, 4}};
        else if (y < 200) runs = {{1 << 20, 5}};
        else              runs = {{300, 6}, {1 << 20, 7}};
        for (auto &r : runs) if (x < r.x) return r.d;
        return 0;
    };

    set_reg(VC2_VIDEO_ENTRY, a_ftab);
    set_reg(VC2_CONFIG, 0x0001);          // release soft reset
    // Video timing enable, the cursor on at 32x32 (bit 7; bit 9 would be
    // 64x64), and the DID table walker on (bit 3).
    set_reg(VC2_DC_CONTROL, 0x0004 | 0x0080 | 0x0008);

    // Run for four frames' worth of pixel clocks plus slack.
    const int PIX_DIV = 2;
    uint64_t budget = (uint64_t)H_TOTAL * 2 * V_TOTAL * PIX_DIV * 6;

    bool hs_d = false, vs_d = false, de_d = false;
    uint64_t hsyncs = 0, vsyncs = 0, de_rises = 0;
    int  x = 0, y = 0;
    int  seen_w = 0, seen_h = 0, frames = 0;
    int  hs_width = 0, hs_run = 0, hs_width_seen = 0;
    // Where the cursor was seen, and with what value. Sampled on the last
    // frame only, so the first frame's start-up has no say in it.
    uint64_t curs_pixels = 0, curs_wrong_value = 0, curs_outside = 0;
    uint64_t did_pixels = 0, did_wrong = 0;
    int curs_x_min = 1 << 20, curs_x_max = -1;
    int curs_y_min = 1 << 20, curs_y_max = -1;
    uint64_t curs_row_hits[40] = {0};

    for (uint64_t i = 0; i < budget; i++) {
        tick();
        bool hs = dut->hsync, vs = dut->vsync, de = dut->de, ce = dut->ce_pix;

        if (hs && !hs_d) { hsyncs++; if (y < 4096) y++; x = 0; hs_run = 0; }
        if (vs && !vs_d) { vsyncs++; if (frames) { seen_h = y; } frames++; y = 0; }
        if (de && !de_d) de_rises++;
        if (ce && hs)    hs_run++;
        if (!hs && hs_d) { hs_width = hs_run; if (hs_width) hs_width_seen = hs_width; }
        if (ce && de)    { x++; if (x > seen_w) seen_w = x; }
        // THE CURSOR IS SAMPLED AGAINST VC2'S OWN COORDINATES, not the
        // testbench's x/y - those count emitted pixels and the cursor is
        // placed in frame buffer coordinates, which is what pix_x/pix_y are.
        // The DID is sampled the same way the cursor is: against VC2's own
        // coordinates, on settled frames only.
        if (ce && de && frames >= 2) {
            int want_did = ref_did(dut->pix_y, dut->pix_x);
            did_pixels++;
            if (dut->did != want_did) {
                did_wrong++;
                if (did_wrong <= 5)
                    printf("     did mismatch at (%d,%d): got %d want %d\n",
                           (int)dut->pix_x, (int)dut->pix_y,
                           (int)dut->did, want_did);
            }
        }
        if (ce && de && frames >= 2 && dut->cursor_pix) {
            int px = dut->pix_x, py = dut->pix_y;
            curs_pixels++;
            int want = (py - CURS_Y == MARK_ROW) ? 3 : 1;
            if (dut->cursor_pix != want) curs_wrong_value++;
            if (px < CURS_X || px >= CURS_X + CURS_SZ ||
                py < CURS_Y || py >= CURS_Y + CURS_SZ) curs_outside++;
            if (px < curs_x_min) curs_x_min = px;
            if (px > curs_x_max) curs_x_max = px;
            if (py < curs_y_min) curs_y_min = py;
            if (py > curs_y_max) curs_y_max = py;
            { int r = py - CURS_Y; if (r >= 0 && r < 40) curs_row_hits[r]++; }
        }
        hs_d = hs; vs_d = vs; de_d = de;
    }

    int want_lines  = V_TOTAL;
    int want_w      = H_VIS * 2;
    int want_hswide = H_SYNC * 2;
    printf("vc2: %d frames, %d lines per frame, %d visible pixels per line, "
           "hsync %d pixels\n", frames, seen_h, seen_w, hs_width_seen);
    printf("     want %d lines, %d visible pixels, hsync %d pixels\n",
           want_lines, want_w, want_hswide);
    printf("     edges: %llu hsync, %llu vsync, %llu display-enable\n",
           (unsigned long long)hsyncs, (unsigned long long)vsyncs,
           (unsigned long long)de_rises);

    int fail = 0;
    auto check = [&](const char *what, bool ok) {
        printf("  %s %s\n", ok ? "ok     " : "FAILED ", what);
        if (!ok) fail = 1;
    };
    check("at least two complete frames", frames >= 2);
    check("the frame has the line count the table describes",
          seen_h == want_lines);
    check("each line has the visible width the table describes",
          seen_w == want_w);
    check("the sync pulse is the width the table describes",
          hs_width_seen == want_hswide);
    check("one display-enable pulse per visible line",
          de_rises >= (uint64_t)V_VIS * (uint64_t)(frames - 1) && de_rises > 0);

    printf("     cursor: %llu pixels, x %d..%d, y %d..%d (want %d..%d, %d..%d)\n",
           (unsigned long long)curs_pixels, curs_x_min, curs_x_max,
           curs_y_min, curs_y_max, CURS_X, CURS_X + CURS_SZ - 1,
           CURS_Y, CURS_Y + CURS_SZ - 1);
    if (getenv("VC2_CURSOR_ROWS")) {
        printf("     per-row pixel counts:\n");
        for (int r = 0; r < 34; r++)
            printf("       row %2d: %llu\n", r,
                   (unsigned long long)curs_row_hits[r]);
    }
    check("the cursor is drawn at all", curs_pixels > 0);
    check("every cursor pixel is inside the square it was placed at",
          curs_outside == 0);
    check("the cursor lands exactly where it was put",
          curs_x_min == CURS_X && curs_x_max == CURS_X + CURS_SZ - 1 &&
          curs_y_min == CURS_Y && curs_y_max == CURS_Y + CURS_SZ - 1);
    // A solid plane 0 over an empty plane 1 is value 1 everywhere. Value 3
    // would mean the second plane was read from the wrong place - the
    // sixty-four word offset is the easiest part of the format to get wrong.
    check("the marked row reads 3 and every other reads 1, so plane 1 is "
          "where the format says and no row is offset",
          curs_wrong_value == 0);

    printf("     did: %llu pixels sampled, %llu wrong\n",
           (unsigned long long)did_pixels, (unsigned long long)did_wrong);
    check("every displayed pixel carries the DID its table run says",
          did_pixels > 0 && did_wrong == 0);

    printf(fail ? "VC2: FAIL\n" : "VC2: PASS\n");
    delete dut;
    return fail;
}
