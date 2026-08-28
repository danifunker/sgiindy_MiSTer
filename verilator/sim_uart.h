// sim_uart.h - the harness's end of the serial console.
//
// Shared by both harnesses so there is one implementation of the tricky part:
// working out what bit rate the machine is talking at.
//
// NOTHING HERE IS CONFIGURED WITH A BAUD RATE, deliberately. The PROM changes
// it during boot - it comes up at 9600, announces "diagnostic baud rate set to
// 19200" before the System Maintenance Menu, and will go to 38400 if it thinks
// the terminal is out of step. A harness with a fixed rate types garbage the
// moment that happens, and the PROM's own auto-baud then chases it further.
//
// So the rate is measured off the machine's own transmit line. In 8N1 the
// narrowest run of a constant level is exactly one bit, and over a line of
// ordinary text two adjacent bits always differ somewhere - so the narrowest
// run seen in a burst of output is the bit time. It is committed at the end of
// each burst, which is also when the PROM changes rates, so each new line of
// output re-measures before anything is typed back.
#pragma once
#include <cstdint>
#include <deque>
#include <string>

namespace sgisim {

struct UartRx {
    // Committed bit time, in system clocks. Zero until the machine has
    // transmitted something.
    uint64_t bit_time = 0;

    // Per-burst measurement.
    uint64_t min_run     = 0;
    uint64_t edge_at     = 0;
    uint64_t burst_start = 0;   // the falling edge that opened this burst
    uint8_t  prev        = 1;
    bool     in_burst    = false;

    // Frame decode, as an independent check on what actually came out of the
    // pin - see docs/06-simulation.md on why that is worth having next to the
    // byte tap.
    bool     in_frame = false;
    int      bit_idx  = 0;
    uint32_t shift    = 0;
    uint64_t frame_at = 0;
    uint64_t stop_at  = 0;
    bool     stop_due = false;
    unsigned framing_errors = 0;
    std::string out;

    // A run shorter than this is a glitch, not a bit, at any rate this machine
    // uses. txdb is low for exactly ONE clock at reset before the transmitter
    // idles it high, and a burst opened on that never closes - which leaves the
    // measurement armed until the first real start bit and then adopts the
    // width of the entire idle period as the bit time. That is a whole
    // afternoon of "the SCC transmits garbage" waiting to happen.
    static const uint64_t MIN_PULSE = 3;

    void note_run(uint64_t run)
    {
        if (min_run == 0 || run < min_run) min_run = run;

        // A run SHORTER than the current bit time cannot happen at the current
        // rate, so it is proof the machine has sped up - take it immediately
        // rather than waiting for the burst to end. The frame in progress is
        // abandoned: it was being sampled at the wrong rate and is not
        // recoverable, so at most one character is lost at a rate change. The
        // byte tap in sgi_scc.sv is the console of record; this decoder is the
        // independent check on the wire.
        if (bit_time && min_run < bit_time) {
            bit_time = min_run;
            in_frame = false;
            stop_due = false;
        }

        if (bit_time == 0) {
            // Nothing has ever been measured, so adopt this at once rather
            // than waiting for the burst to end - otherwise the first
            // character is undecodable, and a test whose whole output is one
            // burst decodes nothing at all.
            //
            // Keep decoding THIS frame rather than resynchronising:
            // burst_start already marks its start bit and the first data-bit
            // sample is still half a bit away. Waiting for the next start bit
            // instead would find one inside this character's own data and
            // every later frame would be a bit out. That is why
            // tests/scc/scctest.c sends 'U' first - its bits alternate, so the
            // opening low run is exactly one bit and this cannot come out at
            // half speed.
            bit_time = min_run;
            in_frame = true; bit_idx = 0; shift = 0; frame_at = burst_start;
        }
    }

    void sample(uint64_t cycle, uint8_t line)
    {
        if (line != prev) {
            uint64_t run = cycle - edge_at;      // the run that just ended
            if (run >= MIN_PULSE) {
                if (!in_burst) {
                    // Open a burst only on a LOW run long enough to be a start
                    // bit; `edge_at` is that falling edge.
                    if (line == 1) {
                        in_burst    = true;
                        burst_start = edge_at;
                        min_run     = 0;
                        note_run(run);
                    }
                } else {
                    note_run(run);
                }
            }
            edge_at = cycle;
        } else if (in_burst && line == 1 && cycle - edge_at > 20 * min_run) {
            // Twenty bit times of mark: the burst is over, so this is the point
            // to commit the refined measurement. It is also where the PROM
            // changes the console rate, which is the whole reason for measuring
            // per burst rather than once.
            bit_time = min_run;
            in_burst = false;
        }

        if (bit_time == 0) { prev = line; return; }

        // A frame ends with one stop bit at mark. Checking it catches a
        // mis-measured bit time, which otherwise shows up only as plausible
        // wrong characters.
        if (stop_due && cycle >= stop_at) {
            stop_due = false;
            if (line == 0) framing_errors++;
        }

        if (!in_frame) {
            if (prev == 1 && line == 0) {
                in_frame = true; bit_idx = 0; shift = 0; frame_at = cycle;
            }
        } else {
            uint64_t want = frame_at + bit_time + bit_time / 2 + bit_time * bit_idx;
            if (cycle >= want && bit_idx < 8) {
                shift |= (line & 1u) << bit_idx;      // LSB first
                if (++bit_idx == 8) {
                    out.push_back(static_cast<char>(shift & 0xFF));
                    in_frame = false;
                    stop_at  = frame_at + bit_time * 9 + bit_time / 2;
                    stop_due = true;
                }
            }
        }
        prev = line;
    }
};

// A UART transmitter on the SCC's receive pin.
//
// Deliberately a real transmitter rather than a back door into the receive
// FIFO: a keystroke only arrives if the receiver, the baud rate generator and
// the RX FIFO all work. One start bit, eight data bits LSB first, one stop bit,
// at whatever bit time UartRx last committed.
struct UartTx {
    std::deque<uint8_t> queue;
    uint64_t bit_time  = 0;
    uint64_t next_edge = 0;
    int      bit_idx   = -1;      // -1 idle, 0 start, 1..8 data, 9 stop
    uint8_t  cur       = 0;
    uint8_t  line      = 1;

    bool busy() const { return bit_idx >= 0 || !queue.empty(); }

    void step(uint64_t cycle, uint64_t measured)
    {
        // Only pick up a new rate between characters, so a rate change part
        // way through a byte cannot split it across two of them.
        if (bit_idx < 0 && measured) bit_time = measured;

        if (bit_time == 0) { line = 1; return; }
        if (bit_idx < 0) {
            if (queue.empty()) { line = 1; return; }
            cur = queue.front(); queue.pop_front();
            bit_idx = 0; next_edge = cycle + bit_time; line = 0;   // start bit
            return;
        }
        if (cycle < next_edge) return;
        next_edge = cycle + bit_time;
        bit_idx++;
        if (bit_idx <= 8)      line = (cur >> (bit_idx - 1)) & 1;
        else if (bit_idx == 9) line = 1;                            // stop bit
        else                   { bit_idx = -1; line = 1; }
    }
};

} // namespace sgisim
