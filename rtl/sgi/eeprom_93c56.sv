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
//  the array powers up erased, and what the PROM writes survives a reset but
//  not a reload of the core. That is a deliberate gap. Two words' contents
//  actually matter and neither can be left erased: CACHSZ_PAGES, a parameter,
//  and the Ethernet address, which is a runtime input because it differs per
//  board.
//============================================================================

module eeprom_93c56 #(
    // Word 0x11 is CACHSZ_REG: the size of the secondary cache in 4 KB pages.
    // The PROM reads it when the R4000's Config register reports no probed
    // secondary cache, which is exactly this core's situation. The erased
    // state is 0xFFFF, and firmware that believes that spends the boot
    // flushing a 256 MB cache which does not exist, so a model with no L2 has
    // to say so explicitly. IRIS carries the same note in src/machine.rs.
    parameter logic [15:0] CACHSZ_PAGES = 16'h0000
)(
    input  logic clk,
    input  logic reset,

    // THE ETHERNET ADDRESS, AND IT IS NOT OPTIONAL JUST BECAUSE THERE IS NO
    // ETHERNET. Words 0x7D..0x7F of this part are the machine's MAC address,
    // two bytes each. IRIS names the same layout in src/eeprom_93c56.rs and
    // writes it here as well as in the RTC.
    //
    // It is an INPUT rather than a parameter because the address has to differ
    // per board: sgiindy.sv latches it from games/<core>/boot1.rom, which the
    // framework uploads at ioctl index 0x40 at every core start, and
    // scripts/deploy.sh generates that file on the device with the MiSTer's own
    // last octet in it.
    //
    // THE PROM DOES NOT READ IT FROM HERE - that was measured. These six bytes
    // were put in this part first, and `printenv` in the Command Monitor still
    // listed fifteen variables and no eaddr; sgi_ds1386.sv's NVRAM is the copy
    // that counts. It is set anyway, because IRIS sets both and a machine whose
    // two copies disagree is a trap for whoever reads them next.
    //
    // WHY ANY OF THIS MATTERS. Erased, an address reads ff:ff:ff:ff:ff:ff -
    // which the PROM carries as a literal string at 0xBFC4CF58 precisely so it
    // can recognise it as invalid - and it then leaves `eaddr` out of the
    // environment. That crashed the IRIX 5.3 installer, and every step of it
    // was measured on hardware:
    //
    //   the installer calls the ARCS firmware vector at SPB+0x20, offset 0x78
    //   - GetEnvironmentVariable - for "eaddr" (0x880076E4), passes the result
    //   straight to a ':'-separated hex parser with NO null check (0x880076EC),
    //   and that parser's first instruction is `lbu $t6, ($a0)` (0x880075B4).
    //   With $a0 = 0 it takes a UTLB refill on virtual address zero and the
    //   PROM's handler prints "PANIC: Unexpected exception".
    //
    // The six bytes are copied into a six-byte buffer and nibble-picked right
    // after the call, which is how that parser was identified as a MAC parser
    // rather than anything else.
    input  logic [47:0] mac_addr,

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

    // ---- the array: ONE M10K, not 2,048 flip-flops ------------------------
    //
    // Until build 37 this was read asynchronously - `shifter <= mem[addr_now]`
    // in the clock the address completed - and written from four places, the
    // reset among them. Quartus cannot put that in a memory block and says
    // nothing about it: build 36's fit report had this module at 1,982 ALMs
    // and 2,132 registers, 5 % of the device, for 2 Kbit of storage.
    //
    // So the array now has exactly the shape memory inference wants
    // (quartus-ram-inference in the project notes; sgi_ds1386.sv's NVRAM is
    // the same fix): one write port and one registered read, both in the one
    // clocked process below and nothing else in it. What that costs the
    // protocol is one clock, twice, and neither is visible to the CPU:
    //
    //  * a READ's word lands in `shifter` one clock after its address does
    //    (`load_pending`). The first data bit leaves on the next SK rising
    //    edge, and SK is a bit in an MC register that software stores to -
    //    DI, then SK low, then SK high, three bus writes apart - so the word
    //    is there thousands of clocks before it is needed;
    //  * every store reaches the array one clock after the SK edge or bulk
    //    step that makes it (`wr_pend`), and nothing can read that word
    //    sooner than a whole command later.
    //
    // The Ethernet address used to be three stores inside the reset. It is
    // now written in the three clocks after reset releases (`seeding`), as
    // sgi_ds1386.sv does: the PROM is millions of clocks from its first
    // Microwire command by then.
    logic [15:0] mem [0:127];
    logic [15:0] mem_q;
    logic        wr_pend;
    logic  [6:0] wr_addr;
    logic [15:0] wr_data;

    always_ff @(posedge clk) begin
        if (wr_pend) mem[wr_addr] <= wr_data;
        mem_q <= mem[addr_now[6:0]];
    end

    // Power-up contents. Quartus turns an initial block over an inferred
    // memory into its power-up value and Verilator runs it at time zero, so
    // this is the erased state of a real part plus the one word this core has
    // to answer differently. It is a POWER-UP value only: nothing clears the
    // array at reset - the flip-flop version did not either - so what the
    // PROM writes survives a reset and is lost when the core is loaded again.
    integer i;
    initial begin
        for (i = 0; i < 128; i = i + 1) mem[i] = 16'hFFFF;
        mem[8'h11] = CACHSZ_PAGES;
    end

    logic       load_pending;    // a READ's word is in mem_q this clock
    logic       seeding;         // writing the Ethernet address after reset
    logic [1:0] seed_idx;

    always_ff @(posedge clk) begin
        sk_q    <= sk;
        cs_q    <= cs;
        wr_pend <= 1'b0;

        if (reset) begin
            // The PROM does NOT read the Ethernet address from here: the same
            // six bytes were put in this part first and `printenv` still
            // showed no eaddr. It is set because IRIS sets both and a machine
            // whose two copies disagree is a trap for whoever reads them next.
            seeding      <= 1'b1;
            seed_idx     <= 2'd0;
            load_pending <= 1'b0;
            state        <= S_STANDBY;
            do_out       <= 1'b1;
            write_enable <= 1'b0;
            sk_q         <= 1'b0;
            cs_q         <= 1'b0;
        end else begin
            if (seeding) begin
                wr_pend  <= 1'b1;
                wr_addr  <= 7'h7D + {5'd0, seed_idx};
                wr_data  <= (seed_idx == 2'd0) ? mac_addr[47:32]
                          : (seed_idx == 2'd1) ? mac_addr[31:16]
                          :                      mac_addr[15:0];
                seed_idx <= seed_idx + 2'd1;
                if (seed_idx == 2'd2) seeding <= 1'b0;
            end

            if (load_pending) begin
                shifter      <= mem_q;
                load_pending <= 1'b0;
            end

            if (state == S_BULK) begin
                // ERAL/WRAL, one word per clock so the array keeps its single
                // write port. Nothing the PROM does gets here, but leaving the
                // opcodes silently unimplemented would be a worse trap than
                // 128 clocks of fill.
                wr_pend   <= 1'b1;
                wr_addr   <= bulk_addr[6:0];
                wr_data   <= bulk_val;
                bulk_addr <= bulk_addr + 8'd1;
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
                        // A leading 1 opens a command; leading zeroes are
                        // ignored, which is how the part tolerates being
                        // clocked while idle.
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
                                    // The word is read at addr_now on this
                                    // edge and loaded on the next clock; it
                                    // starts shifting out on the next SK
                                    // edge, behind the dummy zero the part
                                    // emits as soon as the address lands.
                                    load_pending <= 1'b1;
                                    bit_count    <= 5'd0;
                                    do_out       <= 1'b0;
                                    state        <= S_DATA_OUT;
                                end
                                OP_WRITE: begin
                                    bit_count <= 5'd0;
                                    shifter   <= 16'd0;
                                    state     <= write_enable ? S_DATA_IN : S_IDLE;
                                end
                                OP_ERASE: begin
                                    wr_pend <= write_enable;
                                    wr_addr <= addr_now[6:0];
                                    wr_data <= 16'hFFFF;
                                    state   <= S_IDLE;
                                end
                                OP_CTRL: begin
                                    // The sub-command is the top two address
                                    // bits; the rest are don't-care.
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
                                wr_pend <= 1'b1;
                                wr_addr <= address[6:0];
                                wr_data <= data_now;
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
    end

endmodule
