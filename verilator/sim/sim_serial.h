#pragma once
//
// sim_serial.h — Reusable soft UART + ImGui serial terminal for Verilator sims
//
// Core-agnostic: caller provides txd pin samples and receives rxd pin output.
// Can be used with any MiSTer core that has a UART/SCC serial port.
//

#include "imgui.h"
#include <cstdint>
#include <cstdio>
#include <queue>
#include <string>
#include <vector>

// Bit-level soft UART transceiver.
// Operates at the wire level, one tick per system clock rising edge.
struct SoftUART {
    // Configure from individual parameters
    void Configure(uint32_t clocks_per_baud, int data_bits = 8,
                   int stop_bits = 1, bool parity_en = false, bool parity_even = false);

    // Configure from wbuart32 31-bit setup register format:
    //   [23:0]  = clocks per baud
    //   [24]    = even parity select
    //   [26]    = parity enable
    //   [27]    = two stop bits
    //   [29:28] = data bits (00=8, 01=7, 10=6, 11=5)
    void ConfigureFromSetup(uint32_t setup_reg);

    // RX: call every clock tick with the FPGA's txd output pin value.
    // Returns true when a complete byte has been received.
    bool RxTick(bool txd_pin);
    uint8_t RxByte() const { return m_rx_byte; }
    bool RxFrameError() const { return m_rx_frame_error; }

    // TX: queue a byte for transmission.
    void TxEnqueue(uint8_t byte);
    // Call every clock tick. Returns current rxd pin value to drive into FPGA (1=idle).
    bool TxTick();
    bool TxBusy() const { return m_tx_state != TxState::IDLE || !m_tx_queue.empty(); }

    uint32_t GetClocksPerBaud() const { return m_clocks_per_baud; }
    int GetDataBits() const { return m_data_bits; }

private:
    uint32_t m_clocks_per_baud = 3385; // default ~9600 baud at 32.5MHz
    int m_data_bits = 8;
    int m_stop_bits = 1;
    bool m_parity_en = false;
    bool m_parity_even = false;

    // RX state machine
    enum class RxState { IDLE, START, DATA, PARITY, STOP };
    RxState m_rx_state = RxState::IDLE;
    uint32_t m_rx_counter = 0;
    int m_rx_bit_index = 0;
    uint8_t m_rx_shift = 0;
    uint8_t m_rx_byte = 0;
    bool m_rx_ready = false;
    bool m_rx_frame_error = false;
    bool m_rx_last_pin = true; // track for edge detection

    // TX state machine
    enum class TxState { IDLE, START, DATA, PARITY, STOP };
    TxState m_tx_state = TxState::IDLE;
    uint32_t m_tx_counter = 0;
    int m_tx_bit_index = 0;
    uint8_t m_tx_shift = 0;
    bool m_tx_pin = true; // idle high
    int m_tx_stop_count = 0;
    std::queue<uint8_t> m_tx_queue;
};

// ImGui serial terminal window with integrated soft UART.
struct SimSerialTerminal {
    SimSerialTerminal();

    // Call once per sim clock tick with the FPGA's txd output pin value.
    // Returns the rxd pin value to drive into the FPGA.
    bool Tick(bool fpga_txd_pin);

    // Update baud config from wbuart32 setup register (call when changed)
    void UpdateConfig(uint32_t uart_setup_reg);
    // Or configure directly (for non-wbuart32 cores)
    void UpdateConfigDirect(uint32_t clocks_per_baud, int data_bits = 8,
                            int stop_bits = 1, bool parity_en = false,
                            bool parity_even = false);

    // Update SCC register state for status display
    void UpdateSCCStatus(uint8_t wr3, uint8_t wr5, uint8_t wr9, uint8_t wr14);

    // Draw the ImGui window
    void Draw(const char* title, bool* p_open);

private:
    void AddReceivedChar(uint8_t c);
    void SendInput();

    SoftUART m_uart;

    // Terminal display buffer
    std::vector<std::string> m_lines;
    std::string m_current_line;
    static const int MAX_LINES = 1000;
    bool m_auto_scroll = true;
    bool m_scroll_to_bottom = false;

    // Input
    char m_input_buf[256] = {};

    // Stats
    uint64_t m_rx_byte_count = 0;
    uint64_t m_tx_byte_count = 0;
    uint32_t m_frame_error_count = 0;

    // Display options
    bool m_hex_mode = false;
    bool m_last_was_cr = false;

    // Line ending for TX
    enum class LineEnding { CR, LF, CRLF };
    LineEnding m_line_ending = LineEnding::CR;

    // SCC register state for status display
    uint8_t m_scc_wr3 = 0;
    uint8_t m_scc_wr5 = 0;
    uint8_t m_scc_wr9 = 0;
    uint8_t m_scc_wr14 = 0;
};
