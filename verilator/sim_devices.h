// sim_devices.h - C++ side of the Verilator harness's memory and devices.
#pragma once
#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

namespace sgisim {

// Backing-store selector, matching sim_ram.v's `space` port.
enum Space { SPACE_RAM = 0, SPACE_PROM = 1, SPACE_GIO = 2 };

// Big-endian byte store: byte(a) is the byte at address `a` within the space,
// which is also how it appears at data[63-8*(a&7) -: 8] on the bus.
struct Memory {
    std::vector<uint8_t> bytes;
    void   resize(size_t n)              { bytes.assign(n, 0); }
    size_t size() const                  { return bytes.size(); }
    uint64_t read64(uint32_t addr) const;
    void     write64(uint32_t addr, uint64_t data, uint8_t be);
};

// The IRIS test device, as an empty GIO64 slot 0 would not be. Present only
// when the harness is told to fit one; the suite probes for it and works
// without it, using the serial console alone.
//
// Register map is cpu-tests/harness/iris.h.
struct TestDevice {
    bool     present   = false;
    bool     exited    = false;
    uint32_t exit_code = 0;
    uint32_t run_config = 0;
    std::string out;                     // bytes written to PUTC
    uint64_t read64(uint32_t addr) const;
    void     write64(uint32_t addr, uint64_t data, uint8_t be);
};

struct Devices {
    Memory     ram;
    Memory     prom;
    TestDevice testdev;
};

extern Devices g_dev;

// ---- ELF loading ---------------------------------------------------------

struct ElfLoadResult {
    bool     ok = false;
    uint32_t entry = 0;
    std::string error;
    std::vector<std::string> segments;   // human-readable, for the log
};

// Load an ELF32 MSB MIPS image into the physical address space, the way
// IRIS's --load-elf does. `phys_of` maps a program header's paddr/vaddr onto a
// physical address. Probes both ends of every segment after writing, because
// unmapped physical space swallows writes silently and reads back zero - a
// mis-addressed load otherwise shows up much later as a CPU fetching zeros.
ElfLoadResult load_elf(const std::string &path);

} // namespace sgisim
