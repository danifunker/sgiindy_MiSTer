//============================================================================
//  tb_rex3draw - np_rex3 against a transcription of IRIS's rasteriser.
//
//  THIS IS THE BENCH THAT SAYS WHETHER THE ENGINE DRAWS THE RIGHT PIXELS.
//  tests/run-rex3.sh checks the PROM's own console commands and nothing else,
//  and the PROM asks for flat colour-index spans and blocks - about a tenth of
//  what REX3 can be told to do. Everything a GL program uses is outside it:
//  the colour DDAs, the dither, the three line address modes, the stipple, the
//  blend. This drives np_rex3 with those and compares every pixel against
//  IRIS's rex3_generic.rs, transcribed below.
//
//  THE ORACLE IS A TRANSCRIPTION, NOT A SECOND DESIGN. Each function here is
//  the same function from iris/src/rex3_generic.rs with the same name; where
//  it deviates there is a comment saying so and why. That is the same
//  arrangement tb_mcdma.cpp has with IRIS's DMA loops, and it is the only one
//  that catches a misreading of the hardware rather than a mistyping of it.
//
//  THREE DELIBERATE DIFFERENCES FROM IRIS, all documented at their site:
//    * plane selections 0, 3 and 7 draw into the drawing planes here, where
//      IRIS drops them. That is np_rex3's own choice - see `plane_of` - and
//      the PROM's console path depends on it.
//    * the write-side x clip is the 2048-pixel stride, not IRIS's 1344-pixel
//      screen. Every coordinate this bench generates is inside both.
//    * the frame buffer row is taken modulo 1024 rather than clipped, so the
//      bench keeps TOPSCAN at 1023 (which makes the two agree) and generates
//      no row outside the buffer.
//
//  The host paths - READ, COLORHOST, ALPHAHOST - are NOT exercised here. They
//  carry state across GOs that this bench does not model, and they already
//  have tests: tests/run-rex3.sh for the PROM's, verilator/tb_mcdma.cpp and
//  tests/run-dma.sh for X's pixel DMA.
//
//    make -C verilator rex3draw && ./obj_dir_rex3draw/Vnp_rex3draw
//    REX3D_CASES=20000 ./obj_dir_rex3draw/Vnp_rex3draw   # a longer run
//    REX3D_SEED=7      ./obj_dir_rex3draw/Vnp_rex3draw
//    REX3D_VERBOSE=1   ./obj_dir_rex3draw/Vnp_rex3draw   # print every case
//============================================================================

#include "Vnp_rex3.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// ---- geometry ------------------------------------------------------------
static const int FBW = 2048;          // the stride, in pixels
static const int FBH = 1024;
static const int COORD_BIAS = 4096;

static uint32_t *fb_rgb;              // the oracle's two planes
static uint32_t *fb_aux;
static uint32_t *rt_rgb;              // and what np_rex3 actually wrote
static uint32_t *rt_aux;

// ==========================================================================
//  The oracle: iris/src/rex3_generic.rs, transcribed
// ==========================================================================

// DRAWMODE0
static const uint32_t OP_NOOP = 0, OP_READ = 1, OP_DRAW = 2, OP_SCR2SCR = 3;
static const uint32_t AM_SPAN = 0, AM_BLOCK = 1, AM_ILINE = 2, AM_FLINE = 3,
                      AM_ALINE = 4;

struct Ctx {
    uint32_t drawmode0 = 0, drawmode1 = 0;
    uint32_t lsmode = 0, lspattern = 0, zpattern = 0;
    uint32_t colorback = 0, colorvram = 0, alpharef = 0;
    uint32_t smask0x = 0, smask0y = 0;
    uint32_t smask1x = 0, smask1y = 0, smask2x = 0, smask2y = 0;
    uint32_t smask3x = 0, smask3y = 0, smask4x = 0, smask4y = 0;
    int32_t  xstart = 0, ystart = 0, xend = 0, yend = 0, xsave = 0;
    uint32_t xymove = 0, xywin = 0, clipmode = 0, wrmask = 0;
    uint32_t aweight0 = 0, aweight1 = 0;
    uint32_t bresd = 0, bresoctinc1 = 0, bresrndinc2 = 0;
    uint32_t colorred = 0, colorgrn = 0, colorblue = 0, coloralpha = 0;
    int32_t  slopered = 0, slopegrn = 0, slopeblue = 0, slopealpha = 0;
    uint8_t  zpat_bit = 31, pat_bit = 31;
};

static Ctx ox;

static inline uint32_t bits(uint32_t v, int hi, int lo)
{
    return (v >> lo) & ((hi - lo == 31) ? 0xFFFFFFFFu : ((1u << (hi - lo + 1)) - 1));
}

// DRAWMODE0 fields
static uint32_t dm0_opcode()   { return bits(ox.drawmode0, 1, 0); }
static uint32_t dm0_adrmode()  { return bits(ox.drawmode0, 4, 2); }
static uint32_t dm0_dosetup()  { return bits(ox.drawmode0, 5, 5); }
static uint32_t dm0_stoponx()  { return bits(ox.drawmode0, 8, 8); }
static uint32_t dm0_stopony()  { return bits(ox.drawmode0, 9, 9); }
static uint32_t dm0_skipfirst(){ return bits(ox.drawmode0, 10, 10); }
static uint32_t dm0_skiplast() { return bits(ox.drawmode0, 11, 11); }
static uint32_t dm0_enzpat_r() { return bits(ox.drawmode0, 12, 12); }
static uint32_t dm0_enlspat_r(){ return bits(ox.drawmode0, 13, 13); }
static uint32_t dm0_lsadvlast(){ return bits(ox.drawmode0, 14, 14); }
static uint32_t dm0_length32() { return bits(ox.drawmode0, 15, 15); }
static uint32_t dm0_zpopaq_r() { return bits(ox.drawmode0, 16, 16); }
static uint32_t dm0_lsopaq_r() { return bits(ox.drawmode0, 17, 17); }
static uint32_t dm0_shade_r()  { return bits(ox.drawmode0, 18, 18); }
static uint32_t dm0_lronly()   { return bits(ox.drawmode0, 19, 19); }
static uint32_t dm0_xyoffset() { return bits(ox.drawmode0, 20, 20); }
static uint32_t dm0_ciclamp()  { return bits(ox.drawmode0, 21, 21); }
static uint32_t dm0_endptflt() { return bits(ox.drawmode0, 22, 22); }
static uint32_t dm0_ystride()  { return bits(ox.drawmode0, 23, 23); }

// DRAWMODE1 fields
static uint32_t dm1_planes()   { return bits(ox.drawmode1, 2, 0); }
static uint32_t dm1_drawdepth(){ return bits(ox.drawmode1, 4, 3); }
static uint32_t dm1_dblsrc()   { return bits(ox.drawmode1, 5, 5); }
static uint32_t dm1_compare_r(){ return bits(ox.drawmode1, 14, 12); }
static uint32_t dm1_rgbmode()  { return bits(ox.drawmode1, 15, 15); }
static uint32_t dm1_dither_r() { return bits(ox.drawmode1, 16, 16); }
static uint32_t dm1_fastclr()  { return bits(ox.drawmode1, 17, 17); }
static uint32_t dm1_blend_r()  { return bits(ox.drawmode1, 18, 18); }
static uint32_t dm1_sfactor()  { return bits(ox.drawmode1, 21, 19); }
static uint32_t dm1_dfactor()  { return bits(ox.drawmode1, 24, 22); }
static uint32_t dm1_backblend(){ return bits(ox.drawmode1, 25, 25); }
static uint32_t dm1_blendalph(){ return bits(ox.drawmode1, 27, 27); }
static uint32_t dm1_logicop_r(){ return bits(ox.drawmode1, 31, 28); }

static uint32_t cid_mask()     { return bits(ox.clipmode, 12, 9); }
static uint32_t cidtest()      { return cid_mask() == 0xF ? 0 : 1; }
static uint32_t ensmask()      { return bits(ox.clipmode, 4, 0); }

// rex3_shape::unpack's FASTCLEAR fold: the bit collapses the whole pixel
// pipeline, but only where hardware honours it.
static bool fastclear_active()
{
    return dm1_fastclr() && dm0_opcode() == OP_DRAW && cidtest() == 0;
}
static uint32_t dm0_enzpattern() { return fastclear_active() ? 0 : dm0_enzpat_r(); }
static uint32_t dm0_enlspattern(){ return fastclear_active() ? 0 : dm0_enlspat_r(); }
static uint32_t dm0_zpopaque()   { return fastclear_active() ? 0 : dm0_zpopaq_r(); }
static uint32_t dm0_lsopaque()   { return fastclear_active() ? 0 : dm0_lsopaq_r(); }
static uint32_t dm0_shade()      { return fastclear_active() ? 0 : dm0_shade_r(); }
static uint32_t dm1_dither()     { return fastclear_active() ? 0 : dm1_dither_r(); }
static uint32_t dm1_blend()      { return fastclear_active() ? 0 : dm1_blend_r(); }
static uint32_t dm1_compare()    { return fastclear_active() ? 7 : dm1_compare_r(); }
static uint32_t dm1_logicop()    { return dm1_logicop_r(); }

// ---- colour depth --------------------------------------------------------
static uint32_t rgb4_to_rgb24(uint32_t v)
{
    uint32_t r = (v & 1) ? 0xFF : 0, g_raw = (v >> 1) & 3;
    uint32_t g = (g_raw << 6) | (g_raw << 4) | (g_raw << 2) | g_raw;
    uint32_t b = (v & 8) ? 0xFF : 0;
    return (b << 16) | (g << 8) | r;
}
static uint32_t rgb8_to_rgb24(uint32_t v)
{
    uint32_t rr = v & 7, gr = (v >> 3) & 7, br = (v >> 6) & 3;
    uint32_t r = (rr << 5) | (rr << 2) | (rr >> 1);
    uint32_t g = (gr << 5) | (gr << 2) | (gr >> 1);
    uint32_t b = (br << 6) | (br << 4) | (br << 2) | br;
    return (b << 16) | (g << 8) | r;
}
static uint32_t rgb12_to_rgb24(uint32_t v)
{
    uint32_t rr = v & 0xF, gr = (v >> 4) & 0xF, br = (v >> 8) & 0xF;
    return (((br << 4) | br) << 16) | (((gr << 4) | gr) << 8) | ((rr << 4) | rr);
}

static const uint64_t BAYER_PACKED = 0x5D7F91B36E4CA280ull;
static uint32_t bayer_threshold(uint32_t idx)
{
    return (uint32_t)((BAYER_PACKED >> (idx * 4)) & 0xF);
}

static uint32_t compress(uint32_t val, int x, int y)
{
    if (!dm1_rgbmode()) return val & 0xFFFFFF;
    uint32_t r = val & 0xFF, g = (val >> 8) & 0xFF, b = (val >> 16) & 0xFF;
    if (!dm1_dither()) {
        switch (dm1_drawdepth()) {
        case 0: return (((b >> 7) & 1) << 3) | (((g >> 6) & 3) << 1) | ((r >> 7) & 1);
        case 1: return (((b >> 6) & 3) << 6) | (((g >> 5) & 7) << 3) | ((r >> 5) & 7);
        case 2: return (((b >> 4) & 0xF) << 8) | (((g >> 4) & 0xF) << 4) | ((r >> 4) & 0xF);
        default: return val & 0xFFFFFF;
        }
    }
    uint32_t bayer = bayer_threshold((uint32_t)(((y & 3) << 2) | (x & 3)));
    if (dm1_drawdepth() == 0) {
        uint8_t sr = (uint8_t)((r >> 3) - (r >> 4));
        uint8_t sg = (uint8_t)((g >> 2) - (g >> 4));
        uint8_t sb = (uint8_t)((b >> 3) - (b >> 4));
        uint32_t dr = (sr >> 4) & 1, dg = (sg >> 4) & 3, db = (sb >> 4) & 1;
        if ((uint32_t)(sr & 0xF) > bayer && dr < 1) dr++;
        if ((uint32_t)(sg & 0xF) > bayer && dg < 3) dg++;
        if ((uint32_t)(sb & 0xF) > bayer && db < 1) db++;
        return (db << 3) | (dg << 1) | dr;
    }
    if (dm1_drawdepth() == 1) {
        uint8_t sr = (uint8_t)((r >> 1) - (r >> 4));
        uint8_t sg = (uint8_t)((g >> 1) - (g >> 4));
        uint8_t sb = (uint8_t)((b >> 2) - (b >> 4));
        uint32_t dr = (sr >> 4) & 7, dg = (sg >> 4) & 7, db = (sb >> 4) & 3;
        if ((uint32_t)(sr & 0xF) > bayer && dr < 7) dr++;
        if ((uint32_t)(sg & 0xF) > bayer && dg < 7) dg++;
        if ((uint32_t)(sb & 0xF) > bayer && db < 3) db++;
        return (db << 6) | (dg << 3) | dr;
    }
    if (dm1_drawdepth() == 2) {
        uint32_t sr = r - (r >> 4), sg = g - (g >> 4), sb = b - (b >> 4);
        uint32_t dr = (sr >> 4) & 15, dg = (sg >> 4) & 15, db = (sb >> 4) & 15;
        if ((sr & 0xF) > bayer && dr < 15) dr++;
        if ((sg & 0xF) > bayer && dg < 15) dg++;
        if ((sb & 0xF) > bayer && db < 15) db++;
        return (db << 8) | (dg << 4) | dr;
    }
    return val & 0xFFFFFF;
}

static uint32_t expand(uint32_t val)
{
    if (!dm1_rgbmode()) return val;
    switch (dm1_drawdepth()) {
    case 0:  return rgb4_to_rgb24(val);
    case 1:  return rgb8_to_rgb24(val);
    case 2:  return rgb12_to_rgb24(val);
    default: return val;
    }
}

static uint32_t amplify(uint32_t v)
{
    switch (dm1_planes()) {
    case 4: return ((v & 0xFF) << 8) | ((v & 0xFF) << 16);
    case 5: return ((v & 3) << 2) | ((v & 3) << 6);
    case 6: return (v & 3) | ((v & 3) << 4);
    default:
        switch (dm1_drawdepth()) {
        case 0:  return (v & 0xF) | ((v & 0xF) << 4);
        case 1:  return (v & 0xFF) | ((v & 0xFF) << 8);
        case 2:  return (v & 0xFFF) | ((v & 0xFFF) << 12);
        default: return v & 0xFFFFFF;
        }
    }
}

static uint32_t logic_op(uint32_t s, uint32_t d)
{
    switch (dm1_logicop()) {
    case 0:  return 0;
    case 1:  return s & d;
    case 2:  return s & ~d;
    case 3:  return s;
    case 4:  return ~s & d;
    case 5:  return d;
    case 6:  return s ^ d;
    case 7:  return s | d;
    case 8:  return ~(s | d);
    case 9:  return ~(s ^ d);
    case 10: return ~d;
    case 11: return s | ~d;
    case 12: return ~s;
    case 13: return ~s | d;
    case 14: return ~(s & d);
    default: return ~0u;
    }
}

static bool afunc(uint32_t sa, uint32_t aref)
{
    switch (dm1_compare()) {
    case 0:  return false;
    case 1:  return sa < aref;
    case 2:  return sa == aref;
    case 3:  return sa <= aref;
    case 4:  return sa > aref;
    case 5:  return sa != aref;
    case 6:  return sa >= aref;
    default: return true;
    }
}

// THE DEVIATION. IRIS maps only planes 1 and 2 onto the drawing planes and
// drops a write through any other unmapped selection; np_rex3 maps every
// non-auxiliary selection onto them, because that is what the PROM's console
// path draws through. The oracle follows np_rex3 so the bench can cover
// planes 0 as well as the rest.
static bool plane_is_aux() { uint32_t p = dm1_planes(); return p >= 4 && p <= 6; }
static void plane_shift_mask(uint32_t *shift, uint32_t *mask)
{
    bool dbl = dm1_dblsrc() != 0;
    switch (dm1_planes()) {
    case 4: *shift = dbl ? 16 : 8;  *mask = 0xFF;  return;
    case 5: *shift = dbl ? 6 : 2;   *mask = 0x3;   return;
    case 6: *shift = dbl ? 4 : 0;   *mask = 0x3;   return;
    default:
        switch (dm1_drawdepth()) {
        case 0: *shift = dbl ? 4 : 0;  *mask = 0xF;      return;
        case 1: *shift = dbl ? 8 : 0;  *mask = 0xFF;     return;
        case 2: *shift = 0;            *mask = 0xFFF;    return;
        default:*shift = 0;            *mask = 0xFFFFFF; return;
        }
    }
}
static uint32_t read_plane(uint32_t addr)
{
    uint32_t sh, mk; plane_shift_mask(&sh, &mk);
    uint32_t raw = (plane_is_aux() ? fb_aux : fb_rgb)[addr] & 0xFFFFFF;
    return (raw >> sh) & mk;
}
// Every pixel either side touched this case, so the comparison is over what
// was drawn rather than over two million words.
static std::vector<uint32_t> touched;
// With REX3D_TRACE, the ordered write lists of both sides, so a failure says
// which pixels each one visited and in what order rather than only that the
// picture differs.
static bool trace_writes = false;
struct Wr { uint32_t idx, val; bool aux; };
static std::vector<Wr> ow, rw;
static void write_plane(uint32_t addr, uint32_t val)
{
    uint32_t *p = &(plane_is_aux() ? fb_aux : fb_rgb)[addr];
    uint32_t mask = ox.wrmask & 0xFFFFFF;
    *p = (*p & ~mask) | (val & mask);
    touched.push_back(addr);
    if (trace_writes) ow.push_back({ addr, *p & 0xFFFFFF, plane_is_aux() });
}
static bool cid_allows_write(uint32_t addr)
{
    uint32_t cid = fb_aux[addr] & 3;
    return (cid_mask() & (1u << cid)) != 0;
}

// ---- addressing ----------------------------------------------------------
// -1 means "clipped away".
static int64_t calculate_fb_address(int x, int y, bool is_write)
{
    bool is_scr2scr = dm0_opcode() == OP_SCR2SCR;
    int x_curr = x, y_curr = y;
    if (is_scr2scr || dm0_xyoffset()) {
        x_curr += (int16_t)(ox.xymove >> 16);
        y_curr += (int16_t)(ox.xymove & 0xFFFF);
    }
    int x_off = (int16_t)(ox.xywin >> 16), y_off = (int16_t)(ox.xywin & 0xFFFF);
    int x_abs = x_curr + x_off, y_abs = y_curr + y_off;

    if (is_write) {
        uint32_t em = ensmask();
        if (em & 1) {
            int mnx = (int16_t)(ox.smask0x >> 16), mxx = (int16_t)(ox.smask0x & 0xFFFF);
            int mny = (int16_t)(ox.smask0y >> 16), mxy = (int16_t)(ox.smask0y & 0xFFFF);
            if (x_curr < mnx || x_curr > mxx || y_curr < mny || y_curr > mxy) return -1;
        }
        if (em & 0x1E) {
            const uint32_t sx[4] = { ox.smask1x, ox.smask2x, ox.smask3x, ox.smask4x };
            const uint32_t sy[4] = { ox.smask1y, ox.smask2y, ox.smask3y, ox.smask4y };
            bool inside = false;
            for (int i = 0; i < 4 && !inside; i++) {
                if (!(em & (1u << (i + 1)))) continue;
                int mnx = (int16_t)(sx[i] >> 16), mxx = (int16_t)(sx[i] & 0xFFFF);
                int mny = (int16_t)(sy[i] >> 16), mxy = (int16_t)(sy[i] & 0xFFFF);
                if (x_abs >= mnx && x_abs <= mxx && y_abs >= mny && y_abs <= mxy)
                    inside = true;
            }
            if (!inside) return -1;
        }
    }
    int x_phys = x_abs - COORD_BIAS, y_phys = y_abs - COORD_BIAS;
    // See the header: np_rex3 clips x against the 2048-pixel stride rather
    // than IRIS's 1344-pixel screen, and wraps y instead of clipping it. The
    // bench generates nothing that can tell the difference.
    if (x_phys < 0 || x_phys >= FBW || y_phys < 0 || y_phys >= FBH) return -1;
    return (int64_t)y_phys * FBW + x_phys;
}
static int64_t calculate_src_address(int x, int y)
{
    int x_abs = x + (int16_t)(ox.xywin >> 16);
    int y_abs = y + (int16_t)(ox.xywin & 0xFFFF);
    int x_phys = x_abs - COORD_BIAS, y_phys = y_abs - COORD_BIAS;
    if (x_phys < 0 || x_phys >= FBW || y_phys < 0 || y_phys >= FBH) return -1;
    return (int64_t)y_phys * FBW + x_phys;
}

// ---- blending ------------------------------------------------------------
static uint32_t bfactor(uint32_t sel, uint32_t c, uint32_t a)
{
    switch (sel) {
    case 0:  return 0;
    case 1:  return 255;
    case 2:  return c;
    case 3:  return 255 - c;
    case 4:  return a;
    case 5:  return 255 - a;
    default: return 0;
    }
}
static uint32_t blend(uint32_t src, uint32_t dst)
{
    uint32_t sa_real = (src >> 24) & 0xFF;
    uint32_t sa_src = dm1_blendalph() ? sa_real : 255;
    uint32_t res = 0;
    for (int i = 0; i < 4; i++) {
        int sh = i * 8;
        uint32_t s_c = (src >> sh) & 0xFF, d_c = (dst >> sh) & 0xFF;
        uint32_t sf = bfactor(dm1_sfactor(), d_c, sa_src);
        uint32_t df = bfactor(dm1_dfactor(), s_c, sa_real);
        uint32_t v = (s_c * sf + d_c * df) / 255;
        if (v > 255) v = 255;
        res |= v << sh;
    }
    return res;
}

// ---- per-pixel iteration -------------------------------------------------
static uint32_t clamp_shade(uint32_t c)
{
    uint32_t v = (c >> 11) & 0x1FF;
    if (c & (1u << 31) || v >= 0x180) return 0;
    if (v > 0xFF) return 0x0007FFFF;
    return c;
}
static uint32_t clamp_color_component(uint32_t c)
{
    uint32_t v = (c >> 11) & 0x1FF;
    if (c & (1u << 31) || v >= 0x180) return 0;
    if (v > 0xFF) return 0xFF;
    return v;
}
static void iterate_shade()
{
    if (!dm0_shade()) return;
    ox.colorred   += (uint32_t)ox.slopered;
    ox.colorgrn   += (uint32_t)ox.slopegrn;
    ox.colorblue  += (uint32_t)ox.slopeblue;
    ox.coloralpha += (uint32_t)ox.slopealpha;
    if (dm1_rgbmode()) {
        ox.colorred   = clamp_shade(ox.colorred);
        ox.colorgrn   = clamp_shade(ox.colorgrn);
        ox.colorblue  = clamp_shade(ox.colorblue);
        ox.coloralpha = clamp_shade(ox.coloralpha);
    } else if (dm0_ciclamp()) {
        if (dm1_drawdepth() == 1 && (ox.colorred & (1u << 19))) ox.colorred = 0x0007FFFF;
        if (dm1_drawdepth() == 2 && (ox.colorred & (1u << 21))) ox.colorred = 0x001FFFFF;
    }
}
static void advance_zpat() { ox.zpat_bit = (uint8_t)((ox.zpat_bit - 1) & 31); }
static void advance_lspat()
{
    uint8_t lsrepeat = (uint8_t)bits(ox.lsmode, 15, 8);
    uint8_t repeat = lsrepeat ? lsrepeat : 1;
    uint8_t rcount = (uint8_t)bits(ox.lsmode, 7, 0);
    if (rcount == 0) {
        ox.lsmode = (ox.lsmode & ~0xFFu) | (uint32_t)(repeat - 1);
        uint8_t length = (uint8_t)(bits(ox.lsmode, 27, 24) + 17);
        uint8_t wrap = (uint8_t)(32 > length ? 32 - length : 0);
        ox.pat_bit = (ox.pat_bit == wrap) ? 31 : (uint8_t)((ox.pat_bit - 1) & 31);
    } else {
        ox.lsmode = (ox.lsmode & ~0xFFu) | (uint32_t)(rcount - 1);
    }
}
static void iterate_pattern()
{
    if (dm0_enzpattern())  advance_zpat();
    if (dm0_enlspattern()) advance_lspat();
}

static uint32_t fastclear_color()
{
    uint32_t v = ox.colorvram;
    switch (dm1_drawdepth()) {
    case 0: { uint32_t c = v & 0xF;  return c | (c << 4) | (c << 8) | (c << 16); }
    case 1: { uint32_t c = v & 0xFF; return c | (c << 8) | (c << 16); }
    case 2: {
        uint32_t c = dm1_rgbmode()
                   ? (((v & 0xF00000) >> 12) | ((v & 0xF000) >> 8) | ((v & 0xF0) >> 4))
                   : (v & 0xFFF);
        return c | (c << 12);
    }
    default: return v & 0xFFFFFF;
    }
}

static uint32_t get_colori()
{
    if (dm1_rgbmode())
        return (clamp_color_component(ox.colorblue) << 16)
             | (clamp_color_component(ox.colorgrn) << 8)
             |  clamp_color_component(ox.colorred);
    return ox.colorred >> 11;
}

// ---- pixel bodies --------------------------------------------------------
static void pixel_draw(uint32_t fc_color, int x, int y)
{
    bool use_bg = false;
    if (dm0_enzpattern() && ((ox.zpattern >> ox.zpat_bit) & 1) == 0) {
        if (dm0_zpopaque()) use_bg = true; else return;
    }
    if (dm0_enlspattern() && ((ox.lspattern >> ox.pat_bit) & 1) == 0) {
        if (dm0_lsopaque()) use_bg = true; else return;
    }
    int64_t addr = calculate_fb_address(x, y, true);
    if (addr < 0) return;
    if (cidtest() && !cid_allows_write((uint32_t)addr)) return;
    if (fastclear_active()) { write_plane((uint32_t)addr, fc_color); return; }

    uint32_t raw_src = use_bg
        ? ox.colorback
        : ((get_colori() & 0x00FFFFFF)
           | (clamp_color_component(ox.coloralpha) << 24));

    if (dm1_compare() != 7 && !afunc((raw_src >> 24) & 0xFF, ox.alpharef & 0xFF)) return;

    uint32_t res;
    if (dm1_blend()) {
        uint32_t dst_raw = dm1_backblend() ? ox.colorback
                                           : expand(read_plane((uint32_t)addr));
        res = amplify(compress(blend(raw_src, dst_raw), x, y));
    } else {
        uint32_t s = amplify(compress(raw_src, x, y));
        uint32_t d = amplify(read_plane((uint32_t)addr));
        res = logic_op(s, d);
    }
    write_plane((uint32_t)addr, res);
}

static void pixel_scr2scr(int x, int y)
{
    int64_t sa = calculate_src_address(x, y);
    uint32_t raw_src = (sa < 0) ? 0 : expand(read_plane((uint32_t)sa));
    int64_t da = calculate_fb_address(x, y, true);
    if (da < 0) return;
    if (cidtest() && !cid_allows_write((uint32_t)da)) return;
    uint32_t res;
    if (dm1_blend()) {
        uint32_t dst_raw = dm1_backblend() ? ox.colorback
                                           : expand(read_plane((uint32_t)da));
        res = compress(blend(raw_src, dst_raw), x, y);   // no amplify: IRIS's shape
    } else {
        uint32_t s = amplify(compress(raw_src, x, y));
        uint32_t d = amplify(read_plane((uint32_t)da));
        res = logic_op(s, d);
    }
    write_plane((uint32_t)da, res);
}

static void pixel(uint32_t fc_color, int x, int y)
{
    if (dm0_opcode() == OP_SCR2SCR)  pixel_scr2scr(x, y);
    else if (dm0_opcode() == OP_DRAW) pixel_draw(fc_color, x, y);
}

// ---- the walkers ---------------------------------------------------------
static const int OCT[8][5] = {
    { 0,  1, -1, -1, 1 }, { 0,  1,  1,  1, 1 },
    { 0, -1, -1, -1, 1 }, { 0, -1,  1,  1, 1 },
    { 1,  1,  0, -1, 0 }, { 1,  1,  0,  1, 0 },
    {-1, -1,  0, -1, 0 }, {-1, -1,  0,  1, 0 },
};

static void draw_block_g()
{
    bool stopony = dm0_stopony(), length32 = dm0_length32(), ystride = dm0_ystride();
    bool first = true, skipfirst = dm0_skipfirst(), skiplast = dm0_skiplast();
    bool stoponx = dm0_stoponx();
    uint32_t octant = bits(ox.bresoctinc1, 26, 24);
    bool x_dec = (octant & 2) != 0, y_dec = (octant & 1) != 0;
    bool lrskip = dm0_lronly() && x_dec;
    int32_t stepx = x_dec ? -(1 << 11) : (1 << 11);
    int32_t stepy = (y_dec ? -1 : 1) * ((ystride ? 2 : 1) << 11);
    int32_t span_len = (ox.xend - ox.xstart) >> 11;
    if (span_len < 0) span_len = -span_len;
    bool have_stop = length32 && span_len >= 32;
    int32_t xstop = ox.xstart + stepx * 32;
    uint32_t fc = fastclear_color();

    for (;;) {
        int x = ox.xstart >> 11, y = ox.ystart >> 11;
        ox.xstart += stepx;
        bool x_end = x_dec ? (ox.xstart < ox.xend) : (ox.xstart > ox.xend);
        if (!((first && skipfirst) || (x_end && skiplast) || lrskip))
            pixel(fc, x, y);
        iterate_shade();
        iterate_pattern();
        if (x_end) {
            ox.ystart += stepy;
            ox.xstart = ox.xsave;
            ox.pat_bit = 31; ox.zpat_bit = 31;
            if (!stopony) break;
            bool y_end = y_dec ? (ox.ystart < ox.yend) : (ox.ystart > ox.yend);
            if (y_end) break;
            first = true;
        } else if (have_stop) {
            bool hit = x_dec ? (ox.xstart <= xstop) : (ox.xstart >= xstop);
            if (hit) break;
        }
        if (!stoponx) break;
    }
}

static void draw_span_g()
{
    if (dm0_lronly() && (bits(ox.bresoctinc1, 26, 24) & 2)) return;
    bool length32 = dm0_length32();
    bool first = true, skipfirst = dm0_skipfirst(), skiplast = dm0_skiplast();
    bool stoponx = dm0_stoponx();
    int32_t span_len = (ox.xend - ox.xstart) >> 11;
    bool have_stop = length32 && span_len >= 32;
    int32_t xstop = ox.xstart + (32 << 11);
    uint32_t fc = fastclear_color();

    for (;;) {
        int x = ox.xstart >> 11, y = ox.ystart >> 11;
        ox.xstart += (1 << 11);
        bool x_end = ox.xstart > ox.xend;
        if (!((first && skipfirst) || (x_end && skiplast))) pixel(fc, x, y);
        iterate_shade();
        iterate_pattern();
        if (x_end) { ox.pat_bit = 31; ox.zpat_bit = 31; break; }
        if (have_stop && ox.xstart >= xstop) break;
        if (!stoponx) break;
        first = false;
    }
}

static void draw_line_bresenham(bool extra_skip_first, bool extra_skip_last)
{
    uint32_t octant = bits(ox.bresoctinc1, 26, 24);
    int incrx1 = OCT[octant][0], incrx2 = OCT[octant][1];
    int incry1 = OCT[octant][2], incry2 = OCT[octant][3];
    int x2 = ox.xend >> 11, y2 = ox.yend >> 11;
    int x = ox.xstart >> 11, y = ox.ystart >> 11;
    int32_t incr1 = (int32_t)bits(ox.bresoctinc1, 19, 0);
    uint32_t r2 = bits(ox.bresrndinc2, 20, 0);
    int32_t incr2 = (r2 & (1u << 20)) ? (int32_t)(r2 | 0xFFE00000u) : (int32_t)r2;
    uint32_t rd = ox.bresd & 0x7FFFFFF;
    int32_t d = (rd & (1u << 26)) ? (int32_t)(rd | 0xF8000000u) : (int32_t)rd;

    int adx = x2 - x; if (adx < 0) adx = -adx;
    int ady = y2 - y; if (ady < 0) ady = -ady;
    int major = adx > ady ? adx : ady;
    int pixel_count = major + 1;
    if (dm0_length32() && pixel_count > 32) pixel_count = 32;

    bool iterate_one = !dm0_stoponx() && !dm0_stopony();
    bool skip_first = dm0_skipfirst() || extra_skip_first;
    bool skip_last  = dm0_skiplast()  || extra_skip_last;
    if (iterate_one) { pixel_count = 1; skip_first = false; skip_last = false; }
    bool lsadvlast = dm0_lsadvlast();
    uint32_t fc = fastclear_color();

    for (int i = 0; i < pixel_count; i++) {
        bool is_first = (i == 0), is_last = (i == pixel_count - 1);
        if ((!is_first || !skip_first) && (!is_last || !skip_last)) pixel(fc, x, y);
        iterate_shade();
        if (!is_last || lsadvlast) iterate_pattern();
        if (!is_last || iterate_one) {
            if (d < 0) { x += incrx1; y -= incry1; d += incr1; }
            else       { x += incrx2; y -= incry2; d += incr2; }
        }
    }
    ox.xstart = x << 11;
    ox.ystart = y << 11;
    ox.bresd  = (uint32_t)d & 0x7FFFFFF;
}

static void fline_apply_fract(int32_t *d, int *x, int *y)
{
    uint32_t octant = bits(ox.bresoctinc1, 26, 24);
    int incrx2 = OCT[octant][1], incry2 = OCT[octant][3];
    bool y_major = OCT[octant][4] != 0;
    int x1p = ox.xstart >> 11, y1p = ox.ystart >> 11;
    int x2p = ox.xend >> 11,   y2p = ox.yend >> 11;
    int dx = x1p - x2p; if (dx < 0) dx = -dx;
    int dy = y1p - y2p; if (dy < 0) dy = -dy;
    int xf = (ox.xstart >> 7) & 0xF, yf = (ox.ystart >> 7) & 0xF, t;
    switch (octant) {
    case 1: t = xf; xf = yf; yf = t; t = dx; dx = dy; dy = t; break;
    case 3: xf = 0x10 - xf; t = xf; xf = yf; yf = t; t = dx; dx = dy; dy = t; break;
    case 7: xf = 0x10 - xf; break;
    case 6: xf = 0x10 - xf; yf = 0x10 - yf; break;
    case 2: t = 0x10 - xf; xf = 0x10 - yf; yf = t; t = dx; dx = dy; dy = t; break;
    case 0: t = 0x10 - yf; yf = xf; xf = t; t = dx; dx = dy; dy = t; break;
    case 4: yf = 0x10 - yf; break;
    default: break;
    }
    *d += dy - dx;
    *d += 2 * (((dx * yf) >> 4) - ((dy * xf) >> 4));
    int major_delta = y_major ? dy : dx;
    int32_t e = *d - 2 * major_delta;
    if (e > 0) {
        *d = e;
        if (!y_major) *y -= incry2; else *x += incrx2;
    }
}

static void setup()
{
    int32_t dx = ox.xend - ox.xstart, dy = ox.yend - ox.ystart;
    int32_t adx = (dx < 0 ? -dx : dx) >> 11, ady = (dy < 0 ? -dy : dy) >> 11;
    uint32_t octant = 0;
    if (dy < 0) octant |= 1;
    if (dx < 0) octant |= 2;
    if (adx > ady) octant |= 4;
    int32_t major = adx > ady ? adx : ady, minor = adx > ady ? ady : adx;
    int32_t incr1 = 2 * minor, incr2 = 2 * (minor - major), d = incr1 - major;
    ox.bresoctinc1 = (ox.bresoctinc1 & ~(7u << 24)) | (octant << 24);
    ox.bresoctinc1 = (ox.bresoctinc1 & ~0xFFFFFu) | ((uint32_t)incr1 & 0xFFFFF);
    ox.bresrndinc2 = (ox.bresrndinc2 & ~0x1FFFFFu) | ((uint32_t)incr2 & 0x1FFFFF);
    uint32_t am = dm0_adrmode();
    if (am == AM_FLINE || am == AM_ALINE) {
        int x = ox.xstart >> 11, y = ox.ystart >> 11;
        int d_pre = d;
        fline_apply_fract(&d, &x, &y);
        if (trace_writes)
            printf("    setup: oct=%u adx=%d ady=%d incr1=%d incr2=%d d=%d "
                   "-> fract d=%d start=(%d,%d)\n",
                   octant, adx, ady, incr1, incr2, d_pre, d, x, y);
        ox.xstart = x << 11;
        ox.ystart = y << 11;
    } else if (trace_writes) {
        printf("    setup: oct=%u adx=%d ady=%d incr1=%d incr2=%d d=%d\n",
               octant, adx, ady, incr1, incr2, d);
    }
    ox.bresd = (uint32_t)d & 0x7FFFFFF;
}

static void oracle_go()
{
    uint32_t am = dm0_adrmode();
    bool is_line = (am == AM_ILINE || am == AM_FLINE || am == AM_ALINE);
    if (dm0_dosetup()) { ox.pat_bit = 31; ox.zpat_bit = 31; }
    if (dm0_dosetup()) setup();
    else if (is_line) {
        int xs = ox.xstart >> 11, ys = ox.ystart >> 11;
        int xe = ox.xend >> 11,   ye = ox.yend >> 11;
        int adx = xe - xs; if (adx < 0) adx = -adx;
        int ady = ye - ys; if (ady < 0) ady = -ady;
        if (adx != ady) {
            bool seg_x_major = adx > ady;
            bool oct_x_major = (bits(ox.bresoctinc1, 26, 24) & 4) != 0;
            if (seg_x_major != oct_x_major) setup();
        }
    }
    if (dm0_opcode() == OP_NOOP) return;
    if (is_line) {
        bool sf = false, sl = false;
        if (am == AM_ALINE && dm0_endptflt()) {
            uint32_t xsf = (ox.xstart >> 7) & 0xF, ysf = (ox.ystart >> 7) & 0xF;
            uint32_t xef = (ox.xend >> 7) & 0xF,   yef = (ox.yend >> 7) & 0xF;
            if (xsf || ysf) {
                uint32_t wi = xsf + ysf; if (wi > 15) wi = 15;
                if (((ox.aweight0 >> (wi * 4)) & 0xF) == 0) sf = true;
            }
            if (xef || yef) {
                uint32_t wi = xef + yef; if (wi > 15) wi = 15;
                if (((ox.aweight1 >> (wi * 4)) & 0xF) == 0) sl = true;
            }
        }
        draw_line_bresenham(sf, sl);
    } else if (am == AM_SPAN) {
        draw_span_g();
    } else {
        draw_block_g();
    }
}

// ---- the oracle's register file -----------------------------------------
enum {
    R_DRAWMODE1 = 0x0000, R_DRAWMODE0 = 0x0004, R_LSMODE = 0x0008,
    R_LSPATTERN = 0x000C, R_ZPATTERN = 0x0014, R_COLORBACK = 0x0018,
    R_COLORVRAM = 0x001C, R_ALPHAREF = 0x0020, R_SMASK0X = 0x0028,
    R_SMASK0Y = 0x002C, R_SETUP = 0x0030,
    R_XSTART = 0x0100, R_YSTART = 0x0104, R_XEND = 0x0108, R_YEND = 0x010C,
    R_XYMOVE = 0x0114, R_BRESD = 0x0118, R_BRESOCTINC1 = 0x0120,
    R_BRESRNDINC2 = 0x0124,
    R_AWEIGHT0 = 0x0130, R_AWEIGHT1 = 0x0134,
    R_XSTARTF = 0x0138, R_YSTARTF = 0x013C, R_XENDF = 0x0140, R_YENDF = 0x0144,
    R_XSTARTI = 0x0148, R_XENDF1 = 0x014C, R_XYSTARTI = 0x0150,
    R_XYENDI = 0x0154,
    R_COLORRED = 0x0200, R_COLORALPHA = 0x0204, R_COLORGRN = 0x0208,
    R_COLORBLUE = 0x020C, R_SLOPERED = 0x0210, R_SLOPEALPHA = 0x0214,
    R_SLOPEGRN = 0x0218, R_SLOPEBLUE = 0x021C, R_WRMASK = 0x0220,
    R_COLORI = 0x0224,
    R_SMASK1X = 0x1300, R_SMASK1Y = 0x1304, R_SMASK2X = 0x1308,
    R_SMASK2Y = 0x130C, R_SMASK3X = 0x1310, R_SMASK3Y = 0x1314,
    R_SMASK4X = 0x1318, R_SMASK4Y = 0x131C,
    R_TOPSCAN = 0x1320, R_XYWIN = 0x1324, R_CLIPMODE = 0x1328,
};
static const uint32_t GO = 0x800;

static int32_t from_slope_n(uint32_t val, int nbits)
{
    uint32_t mag = val & ((1u << (nbits - 1)) - 1);
    if (mag == 0) return 0;
    uint32_t r = (val & 0x80000000u)
               ? (((1u << (nbits - 1)) - mag) | (1u << (nbits - 1)))
               : mag;
    // sign-extend from nbits
    int shift = 32 - nbits;
    return ((int32_t)(r << shift)) >> shift;
}

static void oracle_write(uint32_t off, uint32_t val)
{
    switch (off) {
    case R_DRAWMODE1: ox.drawmode1 = val; break;
    case R_DRAWMODE0: ox.drawmode0 = val; break;
    case R_LSMODE:    ox.lsmode = val & 0x0FFFFFFF; break;
    case R_LSPATTERN: ox.lspattern = val; break;
    // A WRITE RESTARTS THE Z PATTERN AT ITS MSB. DELIBERATE DIVERGENCE FROM
    // IRIS, which restarts it only on DOSETUP: the spec's pattern register is
    // "(msb = first pixel)", and every writer - X's glyph rows, GL's bitmaps,
    // polygon stipple, software-z line segments - loads a fresh word per GO
    // and means it from the top (docs/design/rex3-source-audit.md 4.2). np_rex3 does the same.
    case R_ZPATTERN:  ox.zpattern = val; ox.zpat_bit = 31; break;
    case R_COLORBACK: ox.colorback = val; break;
    case R_COLORVRAM: ox.colorvram = val; break;
    case R_ALPHAREF:  ox.alpharef = val & 0xFF; break;
    case R_SMASK0X:   ox.smask0x = val; break;
    case R_SMASK0Y:   ox.smask0y = val; break;
    case R_XYMOVE:    ox.xymove = val; break;
    case R_BRESD:        ox.bresd = val & 0x07FFFFFF; break;
    case R_BRESOCTINC1:  ox.bresoctinc1 = val & 0x070FFFFF; break;
    case R_BRESRNDINC2:  ox.bresrndinc2 = val & 0xFF1FFFFF; break;
    case R_AWEIGHT0:  ox.aweight0 = val; break;
    case R_AWEIGHT1:  ox.aweight1 = val; break;
    case R_XSTART:    ox.xstart = ox.xsave = (int32_t)(val & 0x07FFFF80); break;
    case R_YSTART:    ox.ystart = (int32_t)(val & 0x07FFFF80); break;
    case R_XEND:      ox.xend = (int32_t)(val & 0x07FFFF80); break;
    case R_YEND:      ox.yend = (int32_t)(val & 0x07FFFF80); break;
    case R_XSTARTI:   ox.xstart = ox.xsave = ((int32_t)(int16_t)val) << 11; break;
    // THE GL-FORMAT COORDINATES: "12.4(7) GL version of XSTART, (zeros 4
    // msbs)" - IRIS's from12_4_7 keeps bits 22:7 of what is really a float.
    // 0x14C is XENDF1, "Same as XENDF" - this bench used to decode it as an
    // integer, the same slip np_rex3 had (docs/design/rex3-source-audit.md 4.2).
    case R_XSTARTF:   ox.xstart = ox.xsave = (int32_t)(val & 0x007FFF80); break;
    case R_YSTARTF:   ox.ystart = (int32_t)(val & 0x007FFF80); break;
    case R_XENDF:
    case R_XENDF1:    ox.xend = (int32_t)(val & 0x007FFF80); break;
    case R_YENDF:     ox.yend = (int32_t)(val & 0x007FFF80); break;
    // SETUP: DOSETUP's derivation without the walk - IRIS's setup(), which is
    // what this bench's setup() transcribes.
    case R_SETUP:     setup(); break;
    case R_XYSTARTI:  ox.xstart = ox.xsave = ((int32_t)(int16_t)(val >> 16)) << 11;
                      ox.ystart = ((int32_t)(int16_t)val) << 11; break;
    case R_XYENDI:    ox.xend = ((int32_t)(int16_t)(val >> 16)) << 11;
                      ox.yend = ((int32_t)(int16_t)val) << 11; break;
    case R_COLORRED:  ox.colorred = (!dm1_rgbmode() && dm1_drawdepth() == 2)
                                  ? ((val << 2) & 0xFFFFFF) : (val & 0xFFFFFF); break;
    case R_COLORALPHA: ox.coloralpha = val & 0xFFFFF; break;
    case R_COLORGRN:  ox.colorgrn = val & 0xFFFFF; break;
    case R_COLORBLUE: ox.colorblue = val & 0xFFFFF; break;
    case R_SLOPERED:  ox.slopered = from_slope_n(val, 24); break;
    case R_SLOPEALPHA:ox.slopealpha = from_slope_n(val, 20); break;
    case R_SLOPEGRN:  ox.slopegrn = from_slope_n(val, 20); break;
    case R_SLOPEBLUE: ox.slopeblue = from_slope_n(val, 20); break;
    case R_WRMASK:    ox.wrmask = val & 0xFFFFFF; break;
    case R_COLORI:
        if (dm1_rgbmode()) {
            ox.colorred  = (val & 0xFF) << 11;
            ox.colorgrn  = ((val >> 8) & 0xFF) << 11;
            ox.colorblue = ((val >> 16) & 0xFF) << 11;
        } else {
            ox.colorred = val << 11;
        }
        break;
    case R_SMASK1X: ox.smask1x = val; break;
    case R_SMASK1Y: ox.smask1y = val; break;
    case R_SMASK2X: ox.smask2x = val; break;
    case R_SMASK2Y: ox.smask2y = val; break;
    case R_SMASK3X: ox.smask3x = val; break;
    case R_SMASK3Y: ox.smask3y = val; break;
    case R_SMASK4X: ox.smask4x = val; break;
    case R_SMASK4Y: ox.smask4y = val; break;
    case R_TOPSCAN: break;                    // the row wrap, not modelled
    case R_XYWIN:   ox.xywin = val; break;
    case R_CLIPMODE:ox.clipmode = val & 0x1FFF; break;
    default: break;
    }
}

// ==========================================================================
//  The device under test
// ==========================================================================
static Vnp_rex3 *dut;
static uint64_t clks = 0;
static int ack_delay = 2;
static int busy_left = 0;
static uint32_t busy_addr = 0;
static uint64_t busy_data = 0;
static bool busy_is_write = false;
static uint8_t busy_be = 0;

// np_rex3's frame buffer address: a 32-bit slot per pixel on the 2048 stride,
// two slots to a 64-bit word, the auxiliary planes 8 MB above the drawing
// ones. `rt_rgb`/`rt_aux` hold the slots; the port presents byte addresses.
static uint32_t *rt_slot(uint32_t byte_addr, bool *aux_out)
{
    bool aux = (byte_addr & 0x00800000u) != 0;
    uint32_t idx = (byte_addr & 0x007FFFFFu) >> 2;
    if (aux_out) *aux_out = aux;
    return &(aux ? rt_aux : rt_rgb)[idx];
}

static void rtl_touched(uint32_t idx);

static void bridge_before_edge()
{
    dut->fb_ack = 0;
    dut->fb_rdata = 0;

    auto commit = [&]() {
        uint32_t wa = busy_addr & ~7u;
        uint32_t *lo = rt_slot(wa, nullptr);
        uint32_t *hi = rt_slot(wa + 4, nullptr);
        uint64_t old = ((uint64_t)*hi << 32) | *lo;
        if (busy_is_write) {
            uint64_t val = 0;
            for (int k = 0; k < 8; k++) {
                bool en = (busy_be >> k) & 1;      // be[k] guards bits [8k+7:8k]
                uint64_t by = en ? ((busy_data >> (8 * k)) & 0xFF)
                                 : ((old >> (8 * k)) & 0xFF);
                val |= by << (8 * k);
            }
            *lo = (uint32_t)val;
            *hi = (uint32_t)(val >> 32);
            rtl_touched((busy_addr & 0x007FFFFFu) >> 2);
            if (trace_writes) {
                bool aux = (busy_addr & 0x00800000u) != 0;
                uint32_t idx = (busy_addr & 0x007FFFFFu) >> 2;
                rw.push_back({ idx, (uint32_t)((busy_addr & 4)
                                ? (val >> 32) : val) & 0xFFFFFF, aux });
            }
        } else {
            dut->fb_rdata = old;
        }
        dut->fb_ack = 1;
    };

    if (busy_left > 0) { if (--busy_left == 0) commit(); return; }
    if (dut->fb_req) {
        busy_addr = dut->fb_addr; busy_data = dut->fb_wdata;
        busy_be = dut->fb_be;     busy_is_write = dut->fb_we;
        if (ack_delay == 0) commit(); else busy_left = ack_delay;
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

static void rtl_write(uint32_t off, uint32_t val)
{
    dut->sel = 1; dut->we = 1; dut->off = off; dut->wdata = val; dut->be = 0xF;
    // The engine holds a write while a command runs; wait for the ack.
    int guard = 0;
    do { tick(); } while (!dut->ack && ++guard < 200000);
    dut->sel = 0; dut->we = 0;
    tick();
}

// ==========================================================================
//  The comparison
// ==========================================================================
// The RTL's writes join the oracle's in the touched list, so a pixel only one
// side drew is still compared. Both planes share the index.
static void rtl_touched(uint32_t idx) { touched.push_back(idx); }

struct Op { uint32_t off, val; };
static std::vector<Op> prog;

static void both(uint32_t off, uint32_t val)
{
    prog.push_back({ off, val });
    oracle_write(off & ~GO, val);
    rtl_write(off, val);
}

static uint64_t rng_state = 0x243F6A8885A308D3ull;
static uint32_t rnd()
{
    rng_state ^= rng_state << 13; rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return (uint32_t)(rng_state >> 32);
}
static uint32_t rnd_range(uint32_t n) { return rnd() % n; }

static int failures = 0, cases = 0, empty_cases = 0;
static uint64_t compared = 0;
static bool verbose = false;

// Every draw shape the corpus in iris/src/rex3_shaders.rs actually saw, as
// (DRAWMODE0, DRAWMODE1, CLIPMODE) - minus the host ones, which this bench
// does not model. Filled from the generated table by tools/rex3_corpus.py.
#include "rex3_corpus.h"

static void seed_framebuffers(uint32_t seed)
{
    rng_state = 0x9E3779B97F4A7C15ull ^ ((uint64_t)seed << 32) ^ seed;
    for (int i = 0; i < FBW * FBH; i++) {
        uint32_t rgb = rnd() & 0xFFFFFF;
        uint32_t aux = rnd() & 0xFFFFFF;
        fb_rgb[i] = rgb; fb_aux[i] = aux;
        // np_rex3 keeps a copy of the window-ID nibble in byte 3 of the
        // drawing slot so a CID-clipped draw costs one read, not two.
        rt_rgb[i] = rgb | ((aux & 0xF) << 24);
        rt_aux[i] = aux;
    }
}

static bool compare_and_report(const char *what)
{
    int bad = 0;
    for (size_t k = 0; k < touched.size(); k++) {
        uint32_t i = touched[k];
        if ((fb_rgb[i] & 0xFFFFFF) == (rt_rgb[i] & 0xFFFFFF)
         && (fb_aux[i] & 0xFFFFFF) == (rt_aux[i] & 0xFFFFFF)) continue;
        if (bad < 6)
            printf("    (%4u,%4u)  rgb oracle %06x rtl %06x | aux oracle %06x rtl %06x\n",
                   i % FBW, i / FBW, fb_rgb[i] & 0xFFFFFF, rt_rgb[i] & 0xFFFFFF,
                   fb_aux[i] & 0xFFFFFF, rt_aux[i] & 0xFFFFFF);
        bad++;
    }
    if (bad) {
        printf("  FAILED %s: %d of %d touched pixels differ\n",
               what, bad, (int)touched.size());
        printf("    program:");
        for (size_t i = 0; i < prog.size(); i++)
            printf(" %04x=%08x", prog[i].off, prog[i].val);
        printf("\n");
        if (trace_writes) {
            printf("    oracle wrote %d:", (int)ow.size());
            for (size_t i = 0; i < ow.size() && i < 24; i++)
                printf(" %s(%u,%u)=%06x", ow[i].aux ? "a" : "",
                       ow[i].idx % FBW, ow[i].idx / FBW, ow[i].val);
            printf("\n    rtl    wrote %d:", (int)rw.size());
            for (size_t i = 0; i < rw.size() && i < 24; i++)
                printf(" %s(%u,%u)=%06x", rw[i].aux ? "a" : "",
                       rw[i].idx % FBW, rw[i].idx / FBW, rw[i].val);
            printf("\n");
        }
        failures++;
        // Put both sides back on the RTL's values so one bad case does not
        // cascade into every case after it.
        for (size_t k = 0; k < touched.size(); k++) {
            uint32_t i = touched[k];
            fb_rgb[i] = rt_rgb[i] & 0xFFFFFF;
            fb_aux[i] = rt_aux[i] & 0xFFFFFF;
            rt_rgb[i] = fb_rgb[i] | ((fb_aux[i] & 0xF) << 24);
        }
        return false;
    }
    return true;
}

// One randomised primitive. `dm0`, `dm1` and `cm` come either from the corpus
// or from a random draw over the fields; everything else is random within the
// ranges the header promises.
static void run_case(uint32_t dm0, uint32_t dm1, uint32_t cm)
{
    prog.clear();
    touched.clear();
    ow.clear(); rw.clear();
    cases++;

    // Somewhere comfortably inside the frame buffer, with the 4096 bias.
    int x0 = 40 + rnd_range(200), y0 = 40 + rnd_range(200);
    int w  = 1 + rnd_range(40),   h  = 1 + rnd_range(20);
    int x1 = x0 + w, y1 = y0 + h;
    if (rnd() & 1) { int t = x0; x0 = x1; x1 = t; }       // right-to-left too
    if (rnd() & 1) { int t = y0; y0 = y1; y1 = t; }

    both(R_DRAWMODE1, dm1);
    both(R_TOPSCAN,   0x000003FF);
    both(R_XYWIN,     0x10001000);
    both(R_CLIPMODE,  cm);
    both(R_WRMASK,    (rnd() & 1) ? 0x00FFFFFF : (rnd() & 0x00FFFFFF));
    both(R_ZPATTERN,  rnd());
    both(R_LSPATTERN, rnd());
    both(R_LSMODE,    ((rnd_range(4)) << 24) | ((rnd_range(3)) << 8) | 0);
    both(R_COLORBACK, rnd());
    both(R_COLORVRAM, rnd());
    both(R_ALPHAREF,  rnd() & 0xFF);
    both(R_AWEIGHT0,  rnd());
    both(R_AWEIGHT1,  rnd());
    both(R_XYMOVE,    0);
    // SMASK0 IS WINDOW RELATIVE, which means relative to the walker's own
    // coordinate - and that carries the 4096 bias. A box written in unbiased
    // pixels clips every primitive away and the comparison then passes over
    // nothing at all, which is exactly how this bench first "passed".
    // THE WINDOW IS THE BIAS. XYWIN of 0x10001000 adds the 4096 that the
    // address calculation then takes away, so every coordinate below is a
    // plain pixel. SMASK0 is window relative and compares against those;
    // SMASK1-4 are screen absolute and the host pre-biases them, so they
    // compare against the coordinate plus 4096. Writing either in the other's
    // units clips every primitive away and the comparison then passes over
    // nothing at all - which is exactly how this bench first "passed".
    {
        int lo_x = (x0 < x1 ? x0 : x1) - 3;
        int hi_x = (x0 < x1 ? x1 : x0) + 3;
        int lo_y = (y0 < y1 ? y0 : y1) - 3;
        int hi_y = (y0 < y1 ? y1 : y0) + 3;
        both(R_SMASK0X, ((uint32_t)lo_x << 16) | (uint32_t)(hi_x & 0xFFFF));
        both(R_SMASK0Y, ((uint32_t)lo_y << 16) | (uint32_t)(hi_y & 0xFFFF));
    }
    for (int i = 0; i < 4; i++) {
        int lo_x = (x0 < x1 ? x0 : x1) + 0x1000 - 5 + i;
        int hi_x = (x0 < x1 ? x1 : x0) + 0x1000 + 5 - i;
        int lo_y = (y0 < y1 ? y0 : y1) + 0x1000 - 5 + i;
        int hi_y = (y0 < y1 ? y1 : y0) + 0x1000 + 5 - i;
        both(R_SMASK1X + 8 * i, ((uint32_t)lo_x << 16) | (uint32_t)(hi_x & 0xFFFF));
        both(R_SMASK1Y + 8 * i, ((uint32_t)lo_y << 16) | (uint32_t)(hi_y & 0xFFFF));
    }
    // Colours. COLORI writes the DDAs, so it goes after DRAWMODE1 and before
    // the slopes; a later COLORRED overrides the red one on purpose.
    both(R_COLORI,     rnd());
    both(R_COLORALPHA, rnd() & 0xFFFFF);
    if (rnd() & 1) both(R_COLORRED,  rnd() & 0xFFFFFF);
    if (rnd() & 1) both(R_COLORGRN,  rnd() & 0xFFFFF);
    if (rnd() & 1) both(R_COLORBLUE, rnd() & 0xFFFFF);
    // Slopes: small, signed, sign-magnitude on the bus.
    auto slope = [&]() -> uint32_t {
        uint32_t mag = rnd_range(0x800);
        return (rnd() & 1) ? (0x80000000u | mag) : mag;
    };
    both(R_SLOPERED,   slope());
    both(R_SLOPEGRN,   slope());
    both(R_SLOPEBLUE,  slope());
    both(R_SLOPEALPHA, slope());

    // THE BRESENHAM STATE IS WRITTEN, NOT INHERITED. A line GO without
    // DOSETUP walks on whatever these registers already hold, and leaving
    // that to whatever the previous case happened to leave behind makes one
    // failure cascade into every continuation after it. So the bench writes
    // the values DOSETUP would have derived - and sometimes lies about which
    // axis is major, which is what makes the continuation re-derive fire.
    {
        int adx = x1 > x0 ? x1 - x0 : x0 - x1;
        int ady = y1 > y0 ? y1 - y0 : y0 - y1;
        uint32_t octant = 0;
        if (y1 < y0) octant |= 1;
        if (x1 < x0) octant |= 2;
        if (adx > ady) octant |= 4;
        if (rnd_range(8) == 0) octant ^= 4;          // exercise the re-derive
        int major = adx > ady ? adx : ady;
        int minor = adx > ady ? ady : adx;
        both(R_BRESOCTINC1, (octant << 24) | ((uint32_t)(2 * minor) & 0xFFFFF));
        both(R_BRESRNDINC2, (uint32_t)(2 * (minor - major)) & 0x1FFFFF);
        both(R_BRESD,       (uint32_t)(2 * minor - major) & 0x7FFFFFF);
    }

    // SETUP INSTEAD OF DOSETUP, a quarter of the time: GL's glBitmap, IRIS
    // GL's lrectwrite and both libraries' depth lines write the endpoints,
    // write SETUP, and then GO without DOSETUP. The Bresenham registers get
    // deliberately WRONG values first, so only a SETUP that really derives
    // them can pass.
    uint32_t am = (dm0 >> 2) & 7;
    bool via_setup = (dm0 & (1u << 5)) && rnd_range(4) == 0;
    uint32_t dm0_go = via_setup ? (dm0 & ~(1u << 5)) : dm0;
    if (via_setup) {
        both(R_BRESOCTINC1, (rnd() & 0x070FFFFF));
        both(R_BRESRNDINC2, (rnd() & 0xFF1FFFFF));
        both(R_BRESD,       (rnd() & 0x07FFFFFF));
    }
    // GL writes its coordinates as the raw bits of the float 4096 + x, into
    // the GL-format registers (docs/design/rex3-source-audit.md 4.1): half the time the endpoints go
    // that way. The mantissa of 4096 + x + f/16 is exactly x.f in 12.11, and
    // XYWIN's 0x1000 puts the bias back as it does for the integer forms.
    bool via_float = rnd() & 1;
    auto glf = [](int px, uint32_t f16) -> uint32_t {
        float v = 4096.0f + (float)px + (float)f16 / 16.0f;
        uint32_t b; memcpy(&b, &v, 4); return b;
    };
    both(R_DRAWMODE0, dm0_go);
    both(R_XYSTARTI, ((uint32_t)x0 << 16) | (uint32_t)(y0 & 0xFFFF));
    // Fractional endpoints exist only for F_LINE and A_LINE; giving them to
    // everything else would move the integer coordinate the others read.
    uint32_t endgo = via_setup ? 0 : GO;
    if (am == AM_FLINE || am == AM_ALINE) {
        uint32_t f[4];
        for (int i = 0; i < 4; i++) f[i] = rnd() & 0xF;
        if (via_float) {
            both(R_XSTARTF, glf(x0, f[0]));
            both(R_YSTARTF, glf(y0, f[1]));
            both(R_XENDF,   glf(x1, f[2]));
            both(R_YENDF | endgo, glf(y1, f[3]));
        } else {
            both(R_XSTART, (((uint32_t)x0 << 11) | (f[0] << 7)) & 0x07FFFF80);
            both(R_YSTART, (((uint32_t)y0 << 11) | (f[1] << 7)) & 0x07FFFF80);
            both(R_XEND,   (((uint32_t)x1 << 11) | (f[2] << 7)) & 0x07FFFF80);
            both(R_YEND | endgo, (((uint32_t)y1 << 11) | (f[3] << 7)) & 0x07FFFF80);
        }
    } else if (am == AM_SPAN && via_float) {
        // IRIS GL's polygon span: XSTARTI and XENDF1, the end as a float.
        both(R_XENDF1 | endgo, glf(x1, 0));
    } else {
        both(R_XYENDI | endgo,
             ((uint32_t)x1 << 16) | (uint32_t)(y1 & 0xFFFF));
    }
    if (via_setup) {
        both(R_SETUP, 0);
        both(R_DRAWMODE0 | GO, dm0_go);
    }

    oracle_go();

    uint64_t start = clks;
    while (dut->gfx_busy && clks - start < 4000000) tick();
    for (int i = 0; i < 8; i++) tick();
    if (dut->gfx_busy) {
        printf("  FAILED engine never returned to idle "
               "(dm0=%08x dm1=%08x cm=%08x)\n", dm0, dm1, cm);
        failures++;
        return;
    }

    compared += touched.size();
    if (touched.empty()) empty_cases++;

    char name[128];
    snprintf(name, sizeof name, "dm0=%08x dm1=%08x cm=%08x", dm0, dm1, cm);
    bool ok = compare_and_report(name);
    if (verbose && ok) printf("  ok      %s\n", name);
}

// A dm0/dm1/clipmode drawn from the fields rather than the corpus, so the
// bench reaches combinations no IRIX program has happened to ask for.
static void random_shape(uint32_t *dm0, uint32_t *dm1, uint32_t *cm)
{
    static const uint32_t AM[5] = { AM_SPAN, AM_BLOCK, AM_ILINE, AM_FLINE, AM_ALINE };
    uint32_t opcode = (rnd_range(8) == 0) ? OP_SCR2SCR : OP_DRAW;
    uint32_t am = AM[rnd_range(5)];
    *dm0 = opcode | (am << 2)
         | (1u << 5)                             // DOSETUP
         | ((rnd_range(4) != 0) ? (1u << 8) : 0) // STOPONX
         | ((rnd_range(3) != 0) ? (1u << 9) : 0) // STOPONY
         // SKIPFIRST IS LEFT OFF FOR A BLOCK. IRIS's block walker sets its
         // `first` flag at the start of every row and never clears it, so a
         // block under SKIPFIRST draws no pixels at all - while its span and
         // line walkers both clear the flag after the first pixel. No shape
         // in the corpus sets SKIPFIRST at any address mode, so that arm of
         // IRIS has never run against real software; np_rex3 reads the bit as
         // "the first pixel of each row", which is what makes it useful to a
         // polygon rasteriser and what the other two walkers already do.
         | ((rnd_range(8) == 0 && am != AM_BLOCK) ? (1u << 10) : 0)
         | ((rnd_range(8) == 0) ? (1u << 11) : 0)
         | ((rnd_range(3) == 0) ? (1u << 12) : 0) // ENZPATTERN
         | ((rnd_range(3) == 0) ? (1u << 13) : 0) // ENLSPATTERN
         | ((rnd_range(4) == 0) ? (1u << 14) : 0) // LSADVLAST
         | ((rnd_range(6) == 0) ? (1u << 15) : 0) // LENGTH32
         | ((rnd_range(6) == 0) ? (1u << 16) : 0) // ZPOPAQUE
         | ((rnd_range(6) == 0) ? (1u << 17) : 0) // LSOPAQUE
         | ((rnd_range(2) == 0) ? (1u << 18) : 0) // SHADE
         | ((rnd_range(5) == 0) ? (1u << 19) : 0) // LRONLY
         | ((rnd_range(6) == 0) ? (1u << 20) : 0) // XYOFFSET
         | ((rnd_range(2) == 0) ? (1u << 21) : 0) // CICLAMP
         | ((rnd_range(3) == 0) ? (1u << 22) : 0) // ENDPTFILTER
         | ((rnd_range(6) == 0) ? (1u << 23) : 0);// YSTRIDE
    static const uint32_t PL[5] = { 0, 1, 4, 5, 6 };
    uint32_t planes = PL[rnd_range(5)];
    uint32_t depth = rnd_range(4);
    uint32_t compare = (rnd_range(3) == 0) ? rnd_range(8) : 7;
    *dm1 = planes | (depth << 3)
         | ((rnd_range(3) == 0) ? (1u << 5) : 0)  // DBLSRC
         | (compare << 12)
         | ((rnd_range(2) == 0) ? (1u << 15) : 0) // RGBMODE
         | ((rnd_range(2) == 0) ? (1u << 16) : 0) // DITHER
         | ((rnd_range(8) == 0) ? (1u << 17) : 0) // FASTCLEAR
         | ((rnd_range(3) == 0) ? (1u << 18) : 0) // BLEND
         | (rnd_range(6) << 19)                   // SFACTOR
         | (rnd_range(6) << 22)                   // DFACTOR
         | ((rnd_range(6) == 0) ? (1u << 25) : 0) // BACKBLEND
         | ((rnd_range(2) == 0) ? (1u << 27) : 0) // BLENDALPHA
         | (rnd_range(16) << 28);                 // LOGICOP
    uint32_t ensm = rnd_range(4) == 0 ? (rnd_range(32)) : 0;
    uint32_t cidm = rnd_range(3) == 0 ? rnd_range(16) : 0xF;
    *cm = ensm | (cidm << 9);
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    int n_cases = 4000;
    uint32_t seed = 1;
    if (const char *e = getenv("REX3D_CASES"))   n_cases = atoi(e);
    if (const char *e = getenv("REX3D_SEED"))    seed = (uint32_t)atoi(e);
    if (const char *e = getenv("REX3D_ACK"))     ack_delay = atoi(e);
    if (getenv("REX3D_VERBOSE"))                 verbose = true;
    if (getenv("REX3D_TRACE"))                   trace_writes = true;

    fb_rgb = (uint32_t *)calloc((size_t)FBW * FBH, 4);
    fb_aux = (uint32_t *)calloc((size_t)FBW * FBH, 4);
    rt_rgb = (uint32_t *)calloc((size_t)FBW * FBH, 4);
    rt_aux = (uint32_t *)calloc((size_t)FBW * FBH, 4);

    dut = new Vnp_rex3;
    dut->reset = 1; dut->clk = 0;
    dut->sel = 0; dut->we = 0; dut->off = 0; dut->wdata = 0; dut->be = 0;
    dut->fb_ack = 0; dut->fb_rdata = 0; dut->vert_int = 0; dut->dcb_rdata = 0;
    dut->nd_req = 0; dut->nd_we = 0; dut->nd_off = 0; dut->nd_wdata = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    tick();

    seed_framebuffers(seed);

    printf("tb_rex3draw: np_rex3 against IRIS's rex3_generic, "
           "%d corpus shapes + %d random cases, ack delay %d\n",
           (int)REX3_CORPUS_N, n_cases, ack_delay);

    // The corpus first: every non-host draw shape a real IRIX desktop asked
    // for. These are the ones that have to work.
    for (size_t i = 0; i < REX3_CORPUS_N; i++)
        run_case(REX3_CORPUS[i][0], REX3_CORPUS[i][1], REX3_CORPUS[i][2]);
    int corpus_failures = failures;
    printf("  corpus: %d shapes, %d failed\n", (int)REX3_CORPUS_N, corpus_failures);

    // Then the field-level random walk, which reaches shapes nothing has
    // asked for yet.
    for (int i = 0; i < n_cases; i++) {
        uint32_t dm0, dm1, cm;
        random_shape(&dm0, &dm1, &cm);
        run_case(dm0, dm1, cm);
    }

    printf("  %d cases, %d failed, %llu pixel writes compared, "
           "%d cases wrote nothing, %llu clocks\n",
           cases, failures, (unsigned long long)compared, empty_cases,
           (unsigned long long)clks);
    printf("tb_rex3draw: %s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
