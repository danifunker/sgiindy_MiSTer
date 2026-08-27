//
// sim_serial.cpp — Reusable soft UART + ImGui serial terminal for Verilator sims
//

#include "sim_serial.h"
#include <cstring>
#include <algorithm>

// ============================================================================
// SoftUART
// ============================================================================

void SoftUART::Configure(uint32_t clocks_per_baud, int data_bits,
                         int stop_bits, bool parity_en, bool parity_even) {
    m_clocks_per_baud = clocks_per_baud > 0 ? clocks_per_baud : 1;
    m_data_bits = data_bits;
    m_stop_bits = stop_bits;
    m_parity_en = parity_en;
    m_parity_even = parity_even;
}

void SoftUART::ConfigureFromSetup(uint32_t setup_reg) {
    uint32_t cpb = setup_reg & 0xFFFFFF;
    bool even   = (setup_reg >> 24) & 1;
    bool par_en = (setup_reg >> 26) & 1;
    bool two_st = (setup_reg >> 27) & 1;
    int dbits_code = (setup_reg >> 28) & 3;
    int dbits = 8 - dbits_code; // 00=8, 01=7, 10=6, 11=5
    Configure(cpb, dbits, two_st ? 2 : 1, par_en, even);
}

// RX: watch the FPGA's txd output, reconstruct bytes
bool SoftUART::RxTick(bool txd_pin) {
    m_rx_ready = false;

    switch (m_rx_state) {
    case RxState::IDLE:
        // Detect falling edge (start bit)
        if (m_rx_last_pin && !txd_pin) {
            m_rx_state = RxState::START;
            m_rx_counter = m_clocks_per_baud / 2; // sample at mid-bit
            m_rx_shift = 0;
            m_rx_bit_index = 0;
            m_rx_frame_error = false;
        }
        break;

    case RxState::START:
        if (m_rx_counter > 0) {
            m_rx_counter--;
        } else {
            // At mid-start-bit: verify it's still low
            if (txd_pin) {
                // False start, return to idle
                m_rx_state = RxState::IDLE;
            } else {
                m_rx_state = RxState::DATA;
                m_rx_counter = m_clocks_per_baud;
            }
        }
        break;

    case RxState::DATA:
        if (m_rx_counter > 0) {
            m_rx_counter--;
        } else {
            // Sample data bit (LSB first)
            if (txd_pin)
                m_rx_shift |= (1 << m_rx_bit_index);
            m_rx_bit_index++;
            if (m_rx_bit_index >= m_data_bits) {
                m_rx_state = m_parity_en ? RxState::PARITY : RxState::STOP;
            }
            m_rx_counter = m_clocks_per_baud;
        }
        break;

    case RxState::PARITY:
        if (m_rx_counter > 0) {
            m_rx_counter--;
        } else {
            // We don't validate parity, just skip it
            m_rx_state = RxState::STOP;
            m_rx_counter = m_clocks_per_baud;
        }
        break;

    case RxState::STOP:
        if (m_rx_counter > 0) {
            m_rx_counter--;
        } else {
            // At mid-stop-bit: should be high
            if (!txd_pin)
                m_rx_frame_error = true;
            m_rx_byte = m_rx_shift;
            m_rx_ready = true;
            m_rx_state = RxState::IDLE;
        }
        break;
    }

    m_rx_last_pin = txd_pin;
    return m_rx_ready;
}

// TX: serialize bytes onto the rxd pin going into the FPGA
void SoftUART::TxEnqueue(uint8_t byte) {
    m_tx_queue.push(byte);
}

bool SoftUART::TxTick() {
    switch (m_tx_state) {
    case TxState::IDLE:
        if (!m_tx_queue.empty()) {
            m_tx_shift = m_tx_queue.front();
            m_tx_queue.pop();
            m_tx_state = TxState::START;
            m_tx_counter = m_clocks_per_baud;
            m_tx_pin = false; // start bit
            m_tx_bit_index = 0;
        }
        break;

    case TxState::START:
        if (m_tx_counter > 0) {
            m_tx_counter--;
        } else {
            m_tx_state = TxState::DATA;
            m_tx_pin = (m_tx_shift >> m_tx_bit_index) & 1;
            m_tx_counter = m_clocks_per_baud;
        }
        break;

    case TxState::DATA:
        if (m_tx_counter > 0) {
            m_tx_counter--;
        } else {
            m_tx_bit_index++;
            if (m_tx_bit_index >= m_data_bits) {
                if (m_parity_en) {
                    m_tx_state = TxState::PARITY;
                    // Compute parity
                    int ones = 0;
                    for (int i = 0; i < m_data_bits; i++)
                        if ((m_tx_shift >> i) & 1) ones++;
                    m_tx_pin = m_parity_even ? (ones & 1) : !(ones & 1);
                } else {
                    m_tx_state = TxState::STOP;
                    m_tx_pin = true; // stop bit
                    m_tx_stop_count = 0;
                }
            } else {
                m_tx_pin = (m_tx_shift >> m_tx_bit_index) & 1;
            }
            m_tx_counter = m_clocks_per_baud;
        }
        break;

    case TxState::PARITY:
        if (m_tx_counter > 0) {
            m_tx_counter--;
        } else {
            m_tx_state = TxState::STOP;
            m_tx_pin = true; // stop bit
            m_tx_stop_count = 0;
            m_tx_counter = m_clocks_per_baud;
        }
        break;

    case TxState::STOP:
        if (m_tx_counter > 0) {
            m_tx_counter--;
        } else {
            m_tx_stop_count++;
            if (m_tx_stop_count >= m_stop_bits) {
                m_tx_state = TxState::IDLE;
                m_tx_pin = true;
            } else {
                m_tx_counter = m_clocks_per_baud;
            }
        }
        break;
    }

    return m_tx_pin;
}

// ============================================================================
// SimSerialTerminal
// ============================================================================

SimSerialTerminal::SimSerialTerminal() {
    m_lines.push_back("[Serial terminal ready]");
}

bool SimSerialTerminal::Tick(bool fpga_txd_pin) {
    // RX: watch FPGA's txd, decode bytes
    if (m_uart.RxTick(fpga_txd_pin)) {
        uint8_t byte = m_uart.RxByte();
        m_rx_byte_count++;
        if (m_uart.RxFrameError())
            m_frame_error_count++;
        AddReceivedChar(byte);
    }

    // TX: drive rxd pin into FPGA
    return m_uart.TxTick();
}

void SimSerialTerminal::UpdateConfig(uint32_t uart_setup_reg) {
    uint32_t old_cpb = m_uart.GetClocksPerBaud();
    m_uart.ConfigureFromSetup(uart_setup_reg);
    if (m_uart.GetClocksPerBaud() != old_cpb) {
        fprintf(stderr, "Serial: baud config changed, clocks_per_baud=%u data_bits=%d\n",
                m_uart.GetClocksPerBaud(), m_uart.GetDataBits());
    }
}

void SimSerialTerminal::UpdateConfigDirect(uint32_t clocks_per_baud, int data_bits,
                                           int stop_bits, bool parity_en, bool parity_even) {
    uint32_t old_cpb = m_uart.GetClocksPerBaud();
    m_uart.Configure(clocks_per_baud, data_bits, stop_bits, parity_en, parity_even);
    if (clocks_per_baud != old_cpb) {
        uint32_t approx_baud = clocks_per_baud > 0 ? 31334400 / clocks_per_baud : 0;
        fprintf(stderr, "Serial: baud config changed, clocks_per_baud=%u (~%u baud) %d%c%d\n",
                clocks_per_baud, approx_baud, data_bits, parity_en ? (parity_even ? 'E' : 'O') : 'N', stop_bits);
    }
}

void SimSerialTerminal::AddReceivedChar(uint8_t c) {
    if (c >= 0x20 && c < 0x7F)
        fprintf(stderr, "SERIAL_RX: '%c' (0x%02X) total=%llu\n", c, c, (unsigned long long)m_rx_byte_count);
    else
        fprintf(stderr, "SERIAL_RX: 0x%02X total=%llu\n", c, (unsigned long long)m_rx_byte_count);
    if (m_hex_mode) {
        char hex[8];
        snprintf(hex, sizeof(hex), "%02X ", c);
        m_current_line += hex;
        if (m_current_line.length() > 72) {
            m_lines.push_back(m_current_line);
            m_current_line.clear();
        }
    } else {
        if (c == '\r') {
            m_lines.push_back(m_current_line);
            m_current_line.clear();
            m_last_was_cr = true;
        } else if (c == '\n') {
            if (!m_last_was_cr) {
                m_lines.push_back(m_current_line);
                m_current_line.clear();
            }
            m_last_was_cr = false;
        } else if (c == '\b' || c == 0x7F) {
            if (!m_current_line.empty())
                m_current_line.pop_back();
            m_last_was_cr = false;
        } else if (c >= 0x20 && c < 0x7F) {
            m_current_line += (char)c;
            m_last_was_cr = false;
        } else {
            // Non-printable: show as <XX>
            char hex[8];
            snprintf(hex, sizeof(hex), "<%02X>", c);
            m_current_line += hex;
            m_last_was_cr = false;
        }
    }

    // Trim old lines
    while ((int)m_lines.size() > MAX_LINES)
        m_lines.erase(m_lines.begin());

    m_scroll_to_bottom = true;
}

void SimSerialTerminal::SendInput() {
    // Send each character
    for (int i = 0; m_input_buf[i]; i++) {
        m_uart.TxEnqueue((uint8_t)m_input_buf[i]);
        m_tx_byte_count++;
    }
    // Send line ending
    switch (m_line_ending) {
    case LineEnding::CR:   m_uart.TxEnqueue('\r'); m_tx_byte_count++; break;
    case LineEnding::LF:   m_uart.TxEnqueue('\n'); m_tx_byte_count++; break;
    case LineEnding::CRLF: m_uart.TxEnqueue('\r'); m_uart.TxEnqueue('\n'); m_tx_byte_count += 2; break;
    }
    m_input_buf[0] = '\0';
}

void SimSerialTerminal::UpdateSCCStatus(uint8_t wr3, uint8_t wr5, uint8_t wr9, uint8_t wr14) {
    m_scc_wr3 = wr3;
    m_scc_wr5 = wr5;
    m_scc_wr9 = wr9;
    m_scc_wr14 = wr14;
}

void SimSerialTerminal::Draw(const char* title, bool* p_open) {
    ImGui::SetNextWindowSize(ImVec2(580, 420), ImGuiCond_FirstUseEver);

    if (!ImGui::Begin(title, p_open)) {
        ImGui::End();
        return;
    }

    // SCC init status
    bool rx_en = m_scc_wr3 & 0x01;   // WR3[0] = RX Enable
    bool tx_en = m_scc_wr5 & 0x08;   // WR5[3] = TX Enable
    bool brg_en = m_scc_wr14 & 0x01; // WR14[0] = BRG Enable
    bool mie = m_scc_wr9 & 0x08;     // WR9[3] = Master Interrupt Enable
    bool scc_ready = rx_en && tx_en && brg_en;

    if (scc_ready)
        ImGui::TextColored(ImVec4(0.4f, 1.0f, 0.4f, 1.0f), "SCC READY");
    else
        ImGui::TextColored(ImVec4(1.0f, 0.4f, 0.4f, 1.0f), "SCC INIT");
    ImGui::SameLine();
    ImGui::TextDisabled("RX:%s TX:%s BRG:%s MIE:%s",
                        rx_en ? "on" : "--", tx_en ? "on" : "--",
                        brg_en ? "on" : "--", mie ? "on" : "--");

    // Status bar
    uint32_t cpb = m_uart.GetClocksPerBaud();
    uint32_t approx_baud = cpb > 0 ? 31334400 / cpb : 0;
    ImGui::Text("~%u baud (%u cpb) %dN%d | RX: %llu  TX: %llu  Err: %u",
                approx_baud, cpb, m_uart.GetDataBits(), 1,
                (unsigned long long)m_rx_byte_count,
                (unsigned long long)m_tx_byte_count,
                m_frame_error_count);
    ImGui::SameLine();

    // Buttons
    if (ImGui::SmallButton("Clear")) {
        m_lines.clear();
        m_current_line.clear();
        m_rx_byte_count = 0;
        m_tx_byte_count = 0;
        m_frame_error_count = 0;
    }
    ImGui::SameLine();
    ImGui::Checkbox("Hex", &m_hex_mode);
    ImGui::SameLine();
    ImGui::Checkbox("Auto-scroll", &m_auto_scroll);

    ImGui::Separator();

    // Scrolling text region
    float footer_height = ImGui::GetStyle().ItemSpacing.y + ImGui::GetFrameHeightWithSpacing() + 4;
    ImGui::BeginChild("ScrollRegion", ImVec2(0, -footer_height), false,
                      ImGuiWindowFlags_HorizontalScrollbar);

    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(4, 1));
    for (const auto& line : m_lines) {
        ImGui::TextUnformatted(line.c_str());
    }
    // Show current (incomplete) line with cursor
    if (!m_current_line.empty()) {
        std::string display = m_current_line + "_";
        ImGui::TextUnformatted(display.c_str());
    }
    ImGui::PopStyleVar();

    if (m_scroll_to_bottom || (m_auto_scroll && ImGui::GetScrollY() >= ImGui::GetScrollMaxY()))
        ImGui::SetScrollHereY(1.0f);
    m_scroll_to_bottom = false;

    ImGui::EndChild();

    // Input field
    ImGui::Separator();
    bool reclaim_focus = false;
    ImGuiInputTextFlags flags = ImGuiInputTextFlags_EnterReturnsTrue;
    ImGui::PushItemWidth(-100);
    if (ImGui::InputText("##Input", m_input_buf, sizeof(m_input_buf), flags)) {
        SendInput();
        reclaim_focus = true;
    }
    ImGui::PopItemWidth();
    ImGui::SameLine();

    // Line ending selector
    const char* le_labels[] = { "CR", "LF", "CRLF" };
    int le_idx = (int)m_line_ending;
    ImGui::PushItemWidth(60);
    if (ImGui::Combo("##LE", &le_idx, le_labels, 3))
        m_line_ending = (LineEnding)le_idx;
    ImGui::PopItemWidth();

    // Auto-focus the input
    ImGui::SetItemDefaultFocus();
    if (reclaim_focus)
        ImGui::SetKeyboardFocusHere(-1);

    ImGui::End();
}
