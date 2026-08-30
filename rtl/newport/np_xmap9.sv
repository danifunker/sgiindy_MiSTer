//============================================================================
//  np_xmap9 - the Newport cross-map, one of two.
//
//  XMAP9 decides how to READ a frame buffer word. Its 32-entry mode table is
//  indexed by the 5-bit display ID that VC2 emits for the pixel, and the entry
//  says whether the pixel is a colour index or packed RGB, how many bits of
//  the word it occupies, and which 256-colour page of CMAP an index lands on.
//
//  THE REVISION REGISTER IS WHAT MAKES THIS BOARD "Indy 24-bit". XL8 answers
//  1 here and XL24 answers 3; nothing else in the probe path distinguishes
//  them. See Ng1XmapInit and ng1_install in ng1_init.c.
//
//  Two chips for the two-pixel pipeline, as with CMAP. DCB address 4 writes
//  both, 5 and 6 write one each.
//============================================================================

module np_xmap9 #(
    parameter logic [7:0] REVISION = 8'd3      // 3 = XL24, 1 = XL8
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        sel,
    input  logic        we,
    input  logic  [2:0] crs,
    // The mode-table write is 32 bits: address in [31:24], data in [23:0].
    // Every other register is a byte, and the DCB delivers it in [7:0].
    input  logic [31:0] wdata,
    output logic  [7:0] rdata,

    // ---- read port for the display ---------------------------------------
    input  logic  [4:0] look_did,
    output logic [23:0] look_mode,

    // The colour map page the CURSOR's two bits index, register 3. The cursor
    // does not take its colours from the RAMDAC's cursor registers - those are
    // the BT445's own hardware cursor, which Newport does not use - it indexes
    // CMAP at (this << 5) | value. See np_vc2.sv and IRIS's compositor.rs.
    output logic  [7:0] curs_cmap
);

    logic  [7:0] config_reg;
    logic  [7:0] curs_cmap_msb;
    logic  [7:0] pup_cmap_msb;
    logic  [7:0] mode_addr;
    logic [23:0] mode_table [32];

    // MODE_ADDR selects an entry in [6:2] and a byte of it in [1:0], so a
    // diagnostic can read the table back one byte at a time.
    wire [4:0] rd_entry = mode_addr[6:2];
    wire [1:0] rd_byte  = mode_addr[1:0];

    // REGISTERED, one cycle after `sel`, the same as every other chip on this
    // bus. The mode table is small enough to have stayed combinational, but a
    // Display Control Bus where some chips answer immediately and others a
    // cycle later needs two rules in the sequencer instead of one, and the one
    // that reads the wrong chip late is a bug nobody would find twice.
    logic [7:0] rdata_c;
    always_ff @(posedge clk) rdata <= rdata_c;

    always_comb begin
        case (crs)
            3'd0:    rdata_c = config_reg;
            3'd1:    rdata_c = REVISION;
            // FIFO fill level. 2 = three entries free, the reset value; this
            // model has no FIFO and xmap9FIFOWait only needs a non-full answer.
            3'd2:    rdata_c = 8'd2;
            3'd3:    rdata_c = curs_cmap_msb;
            3'd4:    rdata_c = pup_cmap_msb;
            3'd5:    rdata_c = (rd_byte == 2'd0) ? mode_table[rd_entry][7:0]
                           : (rd_byte == 2'd1) ? mode_table[rd_entry][15:8]
                           : (rd_byte == 2'd2) ? mode_table[rd_entry][23:16]
                           :                     8'h00;
            3'd7:    rdata_c = mode_addr;
            default: rdata_c = 8'h00;
        endcase
    end

    assign look_mode = mode_table[look_did];
    assign curs_cmap = curs_cmap_msb;

    integer i;
    always_ff @(posedge clk) begin
        if (reset) begin
            config_reg    <= 8'h00;
            curs_cmap_msb <= 8'h00;
            pup_cmap_msb  <= 8'h00;
            mode_addr     <= 8'h00;
            for (i = 0; i < 32; i = i + 1) mode_table[i] <= 24'h0;
        end else if (sel && we) begin
            case (crs)
                3'd0: config_reg    <= wdata[7:0];
                3'd3: curs_cmap_msb <= wdata[7:0];
                3'd4: pup_cmap_msb  <= wdata[7:0];
                // The mode table write is the one 32-bit transfer XMAP9
                // takes: address in [28:24], entry data in [23:0]. Every other
                // register is a byte, and the DCB delivers it in [7:0].
                3'd5: mode_table[wdata[28:24]] <= wdata[23:0];
                3'd7: mode_addr     <= wdata[7:0];
                default: ;
            endcase
        end
    end

endmodule
