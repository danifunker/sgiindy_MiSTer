// sim_devices.h - C++ side of the Verilator harness's memory and devices.
#pragma once
#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>
#include <map>

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

// A SCSI disk, presented the way hps_io presents one: 512-byte blocks moved
// through a shared sector buffer, with a read or write request raised as a
// level and answered with an ack. One per target ID.
//
// The buffer is 16 bits wide because that is the width hps_io uses, and the
// byte order within a word is the HPS's, not the guest's - scsi.v unpacks it
// (see its buf0/buf1 comment). The harness therefore has to pack it the same
// way round, which is the "sim packs byte0 in high half" branch there.
//
// FILE-BACKED, NOT LOADED. An install target is gigabytes and the guest touches
// a few megabytes of it, so the image stays on disk and blocks are moved a
// sector at a time. Loading it into a vector cost one byte of host memory per
// byte of guest disk, which is fine for an 8 MB fixture and absurd for a 2 GB
// one.
//
// WRITES GO TO ONE OF TWO PLACES, and which one is an explicit choice at mount:
//
//   --disk     read-only. Writes land in `overlay`, an in-memory map of the
//              sectors that have been written, and reads consult it first. The
//              guest sees a coherent read-write disk for the length of the run
//              and the file on the host is never touched. This is what every
//              test mounts, because a test that rewrites its own fixture stops
//              being a test the second time it runs.
//
//   --disk-rw  read-write. Writes go through to the file. This is what an
//              install target wants, and it is deliberately not the default:
//              the difference between the two is whether a bug in the guest,
//              or in this harness, can destroy a checked-in image.
struct ScsiDisk {
    bool        mounted  = false;
    bool        writable = false;
    int         fd       = -1;
    uint64_t    size_bytes = 0;
    std::string path;

    // Sectors written to a read-only mount, by LBA. Bounded by what the guest
    // actually writes, which for every test here is a handful of blocks.
    std::map<uint32_t, std::vector<uint8_t>> overlay;

    // Set when a transfer is in flight, so the harness can step it over the
    // several cycles a real HPS session takes rather than answering instantly
    // - an instant ack hides every ordering bug in the target's buffer
    // handling.
    bool     busy    = false;
    bool     writing = false;
    uint32_t lba     = 0;
    int      countdown = 0;
    uint8_t  sector[512] = {0};

    bool   load(const std::string &p, bool rw = false);
    size_t blocks() const { return (size_t)(size_bytes / 512); }

    // Both return false only if the host I/O itself failed; a read past the end
    // of the image yields zeros, which is what a short tail on a real disk
    // would do rather than a bus error.
    bool   read_block(uint32_t lba, uint8_t *dst);
    bool   write_block(uint32_t lba, const uint8_t *src);
};

struct Devices {
    Memory     ram;
    Memory     prom;
    TestDevice testdev;
    ScsiDisk   scsi[7];
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
