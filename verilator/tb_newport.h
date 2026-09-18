//============================================================================
//  tb_newport.h - the Newport board as the CPU and the MC's DMA engine see
//  it, and a frame buffer behind it. Shared by tb_newport.cpp (the directed
//  tests, `make newporttest`) and tb_newport_replay.cpp (the RX3TRACE
//  replay, `make newportreplay`).
//
//  WHY A NEWPORT-LEVEL BENCH. tb_rex3.cpp and tb_rex3draw.cpp drive np_rex3
//  through its own 32-bit register port, and that port is downstream of the
//  bug docs/design/rex3-source-audit.md found first: newport.sv turns the CPU's doubleword into ONE
//  register write (3.1, 4.4). Nothing reached newport.sv's bus handling
//  until this - so everything here drives the top-level ports with the
//  exact transaction shapes the rest of the machine produces.
//
//  THE CPU'S BUS (rtl/cpu/r4300_bus.sv, whose header is the contract):
//    `sel`    a one-cycle pulse;
//    `we`, `addr[19:0]` (offset in the 1 MB GIO window, doubleword aligned -
//             REX3's registers are at 0xF0000 + offset, the GO alias adds
//             0x800), `aoff[2:0]` (the access's byte offset within the
//             doubleword), `be[7:0]`, `wdata[63:0]` - held until `ack`.
//    Big-endian: wdata[63-8i -: 8] is the byte at doubleword address + i,
//    guarded by be[7-i]. A 32-bit store to register R: aoff = R & 7, be =
//    (R & 4) ? 0x0F : 0xF0, the value in wdata[63:32] (R & 4 == 0) or
//    [31:0]. The OTHER half carries whatever the other half of the 64-bit
//    GPR held (cpu.vhd's rotatedData) - so this bench fills it with the
//    complement of the value, and a core that reads the wrong half fails.
//    A 64-bit store (sd/sdc1) to 8-aligned R: aoff 0, be 0xFF, wdata =
//    {word for R, word for R + 4}. Loads: the same addr/aoff, be left at
//    whatever the last store set (cpu.vhd does the same); the 32-bit result
//    is rdata[63:32] if aoff[2] == 0 else rdata[31:0].
//    The next request comes no sooner than two clocks after the ack
//    (r4300_bus: ack -> mem_done -> next mem_request -> bus_req).
//
//  THE MC's VDMA BEATS (rtl/sgi/mc_gio_dma.sv via sgi_indy.sv): `nd_req`
//  held until `nd_ack`, `nd_we`, `nd_addr[19:0]` = 0xF0000 + offset (the
//  kernel's Ng1PixelDma also puts the host buffer's start byte in bits 2:0),
//  `nd_wdata[63:0]`, `nd_rdata`.
//
//  THE FRAME BUFFER (np_rex3.sv's frame buffer notes): 16 MB, two plane
//  sets of 2048 x 1024 32-bit slots - the drawing planes at FB_BASE (0), the
//  auxiliary planes 8 MB above them - two slots to a 64-bit word, the even
//  pixel in the low half. REX3's random port `fbw_*` presents a SLOT's byte
//  address (4-aligned, not 8: docs memory "sim memory lane alignment") and
//  picks its half with the byte enables, be[k] guarding bits [8k+7:8k]. It
//  is request-held-until-ack, one transaction at a time, `fb_lat` cycles
//  each (0 = acknowledged in the cycle the request is first seen). The
//  display's two ports `fbr_*`/`fba_*` are answered one cycle after the
//  request, as newport.sv expects.
//
//  Stored as 2M host uint64_t words, so on a little-endian host the raw
//  bytes of the drawing half ARE IRIS's fb_rgb layout (u32 slot per pixel,
//  pixel (x, y) at y * 2048 + x) and the second half is fb_aux.
//============================================================================
#pragma once

#include "Vnewport.h"
#include "verilated.h"

#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace np {

// ---- REX3's register offsets (np_rex3.sv, the REX3 specification) ---------
enum : uint32_t {
    R_DRAWMODE1 = 0x0000, R_DRAWMODE0 = 0x0004, R_LSMODE = 0x0008,
    R_LSPATTERN = 0x000C, R_LSPATSAVE = 0x0010, R_ZPATTERN = 0x0014,
    R_COLORBACK = 0x0018, R_COLORVRAM = 0x001C, R_ALPHAREF = 0x0020,
    R_STALL0 = 0x0024, R_SMASK0X = 0x0028, R_SMASK0Y = 0x002C,
    R_SETUP = 0x0030, R_STEPZ = 0x0034, R_LSRESTORE = 0x0038, R_LSSAVE = 0x003C,
    R_XSTART = 0x0100, R_YSTART = 0x0104, R_XEND = 0x0108, R_YEND = 0x010C,
    R_XSAVE = 0x0110, R_XYMOVE = 0x0114, R_BRESD = 0x0118, R_BRESS1 = 0x011C,
    R_BRESOCTINC1 = 0x0120, R_BRESRNDINC2 = 0x0124, R_BRESE1 = 0x0128,
    R_BRESS2 = 0x012C, R_AWEIGHT0 = 0x0130, R_AWEIGHT1 = 0x0134,
    R_XSTARTF = 0x0138, R_YSTARTF = 0x013C, R_XENDF = 0x0140, R_YENDF = 0x0144,
    R_XSTARTI = 0x0148, R_XENDF1 = 0x014C, R_XYSTARTI = 0x0150,
    R_XYENDI = 0x0154, R_XSTARTENDI = 0x0158,
    R_COLORRED = 0x0200, R_COLORALPHA = 0x0204, R_COLORGRN = 0x0208,
    R_COLORBLUE = 0x020C, R_SLOPERED = 0x0210, R_SLOPEALPHA = 0x0214,
    R_SLOPEGRN = 0x0218, R_SLOPEBLUE = 0x021C, R_WRMASK = 0x0220,
    R_COLORI = 0x0224, R_COLORX = 0x0228, R_SLOPERED1 = 0x022C,
    R_HOSTRW0 = 0x0230, R_HOSTRW1 = 0x0234, R_DCBMODE = 0x0238,
    R_DCBDATA0 = 0x0240, R_DCBDATA1 = 0x0244,
    R_SMASK1X = 0x1300, R_SMASK1Y = 0x1304, R_SMASK2X = 0x1308,
    R_SMASK2Y = 0x130C, R_SMASK3X = 0x1310, R_SMASK3Y = 0x1314,
    R_SMASK4X = 0x1318, R_SMASK4Y = 0x131C, R_TOPSCAN = 0x1320,
    R_XYWIN = 0x1324, R_CLIPMODE = 0x1328, R_STALL1 = 0x132C,
    R_CONFIG = 0x1330, R_STATUS = 0x1338, R_USERSTATUS = 0x133C,
    R_DCBRESET = 0x1340,
};
static const uint32_t GO        = 0x0800;     // the GO alias
static const uint32_t REX3_BASE = 0xF0000;    // REX3 in the 1 MB GIO window

// STATUS / USER_STATUS bits (np_rex3.sv's status_val).
static const uint32_t ST_GFXBUSY  = 1u << 3;
static const uint32_t ST_BACKBUSY = 1u << 4;

// ---- DRAWMODE0 ---------------------------------------------------------------
enum : uint32_t {
    DM0_NOOP = 0, DM0_READ = 1, DM0_DRAW = 2, DM0_SCR2SCR = 3,
    DM0_SPAN = 0u << 2, DM0_BLOCK = 1u << 2, DM0_ILINE = 2u << 2,
    DM0_FLINE = 3u << 2, DM0_ALINE = 4u << 2,
    DM0_DOSETUP = 1u << 5, DM0_COLORHOST = 1u << 6, DM0_ALPHAHOST = 1u << 7,
    DM0_STOPONX = 1u << 8, DM0_STOPONY = 1u << 9,
    DM0_SKIPFIRST = 1u << 10, DM0_SKIPLAST = 1u << 11,
    DM0_ENZPATTERN = 1u << 12, DM0_ENLSPATTERN = 1u << 13,
    DM0_LENGTH32 = 1u << 15, DM0_SHADE = 1u << 18,
};
// ---- DRAWMODE1 ---------------------------------------------------------------
enum : uint32_t {
    DM1_PLANES_RGB = 1,                               // the drawing planes
    DM1_DEPTH8 = 1u << 3, DM1_DEPTH12 = 2u << 3, DM1_DEPTH24 = 3u << 3,
    DM1_DBLSRC = 1u << 5, DM1_RWPACKED = 1u << 7,
    DM1_HD8 = 1u << 8, DM1_HD12 = 2u << 8, DM1_HD32 = 3u << 8,
    DM1_RWDOUBLE = 1u << 10, DM1_SWAPENDIAN = 1u << 11,
    DM1_COMPARE_OFF = 7u << 12,                       // alpha function: always pass
    DM1_RGBMODE = 1u << 15,
    DM1_LO_SRC = 3u << 28,                            // logic op SRC
};

// Register names, for reports. `reg` without the GO bit.
inline const char *reg_name(uint32_t reg)
{
    switch (reg & ~GO & 0x1FFF) {
    case R_DRAWMODE1: return "DRAWMODE1";   case R_DRAWMODE0: return "DRAWMODE0";
    case R_LSMODE: return "LSMODE";         case R_LSPATTERN: return "LSPATTERN";
    case R_LSPATSAVE: return "LSPATSAVE";   case R_ZPATTERN: return "ZPATTERN";
    case R_COLORBACK: return "COLORBACK";   case R_COLORVRAM: return "COLORVRAM";
    case R_ALPHAREF: return "ALPHAREF";     case R_STALL0: return "STALL0";
    case R_SMASK0X: return "SMASK0X";       case R_SMASK0Y: return "SMASK0Y";
    case R_SETUP: return "SETUP";           case R_STEPZ: return "STEPZ";
    case R_LSRESTORE: return "LSRESTORE";   case R_LSSAVE: return "LSSAVE";
    case R_XSTART: return "XSTART";         case R_YSTART: return "YSTART";
    case R_XEND: return "XEND";             case R_YEND: return "YEND";
    case R_XSAVE: return "XSAVE";           case R_XYMOVE: return "XYMOVE";
    case R_BRESD: return "BRESD";           case R_BRESS1: return "BRESS1";
    case R_BRESOCTINC1: return "BRESOCTINC1"; case R_BRESRNDINC2: return "BRESRNDINC2";
    case R_BRESE1: return "BRESE1";         case R_BRESS2: return "BRESS2";
    case R_AWEIGHT0: return "AWEIGHT0";     case R_AWEIGHT1: return "AWEIGHT1";
    case R_XSTARTF: return "XSTARTF";       case R_YSTARTF: return "YSTARTF";
    case R_XENDF: return "XENDF";           case R_YENDF: return "YENDF";
    case R_XSTARTI: return "XSTARTI";       case R_XENDF1: return "XENDF1";
    case R_XYSTARTI: return "XYSTARTI";     case R_XYENDI: return "XYENDI";
    case R_XSTARTENDI: return "XSTARTENDI";
    case R_COLORRED: return "COLORRED";     case R_COLORALPHA: return "COLORALPHA";
    case R_COLORGRN: return "COLORGRN";     case R_COLORBLUE: return "COLORBLUE";
    case R_SLOPERED: return "SLOPERED";     case R_SLOPEALPHA: return "SLOPEALPHA";
    case R_SLOPEGRN: return "SLOPEGRN";     case R_SLOPEBLUE: return "SLOPEBLUE";
    case R_WRMASK: return "WRMASK";         case R_COLORI: return "COLORI";
    case R_COLORX: return "COLORX";         case R_SLOPERED1: return "SLOPERED1";
    case R_HOSTRW0: return "HOSTRW0";       case R_HOSTRW1: return "HOSTRW1";
    case R_DCBMODE: return "DCBMODE";       case R_DCBDATA0: return "DCBDATA0";
    case R_DCBDATA1: return "DCBDATA1";
    case R_SMASK1X: return "SMASK1X";       case R_SMASK1Y: return "SMASK1Y";
    case R_SMASK2X: return "SMASK2X";       case R_SMASK2Y: return "SMASK2Y";
    case R_SMASK3X: return "SMASK3X";       case R_SMASK3Y: return "SMASK3Y";
    case R_SMASK4X: return "SMASK4X";       case R_SMASK4Y: return "SMASK4Y";
    case R_TOPSCAN: return "TOPSCAN";       case R_XYWIN: return "XYWIN";
    case R_CLIPMODE: return "CLIPMODE";     case R_STALL1: return "STALL1";
    case R_CONFIG: return "CONFIG";         case R_STATUS: return "STATUS";
    case R_USERSTATUS: return "USER_STATUS"; case R_DCBRESET: return "DCBRESET";
    default: return "?";
    }
}

inline std::string strf(const char *fmt, ...)
{
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    return buf;
}

//============================================================================
//  The harness
//============================================================================
class Harness {
public:
    static const uint32_t FB_WORDS   = 2u << 20;     // 16 MB of 64-bit words
    static const uint32_t PLANE_WORDS = 1u << 20;    // one plane set, 8 MB
    static const uint32_t AUX_OFF    = 0x00800000;   // auxiliary planes, bytes
    static const int      FB_W = 2048, FB_H = 1024;
    static constexpr uint64_t POISON = 0xDEADBEEFCAFEF00DULL;

    Vnewport *dut = nullptr;
    uint64_t  cyc = 0;
    std::vector<uint64_t> fb;

    // Knobs.
    int      fb_lat   = 1;            // cycles per random-port transaction
    int      bus_gap  = 2;            // idle clocks before every bus request
    uint64_t timeout  = 200000000ull; // clocks one transaction may take

    // What happened.
    bool     timed_out  = false;
    uint64_t last_lat   = 0;          // clocks from request to ack, last transaction
    uint32_t last_ack_nd = 0;         // dbg_nd in the ack cycle, last transaction
    uint64_t fbw_reads = 0, fbw_writes = 0, fbw_proto = 0, fb_oob = 0;
    uint64_t disp_reads = 0;
    uint64_t bus_xfers = 0, dma_xfers = 0;

    Harness(int argc, char **argv)
    {
        Verilated::commandArgs(argc, argv);
        dut = new Vnewport;
        fb.assign(FB_WORDS, 0);
        for (int b = 0; b < 256; b++) {
            uint64_t m = 0;
            for (int k = 0; k < 8; k++)
                if ((b >> k) & 1) m |= 0xFFull << (8 * k);
            be_mask_[b] = m;
        }
        dut->clk = 0; dut->reset = 1;
        dut->sel = 0; dut->we = 0; dut->addr = 0; dut->aoff = 0; dut->be = 0;
        dut->wdata = 0;
        dut->nd_req = 0; dut->nd_we = 0; dut->nd_addr = 0; dut->nd_wdata = 0;
        dut->fbw_rdata = 0; dut->fbw_ack = 0;
        dut->fbr_rdata = 0; dut->fbr_ack = 0;
        dut->fba_rdata = 0; dut->fba_ack = 0;
        dut->dbg_raw_index = 0;
        dut->eval();
    }
    ~Harness() { dut->final(); delete dut; }

    void reset(int cycles = 16)
    {
        dut->sel = 0; dut->nd_req = 0;
        dut->reset = 1;
        for (int i = 0; i < cycles; i++) tick();
        dut->reset = 0;
        fb_left_ = -1; fbr_pend_ = fba_pend_ = false;
        for (int i = 0; i < 4; i++) tick();
        timed_out = false;
    }

    // ---- one clock ------------------------------------------------------------
    void tick()
    {
        // REX3's random port: one transaction at a time, fb_lat clocks each.
        dut->fbw_ack   = 0;
        dut->fbw_rdata = POISON;          // garbage unless acknowledged
        if (fb_left_ < 0 && dut->fbw_req) {
            t_addr_ = dut->fbw_addr; t_we_ = dut->fbw_we;
            t_be_ = dut->fbw_be;     t_wdata_ = dut->fbw_wdata;
            fb_left_ = fb_lat;
        }
        if (fb_left_ == 0) {
            // The request must still be there, unchanged, when it is answered.
            if (!dut->fbw_req || dut->fbw_addr != t_addr_ || dut->fbw_we != t_we_)
                fbw_proto++;
            uint64_t &w = word(t_addr_);
            if (t_we_) {
                uint64_t m = be_mask_[t_be_];
                w = (w & ~m) | (t_wdata_ & m);
                fbw_writes++;
            } else {
                dut->fbw_rdata = w;
                fbw_reads++;
            }
            dut->fbw_ack = 1;
            fb_left_ = -1;
        } else if (fb_left_ > 0) {
            fb_left_--;
        }

        // The display's serial ports: last clock's requests, answered now.
        dut->fbr_ack = fbr_pend_;
        if (fbr_pend_) { dut->fbr_rdata = word_wrap(fbr_a_); disp_reads++; }
        dut->fba_ack = fba_pend_;
        if (fba_pend_) { dut->fba_rdata = word_wrap(fba_a_); disp_reads++; }
        fbr_pend_ = dut->fbr_req; fbr_a_ = dut->fbr_addr;
        fba_pend_ = dut->fba_req; fba_a_ = dut->fba_addr;

        // Two evaluations a clock. Verilator settles logic fed by changed
        // inputs before it runs the edge, so the extra eval() tb_rex3.cpp
        // does here changes nothing: built both ways, the directed tests at
        // latencies 0, 1, 4 and 20 and two replays came out identical, and
        // this way is ~15% faster. -DNP_PRE_EDGE_EVAL puts it back.
#ifdef NP_PRE_EDGE_EVAL
        dut->eval();
#endif
        dut->clk = 1; dut->eval();
        dut->clk = 0; dut->eval();
        cyc++;
    }
    void ticks(uint64_t n) { while (n--) tick(); }

    // ---- the CPU's bus --------------------------------------------------------
    // `off` is the byte offset in REX3's 8 KB window as the CPU addresses it,
    // GO alias included.
    bool wr32(uint32_t off, uint32_t v)
    {
        bool lo = (off & 4) != 0;
        uint64_t other = (uint64_t)(~v);          // the GPR's other half
        uint64_t wd = lo ? ((other << 32) | v) : (((uint64_t)v << 32) | (other & 0xFFFFFFFFull));
        return bus(true, REX3_BASE + (off & ~7u), off & 7, lo ? 0x0F : 0xF0, wd, nullptr);
    }
    bool wr64(uint32_t off, uint64_t v)
    {
        return bus(true, REX3_BASE + (off & ~7u), 0, 0xFF, v, nullptr);
    }
    // A byte or halfword store, as addressed (the DCBDATA ports).
    bool wr_sub(uint32_t off, int bytes, uint32_t v)
    {
        int i = off & 7;
        uint8_t be = 0;
        uint64_t wd = 0;
        for (int k = 0; k < bytes && i + k < 8; k++) {
            uint64_t by = (v >> (8 * (bytes - 1 - k))) & 0xFF;
            wd |= by << (56 - 8 * (i + k));
            be |= (uint8_t)(1u << (7 - (i + k)));
        }
        return bus(true, REX3_BASE + (off & ~7u), i, be, wd, nullptr);
    }
    bool rd32(uint32_t off, uint32_t &v)
    {
        uint64_t r = 0;
        bool ok = bus(false, REX3_BASE + (off & ~7u), off & 7, last_be_, 0, &r);
        v = (off & 4) ? (uint32_t)r : (uint32_t)(r >> 32);
        return ok;
    }
    bool rd64(uint32_t off, uint64_t &v)
    {
        return bus(false, REX3_BASE + (off & ~7u), 0, last_be_, 0, &v);
    }
    bool rd_sub(uint32_t off, int bytes, uint32_t &v)
    {
        uint64_t r = 0;
        bool ok = bus(false, REX3_BASE + (off & ~7u), off & 7, last_be_, 0, &r);
        int i = off & 7;
        v = 0;
        for (int k = 0; k < bytes && i + k < 8; k++)
            v = (v << 8) | (uint32_t)((r >> (56 - 8 * (i + k))) & 0xFF);
        return ok;
    }

    // ---- the MC's VDMA beats ----------------------------------------------------
    // `off` as the DMA engine addresses it: GO alias and start byte included.
    bool dma_wr(uint32_t off, uint64_t v) { return dma(true, REX3_BASE + off, v, nullptr); }
    bool dma_rd(uint32_t off, uint64_t &v) { return dma(false, REX3_BASE + off, 0, &v); }

    // ---- engine state -------------------------------------------------------------
    // np_rex3's dbg_nd: {write beats[15:0], read beats[7:0], drops[3:0],
    // VDMA read waiting, engine_busy, go_pending, wr_held}.
    uint32_t dbg_nd() const { return dut->dbg_nd; }
    bool engine_idle() const { return (dut->dbg_nd & 0xF) == 0; }
    // Clock until np_rex3 reports nothing running, pending or held.
    bool wait_idle(uint64_t max = 400000000ull)
    {
        for (uint64_t n = 0; n < max; n++) {
            if (engine_idle()) return true;
            tick();
        }
        return false;
    }
    // REX3WAIT, as the PROM and the kernel spell it: poll USER_STATUS until
    // neither the graphics nor the back end is busy.
    bool rex3wait(uint64_t max_polls = 50000000ull)
    {
        for (uint64_t n = 0; n < max_polls; n++) {
            uint32_t st = 0;
            if (!rd32(R_USERSTATUS, st)) return false;
            if (!(st & (ST_GFXBUSY | ST_BACKBUSY))) return true;
        }
        return false;
    }

    // ---- the frame buffer ---------------------------------------------------------
    uint32_t slot(int x, int y, bool aux) const
    {
        uint32_t a = (aux ? AUX_OFF : 0) + ((((uint32_t)y << 11) + (uint32_t)x) << 2);
        uint64_t w = fb[(a & 0xFFFFFF) >> 3];
        return (x & 1) ? (uint32_t)(w >> 32) : (uint32_t)w;
    }
    void set_slot(int x, int y, bool aux, uint32_t s)
    {
        uint32_t a = (aux ? AUX_OFF : 0) + ((((uint32_t)y << 11) + (uint32_t)x) << 2);
        uint64_t &w = fb[(a & 0xFFFFFF) >> 3];
        if (x & 1) w = (w & 0x00000000FFFFFFFFull) | ((uint64_t)s << 32);
        else       w = (w & 0xFFFFFFFF00000000ull) | (uint64_t)s;
    }
    void clear_fb() { std::fill(fb.begin(), fb.end(), 0); }

    // Both plane sets, 2048 x 1024 u32 little-endian each: IRIS's fb_rgb and
    // fb_aux layout, pixel (x, y) at y * 2048 + x.
    bool dump(const std::string &rgb_path, const std::string &aux_path) const
    {
        return dump_plane(rgb_path, 0) && dump_plane(aux_path, PLANE_WORDS);
    }
    bool dump_plane(const std::string &path, uint32_t first_word) const
    {
        FILE *f = fopen(path.c_str(), "wb");
        if (!f) { fprintf(stderr, "cannot write %s\n", path.c_str()); return false; }
        bool ok = true;
        std::vector<uint8_t> buf(1 << 16);
        for (uint32_t w = 0; w < PLANE_WORDS && ok; w += 8192) {
            for (int k = 0; k < 8192; k++) {
                uint64_t v = fb[first_word + w + k];
                for (int b = 0; b < 8; b++) buf[8 * k + b] = (uint8_t)(v >> (8 * b));
            }
            ok = fwrite(buf.data(), 1, buf.size(), f) == buf.size();
        }
        fclose(f);
        return ok;
    }

private:
    uint64_t be_mask_[256];
    int      fb_left_ = -1;
    uint32_t t_addr_ = 0;
    uint64_t t_wdata_ = 0;
    uint8_t  t_be_ = 0;
    bool     t_we_ = false;
    bool     fbr_pend_ = false, fba_pend_ = false;
    uint32_t fbr_a_ = 0, fba_a_ = 0;
    uint8_t  last_be_ = 0;

    uint64_t &word(uint32_t a)
    {
        if (a >= 0x01000000u) fb_oob++;
        return fb[(a & 0xFFFFFF) >> 3];
    }
    uint64_t word_wrap(uint32_t a) const { return fb[(a & 0xFFFFFF) >> 3]; }

    bool bus(bool we, uint32_t addr, uint32_t aoff, uint8_t be, uint64_t wdata,
             uint64_t *rdata)
    {
        for (int i = 0; i < bus_gap; i++) tick();
        dut->sel = 1; dut->we = we; dut->addr = addr & 0xFFFFF;
        dut->aoff = aoff & 7; dut->be = be; dut->wdata = wdata;
        if (we) last_be_ = be;
        tick();
        dut->sel = 0;              // a pulse; the rest is held until the ack
        uint64_t n = 1;
        while (!dut->ack) {
            if (n >= timeout) { timed_out = true; last_lat = n; return false; }
            tick();
            n++;
        }
        last_lat = n;
        last_ack_nd = dut->dbg_nd;
        if (rdata) *rdata = dut->rdata;
        bus_xfers++;
        return true;
    }

    bool dma(bool we, uint32_t addr, uint64_t wdata, uint64_t *rdata)
    {
        for (int i = 0; i < bus_gap; i++) tick();
        dut->nd_req = 1; dut->nd_we = we; dut->nd_addr = addr & 0xFFFFF;
        dut->nd_wdata = wdata;
        uint64_t n = 0;
        do {
            tick();
            n++;
            if (!dut->nd_ack && n >= timeout) {
                dut->nd_req = 0; timed_out = true; last_lat = n;
                return false;
            }
        } while (!dut->nd_ack);
        last_lat = n;
        last_ack_nd = dut->dbg_nd;
        if (rdata) *rdata = dut->nd_rdata;
        dut->nd_req = 0;           // held until the ack, and no longer
        dma_xfers++;
        return true;
    }
};

}  // namespace np
