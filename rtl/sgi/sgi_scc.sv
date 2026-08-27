//============================================================================
//  sgi_scc - the SGI side of the Z8530.
//
//  Two jobs: turn one bus transaction into the SCC's cs_n / rd_n / wr_n
//  handshake, and get the channel mapping right.
//
//  CHANNEL NAMING. This is the trap. IOC2 puts the SCC's four byte-wide ports
//  at IOC_BASE + 0x30, 0x34, 0x38, 0x3C - a stride of four, one register per
//  32-bit word. IRIS calls the pair at +0x30/+0x34 "channel B / tty1"
//  (ioc.rs: IOC_SERIAL1_CMD/DATA) and that is the SGI serial console; the pair
//  at +0x38/+0x3C is channel A / tty2. The DE1 sandbox's RTL called the same
//  window "Port 1 / channel A", which is why a working console can look broken
//  when moving code between them. `port` here follows IRIS, and `a_b` follows
//  the Zilog part: 1 = channel A, and the console is channel B, so `a_b` is
//  high only for the +0x38/+0x3C pair.
//
//  HANDSHAKE. The SCC edge-detects both strobes internally: a write fires on
//  the falling edge of (wr_n | cs_n), and a control-port read resets the
//  register pointer - and a data-port read pops the RX FIFO - on the falling
//  edge of read_en. So a transaction has to hold the strobe for more than one
//  clock and then release it, which is what the four-state machine below does.
//  Driving cs_n low for a single cycle looks like it works for writes and
//  silently never advances the register pointer on reads.
//
//  BYTE LANE. The IOC decodes address bits [31:2] only, and which byte lane an
//  8-bit register drives is not settled: IRIS's ioc.rs aliases all four byte
//  addresses to the same register on an 8-bit access (read8 masks with !3) but
//  returns the value in the LOW 8 bits of a 32-bit read, while both the PROM
//  and the test suite use byte accesses at offset 0 - the most significant
//  lane of a big-endian word. Rather than pick, reads replicate the register
//  across all four byte lanes of the addressed word and writes take whichever
//  lane is enabled, so either reading works. Worth pinning down against the
//  PROM when M3 starts.
//============================================================================

module sgi_scc
(
    input  logic        clk,
    input  logic        reset,
    input  logic        sclk,       // serial-side clock: BRG and bit engines

    // ---- bus ----
    input  logic        sel,        // one-cycle request in the SCC window
    input  logic  [1:0] port,       // 0=chB cmd 1=chB data 2=chA cmd 3=chA data
    input  logic        we,
    input  logic  [3:0] be,         // byte enables, be[3] = most significant
    input  logic [31:0] wdata,      // big-endian: [31:24] is the byte at +0
    output logic [31:0] rdata,
    output logic        ack,

    // ---- serial pins ----
    input  logic        rxda,
    output logic        txda,
    input  logic        rxdb,
    output logic        txdb,
    output logic        int_n,

    // ---- console tap ----
    // Pulses once per byte the transmitter actually picks up, which is the
    // byte the machine is printing. Nothing here depends on the bit rate.
    output logic        tx_valid,
    output logic  [7:0] tx_data,
    output logic        tx_chan     // 0 = channel B (tty1), 1 = channel A
);

    // ---- write-lane collapse -------------------------------------------
    logic [7:0] wr_byte;
    always_comb begin
        wr_byte = 8'h00;
        if (be[3]) wr_byte = wdata[31:24];
        if (be[2]) wr_byte = wdata[23:16];
        if (be[1]) wr_byte = wdata[15:8];
        if (be[0]) wr_byte = wdata[7:0];
    end

    // ---- handshake ------------------------------------------------------
    typedef enum logic [1:0] { H_IDLE, H_STROBE, H_HOLD, H_RELEASE } hstate_t;
    hstate_t    hstate;

    logic       cs_n, rd_n, wr_n;
    logic       a_b, d_c, is_wr;
    logic [7:0] data_in;
    logic [7:0] data_out;
    logic [7:0] rd_byte;

    always_ff @(posedge clk) begin
        if (reset) begin
            hstate <= H_IDLE;
            cs_n   <= 1'b1;
            rd_n   <= 1'b1;
            wr_n   <= 1'b1;
            ack    <= 1'b0;
        end else begin
            ack <= 1'b0;
            case (hstate)
                H_IDLE:
                    if (sel) begin
                        a_b     <= port[1];      // 1 = channel A (+0x38/+0x3C)
                        d_c     <= port[0];      // 1 = data port
                        is_wr   <= we;
                        data_in <= wr_byte;
                        cs_n    <= 1'b0;
                        rd_n    <= we ? 1'b1 : 1'b0;
                        wr_n    <= we ? 1'b0 : 1'b1;
                        hstate  <= H_STROBE;
                    end

                H_STROBE: begin
                    // The write pulse fires on this edge; the read mux is
                    // combinational and settled.
                    rd_byte <= data_out;
                    hstate  <= H_HOLD;
                end

                H_HOLD: begin
                    // Release the strobes. The falling edge of read_en is what
                    // resets the register pointer and pops the RX FIFO.
                    cs_n   <= 1'b1;
                    rd_n   <= 1'b1;
                    wr_n   <= 1'b1;
                    hstate <= H_RELEASE;
                end

                H_RELEASE: begin
                    ack    <= 1'b1;
                    hstate <= H_IDLE;
                end
            endcase
        end
    end

    assign rdata = {4{rd_byte}};

    // ---- the part -------------------------------------------------------
    logic dbg_tx_a_strobe, dbg_tx_b_strobe;
    logic [7:0] dbg_tx_a, dbg_tx_b;

    z8530_scc u_scc (
        .clk        (clk),
        .pclk       (clk),
        .sclk       (sclk),
        .reset_n    (~reset),

        .cs_n       (cs_n),
        .rd_n       (rd_n),
        .wr_n       (wr_n),
        .a_b        (a_b),
        .d_c        (d_c),
        .data_in    (data_in),
        .data_out   (data_out),
        .data_oe    (),

        .int_n      (int_n),
        .intack_n   (1'b1),

        // Channel A. The modem-control inputs are deasserted (they are active
        // low), so Auto Enables never gates the transmitter off in a machine
        // with nothing plugged into the port.
        .rxca       (1'b0),
        .txca       (1'b0),
        .rxda       (rxda),
        .txda       (txda),
        .ctsa_n     (1'b0),
        .dcda_n     (1'b0),
        .synca_n    (1'b1),
        .rtsa_n     (),
        .dtra_n     (),

        // Channel B - the console.
        .rxcb       (1'b0),
        .txcb       (1'b0),
        .rxdb       (rxdb),
        .txdb       (txdb),
        .ctsb_n     (1'b0),
        .dcdb_n     (1'b0),
        .syncb_n    (1'b1),
        .rtsb_n     (),
        .dtrb_n     (),

        .dbg_tx_byte_a        (dbg_tx_a),
        .dbg_tx_byte_a_strobe (dbg_tx_a_strobe),
        .dbg_tx_byte_b        (dbg_tx_b),
        .dbg_tx_byte_b_strobe (dbg_tx_b_strobe),
        .dbg_read_en          (),
        .dbg_rr0_a            (),
        .dbg_tx_fifo_wfull_a  ()
    );

    // Channel B first: it is the console, and two bytes cannot pop in the same
    // cycle from one BRG anyway.
    always_ff @(posedge clk) begin
        tx_valid <= 1'b0;
        if (!reset) begin
            if (dbg_tx_b_strobe) begin
                tx_valid <= 1'b1;
                tx_data  <= dbg_tx_b;
                tx_chan  <= 1'b0;
            end else if (dbg_tx_a_strobe) begin
                tx_valid <= 1'b1;
                tx_data  <= dbg_tx_a;
                tx_chan  <= 1'b1;
            end
        end
    end

endmodule
