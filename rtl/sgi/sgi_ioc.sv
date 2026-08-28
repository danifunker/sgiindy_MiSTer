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
//  INT2, THE INTERRUPT CONTROLLER, IS AT +0x80 AND IS REAL. Three status
//  registers, three masks, and five lines out to the CPU:
//
//    L0_STAT  & L0_MASK  -> Cause.IP2      the LOCAL0 level
//    L1_STAT  & L1_MASK  -> Cause.IP3      the LOCAL1 level
//    MAP_STAT bit 0      -> Cause.IP4      8254 counter 0
//    MAP_STAT bit 1      -> Cause.IP5      8254 counter 1
//    ERR_STAT            -> Cause.IP6      bus error
//
//  and the two mappable summaries fold back into the levels: MAP_STAT &
//  MAP_MASK0 is L0_STAT bit 7, MAP_STAT & MAP_MASK1 is L1_STAT bit 3. That is
//  IRIS's Ioc::update_interrupts, and it is the arrangement the PROM's own
//  dispatch assumes.
//
//  EVERY STATUS BIT IS A LEVEL, NOT A LATCH, WITH TWO EXCEPTIONS. A device
//  holds its line until its ISR clears the condition at the device; the status
//  bit follows the wire and Cause.IP follows the status bit, so there is
//  nothing here to acknowledge. The exceptions are MAP_STAT bits 0 and 1, the
//  two 8254 counters, which are set by an edge and cleared only by a write to
//  TMR_CLR at +0xA0 - a counter output is a pulse, so something has to
//  remember it.
//
//  WHAT THIS IS FOR IS IRIX, NOT THE PROM. The PROM writes a walking pattern
//  through both LOCAL masks as its INT path test, settles on L1_MASK = 0x02
//  (the front panel) and nothing else, and polls its devices - it never takes
//  an interrupt for SCSI at all. So a boot to the Command Monitor proves
//  nothing about anything below, and reasoning about device timing from the
//  console will mislead you; it already did once, and docs/12-chipset.md
//  records the wrong conclusion next to the right one. tests/run-int.sh is
//  what actually exercises this block.
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

    // Interrupt sources, all active high. Bit assignments are IRIS's
    // l0_regs / l1_regs / map_regs:
    //   L0   0 FIFO full, 1 SCSI0, 2 SCSI1, 3 Ethernet, 4 MC DMA,
    //        5 parallel, 6 graphics, 7 MAP_INT0 (generated here)
    //   L1   0 GP0, 1 panel, 2 GP2, 3 MAP_INT1 (generated here), 4 HPC DMA,
    //        5 AC fail, 6 video vsync, 7 vertical retrace
    //   MAP  4 keyboard/mouse, 5 serial, 6/7 GIO expansion slots 0 and 1.
    //        Bits 0 and 1 are the 8254 counters and come in on pit_edge
    //        below rather than here, because they are edges.
    // Bit 7 of l0_source and bit 3 of l1_source are ignored: they are the two
    // mappable summaries and are computed from MAP_STAT.
    input  logic  [7:0] l0_source,
    input  logic  [7:0] l1_source,
    input  logic  [7:0] map_source,

    output logic  [4:0] irq_lines,    // to the CPU: Cause.IP[6:2]

    // Observability. INT2's whole visible state in one bus, so a harness can
    // say why a line is or is not asserted without reaching into the
    // hierarchy: {MAP_STAT, L1_MASK, L1_STAT, L0_MASK, L0_STAT}.
    output logic [39:0] int2_state
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
    localparam int I_MAP_MASK0 = 8'h94 >> 2;
    localparam int I_MAP_MASK1 = 8'h98 >> 2;
    localparam int I_TMR_CLR   = 8'hA0 >> 2;    // write-only: clears MAP_STAT[1:0]
    localparam int I_ERR_STAT  = 8'hA4 >> 2;
    localparam int I_PIT_BASE  = 8'hB0 >> 2;    // counters 0..2 then the control word

    logic [7:0] reg8 [0:63];

    // The only interrupt state this block owns: the two counter latches.
    // Everything else is a wire from a device or a mask in reg8.
    logic [1:0] tmr_stat;

    // MAP_STAT. Bits 4..7 follow their sources; bits 0 and 1 are the latches.
    // MAP_POL at +0x9C is stored and does nothing: it selects the active edge
    // of the two GIO expansion lines, and neither is fitted.
    wire [7:0] map_stat = {map_source[7:4], 2'b00, tmr_stat};

    // The two mappable summaries, folded back into the levels they belong to.
    wire map_int0 = |(map_stat & reg8[I_MAP_MASK0]);
    wire map_int1 = |(map_stat & reg8[I_MAP_MASK1]);

    wire [7:0] l0_stat = {map_int0, l0_source[6:0]};
    wire [7:0] l1_stat = {l1_source[7:4], map_int1, l1_source[2:0]};

    // Nothing in this core reports a bus error yet - the unclaimed-cycle path
    // in sgi_indy.sv answers rather than faulting - so ERR_STAT is a real
    // zero and IP6 never fires. It is here because reading it is part of the
    // PROM's interrupt init and a hole would show up as an unclaimed cycle.
    wire [7:0] err_stat = 8'h00;

    assign int2_state = {map_stat, reg8[I_L1_MASK], l1_stat,
                         reg8[I_L0_MASK], l0_stat};

    assign irq_lines = {|err_stat,                          // IP6 bus error
                        tmr_stat[1],                        // IP5 counter 1
                        tmr_stat[0],                        // IP4 counter 0
                        |(l1_stat & reg8[I_L1_MASK]),       // IP3 LOCAL1
                        |(l0_stat & reg8[I_L0_MASK])};      // IP2 LOCAL0

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

    // Counter 0 and 1 outputs are one-tick pulses at the end of each period
    // (pit8254.sv), so they are edge-detected into the MAP_STAT latches. The
    // rise is what counts: a level would be missed as often as it was seen,
    // because the pulse is one 8254 tick wide and the CPU is not looking.
    logic [2:0] pit_out, pit_out_d;
    wire  [1:0] pit_edge = pit_out[1:0] & ~pit_out_d[1:0];

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
        .out   (pit_out)
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
            I_MAP_STAT: ioc_rd = map_stat;
            I_ERR_STAT: ioc_rd = err_stat;
            // Write-only. The PROM does not read it back, but a loopback here
            // would report interrupts that are not pending.
            I_TMR_CLR:  ioc_rd = 8'h00;
            default:    ioc_rd = (idx >= I_PIT_BASE) ? pit_dout : reg8[idx];
        endcase
    endfunction

    wire [1:0] wr_en = {sel && we && (|be[3:0]), sel && we && (|be[7:4])};

    integer i;
    always_ff @(posedge clk) begin
        ack   <= 1'b0;
        rdata <= 64'h0;

        pit_out_d <= pit_out;

        if (reset) begin
            for (i = 0; i < 64; i = i + 1) reg8[i] <= 8'h00;
            tmr_stat  <= 2'b00;
            pit_out_d <= 3'b000;
            // PANEL bit 0 is the power state, and the machine is on.
            reg8[8'h50 >> 2] <= 8'h01;
            // IOC_READ bits 6:4 are the Ethernet and SCSI "power good" lines.
            reg8[8'h60 >> 2] <= 8'h70;
        end else begin
            // A counter that expires in the same clock as the write that
            // clears it stays pending: the interrupt happened, and losing it
            // costs a whole timer period. Hence set after clear, below.
            for (int w = 0; w < 2; w++) begin
                if (wr_en[w]) begin
                    logic [5:0] idx;
                    logic [7:0] wr_byte_v;
                    idx = {addr[7:3], w[0]};
                    // TMR_CLR is a write-only strobe, not a register: a 1 bit
                    // clears the matching MAP_STAT latch. Only the two counter
                    // bits are clearable; the rest of MAP_STAT is a level.
                    // Via a variable: Quartus 17.0 will not bit-select a
                    // function call, so `ioc_wr_byte(w[0])[1:0]` is a syntax
                    // error there even though Verilator takes it.
                    wr_byte_v = ioc_wr_byte(w[0]);
                    if (idx == I_TMR_CLR)
                        tmr_stat <= tmr_stat & ~wr_byte_v[1:0];
                    // The three status registers are read-only, the timer has
                    // its own state; everything else, including all the masks,
                    // is plain storage.
                    if (idx != I_L0_STAT && idx != I_L1_STAT && idx != I_MAP_STAT
                        && idx != I_KBD_DATA && idx != I_KBD_CMD
                        && idx != I_TMR_CLR && idx != I_ERR_STAT
                        && idx < I_PIT_BASE)
                        reg8[idx] <= ioc_wr_byte(w[0]);
                end
            end

            if (|pit_edge) tmr_stat <= tmr_stat | pit_edge;

            if (sel) begin
                rdata <= {24'h0, ioc_rd(1'b0), 24'h0, ioc_rd(1'b1)};
                ack   <= 1'b1;
            end
        end
    end

endmodule
