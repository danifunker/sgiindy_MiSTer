// sim_devices.cpp - memory, the IRIS test device, and the ELF loader.
//
// Everything here stores bytes in address order (big-endian), so a hex dump of
// `Memory::bytes` reads like the machine's address space. The bus carries the
// byte at `addr + i` in `data[63-8*i -: 8]`, which is the packing read64 and
// write64 implement; see rtl/cpu/r4300_bus.sv for where that convention is
// established.

#include "sim_devices.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>

namespace sgisim {

Devices g_dev;

uint64_t Memory::read64(uint32_t addr) const
{
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) {
        size_t a = static_cast<size_t>(addr) + i;
        uint8_t b = (a < bytes.size()) ? bytes[a] : 0;
        v |= static_cast<uint64_t>(b) << (56 - 8 * i);
    }
    return v;
}

void Memory::write64(uint32_t addr, uint64_t data, uint8_t be)
{
    for (int i = 0; i < 8; i++) {
        if (!((be >> (7 - i)) & 1)) continue;      // be[7-i] guards byte +i
        size_t a = static_cast<size_t>(addr) + i;
        if (a < bytes.size())
            bytes[a] = static_cast<uint8_t>(data >> (56 - 8 * i));
    }
}

// ---- test device ---------------------------------------------------------

static const uint32_t TD_SIGNATURE   = 0x00;
static const uint32_t TD_PUTC        = 0x04;
static const uint32_t TD_DUMP        = 0x08;
static const uint32_t TD_EXIT        = 0x0C;
static const uint32_t TD_CAPS        = 0x20;
static const uint32_t TD_RUN_CONFIG  = 0x24;
static const uint32_t TD_MAGIC       = 0x49524953;   // 'IRIS'
// TESTDEV_CAP_RUN_CONFIG only; no host timebase, because a cycle-accurate
// simulation has no meaningful host-nanosecond answer to give.
static const uint32_t TD_CAPS_VALUE  = 0x00000002;

// The device sits at GIO64 slot 0 base + 0x000000 and is 32 bits wide, so on
// this 64-bit big-endian bus a register at offset N appears in the upper half
// when N is 8-byte aligned and in the lower half otherwise.
static uint32_t td_reg32(const TestDevice &d, uint32_t off)
{
    switch (off) {
    case TD_SIGNATURE:  return TD_MAGIC;
    case TD_CAPS:       return TD_CAPS_VALUE;
    case TD_RUN_CONFIG: return d.run_config;
    default:            return 0;
    }
}

uint64_t TestDevice::read64(uint32_t addr) const
{
    if (!present) return 0xFFFFFFFFFFFFFFFFull;
    uint64_t hi = td_reg32(*this, addr & ~7u);
    uint64_t lo = td_reg32(*this, (addr & ~7u) + 4);
    return (hi << 32) | lo;
}

void TestDevice::write64(uint32_t addr, uint64_t data, uint8_t be)
{
    if (!present) return;
    // Pick the addressed 32-bit half from the byte enables: be[7:4] guard
    // bytes +0..+3, be[3:0] guard +4..+7.
    bool     lo_half = (be & 0x0F) != 0;
    uint32_t off     = (addr & ~7u) + (lo_half ? 4 : 0);
    uint32_t val     = lo_half ? static_cast<uint32_t>(data)
                               : static_cast<uint32_t>(data >> 32);

    switch (off) {
    case TD_PUTC: out.push_back(static_cast<char>(val & 0xFF)); break;
    case TD_DUMP: break;                       // no state worth dumping yet
    case TD_EXIT: exited = true; exit_code = val; break;
    default:      break;
    }
}

// ---- ELF -----------------------------------------------------------------

static uint16_t be16(const uint8_t *p) { return (p[0] << 8) | p[1]; }
static uint32_t be32(const uint8_t *p)
{
    return (static_cast<uint32_t>(p[0]) << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
}

// Physical RAM on IP22/IP24 starts at 0x08000000; the suite links at KSEG0
// 0x88200000 for that reason (cpu-tests/docs/memory-map.md). Segment addresses
// arrive as KSEG0/KSEG1 virtual addresses, and both are unmapped windows onto
// physical memory, so masking the top three bits is the whole translation.
static uint32_t phys_of(uint32_t vaddr) { return vaddr & 0x1FFFFFFF; }

static const uint32_t RAM_PHYS_BASE = 0x08000000;

ElfLoadResult load_elf(const std::string &path)
{
    ElfLoadResult r;
    FILE *f = fopen(path.c_str(), "rb");
    if (!f) { r.error = "cannot open " + path; return r; }

    std::vector<uint8_t> img;
    {
        fseek(f, 0, SEEK_END);
        long n = ftell(f);
        fseek(f, 0, SEEK_SET);
        img.resize(static_cast<size_t>(n));
        if (fread(img.data(), 1, img.size(), f) != img.size()) {
            fclose(f); r.error = "short read on " + path; return r;
        }
        fclose(f);
    }

    if (img.size() < 52 || memcmp(img.data(), "\x7F" "ELF", 4) != 0) {
        r.error = "not an ELF file"; return r;
    }
    if (img[4] != 1) { r.error = "not ELF32"; return r; }
    if (img[5] != 2) { r.error = "not big-endian - the suite builds ELF32 MSB"; return r; }
    if (be16(&img[18]) != 8) { r.error = "not EM_MIPS"; return r; }

    r.entry = be32(&img[24]);
    uint32_t phoff     = be32(&img[28]);
    uint16_t phentsize = be16(&img[42]);
    uint16_t phnum     = be16(&img[44]);

    for (uint16_t i = 0; i < phnum; i++) {
        const uint8_t *ph = &img[phoff + static_cast<size_t>(i) * phentsize];
        uint32_t type   = be32(ph +  0);
        uint32_t offset = be32(ph +  4);
        uint32_t vaddr  = be32(ph +  8);
        uint32_t filesz = be32(ph + 16);
        uint32_t memsz  = be32(ph + 20);
        if (type != 1 /* PT_LOAD */ || memsz == 0) continue;

        uint32_t pa = phys_of(vaddr);
        if (pa < RAM_PHYS_BASE || pa + memsz > RAM_PHYS_BASE + g_dev.ram.size()) {
            char buf[256];
            snprintf(buf, sizeof buf,
                     "segment %u at vaddr %08x -> phys %08x (%u bytes) is outside RAM "
                     "[%08x, %08zx)",
                     i, vaddr, pa, memsz, RAM_PHYS_BASE,
                     static_cast<size_t>(RAM_PHYS_BASE) + g_dev.ram.size());
            r.error = buf;
            return r;
        }

        uint32_t off = pa - RAM_PHYS_BASE;
        for (uint32_t k = 0; k < filesz; k++)
            g_dev.ram.bytes[off + k] = img[offset + k];
        for (uint32_t k = filesz; k < memsz; k++)
            g_dev.ram.bytes[off + k] = 0;        // .bss

        // Probe both ends. Unmapped physical space accepts writes silently and
        // reads back zero, so a mis-addressed load is invisible until the CPU
        // starts fetching zeros - check the bytes actually landed.
        bool ok = true;
        if (filesz > 0) {
            ok &= (g_dev.ram.bytes[off] == img[offset]);
            ok &= (g_dev.ram.bytes[off + filesz - 1] == img[offset + filesz - 1]);
        }
        if (!ok) { r.error = "segment readback mismatch - load address is wrong"; return r; }

        char buf[256];
        snprintf(buf, sizeof buf,
                 "  seg%u  vaddr %08x  phys %08x  file %7u  mem %7u",
                 i, vaddr, pa, filesz, memsz);
        r.segments.push_back(buf);
    }

    r.ok = true;
    return r;
}

} // namespace sgisim

// ---- DPI entry points ----------------------------------------------------
//
// Declared in sim_ram.v. Verilator generates prototypes into Vsim_top__Dpi.h;
// these definitions must match, so they are plain extern "C".

extern "C" uint64_t sgi_dpi_read(uint32_t space, uint32_t addr)
{
    using namespace sgisim;
    switch (space) {
    case SPACE_RAM:  return g_dev.ram.read64(addr);
    case SPACE_PROM: return g_dev.prom.read64(addr);
    case SPACE_GIO:  return g_dev.testdev.read64(addr);
    default:         return 0;
    }
}

extern "C" void sgi_dpi_write(uint32_t space, uint32_t addr, uint64_t data, uint8_t be)
{
    using namespace sgisim;
    switch (space) {
    case SPACE_RAM: g_dev.ram.write64(addr, data, be); break;
    case SPACE_GIO: g_dev.testdev.write64(addr, data, be); break;
    default: break;                         // the PROM is read-only
    }
}

// ---- SCSI disks ----------------------------------------------------------

namespace sgisim {

bool ScsiDisk::load(const std::string &p)
{
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return false; }
    // Round up to a whole block. A short tail would otherwise read back as
    // whatever was in the vector, and a disk whose last sector is half there
    // is not a thing the guest can be expected to cope with.
    size_t blocks = (size_t)((n + 511) / 512);
    image.assign(blocks * 512, 0);
    size_t got = fread(image.data(), 1, (size_t)n, f);
    fclose(f);
    if (got != (size_t)n) return false;
    path    = p;
    mounted = true;
    return true;
}

} // namespace sgisim
