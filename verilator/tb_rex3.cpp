//============================================================================
//  tb_rex3 - does the rasteriser lose writes when memory is slow?
//
//  THIS EXISTS BECAUSE HARDWARE DREW NOTHING AND NOTHING IN THE REPOSITORY
//  COULD HAVE SEEN WHY. tests/run-rex3.sh is the strong test of what REX3
//  draws - every command replayed against every pixel - but it needs a whole
//  machine, and the machine's memory answers in one cycle. Against DDR3 it
//  does not, and the difference is the whole of this file.
//
//  DR_FILL, the opaque-fill fast path, asserts a write EVERY CYCLE and counts
//  what it has asserted in a four-bit `wr_outstanding`, then DR_DRAIN waits
//  for that count to reach zero. Against a memory that accepts one write per
//  cycle every count is matched by an acknowledgement and the shape is
//  correct. Against rtl/mister/ddr3_mux.sv, which holds ONE transaction at a
//  time and takes tens of cycles over it, the requests REX3 asserts while a
//  transaction is already in flight are never latched by anybody - so the
//  pixels are never written, the count never comes back down, and DR_DRAIN
//  waits for ever.
//
//  So the test is: draw a filled rectangle, and check that every pixel of it
//  reached memory. ACK_DELAY is the knob. At 1 this passes on the broken RTL,
//  which is exactly why a whole machine full of one-cycle memory never caught
//  it; at anything realistic it does not.
//============================================================================

#include "Vnp_rex3.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <map>
#include <set>

static Vnp_rex3 *dut;
static uint64_t  clks = 0;
static int       failures = 0;

// ---- the frame buffer, and a bridge as unhelpful as the real one ----------
// One transaction at a time, ACK_DELAY cycles over it. That is the DDR3 mux's
// actual contract and it is the only thing this test changes about the world.
static std::map<uint32_t, uint64_t> fb;
static std::set<uint32_t>           written;
static int      ack_delay = 1;
static int      busy_left = 0;
static uint32_t busy_addr = 0;
static uint64_t busy_data = 0;
static bool     busy_is_write = false;
static uint8_t  busy_be = 0;
static uint64_t accepted = 0, presented = 0;
// Every distinct address REX3 ever asserted a write to. The difference between
// this and `written` is the set of pixels it believes it drew and did not.
static std::set<uint32_t> intended;
// Every byte that actually landed, as (word address << 3) | byte lane k, where
// lane k is bits [8k+7:8k] - the shape the port's byte enables use.
static std::set<uint64_t> written_bytes;

// THE FRAME BUFFER LAYOUT (np_rex3.sv): four bytes a pixel per plane set, a
// 32-bit slot per pixel, two to a 64-bit word with the EVEN pixel in the low
// half; the auxiliary planes sit 8 MB above the drawing planes. `fb` is keyed
// by the 8-byte word address; REX3 presents the slot's own byte address and
// picks its half with the byte enables.
static uint32_t slot_addr(int x, int y, bool aux)
{
    return (aux ? 0x00800000u : 0u) + (((((uint32_t)y) << 11) + (uint32_t)x) << 2);
}
static uint32_t word_addr(uint32_t a) { return a & ~7u; }
static uint32_t slot_val(int x, int y, bool aux)
{
    uint32_t w = word_addr(slot_addr(x, y, aux));
    uint64_t v = fb.count(w) ? fb[w] : 0;
    return (x & 1) ? (uint32_t)(v >> 32) : (uint32_t)v;
}
static void set_slot(int x, int y, bool aux, uint32_t s)
{
    uint32_t w = word_addr(slot_addr(x, y, aux));
    uint64_t v = fb.count(w) ? fb[w] : 0;
    if (x & 1) v = (v & 0x00000000FFFFFFFFull) | ((uint64_t)s << 32);
    else       v = (v & 0xFFFFFFFF00000000ull) | (uint64_t)s;
    fb[w] = v;
}
// The pixel's colour index byte reached memory: lane 0 of the even pixel's
// slot, lane 4 of the odd one's.
static bool pix_written(int x, int y)
{
    uint32_t w = word_addr(slot_addr(x, y, false));
    return written_bytes.count(((uint64_t)w << 3) | (uint64_t)((x & 1) ? 4 : 0)) != 0;
}
static uint8_t pix_index(int x, int y) { return (uint8_t)(slot_val(x, y, false) & 0xFF); }

static void bridge_before_edge()
{
    dut->fb_ack   = 0;
    dut->fb_rdata = 0xDEADBEEFCAFEF00DULL;      // garbage unless acked

    if (dut->fb_req && dut->fb_we) intended.insert(dut->fb_addr);

    auto commit = [&]() {
        uint32_t wa = word_addr(busy_addr);
        if (busy_is_write) {
            uint64_t old = fb.count(wa) ? fb[wa] : 0;
            uint64_t val = 0;
            for (int i = 0; i < 8; i++) {
                int shift = 56 - 8 * i;              // byte 0 is the top one
                bool en = (busy_be >> (7 - i)) & 1;
                uint64_t by = en ? ((busy_data >> shift) & 0xFF)
                                 : ((old       >> shift) & 0xFF);
                val |= by << shift;
                if (en) written_bytes.insert(((uint64_t)wa << 3) | (uint64_t)(7 - i));
            }
            fb[wa] = val;
            written.insert(busy_addr);
        } else {
            dut->fb_rdata = fb.count(wa) ? fb[wa] : 0;
        }
        dut->fb_ack = 1;
        accepted++;
    };

    if (busy_left > 0) {
        if (--busy_left == 0) commit();
        return;
    }

    if (dut->fb_req) {
        presented++;
        busy_addr     = dut->fb_addr;
        busy_data     = dut->fb_wdata;
        busy_be       = dut->fb_be;
        busy_is_write = dut->fb_we;
        // ACK_DELAY 0 IS THE MEMORY EVERY OTHER TEST IN THIS TREE USES: accept
        // and acknowledge within the same cycle, so a master can start a new
        // transaction on every clock and nothing is ever refused. It is what
        // sim_top's frame buffer does, and it is not what DDR3 does.
        if (ack_delay == 0) commit();
        else                busy_left = ack_delay;
    }
}

static void tick()
{
    bridge_before_edge();
    dut->eval();
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
    clks++;
}

// ---- the register bus -----------------------------------------------------
static void wr(uint32_t off, uint32_t val)
{
    dut->sel = 1; dut->we = 1; dut->off = off; dut->wdata = val; dut->be = 0xF;
    tick();
    dut->sel = 0; dut->we = 0;
    tick();
}

// Register offsets, from np_rex3.sv.
enum {
    R_DRAWMODE1 = 0x0000, R_DRAWMODE0 = 0x0004, R_ZPATTERN = 0x0014,
    R_XSTARTI   = 0x0148, R_XENDI     = 0x014C,
    R_XYSTARTI  = 0x0150, R_XYENDI    = 0x0154,
    R_WRMASK    = 0x0220, R_COLORI    = 0x0224,
    R_TOPSCAN   = 0x1320, R_XYWIN     = 0x1324, R_CLIPMODE = 0x1328,
};
static const uint32_t GO = 0x800;

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    ack_delay = 8;
    if (const char *e = getenv("REX3_ACK_DELAY")) ack_delay = atoi(e);
    dut = new Vnp_rex3;

    dut->reset = 1; dut->clk = 0;
    dut->sel = 0; dut->we = 0; dut->off = 0; dut->wdata = 0; dut->be = 0;
    dut->fb_ack = 0; dut->fb_rdata = 0; dut->vert_int = 0; dut->dcb_rdata = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    tick();

    // A filled rectangle, which is what a screen clear and every box the boot
    // screen draws actually is. OP_DRAW, block address mode, stop on both
    // axes - the shape that reaches DR_FILL.
    // 32 wide because the engine walks a span of 32 at a time; wider is a
    // rasteriser question and tests/run-rex3.sh is where that belongs. This
    // test is about back-pressure and nothing else.
    const int X0 = 4, Y0 = 2, X1 = 35, Y1 = 9;
    const int W = X1 - X0 + 1, H = Y1 - Y0 + 1;

    // THE IDENTITY WINDOW IS 0x10001000, NOT ZERO. Coordinates carry a 4096
    // bias that is subtracted when one becomes an address, so a window of zero
    // puts every column at x - 4096, off the left of the frame buffer, where
    // clipping drops it and the engine draws nothing at all - which is what
    // the first run of this test measured.
    wr(R_XYWIN,     0x10001000);
    wr(R_CLIPMODE,  0x00000000);       // clipping off
    // fb_row is (y + win_y - 4096 - topscan - 1) mod FB_LINES, so 1023 makes
    // it the identity: y - 1024, and 1024 is the number of lines.
    wr(R_TOPSCAN,   0x000003FF);
    wr(R_WRMASK,    0x00FFFFFF);       // all drawing planes writable
    wr(R_COLORI,    0x0000005A);       // an index nothing else would produce
    wr(R_ZPATTERN,  0xFFFFFFFF);
    // planes 0 (the DRAWING planes - 4 and 5 are the auxiliary ones, and
    // picking those sends every write into the top half of the word where the
    // display never looks), drawdepth 1 (8 bits), compare 7 (disabled),
    // logicop 3 = SRC, which is at [31:28] and not next to the depth fields.
    wr(R_DRAWMODE1, (3u << 28) | (7u << 12) | (1u << 3) | 0u);
    // opcode 2 (DRAW) | adrmode 1 (block) << 2 | stoponx << 8 | stopony << 9
    wr(R_DRAWMODE0, 2 | (1u << 2) | (1u << 8) | (1u << 9));
    wr(R_XYSTARTI,  ((uint32_t)X0 << 16) | (uint32_t)Y0);
    wr(R_XYENDI | GO, ((uint32_t)X1 << 16) | (uint32_t)Y1);

    // Let it run. A rectangle this size is a few hundred pixels; give it far
    // more than it can need, then see whether it ever finished.
    const uint64_t BUDGET = 400000;
    uint64_t start = clks;
    while (clks - start < BUDGET && dut->gfx_busy) tick();
    for (int i = 0; i < 200; i++) tick();
    bool finished = !dut->gfx_busy;

    printf("ack delay %d cycle%s%s\n", ack_delay, ack_delay == 1 ? "" : "s",
           ack_delay == 0 ? " (a one-cycle memory: nothing is ever refused)" : "");
    printf("  %llu cycles, %llu requests presented, %llu accepted\n",
           (unsigned long long)(clks - start),
           (unsigned long long)presented, (unsigned long long)accepted);
    printf("  engine %s\n", finished ? "returned to idle" : "STILL BUSY - it never drained");

    // Every pixel of the rectangle must have reached memory, and with the
    // colour it was told to use.
    uint64_t missing = 0, wrongcolour = 0;
    for (int y = Y0; y <= Y1; y++)
        for (int x = X0; x <= X1; x++) {
            if (!pix_written(x, y)) { missing++; continue; }
            if (pix_index(x, y) != 0x5A) wrongcolour++;
        }
    if (getenv("REX3_MAP")) {
        printf("  coverage map (# written, . missing), rows \n");
        for (int y = Y0; y <= Y1; y++) {
            printf("    y=%2d ", y);
            for (int x = X0; x <= X1; x++)
                putchar(pix_written(x, y) ? '#' : '.');
            putchar('\n');
        }
    }
    printf("  %d x %d = %d pixels: %llu never written, %llu written with the wrong colour\n",
           W, H, W * H, (unsigned long long)missing, (unsigned long long)wrongcolour);

    auto check = [&](const char *what, bool ok) {
        printf("  %s %s\n", ok ? "ok     " : "FAILED ", what);
        if (!ok) failures++;
    };
    printf("\n");
    check("the engine finished the primitive", finished);
    check("every pixel of the rectangle reached memory", missing == 0);
    check("every pixel carried the colour it was given", wrongcolour == 0);
    // THE PROPERTY THIS FILE EXISTS FOR. Every address REX3 asserted a write
    // to must have reached memory. A rasteriser that fires writes at a memory
    // which is not ready loses exactly the difference, and believes it drew
    // them.
    uint64_t lost = 0;
    for (uint32_t a : intended) if (!written.count(a)) lost++;
    printf("  %zu addresses asserted, %llu of them never reached memory\n",
           intended.size(), (unsigned long long)lost);
    check("every write the engine asserted reached memory", lost == 0);

    //========================================================================
    //  Phase 2: the VDMA host port - X's pixel path (docs/33).
    //
    //  What IRIX's ng1 driver actually does: program a host-sourced packed
    //  draw (DRAW | colorhost, RWPACKED | RWDOUBLE, 8bpp host depth), then
    //  stream the image through the MC's DMA engine as 64-bit beats into
    //  HOSTRW0|GO. Every beat is eight pixels; every row boundary is a word
    //  boundary. The check is the same as phase 1's: every pixel of the
    //  image lands, in the right place, with the right value.
    //========================================================================
    {
        auto nd_beat_wr = [&](uint64_t val) -> bool {
            dut->nd_req = 1; dut->nd_we = 1; dut->nd_off = 0xA30;
            dut->nd_wdata = val;
            for (int guard = 0; guard < 100000; guard++) {
                tick();
                if (dut->nd_ack) { dut->nd_req = 0; tick(); return true; }
            }
            dut->nd_req = 0;
            return false;
        };
        auto nd_beat_rd = [&](uint64_t &val) -> bool {
            dut->nd_req = 1; dut->nd_we = 0; dut->nd_off = 0xA30;
            for (int guard = 0; guard < 100000; guard++) {
                tick();
                if (dut->nd_ack) { val = dut->nd_rdata; dut->nd_req = 0; tick(); return true; }
            }
            dut->nd_req = 0;
            return false;
        };

        const int DX0 = 10, DY0 = 100, DW = 32, DH = 4;
        auto px_val = [&](int x, int y) -> uint8_t {
            return (uint8_t)(0x21 + (y - DY0) * DW + (x - DX0));
        };

        // 8bpp host pixels, packed, doubled: eight pixels per 64-bit beat.
        // planes 0, drawdepth 1, RWPACKED, hostdepth 1, RWDOUBLE,
        // compare disabled, logicop SRC.
        wr(R_DRAWMODE1, (3u << 28) | (7u << 12) | (1u << 10) | (1u << 8)
                        | (1u << 7) | (1u << 3) | 0u);
        // DRAW, block, COLORHOST, stop on both axes.
        wr(R_DRAWMODE0, 2 | (1u << 2) | (1u << 6) | (1u << 8) | (1u << 9));
        wr(R_XYSTARTI,  ((uint32_t)DX0 << 16) | (uint32_t)DY0);
        wr(R_XYENDI,    ((uint32_t)(DX0 + DW - 1) << 16)
                        | (uint32_t)(DY0 + DH - 1));

        bool beats_ok = true;
        for (int y = DY0; y < DY0 + DH && beats_ok; y++)
            for (int x = DX0; x < DX0 + DW && beats_ok; x += 8) {
                uint64_t beat = 0;
                for (int j = 0; j < 8; j++)
                    beat |= (uint64_t)px_val(x + j, y) << (56 - 8*j);
                beats_ok = nd_beat_wr(beat);
            }
        for (int i = 0; i < 2000 && dut->gfx_busy; i++) tick();

        uint64_t dmiss = 0, dwrong = 0;
        for (int y = DY0; y < DY0 + DH; y++)
            for (int x = DX0; x < DX0 + DW; x++) {
                if (!pix_written(x, y)) { dmiss++; continue; }
                if (pix_index(x, y) != px_val(x, y)) dwrong++;
            }
        printf("\nVDMA host port: %dx%d image as %d beats\n", DW, DH,
               DW * DH / 8);
        check("every beat was accepted", beats_ok);
        check("the engine went idle after the last beat", !dut->gfx_busy);
        check("every DMA'd pixel reached memory", dmiss == 0);
        check("every DMA'd pixel carried its own byte", dwrong == 0);

        // Read the first eight pixels of the first row back through the same
        // port: OP_READ, host mode - the GIO->MEM direction of Ng1PixelDma.
        wr(R_DRAWMODE0, 1 | (1u << 2) | (1u << 8) | (1u << 9));
        wr(R_XYSTARTI,  ((uint32_t)DX0 << 16) | (uint32_t)DY0);
        wr(R_XYENDI,    ((uint32_t)(DX0 + DW - 1) << 16)
                        | (uint32_t)(DY0 + DH - 1));
        uint64_t got = 0, wantv = 0;
        bool rd_ok = nd_beat_rd(got);
        for (int j = 0; j < 8; j++)
            wantv |= (uint64_t)px_val(DX0 + j, DY0) << (56 - 8*j);
        if (rd_ok && got != wantv)
            printf("  read beat %016llx, expected %016llx\n",
                   (unsigned long long)got, (unsigned long long)wantv);
        check("a DMA read beat returned the pixels just drawn",
              rd_ok && got == wantv);
    }

    //========================================================================
    //  Phase 3: FASTCLEAR and the CID clip - the two write-path features X
    //  leans on that the PROM never touches (docs/33). FASTCLEAR must write
    //  COLORVRAM through a hostile logic op and a zero z-pattern; the CID
    //  clip must land pixels only where the auxiliary planes' low nibble
    //  matches CLIPMODE's cidmatch field.
    //========================================================================
    {
        enum { R_ZPATTERN_ = 0x0014, R_COLORVRAM = 0x001C, R_CLIPMODE_ = 0x1328 };
        const int FX0 = 200, FY0 = 300, FW = 24, FH = 5;

        // FASTCLEAR: logicop DST (write destination back = draws nothing if
        // the bit is ignored), z-pattern all-zero (skips every pixel if the
        // bit is ignored), COLORI a decoy. Only FASTCLEAR semantics produce
        // 0x37 in the frame buffer.
        wr(R_COLORVRAM, 0x00000037);
        wr(R_COLORI,    0x00000099);
        wr(R_ZPATTERN_, 0x00000000);
        wr(R_CLIPMODE_, 0x1E00);      // cidmatch = 0xF: CID clip off, as X sets it
        wr(R_DRAWMODE1, (5u << 28) | (1u << 17) | (7u << 12) | (1u << 3));
        wr(R_DRAWMODE0, 2 | (1u << 2) | (1u << 8) | (1u << 9) | (1u << 12));
        wr(R_XYSTARTI,  ((uint32_t)FX0 << 16) | (uint32_t)FY0);
        wr(R_XYENDI | GO, ((uint32_t)(FX0 + FW - 1) << 16)
                          | (uint32_t)(FY0 + FH - 1));
        for (int i = 0; i < 200000 && dut->gfx_busy; i++) tick();

        uint64_t fc_wrong = 0;
        for (int y = FY0; y < FY0 + FH; y++)
            for (int x = FX0; x < FX0 + FW; x++)
                if (!pix_written(x, y) || pix_index(x, y) != 0x37) fc_wrong++;
        printf("\nFASTCLEAR: %dx%d fill, %llu pixels wrong\n", FW, FH,
               (unsigned long long)fc_wrong);
        check("FASTCLEAR writes COLORVRAM through logicop DST and zpat 0",
              fc_wrong == 0);

        // CID clip: pre-set the aux low nibble to 5 for the left half of a
        // row only, then draw the whole row with cidmatch=5. Only the left
        // half may change.
        // The nibble lives in the auxiliary slot AND as a copy in byte 3 of
        // the drawing slot, which is where a drawing-plane draw reads it.
        const int CY = 320, CX0 = 200, CWD = 16;
        for (int x = CX0; x < CX0 + CWD; x++) {
            uint32_t aux = (x < CX0 + CWD/2) ? 5u : 0u;
            set_slot(x, CY, true,  aux);
            set_slot(x, CY, false, (aux << 24) | 0x11);   // old pixel index 0x11
        }
        wr(R_ZPATTERN_, 0xFFFFFFFF);
        wr(R_COLORI,    0x00000042);
        wr(R_CLIPMODE_, (5u << 9));             // cidmatch = 5, smasks off
        wr(R_DRAWMODE1, (3u << 28) | (7u << 12) | (1u << 3));
        wr(R_DRAWMODE0, 2 | (1u << 2) | (1u << 8) | (1u << 9));
        wr(R_XYSTARTI,  ((uint32_t)CX0 << 16) | (uint32_t)CY);
        wr(R_XYENDI | GO, ((uint32_t)(CX0 + CWD - 1) << 16) | (uint32_t)CY);
        for (int i = 0; i < 200000 && dut->gfx_busy; i++) tick();
        wr(R_CLIPMODE_, 0x1E00);                // cidmatch back to 0xF

        uint64_t cid_wrong = 0;
        for (int x = CX0; x < CX0 + CWD; x++) {
            uint8_t want = (x < CX0 + CWD/2) ? 0x42 : 0x11;
            if (pix_index(x, CY) != want) {
                cid_wrong++;
                if (cid_wrong <= 4)
                    printf("  cid x=%d got %02x want %02x\n", x,
                           (unsigned)pix_index(x, CY), want);
            }
        }
        printf("CID clip: %llu pixels wrong\n", (unsigned long long)cid_wrong);
        check("the CID clip draws only where the aux nibble matches",
              cid_wrong == 0);
        // And the copy that draw read must still match the auxiliary slot -
        // a drawing-plane write may not disturb byte 3.
        uint64_t copy_wrong = 0;
        for (int x = CX0; x < CX0 + CWD; x++)
            if ((slot_val(x, CY, false) >> 24) != (slot_val(x, CY, true) & 0xF))
                copy_wrong++;
        check("a drawing-plane write leaves the window-ID copy alone",
              copy_wrong == 0);

        // THE COPY IS MAINTAINED BY THE RASTERISER. Draw into the popup
        // planes (planes 5, the PROM's PUP mask 0xCC) across the same row
        // with a value that sets popup bits, and byte 3 of every drawing slot
        // must follow aux[3:0] - DR_CID's second write.
        wr(R_WRMASK,    0x000000CC);
        wr(R_COLORI,    0x00000003);                   // both popup bits
        wr(R_DRAWMODE1, (3u << 28) | (7u << 12) | (0u << 3) | 5u);
        wr(R_DRAWMODE0, 2 | (1u << 2) | (1u << 8) | (1u << 9));
        wr(R_XYSTARTI,  ((uint32_t)CX0 << 16) | (uint32_t)CY);
        wr(R_XYENDI | GO, ((uint32_t)(CX0 + CWD - 1) << 16) | (uint32_t)CY);
        for (int i = 0; i < 200000 && dut->gfx_busy; i++) tick();
        wr(R_WRMASK,    0x00FFFFFF);

        uint64_t pup_unchanged = 0, pup_copy_wrong = 0;
        for (int x = CX0; x < CX0 + CWD; x++) {
            uint32_t aux = slot_val(x, CY, true);
            if ((aux & 0xC) == 0) pup_unchanged++;
            if ((slot_val(x, CY, false) >> 24) != (aux & 0xF)) {
                pup_copy_wrong++;
                if (pup_copy_wrong <= 4)
                    printf("  copy x=%d drawing slot %08x aux slot %08x\n", x,
                           (unsigned)slot_val(x, CY, false), (unsigned)aux);
            }
        }
        printf("popup draw: %llu pixels without popup bits, %llu copies wrong\n",
               (unsigned long long)pup_unchanged, (unsigned long long)pup_copy_wrong);
        check("a popup-plane draw set the popup bits", pup_unchanged == 0);
        check("and refreshed the window-ID copy in every drawing slot",
              pup_copy_wrong == 0);
    }

    printf(failures ? "\nREX3FILL: FAIL\n" : "\nREX3FILL: PASS\n");
    delete dut;
    return failures ? 1 : 0;
}
