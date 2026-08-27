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

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <map>
#include <vector>
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
    { 0x08000000, 0x0BFFFFFF, "RAM"            },
    { 0x00000000, 0x0007FFFF, "RAM-alias"      },
    { 0x1F400000, 0x1F5FFFFF, "GIO0"           },
    { 0x1FA00000, 0x1FA1FFFF, "MC"             },
    { 0x1FB80000, 0x1FB8FFFF, "HPC3"           },
    { 0x1FBD9830, 0x1FBD9833, "SCC1_CMD"       },
    { 0x1FBD9834, 0x1FBD9837, "SCC1_DATA"      },
    { 0x1FBD9838, 0x1FBD983B, "SCC2_CMD"       },
    { 0x1FBD983C, 0x1FBD983F, "SCC2_DATA"      },
    { 0x1FBD9800, 0x1FBD98FF, "IOC"            },
    { 0x1FBE0000, 0x1FBE3FFF, "DS1386-NVRAM"   },
    { 0x1F0F0000, 0x1F0FFFFF, "NEWPORT-REX3"   },
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
    // Which cpu_error bits abort the run. See kErrorNames: only the two that
    // mean the core itself is wedged are fatal by default.
    uint32_t fatal_errors = (1u << 1) | (1u << 4);   // stall, fifo
    bool     uart         = false;   // decode the txdb line as well
};

//
// A UART receiver on the SCC's channel-B transmit pin.
//
// The byte tap in sgi_scc.sv says what the CPU handed the transmitter; this
// says what actually came out of it. A model that queued the writes but never
// shifted anything would satisfy the first and fail this, which is the whole
// point of running both.
//
// The bit time is measured rather than configured: it is the width of the
// first start bit, which is why tests/scc/scctest.c sends 'U' first. 'U'
// alternates, so the low run at the start of that frame is exactly one bit;
// after a character with bit 0 clear it would be two and every later frame
// would sample in the wrong place.
struct UartRx {
    uint64_t bit_time = 0;
    uint64_t fall_at  = 0;
    bool     in_frame = false;
    int      bit_idx  = 0;
    uint32_t shift    = 0;
    uint8_t  prev     = 1;
    uint64_t stop_at  = 0;
    bool     stop_due = false;
    unsigned framing_errors = 0;
    std::string out;

    void sample(uint64_t cycle, uint8_t line)
    {
        if (bit_time == 0) {
            // Auto-baud: time the first low run, which is the first start bit.
            if (prev == 1 && line == 0) fall_at = cycle;
            if (prev == 0 && line == 1 && fall_at) {
                bit_time = cycle - fall_at;
                // Keep decoding this same frame rather than resynchronising:
                // fall_at already marks its start bit, and the first data-bit
                // sample is still half a bit away. Waiting for the next start
                // bit instead would find one inside this character's own data
                // and every frame after it would be a bit out.
                in_frame = true;
                bit_idx  = 0;
                shift    = 0;
            }
            prev = line;
            return;
        }
        // A frame ends with one stop bit at mark. Checking it catches a
        // mis-measured bit time, which otherwise shows up only as plausible
        // wrong characters.
        if (stop_due && cycle >= stop_at) {
            stop_due = false;
            if (line == 0) framing_errors++;
        }

        if (!in_frame) {
            if (prev == 1 && line == 0) {    // start bit
                in_frame = true;
                bit_idx  = 0;
                shift    = 0;
                fall_at  = cycle;
            }
        } else {
            // Sample each data bit in the middle of its cell.
            uint64_t want = fall_at + bit_time + bit_time / 2 + bit_time * bit_idx;
            if (cycle >= want && bit_idx < 8) {
                shift |= (line & 1u) << bit_idx;   // LSB first
                bit_idx++;
                if (bit_idx == 8) {
                    out.push_back(static_cast<char>(shift & 0xFF));
                    in_frame = false;
                    stop_at  = fall_at + bit_time * 9 + bit_time / 2;
                    stop_due = true;
                }
            }
        }
        prev = line;
    }
};

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
        "  --trace           print a bus trace\n"
        "  --trace-from N    start the trace at cycle N\n"
        "  --trace-count N   how many transactions to print (default 2000)\n"
        "  --hot             on exit, list the most-accessed addresses\n"
        "  --uart            also decode the SCC's txdb line and compare\n"
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
        else if (a == "--hot")         opt.hot = true;
        else if (a == "--uart")        opt.uart = true;
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

    printf("boot PC %08x, RAM %u MB, testdev %s\n",
           boot_pc, opt.ram_mb, opt.testdev ? "yes" : "no");
    fflush(stdout);

    Vsim_top *top = new Vsim_top;
    top->reset       = 1;
    top->sclk        = 0;
    top->boot_pc     = boot_pc;
    top->gio_present = opt.testdev ? 1 : 0;
    top->clk         = 0;

    // ---- run ----
    std::string console;
    std::map<uint32_t, uint64_t> hits;
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

    UartRx uart;
    int rc = -1;
    const char *stop_reason = "max-cycles";
    // With the real SCC in the core, a bare-metal image that never programs
    // WR5 gets nothing out of the transmitter - the same as on real hardware,
    // and the reason cpu-tests has a test device at all. Console output can
    // therefore arrive on either sink, so both are drained into `console`.
    size_t td_seen = 0;
    uint64_t err_count[6] = {0};
    uint8_t  err_prev = 0;

    auto tick = [&](int v) { top->clk = v; top->eval(); };

    for (; cycle < opt.max_cycles; cycle++) {
        if (cycle == 8) top->reset = 0;

        tick(1);

        // SCC serial clock. Divided from the system clock purely so the
        // serialiser runs at a sane fraction of it in simulation; on hardware
        // this is a 3.6864 MHz PLL output. Nothing the harness reads depends
        // on the ratio.
        if ((cycle & (SCLK_DIV - 1)) == 0) top->sclk = !top->sclk;

        if (opt.uart) uart.sample(cycle, top->txdb);

        if (top->tx_valid) {
            last_progress = cycle;
            char c = static_cast<char>(top->tx_data);
            console.push_back(c);
            fputc(c, stdout);
            if (c == '\n') fflush(stdout);
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
                printf("[%10llu] %s %08x %-14s data %016llx be %02x\n",
                       static_cast<unsigned long long>(cycle),
                       top->bus_we ? "WR" : "RD", a, reg_name(a),
                       static_cast<unsigned long long>(
                           top->bus_we ? top->bus_wdata : top->bus_rdata),
                       top->bus_be);
                traced++;
            }
            if (a == stuck_addr) stuck_hits++; else { stuck_addr = a; stuck_hits = 1; }
        }

        if (top->bus_unclaimed)
            fprintf(stderr, "[%10llu] unclaimed bus cycle at %08x\n",
                    static_cast<unsigned long long>(cycle), top->bus_addr);

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
                if (c == '\r') continue;
                console.push_back(c);
                fputc(c, stdout);
                if (c == '\n') fflush(stdout);
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

    if (opt.hot) {
        std::vector<std::pair<uint32_t, uint64_t>> v(hits.begin(), hits.end());
        std::sort(v.begin(), v.end(),
                  [](const auto &a, const auto &b) { return a.second > b.second; });
        printf("hottest addresses:\n");
        for (size_t i = 0; i < v.size() && i < 15; i++)
            printf("  %08x %-14s %llu\n", v[i].first, reg_name(v[i].first),
                   static_cast<unsigned long long>(v[i].second));
    }

    if (!opt.dump_console.empty()) {
        FILE *f = fopen(opt.dump_console.c_str(), "wb");
        if (f) { fwrite(console.data(), 1, console.size(), f); fclose(f); }
    }

    delete top;
    return rc < 0 ? 1 : rc;
}
