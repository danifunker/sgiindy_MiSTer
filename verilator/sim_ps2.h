// sim_ps2.h - host-side driver for the core's ps2_key / ps2_mouse inputs.
//
// Those two ports are MiSTer's decoded PS/2 form, and hps_io signals an event
// by toggling the top bit rather than by pulsing a strobe. So the harness has
// to do the same: set the payload, flip the toggle, and leave both alone until
// the next event. i8042.sv compares the toggle against the last value it saw,
// which means an event is only observed if the core is actually being clocked
// when it changes - hence the queue here rather than a direct poke, so events
// injected while the machine is paused are delivered when it runs again.
//
// One event per N cycles, because i8042.sv turns each into up to three queued
// bytes and does it one byte per cycle; firing faster than it drains would
// only exercise the overflow guard.
#pragma once
#include <cstdint>
#include <deque>
#include <string>

struct Ps2Event {
    bool     is_mouse;
    uint16_t key;      // {pressed, extended, code[7:0]} - the low 10 bits
    uint8_t  buttons;  // mouse: bit0 left, bit1 right, bit2 middle
    int      dx, dy;
};

class Ps2Injector {
public:
    // Gap between events, in core clocks. Generous: the PROM polls the status
    // register rather than taking an interrupt, and a real keyboard at 10-16
    // kHz on the wire is far slower than this anyway.
    static constexpr uint64_t GAP = 2000;

    void push_key(uint8_t code, bool extended, bool pressed) {
        q_.push_back({false, (uint16_t)((pressed ? 0x200 : 0) |
                                        (extended ? 0x100 : 0) | code), 0, 0, 0});
    }
    // A press/release pair, which is what a tap on a real key produces.
    void tap(uint8_t code, bool extended = false) {
        push_key(code, extended, true);
        push_key(code, extended, false);
    }
    void push_mouse(uint8_t buttons, int dx, int dy) {
        q_.push_back({true, 0, buttons, dx, dy});
    }

    bool idle() const { return q_.empty(); }

    // Call once per clock, before eval(). Returns true if it changed a port.
    template <typename TOP>
    bool step(TOP *top, uint64_t cycle) {
        if (q_.empty() || cycle < next_) return false;
        Ps2Event e = q_.front(); q_.pop_front();
        next_ = cycle + GAP;
        if (e.is_mouse) {
            // hps_io hands the guest the three raw PS/2 packet bytes, so build
            // exactly those: [7:0] flags, [15:8] dx, [23:16] dy.
            int dx = e.dx < -256 ? -256 : (e.dx > 255 ? 255 : e.dx);
            int dy = e.dy < -256 ? -256 : (e.dy > 255 ? 255 : e.dy);
            uint8_t b0 = (uint8_t)(0x08 | (e.buttons & 0x07));
            if (dx < 0) b0 |= 0x10;      // dx sign
            if (dy < 0) b0 |= 0x20;      // dy sign
            uint32_t v = (uint32_t)b0
                       | ((uint32_t)(dx & 0xFF) << 8)
                       | ((uint32_t)(dy & 0xFF) << 16);
            mouse_tog_ = !mouse_tog_;
            top->ps2_mouse = v | ((uint32_t)mouse_tog_ << 24);
        } else {
            key_tog_ = !key_tog_;
            top->ps2_key = (uint16_t)(e.key | (key_tog_ ? 0x400 : 0));
        }
        return true;
    }

private:
    std::deque<Ps2Event> q_;
    uint64_t next_    = 0;
    bool     key_tog_ = false;
    bool     mouse_tog_ = false;
};

// Set-2 scan codes for the handful of keys a test needs to send. Anything
// beyond this belongs in a table generated from a keymap, not hand-written.
inline bool ps2_code_for_ascii(char c, uint8_t &code, bool &shift) {
    static const struct { char c; uint8_t code; } plain[] = {
        {'a',0x1C},{'b',0x32},{'c',0x21},{'d',0x23},{'e',0x24},{'f',0x2B},
        {'g',0x34},{'h',0x33},{'i',0x43},{'j',0x3B},{'k',0x42},{'l',0x4B},
        {'m',0x3A},{'n',0x31},{'o',0x44},{'p',0x4D},{'q',0x15},{'r',0x2D},
        {'s',0x1B},{'t',0x2C},{'u',0x3C},{'v',0x2A},{'w',0x1D},{'x',0x22},
        {'y',0x35},{'z',0x1A},
        {'0',0x45},{'1',0x16},{'2',0x1E},{'3',0x26},{'4',0x25},{'5',0x2E},
        {'6',0x36},{'7',0x3D},{'8',0x3E},{'9',0x46},
        {' ',0x29},{'\r',0x5A},{'\n',0x5A},{'\b',0x66},{'\t',0x0D},
        {'-',0x4E},{'=',0x55},{'.',0x49},{',',0x41},{'/',0x4A},{';',0x4C},
    };
    shift = false;
    if (c >= 'A' && c <= 'Z') { shift = true; c = (char)(c - 'A' + 'a'); }
    for (auto &e : plain) if (e.c == c) { code = e.code; return true; }
    return false;
}
