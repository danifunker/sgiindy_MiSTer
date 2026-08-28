//============================================================================
//  uart_test - the harness's serial decoder, against waveforms it got wrong.
//
//  verilator/sim_uart.h is host code, not RTL, so it can be tested without a
//  simulator - and it needs to be, because both of the bugs below reached the
//  point of "the SCC transmits garbage" before anything caught them.
//
//  Build and run:  tests/uart/run.sh
//============================================================================
#include "sim_uart.h"
#include <cstdio>
#include <string>

using namespace sgisim;

namespace {

int failures = 0;

void check(const char *what, const std::string &got, const std::string &want)
{
    if (got == want) { printf("  ok      %s\n", what); return; }
    printf("  FAILED  %s\n            got  \"", what);
    for (char c : got)  printf(c == '\n' ? "\\n" : "%c", c);
    printf("\"\n            want \"");
    for (char c : want) printf(c == '\n' ? "\\n" : "%c", c);
    printf("\"\n");
    failures++;
}

// Drive a UartRx with an 8N1 waveform. `pre_glitch` reproduces what the real
// core does: txdb sits low for one clock at reset before the transmitter idles
// it high.
struct Wave {
    UartRx   rx;
    uint64_t cycle = 0;

    void level(uint8_t v, uint64_t n) { for (uint64_t i = 0; i < n; i++) rx.sample(cycle++, v); }

    void byte(uint8_t b, uint64_t bt)
    {
        level(0, bt);                                   // start
        for (int i = 0; i < 8; i++) level((b >> i) & 1, bt);   // LSB first
        level(1, bt);                                   // stop
    }

    void text(const char *s, uint64_t bt) { for (const char *p = s; *p; p++) byte((uint8_t)*p, bt); }
};

} // namespace

int main()
{
    printf("sim_uart.h\n");

    // 1. The plain case.
    {
        Wave w;
        w.level(1, 5000);
        w.text("USCC-TX-OK\n", 512);
        w.level(1, 40000);
        check("decodes a clean 8N1 burst", w.rx.out, "USCC-TX-OK\n");
        if (w.rx.bit_time != 512) { printf("  FAILED  bit time %llu, want 512\n",
                                           (unsigned long long)w.rx.bit_time); failures++; }
        else                        printf("  ok      measures the bit time\n");
    }

    // 2. The reset glitch. txdb is low for exactly one clock at cycle 0 before
    //    the transmitter idles it high. A decoder that opens a measurement on
    //    that falling edge never closes it, and then adopts the width of the
    //    whole idle period as one bit - which is what made the first real
    //    character decode as a single 0xFF.
    {
        Wave w;
        w.level(0, 1);
        w.level(1, 248000);
        w.text("USCC-TX-OK\n", 512);
        w.level(1, 40000);
        check("survives the one-clock low at reset", w.rx.out, "USCC-TX-OK\n");
    }

    // 3. A rate change between bursts. The PROM does this during boot - it
    //    announces "diagnostic baud rate set to 19200" before the System
    //    Maintenance Menu - and a decoder that measures once gets everything
    //    after it wrong, while a harness that TYPES at the stale rate sends
    //    garbage the PROM's own auto-baud then chases further.
    //
    //    What is asserted here is what is actually true: the burst before the
    //    change decodes, the rate is picked up during the burst that follows
    //    it, and every burst after that decodes. The character the change
    //    lands in is lost, which is fine - the byte tap is the console of
    //    record and this is the independent check on the wire.
    {
        Wave w;
        w.level(1, 5000);
        w.text("slow\n", 512);
        w.level(1, 40000);
        w.text("fast\n", 256);
        w.level(1, 40000);
        w.text("again\n", 256);
        w.level(1, 40000);
        const std::string &o = w.rx.out;
        bool ok = o.rfind("slow\n", 0) == 0 &&
                  o.size() >= 6 && o.compare(o.size() - 6, 6, "again\n") == 0;
        if (ok) printf("  ok      keeps decoding across a baud change\n");
        else    { check("keeps decoding across a baud change", o, "slow\n...again\n"); }
        if (w.rx.bit_time != 256) { printf("  FAILED  bit time %llu, want 256\n",
                                           (unsigned long long)w.rx.bit_time); failures++; }
        else                        printf("  ok      commits the new rate\n");
    }

    // 4. The transmitter, checked by looping it back into the receiver. This
    //    is the path a keystroke takes to the machine.
    //
    //    The receiver is told the bit time rather than measuring it: 'h' has
    //    its low bits clear, so the opening low run is four bits wide and
    //    auto-baud would come out four times slow. That is not a bug in either
    //    end - it is why tests/scc/scctest.c sends 'U' first - but it is not
    //    what this case is testing.
    {
        UartTx tx;
        UartRx rx;
        rx.bit_time = 512;
        for (unsigned char c : std::string("hinv\r")) tx.queue.push_back(c);
        for (uint64_t cycle = 0; cycle < 200000; cycle++) {
            tx.step(cycle, 512);
            rx.sample(cycle, tx.line);
        }
        check("transmits what it was given", rx.out, "hinv\r");
    }

    printf(failures ? "\nUART: FAIL\n" : "\nUART: PASS\n");
    return failures != 0;
}
