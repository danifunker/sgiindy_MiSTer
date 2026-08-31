//============================================================================
//  eeprom_93c56 - the R4000 configuration EEPROM hanging off MC + 0x30.
//
//  128 words x 16 bits, Microwire, bit-banged by the CPU through four bits of
//  one MC register. The MC spec calls it the "R4000 Configuration EEROM
//  Interface": the R4000 reads it through MC at hard reset to set its own
//  configuration bits, and the PROM then reads and writes it in software.
//
//  PROTOCOL, as the PROM actually drives it (0xBFC0A83C onwards):
//
//    start   CS=0, then CS=1, then SK=1
//    command 11 bits shifted MSB first: 1 start bit, 2 opcode bits, 8 address
//            bits. DI is set up, SK is driven low, then high - so the RISING
//            edge of SK is what samples DI.
//    read    opcode 10: the part emits a dummy 0 and then 16 data bits, MSB
//            first, which the CPU samples on bit 4 of the MC register
//    write   opcode 01, preceded by WREN and followed by WRDS (opcode 00 with
//            address bits 11xxxxxx and 00xxxxxx respectively), then 16 data
//            bits shifted in the same way
//    end     SK=0, CS=0, SK=1
//
//  CS, SK and DI are three bits of one CPU-written register, so they are
//  already in this clock domain and no synchroniser is wanted. The PROM never
//  moves two of them in one store - it always writes DI, then SK low, then SK
//  high - so a CS change and an SK edge cannot collide; CS is given priority
//  anyway, because CS is level sensitive on the real part and resets the shift
//  logic regardless of the clock.
//
//  DO MUST READ HIGH WHEN THE PART IS IDLE. After a write the PROM raises CS
//  and polls bit 4 up to 100000 times waiting for "ready" (0xBFC0AA8C); a
//  model that left DO low there would burn the whole timeout on every write.
//  Dropping CS therefore restores DO to 1, which is what a real part does -
//  DO is high-Z between transfers and the MC's input floats high.
//
//  Contents are volatile: there is no backing store on the FPGA side yet, so
//  the array powers up erased and anything the PROM writes is lost at reset.
//  That is a deliberate gap. TWO words' power-up values actually matter, and
//  both are parameters below: CACHSZ_PAGES and the Ethernet address.
//============================================================================

module eeprom_93c56 #(
    // Word 0x11 is CACHSZ_REG: the size of the secondary cache in 4 KB pages.
    // The PROM reads it when the R4000's Config register reports no probed
    // secondary cache, which is exactly this core's situation. The erased
    // state is 0xFFFF, and firmware that believes that spends the boot
    // flushing a 256 MB cache which does not exist, so a model with no L2 has
    // to say so explicitly. IRIS carries the same note in src/machine.rs.
    parameter logic [15:0] CACHSZ_PAGES = 16'h0000,

    // THE ETHERNET ADDRESS, AND IT IS NOT OPTIONAL JUST BECAUSE THERE IS NO
    // ETHERNET. Words 0x7D..0x7F of this part are the machine's MAC address,
    // two bytes each, and the PROM turns them into the `eaddr` environment
    // variable. IRIS names the same layout in src/eeprom_93c56.rs.
    //
    // Erased, those words read 0xFFFF and the address comes out as
    // ff:ff:ff:ff:ff:ff - which the PROM carries as a literal string at
    // 0xBFC4CF58 precisely so it can recognise it as invalid. It then leaves
    // `eaddr` out of the environment altogether, and `printenv` in the Command
    // Monitor showed exactly that: fifteen variables and no eaddr.
    //
    // THAT IS WHAT CRASHED THE IRIX 5.3 INSTALLER, all the way from a blank
    // EEPROM to a panic, and every step was measured on hardware:
    //
    //   the installer calls the ARCS firmware vector at SPB+0x20, offset 0x78
    //   - GetEnvironmentVariable - for "eaddr" (0x880076E4), passes the result
    //   straight to a ':'-separated hex parser with NO null check (0x880076EC),
    //   and that parser's first instruction is `lbu $t6, ($a0)` (0x880075B4).
    //   With $a0 = 0 it takes a UTLB refill on virtual address zero and the
    //   PROM's handler prints "PANIC: Unexpected exception".
    //
    // The six bytes are copied into a six-byte buffer and nibble-picked right
    // after the call, which is how the parser was identified as a MAC parser
    // rather than anything else.
    //
    // 08:00:69 is SGI's OUI. The suffix matches the one IRIS uses, so the two
    // machines report the same address and can be compared directly; nothing
    // in this core transmits, so there is no address to collide with.
    parameter logic [47:0] MAC_ADDR = 48'h08_00_69_12_34_56
)(
    input  logic clk,
    input  logic reset,

    input  logic cs,          // chip select, active high
    input  logic sk,          // serial clock; the part advances on its rising edge
    input  logic di,          // data in, from the MC register
    output logic do_out       // data out, back into bit 4 of the MC register
);

    // Opcodes, in the order they arrive after the start bit.
    localparam logic [1:0] OP_CTRL  = 2'b00;   // WRDS / WRAL / ERAL / WREN
    localparam logic [1:0] OP_WRITE = 2'b01;
    localparam logic [1:0] OP_READ  = 2'b10;
    localparam logic [1:0] OP_ERASE = 2'b11;

    typedef enum logic [2:0] {
        S_STANDBY,   // CS low
        S_IDLE,      // CS high, waiting for the start bit
        S_OPCODE,    // 2 opcode bits
        S_ADDRESS,   // 8 address bits
        S_DATA_IN,   // 16 bits being written
        S_DATA_OUT,  // 16 bits being read out
        S_BULK       // ERAL / WRAL walking the array one word per clock
    } state_t;

    state_t      state;
    logic [15:0] mem [0:127];
    logic [15:0] shifter;
    logic  [4:0] bit_count;
    logic  [1:0] opcode;
    logic  [7:0] address;
    logic        write_enable;   // set by WREN, cleared by WRDS and by reset

    logic  [7:0] bulk_addr;
    logic [15:0] bulk_val;

    logic sk_q, cs_q;
    wire  sk_rise = sk & ~sk_q;

    // The bit arriving on this SK edge is always the LSB of what has been
    // shifted so far, so both the completed address and the completed data
    // word can be named once rather than reassembled at each use.
    wire  [7:0] addr_now = {shifter[6:0],  di};
    wire [15:0] data_now = {shifter[14:0], di};

    // Power-up contents. Quartus turns an initial block over an inferred
    // memory into its power-up value and Verilator runs it at time zero, so
    // this is the erased state of a real part plus the one word this core has
    // to answer differently.
    integer i;
    initial begin
        for (i = 0; i < 128; i = i + 1) mem[i] = 16'hFFFF;
        mem[8'h11] = CACHSZ_PAGES;
        mem[8'h7D] = MAC_ADDR[47:32];
        mem[8'h7E] = MAC_ADDR[31:16];
        mem[8'h7F] = MAC_ADDR[15:0];
    end

    always_ff @(posedge clk) begin
        sk_q <= sk;
        cs_q <= cs;

        if (reset) begin
            state        <= S_STANDBY;
            do_out       <= 1'b1;
            write_enable <= 1'b0;
            sk_q         <= 1'b0;
            cs_q         <= 1'b0;
        end else if (state == S_BULK) begin
            // ERAL/WRAL, one word per clock so the array stays a single-write-
            // port memory rather than 2048 flops. Nothing the PROM does gets
            // here, but leaving the opcodes silently unimplemented would be a
            // worse trap than 128 clocks of fill.
            mem[bulk_addr[6:0]] <= bulk_val;
            bulk_addr           <= bulk_addr + 8'd1;
            if (bulk_addr == 8'd127) state <= S_IDLE;
        end else if (cs != cs_q) begin
            if (cs) begin
                state  <= S_IDLE;
            end else begin
                state  <= S_STANDBY;
                do_out <= 1'b1;          // idle high - see the header
            end
        end else if (cs && sk_rise) begin
            case (state)
                S_STANDBY: ;             // CS low: nothing happens

                S_IDLE:
                    // A leading 1 opens a command; leading zeroes are ignored,
                    // which is how the part tolerates being clocked while idle.
                    if (di) begin
                        state     <= S_OPCODE;
                        bit_count <= 5'd0;
                        shifter   <= 16'd0;
                    end

                S_OPCODE: begin
                    shifter   <= {shifter[14:0], di};
                    bit_count <= bit_count + 5'd1;
                    if (bit_count == 5'd1) begin
                        opcode    <= {shifter[0], di};
                        state     <= S_ADDRESS;
                        bit_count <= 5'd0;
                        shifter   <= 16'd0;
                    end
                end

                S_ADDRESS: begin
                    shifter   <= {shifter[14:0], di};
                    bit_count <= bit_count + 5'd1;
                    if (bit_count == 5'd7) begin
                        address <= addr_now;
                        case (opcode)
                            OP_READ: begin
                                // Load the word now; it starts shifting out on
                                // the next edge, behind the dummy zero the
                                // part emits as soon as the address lands.
                                shifter   <= mem[addr_now[6:0]];
                                bit_count <= 5'd0;
                                do_out    <= 1'b0;
                                state     <= S_DATA_OUT;
                            end
                            OP_WRITE: begin
                                bit_count <= 5'd0;
                                shifter   <= 16'd0;
                                state     <= write_enable ? S_DATA_IN : S_IDLE;
                            end
                            OP_ERASE: begin
                                if (write_enable) mem[addr_now[6:0]] <= 16'hFFFF;
                                state <= S_IDLE;
                            end
                            OP_CTRL: begin
                                // The sub-command is the top two address bits;
                                // the rest are don't-care.
                                bit_count <= 5'd0;
                                shifter   <= 16'd0;
                                bulk_addr <= 8'd0;
                                bulk_val  <= 16'hFFFF;
                                state     <= S_IDLE;
                                case (addr_now[7:6])
                                    2'b00: write_enable <= 1'b0;            // WRDS
                                    2'b01: if (write_enable) state <= S_DATA_IN;
                                    2'b10: if (write_enable) state <= S_BULK; // ERAL
                                    2'b11: write_enable <= 1'b1;            // WREN
                                endcase
                            end
                        endcase
                    end
                end

                S_DATA_IN: begin
                    shifter   <= {shifter[14:0], di};
                    bit_count <= bit_count + 5'd1;
                    if (bit_count == 5'd15) begin
                        state <= S_IDLE;
                        if (opcode == OP_WRITE) begin
                            mem[address[6:0]] <= data_now;
                        end else begin                                // WRAL
                            bulk_addr <= 8'd0;
                            bulk_val  <= data_now;
                            state     <= S_BULK;
                        end
                    end
                end

                S_DATA_OUT: begin
                    // bit_count 0 was consumed emitting the dummy zero, so
                    // this edge presents D15 and the sixteenth presents D0.
                    if (bit_count < 5'd16) begin
                        do_out    <= shifter[4'd15 - bit_count[3:0]];
                        bit_count <= bit_count + 5'd1;
                    end else begin
                        do_out <= 1'b1;
                        state  <= S_IDLE;
                    end
                end

                S_BULK: ;                // handled above, before the SK gate
            endcase
        end
    end

endmodule
