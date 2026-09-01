//============================================================================
//  sim_cputest - headless Verilator harness for CPU validation.
//
//  Loads a bare-metal ELF straight into the memory model and runs the core
//  with no PROM and no chipset, which is all the cpu-tests suite needs: RAM at
//  physical 0x08000000, the SCC transmitter at 0x1FBD9830/0x34, and optionally
//  a device in GIO64 slot 0.
//
//    ./obj_dir/Vsim_top --elf build/cputest.elf --testdev
//
//  Exit code is the suite's own: the value it hands the test device, or the
//  `rc=` it prints in IRIS-CPUTEST-DONE when there is no test device.
//
//  Diagnostics, ported from the DE1 sandbox's ImGui harness because they
//  earned their keep there (docs/06-simulation.md):
//
//    --trace          timestamped bus trace with decoded register names
//    --stuck N        no-forward-progress detector, and what it was polling
//    --hot            the addresses the CPU hammered, on exit
//
//  The stuck detector watches the BUS rather than the PC. cpu.vhd's PC is only
//  observable through the savestate export, which is inside a `-- synthesis
//  translate_off` block and so is not in the synthesised netlist. Watching
//  bus addresses finds the same failure - "the PROM is polling a register that
//  never returns what it wants" - and names the register directly, which the
//  PC alone would not.
//============================================================================

#include "Vsim_top.h"
#include "verilated.h"
#include "sim_devices.h"
#include "sim_uart.h"
#include "sim_ps2.h"
#include "sim_video_cap.h"
#include "sim_scsi.h"

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <map>
#include <deque>
#include <array>
#include <vector>
#include <tuple>
#include <algorithm>

using namespace sgisim;

// Half-period of the SCC's serial clock, in system clocks. Must be a power of
// two. 4 keeps the bit engines moving without dominating the run.
static const uint64_t SCLK_DIV = 4;

// ---- MMIO register names -------------------------------------------------
//
// Ported from the sandbox's decode_reg_name table (docs/06-simulation.md); it
// is what makes a bus trace readable. Only the windows this core decodes so
// far are listed; the rest of the IP24 map is in docs/02-address-map.md.
struct RegName { uint32_t lo, hi; const char *name; };

static const RegName kRegNames[] = {
    { 0x08000000, 0x0FFFFFFF, "RAM"            },
    { 0x00000000, 0x0007FFFF, "RAM-alias"      },
    { 0x1F0F0000, 0x1F0FFFFF, "NEWPORT-REX3"   },
    { 0x1F400000, 0x1F5FFFFF, "GIO0"           },
    { 0x1FA00000, 0x1FA000FF, "MC"             },
    { 0x1FA00100, 0x1FA00FFF, "MC-lock"        },
    { 0x1FA01000, 0x1FA01FFF, "MC-RPSS_CTR"    },
    { 0x1FA02000, 0x1FA02FFF, "MC-GIO-DMA"     },
    { 0x1FA10000, 0x1FA1FFFF, "MC-semaphore"   },
    { 0x1FB80000, 0x1FB8FFFF, "HPC3-PBUS-DMA"  },
    { 0x1FB90000, 0x1FB93FFF, "HPC3-SCSI-DMA"  },
    { 0x1FB94000, 0x1FB97FFF, "HPC3-ENET-DMA"  },
    { 0x1FB98000, 0x1FB9FFFF, "HPC3-ENET-BDP"  },
    { 0x1FBB0000, 0x1FBB00FF, "HPC3-MISC"      },
    { 0x1FBC0000, 0x1FBCFFFF, "WD33C93-SCSI"   },
    { 0x1FBD4000, 0x1FBD4FFF, "SEEQ-ENET"      },
    { 0x1FBD8000, 0x1FBD83FF, "HAL2"           },
    { 0x1FBD8400, 0x1FBD87FF, "HPC3-PBUS-PIO1" },
    { 0x1FBD9000, 0x1FBD97FF, "HPC3-PBUS-PIO"  },
    { 0x1FBD9800, 0x1FBD982F, "IOC"            },
    { 0x1FBD9830, 0x1FBD9833, "SCC1_CMD"       },
    { 0x1FBD9834, 0x1FBD9837, "SCC1_DATA"      },
    { 0x1FBD9838, 0x1FBD983B, "SCC2_CMD"       },
    { 0x1FBD983C, 0x1FBD983F, "SCC2_DATA"      },
    { 0x1FBD9840, 0x1FBD987F, "IOC"            },
    { 0x1FBD9880, 0x1FBD98FF, "INT2"           },
    { 0x1FBD9900, 0x1FBD9FFF, "HPC3-EXT-IO"    },
    { 0x1FBDC000, 0x1FBDCFFF, "HPC3-CFG-DMA"   },
    { 0x1FBDD000, 0x1FBDDFFF, "HPC3-CFG-PIO"   },
    { 0x1FBE0000, 0x1FBE00FF, "DS1386-RTC"     },
    { 0x1FBE0100, 0x1FBE7FFF, "DS1386-NVRAM"   },
    { 0x1FBE8000, 0x1FBFFFFF, "HPC3"           },
    { 0x1FC00000, 0x1FC7FFFF, "PROM"           },
};

// Match by word overlap, not `addr >= lo && addr <= hi`. Bus transactions are
// doubleword aligned even for byte loads - byte selection is by byte enable,
// not by a different bus address - so the sandbox's original containment test
// silently never fired for a byte poll. That bug is recorded three times in
// the old codebase; this is the fixed form.
static const char *reg_name(uint32_t addr)
{
    uint32_t lo = addr, hi = addr + 7;
    for (const RegName &r : kRegNames)
        if (lo <= r.hi && hi >= r.lo) return r.name;
    return "?";
}

// ---- options -------------------------------------------------------------

struct Options {
    std::string elf, prom, dump_console;
    bool     testdev      = false;
    bool     trace        = false;
    bool     hot          = false;
    uint64_t max_cycles   = 4000ull * 1000 * 1000;
    uint64_t stuck_cycles = 0;
    uint32_t boot_pc      = 0xBFC00000;
    uint32_t ram_mb       = 64;
    uint64_t trace_from   = 0;
    uint64_t trace_count  = 2000;
    // Addresses to report every bus access to, doubleword-aligned. The PROM
    // runs from KSEG1, which the architecture defines as uncached, so every
    // instruction it executes is a bus read - which makes an address watch on
    // a PROM text address a PC watch, and the cheapest way to answer "is this
    // routine reached at all" without a trace of four million transactions.
    std::vector<uint32_t> watch;
    uint64_t watch_count = 20;
    std::string fbdump;
    std::string viddump;
    bool        fbindex = false;
    // --pc: print every PC the CPU decodes, from --pc-from, for --pc-count.
    // Expensive - one line per instruction - so it is off by default and the
    // ring buffer below is what a normal run relies on.
    // --ramdump ADDR:LEN:FILE, repeatable. ADDR is a MIPS address: KSEG0/KSEG1
    // are stripped, so 0x88010174 and 0x08010174 both name the same bytes.
    std::vector<std::array<std::string, 3>> ramdumps;
    // --pc-user FILE: cycle and PC for every USER-mode instruction entering
    // decode. Made for diffing two runs that should agree - the first
    // differing PC names the instruction where they parted company.
    //
    // READ THE CAVEAT BEFORE TRUSTING A DIFF OF THESE. This is the DECODE tap,
    // and decode re-presents an instruction on every pipeline replay and
    // stall. Two runs in different configurations replay in different places,
    // so a raw diff reports divergences that are not there - it will point at
    // a "loop" that is really a function prologue being replayed. Collapse
    // consecutive repeats in both streams before comparing, and treat the
    // result as a lead rather than as proof.
    std::string pcuser;
    bool        exc = false;
    uint64_t    exc_count = 200;
    // Cycle the exception log starts at. --trace-from-pc parks it out of
    // reach and the arm brings it back, so `--trace-from-pc P --exc` means
    // "every exception from the moment P is decoded" instead of "the first
    // 200 exceptions of the boot", which on a running kernel is timer
    // interrupts and nothing else. An explicit --pc-from after
    // --trace-from-pc still wins; one before it does not.
    uint64_t    exc_from = 0;
    // --trace-from-pc HEX: arm the bus trace the first time the CPU decodes
    // this PC. A cycle number cannot be known in advance for anything that
    // happens after a kernel has booted, and this is how a line fill for a
    // named instruction gets caught with its data.
    bool        trace_from_pc_set = false;
    uint32_t    trace_from_pc = 0;
    bool        pctrace = false;
    uint64_t    pc_from = 0;
    uint64_t    pc_count = 2000;
    // Newport fitted. Default on, because a real Indy always has a graphics
    // board; the serial-console regressions turn it off, because the PROM
    // moves its console to the graphics head as soon as it finds one.
    bool        gfx = true;
    // Which cpu_error bits abort the run. See kErrorNames: only the two that
    // mean the core itself is wedged are fatal by default.
    uint32_t fatal_errors = (1u << 1) | (1u << 4);   // stall, fifo
    bool     uart         = false;   // decode the txdb line as well
    // Keystrokes to send at the 8042, as (trigger, text). Same shape as
    // --type, but they arrive at the keyboard port rather than the serial
    // console, which is the only way to exercise the PC keyboard path.
    std::vector<std::pair<std::string, std::string>> keys;
    // Key batches fired at a cycle count rather than on console text.
    std::vector<std::pair<uint64_t, std::string>> keys_at;
    // Disk images, as ID=path. Repeatable; IDs 0..6.
    // (id, path, writable). See ScsiDisk in sim_devices.h for what writable
    // costs and buys: --disk keeps the host file untouched, --disk-rw does not.
    std::vector<std::tuple<int, std::string, bool>> disks;
    // Primary caches. Both on; the flags exist to bisect a failure onto one
    // of them without rebuilding, which is how the fill path was brought up.
    bool     icache       = true;
    bool     dcache       = true;
    // Strings to send at the console, in order. `first` is an optional trigger
    // that must have appeared in the console output before `second` is sent.
    std::vector<std::pair<std::string, std::string>> type;
    uint64_t idle_cycles  = 400000;  // console quiet time that counts as a prompt
    std::string stop_on;             // end the run when this appears on the console
    // Log every change of the five INT2 lines into the CPU, with the status
    // and mask registers that produced it. An interrupt that never fires and
    // an interrupt that fires and is ignored look identical from the console.
    bool     irq          = false;
};

// Turn the backslash escapes a shell argument can carry into bytes, so
// `--type '.go\r'` sends a carriage return rather than two characters.
static std::string unescape(const std::string &in)
{
    std::string out;
    for (size_t i = 0; i < in.size(); i++) {
        if (in[i] != '\\' || i + 1 == in.size()) { out.push_back(in[i]); continue; }
        switch (in[++i]) {
            case 'r': out.push_back('\r'); break;
            case 'n': out.push_back('\n'); break;
            case 't': out.push_back('\t'); break;
            case '0': out.push_back('\0'); break;
            default:  out.push_back(in[i]); break;
        }
    }
    return out;
}

//
// cpu.vhd's error_* outputs are N64 debugging aids, not faults, and treating
// them as faults stops the suite dead on its first deliberate trap:
//
//   error_instr      a `cache` op outside the ten the core implements
//                    (cpu.vhd:1921) - Index_Load_Tag on the I-cache is one
//   error_stall      the pipeline has not moved for 4096 clocks (cpu.vhd:3583)
//   error_FPU        an FPU exception was taken (cpu_FPU.vhd:605)
//   error_exception  AdEL/AdES/Bp/RI/Ov was taken (cpu_cop0.vhd:670)
//   error_fifo       the CPU's write FIFO overflowed
//   error_TLB        a TLB op was issued while the TLB machine was busy
//
// On an N64 an overflow trap or a reserved instruction means the game has gone
// wrong, so flagging them is useful there. Here the suite raises every one of
// them on purpose - excep/ alone takes fifteen - so they are counted and
// reported, and only a wedged pipeline or a FIFO overflow stops the run.
static const char *const kErrorNames[6] = {
    "instr(unimpl-cache-op)", "stall(pipeline-wedged)", "FPU-exception",
    "CPU-exception", "fifo-overflow", "TLB-busy"
};

static void usage()
{
    fprintf(stderr,
        "usage: Vsim_top [options]\n"
        "  --elf FILE        load a bare-metal ELF and boot from its entry point\n"
        "  --prom FILE       load a boot PROM image at 0x1FC00000\n"
        "  --boot-pc HEX     override the reset PC (default 0xBFC00000)\n"
        "  --testdev         fit the IRIS test device in GIO64 slot 0\n"
        "  --ram-mb N        main memory size (default 64)\n"
        "  --max-cycles N    give up after N clocks (default 4e9)\n"
        "  --stuck N         report no forward progress after N clocks\n"
        "  --irq             log every change of the INT2 interrupt lines\n"
        "  --trace           print a bus trace\n"
        "  --trace-from N    start the trace at cycle N\n"
        "  --trace-count N   how many transactions to print (default 2000)\n"
        "  --hot             on exit, list the most-accessed addresses\n"
        "  --fbdump FILE     on exit, write Newport's frame buffer as a PPM.\n"
        "                    Once graphics are found the PROM moves its console\n"
        "                    there and the serial port goes quiet\n"
        "  --viddump FILE    on exit, write what came out of the video PINS as a\n"
        "                    PPM - the index after XMAP9 and CMAP, not the store\n"
        "  --fbindex         dump the colour index as grey, not the colour\n"
        "  --ramdump A:N:F   on exit, write N bytes of guest RAM from address A\n"
        "                    to file F (repeatable). A is a MIPS address; KSEG0\n"
        "                    and KSEG1 are stripped, so 0x88010174 works. This\n"
        "                    is guestmem.py for the simulator: disassemble the\n"
        "                    result with tools/misterdeploy/disbin.py\n"
        "  --trace-from-pc H arm the bus trace the first time PC H is decoded\n"
        "                    (implies --trace). For catching the line fill that\n"
        "                    served a named instruction\n"
        "  --pc-user FILE    write every user-mode PC to FILE, one per line and\n"
        "                    nothing else, for diffing two runs against each other\n"
        "  --exc             one line per exception the CPU accepts: ExcCode,\n"
        "                    BadVAddr and EPC (first 200; --exc-count N).\n"
        "                    With --trace-from-pc it starts at the arm, not at\n"
        "                    cycle 0\n"
        "  --watch-count N   hits per --watch address to print (default 20)\n"
        "  --pc              print one line per decoded instruction. The last\n"
        "                    64 PCs are ALWAYS printed on exit, which is what\n"
        "                    names a wedge that has stopped touching the bus\n"
        "  --pc-from N       start the PC trace at cycle N (implies --pc)\n"
        "  --pc-count N      how many PCs to print (default 2000)\n"
        "  --no-gfx          leave Newport unfitted, which keeps the PROM's\n"
        "                    console on the serial port\n"
        "  --key-at N STR    press STR at the keyboard once cycle N is reached.\n"
        "                    --key-on triggers on console text, and there is no\n"
        "                    console once Newport is fitted\n"
        "  --watch HEX       report every bus access to HEX (repeatable). PROM\n"
        "                    text is uncached, so this is a PC watch\n"        "  --uart            also decode the SCC's txdb line and compare\n"
        "  --disk ID=PATH    attach a SCSI disk image at target ID (default 1),\n"
        "                    read-only: writes are kept in memory for the run\n"
        "  --disk-rw ID=PATH the same, but writes go through to the host file\n"
        "  --key TEXT        type TEXT at the PC keyboard port (not the console)\n"
        "  --key-on TRIG TEXT  the same, once TRIG has appeared on the console\n"
        "  --no-icache       run with the primary instruction cache off\n"
        "  --no-dcache       run with the primary data cache off\n"
        "  --type STR        type STR at the console once it goes quiet; repeatable.\n"
        "                    Understands \\r \\n \\t. Needs the machine to have\n"
        "                    transmitted first, to measure the bit rate\n"
        "  --type-on TRIG STR  the same, but only once TRIG has appeared in the\n"
        "                    console output. Far more reliable than the quiet rule\n"
        "                    during POST, where the gaps between lines are long\n"
        "  --idle N          console quiet time that counts as a prompt (default 400000)\n"
        "  --stop-on STR     end the run once STR has appeared on the console, so a\n"
        "                    scripted session does not sit out its stuck timer\n"
        "  --fatal-errors M  cpu_error bits that abort the run (default 0x12)\n"
        "  --console FILE    also write the console output to FILE\n");
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Options opt;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&](const char *what) -> const char * {
            if (i + 1 >= argc) { fprintf(stderr, "%s needs a value\n", what); exit(2); }
            return argv[++i];
        };
        if      (a == "--elf")         opt.elf = next("--elf");
        else if (a == "--prom")        opt.prom = next("--prom");
        else if (a == "--console")     opt.dump_console = next("--console");
        else if (a == "--boot-pc")     opt.boot_pc = strtoul(next("--boot-pc"), nullptr, 0);
        else if (a == "--testdev")     opt.testdev = true;
        else if (a == "--trace")       opt.trace = true;
        else if (a == "--irq")         opt.irq = true;
        else if (a == "--hot")         opt.hot = true;
        // Once Newport is fitted the PROM moves its console to the graphics
        // head, so the serial port stops being the whole story.
        else if (a == "--fbdump")     opt.fbdump = next("--fbdump");
        else if (a == "--viddump")    opt.viddump = next("--viddump");
        else if (a == "--fbindex")    opt.fbindex = true;
        else if (a == "--ramdump") {
            std::string spec = next("--ramdump");
            size_t c1 = spec.find(':'), c2 = spec.rfind(':');
            if (c1 == std::string::npos || c1 == c2) {
                fprintf(stderr, "--ramdump wants ADDR:LEN:FILE\n"); return 2;
            }
            opt.ramdumps.push_back({spec.substr(0, c1),
                                    spec.substr(c1 + 1, c2 - c1 - 1),
                                    spec.substr(c2 + 1)});
        }
        else if (a == "--trace-from-pc") { opt.trace = true; opt.trace_from_pc_set = true;
            // Park the start cycle out of reach until the PC is seen.
            opt.trace_from = ~0ull;
            opt.exc_from   = ~0ull;
            opt.pc_from    = ~0ull;
            opt.trace_from_pc = (uint32_t)strtoul(next("--trace-from-pc"), nullptr, 16); }
        else if (a == "--pc-user")    opt.pcuser = next("--pc-user");
        else if (a == "--exc")        opt.exc = true;
        else if (a == "--watch-count") opt.watch_count = strtoull(next("--watch-count"), nullptr, 0);
        else if (a == "--exc-count")  { opt.exc = true;
                                        opt.exc_count = strtoull(next("--exc-count"), nullptr, 0); }
        else if (a == "--pc")         opt.pctrace = true;
        else if (a == "--pc-from")    { opt.pctrace = true;
                                        opt.pc_from = strtoull(next("--pc-from"), nullptr, 0); }
        else if (a == "--pc-count")   opt.pc_count = strtoull(next("--pc-count"), nullptr, 0);
        else if (a == "--no-gfx")     opt.gfx = false;
        else if (a == "--watch")       opt.watch.push_back(
                 static_cast<uint32_t>(strtoul(next("--watch"), nullptr, 16)) & ~7u);
        else if (a == "--uart")        opt.uart = true;
        else if (a == "--disk") {
            // --disk ID=PATH, or --disk PATH for ID 1 (ID 0 is the host
            // adapter's own ID on SGI, so a disk never lives there).
            std::string spec = next("--disk");
            size_t eq = spec.find('=');
            if (eq == std::string::npos) opt.disks.push_back({1, spec, false});
            else opt.disks.push_back({atoi(spec.substr(0, eq).c_str()), spec.substr(eq + 1), false});
        }
        else if (a == "--disk-rw") {
            // The same, but writes go through to the host file. Deliberately a
            // separate flag: an install target wants persistence, and every
            // checked-in fixture wants protection from it.
            std::string spec = next("--disk-rw");
            size_t eq = spec.find('=');
            if (eq == std::string::npos) opt.disks.push_back({1, spec, true});
            else opt.disks.push_back({atoi(spec.substr(0, eq).c_str()), spec.substr(eq + 1), true});
        }
        else if (a == "--key")         opt.keys.push_back({"", unescape(next("--key"))});
        // --key-at exists because --key-on triggers on CONSOLE text, and once
        // Newport is fitted there is no console: the PROM draws its prompts
        // into the frame buffer. A cycle number is crude, but it is the only
        // trigger available for "type at the graphics head", which is the only
        // way anything reaches the keyboard controller at all.
        else if (a == "--key-at") {
            uint64_t at = strtoull(next("--key-at"), nullptr, 0);
            opt.keys_at.push_back({at, unescape(next("--key-at"))});
        }
        else if (a == "--key-on") {
            std::string ktrig = unescape(next("--key-on"));
            opt.keys.push_back({ktrig, unescape(next("--key-on"))});
        }
        else if (a == "--no-icache")   opt.icache = false;
        else if (a == "--no-dcache")   opt.dcache = false;
        else if (a == "--type")        opt.type.push_back({"", unescape(next("--type"))});
        else if (a == "--type-on") {
            std::string trig = unescape(next("--type-on"));
            opt.type.push_back({trig, unescape(next("--type-on"))});
        }
        else if (a == "--idle")        opt.idle_cycles = strtoull(next("--idle"), nullptr, 0);
        else if (a == "--stop-on")     opt.stop_on = unescape(next("--stop-on"));
        else if (a == "--ram-mb")      opt.ram_mb = strtoul(next("--ram-mb"), nullptr, 0);
        else if (a == "--max-cycles")  opt.max_cycles = strtoull(next("--max-cycles"), nullptr, 0);
        else if (a == "--stuck")       opt.stuck_cycles = strtoull(next("--stuck"), nullptr, 0);
        else if (a == "--trace-from")  opt.trace_from = strtoull(next("--trace-from"), nullptr, 0);
        else if (a == "--fatal-errors") opt.fatal_errors = strtoul(next("--fatal-errors"), nullptr, 0);
        else if (a == "--trace-count") opt.trace_count = strtoull(next("--trace-count"), nullptr, 0);
        else if (a == "-h" || a == "--help") { usage(); return 0; }
        else if (a.rfind("+", 0) == 0 || a.rfind("-V", 0) == 0) { /* verilator */ }
        else { fprintf(stderr, "unknown option %s\n", a.c_str()); usage(); return 2; }
    }

    g_dev.ram.resize(static_cast<size_t>(opt.ram_mb) * 1024 * 1024);
    g_dev.prom.resize(512 * 1024);
    g_dev.vram.resize(sgisim::VRAM_BYTES);
    g_dev.testdev.present = opt.testdev;

    uint32_t boot_pc = opt.boot_pc;

    if (!opt.prom.empty()) {
        FILE *f = fopen(opt.prom.c_str(), "rb");
        if (!f) { fprintf(stderr, "cannot open PROM %s\n", opt.prom.c_str()); return 2; }
        size_t n = fread(g_dev.prom.bytes.data(), 1, g_dev.prom.bytes.size(), f);
        fclose(f);
        printf("PROM: %s (%zu bytes)\n", opt.prom.c_str(), n);
    }

    if (!opt.elf.empty()) {
        ElfLoadResult r = load_elf(opt.elf);
        if (!r.ok) { fprintf(stderr, "ELF load failed: %s\n", r.error.c_str()); return 2; }
        printf("ELF: %s  entry %08x\n", opt.elf.c_str(), r.entry);
        for (const std::string &s : r.segments) printf("%s\n", s.c_str());
        // Boot straight into the image, the way IRIS's --load-elf does.
        if (opt.boot_pc == 0xBFC00000) boot_pc = r.entry;
    }

    for (auto &dd : opt.disks) {
        std::pair<int, std::string> d{std::get<0>(dd), std::get<1>(dd)};
        bool d_rw = std::get<2>(dd);
        if (d.first < 0 || d.first > 6) {
            fprintf(stderr, "SCSI id %d out of range (0..6)\n", d.first); return 2;
        }
        if (!g_dev.scsi[d.first].load(d.second, d_rw)) {
            fprintf(stderr, "cannot open disk %s\n", d.second.c_str()); return 2;
        }
        printf("SCSI %d: %s (%zu blocks)\n", d.first, d.second.c_str(),
               g_dev.scsi[d.first].blocks());
    }

    printf("boot PC %08x, RAM %u MB, testdev %s, I$ %s, D$ %s\n",
           boot_pc, opt.ram_mb, opt.testdev ? "yes" : "no",
           opt.icache ? "on" : "off", opt.dcache ? "on" : "off");
    fflush(stdout);

    // Opened up front and flushed per line, so a long run can be watched with
    // `tail -f` instead of only being readable once it has finished.
    FILE *pcuser_f = nullptr;
    FILE *console_f = nullptr;
    if (!opt.pcuser.empty()) {
        pcuser_f = fopen(opt.pcuser.c_str(), "wb");
        if (!pcuser_f) fprintf(stderr, "cannot write %s\n", opt.pcuser.c_str());
    }
    if (!opt.dump_console.empty()) {
        console_f = fopen(opt.dump_console.c_str(), "wb");
        if (!console_f) fprintf(stderr, "cannot write %s\n", opt.dump_console.c_str());
    }

    Vsim_top *top = new Vsim_top;
    top->reset       = 1;
    top->sclk        = 0;
    top->boot_pc     = boot_pc;
    // The MC's bank decode must agree with the memory actually behind it.
    top->mem_mb      = opt.ram_mb;
    top->gio_present = opt.testdev ? 1 : 0;
    top->gfx_present = opt.gfx ? 1 : 0;
    top->icache_en   = opt.icache ? 1 : 0;
    top->dcache_en   = opt.dcache ? 1 : 0;
    top->rxdb        = 1;                 // idle mark; nothing types at the console here
    top->ps2_key     = 0;
    top->ps2_mouse   = 0;
    top->clk         = 0;

    // ---- run ----
    std::string console;
    std::map<uint32_t, uint64_t> hits;
    std::map<uint32_t, uint64_t> watch_hits;
    struct Unclaimed { uint64_t count = 0, first = 0, last = 0; unsigned we = 0, re = 0; };
    std::map<uint32_t, Unclaimed> unclaimed;
    uint64_t cycle = 0, traced = 0, txns = 0;

    // No-forward-progress detector.
    //
    // "Progress" is a bus address the CPU has not touched in its last few
    // transactions, or a byte on the console. A poll loop cycles round a
    // handful of addresses forever and produces neither, which is exactly the
    // failure this is for: the PROM waiting on a register that never returns
    // what it wants.
    //
    // Watching a high-water address instead does not work - it stops rising
    // as soon as the program has touched the top of its working set, and then
    // fires on the next long-running test.
    static const int RECENT = 32;
    uint32_t recent[RECENT] = {0};
    int      recent_at = 0;
    uint64_t last_progress = 0;
    uint32_t stuck_addr = 0;
    uint64_t stuck_hits = 0;

    // THE LAST 64 PCs, ALWAYS. A wedge that stops touching the bus - an IRIX
    // kernel spinning in a loop that fits in the caches - leaves the stuck
    // detector with nothing to name and the bus trace ending mid-routine.
    // These sixty-four entries are the loop itself. They cost two stores per
    // instruction and are worth it: without them the only way to see a
    // cached loop is to rebuild with --no-icache and wait out a much slower
    // boot. See rtl/cpu/r4300/cpu.vhd's dbg_pc for where they come from.
    static const int PCRING = 64;
    uint32_t pcring[PCRING] = {0};
    uint64_t pcring_cy[PCRING] = {0};
    int      pcring_at = 0;
    uint64_t pcs = 0, pcs_traced = 0;
    uint64_t excs = 0;
    // See the exception log below: the line is emitted one clock after the
    // acceptance, because that is when EPC is valid.
    static const char *const kExcName[32] = {
        "Int","TLBMod","TLBL","TLBS","AdEL","AdES","IBE","DBE",
        "Sys","Bp","RI","CpU","Ov","Tr","?","FPE",
        "?","?","?","?","?","?","?","?",
        "?","?","?","?","?","?","?","?"};
    bool     exc_pending = false;
    uint64_t exc_cycle   = 0;
    uint32_t exc_code    = 0, exc_bad = 0;
    uint64_t retired = 0;

    // The same, for USER-mode instructions only - anything the CPU decoded
    // with Status.KSU saying user and EXL/ERL clear (dbg_mode's top two bits).
    // A kernel that reports a signal 11 in a process has already unwound the
    // fault by the time it says so, and the general ring is full of the
    // kernel's own reporting path by then; this one still holds the
    // instructions that actually trapped.
    uint32_t upcring[PCRING] = {0};
    uint64_t upcring_cy[PCRING] = {0};
    int      upcring_at = 0;
    uint64_t upcs = 0;

    UartRx   uart;
    UartTx   utx;
    Ps2Injector ps2;
    size_t key_at_n = 0;
    ScsiBlockDev scsi_dev;
    size_t   key_at = 0;
    size_t   type_at = 0;          // next --type string to send
    size_t   type_seen_from = 0;   // a trigger only counts after the last send
    uint64_t last_console = 0;     // cycle of the last byte the machine printed
    int rc = -1;
    const char *stop_reason = "max-cycles";
    // With the real SCC in the core, a bare-metal image that never programs
    // WR5 gets nothing out of the transmitter - the same as on real hardware,
    // and the reason cpu-tests has a test device at all. Console output can
    // therefore arrive on either sink, so both are drained into `console`.
    size_t td_seen = 0;
    uint64_t err_count[6] = {0};
    uint8_t  err_prev = 0;

    // What actually came out of the video pins. Built from the output side
    // rather than from the frame buffer store on purpose: a picture taken from
    // the store would look right even if VC2's timing generator were emitting
    // nonsense. See verilator/sim_video_cap.h.
    VideoCapture vidcap;

    auto tick = [&](int v) { top->clk = v; top->eval(); };

    for (; cycle < opt.max_cycles; cycle++) {
        if (cycle == 8) top->reset = 0;

        tick(1);

        // SCC serial clock. Divided from the system clock purely so the
        // serialiser runs at a sane fraction of it in simulation; on hardware
        // this is a 3.6864 MHz PLL output. Nothing the harness reads depends
        // on the ratio.
        if ((cycle & (SCLK_DIV - 1)) == 0) top->sclk = !top->sclk;

        // Always decode the wire, not just under --uart: the measured bit time
        // is what --type sends at, and it costs a comparison per cycle.
        vidcap.step(top->vid_ce_pix, top->vid_de, top->vid_hsync, top->vid_vsync,
                    top->vid_r, top->vid_g, top->vid_b);

        uart.sample(cycle, top->txdb);
        utx.step(cycle, uart.bit_time);
        top->rxdb = utx.line;
        ps2.step(top, cycle);
        scsi_dev.step(top);

        // Key batches with a cycle trigger, for the graphics console.
        if (key_at_n < opt.keys_at.size() && cycle >= opt.keys_at[key_at_n].first
            && ps2.idle()) {
            const std::string &text = opt.keys_at[key_at_n].second;
            fprintf(stderr, "[%10llu] pressing %zu key(s) at the graphics head\n",
                    static_cast<unsigned long long>(cycle), text.size());
            for (char c : text) {
                uint8_t code; bool shift;
                if (!ps2_code_for_ascii(c, code, shift)) continue;
                if (shift) ps2.push_key(0x12, false, true);
                ps2.tap(code);
                if (shift) ps2.push_key(0x12, false, false);
            }
            key_at_n++;
        }

        // Queue the next --key/--key-on batch once its trigger has been seen
        // and the previous batch has drained.
        if (key_at < opt.keys.size() && ps2.idle()) {
            const std::string &ktrig = opt.keys[key_at].first;
            if (ktrig.empty() || console.find(ktrig) != std::string::npos) {
                for (char c : opt.keys[key_at].second) {
                    uint8_t code; bool shift;
                    if (!ps2_code_for_ascii(c, code, shift)) continue;
                    if (shift) ps2.push_key(0x12, false, true);   // left shift down
                    ps2.tap(code);
                    if (shift) ps2.push_key(0x12, false, false);
                }
                key_at++;
            }
        }

        // Send the next --type string once the machine has stopped talking.
        // Waiting for quiet rather than for a particular prompt string keeps
        // this useful for "[Press any key to continue.]" and for the Command
        // Monitor alike, and avoids matching a prompt inside a diagnostic.
        if (type_at < opt.type.size() && uart.bit_time && !utx.busy() &&
            last_console && cycle - last_console > opt.idle_cycles) {
            const std::string &trig = opt.type[type_at].first;
            bool armed = trig.empty() ||
                         console.find(trig, type_seen_from) != std::string::npos;
            if (armed) {
                const std::string &text = opt.type[type_at].second;
                for (unsigned char c : text) utx.queue.push_back(c);
                fprintf(stderr, "[%10llu] typing %zu bytes at the console%s%s\n",
                        static_cast<unsigned long long>(cycle), text.size(),
                        trig.empty() ? "" : " after ", trig.c_str());
                fflush(stderr);
                type_at++;
                type_seen_from = console.size();
                last_console = cycle;      // do not fire again until it answers
            }
        }

        if (top->tx_valid) {
            last_progress = cycle;
            last_console  = cycle;
            char c = static_cast<char>(top->tx_data);
            console.push_back(c);
            fputc(c, stdout);
            if (console_f) fputc(c, console_f);
            if (c == '\n') { fflush(stdout); if (console_f) fflush(console_f); }
        }

        if (top->bus_ack) {
            txns++;
            uint32_t a = top->bus_addr;
            if (opt.hot) hits[a]++;
            bool seen = false;
            for (int k = 0; k < RECENT; k++) if (recent[k] == a) { seen = true; break; }
            if (!seen) {
                recent[recent_at] = a;
                recent_at = (recent_at + 1) % RECENT;
                last_progress = cycle;
            }

            if (opt.trace && cycle >= opt.trace_from && traced < opt.trace_count) {
                // HOLE is the one that matters to a lost store: the cycle was
                // acknowledged, the address and the data on it are the CPU's,
                // and main memory never saw it, because MEMCFG has no bank
                // covering that address. It is indistinguishable from a good
                // write on the three signals above.
                printf("[%10llu] %s %08x %-14s data %016llx be %02x %s\n",
                       static_cast<unsigned long long>(cycle),
                       top->bus_we ? "WR" : "RD", a, reg_name(a),
                       static_cast<unsigned long long>(
                           top->bus_we ? top->bus_wdata : top->bus_rdata),
                       top->bus_be,
                       top->bus_hole ? "HOLE" : top->bus_mem ? "ram" : "dev");
                traced++;
            }
            for (uint32_t w : opt.watch) {
                if ((a & ~7u) == w) {
                    watch_hits[w]++;
                    if (watch_hits[w] <= opt.watch_count)
                        printf("[%10llu] WATCH %08x %s %08x data %016llx be %02x"
                               " %-4s hit %llu\n",
                               static_cast<unsigned long long>(cycle), w,
                               top->bus_we ? "WR" : "RD", a,
                               static_cast<unsigned long long>(
                                   top->bus_we ? top->bus_wdata : top->bus_rdata),
                               top->bus_be,
                               top->bus_hole ? "HOLE" : top->bus_mem ? "ram" : "dev",
                               static_cast<unsigned long long>(watch_hits[w]));
                }
            }
            if (a == stuck_addr) stuck_hits++; else { stuck_addr = a; stuck_hits = 1; }
        }

        // INT2's five lines into the CPU, printed on every change. `stat`
        // and `mask` are the pair that decided it, so a line that should have
        // fired but did not is one line of output away from its reason: an
        // asserted status bit against a zero mask is software that has not
        // enabled the source, and a clear status bit is the device.
        if (opt.irq) {
            static uint32_t prev_lines = 0xffffffff;
            static uint64_t prev_state = ~0ull;
            uint64_t st = top->int2_state;
            if (top->irq_lines != prev_lines || st != prev_state) {
                printf("[%10llu] IRQ IP[6:2]=%c%c%c%c%c  L0 %02x/%02x  "
                       "L1 %02x/%02x  MAP %02x\n",
                       static_cast<unsigned long long>(cycle),
                       (top->irq_lines & 16) ? '6' : '.',
                       (top->irq_lines &  8) ? '5' : '.',
                       (top->irq_lines &  4) ? '4' : '.',
                       (top->irq_lines &  2) ? '3' : '.',
                       (top->irq_lines &  1) ? '2' : '.',
                       (unsigned)((st >>  0) & 0xff), (unsigned)((st >>  8) & 0xff),
                       (unsigned)((st >> 16) & 0xff), (unsigned)((st >> 24) & 0xff),
                       (unsigned)((st >> 32) & 0xff));
                prev_lines = top->irq_lines;
                prev_state = st;
            }
        }

        // One line per exception the CPU accepts, under --exc. ExcCode is what
        // separates a TLB miss from an address error from a reserved
        // instruction, and from the console all three are "generated trap".
        // ONE CYCLE LATE, DELIBERATELY. cpu_cop0.vhd raises dbg_exc on the
        // clock it ACCEPTS the exception, and writes EPC on the clock after
        // that (`if (exception = '1') then COP0_14_EPC <= nextEPC_1`). Printed
        // on the pulse itself, `epc=` is therefore the PREVIOUS exception's -
        // which reads as a plausible address and is wrong, the worst kind of
        // instrument. Cause and BadVAddr settle with the pulse, so they are
        // captured there and the line is emitted one clock later with an EPC
        // that belongs to it.
        if (exc_pending) {
            exc_pending = false;
            excs++;
            if (excs <= opt.exc_count)
                printf("[%10llu] EXC %-6s code=%02x badvaddr=%08x epc=%08x\n",
                       static_cast<unsigned long long>(exc_cycle),
                       kExcName[exc_code & 31], exc_code, exc_bad,
                       top->dbg_exc_epc);
        }
        if (opt.exc && top->dbg_exc && cycle >= opt.exc_from) {
            exc_pending = true;
            exc_cycle   = cycle;
            exc_code    = top->dbg_exc_code;
            exc_bad     = top->dbg_exc_bad;
        }

        // The PC of whatever entered decode this clock. Recorded on every
        // instruction, printed only on exit (or under --pc).
        if (top->dbg_pc_valid) {
            pcs++;
            pcring[pcring_at]    = top->dbg_pc;
            pcring_cy[pcring_at] = cycle;
            pcring_at = (pcring_at + 1) % PCRING;
            if (opt.trace_from_pc_set && top->dbg_pc == opt.trace_from_pc &&
                opt.trace_from > cycle) {
                opt.trace_from = cycle;
                if (opt.exc_from == ~0ull) opt.exc_from = cycle;
                if (opt.pc_from  == ~0ull) opt.pc_from  = cycle;
                fprintf(stderr, "[%10llu] trace armed at PC %08x\n",
                        static_cast<unsigned long long>(cycle), top->dbg_pc);
            }
            if ((top->dbg_mode >> 2) != 0) {
                upcs++;
                if (pcuser_f) fprintf(pcuser_f, "%10llu %08x\n",
                                      static_cast<unsigned long long>(cycle),
                                      top->dbg_pc);
                if (pcuser_f) fprintf(pcuser_f, "%10llu %08x\n",
                                      static_cast<unsigned long long>(cycle), top->dbg_pc);
                upcring[upcring_at]    = top->dbg_pc;
                upcring_cy[upcring_at] = cycle;
                upcring_at = (upcring_at + 1) % PCRING;
            }
            if (opt.pctrace && cycle >= opt.pc_from && pcs_traced < opt.pc_count) {
                printf("[%10llu] PC %08x  ksu=%u %s %s\n",
                       static_cast<unsigned long long>(cycle), top->dbg_pc,
                       (unsigned)(top->dbg_mode >> 2),
                       (top->dbg_mode & 2) ? "64" : "32",
                       (top->dbg_mode & 1) ? "tlb" : "unmapped");
                pcs_traced++;
            }
        }

        // dbg_retire / dbg_rpc are wired all the way out to here and are NOT
        // used, deliberately. They were added to give --pc-user one line per
        // instruction RETIRED, which is what a diff of two runs wants; the
        // stream that came back was interleaved rather than sequential, so the
        // mirror of pcOld2..4 in cpu.vhd does not yet track the pipeline the
        // way pcOld2..4 do. Finishing it is worth doing - see docs/06 - but an
        // instrument that looks right and is not is worse than none, so
        // --pc-user stays on the decode tap below, whose one quirk (an
        // instruction re-presented on a pipeline replay) is documented.
        if (top->dbg_retire) retired++;

        // Unclaimed cycles are collected, not printed: an undecoded register
        // in a poll loop produces one line per iteration and buries everything
        // else. The summary on exit is what actually answers "what does the
        // PROM want next", which is the whole reason this signal exists.
        if (top->bus_unclaimed) {
            Unclaimed &u = unclaimed[top->bus_addr];
            if (!u.count) u.first = cycle;
            u.last = cycle;
            u.count++;
            u.we |= top->bus_we ? 1u : 0u;
            u.re |= top->bus_we ? 0u : 1u;
        }

        // Count rising edges only; error_exception latches high for the rest
        // of the run once anything has trapped.
        if (top->cpu_error != err_prev) {
            uint8_t rising = top->cpu_error & ~err_prev;
            for (int b = 0; b < 6; b++)
                if (rising & (1u << b)) {
                    err_count[b]++;
                    if (opt.trace)
                        fprintf(stderr, "[%10llu] cpu_error %s\n",
                                static_cast<unsigned long long>(cycle), kErrorNames[b]);
                }
            err_prev = top->cpu_error;
        }
        if (top->cpu_error & opt.fatal_errors) {
            fprintf(stderr, "[%10llu] fatal cpu_error %02x\n",
                    static_cast<unsigned long long>(cycle), top->cpu_error);
            stop_reason = "cpu-error";
            break;
        }

        {
            const std::string &td = g_dev.testdev.out;
            while (td_seen < td.size()) {
                char c = td[td_seen++];
                last_progress = cycle;
                last_console  = cycle;
                if (c == '\r') continue;
                console.push_back(c);
                fputc(c, stdout);
                if (console_f) fputc(c, console_f);
                if (c == '\n') { fflush(stdout); if (console_f) fflush(console_f); }
            }
        }

        tick(0);

        if (g_dev.testdev.exited) {
            rc = static_cast<int>(g_dev.testdev.exit_code);
            stop_reason = "testdev-exit";
            break;
        }

        if (opt.stuck_cycles && cycle - last_progress > opt.stuck_cycles) {
            fprintf(stderr,
                    "\n[%10llu] no new bus address and no console output for "
                    "%llu cycles; hammering %08x (%s) x%llu\n",
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned long long>(opt.stuck_cycles),
                    stuck_addr, reg_name(stuck_addr),
                    static_cast<unsigned long long>(stuck_hits));
            stop_reason = "stuck";
            break;
        }

        // A scripted PROM session knows when it is finished; without this it
        // would sit out the whole no-progress timer after its last command.
        if (!opt.stop_on.empty() && !utx.busy() &&
            console.find(opt.stop_on) != std::string::npos) {
            stop_reason = "stop-on";
            rc = 0;
            break;
        }

        // Without a test device the DONE line is the result, exactly as
        // run-prom.sh treats it.
        if (rc < 0 && console.size() > 20) {
            size_t p = console.rfind("IRIS-CPUTEST-DONE rc=");
            if (p != std::string::npos) {
                size_t q = console.find('\n', p);
                if (q != std::string::npos) {
                    rc = atoi(console.c_str() + p + strlen("IRIS-CPUTEST-DONE rc="));
                    stop_reason = "done-line";
                    break;
                }
            }
        }
    }

    top->final();

    printf("\n--- %s after %llu cycles, %llu bus transactions ---\n",
           stop_reason, static_cast<unsigned long long>(cycle),
           static_cast<unsigned long long>(txns));

    if (!g_dev.testdev.out.empty())
        printf("testdev console: %zu bytes\n", g_dev.testdev.out.size());

    if (opt.uart) {
        printf("uart: bit time %llu clocks, %zu bytes decoded off txdb, "
               "%u framing errors\n",
               static_cast<unsigned long long>(uart.bit_time), uart.out.size(),
               uart.framing_errors);
        printf("uart: \"");
        for (char c : uart.out)
            if (c == '\n') printf("\\n"); else if (c >= 32 && c < 127) putchar(c);
            else printf("\\x%02x", static_cast<unsigned char>(c));
        printf("\"\n");
        // The tap and the wire must agree. The tap sees the calibration
        // character too, the wire decode does not, so compare on the tail.
        std::string tapped = console;
        if (!uart.out.empty() && tapped.size() >= uart.out.size() &&
            tapped.compare(tapped.size() - uart.out.size(),
                           uart.out.size(), uart.out) == 0) {
            printf("uart: MATCHES the byte tap\n");
        } else {
            printf("uart: DIFFERS from the byte tap; tap was \"");
            for (char c : tapped)
                if (c == '\n') printf("\\n"); else if (c >= 32 && c < 127) putchar(c);
                else printf("\\x%02x", static_cast<unsigned char>(c));
            printf("\" (%zu bytes)\n", tapped.size());
            if (rc == 0) rc = 1;
        }
    }

    for (const auto &d : opt.ramdumps) {
        uint32_t a = static_cast<uint32_t>(strtoul(d[0].c_str(), nullptr, 0));
        uint32_t n = static_cast<uint32_t>(strtoul(d[1].c_str(), nullptr, 0));
        // KSEG0/KSEG1 -> physical, then physical -> offset into the RAM store.
        if ((a >> 29) == 4 || (a >> 29) == 5) a &= 0x1fffffffu;
        uint32_t off = a - 0x08000000u;
        if (a < 0x08000000u || off + n > g_dev.ram.size()) {
            fprintf(stderr, "--ramdump %s: not in RAM\n", d[0].c_str());
            continue;
        }
        FILE *f = fopen(d[2].c_str(), "wb");
        if (!f) { fprintf(stderr, "cannot write %s\n", d[2].c_str()); continue; }
        fwrite(g_dev.ram.bytes.data() + off, 1, n, f);
        fclose(f);
        printf("ramdump %08x +%u -> %s\n", a, n, d[2].c_str());
    }

    if (upcs) {
        printf("last %d USER-mode PCs (oldest first), %llu total:\n",
               (int)(upcs < PCRING ? upcs : PCRING),
               static_cast<unsigned long long>(upcs));
        int n = (int)(upcs < PCRING ? upcs : PCRING);
        for (int i = 0; i < n; i++) {
            int k = (upcring_at - n + i + PCRING) % PCRING;
            printf("  [%10llu] %08x\n",
                   static_cast<unsigned long long>(upcring_cy[k]), upcring[k]);
        }
    }

    // The last sixty-four instructions, oldest first. Read the CYCLES as much
    // as the addresses: a tight loop repeating with no gaps is a spin, and the
    // same PC arriving after a long gap is the machine having waited.
    if (pcs) {
        printf("last %d PCs decoded (oldest first), %llu total:\n",
               (int)(pcs < PCRING ? pcs : PCRING),
               static_cast<unsigned long long>(pcs));
        int n = (int)(pcs < PCRING ? pcs : PCRING);
        for (int i = 0; i < n; i++) {
            int k = (pcring_at - n + i + PCRING) % PCRING;
            printf("  [%10llu] %08x\n",
                   static_cast<unsigned long long>(pcring_cy[k]), pcring[k]);
        }
    }

    {
        bool any = false;
        for (int b = 0; b < 6; b++) if (err_count[b]) any = true;
        if (any) {
            printf("cpu_error flags raised (informational unless fatal):\n");
            for (int b = 0; b < 6; b++)
                if (err_count[b])
                    printf("  %-24s %llu\n", kErrorNames[b],
                           static_cast<unsigned long long>(err_count[b]));
        }
    }

    if (!unclaimed.empty()) {
        // Sorted by address, not by count: the point is to read this as a map
        // of the holes in the decode, and adjacent registers of one missing
        // device should sit together.
        uint64_t total = 0;
        for (const auto &e : unclaimed) total += e.second.count;
        printf("unclaimed bus cycles: %llu, at %zu distinct addresses\n",
               static_cast<unsigned long long>(total), unclaimed.size());
        size_t shown = 0;
        for (const auto &e : unclaimed) {
            if (shown++ >= 32) {
                printf("  ... and %zu more addresses\n", unclaimed.size() - 32);
                break;
            }
            printf("  %08x %-16s %-3s x%-8llu  first %llu last %llu\n",
                   e.first, reg_name(e.first),
                   e.second.we && e.second.re ? "R/W" : e.second.we ? "W" : "R",
                   static_cast<unsigned long long>(e.second.count),
                   static_cast<unsigned long long>(e.second.first),
                   static_cast<unsigned long long>(e.second.last));
        }
    }

    if (!opt.watch.empty()) {
        printf("watched addresses:\n");
        for (uint32_t w : opt.watch)
            printf("  %08x %llu hits\n", w,
                   static_cast<unsigned long long>(watch_hits[w]));
    }

    if (opt.hot) {
        std::vector<std::pair<uint32_t, uint64_t>> v(hits.begin(), hits.end());
        std::sort(v.begin(), v.end(),
                  [](const auto &a, const auto &b) { return a.second > b.second; });
        printf("hottest addresses:\n");
        for (size_t i = 0; i < v.size() && i < 15; i++)
            printf("  %08x %-14s %llu\n", v[i].first, reg_name(v[i].first),
                   static_cast<unsigned long long>(v[i].second));
    }

    // Newport's own summary. Frames and their measured size come from the
    // pins, so a non-zero line here is the video timing table having been
    // walked correctly all the way round a frame; the lit count is REX3
    // having put something in the frame buffer for the readout to find.
    if (opt.gfx) {
        printf("video: %llu frames, best %dx%d, last %dx%d, %llu lit pixels\n",
               static_cast<unsigned long long>(vidcap.frames),
               vidcap.best_w, vidcap.best_h, vidcap.seen_w, vidcap.seen_h,
               static_cast<unsigned long long>(vidcap.lit));
        printf("video edges: %llu hsync, %llu vsync, %llu display-enable, "
               "%llu displayed pixels\n",
               static_cast<unsigned long long>(vidcap.hsyncs),
               static_cast<unsigned long long>(vidcap.vsyncs),
               static_cast<unsigned long long>(vidcap.de_rises),
               static_cast<unsigned long long>(vidcap.de_pixels));
        // Per channel, because a dead one is invisible everywhere else. See
        // sim_video_cap.h.
        printf("video colour: %llu red, %llu green, %llu blue pixels\n",
               static_cast<unsigned long long>(vidcap.chan[0]),
               static_cast<unsigned long long>(vidcap.chan[1]),
               static_cast<unsigned long long>(vidcap.chan[2]));
    }

    if (!opt.viddump.empty()) {
        if (dump_video_ppm(opt.viddump, vidcap))
            printf("video output written to %s\n", opt.viddump.c_str());
        else
            printf("could not write %s (no complete frame?)\n", opt.viddump.c_str());
    }

    if (!opt.fbdump.empty()) {
        if (dump_framebuffer_ppm(opt.fbdump, 1280, 1024, opt.fbindex))
            printf("frame buffer written to %s\n", opt.fbdump.c_str());
        else
            printf("could not write %s\n", opt.fbdump.c_str());
    }

    if (pcuser_f) fclose(pcuser_f);
    if (console_f) fclose(console_f);

    delete top;
    return rc < 0 ? 1 : rc;
}
