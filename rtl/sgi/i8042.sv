//============================================================================
//  i8042 - the PC-style keyboard/mouse controller in IOC2.
//
//  The Indy carries a PC keyboard controller, reachable through IOC2 at
//  +0x40 (data) and +0x44 (command on a write, STATUS on a read). That
//  write/read split is the whole reason the previous stub had to read zero:
//  the PROM writes the self-test command 0xAA to +0x44 and then polls the
//  same address, so a register that reads back what was written answers
//  0xAA, whose bit 1 says "input buffer full", and the PROM waits forever
//  for a controller that never drains. See docs/12-chipset.md finding 10.
//
//  This models the controller and both devices behind it, rather than the
//  PS/2 serial lines: MiSTer's hps_io already decodes the wire protocol into
//  `ps2_key` and `ps2_mouse`, so the line-level half would be two state
//  machines translating a protocol back into itself. Command handling and
//  the byte queue follow IRIS's src/ps2.rs, which drives both this PROM and
//  IRIX.
//
//  KEYBOARD SCAN CODES ARE SET 2, which is what `ps2_key` delivers and what
//  a PS/2 keyboard sends unasked. Set 1 translation (controller config bit
//  6) is accepted as a config write and then ignored - nothing in the PROM
//  or in IRIX's kernel driver asks for it, and translating would mean
//  carrying a 132-entry table for a case that does not arise. If something
//  ever does set it, the codes will be wrong rather than absent, which is a
//  visible failure rather than a silent one.
//
//  INTERRUPTS are generated but not yet routed: sgi_indy.sv leaves INT2's
//  sources tied off until the CPU takes interrupts at all. Until then the
//  PROM and the harness poll the status register, which is what the PROM's
//  own console path does anyway.
//============================================================================

module i8042 (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,

    // ---- register interface, from sgi_ioc -------------------------------
    input  logic        sel,        // one-cycle access pulse
    input  logic        we,
    input  logic        is_cmd,     // 0 = +0x40 data port, 1 = +0x44 cmd/status
    input  logic  [7:0] din,
    output logic  [7:0] dout,       // data byte or status, per is_cmd

    // ---- host events -----------------------------------------------------
    // MiSTer's decoded forms. Both are edge-encoded on their top bit: the
    // sender toggles it once per event, so a level compare against the last
    // seen value is the event strobe and no handshake is needed.
    input  logic [10:0] ps2_key,    // {toggle, pressed, extended, code[7:0]}
    input  logic [24:0] ps2_mouse,  // {toggle, dy[8:0], dx[8:0], 1'b0, btn_m, btn_r, btn_l}

    output logic        irq_kbd,
    output logic        irq_mouse
);

    // ---- output queue ----------------------------------------------------
    // Depth 32. A key press is at most three bytes and a mouse packet three,
    // so this holds ten events unread; the PROM never lets more than one or
    // two accumulate, and IRIX drains on interrupt.
    localparam int QDEPTH = 32;

    logic [8:0] queue [QDEPTH];     // {is_aux, data}
    logic [4:0] q_head, q_tail;
    logic [5:0] q_count;

    wire        q_empty = (q_count == 0);
    wire        q_full  = (q_count >= QDEPTH - 4);   // headroom for one packet
    wire [8:0]  q_front = queue[q_head];

    // Pushes are requested from several places in one cycle at most; a small
    // two-slot staging register would be needed for more, and nothing here
    // needs more.
    logic       push_en;
    logic [8:0] push_val;
    logic       pop_en;

    // Some device commands answer with more than one byte - a reset is ACK,
    // then the power-on self-test result, then (for the mouse) the device ID.
    // The port above takes one byte per cycle, so the first goes out with the
    // command and the rest are staged here and drained on idle cycles.
    logic [1:0] pend_cnt;
    logic [8:0] pend_b0, pend_b1;

    // ---- controller state ------------------------------------------------
    // config: the 8042 command byte. Bit 4 disables the keyboard port, bit 5
    // the mouse port, bits 0/1 enable the two interrupts. 0x47 is what a PC
    // BIOS leaves behind and what IRIS starts from: both interrupts on,
    // translation on, system flag set.
    logic [7:0] config_byte;
    logic       next_write_is_mouse;
    logic       kbd_scanning;
    logic       mouse_enabled;
    logic [7:0] mouse_id;
    logic [7:0] mouse_resolution;
    logic [7:0] mouse_sample_rate;

    // What the next data-port write means, when it is not a plain command.
    typedef enum logic [3:0] {
        ARG_NONE,
        ARG_WRITE_CONFIG,
        ARG_KBD_LEDS,
        ARG_KBD_SCANSET,
        ARG_KBD_TYPEMATIC,
        ARG_MOUSE_RESOLUTION,
        ARG_MOUSE_SAMPLE,
        ARG_AUX_LOOP
    } arg_state_e;

    arg_state_e arg_state;

    // ---- status ----------------------------------------------------------
    // bit 0 OBF   - a byte is waiting
    // bit 1 IBF   - the controller has not consumed the last write. Always
    //               clear: every command completes in the cycle it arrives,
    //               so there is never a write in flight. This is the bit the
    //               old stub's loopback set by accident.
    // bit 2 SYS   - set once the controller has passed its self-test. Held
    //               set, as a machine that has been reset and tested is what
    //               the PROM finds.
    // bit 5 AUX   - the waiting byte came from the mouse port
    wire [7:0] status = {2'b00, q_front[8] && !q_empty, 2'b00, 1'b1, 1'b0, !q_empty};

    // Registered one cycle, to line up with sgi_indy's registered ack.
    //
    // This has to be sampled during the access cycle, not read combinationally
    // a cycle later: the pop below happens on the same edge that ends the
    // access, so by the time `ack` is high `q_front` has already advanced to
    // the next byte - or to an empty queue. Reading it then returns the byte
    // *after* the one asked for, which for a single queued ACK means 0x00 and
    // makes a controller that is answering correctly look mute. That is
    // exactly how the keyboard self-test failed: the PROM wrote 0xED, saw OBF
    // set, read the data port and got 0x00 instead of 0xFA.
    logic [7:0] dout_r;
    assign dout = dout_r;

    // A read of the data port consumes the byte. Reading the status port does
    // not, which is what lets the PROM poll OBF and then fetch.
    assign pop_en = sel && !we && !is_cmd && !q_empty;

    // ---- host event edges ------------------------------------------------
    logic        key_tog_q;
    logic        mouse_tog_q;
    wire         key_event   = (ps2_key[10]   != key_tog_q);
    wire         mouse_event = (ps2_mouse[24] != mouse_tog_q);

    // A key event is up to three bytes (E0 F0 code) and a mouse packet three,
    // so both are emitted by a small sequencer rather than in one cycle.
    logic [1:0]  key_phase;
    logic [1:0]  mouse_phase;
    logic        key_busy, mouse_busy;
    logic        key_pressed_l;
    logic  [7:0] key_code_l;
    logic  [7:0] m_b0, m_b1, m_b2;

    assign irq_kbd   = !q_empty && !q_front[8] && config_byte[0];
    assign irq_mouse = !q_empty &&  q_front[8] && config_byte[1];

    // ps2_mouse is not a decoded form - hps_io passes the three bytes of the
    // real PS/2 packet straight through (hps_io.sv:368-370), so byte 0 with
    // its buttons, sign and overflow bits is [7:0], dx is [15:8] and dy is
    // [23:16]. Nothing to assemble: the mouse already said exactly this on
    // the wire and the guest wants it back unchanged.

    integer i;

    always_ff @(posedge clk) begin
        push_en  <= 1'b0;
        push_val <= 9'h000;

        if (reset) begin
            q_head              <= 0;
            q_tail              <= 0;
            q_count             <= 0;
            config_byte         <= 8'h47;
            next_write_is_mouse <= 1'b0;
            kbd_scanning        <= 1'b1;
            mouse_enabled       <= 1'b0;
            mouse_id            <= 8'h00;
            mouse_resolution    <= 8'h02;
            mouse_sample_rate   <= 8'd100;
            arg_state           <= ARG_NONE;
            key_tog_q           <= 1'b0;
            mouse_tog_q         <= 1'b0;
            key_phase           <= 2'd0;
            mouse_phase         <= 2'd0;
            key_busy            <= 1'b0;
            mouse_busy          <= 1'b0;
            pend_cnt            <= 2'd0;
            dout_r              <= 8'h00;
        end else if (ce) begin
            if (sel)
                dout_r <= is_cmd ? status : (q_empty ? 8'h00 : q_front[7:0]);

            // ---- queue maintenance ---------------------------------------
            if (push_en && !pop_en) begin
                queue[q_tail] <= push_val;
                q_tail        <= q_tail + 1'b1;
                q_count       <= q_count + 1'b1;
            end else if (!push_en && pop_en) begin
                q_head  <= q_head + 1'b1;
                q_count <= q_count - 1'b1;
            end else if (push_en && pop_en) begin
                queue[q_tail] <= push_val;
                q_tail        <= q_tail + 1'b1;
                q_head        <= q_head + 1'b1;
            end

            // ---- register access -----------------------------------------
            if (sel && we) begin
                if (is_cmd) begin
                    // Controller command port.
                    next_write_is_mouse <= 1'b0;
                    arg_state           <= ARG_NONE;
                    case (din)
                        // Self-test. 0x55 is "controller passed"; the 0xAA
                        // that follows is the keyboard's own BAT result,
                        // which a real machine sees because the reset also
                        // resets the keyboard.
                        8'hAA: begin
                            push_en  <= 1'b1; push_val <= {1'b0, 8'h55};
                            pend_cnt <= 2'd1; pend_b0 <= {1'b0, 8'hAA};
                        end
                        // Keyboard interface test: 0x00 = no error.
                        8'hAB: begin push_en <= 1'b1; push_val <= {1'b0, 8'h00}; end
                        // Mouse interface test: same.
                        8'hA9: begin push_en <= 1'b1; push_val <= {1'b0, 8'h00}; end
                        8'h20: begin push_en <= 1'b1; push_val <= {1'b0, config_byte}; end
                        8'h60: arg_state           <= ARG_WRITE_CONFIG;
                        8'hD4: next_write_is_mouse <= 1'b1;
                        8'hD3: arg_state           <= ARG_AUX_LOOP;
                        8'hA7: config_byte         <= config_byte |  8'h20;
                        8'hA8: config_byte         <= config_byte & ~8'h20;
                        8'hAD: config_byte         <= config_byte |  8'h10;
                        8'hAE: config_byte         <= config_byte & ~8'h10;
                        default: ;   // unsupported commands are dropped
                    endcase
                end else begin
                    // Data port. Either an argument to the last command, or a
                    // command for one of the two devices.
                    if (arg_state != ARG_NONE) begin
                        arg_state <= ARG_NONE;
                        case (arg_state)
                            ARG_WRITE_CONFIG:     config_byte <= din;
                            ARG_AUX_LOOP:  begin push_en <= 1'b1; push_val <= {1'b1, din}; end
                            ARG_MOUSE_RESOLUTION: begin
                                mouse_resolution <= din;
                                push_en <= 1'b1; push_val <= {1'b1, 8'hFA};
                            end
                            ARG_MOUSE_SAMPLE: begin
                                mouse_sample_rate <= din;
                                push_en <= 1'b1; push_val <= {1'b1, 8'hFA};
                            end
                            // The keyboard acknowledges every argument too.
                            default: begin push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                        endcase
                    end else if (next_write_is_mouse) begin
                        next_write_is_mouse <= 1'b0;
                        case (din)
                            8'hFF: begin  // reset: ACK, then BAT, then the ID
                                mouse_enabled <= 1'b0;
                                mouse_id      <= 8'h00;
                                push_en  <= 1'b1; push_val <= {1'b1, 8'hFA};
                                pend_cnt <= 2'd2;
                                pend_b0  <= {1'b1, 8'hAA};
                                pend_b1  <= {1'b1, 8'h00};
                            end
                            8'hF2: begin  // identify: ACK, then the device ID
                                push_en  <= 1'b1; push_val <= {1'b1, 8'hFA};
                                pend_cnt <= 2'd1; pend_b0 <= {1'b1, mouse_id};
                            end
                            8'hF3: begin arg_state <= ARG_MOUSE_SAMPLE;
                                         push_en <= 1'b1; push_val <= {1'b1, 8'hFA}; end
                            8'hE8: begin arg_state <= ARG_MOUSE_RESOLUTION;
                                         push_en <= 1'b1; push_val <= {1'b1, 8'hFA}; end
                            8'hF4: begin mouse_enabled <= 1'b1;
                                         push_en <= 1'b1; push_val <= {1'b1, 8'hFA}; end
                            8'hF5: begin mouse_enabled <= 1'b0;
                                         push_en <= 1'b1; push_val <= {1'b1, 8'hFA}; end
                            default: begin push_en <= 1'b1; push_val <= {1'b1, 8'hFA}; end
                        endcase
                    end else begin
                        case (din)
                            8'hFF: begin  // reset: ACK, then the BAT result
                                kbd_scanning <= 1'b1;
                                push_en  <= 1'b1; push_val <= {1'b0, 8'hFA};
                                pend_cnt <= 2'd1; pend_b0 <= {1'b0, 8'hAA};
                            end
                            8'hF2: begin  // identify: ACK, then 0xAB 0x83
                                push_en  <= 1'b1; push_val <= {1'b0, 8'hFA};
                                pend_cnt <= 2'd2;
                                pend_b0  <= {1'b0, 8'hAB};
                                pend_b1  <= {1'b0, 8'h83};
                            end
                            8'hED: begin arg_state <= ARG_KBD_LEDS;
                                         push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                            8'hF0: begin arg_state <= ARG_KBD_SCANSET;
                                         push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                            8'hF3: begin arg_state <= ARG_KBD_TYPEMATIC;
                                         push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                            8'hF4: begin kbd_scanning <= 1'b1;
                                         push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                            8'hF5: begin kbd_scanning <= 1'b0;
                                         push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                            default: begin push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                        endcase
                    end
                end
            end

            // ---- staged multi-byte responses -----------------------------
            else if (pend_cnt != 2'd0) begin
                push_en  <= 1'b1;
                push_val <= pend_b0;
                pend_b0  <= pend_b1;
                pend_cnt <= pend_cnt - 1'b1;
            end

            // ---- keyboard event sequencer --------------------------------
            // Runs only when the bus is idle, so a push from a command and a
            // push from a keystroke can never collide on the single port.
            else if (key_busy) begin
                case (key_phase)
                    2'd0: begin
                        push_en  <= 1'b1;
                        push_val <= {1'b0, 8'hE0};
                        key_phase <= 2'd1;
                    end
                    2'd1: begin
                        if (!key_pressed_l) begin
                            push_en   <= 1'b1;
                            push_val  <= {1'b0, 8'hF0};
                            key_phase <= 2'd2;
                        end else begin
                            push_en   <= 1'b1;
                            push_val  <= {1'b0, key_code_l};
                            key_busy  <= 1'b0;
                        end
                    end
                    default: begin
                        push_en  <= 1'b1;
                        push_val <= {1'b0, key_code_l};
                        key_busy <= 1'b0;
                    end
                endcase
            end
            else if (mouse_busy) begin
                case (mouse_phase)
                    2'd0: begin push_en <= 1'b1; push_val <= {1'b1, m_b0}; mouse_phase <= 2'd1; end
                    2'd1: begin push_en <= 1'b1; push_val <= {1'b1, m_b1}; mouse_phase <= 2'd2; end
                    default: begin push_en <= 1'b1; push_val <= {1'b1, m_b2}; mouse_busy <= 1'b0; end
                endcase
            end
            // ---- new host events -----------------------------------------
            else if (key_event) begin
                key_tog_q <= ps2_key[10];
                // Dropped rather than queued when the port is disabled, the
                // keyboard is not scanning, or the queue is nearly full. A
                // lost keystroke is better than a queue that overruns into
                // the middle of a mouse packet.
                if (kbd_scanning && !config_byte[4] && !q_full) begin
                    key_pressed_l  <= ps2_key[9];
                    key_code_l     <= ps2_key[7:0];
                    key_busy       <= 1'b1;
                    // Skip the 0xE0 phase for an ordinary key.
                    key_phase      <= ps2_key[8] ? 2'd0 : 2'd1;
                end
            end
            else if (mouse_event) begin
                mouse_tog_q <= ps2_mouse[24];
                if (mouse_enabled && !config_byte[5] && !q_full) begin
                    m_b0 <= ps2_mouse[7:0];
                    m_b1 <= ps2_mouse[15:8];
                    m_b2 <= ps2_mouse[23:16];
                    mouse_busy  <= 1'b1;
                    mouse_phase <= 2'd0;
                end
            end
        end
    end

endmodule
