//============================================================================
//  tb_newport_replay - a REX3 bus trace captured from IRIS, replayed through
//  newport.sv, and the frame buffers compared with IRIS's.
//
//  docs/design/rex3-source-audit.md section 5, phase 0: "the only gate that exercises GL's real
//  command mix". IRIS records every access the guest makes to REX3 - CPU
//  loads and stores with their widths, the MC's VDMA beats - in program
//  order; this drives each one through the same bus model as the directed
//  tests (tb_newport.h), waiting for each acknowledgement the way the CPU and
//  the DMA engine do, and at every MARKER dumps both plane sets for
//  comparison with IRIS's dump of the same moment.
//
//  RX3TRACE, little-endian. A 16-byte header - the eight ASCII bytes
//  "RX3TRACE", u32 version = 1, u32 record size = 24 - then records:
//    u8  kind     0 CPU write 32, 1 CPU write 64, 2 CPU read 32,
//                 3 CPU read 64, 4 DMA write 64, 5 DMA read 64, 6 MARKER
//    u8  flags    (not interpreted; the values seen are listed at the end)
//    u16 reserved
//    u32 offset   byte offset in REX3's 8 KB window as addressed, the GO
//                 alias bit 0x800 included; 8-aligned for 64-bit accesses
//    u64 data     writes: the value (32-bit in bits 31:0; 64-bit with bits
//                 63:32 = the word at the lower address); reads: what IRIS
//                 returned, compared with what the core returns; MARKER:
//                 the dump index
//    u64 stamp    monotonic, informational
//  A record size above 24 is accepted and the extra bytes skipped. A 32-bit
//  CPU access whose offset is not 4-aligned is taken as the byte (odd
//  offset) or halfword (offset 2 mod 4) access it must have been - REX3's
//  only sub-word registers are the DCBDATA ports.
//
//  Dumps: <out>/core_rgb_NNNN.bin and core_aux_NNNN.bin, 2048 x 1024 u32
//  little-endian each, IRIS's fb_rgb/fb_aux layout (pixel (x, y) at
//  y * 2048 + x). Given --iris-rgb/--iris-aux (printf patterns taking the
//  marker's index), each marker is compared under a mask - by default the
//  low 24 bits, because byte 3 of a core drawing slot is its copy of the
//  window-ID nibble (np_rex3.sv) - and PNGs of IRIS, the core and the
//  difference are written for every plane set that differs. The PNGs show a
//  slot's bytes 0, 1, 2 as red, green, blue: raw plane contents, not what
//  the display would make of them.
//
//  BENCH-SIDE EMULATIONS, off unless asked for, so a trace can be compared
//  past a bus defect docs/design/rex3-source-audit.md has already named. They change what is sent to
//  the RTL, never the RTL, and the summary says which were on:
//    --split64     a 64-bit store goes as two 32-bit stores, the GO on the
//                  second (docs/design/rex3-source-audit.md 3.1/4.4: what newport.sv should do)
//    --gl-coords   the float coordinate registers' values are masked to
//                  0x007FFF80 before they are sent, and a 32-bit XENDF1 goes
//                  to XENDF (docs/design/rex3-source-audit.md 4.1)
//    --sync-reads  every read but STATUS, USER_STATUS, CONFIG and the DCB
//                  ports waits for the engine to go idle first (docs/design/rex3-source-audit.md 4.4)
//
//    make -C verilator newportreplay          (builds, then the synthetic self-test)
//    ./obj_dir_npreplay/Vnewport_replay TRACE -o OUT \
//        --iris-rgb iris/rgb_%04u.bin --iris-aux iris/aux_%04u.bin
//============================================================================
#include "tb_newport.h"

#include <zlib.h>

#include <cctype>
#include <cerrno>
#include <chrono>
#include <climits>
#include <map>
#include <set>
#include <sys/stat.h>
#include <sys/types.h>

using namespace np;

enum : uint8_t {
    K_CPU_WR32 = 0, K_CPU_WR64 = 1, K_CPU_RD32 = 2, K_CPU_RD64 = 3,
    K_DMA_WR64 = 4, K_DMA_RD64 = 5, K_MARKER = 6, K_NKINDS = 7
};
static const char *KIND_NAME[K_NKINDS] = {
    "CPU write 32", "CPU write 64", "CPU read 32", "CPU read 64",
    "DMA write 64", "DMA read 64", "MARKER"
};

struct Rec {
    uint8_t  kind, flags;
    uint32_t off;
    uint64_t data, stamp;
};

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t le64(const uint8_t *p) { return (uint64_t)le32(p) | ((uint64_t)le32(p + 4) << 32); }

//============================================================================
//  Options
//============================================================================
struct Options {
    std::string trace, outdir = "newport_replay_out", iris_rgb, iris_aux;
    std::string init_rgb, init_aux;
    bool     iris_be = false, png = false, no_png = false, verbose = false;
    bool     fail_on_diff = false;
    bool     split64 = false, gl_coords = false, sync_reads = false;
    uint32_t mask_rgb = 0x00FFFFFF, mask_aux = 0x00FFFFFF;
    int      fb_lat = 1;
    uint64_t timeout = 200000000ull;
    uint64_t max_records = UINT64_MAX;
    int      show = 20;          // read mismatches printed in full
};
static Options O;
static Harness *H = nullptr;

static void usage(const char *argv0)
{
    printf("usage: %s TRACE [options]\n"
           "  -o DIR              where core_rgb/aux_NNNN.bin (and PNGs) go (default %s)\n"
           "  --iris-rgb PATTERN  IRIS's drawing-plane dump for a marker, a printf pattern\n"
           "                      taking the index: e.g. iris/rgb_%%04u.bin\n"
           "  --iris-aux PATTERN  IRIS's auxiliary-plane dump for a marker\n"
           "  --iris-be           IRIS's dumps are big-endian u32 (IRIS's save_framebuffers)\n"
           "  --init-rgb FILE     start from this drawing-plane dump instead of zeros\n"
           "  --init-aux FILE     and this auxiliary-plane dump (IRIS's d00: power-on noise)\n"
           "  --mask-rgb HEX      slot bits compared, drawing planes (default 00ffffff)\n"
           "  --mask-aux HEX      slot bits compared, auxiliary planes (default 00ffffff)\n"
           "  --png               also write the core's planes as PNG at every marker\n"
           "  --no-png            no PNGs, not even for differences\n"
           "  --fail-on-diff      exit 1 when any compared marker differs\n"
           "  --fb-lat N          frame buffer random-port clocks per transaction (default 1)\n"
           "  --timeout N         clocks one transaction may take (default 200000000)\n"
           "  --max-records N     stop after N records\n"
           "  --show N            read mismatches printed in full (default 20)\n"
           "  --split64 | --gl-coords | --sync-reads | --emulate-fixes (all three)\n"
           "                      bench-side emulations of docs/design/rex3-source-audit.md fixes; see the source\n"
           "  -v                  print every record\n",
           argv0, O.outdir.c_str());
}

static bool parse(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> const char * {
            if (i + 1 >= argc) { fprintf(stderr, "%s needs a value\n", a.c_str()); exit(2); }
            return argv[++i];
        };
        if (a == "-h" || a == "--help")        { usage(argv[0]); exit(0); }
        else if (a == "-o")                    O.outdir = next();
        else if (a == "--iris-rgb")            O.iris_rgb = next();
        else if (a == "--iris-aux")            O.iris_aux = next();
        else if (a == "--iris-be")             O.iris_be = true;
        else if (a == "--init-rgb")            O.init_rgb = next();
        else if (a == "--init-aux")            O.init_aux = next();
        else if (a == "--mask-rgb")            O.mask_rgb = (uint32_t)strtoul(next(), nullptr, 16);
        else if (a == "--mask-aux")            O.mask_aux = (uint32_t)strtoul(next(), nullptr, 16);
        else if (a == "--png")                 O.png = true;
        else if (a == "--no-png")              O.no_png = true;
        else if (a == "--fail-on-diff")        O.fail_on_diff = true;
        else if (a == "--fb-lat")              O.fb_lat = atoi(next());
        else if (a == "--timeout")             O.timeout = strtoull(next(), nullptr, 0);
        else if (a == "--max-records")         O.max_records = strtoull(next(), nullptr, 0);
        else if (a == "--show")                O.show = atoi(next());
        else if (a == "--split64")             O.split64 = true;
        else if (a == "--gl-coords")           O.gl_coords = true;
        else if (a == "--sync-reads")          O.sync_reads = true;
        else if (a == "--emulate-fixes")       O.split64 = O.gl_coords = O.sync_reads = true;
        else if (a == "-v")                    O.verbose = true;
        else if (a[0] == '+')                  ;   // a Verilator plusarg
        else if (a[0] == '-')                  { fprintf(stderr, "unknown option %s\n", a.c_str()); return false; }
        else if (O.trace.empty())              O.trace = a;
        else                                   { fprintf(stderr, "extra argument %s\n", a.c_str()); return false; }
    }
    return !O.trace.empty();
}

// The marker index into a printf-style pattern: %d, %u, %x or %X, with an
// optional zero pad and width. A pattern without one is used as it is.
static std::string subst_index(const std::string &pat, uint64_t idx)
{
    size_t p = pat.find('%');
    if (p == std::string::npos) return pat;
    size_t q = p + 1;
    while (q < pat.size() && isdigit((unsigned char)pat[q])) q++;
    if (q >= pat.size()) return pat;
    char conv = pat[q];
    std::string flags = pat.substr(p + 1, q - p - 1);
    char buf[64];
    if (conv == 'x' || conv == 'X')
        snprintf(buf, sizeof buf, ("%" + flags + "ll" + conv).c_str(), (unsigned long long)idx);
    else if (conv == 'd' || conv == 'i')
        snprintf(buf, sizeof buf, ("%" + flags + "lld").c_str(), (long long)idx);
    else if (conv == 'u')
        snprintf(buf, sizeof buf, ("%" + flags + "llu").c_str(), (unsigned long long)idx);
    else
        return pat;
    return pat.substr(0, p) + buf + pat.substr(q + 1);
}

static bool mkdirs(const std::string &path)
{
    std::string cur;
    for (size_t i = 0; i <= path.size(); i++) {
        if (i == path.size() || path[i] == '/') {
            if (!cur.empty() && mkdir(cur.c_str(), 0755) != 0 && errno != EEXIST) return false;
        }
        if (i < path.size()) cur += path[i];
    }
    return true;
}

//============================================================================
//  PNG, through zlib
//============================================================================
static void put32be(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}

static bool write_png(const std::string &path, int w, int h, const std::vector<uint8_t> &rgb)
{
    const size_t stride = 1 + 3 * (size_t)w;
    std::vector<uint8_t> raw(stride * h);
    for (int y = 0; y < h; y++) {
        raw[y * stride] = 0;                             // filter: none
        memcpy(&raw[y * stride + 1], &rgb[(size_t)y * 3 * w], 3 * (size_t)w);
    }
    uLongf zlen = compressBound(raw.size());
    std::vector<uint8_t> z(zlen);
    if (compress2(z.data(), &zlen, raw.data(), raw.size(), 6) != Z_OK) return false;
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) return false;
    static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    fwrite(sig, 1, 8, f);
    auto chunk = [&](const char *type, const uint8_t *data, uint32_t len) {
        uint8_t b4[4];
        put32be(b4, len);
        fwrite(b4, 1, 4, f);
        fwrite(type, 1, 4, f);
        uLong crc = crc32(0L, (const Bytef *)type, 4);
        if (len) {
            fwrite(data, 1, len, f);
            crc = crc32(crc, data, len);
        }
        put32be(b4, (uint32_t)crc);
        fwrite(b4, 1, 4, f);
    };
    uint8_t ihdr[13];
    put32be(ihdr, (uint32_t)w);
    put32be(ihdr + 4, (uint32_t)h);
    ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;  // 8-bit RGB
    chunk("IHDR", ihdr, 13);
    chunk("IDAT", z.data(), (uint32_t)zlen);
    chunk("IEND", nullptr, 0);
    bool ok = !ferror(f);
    fclose(f);
    return ok;
}

// A plane set as an image: a slot's bytes 0, 1, 2 as red, green, blue.
static bool png_plane(const std::string &path, const std::vector<uint32_t> &s)
{
    std::vector<uint8_t> rgb((size_t)Harness::FB_W * Harness::FB_H * 3);
    for (size_t i = 0; i < s.size(); i++) {
        rgb[3 * i]     = (uint8_t)s[i];
        rgb[3 * i + 1] = (uint8_t)(s[i] >> 8);
        rgb[3 * i + 2] = (uint8_t)(s[i] >> 16);
    }
    return write_png(path, Harness::FB_W, Harness::FB_H, rgb);
}

// The difference: agreeing pixels as a dim grey of IRIS's, differing ones
// red where only IRIS has something, green where only the core does, and
// yellow where both do.
static bool png_diff(const std::string &path, const std::vector<uint32_t> &iris,
                     const std::vector<uint32_t> &core, uint32_t mask)
{
    std::vector<uint8_t> rgb((size_t)Harness::FB_W * Harness::FB_H * 3);
    for (size_t i = 0; i < iris.size(); i++) {
        uint32_t a = iris[i] & mask, b = core[i] & mask;
        uint8_t r, g, bl;
        if (a == b) {
            uint8_t v = (uint8_t)((((a & 0xFF) + ((a >> 8) & 0xFF) + ((a >> 16) & 0xFF)) / 3) / 3);
            r = g = bl = v;
        } else if (b == 0) { r = 255; g = 0;   bl = 0; }
        else if (a == 0)   { r = 0;   g = 255; bl = 0; }
        else               { r = 255; g = 255; bl = 0; }
        rgb[3 * i] = r; rgb[3 * i + 1] = g; rgb[3 * i + 2] = bl;
    }
    return write_png(path, Harness::FB_W, Harness::FB_H, rgb);
}

//============================================================================
//  The comparison
//============================================================================
static const size_t SLOTS = (size_t)Harness::FB_W * Harness::FB_H;

static std::vector<uint32_t> core_plane(bool aux)
{
    std::vector<uint32_t> s(SLOTS);
    const uint32_t base = aux ? Harness::PLANE_WORDS : 0;
    for (size_t i = 0; i < SLOTS; i += 2) {
        uint64_t w = H->fb[base + i / 2];
        s[i] = (uint32_t)w;
        s[i + 1] = (uint32_t)(w >> 32);
    }
    return s;
}

static bool load_plane(const std::string &path, std::vector<uint32_t> &s)
{
    FILE *f = fopen(path.c_str(), "rb");
    if (!f) return false;
    std::vector<uint8_t> b(SLOTS * 4);
    size_t n = fread(b.data(), 1, b.size(), f);
    fclose(f);
    if (n != b.size()) {
        printf("    %s: %zu bytes, expected %zu (2048 x 1024 u32)\n", path.c_str(), n, b.size());
        return false;
    }
    s.resize(SLOTS);
    for (size_t i = 0; i < SLOTS; i++) {
        const uint8_t *p = &b[4 * i];
        s[i] = O.iris_be ? ((uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3])
                         : le32(p);
    }
    return true;
}

static uint64_t g_markers = 0, g_compared = 0, g_marker_diffs = 0;
static bool     g_diffs_this_marker = false;

static void compare_plane(uint64_t index, bool aux, const std::string &pattern)
{
    const char *pname = aux ? "aux" : "rgb";
    std::string path = subst_index(pattern, index);
    std::vector<uint32_t> iris;
    if (!load_plane(path, iris)) {
        printf("    %s: no IRIS dump at %s - not compared\n", pname, path.c_str());
        return;
    }
    std::vector<uint32_t> core = core_plane(aux);
    const uint32_t mask = aux ? O.mask_aux : O.mask_rgb;
    uint64_t n = 0, only_iris = 0, only_core = 0, nz_iris = 0, swapped_look = 0;
    int bx0 = INT_MAX, by0 = INT_MAX, bx1 = INT_MIN, by1 = INT_MIN;
    std::vector<std::string> first;
    for (size_t i = 0; i < SLOTS; i++) {
        uint32_t a = iris[i] & mask, b = core[i] & mask;
        if (iris[i]) {
            nz_iris++;
            if ((iris[i] & 0xFF000000u) && !(iris[i] & 0xFF)) swapped_look++;
        }
        if (a == b) continue;
        n++;
        if (b == 0) only_iris++;
        if (a == 0) only_core++;
        int x = (int)(i & 2047), y = (int)(i >> 11);
        bx0 = std::min(bx0, x); bx1 = std::max(bx1, x);
        by0 = std::min(by0, y); by1 = std::max(by1, y);
        if (first.size() < 8)
            first.push_back(strf("(%d,%d) iris %08x core %08x", x, y, iris[i], core[i]));
    }
    g_compared++;
    if (n == 0) {
        printf("    %s: identical to IRIS (mask %08x)\n", pname, mask);
    } else {
        printf("    %s: %llu of %zu slots differ (mask %08x): %llu drawn only by IRIS, %llu only "
               "by the core; bounding box x %d..%d, y %d..%d\n",
               pname, (unsigned long long)n, SLOTS, mask, (unsigned long long)only_iris,
               (unsigned long long)only_core, bx0, bx1, by0, by1);
        for (auto &s : first) printf("        %s\n", s.c_str());
    }
    if (nz_iris > 1000 && swapped_look * 10 > nz_iris * 9)
        printf("    %s: most of IRIS's non-zero slots have a zero low byte and a non-zero top "
               "byte - a big-endian dump? try --iris-be\n", pname);
    if ((n && !O.no_png) || O.png) {
        std::string pre = strf("%s/cmp_%04llu_%s_", O.outdir.c_str(), (unsigned long long)index, pname);
        bool ok = png_plane(pre + "iris.png", iris) && png_plane(pre + "core.png", core)
                  && png_diff(pre + "diff.png", iris, core, mask);
        printf("    %s: %s %siris.png, core.png, diff.png\n", pname,
               ok ? "wrote" : "FAILED to write", pre.c_str());
    }
    if (n) g_diffs_this_marker = true;
}

//============================================================================
//  Records
//============================================================================
struct RegStat { uint64_t reads = 0, mismatches = 0; };
static std::map<uint32_t, RegStat> g_rstat;          // key: kind << 16 | register
struct Mismatch { uint64_t rec, stamp; uint8_t kind; uint32_t off; uint64_t iris, core; };
static std::vector<Mismatch> g_mm;
static uint64_t g_mismatches = 0, g_reads = 0;
static uint64_t g_kind[256] = {0};
static std::set<unsigned> g_flags;
static uint64_t g_sub = 0, g_unaligned64 = 0, g_rewrites = 0;

static void note_read(uint8_t kind, uint32_t off, uint64_t iris, uint64_t core,
                      uint64_t rec, uint64_t stamp)
{
    uint32_t reg = off & ~GO & 0x1FFF;
    RegStat &s = g_rstat[((uint32_t)kind << 16) | reg];
    s.reads++;
    g_reads++;
    if (iris == core) return;
    s.mismatches++;
    g_mismatches++;
    if ((int)g_mm.size() < O.show) {
        g_mm.push_back({rec, stamp, kind, off, iris, core});
        printf("  read mismatch #%llu at record %llu (stamp %llu): %s 0x%04x %s%s: iris %0*llx, core %0*llx\n",
               (unsigned long long)g_mismatches, (unsigned long long)rec, (unsigned long long)stamp,
               KIND_NAME[kind], off, reg_name(reg), (off & GO) ? "|GO" : "",
               kind == K_CPU_RD32 ? 8 : 16, (unsigned long long)iris,
               kind == K_CPU_RD32 ? 8 : 16, (unsigned long long)core);
    }
}

// --gl-coords: what the chip keeps of a GL-format coordinate is float bits
// 22:7, and 0x14C is XENDF1, a float, which XENDF (0x140) decodes.
static void gl_rewrite(uint32_t &off, uint32_t &v)
{
    uint32_t reg = off & ~GO & 0x1FFF;
    if (reg >= R_XSTARTF && reg <= R_YENDF) {
        v &= 0x007FFF80;
        g_rewrites++;
    } else if (reg == R_XENDF1) {
        v &= 0x007FFF80;
        off = R_XENDF | (off & GO);
        g_rewrites++;
    }
}

// --sync-reads: the immediate class, which the chip answers without waiting.
static bool read_is_ordered(uint32_t off)
{
    switch (off & ~GO & 0x1FFC) {
    case R_STATUS: case R_USERSTATUS: case R_CONFIG:
    case R_DCBMODE: case R_DCBDATA0: case R_DCBDATA1: case R_DCBRESET:
        return false;
    default:
        return true;
    }
}

static void marker(uint64_t index, uint64_t rec, uint64_t stamp)
{
    // Let everything issued so far land: REX3WAIT (USER_STATUS has no side
    // effects), then np_rex3's own view of pending and held work.
    if (!H->rex3wait(O.timeout / 4))
        printf("  marker %llu: USER_STATUS never went idle - dumping anyway\n",
               (unsigned long long)index);
    if (!H->wait_idle(1000000))
        printf("  marker %llu: dbg_nd still reports work pending - dumping anyway\n",
               (unsigned long long)index);
    H->ticks(16);
    g_markers++;
    std::string rgb = strf("%s/core_rgb_%04llu.bin", O.outdir.c_str(), (unsigned long long)index);
    std::string aux = strf("%s/core_aux_%04llu.bin", O.outdir.c_str(), (unsigned long long)index);
    bool ok = H->dump(rgb, aux);
    printf("  marker %llu at record %llu (stamp %llu, clock %llu): %s %s, %s\n",
           (unsigned long long)index, (unsigned long long)rec, (unsigned long long)stamp,
           (unsigned long long)H->cyc, ok ? "dumped" : "FAILED to dump", rgb.c_str(), aux.c_str());
    if (O.png) {
        png_plane(strf("%s/core_rgb_%04llu.png", O.outdir.c_str(), (unsigned long long)index), core_plane(false));
        png_plane(strf("%s/core_aux_%04llu.png", O.outdir.c_str(), (unsigned long long)index), core_plane(true));
    }
    g_diffs_this_marker = false;
    if (!O.iris_rgb.empty()) compare_plane(index, false, O.iris_rgb);
    if (!O.iris_aux.empty()) compare_plane(index, true, O.iris_aux);
    if (g_diffs_this_marker) g_marker_diffs++;
    fflush(stdout);
}

// One record. False when the bus never answered.
static bool do_record(const Rec &r, uint64_t idx)
{
    uint32_t off = r.off & 0x1FFF;
    bool ok = true;
    switch (r.kind) {
    case K_CPU_WR32:
        if (off & 3) {
            g_sub++;
            ok = H->wr_sub(off, (off & 1) ? 1 : 2, (uint32_t)r.data);
        } else {
            uint32_t v = (uint32_t)r.data;
            if (O.gl_coords) gl_rewrite(off, v);
            ok = H->wr32(off, v);
        }
        break;
    case K_CPU_WR64: {
        if (off & 7) { g_unaligned64++; off &= ~7u; }
        uint32_t hi = (uint32_t)(r.data >> 32), lo = (uint32_t)r.data;
        uint32_t hoff = off & ~GO, loff = (hoff + 4) | (off & GO);
        if (O.split64) {
            if (O.gl_coords) { gl_rewrite(hoff, hi); gl_rewrite(loff, lo); }
            ok = H->wr32(hoff, hi) && H->wr32(loff, lo);
        } else {
            if (O.gl_coords) {
                // The register numbers of a doubleword cannot be changed -
                // an XENDF1 in its low word stays at 0x14C - only the values
                // can be masked.
                uint32_t h2 = hoff, l2 = loff;
                gl_rewrite(h2, hi);
                gl_rewrite(l2, lo);
            }
            ok = H->wr64(off, ((uint64_t)hi << 32) | lo);
        }
        break;
    }
    case K_CPU_RD32: {
        if (O.sync_reads && read_is_ordered(off)) H->wait_idle(O.timeout);
        uint32_t v = 0;
        if (off & 3) {
            int bytes = (off & 1) ? 1 : 2;
            g_sub++;
            ok = H->rd_sub(off, bytes, v);
            if (ok) note_read(r.kind, off, r.data & (bytes == 1 ? 0xFF : 0xFFFF), v, idx, r.stamp);
        } else {
            ok = H->rd32(off, v);
            if (ok) note_read(r.kind, off, (uint32_t)r.data, v, idx, r.stamp);
        }
        break;
    }
    case K_CPU_RD64: {
        if (off & 7) { g_unaligned64++; off &= ~7u; }
        if (O.sync_reads && read_is_ordered(off)) H->wait_idle(O.timeout);
        uint64_t v = 0;
        ok = H->rd64(off, v);
        if (ok) note_read(r.kind, off, r.data, v, idx, r.stamp);
        break;
    }
    case K_DMA_WR64:
        ok = H->dma_wr(off, r.data);
        break;
    case K_DMA_RD64: {
        uint64_t v = 0;
        ok = H->dma_rd(off, v);
        if (ok) note_read(r.kind, off, r.data, v, idx, r.stamp);
        break;
    }
    case K_MARKER:
        marker(r.data, idx, r.stamp);
        break;
    default:
        break;
    }
    return ok;
}

//============================================================================
int main(int argc, char **argv)
{
    if (!parse(argc, argv)) { usage(argv[0]); return 2; }
    FILE *f = fopen(O.trace.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", O.trace.c_str()); return 2; }
    uint8_t hdr[16];
    if (fread(hdr, 1, 16, f) != 16 || memcmp(hdr, "RX3TRACE", 8) != 0) {
        fprintf(stderr, "%s: not an RX3TRACE file\n", O.trace.c_str());
        return 2;
    }
    uint32_t version = le32(hdr + 8), recsize = le32(hdr + 12);
    if (recsize < 24) { fprintf(stderr, "record size %u is below 24\n", recsize); return 2; }
    if (version != 1) printf("warning: trace version %u, this reader knows 1\n", version);
    struct stat st;
    uint64_t fsize = (stat(O.trace.c_str(), &st) == 0) ? (uint64_t)st.st_size : 0;
    uint64_t nrec = fsize > 16 ? (fsize - 16) / recsize : 0;
    if (!mkdirs(O.outdir)) { fprintf(stderr, "cannot create %s\n", O.outdir.c_str()); return 2; }

    H = new Harness(argc, argv);
    H->fb_lat = O.fb_lat;
    H->timeout = O.timeout;
    H->reset();

    // THE STARTING PICTURE. IRIS never clears its frame buffers at power-on -
    // they hold xorshift noise, which is its d00 dump - so a replay compared
    // with IRIS's later dumps has to start from the same noise, or every
    // pixel nobody wrote differs. Loaded in the core's own slot format: a
    // drawing slot's byte 3 is its copy of the window ID (aux[3:0], which
    // np_rex3's DR_CID keeps in step), and an auxiliary slot's byte 3 is
    // never written, so it starts at zero.
    if (!O.init_rgb.empty() || !O.init_aux.empty()) {
        std::vector<uint32_t> rgb(1u << 21, 0), aux(1u << 21, 0);
        auto load = [](const std::string &path, std::vector<uint32_t> &v) -> bool {
            if (path.empty()) return true;
            FILE *g = fopen(path.c_str(), "rb");
            if (!g) { fprintf(stderr, "cannot open %s\n", path.c_str()); return false; }
            std::vector<uint8_t> b((size_t)v.size() * 4);
            size_t got = fread(b.data(), 1, b.size(), g);
            fclose(g);
            if (got != b.size()) {
                fprintf(stderr, "%s: %zu bytes, expected %zu\n", path.c_str(), got, b.size());
                return false;
            }
            for (size_t i = 0; i < v.size(); i++) v[i] = le32(&b[4 * i]);
            return true;
        };
        if (!load(O.init_rgb, rgb) || !load(O.init_aux, aux)) return 2;
        for (int y = 0; y < 1024; y++)
            for (int x = 0; x < 2048; x++) {
                uint32_t i = (uint32_t)y * 2048 + (uint32_t)x;
                H->set_slot(x, y, true, aux[i] & 0x00FFFFFF);
                H->set_slot(x, y, false, (rgb[i] & 0x00FFFFFF) | ((aux[i] & 0xF) << 24));
            }
        printf("  started from %s%s%s\n", O.init_rgb.empty() ? "zeros" : O.init_rgb.c_str(),
               O.init_aux.empty() ? "" : " + ", O.init_aux.c_str());
    }

    printf("newportreplay: %s - version %u, %u-byte records, %llu of them\n", O.trace.c_str(),
           version, recsize, (unsigned long long)nrec);
    printf("  frame buffer latency %d, dumps to %s%s%s%s\n", O.fb_lat, O.outdir.c_str(),
           O.split64 ? ", EMULATING the doubleword split" : "",
           O.gl_coords ? ", EMULATING the GL coordinate decode" : "",
           O.sync_reads ? ", EMULATING ordered reads" : "");
    fflush(stdout);

    const size_t CHUNK = 65536;
    std::vector<uint8_t> buf((size_t)recsize * CHUNK);
    auto t_start = std::chrono::steady_clock::now();
    auto t_last = t_start;
    uint64_t done = 0, cyc0 = H->cyc;
    bool hung = false, truncated = false;
    while (!hung && done < O.max_records) {
        size_t got = fread(buf.data(), 1, buf.size(), f);
        size_t n = got / recsize;
        if (got % recsize) truncated = true;
        for (size_t i = 0; i < n && done < O.max_records; i++) {
            const uint8_t *p = &buf[i * recsize];
            Rec r;
            r.kind = p[0]; r.flags = p[1];
            r.off = le32(p + 4); r.data = le64(p + 8); r.stamp = le64(p + 16);
            g_kind[r.kind]++;
            g_flags.insert(r.flags);
            if (O.verbose)
                printf("  #%llu %s off 0x%04x (%s%s) data %016llx flags %02x stamp %llu\n",
                       (unsigned long long)done,
                       r.kind < K_NKINDS ? KIND_NAME[r.kind] : "UNKNOWN KIND", r.off & 0x1FFF,
                       reg_name(r.off), (r.off & GO) ? "|GO" : "", (unsigned long long)r.data,
                       r.flags, (unsigned long long)r.stamp);
            if (!do_record(r, done)) {
                printf("BUS HANG at record %llu (%s, offset 0x%04x, stamp %llu): not acknowledged "
                       "in %llu clocks\n", (unsigned long long)done,
                       r.kind < K_NKINDS ? KIND_NAME[r.kind] : "?", r.off & 0x1FFF,
                       (unsigned long long)r.stamp, (unsigned long long)O.timeout);
                hung = true;
                break;
            }
            done++;
            if ((done & 4095) == 0) {
                auto now = std::chrono::steady_clock::now();
                double since = std::chrono::duration<double>(now - t_last).count();
                if (since >= 2.0) {
                    double el = std::chrono::duration<double>(now - t_start).count();
                    printf("  ... %llu records (%.1f%%), %llu clocks, %.0f records/s, %.2f Mclocks/s, "
                           "%llu markers, %llu read mismatches\n",
                           (unsigned long long)done, nrec ? 100.0 * done / nrec : 0.0,
                           (unsigned long long)(H->cyc - cyc0), done / el,
                           (H->cyc - cyc0) / el / 1e6, (unsigned long long)g_markers,
                           (unsigned long long)g_mismatches);
                    fflush(stdout);
                    t_last = now;
                }
            }
        }
        if (got < buf.size()) break;
    }
    fclose(f);
    double el = std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start).count();
    if (el <= 0) el = 1e-9;

    printf("\n== replay summary ==\n");
    printf("records: %llu replayed", (unsigned long long)done);
    for (int k = 0; k < K_NKINDS; k++)
        if (g_kind[k]) printf(", %llu %s", (unsigned long long)g_kind[k], KIND_NAME[k]);
    uint64_t unknown = 0;
    for (int k = K_NKINDS; k < 256; k++) unknown += g_kind[k];
    if (unknown) printf(", %llu of unknown kind (skipped)", (unsigned long long)unknown);
    printf("\n");
    if (truncated) printf("the file ends in a partial record, ignored\n");
    if (g_sub) printf("%llu sub-word CPU accesses inferred from unaligned offsets\n", (unsigned long long)g_sub);
    if (g_unaligned64) printf("%llu 64-bit accesses at an offset not 8-aligned (aligned down)\n", (unsigned long long)g_unaligned64);
    printf("flags values seen:");
    for (unsigned fl : g_flags) printf(" %02x", fl);
    printf("\n");
    printf("emulations: %s%s%s%s\n", O.split64 ? "split64 " : "", O.gl_coords ? "gl-coords " : "",
           O.sync_reads ? "sync-reads " : "",
           (O.split64 || O.gl_coords || O.sync_reads) ? "" : "none (the RTL as it is)");
    if (O.gl_coords) printf("  gl-coords rewrote %llu values\n", (unsigned long long)g_rewrites);
    printf("speed: %.2f s wall, %llu clocks: %.0f records/s, %.2f Mclocks/s\n", el,
           (unsigned long long)(H->cyc - cyc0), done / el, (H->cyc - cyc0) / el / 1e6);
    printf("frame buffer: %llu reads, %llu writes by REX3, %llu display reads, %llu protocol "
           "errors, %llu out of range\n",
           (unsigned long long)H->fbw_reads, (unsigned long long)H->fbw_writes,
           (unsigned long long)H->disp_reads, (unsigned long long)H->fbw_proto,
           (unsigned long long)H->fb_oob);
    printf("reads compared: %llu, mismatching IRIS: %llu\n", (unsigned long long)g_reads,
           (unsigned long long)g_mismatches);
    if (!g_rstat.empty()) {
        printf("  %-12s %-6s %-12s %10s %10s\n", "kind", "reg", "name", "reads", "mismatch");
        for (auto &kv : g_rstat) {
            uint8_t k = (uint8_t)(kv.first >> 16);
            uint32_t reg = kv.first & 0xFFFF;
            printf("  %-12s 0x%04x %-12s %10llu %10llu%s\n", KIND_NAME[k], reg, reg_name(reg),
                   (unsigned long long)kv.second.reads, (unsigned long long)kv.second.mismatches,
                   (reg == R_STATUS || reg == R_USERSTATUS) ? "   (busy bits and VERSION differ by design)" : "");
        }
    }
    printf("markers: %llu dumped, %llu plane sets compared, %llu markers with differences\n",
           (unsigned long long)g_markers, (unsigned long long)g_compared,
           (unsigned long long)g_marker_diffs);
    delete H;
    if (hung) return 3;
    if (O.fail_on_diff && g_marker_diffs) {
        printf("NEWPORTREPLAY: FAIL (--fail-on-diff: %llu markers differ)\n", (unsigned long long)g_marker_diffs);
        return 1;
    }
    return 0;
}
