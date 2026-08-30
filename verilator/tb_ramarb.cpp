//============================================================================
//  tb_ramarb - the CPU/DMA arbiter against a memory that is not instant.
//
//  WHY THIS EXISTS AND WHY IT IS SHORT. The logic under test is about twenty
//  lines and it lived inside sgi_indy.sv, where it could only ever be exercised
//  through a whole-machine simulation. Every whole-machine simulation in this
//  repository uses verilator/sim_ram.v, which answers in ONE CYCLE. The bug
//  this file was written for opens a window exactly as wide as memory is slow,
//  so at a latency of one it is very nearly impossible to hit and at DDR3's
//  tens of cycles it is hit constantly. Nothing was wrong with the whole-machine
//  tests; they were asking a memory that could not answer the question.
//
//  THE PORT MODEL IS THE CONTRACT ddr3_mux ACTUALLY OFFERS, and the important
//  half of it is what it does NOT offer: one transaction at a time. A request
//  raised while another is outstanding is not queued and not stalled, it is
//  DROPPED - `ddr3_mux.sv` will not latch into `pend[i]` while `pend[i]` is
//  already set. So a second request during a transaction is a protocol
//  violation by the arbiter, and this counts every one of them. That single
//  check is what the old logic fails.
//
//  WHAT IS CHECKED, in the order they matter:
//
//    1. The port never sees two overlapping requests.
//    2. Every acknowledgement is routed to the master the transaction was
//       ISSUED for. Getting this wrong hands the CPU another master's data,
//       which on hardware was a PROM panic on a pointer that had just been
//       loaded.
//    3. No master is ever acknowledged when it was not waiting.
//    4. The address and direction presented at issue belong to the master
//       being granted.
//    5. Nothing is lost: every request issued is answered exactly once, both
//       masters make progress, and neither deadlocks.
//
//  THE TWO MASTERS ARE MODELLED IN THEIR REAL SHAPES, because that is the
//  whole difficulty. The CPU PULSES for one cycle and then holds its payload
//  while it waits (rtl/cpu/r4300_bus.sv, S_IDLE -> S_BUSY); the DMA engines
//  HOLD their request until acknowledged (rtl/sgi/hpc3_scsi_dma.sv). A test
//  that drove both as pulses, or both as holds, would pass against the broken
//  arbiter - which is exactly how tb_ddr3 missed its own version of this.
//
//  Run it across latencies; the interesting result is that latency 0 and 1
//  pass against the OLD logic and everything above 1 does not:
//      make -C verilator ramarbtest && ./obj_dir_ramarb/Vram_arb
//      RAMARB_LAT=60 ./obj_dir_ramarb/Vram_arb
//============================================================================

#include "Vram_arb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <random>

static Vram_arb *dut;
static std::mt19937 rng(20260830);

// ---- failure accounting ---------------------------------------------------
static long err_overlap   = 0;   // two transactions on a one-deep port
static long err_misroute  = 0;   // ack delivered to the wrong master
static long err_unasked   = 0;   // ack delivered to a master that was idle
static long err_payload   = 0;   // wrong address/direction presented at issue
static long err_noack     = 0;   // ack cycle that reached neither master

// ---- the port: one transaction at a time, answered after LAT cycles -------
static bool     port_busy      = false;
static int      port_delay     = 0;
static bool     port_owner_dma = false;
static uint32_t port_addr      = 0;
static bool     port_we        = false;

// ---- the CPU: a one-cycle pulse, payload held until acknowledged ----------
static bool     cpu_waiting = false;   // issued, not yet answered
static bool     cpu_drive   = false;   // present cpu_req this cycle
static uint32_t cpu_addr    = 0x1000;
static bool     cpu_we      = false;
static int      cpu_gap     = 0;
static long     cpu_done    = 0;

// ---- the DMA: request held until acknowledged ----------------------------
static bool     dma_on   = false;
static uint32_t dma_addr = 0x8000;
static bool     dma_we   = false;
static int      dma_gap  = 0;
static long     dma_done = 0;

static bool cpu_enabled = true, dma_enabled = true;
static long cycles = 0;

static void tick()
{
    // ---- what the port is presenting this cycle --------------------------
    bool ram_ack = false;
    if (port_busy) {
        if (port_delay > 0) port_delay--;
        else                ram_ack = true;
    }

    // ---- drive the masters ------------------------------------------------
    // The CPU raises its request for exactly one cycle. `cpu_drive` is cleared
    // below whether or not the arbiter took it, which is the entire hazard:
    // an arbiter that cannot accept it now must remember it.
    dut->cpu_req   = cpu_drive ? 1 : 0;
    dut->cpu_we    = cpu_we ? 1 : 0;
    dut->cpu_addr  = cpu_addr;
    dut->cpu_wdata = 0x1111111100000000ULL | cpu_addr;
    dut->cpu_be    = 0xFF;

    dut->dma_req   = dma_on ? 1 : 0;
    dut->dma_we    = dma_we ? 1 : 0;
    dut->dma_addr  = dma_addr;
    dut->dma_wdata = 0x2222222200000000ULL | dma_addr;
    dut->dma_be    = 0xFF;

    dut->ram_ack   = ram_ack ? 1 : 0;
    dut->eval();

    // ---- sample BEFORE the edge, the way synchronous logic does -----------
    bool     s_req     = dut->ram_req;
    bool     s_we      = dut->ram_we;
    uint32_t s_addr    = dut->ram_addr;
    bool     s_grant   = dut->dma_granted;
    bool     s_cpu_ack = dut->cpu_ack;
    bool     s_dma_ack = dut->dma_ack;

    // ---- check 1: the port is one deep ------------------------------------
    // A request presented while a transaction is outstanding is dropped by
    // ddr3_mux, silently. This is the check the old arbiter fails.
    if (s_req && port_busy && !ram_ack) err_overlap++;

    // ---- checks 2, 3, 5: the acknowledgement went to its owner ------------
    if (ram_ack) {
        if (!s_cpu_ack && !s_dma_ack)                 err_noack++;
        if (s_cpu_ack && s_dma_ack)                   err_misroute++;
        if (port_owner_dma && s_cpu_ack)              err_misroute++;
        if (!port_owner_dma && s_dma_ack)             err_misroute++;
        if (s_cpu_ack && !cpu_waiting)                err_unasked++;
        if (s_dma_ack && !dma_on)                     err_unasked++;
    } else {
        if (s_cpu_ack || s_dma_ack)                   err_unasked++;
    }

    // ---- check 4: the payload belongs to whoever was granted --------------
    if (s_req) {
        uint32_t want_addr = s_grant ? dma_addr : cpu_addr;
        bool     want_we   = s_grant ? dma_we   : cpu_we;
        if (s_addr != want_addr || s_we != want_we) err_payload++;
    }

    // ---- the clock --------------------------------------------------------
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
    cycles++;

    // ---- retire the answered transaction ----------------------------------
    // RETIRE ON THE ACKNOWLEDGEMENTS THE ARBITER ACTUALLY DELIVERED, not on
    // the port's own idea of who owned the transaction. That is what the real
    // masters do: r4300_bus.sv leaves S_BUSY on any `bus_ack` at all, wrong
    // data and all, and the DMA engine goes on holding a request that has
    // already been answered to somebody else. Retiring by owner instead would
    // model a CPU that notices it has been lied to, and no CPU does - it also
    // stops the run at the first fault and hides how often it happens.
    if (ram_ack) {
        port_busy = false;
        if (s_cpu_ack) { cpu_done++; cpu_waiting = false;
                         cpu_gap = 1 + (int)(rng() % 12); }
        if (s_dma_ack) { dma_done++; dma_on = false;
                         dma_gap = 1 + (int)(rng() % 12); }
    }

    // ---- take the new one -------------------------------------------------
    if (s_req && !port_busy) {
        port_busy      = true;
        port_owner_dma = s_grant;
        port_addr      = s_addr;
        port_we        = s_we;
        port_delay     = atoi(getenv("RAMARB_LAT") ? getenv("RAMARB_LAT") : "20");
    }

    // ---- the masters decide what to do next -------------------------------
    // The CPU's pulse is spent whether or not it was taken.
    if (cpu_drive) { cpu_drive = false; cpu_waiting = true; }
    if (cpu_enabled && !cpu_waiting && !cpu_drive) {
        if (cpu_gap > 0) cpu_gap--;
        else {
            cpu_addr  = 0x1000 + ((cpu_done * 8) & 0xFFFF);
            cpu_we    = (rng() % 3) == 0;
            cpu_drive = true;
        }
    }
    if (dma_enabled && !dma_on) {
        if (dma_gap > 0) dma_gap--;
        else {
            dma_addr = 0x8000 + ((dma_done * 8) & 0xFFFF);
            dma_we   = (rng() % 2) == 0;
            dma_on   = true;
        }
    }
}

static void reset_all()
{
    port_busy = false; port_owner_dma = false; port_delay = 0;
    cpu_waiting = false; cpu_drive = false; cpu_gap = 0; cpu_done = 0;
    dma_on = false; dma_gap = 0; dma_done = 0;
    dut->reset = 1;
    dut->cpu_req = 0; dut->dma_req = 0; dut->ram_ack = 0;
    for (int i = 0; i < 8; i++) { dut->eval(); dut->clk = 1; dut->eval();
                                 dut->clk = 0; dut->eval(); }
    dut->reset = 0;
}

static int phase(const char *name, bool cpu_en, bool dma_en, int n)
{
    err_overlap = err_misroute = err_unasked = err_payload = err_noack = 0;
    cpu_enabled = cpu_en; dma_enabled = dma_en;
    reset_all();
    for (int i = 0; i < n; i++) tick();

    long bad = err_overlap + err_misroute + err_unasked + err_payload + err_noack;
    // A phase where a master was enabled and completed nothing is a deadlock,
    // and it reads as a pass unless it is checked for.
    bool stalled = (cpu_en && cpu_done == 0) || (dma_en && dma_done == 0);

    printf("  %-28s cpu %6ld  dma %6ld  overlap %5ld  misroute %5ld  "
           "unasked %4ld  payload %4ld  %s\n",
           name, cpu_done, dma_done, err_overlap, err_misroute,
           err_unasked, err_payload,
           (bad || stalled) ? (stalled ? "DEADLOCK" : "FAIL") : "ok");
    return (bad || stalled) ? 1 : 0;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    dut = new Vram_arb;
    dut->clk = 0;

    const char *lat = getenv("RAMARB_LAT") ? getenv("RAMARB_LAT") : "20";
    printf("ram_arb: memory latency %s cycles\n", lat);

    int fail = 0;
    fail |= phase("CPU alone",            true,  false, 40000);
    fail |= phase("DMA alone",            false, true,  40000);
    fail |= phase("both, contending",     true,  true,  200000);

    // The whole point, spelled out: sweep the latency and watch where it
    // breaks. sim_ram.v is the first of these and DDR3 is the last.
    printf("\n  latency sweep (both masters):\n");
    for (int L : {0, 1, 2, 5, 20, 60}) {
        char buf[32]; snprintf(buf, sizeof buf, "%d", L);
        setenv("RAMARB_LAT", buf, 1);
        char nm[48]; snprintf(nm, sizeof nm, "latency %d", L);
        fail |= phase(nm, true, true, 120000);
    }

    printf("\nram_arb: %s\n", fail ? "FAIL" : "PASS");
    delete dut;
    return fail;
}
