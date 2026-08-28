//============================================================================
//  sgi_ioc - IOC2, the Indy's I/O controller, and the INT2 interrupt block.
//
//  IOC2 is PBUS PIO channel 6 of HPC3, so it lives inside HPC3's window at
//  0x1FBD9800 and is decoded ahead of it. Register layout from IRIS's
//  src/ioc.rs, which matches what the PROM touches address for address.
//
//  BYTE LANE. Every register here is eight bits wide on a 32-bit word, stride
//  four, and the value sits in the LOW byte - the byte at word + 3, because
//  the machine is big-endian. That is not a guess: the PROM reads the INT2
//  registers with `lbu` at base+3 (0xBFC03FD8), drives the whole power-on
//  console through byte accesses at 0xBFBD9833 rather than 0xBFBD9830, and
//  reads SYS_ID with a full `lw` and tests bit 5. Writes take whichever byte
//  lane is enabled, so a `sw` of the value works as well as an `sb` at +3.
//
//  INTERRUPT STATUS IS REAL ZERO, NOT A LOOPBACK. L0_STAT, L1_STAT and
//  MAP_STAT read 0 and ignore writes, because nothing in this core raises an
//  interrupt yet. The DE1 sandbox made them read-write registers so the PROM's
//  init writes would "work"; that passes the same tests and then lies as soon
//  as anything real is connected, so it is not done here. When interrupt
//  sources arrive they wire into l0_stat/l1_stat and nothing else changes.
//============================================================================

module sgi_ioc #(
    // SYS_ID, at +0x58. 0x26 is IRIS's value for guinness (an Indy); 0x11 is
    // fullhouse (an Indigo2). Two bits of it steer the PROM:
    //   bit 5  - where the interrupt controller lives. Set means IOC + 0x80,
    //            which is the Indy's INT2; clear sends the PROM to 0x1FBD9000
    //            instead, the Indigo2 location, and its "INT path test" then
    //            fails and drops it into an endless diagnostic loop
    //            (0xBFC03FA0 reads this register to make exactly that choice).
    //   bit 1  - full-house detect, per IRIS's note on the same constant.
    parameter logic [7:0] SYS_ID_VALUE = 8'h26,
    // Passed through to the 8254; see pit8254.sv.
    parameter int PIT_TICK_DIV = 50
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,

    input  logic        sel,          // one-cycle request pulse, address in window
    input  logic        we,
    input  logic  [7:0] addr,         // offset into the 256-byte window, 8-aligned
    input  logic  [2:0] aoff,         // byte offset of the access in its doubleword
    input  logic  [7:0] be,
    input  logic [63:0] wdata,
    output logic [63:0] rdata,
    output logic        ack,

    // Interrupt inputs, for when there are any. Bit assignments are IRIS's
    // l0_regs/l1_regs: L0 bit 1 = SCSI0, bit 3 = Ethernet, bit 4 = MC DMA;
    // L1 bit 4 = HPC DMA, bit 7 = vertical retrace.
    input  logic  [7:0] l0_source,
    input  logic  [7:0] l1_source,
    output logic        int_n         // to the CPU, active low
);

    // Register indices, as (offset >> 2).
    localparam int I_KBD_DATA  = 8'h40 >> 2;
    localparam int I_KBD_CMD   = 8'h44 >> 2;
    localparam int I_SYS_ID    = 8'h58 >> 2;
    localparam int I_L0_STAT   = 8'h80 >> 2;
    localparam int I_L0_MASK   = 8'h84 >> 2;
    localparam int I_L1_STAT   = 8'h88 >> 2;
    localparam int I_L1_MASK   = 8'h8C >> 2;
    localparam int I_MAP_STAT  = 8'h90 >> 2;
    localparam int I_PIT_BASE  = 8'hB0 >> 2;    // counters 0..2 then the control word

    logic [7:0] reg8 [0:63];

    // Live interrupt state. Masks live in reg8 with everything else; the
    // status lines are inputs and are not stored.
    wire [7:0] l0_stat = l0_source;
    wire [7:0] l1_stat = l1_source;
    assign int_n = ~(|(l0_stat & reg8[I_L0_MASK]) | |(l1_stat & reg8[I_L1_MASK]));

    // Collapse whichever byte lane is enabled onto the register's value, the
    // same way sgi_scc.sv does: an 8-bit register on a 32-bit word does not
    // care which lane the CPU used to reach it.
    function automatic logic [7:0] ioc_wr_byte(input logic w);
        ioc_wr_byte = 8'h00;
        for (int b = 0; b < 4; b++)
            if (be[7 - 4*w - b]) ioc_wr_byte = wdata[56 - 32*w - 8*b +: 8];
    endfunction

    // The 8254 timer occupies four register slots at the top of the window.
    // Its reads have side effects - an LSB/MSB pair alternates - so the strobe
    // has to name the half the CPU actually addressed rather than firing for
    // both halves of the doubleword. Byte enables are meaningless on a read
    // (see r4300_bus.sv), so `aoff` is what says which.
    wire       pit_sel  = (addr[7:4] == 4'hB);
    wire [1:0] pit_idx  = {addr[3], aoff[2]};
    wire [7:0] pit_dout;
    wire       pit_rd   = sel && !we && pit_sel;
    wire       pit_wr   = sel &&  we && pit_sel
                          && (aoff[2] ? (|be[3:0]) : (|be[7:4]));

    pit8254 #(.TICK_DIV(PIT_TICK_DIV)) u_pit (
        .clk   (clk),
        .reset (reset),
        .ce    (ce),
        .rd    (pit_rd),
        .wr    (pit_wr),
        .sel   (pit_idx),
        .din   (ioc_wr_byte(aoff[2])),
        .dout  (pit_dout),
        .out   ()
    );

    function automatic logic [7:0] ioc_rd(input logic w);
        logic [5:0] idx;
        idx = {addr[7:3], w};
        case (idx)
            // The PC-style keyboard/mouse controller. Nothing is fitted, and
            // the pair has to read 0 rather than read back what was written:
            // +0x44 is the command port on a write but the STATUS port on a
            // read, and the PROM's self-test writes 0xAA there and then polls
            // it. A loopback answers 0xAA, whose bit 1 says "input buffer
            // full", and the PROM waits for the controller to drain forever.
            // Zero is "idle, nothing to read", so the self-test times out and
            // the diagnostic reports the controller missing - which it is.
            I_KBD_DATA,
            I_KBD_CMD:  ioc_rd = 8'h00;
            I_SYS_ID:   ioc_rd = SYS_ID_VALUE;
            I_L0_STAT:  ioc_rd = l0_stat;
            I_L1_STAT:  ioc_rd = l1_stat;
            I_MAP_STAT: ioc_rd = 8'h00;
            default:    ioc_rd = (idx >= I_PIT_BASE) ? pit_dout : reg8[idx];
        endcase
    endfunction

    wire [1:0] wr_en = {sel && we && (|be[3:0]), sel && we && (|be[7:4])};

    integer i;
    always_ff @(posedge clk) begin
        ack   <= 1'b0;
        rdata <= 64'h0;

        if (reset) begin
            for (i = 0; i < 64; i = i + 1) reg8[i] <= 8'h00;
            // PANEL bit 0 is the power state, and the machine is on.
            reg8[8'h50 >> 2] <= 8'h01;
            // IOC_READ bits 6:4 are the Ethernet and SCSI "power good" lines.
            reg8[8'h60 >> 2] <= 8'h70;
        end else begin
            for (int w = 0; w < 2; w++) begin
                if (wr_en[w]) begin
                    logic [5:0] idx;
                    idx = {addr[7:3], w[0]};
                    // The three status registers are read-only, the timer has
                    // its own state; everything else, including all the masks,
                    // is plain storage.
                    if (idx != I_L0_STAT && idx != I_L1_STAT && idx != I_MAP_STAT
                        && idx != I_KBD_DATA && idx != I_KBD_CMD
                        && idx < I_PIT_BASE)
                        reg8[idx] <= ioc_wr_byte(w[0]);
                end
            end

            if (sel) begin
                rdata <= {24'h0, ioc_rd(1'b0), 24'h0, ioc_rd(1'b1)};
                ack   <= 1'b1;
            end
        end
    end

endmodule
