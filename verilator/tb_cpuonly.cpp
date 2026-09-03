//============================================================================
//  tb_cpuonly.cpp - the CPU alone, against the instruction sequence that
//  panics on hardware, with the memory latency as a swept variable.
//
//  THE FAULT THIS IS AIMED AT. On a DE10-Nano, about one boot in three ends
//  in a PROM panic, always the same one:
//
//      Cause 0x8014 <EXC=WADE>   EPC 0x9fc1dc84   bad address 0x9fc1dc77
//
//  0x9fc1dc84 is `sb $t9, ($t0)` in the WD33C93 command-issue path, and two
//  instructions earlier `lw $t0, 0x148($s1)` loads a CONSTANT out of the PROM
//  - 0xbfbc0003, the chip's address port. ddr3_peek confirms that constant is
//  correct in DDR3, so a load of a known word came back wrong on some boots
//  and not others.
//
//  Two things are checked here and they are different questions:
//
//  1. CAN THE LOAD GO WRONG? The one thing not constant between boots is how
//     long memory takes to answer - DDR3 refresh, the HPS's own traffic and
//     Newport's frame buffer reads all move it. So the sequence is replayed
//     with the memory answering after 0..N idle clocks, each cache both ways.
//
//  2. WHERE CAN THAT EXCEPTION COME FROM AT ALL? `sb` cannot raise an
//     alignment address error - cpu.vhd:1960 leaves its decodeExcType at
//     EXCTYPE_NONE. But EXEExceptionMem (cpu.vhd:2304) has three arms that do
//     NOT test decodeExcType, so any load or store with a non-canonical
//     address raises *something*. What Cause code that something carries
//     decides whether the panic's instruction is the sb at EPC or an earlier
//     one, and that changes where to look next. So the cases below construct
//     the conditions directly and print what the CPU actually reports.
//
//  Build:  make -C verilator cpuonly
//  Run:    ./verilator/obj_dir_cpuonly/Vtb_cpuonly [--max-lat N] [--verbose]
//============================================================================

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include "Vtb_cpuonly.h"
#include "Vtb_cpuonly___024root.h"
#include "verilated.h"

// tb_cpuonly.sv indexes its memory with addr[19:3], so every address folds
// into one 1 MB window. Keep test addresses distinct in their low 20 bits.
static inline uint32_t IDX(uint32_t addr) { return (addr >> 3) & 0x1FFFF; }

static const uint32_t PTR_ADDR = 0x9fc7b410;   // the real PROM address
static const uint32_t PTR_VAL  = 0xbfbc0003;   // the real constant in it

static const uint32_t OUT_BASE  = 0xa0001000;  // KSEG1: unmapped, no TLB
static const uint32_t OUT_VAL   = OUT_BASE + 0x00;
static const uint32_t OUT_DONE  = OUT_BASE + 0x08;
static const uint32_t OUT_CAUSE = OUT_BASE + 0x10;
static const uint32_t OUT_EPC   = OUT_BASE + 0x18;
static const uint32_t OUT_BADV  = OUT_BASE + 0x20;

// Planted at every BEV=1 vector: record Cause, EPC and BadVAddr, then stop.
// Without it an exception runs off into whatever is at the vector and the
// failure reads as a hang instead of as an exception.
static const std::vector<uint32_t> HANDLER = {
    0x3c1aa000,  // lui   $k0, 0xa000
    0x401b6800,  // mfc0  $k1, Cause
    0xaf5b1010,  // sw    $k1, 0x1010($k0)
    0x401b7000,  // mfc0  $k1, EPC
    0xaf5b1018,  // sw    $k1, 0x1018($k0)
    0x401b4000,  // mfc0  $k1, BadVAddr
    0xaf5b1020,  // sw    $k1, 0x1020($k0)
    0x1000ffff,  // b     .
    0x00000000,  // nop
};
static const uint32_t VECTORS[] = { 0xbfc00200, 0xbfc00280, 0xbfc00300, 0xbfc00380 };

// Every case ends with this so "finished" is distinguishable from "hung".
static const std::vector<uint32_t> TAIL = {
    0x24025a5a,  // addiu $v0, $zero, 0x5a5a
    0xaf421008,  // sw    $v0, 0x1008($k0)
    0x1000ffff,  // b     .
    0x00000000,  // nop
};

struct Case {
    const char *name;
    const char *asks;
    std::vector<uint32_t> body;   // $k0 is already 0xa0000000 on entry
    bool  expect_exception;
    uint32_t expect_value;        // checked only when no exception is expected
    bool  check_hi;               // also check the upper 32 bits of OUT_VAL
    uint32_t expect_hi;
};

static const std::vector<Case> CASES = {
    {
        "load-use from PROM",
        "does the lw that fails on hardware ever return the wrong word?",
        {
            0x3c119fc7,  // lui   $s1, 0x9fc7
            0x3631b2c8,  // ori   $s1, $s1, 0xb2c8      -> PTR_ADDR - 0x148
            0x8e280148,  // lw    $t0, 0x148($s1)       <-- the load under test
            0x24190011,  // addiu $t9, $zero, 0x11      (the PROM's next insn)
            0xaf481000,  // sw    $t0, 0x1000($k0)      publish what it gave
        },
        false, PTR_VAL, false, 0
    },
    {
        "sb via sign-extended KSEG0",
        "a byte store to KSEG0 in kernel mode must NOT fault",
        {
            0x3c089fc1,  // lui   $t0, 0x9fc1           -> 0xFFFFFFFF9FC1DC77
            0x3508dc77,  // ori   $t0, $t0, 0xdc77
            0x24190011,  // addiu $t9, $zero, 0x11
            0xa1190000,  // sb    $t9, ($t0)
            0xaf481000,  // sw    $t0, 0x1000($k0)
        },
        false, 0x9fc1dc77, false, 0
    },
    {
        "sb via ZERO-extended KSEG0",
        "the same address with a zero upper word - does sb fault, and as what?",
        {
            0x34089fc1,  // ori   $t0, $zero, 0x9fc1    -> 0x000000009FC1DC77
            0x00084438,  // dsll  $t0, $t0, 16
            0x3508dc77,  // ori   $t0, $t0, 0xdc77
            0x24190011,  // addiu $t9, $zero, 0x11
            0xa1190000,  // sb    $t9, ($t0)            <-- the panic's insn
            0xaf481000,  // sw    $t0, 0x1000($k0)
        },
        true, 0, false, 0
    },
    {
        "sw misaligned",
        "harness sanity: a genuinely misaligned sw must give AdES = 5",
        {
            0x3c089fc1,  // lui   $t0, 0x9fc1
            0x3508dc77,  // ori   $t0, $t0, 0xdc77      -> odd address
            0xad090000,  // sw    $t1, ($t0)
        },
        true, 0, false, 0
    },
    {
        // THE READ PATH HAS BEEN CLEARED THREE WAYS AND THE WRITE PATH NOT AT
        // ALL, which is the wrong way round now that the panic's bad pointer
        // looks like a store that lost a byte: 0x00747474 is 0xa8747474 with
        // its top byte missing, on a boot whose memory had been zeroed. Eight
        // byte stores at the eight offsets of one doubleword, read back as a
        // single `ld`, is the tightest check there is on byte-enable
        // placement - a lane that goes astray shows up as a zero in a known
        // position rather than as a wrong answer somewhere later.
        "byte stores at all 8 offsets, read back as one doubleword",
        "does every byte enable land where it should?",
        {
            0xff402000,  // sd    $zero, 0x2000($k0)   clear the target
            0x24080011,  // addiu $t0, $zero, 0x11
            0xa3482000,  // sb    $t0, 0x2000($k0)
            0x24080022,  // addiu $t0, $zero, 0x22
            0xa3482001,  // sb    $t0, 0x2001($k0)
            0x24080033,  // addiu $t0, $zero, 0x33
            0xa3482002,  // sb    $t0, 0x2002($k0)
            0x24080044,  // addiu $t0, $zero, 0x44
            0xa3482003,  // sb    $t0, 0x2003($k0)
            0x24080055,  // addiu $t0, $zero, 0x55
            0xa3482004,  // sb    $t0, 0x2004($k0)
            0x24080066,  // addiu $t0, $zero, 0x66
            0xa3482005,  // sb    $t0, 0x2005($k0)
            0x24080077,  // addiu $t0, $zero, 0x77
            0xa3482006,  // sb    $t0, 0x2006($k0)
            0x24080088,  // addiu $t0, $zero, 0x88
            0xa3482007,  // sb    $t0, 0x2007($k0)
            0xdf492000,  // ld    $t1, 0x2000($k0)
            0xff491000,  // sd    $t1, 0x1000($k0)     publish all 64 bits
        },
        false, 0x55667788, true, 0x11223344
    },
    {
        // The same question for wider stores: a 32-bit store into each half of
        // a doubleword, which is the access the PROM's pointer writes actually
        // are.
        "word stores into both halves of a doubleword",
        "does a 32-bit store write all four of its bytes?",
        {
            0xff402000,  // sd    $zero, 0x2000($k0)
            0x3c08a874,  // lui   $t0, 0xa874
            0x35087474,  // ori   $t0, $t0, 0x7474     -> the panic's pointer
            0xaf482000,  // sw    $t0, 0x2000($k0)
            0x3c091122,  // lui   $t1, 0x1122
            0x35293344,  // ori   $t1, $t1, 0x3344
            0xaf492004,  // sw    $t1, 0x2004($k0)
            0xdf492000,  // ld    $t1, 0x2000($k0)
            0xff491000,  // sd    $t1, 0x1000($k0)
        },
        false, 0x11223344, true, 0xa8747474
    },
    {
        "load-use from PROM, ALL 64 BITS",
        "the constant has bit 31 set - is it sign-extended into the register?",
        {
            0x3c119fc7,  // lui   $s1, 0x9fc7
            0x3631b2c8,  // ori   $s1, $s1, 0xb2c8
            0x8e280148,  // lw    $t0, 0x148($s1)   -> must be FFFFFFFF_BFBC0003
            0x24190011,  // addiu $t9, $zero, 0x11
            0xff481000,  // sd    $t0, 0x1000($k0)  publish the whole register
        },
        false, PTR_VAL, true, 0xFFFFFFFFu
    },
};

class Harness {
public:
    Vtb_cpuonly *top;
    Harness() : top(new Vtb_cpuonly) {}
    ~Harness() { delete top; }

    void poke32(uint32_t addr, uint32_t v) {
        uint64_t &w = top->rootp->tb_cpuonly__DOT__mem[IDX(addr)];
        // The byte at addr+i lives in [63-8i -: 8], so a doubleword's first
        // word is its HIGH half.
        if (addr & 4) w = (w & 0xFFFFFFFF00000000ull) | v;
        else          w = (w & 0x00000000FFFFFFFFull) | ((uint64_t)v << 32);
    }
    uint32_t peek32(uint32_t addr) {
        uint64_t w = top->rootp->tb_cpuonly__DOT__mem[IDX(addr)];
        return (addr & 4) ? (uint32_t)w : (uint32_t)(w >> 32);
    }
    void clear() {
        for (int i = 0; i < (1 << 17); i++) top->rootp->tb_cpuonly__DOT__mem[i] = 0;
    }
    void tick() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }
};

struct Result {
    bool done, exception;
    uint32_t value, hi, cause, epc, badv;
    uint32_t reqs, acks;     // bus requests taken, words acknowledged
    bool same(const Result &o) const {
        return done == o.done && value == o.value && hi == o.hi
            && cause == o.cause && epc == o.epc && badv == o.badv;
    }
};

static Result run_one(Harness &h, const Case &c, int lat, bool ic, bool dc, bool burst,
                      long budget)
{
    h.clear();
    uint32_t pc = 0xbfc00000;
    h.poke32(pc, 0x3c1aa000); pc += 4;                       // lui $k0, 0xa000
    for (uint32_t w : c.body) { h.poke32(pc, w); pc += 4; }
    for (uint32_t w : TAIL)   { h.poke32(pc, w); pc += 4; }
    for (uint32_t v : VECTORS)
        for (size_t i = 0; i < HANDLER.size(); i++)
            h.poke32(v + 4 * (uint32_t)i, HANDLER[i]);
    h.poke32(PTR_ADDR,     PTR_VAL);
    h.poke32(PTR_ADDR + 4, 0xbfbc0007);

    h.top->reset = 1;
    h.top->boot_pc = 0xbfc00000;
    h.top->icache_en = ic;
    h.top->dcache_en = dc;
    h.top->irq_lines = 0;
    h.top->lat = (uint8_t)lat;
    h.top->burst_en = burst;
    for (int i = 0; i < 32; i++) h.tick();
    h.top->reset = 0;

    for (long i = 0; i < budget; i++) {
        h.tick();
        if (h.peek32(OUT_CAUSE) != 0) {
            // The handler publishes Cause first and EPC and BadVAddr after,
            // so stopping on Cause alone reads those two as zero and makes an
            // exception look like it had no address. Let the handler finish.
            for (int j = 0; j < 200; j++) h.tick();
            break;
        }
        // STOP DEAD ON A CLEAN FINISH. The tail is `b .`, and letting that
        // spin for even a few hundred more clocks lets the CP0 count/compare
        // interrupt fire and land in the handler, which then reports an
        // exception for a case that had already passed. That is the harness
        // inventing a failure, and it cost a wrong reading of case 2 once.
        if (h.peek32(OUT_DONE) == 0x5a5a) break;
    }
    Result r{};
    r.done      = (h.peek32(OUT_DONE) == 0x5a5a);
    // A doubleword's first word is its high half in this core's byte order, so
    // a 32-bit `sw` lands there and a 64-bit `sd` fills both.
    r.value     = c.check_hi ? h.peek32(OUT_VAL + 4) : h.peek32(OUT_VAL);
    r.hi        = h.peek32(OUT_VAL);
    r.cause     = h.peek32(OUT_CAUSE);
    r.epc       = h.peek32(OUT_EPC);
    r.badv      = h.peek32(OUT_BADV);
    r.exception = (r.cause != 0);
    r.reqs      = h.top->n_req_o;
    r.acks      = h.top->n_ack_o;
    return r;
}

static const char *exc_name(unsigned code)
{
    switch (code) {
        case 0:  return "Int";
        case 1:  return "TLBMod";
        case 2:  return "TLBL";
        case 3:  return "TLBS";
        case 4:  return "AdEL";
        case 5:  return "AdES  <- WADE, the panic's code";
        case 6:  return "IBE";
        case 7:  return "DBE";
        case 10: return "RI";
        default: return "?";
    }
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    int  maxlat = 12;
    bool verbose = false;
    long budget = 400000;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--max-lat") && i + 1 < argc) maxlat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--verbose")) verbose = true;
        else if (!strcmp(argv[i], "--budget") && i + 1 < argc) budget = atol(argv[++i]);
    }

    Harness h;
    int fails = 0, runs = 0;
    // A LINE FILL IS ONE BURST NOW (docs/39), and the memory here can answer
    // it either way: streaming, as main memory does on the board, or one word
    // per request, as the PROM does. Every case runs both ways at every
    // latency and the two must agree in every register - and at least one
    // burst has to have been streamed, or the check is checking nothing.
    long burst_runs = 0, burst_seen = 0;

    for (const Case &c : CASES) {
        printf("\n== %s\n   %s\n", c.name, c.asks);
        // Collapse the sweep: report the distinct outcomes, not 52 identical
        // lines. A latency-sensitive bug shows up as more than one outcome.
        struct Seen { uint32_t value, hi, cause, epc, badv; bool done; int count;
                      int first_lat; const char *mode; };
        std::vector<Seen> seen;
        for (int mode = 0; mode < 4; mode++) {
            bool ic = mode & 1, dc = mode & 2;
            static const char *names[4] = { "i=off d=off", "i=on  d=off",
                                            "i=off d=on ", "i=on  d=on " };
            for (int lat = 0; lat <= maxlat; lat++) {
                Result r  = run_one(h, c, lat, ic, dc, false, budget);
                Result rb = run_one(h, c, lat, ic, dc, true,  budget);
                runs += 2;
                bool ok = c.expect_exception
                        ? r.exception
                        : (r.done && !r.exception && r.value == c.expect_value
                           && (!c.check_hi || r.hi == c.expect_hi));
                if (!ok) fails++;
                if (!rb.same(r)) {
                    fails++;
                    printf("     %s lat=%-3d BURST DISAGREES: value=0x%08x/0x%08x "
                           "cause=0x%08x/0x%08x done=%d/%d\n",
                           names[mode], lat, r.value, rb.value, r.cause, rb.cause,
                           r.done, rb.done);
                }
                if (dc) {
                    burst_runs++;
                    if (rb.acks > rb.reqs) burst_seen++;
                }
                bool merged = false;
                for (Seen &s : seen)
                    if (s.value == r.value && s.hi == r.hi && s.cause == r.cause && s.epc == r.epc
                        && s.badv == r.badv && s.done == r.done
                        && !strcmp(s.mode, names[mode])) { s.count++; merged = true; break; }
                if (!merged)
                    seen.push_back({ r.value, r.hi, r.cause, r.epc, r.badv, r.done, 1, lat, names[mode] });
                if (verbose)
                    printf("     %s lat=%-3d value=0x%08x cause=0x%08x epc=0x%08x badv=0x%08x %s\n",
                           names[mode], lat, r.value, r.cause, r.epc, r.badv, ok ? "" : "MISMATCH");
            }
        }
        for (const Seen &s : seen) {
            if (s.cause)
                printf("   %s  x%-3d  EXCEPTION exc=%u %-28s epc=0x%08x badvaddr=0x%08x\n",
                       s.mode, s.count, (s.cause >> 2) & 0x1f,
                       exc_name((s.cause >> 2) & 0x1f), s.epc, s.badv);
            else if (c.check_hi)
                printf("   %s  x%-3d  no exception, register = 0x%08x_%08x%s%s\n",
                       s.mode, s.count, s.hi, s.value,
                       s.hi == c.expect_hi ? "  sign-extended"
                                           : "  <-- NOT SIGN-EXTENDED",
                       s.done ? "" : "  (NEVER FINISHED)");
            else
                printf("   %s  x%-3d  no exception, value=0x%08x%s\n",
                       s.mode, s.count, s.value, s.done ? "" : "  (NEVER FINISHED)");
        }
    }

    printf("\nline fills streamed as bursts in %ld of %ld data-cache runs\n",
           burst_seen, burst_runs);
    if (burst_runs && !burst_seen) {
        printf("   FAILED: no burst was ever streamed - r4300_bus is not asking for lines\n");
        fails++;
    }
    printf("\n%d runs, %d against expectation\n", runs, fails);
    return fails ? 1 : 0;
}
