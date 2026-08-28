//============================================================================
//  z8530_scc - Zilog Z8530 / Z85C30 SCC, synthesisable model.
//
//  Vendored from the DE1 SGI sandbox, where it was written for this project
//  and debugged against the IP24 PROM's console output. Not SGI-specific: the
//  SGI-side glue (which of the four stride-4 IOC ports is which channel, how a
//  byte gets from the CPU bus onto cs_n/rd_n/wr_n) lives in sgi_scc.sv, and
//  this file is the part itself.
//
//  Two clock domains. `clk` is the CPU/bus side: the register file, the
//  interrupt latches and the RR read mux. `sclk` is the serial side: the baud
//  rate generator, the TX and RX bit state machines and the external clock
//  synchronisers. The byte FIFOs between them are asynchronous, with
//  Gray-coded pointers.
//
//  The dbg_tx_byte_* outputs are a non-standard debug tap: they present the
//  byte a channel has just popped from its TX FIFO into the shift register,
//  with a one-cycle strobe. That is what the console tap uses - see
//  docs/06-simulation.md on why decoding the serial waveform is the wrong way
//  to read what the machine is printing.
//============================================================================

// Two-clock-domain implementation:
//   clk  : CPU / bus side. Register file, interrupt latches, RR mux.
//   sclk : Serial side (intended to be sourced from a 3.6864 MHz oscillator
//          to match a real Apple Lisa / Macintosh SCC). Runs the BRG, the
//          external clock-pin synchronizers, the RX data synchronizers and
//          the TX/RX bit-level state machines.
//
// The TX and RX byte FIFOs are asynchronous (clk write / sclk read for TX,
// sclk write / clk read for RX) and use Gray-coded pointer synchronizers.
//
// Features unchanged from the original single-clock model:
//   - Dual independent full-duplex channels (A and B)
//   - Asynchronous mode support, programmable BRG
//   - 4-byte TX and RX FIFOs per channel (was 3 - bumped to 4 so a standard
//     2-bit pointer async FIFO can be used; "TX Buffer Empty" semantics
//     remain "not full".)
//   - Interrupt generation with vector support
//   - Read/Write register interface
//============================================================================

module z8530_scc #(
    // Enable WR9[7:6] software reset commands (force / per-channel).
    // Set to 0 to compile out the soft-reset logic entirely (stretch counters,
    // CDC, and all reset overrides become inert and are optimized away).
    parameter SOFT_RESET_EN = 1,
    // When 1, reading RR8 via the control port (reg_ptr=8, d_c=0) also pops
    // the RX FIFO -- matches real Z8530 datasheet. Set to 0 to pop only on
    // data-port reads (d_c=1). Use 0 if a driver does back-to-back control-
    // port RR8 reads expecting the same byte (some clones / quirky drivers).
    parameter RR8_CTRL_POP = 1,
    // When 1, writing WR8 via the control port (reg_ptr=8, d_c=0) pushes the
    // byte into the TX FIFO, exactly as a data-port write does. The datasheet
    // is explicit: "A read to RR8 (the receive data FIFO) or a write to WR8
    // (the transmit data FIFO) is either done in this fashion or by accessing
    // the Z85X30 having D//C pin High", and 5.2.11 says "WR8 is the transmit
    // buffer register". THE IP24 PROM DEPENDS ON THIS. Its power-on console
    // routine (pon_putc, 0xBFC03C34) never touches the data port at all: it
    // polls RR0 through the command port, writes 8 to point at WR8, and then
    // writes the character to the same command port. With this path missing
    // the SCC accepts the whole boot banner and prints nothing.
    parameter WR8_CTRL_PUSH = 1,
    // Per-channel BRG clock source (synthesis-time):
    //   1 = sclk (historical SCC RTxC/sclk source, e.g. 3.6864 MHz) -- default
    //   0 = pclk (alternative peripheral clock; can be tied to clk in wrapper)
    // The selection internally synthesizes sclk_a/sclk_b as the chosen clock,
    // giving each channel its own clock domain. WR14[1] is currently stored
    // only; runtime selection would require a glitch-free clock mux.
    parameter BRG_SRC_A = 0,
    parameter BRG_SRC_B = 1,
    // Uniplus Unix workaround (Channel B only): when 1, patch BRG time
    // constant 0x000B -> 0x000A at the divisor input. Lisa Uniplus programs
    // TC=0x0B on Channel B for 9600 baud, almost certainly because it
    // computes the TC assuming Channel B is clocked from the same 4 MHz
    // source as Channel A; at a true 3.6864 MHz that value yields ~8861
    // baud (7.7% slow). With this patch the BRG counter sees 0x0A, giving
    // exact 9600 baud at 3.6864 MHz. RR12/RR13 still read back the value
    // software wrote, and other TC values pass through unchanged. Channel A
    // is left alone because its source is 4 MHz where Uniplus's TC table is
    // already correct.
    parameter UNIPLUS_BAUD_PATCH_B = 1,
    // Enable WR3[5] Auto Enables: /CTS gates the transmitter, /DCD gates the
    // receiver, and (async) /RTS deassert is deferred until the transmitter
    // is empty. Set to 0 to compile the feature out (RTS strictly follows
    // WR5[1]; CTS/DCD remain status/interrupt-only).
    parameter AUTO_ENABLES_EN = 1,
    // Per-channel "RTxC from XTAL, full-rate clock" support (synthesis-time):
    //   When set to 1 and software programs WR11[7]=1 (RTxC=XTAL) with both the
    //   RX clock source (WR11[6:5]=00) and TX clock source (WR11[4:3]=00) set to
    //   RTxC, the channel's serial engine is clocked every sclk cycle (RTxC is
    //   treated as the sclk crystal) instead of from a routed pin clock. The
    //   WR4 clock-mode divide (x1/16/32/64) still applies, so the effective bit
    //   rate is sclk/ClockMode. Set to 0 to compile the override out (that WR11
    //   encoding then selects the RTxC pin, which is tied off -> dead engine).
    parameter RTXC_XTAL_FULLRATE_A = 1,
    parameter RTXC_XTAL_FULLRATE_B = 1
) (
    // System Interface
    input  wire        clk,           // CPU/bus clock (register file, interrupts, RR mux)
    input  wire        pclk,          // Alternative BRG/serializer clock (Zilog "PCLK")
    input  wire        sclk,          // Primary BRG/serializer clock (e.g. 3.6864 MHz)
    input  wire        reset_n,       // Active low reset (async assert)

    // CPU Interface
    input  wire        cs_n,          // Chip select (active low)
    input  wire        rd_n,          // Read strobe (active low)
    input  wire        wr_n,          // Write strobe (active low)
    input  wire        a_b,           // Channel select: 1=A, 0=B
    input  wire        d_c,           // Data/Control: 1=Data, 0=Control
    input  wire [7:0]  data_in,       // Data input
    output reg  [7:0]  data_out,      // Data output
    output wire        data_oe,       // Data output enable

    // Interrupt
    output wire        int_n,         // Interrupt output (active low)
    input  wire        intack_n,      // Interrupt acknowledge

    // Channel A Serial Interface
    input  wire        rxca,          // Receive clock A
    input  wire        txca,          // Transmit clock A
    input  wire        rxda,          // Receive data A
    output wire        txda,          // Transmit data A
    input  wire        ctsa_n,        // Clear to send A (active low)
    input  wire        dcda_n,        // Data carrier detect A (active low)
    input  wire        synca_n,       // Sync A (async-mode input -> RR0[4], active low)
    output wire        rtsa_n,        // Request to send A (active low)
    output wire        dtra_n,        // Data terminal ready A (active low)

    // Channel B Serial Interface
    input  wire        rxcb,          // Receive clock B
    input  wire        txcb,          // Transmit clock B
    input  wire        rxdb,          // Receive data B
    output wire        txdb,          // Transmit data B
    input  wire        ctsb_n,        // Clear to send B (active low)
    input  wire        dcdb_n,        // Data carrier detect B (active low)
    input  wire        syncb_n,       // Sync B (async-mode input -> RR0[4], active low)
    output wire        rtsb_n,        // Request to send B (active low)
    output wire        dtrb_n,        // Data terminal ready B (active low)

    // --- Non-standard debug extension (SGI Indy sim project) ---
    // Exposes the byte a channel just popped from its TX FIFO into tx_shift,
    // and a strobe that pulses for one clk-domain cycle when that happens.
    // Lets a testbench observe "what byte did the CPU send" without needing
    // a real bit clock / decoding the serial waveform - see the
    // SCC1_TXD_DATA_OUT/SCC1_TXD_START_OUT comment in DE1_TOP.v.
    output wire [7:0]  dbg_tx_byte_a,
    output wire        dbg_tx_byte_a_strobe,
    output wire [7:0]  dbg_tx_byte_b,
    output wire        dbg_tx_byte_b_strobe,
    output wire        dbg_read_en,
    output wire [7:0]  dbg_rr0_a,
    output wire        dbg_tx_fifo_wfull_a
);

//============================================================================
// Internal Signals
//============================================================================

// --- clk domain ---
// Register pointer
reg [3:0] reg_ptr_a;
reg [3:0] reg_ptr_b;

// Auto-Enable deferred /RTS deassert hold (clk domain)
reg        rts_hold_a, rts_hold_b;

// Write Registers for Channel A (WR0-WR15)
reg [7:0] wr0_a, wr1_a, wr2_a, wr3_a, wr4_a, wr5_a, wr6_a, wr7_a;
reg [7:0] wr9_a, wr10_a, wr11_a, wr12_a, wr13_a, wr14_a, wr15_a;

// Write Registers for Channel B
reg [7:0] wr0_b, wr1_b, wr3_b, wr4_b, wr5_b, wr6_b, wr7_b;
reg [7:0] wr10_b, wr11_b, wr12_b, wr13_b, wr14_b, wr15_b;

// Read Registers
wire [7:0] rr0_a, rr0_b;
wire [7:0] rr1_a, rr1_b;
wire [7:0] rr2_a, rr2_b;
wire [7:0] rr3_a;
wire [7:0] rr8_a, rr8_b;
wire [7:0] rr10_a, rr10_b;
wire [7:0] rr12_a, rr12_b;
wire [7:0] rr13_a, rr13_b;
wire [7:0] rr15_a, rr15_b;

// Interrupt pending flags (clk-domain latches)
reg        rx_int_pend_a, rx_int_pend_b;
reg        tx_int_pend_a, tx_int_pend_b;
reg        ext_int_pend_a, ext_int_pend_b;

// Toggle pulse clk -> sclk: WR0 error-reset command per channel
reg        err_rst_toggle_a, err_rst_toggle_b;

// --- sclk domain ---
// Baud rate generators
reg [16:0] brg_counter_a, brg_counter_b;
reg        brg_out_a, brg_out_b;
reg        brg_out_a_d, brg_out_b_d;

// Serial TX state machines
reg [3:0]  tx_state_a, tx_state_b;
reg [7:0]  tx_shift_a, tx_shift_b;
reg [3:0]  tx_bit_cnt_a, tx_bit_cnt_b;
reg [5:0]  tx_sample_cnt_a, tx_sample_cnt_b;  // clock-mode timing counters (x1/16/32/64)
reg        tx_out_a, tx_out_b;
reg        tx_active_a, tx_active_b;
reg        tx_underrun_a, tx_underrun_b;       // placeholder, unused (kept for RR0)
reg        tx_byte_grab_toggle_a, tx_byte_grab_toggle_b; // TX int trigger pulse to clk

// Serial RX state machines
reg [3:0]  rx_state_a, rx_state_b;
reg [7:0]  rx_shift_a, rx_shift_b;
reg [3:0]  rx_bit_cnt_a, rx_bit_cnt_b;
reg [5:0]  rx_sample_cnt_a, rx_sample_cnt_b;  // clock-mode timing counters (x1/16/32/64)
reg        rx_active_a, rx_active_b;

// RX BREAK detect (sclk domain). break_*_s is sticky-high while the RX line
// stays low past one full character frame; cleared when the line returns to 1
// or on err_rst pulse from clk. CDC'd to clk via 2-FF sync below.
//
// Counter advances on rx_clk_*_s ticks (the BRG/external bit-sample clock),
// not raw sclk -- so the threshold is in bit-sample units and scales with
// baud automatically. In x16 mode, 11 bit-times = 176 ticks; legal "all-zero
// data byte" gives at most 9 bit-times of low (144 ticks in x16) before the
// stop bit forces line high and resets the counter. Threshold 176 is safe.
reg        break_a_s, break_b_s;
reg [7:0]  break_cnt_a, break_cnt_b;   // counts consecutive low rx-clk ticks
localparam [7:0] BREAK_THRESHOLD = 8'd176;

// RX error flags (set in sclk by FSM, cleared by err_rst pulse from clk).
// Synchronized to clk for the RR1 read.
reg        rx_overrun_a, rx_overrun_b;
reg        rx_framing_err_a, rx_framing_err_b;
reg        rx_parity_err_a, rx_parity_err_b;

// sclk-side capture of err_rst_toggle from clk
reg [2:0]  err_rst_a_sync_s, err_rst_b_sync_s;

// sclk-side mirrors of CPU configuration bytes used by the serializer.
// 2-FF synchronizers (s1 is the metastability buffer, s is consumed value).
reg [7:0]  wr3_a_s1,  wr3_a_s,   wr3_b_s1,  wr3_b_s;
reg [7:0]  wr4_a_s1,  wr4_a_s,   wr4_b_s1,  wr4_b_s;
reg [7:0]  wr5_a_s1,  wr5_a_s,   wr5_b_s1,  wr5_b_s;
reg [7:0]  wr11_a_s1, wr11_a_s,  wr11_b_s1, wr11_b_s;
reg [7:0]  wr12_a_s1, wr12_a_s,  wr12_b_s1, wr12_b_s;
reg [7:0]  wr13_a_s1, wr13_a_s,  wr13_b_s1, wr13_b_s;
reg [7:0]  wr14_a_s1, wr14_a_s,  wr14_b_s1, wr14_b_s;

// --- sclk -> clk status syncs ---
reg [1:0]  tx_active_a_sync,  tx_active_b_sync;
reg [2:0]  tx_byte_grab_a_sync, tx_byte_grab_b_sync;
reg [1:0]  rx_overrun_a_sync, rx_overrun_b_sync;
reg [1:0]  break_a_sync, break_b_sync;   // BREAK status sclk -> clk
reg [1:0]  rx_framing_err_a_sync, rx_framing_err_b_sync;
reg [1:0]  rx_parity_err_a_sync, rx_parity_err_b_sync;
reg [1:0]  tx_underrun_a_sync, tx_underrun_b_sync;
reg [1:0]  tx_drained_a_sync, tx_drained_b_sync;   // sclk transmitter-idle -> clk

// Clock synchronizers
//   External serial-clock pins (rxca/rxcb/txca/txcb) live in the sclk domain;
//   their level is also re-synchronized to clk so anything that still wants a
//   clk-domain rising-edge pulse keeps working.
reg [2:0]  rxca_sync_s, rxcb_sync_s, txca_sync_s, txcb_sync_s; // sclk domain
reg [2:0]  rxca_sync_c, rxcb_sync_c, txca_sync_c, txcb_sync_c; // clk re-sync

// RX data synchronizers - now in sclk (used by RX FSM)
reg [2:0]  rxda_sync_s, rxdb_sync_s;

wire       rxca_rise, rxcb_rise, txca_rise, txcb_rise;            // clk side (unused)
wire       rxca_rise_s, rxcb_rise_s, txca_rise_s, txcb_rise_s;    // sclk side

// Modem signal synchronizers (clk domain - used by ext/status int logic)
reg [2:0]  ctsa_sync, ctsb_sync, dcda_sync, dcdb_sync;

// /SYNC pin synchronizers (clk domain). In async receive mode these pins are
// inputs whose level is reflected in RR0[4] (Sync/Hunt); per the datasheet they
// have no other function here (status only - no interrupt, no gating).
reg [2:0]  synca_sync, syncb_sync;

// CTS/DCD synchronized into the per-channel sclk domains for Auto-Enable
// TX/RX gating (active-low pins; asserted = 0).
reg [1:0]  ctsa_s_sync, dcda_s_sync;   // sclk_a
reg [1:0]  ctsb_s_sync, dcdb_s_sync;   // sclk_b

//============================================================================
// Parameters and State Definitions
//============================================================================

localparam TX_IDLE    = 4'd0;
localparam TX_START   = 4'd1;
localparam TX_DATA    = 4'd2;
localparam TX_PARITY  = 4'd3;
localparam TX_STOP1   = 4'd4;
localparam TX_STOP2   = 4'd5;

localparam RX_IDLE    = 4'd0;
localparam RX_START   = 4'd1;
localparam RX_DATA    = 4'd2;
localparam RX_PARITY  = 4'd3;
localparam RX_STOP    = 4'd4;

//============================================================================
// Control Signal Generation
//============================================================================
wire wr_cmd_n_p;
wire wr_cmd_n;
reg  wr_cmd_s0;

wire chip_sel   = ~cs_n;
wire read_en    = chip_sel & ~rd_n;
reg  read_en_s0;
wire write_en   = chip_sel & ~wr_cmd_n_p/*wr_n*/;

assign data_oe  = read_en;

// RTS and DTR outputs. With Auto Enables, RTS deassert is deferred (see the
// rts_hold_* logic below); assert is always immediate.
assign rtsa_n = ~(wr5_a[1] | rts_hold_a);  // RTS bit in WR5
assign dtra_n = ~wr5_a[7];  // DTR bit in WR5
assign rtsb_n = ~(wr5_b[1] | rts_hold_b);
assign dtrb_n = ~wr5_b[7];

// TX data outputs. WR5[4] (Send Break) forces the line low regardless of FSM.
// Uses the sclk-domain mirror so the override is glitch-free against TX FSM.
assign txda = wr5_a_s[4] ? 1'b0 : tx_out_a;
assign txdb = wr5_b_s[4] ? 1'b0 : tx_out_b;

//============================================================================
// Per-channel BRG clock + reset synchronizers
//   sclk_a, sclk_b are each driven from either `sclk` or `clk` per parameter.
//   Each has its own 2-FF reset synchronizer; reset_n is the async source.
//============================================================================

wire sclk_a = (BRG_SRC_A != 0) ? sclk : pclk;
wire sclk_b = (BRG_SRC_B != 0) ? sclk : pclk;

reg [1:0] sreset_a_sync, sreset_b_sync;
always @(posedge sclk_a or negedge reset_n) begin
    if (!reset_n) sreset_a_sync <= 2'b00;
    else          sreset_a_sync <= {sreset_a_sync[0], 1'b1};
end
always @(posedge sclk_b or negedge reset_n) begin
    if (!reset_n) sreset_b_sync <= 2'b00;
    else          sreset_b_sync <= {sreset_b_sync[0], 1'b1};
end
wire sreset_n_a = sreset_a_sync[1];
wire sreset_n_b = sreset_b_sync[1];

//============================================================================
// WR9[7:6] software reset commands
//   11 = Force Hardware Reset (both channels + shared WR2/WR9)
//   10 = Channel Reset A
//   01 = Channel Reset B
//
// A command produces a per-channel soft-reset that is stretched in clk so it
// reliably crosses to the slower sclk domain (2-FF sync) and so both sides of
// each async FIFO are held in reset with overlap. The clk-side hold is long
// enough (RST_STRETCH clk cycles) to contain the full sclk-side reset window.
//============================================================================

localparam [6:0] RST_STRETCH = 7'd96;   // ~4.8 us at 20 MHz (~17 sclk periods)

wire wr9_write_evt = SOFT_RESET_EN && write_en && !d_c &&
                     (( a_b && reg_ptr_a == 4'd9) ||
                      (!a_b && reg_ptr_b == 4'd9));
wire force_hw_cmd  = wr9_write_evt && (data_in[7:6] == 2'b11);
wire chreset_a_cmd = wr9_write_evt && (data_in[7:6] == 2'b10);
wire chreset_b_cmd = wr9_write_evt && (data_in[7:6] == 2'b01);

reg [6:0] rst_a_cnt, rst_b_cnt, force_cnt;
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        rst_a_cnt <= 7'd0;
        rst_b_cnt <= 7'd0;
        force_cnt <= 7'd0;
    end else begin
        if (chreset_a_cmd || force_hw_cmd) rst_a_cnt <= RST_STRETCH;
        else if (rst_a_cnt != 0)           rst_a_cnt <= rst_a_cnt - 1'b1;

        if (chreset_b_cmd || force_hw_cmd) rst_b_cnt <= RST_STRETCH;
        else if (rst_b_cnt != 0)           rst_b_cnt <= rst_b_cnt - 1'b1;

        if (force_hw_cmd)                  force_cnt <= RST_STRETCH;
        else if (force_cnt != 0)           force_cnt <= force_cnt - 1'b1;
    end
end

wire rst_a_clk = (rst_a_cnt != 0);   // channel A soft reset (clk domain)
wire rst_b_clk = (rst_b_cnt != 0);   // channel B soft reset (clk domain)
wire force_clk = (force_cnt != 0);   // force reset, clears shared WR2/WR9

// CDC the channel soft-resets into their respective sclk_* domains
reg [2:0] rst_a_sclk_sync, rst_b_sclk_sync;
always @(posedge sclk_a or negedge sreset_n_a) begin
    if (!sreset_n_a) rst_a_sclk_sync <= 3'b0;
    else             rst_a_sclk_sync <= {rst_a_sclk_sync[1:0], rst_a_clk};
end
always @(posedge sclk_b or negedge sreset_n_b) begin
    if (!sreset_n_b) rst_b_sclk_sync <= 3'b0;
    else             rst_b_sclk_sync <= {rst_b_sclk_sync[1:0], rst_b_clk};
end
wire rst_a_sclk = rst_a_sclk_sync[2];   // channel A soft reset (sclk_a domain)
wire rst_b_sclk = rst_b_sclk_sync[2];   // channel B soft reset (sclk_b domain)

//============================================================================
// Clock-pin synchronizers (sclk) + clk-side re-sync (for legacy users)
//============================================================================

always @(posedge sclk_a or negedge sreset_n_a) begin
    if (!sreset_n_a) begin
        rxca_sync_s <= 3'b0;
        txca_sync_s <= 3'b0;
        rxda_sync_s <= 3'b111;
    end else begin
        rxca_sync_s <= {rxca_sync_s[1:0], rxca};
        txca_sync_s <= {txca_sync_s[1:0], txca};
        rxda_sync_s <= {rxda_sync_s[1:0], rxda};
    end
end

always @(posedge sclk_b or negedge sreset_n_b) begin
    if (!sreset_n_b) begin
        rxcb_sync_s <= 3'b0;
        txcb_sync_s <= 3'b0;
        rxdb_sync_s <= 3'b111;
    end else begin
        rxcb_sync_s <= {rxcb_sync_s[1:0], rxcb};
        txcb_sync_s <= {txcb_sync_s[1:0], txcb};
        rxdb_sync_s <= {rxdb_sync_s[1:0], rxdb};
    end
end

assign rxca_rise_s = (rxca_sync_s[2:1] == 2'b01);
assign rxcb_rise_s = (rxcb_sync_s[2:1] == 2'b01);
assign txca_rise_s = (txca_sync_s[2:1] == 2'b01);
assign txcb_rise_s = (txcb_sync_s[2:1] == 2'b01);

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        rxca_sync_c <= 3'b0;
        rxcb_sync_c <= 3'b0;
        txca_sync_c <= 3'b0;
        txcb_sync_c <= 3'b0;
        ctsa_sync   <= 3'b111;
        ctsb_sync   <= 3'b111;
        dcda_sync   <= 3'b111;
        dcdb_sync   <= 3'b111;
        synca_sync  <= 3'b111;
        syncb_sync  <= 3'b111;
    end else begin
        rxca_sync_c <= {rxca_sync_c[1:0], rxca_sync_s[2]};
        rxcb_sync_c <= {rxcb_sync_c[1:0], rxcb_sync_s[2]};
        txca_sync_c <= {txca_sync_c[1:0], txca_sync_s[2]};
        txcb_sync_c <= {txcb_sync_c[1:0], txcb_sync_s[2]};
        ctsa_sync   <= {ctsa_sync[1:0], ctsa_n};
        ctsb_sync   <= {ctsb_sync[1:0], ctsb_n};
        dcda_sync   <= {dcda_sync[1:0], dcda_n};
        dcdb_sync   <= {dcdb_sync[1:0], dcdb_n};
        synca_sync  <= {synca_sync[1:0], synca_n};
        syncb_sync  <= {syncb_sync[1:0], syncb_n};
    end
end

assign rxca_rise = (rxca_sync_c[2:1] == 2'b01);
assign rxcb_rise = (rxcb_sync_c[2:1] == 2'b01);
assign txca_rise = (txca_sync_c[2:1] == 2'b01);
assign txcb_rise = (txcb_sync_c[2:1] == 2'b01);

//============================================================================
// Config-byte synchronizers (clk -> sclk)
//   Updated atomically by the CPU register-write logic; safe to single-flop
//   sync because reads happen long after any write completes.
//============================================================================

always @(posedge sclk_a or negedge sreset_n_a) begin
    if (!sreset_n_a) begin
        wr3_a_s1  <= 8'h0; wr3_a_s  <= 8'h0;
        wr4_a_s1  <= 8'h0; wr4_a_s  <= 8'h0;
        wr5_a_s1  <= 8'h0; wr5_a_s  <= 8'h0;
        wr11_a_s1 <= 8'h0; wr11_a_s <= 8'h0;
        wr12_a_s1 <= 8'h0; wr12_a_s <= 8'h0;
        wr13_a_s1 <= 8'h0; wr13_a_s <= 8'h0;
        wr14_a_s1 <= 8'h0; wr14_a_s <= 8'h0;
    end else begin
        wr3_a_s1  <= wr3_a;  wr3_a_s  <= wr3_a_s1;
        wr4_a_s1  <= wr4_a;  wr4_a_s  <= wr4_a_s1;
        wr5_a_s1  <= wr5_a;  wr5_a_s  <= wr5_a_s1;
        wr11_a_s1 <= wr11_a; wr11_a_s <= wr11_a_s1;
        wr12_a_s1 <= wr12_a; wr12_a_s <= wr12_a_s1;
        wr13_a_s1 <= wr13_a; wr13_a_s <= wr13_a_s1;
        wr14_a_s1 <= wr14_a; wr14_a_s <= wr14_a_s1;
    end
end

always @(posedge sclk_b or negedge sreset_n_b) begin
    if (!sreset_n_b) begin
        wr3_b_s1  <= 8'h0; wr3_b_s  <= 8'h0;
        wr4_b_s1  <= 8'h0; wr4_b_s  <= 8'h0;
        wr5_b_s1  <= 8'h0; wr5_b_s  <= 8'h0;
        wr11_b_s1 <= 8'h0; wr11_b_s <= 8'h0;
        wr12_b_s1 <= 8'h0; wr12_b_s <= 8'h0;
        wr13_b_s1 <= 8'h0; wr13_b_s <= 8'h0;
        wr14_b_s1 <= 8'h0; wr14_b_s <= 8'h0;
    end else begin
        wr3_b_s1  <= wr3_b;  wr3_b_s  <= wr3_b_s1;
        wr4_b_s1  <= wr4_b;  wr4_b_s  <= wr4_b_s1;
        wr5_b_s1  <= wr5_b;  wr5_b_s  <= wr5_b_s1;
        wr11_b_s1 <= wr11_b; wr11_b_s <= wr11_b_s1;
        wr12_b_s1 <= wr12_b; wr12_b_s <= wr12_b_s1;
        wr13_b_s1 <= wr13_b; wr13_b_s <= wr13_b_s1;
        wr14_b_s1 <= wr14_b; wr14_b_s <= wr14_b_s1;
    end
end

//============================================================================
// Baud Rate Generators - now in sclk
//   baud = f_sclk / (2 * (TC + 2) * ClockMode), real-Z8530 formula.
//============================================================================

wire        brg_enabled_a_s = wr14_a_s[0];
wire [15:0] brg_divisor_a   = {wr13_a_s, wr12_a_s};
wire [16:0] brg_reload_a    = {1'b0, brg_divisor_a} + 17'd1;

wire        brg_enabled_b_s   = wr14_b_s[0];
wire [15:0] brg_divisor_b_raw = {wr13_b_s, wr12_b_s};
// UNIPLUS_BAUD_PATCH_B: substitute 0x000A when software programs 0x000B.
// Lisa Uniplus picks TC=0x0B for Ch B 9600 baud, likely assuming Ch B
// shares the 4 MHz Ch A source; with Ch B actually fed from 3.6864 MHz,
// 0x0A is the correct value, so we rewrite.
wire [15:0] brg_divisor_b     = (UNIPLUS_BAUD_PATCH_B != 0 &&
                                 brg_divisor_b_raw == 16'h000B)
                                ? 16'h000A : brg_divisor_b_raw;
wire [16:0] brg_reload_b      = {1'b0, brg_divisor_b} + 17'd1;

always @(posedge sclk_a or negedge sreset_n_a) begin
    if (!sreset_n_a) begin
        brg_counter_a <= 17'd0;
        brg_out_a     <= 1'b0;
    end else if (rst_a_sclk) begin
        brg_counter_a <= 17'd0;
        brg_out_a     <= 1'b0;
    end else if (brg_enabled_a_s) begin
        if (brg_counter_a == 17'd0) begin
            brg_counter_a <= brg_reload_a;
            brg_out_a     <= ~brg_out_a;
        end else begin
            brg_counter_a <= brg_counter_a - 1'b1;
        end
    end
end

always @(posedge sclk_b or negedge sreset_n_b) begin
    if (!sreset_n_b) begin
        brg_counter_b <= 17'd0;
        brg_out_b     <= 1'b0;
    end else if (rst_b_sclk) begin
        brg_counter_b <= 17'd0;
        brg_out_b     <= 1'b0;
    end else if (brg_enabled_b_s) begin
        if (brg_counter_b == 17'd0) begin
            brg_counter_b <= brg_reload_b;
            brg_out_b     <= ~brg_out_b;
        end else begin
            brg_counter_b <= brg_counter_b - 1'b1;
        end
    end
end

// BRG edge detection (sclk_a / sclk_b respectively)
wire brg_rise_a_s = brg_out_a & ~brg_out_a_d;
wire brg_rise_b_s = brg_out_b & ~brg_out_b_d;

always @(posedge sclk_a or negedge sreset_n_a) begin
    if (!sreset_n_a) brg_out_a_d <= 1'b0;
    else             brg_out_a_d <= rst_a_sclk ? 1'b0 : brg_out_a;
end

always @(posedge sclk_b or negedge sreset_n_b) begin
    if (!sreset_n_b) brg_out_b_d <= 1'b0;
    else             brg_out_b_d <= rst_b_sclk ? 1'b0 : brg_out_b;
end

//============================================================================
// TX / RX bit-clock selection (sclk)
//============================================================================

// "RTxC from XTAL, both RX and TX clocks from RTxC" -> run the serial engine at
// full sclk rate (RTxC == sclk) without routing an actual pin clock. Per-channel
// compile-time enable. Uses the sclk-synced WR11 copy.
wire rtxc_xtal_a_s = (RTXC_XTAL_FULLRATE_A != 0) && wr11_a_s[7]
                     && (wr11_a_s[6:5] == 2'b00) && (wr11_a_s[4:3] == 2'b00);
wire rtxc_xtal_b_s = (RTXC_XTAL_FULLRATE_B != 0) && wr11_b_s[7]
                     && (wr11_b_s[6:5] == 2'b00) && (wr11_b_s[4:3] == 2'b00);

wire tx_clk_a_s = rtxc_xtal_a_s ? 1'b1 : ((wr11_a_s[4:3] == 2'b10) ? brg_rise_a_s : txca_rise_s);
wire tx_clk_b_s = rtxc_xtal_b_s ? 1'b1 : ((wr11_b_s[4:3] == 2'b10) ? brg_rise_b_s : txcb_rise_s);
wire rx_clk_a_s = rtxc_xtal_a_s ? 1'b1 : ((wr11_a_s[6:5] == 2'b10) ? brg_rise_a_s : rxca_rise_s);
wire rx_clk_b_s = rtxc_xtal_b_s ? 1'b1 : ((wr11_b_s[6:5] == 2'b10) ? brg_rise_b_s : rxcb_rise_s);

//============================================================================
// Auto Enables (WR3[5]) - CTS/DCD synchronized into sclk + gating terms
//   /CTS (low) auto-enables the transmitter; /DCD (low) auto-enables the
//   receiver. Synchronized into each channel's sclk domain so the TX/RX FSMs
//   can gate on them. Reset to deasserted so a channel won't transmit until
//   /CTS has actually been seen after reset (matches the real chip).
//============================================================================

always @(posedge sclk_a or negedge sreset_n_a) begin
    if (!sreset_n_a) begin
        ctsa_s_sync <= 2'b11;
        dcda_s_sync <= 2'b11;
    end else begin
        ctsa_s_sync <= {ctsa_s_sync[0], ctsa_n};
        dcda_s_sync <= {dcda_s_sync[0], dcda_n};
    end
end
always @(posedge sclk_b or negedge sreset_n_b) begin
    if (!sreset_n_b) begin
        ctsb_s_sync <= 2'b11;
        dcdb_s_sync <= 2'b11;
    end else begin
        ctsb_s_sync <= {ctsb_s_sync[0], ctsb_n};
        dcdb_s_sync <= {dcdb_s_sync[0], dcdb_n};
    end
end

// Auto Enables active in sclk (uses the already-synced WR3 copy)
wire auto_en_a_s = (AUTO_ENABLES_EN != 0) && wr3_a_s[5];
wire auto_en_b_s = (AUTO_ENABLES_EN != 0) && wr3_b_s[5];

// TX may start a new char when Auto Enables is off, or /CTS is asserted (low)
wire tx_cts_ok_a_s = ~auto_en_a_s | ~ctsa_s_sync[1];
wire tx_cts_ok_b_s = ~auto_en_b_s | ~ctsb_s_sync[1];

// RX may begin a frame when Auto Enables is off, or /DCD is asserted (low)
wire rx_dcd_ok_a_s = ~auto_en_a_s | ~dcda_s_sync[1];
wire rx_dcd_ok_b_s = ~auto_en_b_s | ~dcdb_s_sync[1];

//============================================================================
// Character-length helpers
//============================================================================

function [3:0] get_tx_bits;
    input [7:0] wr5;
    begin
        case (wr5[6:5])
            2'b00: get_tx_bits = 4'd5;
            2'b01: get_tx_bits = 4'd7;
            2'b10: get_tx_bits = 4'd6;
            2'b11: get_tx_bits = 4'd8;
        endcase
    end
endfunction

function [3:0] get_rx_bits;
    input [7:0] wr3;
    begin
        case (wr3[7:6])
            2'b00: get_rx_bits = 4'd5;
            2'b01: get_rx_bits = 4'd7;
            2'b10: get_rx_bits = 4'd6;
            2'b11: get_rx_bits = 4'd8;
        endcase
    end
endfunction

// WR4[7:6] clock mode -> (samples per bit) - 1.
//   00 = x1 -> 0, 01 = x16 -> 15, 10 = x32 -> 31, 11 = x64 -> 63
// Also used as the full-bit RX sample index (= N-1).
function [5:0] get_clk_mult;
    input [1:0] mode;
    begin
        case (mode)
            2'b00: get_clk_mult = 6'd0;
            2'b01: get_clk_mult = 6'd15;
            2'b10: get_clk_mult = 6'd31;
            2'b11: get_clk_mult = 6'd63;
        endcase
    end
endfunction

// WR4[7:6] clock mode -> mid-bit RX sample index (= N/2 - 1).
//   x1 -> 0 (degenerate, sampled every tick), x16 -> 7, x32 -> 15, x64 -> 31
function [5:0] get_start_sample;
    input [1:0] mode;
    begin
        case (mode)
            2'b00: get_start_sample = 6'd0;
            2'b01: get_start_sample = 6'd7;
            2'b10: get_start_sample = 6'd15;
            2'b11: get_start_sample = 6'd31;
        endcase
    end
endfunction

//============================================================================
// Async FIFO interface signals
//============================================================================

// TX FIFOs: CPU writes from clk, TX FSM reads on sclk.
// Data-port writes (d_c=1) always push. Control-port writes with the pointer
// at 8 also push when WR8_CTRL_PUSH=1, which is the mirror image of the RR8
// control-port pop below and is how the IP24 PROM prints - see the parameter.
wire        tx_fifo_wen_a   = write_en && a_b &&
                              (d_c || (WR8_CTRL_PUSH != 0 && !d_c && reg_ptr_a == 4'd8));
wire        tx_fifo_wen_b   = write_en && !a_b &&
                              (d_c || (WR8_CTRL_PUSH != 0 && !d_c && reg_ptr_b == 4'd8));
wire        tx_fifo_wfull_a, tx_fifo_wfull_b;
wire        tx_fifo_wempty_a, tx_fifo_wempty_b; // writer-side view of empty
wire [7:0]  tx_fifo_rdata_a, tx_fifo_rdata_b;
wire        tx_fifo_rempty_a, tx_fifo_rempty_b; // sclk-side empty for FSM
reg         tx_fifo_ren_a_s, tx_fifo_ren_b_s;   // sclk-side read enable (one-cycle pulse)

// RX FIFOs: RX FSM writes on sclk, CPU reads from clk
reg  [7:0]  rx_fifo_wdata_a_s, rx_fifo_wdata_b_s;
reg         rx_fifo_wen_a_s, rx_fifo_wen_b_s;
wire        rx_fifo_wfull_a, rx_fifo_wfull_b;   // sclk-side full for FSM
wire        rx_fifo_rempty_a, rx_fifo_rempty_b; // clk-side empty for CPU
wire [7:0]  rx_fifo_rdata_a, rx_fifo_rdata_b;
// RX FIFO pop on CPU read of the RX byte. Data-port reads (d_c=1) always pop.
// Control-port reads of RR8 (d_c=0 && reg_ptr=8) also pop when RR8_CTRL_POP=1
// (datasheet-accurate). Disable that path via RR8_CTRL_POP=0 if a quirky
// driver does back-to-back control-port RR8 reads expecting the same byte.
wire        rx_fifo_ren_a   = (!read_en && read_en_s0) && a_b &&
                              (d_c || (RR8_CTRL_POP != 0 && !d_c && reg_ptr_a == 4'd8)) &&
                              !rx_fifo_rempty_a;
wire        rx_fifo_ren_b   = (!read_en && read_en_s0) && !a_b &&
                              (d_c || (RR8_CTRL_POP != 0 && !d_c && reg_ptr_b == 4'd8)) &&
                              !rx_fifo_rempty_b;

//============================================================================
// TX state machine - Channel A (sclk)
//============================================================================

wire        tx_enable_a_s    = wr5_a_s[3];
wire [3:0]  tx_char_bits_a_s = get_tx_bits(wr5_a_s);
wire        parity_enable_a_s = wr4_a_s[0];
// WR4[3:2] decode:
//   00 = Sync modes enable  -> treated as 1 stop bit (async only)
//   01 = 1 stop bit
//   10 = 1.5 stop bits      -> treated as 1 stop bit for now (TODO)
//   11 = 2 stop bits
wire        two_stop_bits_a_s = (wr4_a_s[3:2] == 2'b11);
wire        x1_mode_a_s      = (wr4_a_s[7:6] == 2'b00);
wire [5:0]  clk_mult_a_s     = get_clk_mult(wr4_a_s[7:6]);

always @(posedge sclk_a or negedge sreset_n_a) begin
    if (!sreset_n_a) begin
        tx_state_a            <= TX_IDLE;
        tx_shift_a            <= 8'hFF;
        tx_bit_cnt_a          <= 4'd0;
        tx_sample_cnt_a       <= 6'd0;
        tx_out_a              <= 1'b1;
        tx_active_a           <= 1'b0;
        tx_underrun_a         <= 1'b0;
        tx_byte_grab_toggle_a <= 1'b0;
        tx_fifo_ren_a_s       <= 1'b0;
    end else if (rst_a_sclk) begin   // synchronous soft reset (Channel Reset A / force)
        tx_state_a            <= TX_IDLE;
        tx_shift_a            <= 8'hFF;
        tx_bit_cnt_a          <= 4'd0;
        tx_sample_cnt_a       <= 6'd0;
        tx_out_a              <= 1'b1;
        tx_active_a           <= 1'b0;
        tx_underrun_a         <= 1'b0;
        tx_byte_grab_toggle_a <= 1'b0;
        tx_fifo_ren_a_s       <= 1'b0;
    end else begin
        tx_fifo_ren_a_s <= 1'b0;  // default: not reading FIFO this cycle
        if (tx_clk_a_s && tx_enable_a_s) begin
            case (tx_state_a)
                TX_IDLE: begin
                    tx_out_a        <= 1'b1;
                    tx_active_a     <= 1'b0;
                    tx_sample_cnt_a <= 6'd0;
                    if (!tx_fifo_rempty_a && tx_cts_ok_a_s) begin
                        tx_shift_a            <= tx_fifo_rdata_a;
                        tx_fifo_ren_a_s       <= 1'b1;    // pop the FIFO
                        tx_byte_grab_toggle_a <= ~tx_byte_grab_toggle_a; // notify clk
                        tx_state_a            <= TX_START;
                        tx_active_a           <= 1'b1;
                    end
                end

                TX_START: begin
                    tx_out_a        <= 1'b0;
                    tx_sample_cnt_a <= tx_sample_cnt_a + 1'b1;
                    if (tx_sample_cnt_a == clk_mult_a_s) begin
                        tx_bit_cnt_a    <= 4'd0;
                        tx_sample_cnt_a <= 6'd0;
                        tx_state_a      <= TX_DATA;
                    end
                end

                TX_DATA: begin
                    tx_out_a        <= tx_shift_a[0];
                    tx_sample_cnt_a <= tx_sample_cnt_a + 1'b1;
                    if (tx_sample_cnt_a == clk_mult_a_s) begin
                        tx_shift_a      <= {1'b0, tx_shift_a[7:1]};
                        tx_bit_cnt_a    <= tx_bit_cnt_a + 1'b1;
                        tx_sample_cnt_a <= 6'd0;
                        if (tx_bit_cnt_a == tx_char_bits_a_s - 1)
                            tx_state_a <= parity_enable_a_s ? TX_PARITY : TX_STOP1;
                    end
                end

                TX_PARITY: begin
                    // WR4[1]: 1 = Even parity, 0 = Odd parity (per Z8530 datasheet)
                    tx_out_a        <= ^tx_shift_a ^ ~wr4_a_s[1];
                    tx_sample_cnt_a <= tx_sample_cnt_a + 1'b1;
                    if (tx_sample_cnt_a == clk_mult_a_s) begin
                        tx_sample_cnt_a <= 6'd0;
                        tx_state_a      <= TX_STOP1;
                    end
                end

                TX_STOP1: begin
                    tx_out_a        <= 1'b1;
                    tx_sample_cnt_a <= tx_sample_cnt_a + 1'b1;
                    if (tx_sample_cnt_a == clk_mult_a_s) begin
                        tx_sample_cnt_a <= 6'd0;
                        tx_state_a      <= two_stop_bits_a_s ? TX_STOP2 : TX_IDLE;
                    end
                end

                TX_STOP2: begin
                    tx_out_a        <= 1'b1;
                    tx_sample_cnt_a <= tx_sample_cnt_a + 1'b1;
                    if (tx_sample_cnt_a == clk_mult_a_s) begin
                        tx_sample_cnt_a <= 6'd0;
                        tx_state_a      <= TX_IDLE;
                    end
                end

                default: tx_state_a <= TX_IDLE;
            endcase
        end
    end
end

//============================================================================
// TX state machine - Channel B (sclk)
//============================================================================

wire        tx_enable_b_s    = wr5_b_s[3];
wire [3:0]  tx_char_bits_b_s = get_tx_bits(wr5_b_s);
wire        parity_enable_b_s = wr4_b_s[0];
// WR4[3:2] decode: see Channel A comment above.
wire        two_stop_bits_b_s = (wr4_b_s[3:2] == 2'b11);
wire        x1_mode_b_s      = (wr4_b_s[7:6] == 2'b00);
wire [5:0]  clk_mult_b_s     = get_clk_mult(wr4_b_s[7:6]);

always @(posedge sclk_b or negedge sreset_n_b) begin
    if (!sreset_n_b) begin
        tx_state_b            <= TX_IDLE;
        tx_shift_b            <= 8'hFF;
        tx_bit_cnt_b          <= 4'd0;
        tx_sample_cnt_b       <= 6'd0;
        tx_out_b              <= 1'b1;
        tx_active_b           <= 1'b0;
        tx_underrun_b         <= 1'b0;
        tx_byte_grab_toggle_b <= 1'b0;
        tx_fifo_ren_b_s       <= 1'b0;
    end else if (rst_b_sclk) begin   // synchronous soft reset (Channel Reset B / force)
        tx_state_b            <= TX_IDLE;
        tx_shift_b            <= 8'hFF;
        tx_bit_cnt_b          <= 4'd0;
        tx_sample_cnt_b       <= 6'd0;
        tx_out_b              <= 1'b1;
        tx_active_b           <= 1'b0;
        tx_underrun_b         <= 1'b0;
        tx_byte_grab_toggle_b <= 1'b0;
        tx_fifo_ren_b_s       <= 1'b0;
    end else begin
        tx_fifo_ren_b_s <= 1'b0;
        if (tx_clk_b_s && tx_enable_b_s) begin
            case (tx_state_b)
                TX_IDLE: begin
                    tx_out_b        <= 1'b1;
                    tx_active_b     <= 1'b0;
                    tx_sample_cnt_b <= 6'd0;
                    if (!tx_fifo_rempty_b && tx_cts_ok_b_s) begin
                        tx_shift_b            <= tx_fifo_rdata_b;
                        tx_fifo_ren_b_s       <= 1'b1;
                        tx_byte_grab_toggle_b <= ~tx_byte_grab_toggle_b;
                        tx_state_b            <= TX_START;
                        tx_active_b           <= 1'b1;
                    end
                end

                TX_START: begin
                    tx_out_b        <= 1'b0;
                    tx_sample_cnt_b <= tx_sample_cnt_b + 1'b1;
                    if (tx_sample_cnt_b == clk_mult_b_s) begin
                        tx_bit_cnt_b    <= 4'd0;
                        tx_sample_cnt_b <= 6'd0;
                        tx_state_b      <= TX_DATA;
                    end
                end

                TX_DATA: begin
                    tx_out_b        <= tx_shift_b[0];
                    tx_sample_cnt_b <= tx_sample_cnt_b + 1'b1;
                    if (tx_sample_cnt_b == clk_mult_b_s) begin
                        tx_shift_b      <= {1'b0, tx_shift_b[7:1]};
                        tx_bit_cnt_b    <= tx_bit_cnt_b + 1'b1;
                        tx_sample_cnt_b <= 6'd0;
                        if (tx_bit_cnt_b == tx_char_bits_b_s - 1)
                            tx_state_b <= parity_enable_b_s ? TX_PARITY : TX_STOP1;
                    end
                end

                TX_PARITY: begin
                    // WR4[1]: 1 = Even parity, 0 = Odd parity (per Z8530 datasheet)
                    tx_out_b        <= ^tx_shift_b ^ ~wr4_b_s[1];
                    tx_sample_cnt_b <= tx_sample_cnt_b + 1'b1;
                    if (tx_sample_cnt_b == clk_mult_b_s) begin
                        tx_sample_cnt_b <= 6'd0;
                        tx_state_b      <= TX_STOP1;
                    end
                end

                TX_STOP1: begin
                    tx_out_b        <= 1'b1;
                    tx_sample_cnt_b <= tx_sample_cnt_b + 1'b1;
                    if (tx_sample_cnt_b == clk_mult_b_s) begin
                        tx_sample_cnt_b <= 6'd0;
                        tx_state_b      <= two_stop_bits_b_s ? TX_STOP2 : TX_IDLE;
                    end
                end

                TX_STOP2: begin
                    tx_out_b        <= 1'b1;
                    tx_sample_cnt_b <= tx_sample_cnt_b + 1'b1;
                    if (tx_sample_cnt_b == clk_mult_b_s) begin
                        tx_sample_cnt_b <= 6'd0;
                        tx_state_b      <= TX_IDLE;
                    end
                end

                default: tx_state_b <= TX_IDLE;
            endcase
        end
    end
end

// Transmitter fully drained, evaluated in each channel's own sclk domain where
// tx_state and the FIFO-empty flag are coherent. Used for the deferred /RTS
// deassert so it never sees the brief clk-domain race between "FIFO empty" and
// "tx_active propagated" that tx_all_sent can momentarily show at byte-grab.
wire tx_drained_a_s = (tx_state_a == TX_IDLE) && tx_fifo_rempty_a;
wire tx_drained_b_s = (tx_state_b == TX_IDLE) && tx_fifo_rempty_b;

//============================================================================
// Error-reset toggle CDC (clk -> sclk)
//============================================================================

wire error_reset_cmd_a = write_en && a_b && !d_c && (reg_ptr_a == 4'd0) && (data_in[5:3] == 3'b110);
wire error_reset_cmd_b = write_en && !a_b && !d_c && (reg_ptr_b == 4'd0) && (data_in[5:3] == 3'b110);

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        err_rst_toggle_a <= 1'b0;
        err_rst_toggle_b <= 1'b0;
    end else begin
        if (error_reset_cmd_a) err_rst_toggle_a <= ~err_rst_toggle_a;
        if (error_reset_cmd_b) err_rst_toggle_b <= ~err_rst_toggle_b;
    end
end

always @(posedge sclk_a or negedge sreset_n_a) begin
    if (!sreset_n_a) err_rst_a_sync_s <= 3'b0;
    else             err_rst_a_sync_s <= {err_rst_a_sync_s[1:0], err_rst_toggle_a};
end

always @(posedge sclk_b or negedge sreset_n_b) begin
    if (!sreset_n_b) err_rst_b_sync_s <= 3'b0;
    else             err_rst_b_sync_s <= {err_rst_b_sync_s[1:0], err_rst_toggle_b};
end

wire err_rst_pulse_a_s = err_rst_a_sync_s[2] ^ err_rst_a_sync_s[1];
wire err_rst_pulse_b_s = err_rst_b_sync_s[2] ^ err_rst_b_sync_s[1];

// Common per-channel RX wires used by both the BREAK detector below and the
// RX state machines further down. Declared here (before BREAK detector) to
// satisfy strict declaration-before-use parse order.
wire        loopback_a_s   = wr14_a_s[4];
wire        loopback_b_s   = wr14_b_s[4];
wire        rx_enable_a_s  = wr3_a_s[0];
wire        rx_enable_b_s  = wr3_b_s[0];
wire        rx_data_a_s    = loopback_a_s ? (wr5_a_s[4] ? 1'b0 : tx_out_a)
                                          : rxda_sync_s[2];
wire        rx_data_b_s    = loopback_b_s ? (wr5_b_s[4] ? 1'b0 : tx_out_b)
                                          : rxdb_sync_s[2];

//============================================================================
// RX BREAK detector (sclk)
//   Counts consecutive cycles of rx_data_* low. When count >= BREAK_THRESHOLD
//   (one full character frame in x16 mode), set sticky break_*_s. Cleared by
//   line returning to 1 (per Z8530 datasheet: "break ends" -> bit goes 1) or
//   by the WR0 error-reset command. Loopback feeds rx_data from tx_out, so
//   software setting Send Break in loopback also triggers the receiver.
//============================================================================

always @(posedge sclk_a or negedge sreset_n_a) begin
    if (!sreset_n_a) begin
        break_a_s   <= 1'b0;
        break_cnt_a <= 8'd0;
    end else if (rst_a_sclk) begin
        break_a_s   <= 1'b0;
        break_cnt_a <= 8'd0;
    end else begin
        if (rx_enable_a_s) begin
            if (rx_data_a_s == 1'b1) begin
                // Line idle -> reset counter and clear sticky break flag.
                break_cnt_a <= 8'd0;
                break_a_s   <= 1'b0;
            end else if (rx_clk_a_s) begin
                // Line is low and a bit-sample tick fired.
                if (break_cnt_a == BREAK_THRESHOLD - 1)
                    break_a_s <= 1'b1;        // threshold reached -> sticky
                if (break_cnt_a < BREAK_THRESHOLD)
                    break_cnt_a <= break_cnt_a + 1'b1;
            end
        end else begin
            break_cnt_a <= 8'd0;
        end
        if (err_rst_pulse_a_s) break_a_s <= 1'b0;
    end
end

always @(posedge sclk_b or negedge sreset_n_b) begin
    if (!sreset_n_b) begin
        break_b_s   <= 1'b0;
        break_cnt_b <= 8'd0;
    end else if (rst_b_sclk) begin
        break_b_s   <= 1'b0;
        break_cnt_b <= 8'd0;
    end else begin
        if (rx_enable_b_s) begin
            if (rx_data_b_s == 1'b1) begin
                break_cnt_b <= 8'd0;
                break_b_s   <= 1'b0;
            end else if (rx_clk_b_s) begin
                if (break_cnt_b == BREAK_THRESHOLD - 1)
                    break_b_s <= 1'b1;
                if (break_cnt_b < BREAK_THRESHOLD)
                    break_cnt_b <= break_cnt_b + 1'b1;
            end
        end else begin
            break_cnt_b <= 8'd0;
        end
        if (err_rst_pulse_b_s) break_b_s <= 1'b0;
    end
end

//============================================================================
// RX state machine - Channel A (sclk)
//============================================================================

// rx_enable_a_s, loopback_a_s, rx_data_a_s declared earlier (before BREAK
// detector) so they're visible to that block under strict parse rules.
wire [3:0]  rx_char_bits_a_s  = get_rx_bits(wr3_a_s);
wire [5:0]  rx_start_sample_a_s = get_start_sample(wr4_a_s[7:6]);
wire [5:0]  rx_bit_sample_a_s   = get_clk_mult(wr4_a_s[7:6]);

always @(posedge sclk_a or negedge sreset_n_a) begin
    if (!sreset_n_a) begin
        rx_state_a        <= RX_IDLE;
        rx_shift_a        <= 8'd0;
        rx_bit_cnt_a      <= 4'd0;
        rx_sample_cnt_a   <= 6'd0;
        rx_active_a       <= 1'b0;
        rx_overrun_a      <= 1'b0;
        rx_framing_err_a  <= 1'b0;
        rx_parity_err_a   <= 1'b0;
        rx_fifo_wen_a_s   <= 1'b0;
        rx_fifo_wdata_a_s <= 8'h00;
    end else if (rst_a_sclk) begin   // synchronous soft reset (Channel Reset A / force)
        rx_state_a        <= RX_IDLE;
        rx_shift_a        <= 8'd0;
        rx_bit_cnt_a      <= 4'd0;
        rx_sample_cnt_a   <= 6'd0;
        rx_active_a       <= 1'b0;
        rx_overrun_a      <= 1'b0;
        rx_framing_err_a  <= 1'b0;
        rx_parity_err_a   <= 1'b0;
        rx_fifo_wen_a_s   <= 1'b0;
        rx_fifo_wdata_a_s <= 8'h00;
    end else begin
        rx_fifo_wen_a_s <= 1'b0;  // default

        if (err_rst_pulse_a_s) begin
            rx_overrun_a     <= 1'b0;
            rx_parity_err_a  <= 1'b0;
            rx_framing_err_a <= 1'b0;
        end

        if (rx_clk_a_s && rx_enable_a_s) begin
            case (rx_state_a)
                RX_IDLE: begin
                    rx_active_a     <= 1'b0;
                    rx_sample_cnt_a <= 6'd0;
                    if (rx_data_a_s == 1'b0 && rx_dcd_ok_a_s) begin
                        rx_state_a      <= RX_START;
                        rx_active_a     <= 1'b1;
                        rx_sample_cnt_a <= x1_mode_a_s ? 6'd0 : 6'd1;
                    end
                end

                RX_START: begin
                    rx_sample_cnt_a <= rx_sample_cnt_a + 1'b1;
                    if (rx_sample_cnt_a == rx_start_sample_a_s) begin
                        if (rx_data_a_s == 1'b0) begin
                            rx_bit_cnt_a    <= 4'd0;
                            rx_shift_a      <= 8'd0;
                            rx_sample_cnt_a <= 6'd0;
                            rx_state_a      <= RX_DATA;
                        end else begin
                            rx_state_a <= RX_IDLE;  // noise
                        end
                    end
                end

                RX_DATA: begin
                    rx_sample_cnt_a <= rx_sample_cnt_a + 1'b1;
                    if (rx_sample_cnt_a == rx_bit_sample_a_s) begin
                        rx_shift_a      <= {rx_data_a_s, rx_shift_a[7:1]};
                        rx_bit_cnt_a    <= rx_bit_cnt_a + 1'b1;
                        rx_sample_cnt_a <= 6'd0;
                        if (rx_bit_cnt_a == rx_char_bits_a_s - 1)
                            rx_state_a <= parity_enable_a_s ? RX_PARITY : RX_STOP;
                    end
                end

                RX_PARITY: begin
                    rx_sample_cnt_a <= rx_sample_cnt_a + 1'b1;
                    if (rx_sample_cnt_a == rx_bit_sample_a_s) begin
                        // WR4[1]: 1 = Even parity, 0 = Odd parity (per Z8530 datasheet)
                        rx_parity_err_a <= (^rx_shift_a ^ rx_data_a_s) == wr4_a_s[1];
                        rx_sample_cnt_a <= 6'd0;
                        rx_state_a      <= RX_STOP;
                    end
                end

                RX_STOP: begin
                    rx_sample_cnt_a <= rx_sample_cnt_a + 1'b1;
                    if (rx_sample_cnt_a == rx_bit_sample_a_s) begin
                        rx_framing_err_a <= (rx_data_a_s != 1'b1);
                        if (!rx_fifo_wfull_a) begin
                            rx_fifo_wdata_a_s <= rx_shift_a >> (8 - rx_char_bits_a_s);
                            rx_fifo_wen_a_s   <= 1'b1;
                        end else begin
                            rx_overrun_a <= 1'b1;
                        end
                        rx_state_a <= RX_IDLE;
                    end
                end

                default: rx_state_a <= RX_IDLE;
            endcase
        end
    end
end

//============================================================================
// RX state machine - Channel B (sclk)
//============================================================================

// rx_enable_b_s, loopback_b_s, rx_data_b_s declared earlier (see Ch A comment).
wire [3:0]  rx_char_bits_b_s  = get_rx_bits(wr3_b_s);
wire [5:0]  rx_start_sample_b_s = get_start_sample(wr4_b_s[7:6]);
wire [5:0]  rx_bit_sample_b_s   = get_clk_mult(wr4_b_s[7:6]);

always @(posedge sclk_b or negedge sreset_n_b) begin
    if (!sreset_n_b) begin
        rx_state_b        <= RX_IDLE;
        rx_shift_b        <= 8'd0;
        rx_bit_cnt_b      <= 4'd0;
        rx_sample_cnt_b   <= 6'd0;
        rx_active_b       <= 1'b0;
        rx_overrun_b      <= 1'b0;
        rx_framing_err_b  <= 1'b0;
        rx_parity_err_b   <= 1'b0;
        rx_fifo_wen_b_s   <= 1'b0;
        rx_fifo_wdata_b_s <= 8'h00;
    end else if (rst_b_sclk) begin   // synchronous soft reset (Channel Reset B / force)
        rx_state_b        <= RX_IDLE;
        rx_shift_b        <= 8'd0;
        rx_bit_cnt_b      <= 4'd0;
        rx_sample_cnt_b   <= 6'd0;
        rx_active_b       <= 1'b0;
        rx_overrun_b      <= 1'b0;
        rx_framing_err_b  <= 1'b0;
        rx_parity_err_b   <= 1'b0;
        rx_fifo_wen_b_s   <= 1'b0;
        rx_fifo_wdata_b_s <= 8'h00;
    end else begin
        rx_fifo_wen_b_s <= 1'b0;

        if (err_rst_pulse_b_s) begin
            rx_overrun_b     <= 1'b0;
            rx_parity_err_b  <= 1'b0;
            rx_framing_err_b <= 1'b0;
        end

        if (rx_clk_b_s && rx_enable_b_s) begin
            case (rx_state_b)
                RX_IDLE: begin
                    rx_active_b     <= 1'b0;
                    rx_sample_cnt_b <= 6'd0;
                    if (rx_data_b_s == 1'b0 && rx_dcd_ok_b_s) begin
                        rx_state_b      <= RX_START;
                        rx_active_b     <= 1'b1;
                        rx_sample_cnt_b <= x1_mode_b_s ? 6'd0 : 6'd1;
                    end
                end

                RX_START: begin
                    rx_sample_cnt_b <= rx_sample_cnt_b + 1'b1;
                    if (rx_sample_cnt_b == rx_start_sample_b_s) begin
                        if (rx_data_b_s == 1'b0) begin
                            rx_bit_cnt_b    <= 4'd0;
                            rx_shift_b      <= 8'd0;
                            rx_sample_cnt_b <= 6'd0;
                            rx_state_b      <= RX_DATA;
                        end else begin
                            rx_state_b <= RX_IDLE;
                        end
                    end
                end

                RX_DATA: begin
                    rx_sample_cnt_b <= rx_sample_cnt_b + 1'b1;
                    if (rx_sample_cnt_b == rx_bit_sample_b_s) begin
                        rx_shift_b      <= {rx_data_b_s, rx_shift_b[7:1]};
                        rx_bit_cnt_b    <= rx_bit_cnt_b + 1'b1;
                        rx_sample_cnt_b <= 6'd0;
                        if (rx_bit_cnt_b == rx_char_bits_b_s - 1)
                            rx_state_b <= parity_enable_b_s ? RX_PARITY : RX_STOP;
                    end
                end

                RX_PARITY: begin
                    rx_sample_cnt_b <= rx_sample_cnt_b + 1'b1;
                    if (rx_sample_cnt_b == rx_bit_sample_b_s) begin
                        // WR4[1]: 1 = Even parity, 0 = Odd parity (per Z8530 datasheet)
                        rx_parity_err_b <= (^rx_shift_b ^ rx_data_b_s) == wr4_b_s[1];
                        rx_sample_cnt_b <= 6'd0;
                        rx_state_b      <= RX_STOP;
                    end
                end

                RX_STOP: begin
                    rx_sample_cnt_b <= rx_sample_cnt_b + 1'b1;
                    if (rx_sample_cnt_b == rx_bit_sample_b_s) begin
                        rx_framing_err_b <= (rx_data_b_s != 1'b1);
                        if (!rx_fifo_wfull_b) begin
                            rx_fifo_wdata_b_s <= rx_shift_b >> (8 - rx_char_bits_b_s);
                            rx_fifo_wen_b_s   <= 1'b1;
                        end else begin
                            rx_overrun_b <= 1'b1;
                        end
                        rx_state_b <= RX_IDLE;
                    end
                end

                default: rx_state_b <= RX_IDLE;
            endcase
        end
    end
end

//============================================================================
// Async FIFO instances (4-deep, 8-bit)
//============================================================================

// FIFO reset ports are gated by the per-channel soft resets in BOTH domains so
// the Gray pointers on each side clear with overlap (clk hold is stretched to
// contain the sclk-side window).
scc_async_fifo #(.DW(8), .AW(2)) u_tx_fifo_a (
    .wclk(clk),    .wrst_n(reset_n   & ~rst_a_clk),
    .wen(tx_fifo_wen_a && !tx_fifo_wfull_a),
    .wdata(data_in), .wfull(tx_fifo_wfull_a), .wempty(tx_fifo_wempty_a),
    .rclk(sclk_a), .rrst_n(sreset_n_a & ~rst_a_sclk),
    .ren(tx_fifo_ren_a_s),
    .rdata(tx_fifo_rdata_a), .rempty(tx_fifo_rempty_a)
);

scc_async_fifo #(.DW(8), .AW(2)) u_tx_fifo_b (
    .wclk(clk),    .wrst_n(reset_n   & ~rst_b_clk),
    .wen(tx_fifo_wen_b && !tx_fifo_wfull_b),
    .wdata(data_in), .wfull(tx_fifo_wfull_b), .wempty(tx_fifo_wempty_b),
    .rclk(sclk_b), .rrst_n(sreset_n_b & ~rst_b_sclk),
    .ren(tx_fifo_ren_b_s),
    .rdata(tx_fifo_rdata_b), .rempty(tx_fifo_rempty_b)
);

scc_async_fifo #(.DW(8), .AW(2)) u_rx_fifo_a (
    .wclk(sclk_a), .wrst_n(sreset_n_a & ~rst_a_sclk),
    .wen(rx_fifo_wen_a_s && !rx_fifo_wfull_a),
    .wdata(rx_fifo_wdata_a_s), .wfull(rx_fifo_wfull_a),
    .wempty(/*unused*/),
    .rclk(clk),    .rrst_n(reset_n   & ~rst_a_clk),
    .ren(rx_fifo_ren_a),
    .rdata(rx_fifo_rdata_a), .rempty(rx_fifo_rempty_a)
);

scc_async_fifo #(.DW(8), .AW(2)) u_rx_fifo_b (
    .wclk(sclk_b), .wrst_n(sreset_n_b & ~rst_b_sclk),
    .wen(rx_fifo_wen_b_s && !rx_fifo_wfull_b),
    .wdata(rx_fifo_wdata_b_s), .wfull(rx_fifo_wfull_b),
    .wempty(/*unused*/),
    .rclk(clk),    .rrst_n(reset_n   & ~rst_b_clk),
    .ren(rx_fifo_ren_b),
    .rdata(rx_fifo_rdata_b), .rempty(rx_fifo_rempty_b)
);

//============================================================================
// sclk -> clk status synchronizers
//============================================================================

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        tx_active_a_sync       <= 2'b0;
        tx_active_b_sync       <= 2'b0;
        tx_byte_grab_a_sync    <= 3'b0;
        tx_byte_grab_b_sync    <= 3'b0;
        rx_overrun_a_sync      <= 2'b0;
        rx_overrun_b_sync      <= 2'b0;
        break_a_sync           <= 2'b0;
        break_b_sync           <= 2'b0;
        rx_framing_err_a_sync  <= 2'b0;
        rx_framing_err_b_sync  <= 2'b0;
        rx_parity_err_a_sync   <= 2'b0;
        rx_parity_err_b_sync   <= 2'b0;
        tx_underrun_a_sync     <= 2'b0;
        tx_underrun_b_sync     <= 2'b0;
        tx_drained_a_sync      <= 2'b11;
        tx_drained_b_sync      <= 2'b11;
    end else begin
        tx_active_a_sync       <= {tx_active_a_sync[0],      tx_active_a};
        tx_active_b_sync       <= {tx_active_b_sync[0],      tx_active_b};
        tx_byte_grab_a_sync    <= {tx_byte_grab_a_sync[1:0], tx_byte_grab_toggle_a};
        tx_byte_grab_b_sync    <= {tx_byte_grab_b_sync[1:0], tx_byte_grab_toggle_b};
        rx_overrun_a_sync      <= {rx_overrun_a_sync[0],     rx_overrun_a};
        rx_overrun_b_sync      <= {rx_overrun_b_sync[0],     rx_overrun_b};
        break_a_sync           <= {break_a_sync[0],          break_a_s};
        break_b_sync           <= {break_b_sync[0],          break_b_s};
        rx_framing_err_a_sync  <= {rx_framing_err_a_sync[0], rx_framing_err_a};
        rx_framing_err_b_sync  <= {rx_framing_err_b_sync[0], rx_framing_err_b};
        rx_parity_err_a_sync   <= {rx_parity_err_a_sync[0],  rx_parity_err_a};
        rx_parity_err_b_sync   <= {rx_parity_err_b_sync[0],  rx_parity_err_b};
        tx_underrun_a_sync     <= {tx_underrun_a_sync[0],    tx_underrun_a};
        tx_underrun_b_sync     <= {tx_underrun_b_sync[0],    tx_underrun_b};
        tx_drained_a_sync      <= {tx_drained_a_sync[0],     tx_drained_a_s};
        tx_drained_b_sync      <= {tx_drained_b_sync[0],     tx_drained_b_s};
    end
end

wire tx_active_a_c      = tx_active_a_sync[1];
wire tx_active_b_c      = tx_active_b_sync[1];
wire rx_overrun_a_c     = rx_overrun_a_sync[1];
wire rx_overrun_b_c     = rx_overrun_b_sync[1];
wire break_a_c          = break_a_sync[1];
wire break_b_c          = break_b_sync[1];
wire rx_framing_err_a_c = rx_framing_err_a_sync[1];
wire rx_framing_err_b_c = rx_framing_err_b_sync[1];
wire rx_parity_err_a_c  = rx_parity_err_a_sync[1];
wire rx_parity_err_b_c  = rx_parity_err_b_sync[1];
wire tx_underrun_a_c    = tx_underrun_a_sync[1];
wire tx_underrun_b_c    = tx_underrun_b_sync[1];
wire tx_drained_a_c     = tx_drained_a_sync[1];
wire tx_drained_b_c     = tx_drained_b_sync[1];

// TX-int trigger: rising/falling edge of the toggle indicates the FSM
// just grabbed a byte from the FIFO.
wire tx_byte_grab_pulse_a = tx_byte_grab_a_sync[2] ^ tx_byte_grab_a_sync[1];
wire tx_byte_grab_pulse_b = tx_byte_grab_b_sync[2] ^ tx_byte_grab_b_sync[1];

// clk-side view of FIFO emptiness
wire rx_avail_clk_a  = ~rx_fifo_rempty_a;
wire rx_avail_clk_b  = ~rx_fifo_rempty_b;
// "TX Buffer Empty" in real Z8530 means CPU has room to write -> not full
wire tx_room_clk_a   = ~tx_fifo_wfull_a;
wire tx_room_clk_b   = ~tx_fifo_wfull_b;
// True "all bytes drained" for RR1[0] "All Sent"
wire tx_all_sent_a   = tx_fifo_wempty_a & ~tx_active_a_c;
wire tx_all_sent_b   = tx_fifo_wempty_b & ~tx_active_b_c;

//============================================================================
// Auto-Enable deferred /RTS deassert (clk):
//   - assert (rts_hold=1) immediately when WR5[1] set
//   - WR5[1] cleared, Auto Enables off  -> release immediately (follow bit)
//   - WR5[1] cleared, Auto Enables on   -> hold until transmitter empty
//============================================================================
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        rts_hold_a <= 1'b0;
        rts_hold_b <= 1'b0;
    end else begin
        // Channel A
        if (rst_a_clk)                                   rts_hold_a <= 1'b0;
        else if (wr5_a[1])                               rts_hold_a <= 1'b1;
        else if (!((AUTO_ENABLES_EN != 0) && wr3_a[5]))  rts_hold_a <= 1'b0;
        else if (tx_drained_a_c)                         rts_hold_a <= 1'b0;
        // Channel B
        if (rst_b_clk)                                   rts_hold_b <= 1'b0;
        else if (wr5_b[1])                               rts_hold_b <= 1'b1;
        else if (!((AUTO_ENABLES_EN != 0) && wr3_b[5]))  rts_hold_b <= 1'b0;
        else if (tx_drained_b_c)                         rts_hold_b <= 1'b0;
    end
end

//============================================================================
// Read Registers (RR0/RR1/RR2/RR3/RR8/RR10/RR12/RR13/RR15)
//============================================================================

// RR0 - Transmit/Receive Buffer Status
assign rr0_a = {
    break_a_c,             // Break/Abort
    tx_underrun_a_c,       // TX Underrun/EOM
    ~ctsa_sync[2],         // CTS
    ~synca_sync[2],        // Sync/Hunt (async: follows /SYNCA pin)
    ~dcda_sync[2],         // DCD
    tx_room_clk_a,         // TX Buffer Empty (= room available)
    1'b0,                  // Zero Count
    rx_avail_clk_a         // RX Character Available
};

assign rr0_b = {
    break_b_c,
    tx_underrun_b_c,
    ~ctsb_sync[2],
    ~syncb_sync[2],        // Sync/Hunt (async: follows /SYNCB pin)
    ~dcdb_sync[2],
    tx_room_clk_b,
    1'b0,
    rx_avail_clk_b
};

// RR1 - Special Receive Condition Status
assign rr1_a = {
    1'b0,                  // End of Frame (SDLC)
    1'b0,                  // CRC/Framing Error
    rx_overrun_a_c,
    rx_parity_err_a_c,
    3'b000,                // Residue Code
    tx_all_sent_a          // All Sent
};

assign rr1_b = {
    1'b0,
    1'b0,
    rx_overrun_b_c,
    rx_parity_err_b_c,
    3'b000,
    tx_all_sent_b
};

// RR2 - Interrupt Vector
// Per Z8530 datasheet: "If the vector is read in Channel A, status is never
// included. If the vector is read in Channel B, status is always included."
// So RR2_b is ALWAYS status-modified; VIS (WR9[0]) gates only the INTACK-
// cycle vector, which this model doesn't implement.
wire status_high = wr9_a[4];

// IE wires (declared here so the vector arbitration below can use the
// gated *_int_active_* views; the full interrupt logic block follows).
wire rx_int_enable_a = (wr1_a[4:3] == 2'b01) || (wr1_a[4:3] == 2'b10);
wire rx_int_enable_b = (wr1_b[4:3] == 2'b01) || (wr1_b[4:3] == 2'b10);

// Gated IP -> IE views. RR3 still shows raw IPs per datasheet; only the
// /INT output and the vector arbiter are masked by WR1[4:3]/WR1[1]/WR1[0].
wire rx_int_active_a  = rx_int_pend_a  & rx_int_enable_a;
wire tx_int_active_a  = tx_int_pend_a  & wr1_a[1];
wire ext_int_active_a = ext_int_pend_a & wr1_a[0];
wire rx_int_active_b  = rx_int_pend_b  & rx_int_enable_b;
wire tx_int_active_b  = tx_int_pend_b  & wr1_b[1];
wire ext_int_active_b = ext_int_pend_b & wr1_b[0];

// Vector arbitration uses the gated (active) interrupt views so a disabled
// source never appears as the highest-priority pending interrupt.
wire [2:0] int_status = rx_int_active_a  ? 3'b110 :
                        tx_int_active_a  ? 3'b100 :
                        ext_int_active_a ? 3'b101 :
                        rx_int_active_b  ? 3'b010 :
                        tx_int_active_b  ? 3'b000 :
                        ext_int_active_b ? 3'b001 : 3'b011;

assign rr2_a = wr2_a;
// Status High/Low (WR9[4]) selects which 3 vector bits carry int_status.
//   0 = status low  -> bits [3:1] (bit-natural order)
//   1 = status high -> bits [6:4] (bit-reversed, per Z8530 datasheet)
assign rr2_b = status_high
               ? {wr2_a[7], int_status[0], int_status[1], int_status[2], wr2_a[3:0]}
               : {wr2_a[7:4], int_status, wr2_a[0]};

// RR3 - Interrupt Pending (Channel A only)
assign rr3_a = {
    2'b00,
    rx_int_pend_a,
    tx_int_pend_a,
    ext_int_pend_a,
    rx_int_pend_b,
    tx_int_pend_b,
    ext_int_pend_b
};

// RR8 - Receive Buffer (from async FIFO read port)
assign rr8_a = rx_fifo_rdata_a;
assign rr8_b = rx_fifo_rdata_b;

// RR10 - Miscellaneous Status (bit 1 = Loop Sending)
assign rr10_a = {6'b0, wr14_a[4] & tx_active_a_c, 1'b0};
assign rr10_b = {6'b0, wr14_b[4] & tx_active_b_c, 1'b0};

// RR12/RR13 - BRG Time Constant (readable)
assign rr12_a = wr12_a;
assign rr12_b = wr12_b;
assign rr13_a = wr13_a;
assign rr13_b = wr13_b;

// RR15 - External/Status Interrupt Control
assign rr15_a = wr15_a;
assign rr15_b = wr15_b;

//============================================================================
// Interrupt Logic (clk)
//============================================================================

wire master_int_enable = wr9_a[3];

wire reset_ext_int_cmd_a = write_en && a_b && !d_c && (reg_ptr_a == 4'd0) && (data_in[5:3] == 3'b010);
wire reset_ext_int_cmd_b = write_en && !a_b && !d_c && (reg_ptr_b == 4'd0) && (data_in[5:3] == 3'b010);
wire reset_tx_int_cmd_a  = write_en && a_b && !d_c && (reg_ptr_a == 4'd0) && (data_in[5:3] == 3'b101);
wire reset_tx_int_cmd_b  = write_en && !a_b && !d_c && (reg_ptr_b == 4'd0) && (data_in[5:3] == 3'b101);

// (rx_int_enable_*, *_int_active_* declared earlier near int_status to
//  satisfy strict-default-nettype-none parse order; see comment above.)

// Modem edge detect (CTS/DCD)
reg cts_a_d, cts_b_d, dcd_a_d, dcd_b_d;
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        cts_a_d <= 1'b1; cts_b_d <= 1'b1;
        dcd_a_d <= 1'b1; dcd_b_d <= 1'b1;
    end else begin
        cts_a_d <= ctsa_sync[2]; cts_b_d <= ctsb_sync[2];
        dcd_a_d <= dcda_sync[2]; dcd_b_d <= dcdb_sync[2];
    end
end

wire cts_change_a = (ctsa_sync[2] != cts_a_d);
wire cts_change_b = (ctsb_sync[2] != cts_b_d);
wire dcd_change_a = (dcda_sync[2] != dcd_a_d);
wire dcd_change_b = (dcdb_sync[2] != dcd_b_d);

// BREAK is an Ext/Status interrupt source: fires on each break edge (both
// onset and end), gated by WR15[7].
reg  break_a_d, break_b_d;
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        break_a_d <= 1'b0;
        break_b_d <= 1'b0;
    end else begin
        break_a_d <= break_a_c;
        break_b_d <= break_b_c;
    end
end
wire break_change_a = (break_a_c != break_a_d);
wire break_change_b = (break_b_c != break_b_d);

wire ext_int_set_a = (wr15_a[5] & cts_change_a) | (wr15_a[3] & dcd_change_a)
                   | (wr15_a[7] & break_change_a);
wire ext_int_set_b = (wr15_b[5] & cts_change_b) | (wr15_b[3] & dcd_change_b)
                   | (wr15_b[7] & break_change_b);

// rx_fifo_rempty falling-edge detect = "a new byte just became visible"
reg rx_fifo_rempty_a_d, rx_fifo_rempty_b_d;
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        rx_fifo_rempty_a_d <= 1'b1;
        rx_fifo_rempty_b_d <= 1'b1;
    end else begin
        rx_fifo_rempty_a_d <= rx_fifo_rempty_a;
        rx_fifo_rempty_b_d <= rx_fifo_rempty_b;
    end
end
wire rx_fifo_arrive_a = rx_fifo_rempty_a_d & ~rx_fifo_rempty_a;
wire rx_fifo_arrive_b = rx_fifo_rempty_b_d & ~rx_fifo_rempty_b;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        rx_int_pend_a <= 1'b0;
        tx_int_pend_a <= 1'b0;
        ext_int_pend_a <= 1'b0;
        rx_int_pend_b <= 1'b0;
        tx_int_pend_b <= 1'b0;
        ext_int_pend_b <= 1'b0;
    end else begin
        // RX int (IP): latched on FIFO empty->non-empty regardless of WR1[4:3];
        // auto-cleared when the FIFO is fully drained.
        // The enable (WR1[4:3]) gates only the /INT output and vector arbiter.
        if (rx_fifo_arrive_a)
            rx_int_pend_a <= 1'b1;
        else if (rx_fifo_rempty_a)
            rx_int_pend_a <= 1'b0;

        if (rx_fifo_arrive_b)
            rx_int_pend_b <= 1'b1;
        else if (rx_fifo_rempty_b)
            rx_int_pend_b <= 1'b0;

        // TX int (IP): latched on TX FSM byte-grab regardless of WR1[1];
        // cleared only by WR0 cmd 101 (Reset TX Int Pending).
        if (reset_tx_int_cmd_a)
            tx_int_pend_a <= 1'b0;
        else if (tx_byte_grab_pulse_a)
            tx_int_pend_a <= 1'b1;

        if (reset_tx_int_cmd_b)
            tx_int_pend_b <= 1'b0;
        else if (tx_byte_grab_pulse_b)
            tx_int_pend_b <= 1'b1;

        // Ext/Status int (IP): latched on any WR15-enabled CTS/DCD edge
        // regardless of WR1[0]; cleared only by WR0 cmd 010.
        if (reset_ext_int_cmd_a)
            ext_int_pend_a <= 1'b0;
        else if (ext_int_set_a)
            ext_int_pend_a <= 1'b1;

        if (reset_ext_int_cmd_b)
            ext_int_pend_b <= 1'b0;
        else if (ext_int_set_b)
            ext_int_pend_b <= 1'b1;

        // Soft-reset overrides (last assignment wins -> reset has priority).
        if (rst_a_clk) begin
            rx_int_pend_a  <= 1'b0;
            tx_int_pend_a  <= 1'b0;
            ext_int_pend_a <= 1'b0;
        end
        if (rst_b_clk) begin
            rx_int_pend_b  <= 1'b0;
            tx_int_pend_b  <= 1'b0;
            ext_int_pend_b <= 1'b0;
        end
    end
end

assign int_n = ~(master_int_enable &
                (rx_int_active_a | tx_int_active_a | ext_int_active_a |
                 rx_int_active_b | tx_int_active_b | ext_int_active_b));

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) read_en_s0 <= 1'b0;
    else          read_en_s0 <= read_en;
end

always_ff @(posedge clk or negedge reset_n) begin
    if (~reset_n) wr_cmd_s0 <= 1'b1;
    else          wr_cmd_s0 <= wr_cmd_n;
end

assign wr_cmd_n = wr_n | cs_n;
assign wr_cmd_n_p = ~(~wr_cmd_n & wr_cmd_s0);

//============================================================================
// Register Write Logic
//   TX FIFO writes are handled by the async FIFO module via tx_fifo_wen_a/b;
//   no need to touch FIFO memory here.
//============================================================================

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        reg_ptr_a <= 4'd0;
        reg_ptr_b <= 4'd0;

        wr0_a <= 8'd0; wr1_a <= 8'd0; wr2_a <= 8'd0; wr3_a <= 8'd0;
        wr4_a <= 8'd0; wr5_a <= 8'd0; wr6_a <= 8'd0; wr7_a <= 8'd0;
        wr9_a <= 8'd0; wr10_a <= 8'd0; wr11_a <= 8'd0;
        wr12_a <= 8'd0; wr13_a <= 8'd0; wr14_a <= 8'd0; wr15_a <= 8'd0;

        wr0_b <= 8'd0; wr1_b <= 8'd0; wr3_b <= 8'd0;
        wr4_b <= 8'd0; wr5_b <= 8'd0; wr6_b <= 8'd0; wr7_b <= 8'd0;
        wr10_b <= 8'd0; wr11_b <= 8'd0;
        wr12_b <= 8'd0; wr13_b <= 8'd0; wr14_b <= 8'd0; wr15_b <= 8'd0;
    end else begin
      if (!read_en && read_en_s0) begin
        // Auto-reset register pointer to 0 after any control register read
        if (!d_c) begin
            if (a_b) reg_ptr_a <= 4'd0;
            else     reg_ptr_b <= 4'd0;
        end
      end else if (write_en) begin
        if (a_b) begin  // Channel A
            if (d_c) begin
                // Data register write -> handled by async FIFO; no-op here
            end else begin  // Control register
                case (reg_ptr_a)
                    4'd0: begin
                        wr0_a <= data_in;
                        // Point High (bit_ptr[3] = 1) activates ONLY when the
                        // full command field [5:3] == 001. Other command codes
                        // (010 reset ext/stat, 011 send abort, 101 reset TX
                        // int, 110 error reset, 111 reset highest IUS) MUST
                        // leave the high pointer bit at 0 and select reg
                        // 0..7 via bits [2:0]. The previous code looked at
                        // bit 3 alone, which is set in command codes 001,
                        // 011, 101 and 111 -- so e.g. WR0=0x38 (Reset IUS)
                        // wrongly re-pointed to reg 8.
                        reg_ptr_a <= {(data_in[5:3] == 3'b001), data_in[2:0]};
                    end
                    4'd1: begin wr1_a <= data_in; reg_ptr_a <= 4'd0; end
                    4'd2: begin wr2_a <= data_in; reg_ptr_a <= 4'd0; end
                    4'd3: begin wr3_a <= data_in; reg_ptr_a <= 4'd0; end
                    4'd4: begin wr4_a <= data_in; reg_ptr_a <= 4'd0; end
                    4'd5: begin wr5_a <= data_in; reg_ptr_a <= 4'd0; end
                    4'd6: begin wr6_a <= data_in; reg_ptr_a <= 4'd0; end
                    4'd7: begin wr7_a <= data_in; reg_ptr_a <= 4'd0; end
                    4'd9: begin wr9_a <= data_in; reg_ptr_a <= 4'd0; end
                    4'd10: begin wr10_a <= data_in; reg_ptr_a <= 4'd0; end
                    4'd11: begin wr11_a <= data_in; reg_ptr_a <= 4'd0; end
                    4'd12: begin wr12_a <= data_in; reg_ptr_a <= 4'd0; end
                    4'd13: begin wr13_a <= data_in; reg_ptr_a <= 4'd0; end
                    4'd14: begin wr14_a <= data_in; reg_ptr_a <= 4'd0; end
                    // WR8 is the transmit buffer: the byte goes to the FIFO
                    // through tx_fifo_wen_a, and all that happens here is the
                    // pointer reset every register access performs.
                    4'd8:  reg_ptr_a <= 4'd0;
                    4'd15: begin wr15_a <= data_in; reg_ptr_a <= 4'd0; end
                    default: reg_ptr_a <= 4'd0;
                endcase
            end
        end else begin  // Channel B
            if (d_c) begin
                // Data register write -> handled by async FIFO; no-op here
            end else begin
                case (reg_ptr_b)
                    4'd0: begin
                        wr0_b <= data_in;
                        // See Ch A WR0 case above: Point High requires the
                        // full command code [5:3] == 001.
                        reg_ptr_b <= {(data_in[5:3] == 3'b001), data_in[2:0]};
                    end
                    4'd1: begin wr1_b <= data_in; reg_ptr_b <= 4'd0; end
                    // WR2 and WR9 are chip-wide shared registers on the real
                    // Z8530: writable through either channel. Stored as the
                    // _a copies; channel-B writes land in the same regs.
                    //@4'd2: begin wr2_a <= data_in; reg_ptr_b <= 4'd0; end
                    4'd3: begin wr3_b <= data_in; reg_ptr_b <= 4'd0; end
                    4'd4: begin wr4_b <= data_in; reg_ptr_b <= 4'd0; end
                    4'd5: begin wr5_b <= data_in; reg_ptr_b <= 4'd0; end
                    4'd6: begin wr6_b <= data_in; reg_ptr_b <= 4'd0; end
                    4'd7: begin wr7_b <= data_in; reg_ptr_b <= 4'd0; end
                    //@4'd9: begin wr9_a <= data_in; reg_ptr_b <= 4'd0; end   // shared master-int-ctrl
                    4'd10: begin wr10_b <= data_in; reg_ptr_b <= 4'd0; end
                    4'd11: begin wr11_b <= data_in; reg_ptr_b <= 4'd0; end
                    4'd12: begin wr12_b <= data_in; reg_ptr_b <= 4'd0; end
                    4'd13: begin wr13_b <= data_in; reg_ptr_b <= 4'd0; end
                    4'd14: begin wr14_b <= data_in; reg_ptr_b <= 4'd0; end
                    4'd8:  reg_ptr_b <= 4'd0;      // transmit buffer - see Ch A
                    4'd15: begin wr15_b <= data_in; reg_ptr_b <= 4'd0; end
                    default: reg_ptr_b <= 4'd0;
                endcase
            end
        end
      end

        // Soft-reset overrides (last assignment wins -> reset has priority).
        // Channel reset clears that channel's registers + pointer; force
        // hardware reset additionally clears the shared WR2/WR9 (and asserts
        // both channel resets via the counters above).
        if (rst_a_clk) begin
            wr0_a <= 8'd0; wr1_a <= 8'd0; wr3_a <= 8'd0; wr4_a <= 8'd0;
            wr5_a <= 8'd0; wr6_a <= 8'd0; wr7_a <= 8'd0; wr10_a <= 8'd0;
            wr11_a <= 8'd0; wr12_a <= 8'd0; wr13_a <= 8'd0; wr14_a <= 8'd0;
            wr15_a <= 8'd0; reg_ptr_a <= 4'd0;
        end
        if (rst_b_clk) begin
            wr0_b <= 8'd0; wr1_b <= 8'd0; wr3_b <= 8'd0; wr4_b <= 8'd0;
            wr5_b <= 8'd0; wr6_b <= 8'd0; wr7_b <= 8'd0; wr10_b <= 8'd0;
            wr11_b <= 8'd0; wr12_b <= 8'd0; wr13_b <= 8'd0; wr14_b <= 8'd0;
            wr15_b <= 8'd0; reg_ptr_b <= 4'd0;
        end
        if (force_clk) begin
            wr2_a <= 8'd0;
            wr9_a <= 8'd0;
        end
    end
end

//============================================================================
// Register Read Logic
//============================================================================

always @(*) begin
    data_out = 8'h00;

    if (read_en) begin
        if (a_b) begin  // Channel A
            if (d_c) begin
                data_out = rr8_a;
            end else begin
                case (reg_ptr_a)
                    4'd0:  data_out = rr0_a;
                    4'd1:  data_out = rr1_a;
                    4'd2:  data_out = rr2_a;
                    4'd3:  data_out = rr3_a;
                    4'd8:  data_out = rr8_a;
                    4'd10: data_out = rr10_a;
                    4'd12: data_out = rr12_a;
                    4'd13: data_out = rr13_a;
                    4'd15: data_out = rr15_a;
                    default: data_out = 8'h00;
                endcase
            end
        end else begin  // Channel B
            if (d_c) begin
                data_out = rr8_b;
            end else begin
                case (reg_ptr_b)
                    4'd0:  data_out = rr0_b;
                    4'd1:  data_out = rr1_b;
                    4'd2:  data_out = rr2_b;
                    4'd10: data_out = rr10_b;
                    4'd12: data_out = rr12_b;
                    4'd13: data_out = rr13_b;
                    4'd15: data_out = rr15_b;
                    default: data_out = 8'h00;
                endcase
            end
        end
    end
end

//============================================================================
// Non-standard debug extension (SGI Indy sim project) - see dbg_tx_byte_a/b
// port comments. Latches a COPY of tx_shift_a/b (not the live, mutating
// register) into the sclk domain at the exact moment a byte is grabbed from
// the TX FIFO, then double-synchronizes that stable copy into the clk
// domain alongside the existing tx_byte_grab_toggle synchronizer - standard
// "data + toggle" CDC pattern, avoids catching tx_shift_a/b mid-shift-out.
//============================================================================
// SGI: the capture has to happen on the SAME sclk edge that flips
// tx_byte_grab_toggle_*, which is the edge the TX FSM loads tx_shift_* on -
// not on tx_fifo_ren_*_s. tx_fifo_ren_*_s is set by that edge, so gating on it
// captures a whole sclk period LATE, while the toggle needs only two or three
// clk cycles to cross. With sclk slower than clk - which is the normal case,
// 3.6864 MHz against a system clock - the strobe therefore arrives before the
// data, and every byte the tap reports is the previous one. It shows up as a
// leading 0x00 and a missing last character, with the serial line itself
// perfectly correct.
reg [7:0] dbg_tx_byte_a_sclk, dbg_tx_byte_b_sclk;
always @(posedge sclk_a or negedge reset_n) begin
    if (!reset_n) dbg_tx_byte_a_sclk <= 8'h00;
    else if (tx_clk_a_s && tx_enable_a_s && tx_state_a == TX_IDLE &&
             !tx_fifo_rempty_a && tx_cts_ok_a_s)
        dbg_tx_byte_a_sclk <= tx_fifo_rdata_a;
end
always @(posedge sclk_b or negedge reset_n) begin
    if (!reset_n) dbg_tx_byte_b_sclk <= 8'h00;
    else if (tx_clk_b_s && tx_enable_b_s && tx_state_b == TX_IDLE &&
             !tx_fifo_rempty_b && tx_cts_ok_b_s)
        dbg_tx_byte_b_sclk <= tx_fifo_rdata_b;
end

reg [7:0] dbg_tx_byte_a_r, dbg_tx_byte_b_r;
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        dbg_tx_byte_a_r <= 8'h00;
        dbg_tx_byte_b_r <= 8'h00;
    end else begin
        // Sampled every cycle rather than gated by the strobe, so it's already
        // settled to the new value BY the cycle the strobe (derived from the
        // same tx_byte_grab_*_sync shift register) pulses.
        dbg_tx_byte_a_r <= dbg_tx_byte_a_sclk;
        dbg_tx_byte_b_r <= dbg_tx_byte_b_sclk;
    end
end

assign dbg_tx_byte_a = dbg_tx_byte_a_r;
assign dbg_tx_byte_b = dbg_tx_byte_b_r;
assign dbg_tx_byte_a_strobe = (tx_byte_grab_a_sync[2] != tx_byte_grab_a_sync[1]);
assign dbg_tx_byte_b_strobe = (tx_byte_grab_b_sync[2] != tx_byte_grab_b_sync[1]);
assign dbg_read_en = read_en;
assign dbg_rr0_a = rr0_a;
assign dbg_tx_fifo_wfull_a = tx_fifo_wfull_a;

endmodule


//============================================================================
// Async FIFO (Gray-pointer, dual-clock, depth = 2**AW)
//============================================================================

module scc_async_fifo #(
    parameter DW = 8,
    parameter AW = 2
) (
    input  wire            wclk,
    input  wire            wrst_n,
    input  wire            wen,
    input  wire [DW-1:0]   wdata,
    output wire            wfull,
    output wire            wempty,   // writer-side view of empty

    input  wire            rclk,
    input  wire            rrst_n,
    input  wire            ren,
    output wire [DW-1:0]   rdata,
    output wire            rempty
);
    localparam DEPTH = 1 << AW;
    reg [DW-1:0] mem [0:DEPTH-1];

    reg  [AW:0] wbin, wgray;
    reg  [AW:0] rbin, rgray;
    reg  [AW:0] wgray_at_r1, wgray_at_r;
    reg  [AW:0] rgray_at_w1, rgray_at_w;

    wire        do_write  = wen && !wfull;
    wire        do_read   = ren && !rempty;
    wire [AW:0] wbin_nxt  = wbin + (do_write ? {{AW{1'b0}}, 1'b1} : {(AW+1){1'b0}});
    wire [AW:0] wgray_nxt = wbin_nxt ^ (wbin_nxt >> 1);
    wire [AW:0] rbin_nxt  = rbin + (do_read  ? {{AW{1'b0}}, 1'b1} : {(AW+1){1'b0}});
    wire [AW:0] rgray_nxt = rbin_nxt ^ (rbin_nxt >> 1);

    // Write side
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin  <= {(AW+1){1'b0}};
            wgray <= {(AW+1){1'b0}};
        end else begin
            wbin  <= wbin_nxt;
            wgray <= wgray_nxt;
            if (wen && !wfull) mem[wbin[AW-1:0]] <= wdata;
        end
    end

    // Read side
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin  <= {(AW+1){1'b0}};
            rgray <= {(AW+1){1'b0}};
        end else begin
            rbin  <= rbin_nxt;
            rgray <= rgray_nxt;
        end
    end

    // Sync write pointer into read domain
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            wgray_at_r1 <= {(AW+1){1'b0}};
            wgray_at_r  <= {(AW+1){1'b0}};
        end else begin
            wgray_at_r1 <= wgray;
            wgray_at_r  <= wgray_at_r1;
        end
    end

    // Sync read pointer into write domain
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            rgray_at_w1 <= {(AW+1){1'b0}};
            rgray_at_w  <= {(AW+1){1'b0}};
        end else begin
            rgray_at_w1 <= rgray;
            rgray_at_w  <= rgray_at_w1;
        end
    end

    assign rempty = (rgray == wgray_at_r);
    assign wempty = (wgray == rgray_at_w);
    // Standard async-FIFO full: top 2 Gray bits inverted vs synced read ptr
    assign wfull  = (wgray == {~rgray_at_w[AW:AW-1], rgray_at_w[AW-2:0]});
    assign rdata  = mem[rbin[AW-1:0]];

endmodule