//============================================================================
//  np_bt445 - the Newport RAMDAC.
//
//  On a real board this carries the pixel clock PLL, the gamma table, the
//  cursor colours and the pixel read mask. Here it is a register model: the
//  PLL setting is recorded and reported back but does not change any clock,
//  because the video output side of this core runs from one pixel clock
//  enable derived from VC2's own timing table rather than from a synthesised
//  monitor clock. That is a real difference from the hardware and it is
//  written down rather than hidden - see docs/16-newport-plan.md.
//
//  The PROM reads the revision register and uses it, with the board revision,
//  to pick which of np_timing.h's three table sets to load. 0x00 keeps it on
//  the "old_fudge"/"new_fudge" tables, which are the ones IRIS is validated
//  against.
//
//  Addressing is two-level: CRS 0 selects a register within the current
//  "command register set", CRS 1..3 are the address/data ports. The PROM's
//  Bt445Set/Bt445Get macros drive it through DCB address 7.
//============================================================================

module np_bt445 #(
    parameter logic [7:0] REVISION = 8'h00
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        sel,
    input  logic        we,
    input  logic  [2:0] crs,
    input  logic  [7:0] wdata,
    output logic  [7:0] rdata,

    // Cursor colours, out to the video mixer. Index 0 is unused (transparent),
    // 1..3 are the three cursor colours a 2-bit cursor plane can name.
    output logic [23:0] curs_color1,
    output logic [23:0] curs_color2,
    output logic [23:0] curs_color3
);

    // CRS 1 is the address within the selected set, CRS 2 the data port,
    // CRS 3 the control/command port. `addr` auto-increments on data access,
    // which is how a 256-entry gamma table is loaded with one address write.
    logic  [7:0] addr;
    logic  [1:0] rgb_ctr;
    logic  [7:0] red_temp, green_temp;
    logic  [7:0] cmd;

    // Register set 0: the gamma/palette table. Set 1: control - PLL, cursor
    // colours, read mask, revision. Only the parts the PROM touches are
    // stored; the rest accept and read back so a diagnostic sees a memory.
    //
    // NEITHER ARRAY IS RESET, and that is a synthesis decision this project
    // has already paid for once. An array cleared by a reset loop cannot infer
    // as a memory block: `sgi_ds1386.sv`'s NVRAM did exactly that and cost
    // 30,430 ALUTs and 65,713 registers, more than the entire R4300i (see
    // syn/README.md). These are 8192 bits between them, so the bill would be
    // smaller, but the rule is the same and so is the fix. A RAM powers up
    // undefined on the part too; `Ng1DacInit` writes the whole gamma table
    // before anything reads it.
    logic [23:0] gamma  [256];
    logic  [7:0] ctrl   [256];

    localparam logic [7:0] CTRL_PLL_CTRL = 8'h05;   // RDAC_PLL_CTRL
    localparam logic [7:0] CTRL_REVISION = 8'h20;   // RDAC_REV_REG

    // Which set the address port refers to. Set by CRS 3.
    logic set_is_ctrl;

    // REGISTERED, one cycle after `sel`, like every other chip on this bus -
    // see np_xmap9.sv. Hoisting the two array reads above the reset also keeps
    // the gamma table and the control space out of flip-flops; they are only
    // 8 Kbit between them, which is not what broke the first synthesis, but it
    // is 8 Kbit that has no business being registers.
    logic [23:0] rd_gamma;
    logic  [7:0] rd_ctrl;
    logic  [7:0] rdata_c;
    always_ff @(posedge clk) begin
        rd_gamma <= gamma[addr];
        rd_ctrl  <= ctrl[addr];
        rdata    <= rdata_c;
    end

    always_comb begin
        case (crs)
            3'd0: rdata_c = cmd;
            3'd1: rdata_c = addr;
            3'd2: rdata_c = set_is_ctrl
                          ? ((addr == CTRL_REVISION) ? REVISION : rd_ctrl)
                          : ((rgb_ctr == 2'd0) ? rd_gamma[7:0]
                          :  (rgb_ctr == 2'd1) ? rd_gamma[15:8]
                          :                      rd_gamma[23:16]);
            3'd3: rdata_c = {7'b0, set_is_ctrl};
            default: rdata_c = 8'h00;
        endcase
    end

    // Nine fixed indices, which synthesises as nine registers rather than as a
    // memory read - that is correct and does not stop the array inferring.
    assign curs_color1 = {ctrl[8'h13], ctrl[8'h12], ctrl[8'h11]};
    assign curs_color2 = {ctrl[8'h16], ctrl[8'h15], ctrl[8'h14]};
    assign curs_color3 = {ctrl[8'h19], ctrl[8'h18], ctrl[8'h17]};

    always_ff @(posedge clk) begin
        if (reset) begin
            addr        <= 8'h00;
            rgb_ctr     <= 2'd0;
            red_temp    <= 8'h00;
            green_temp  <= 8'h00;
            cmd         <= 8'h00;
            set_is_ctrl <= 1'b0;
        end else if (sel) begin
            if (we) begin
                case (crs)
                    3'd0: cmd <= wdata;
                    3'd1: begin addr <= wdata; rgb_ctr <= 2'd0; end
                    3'd2: begin
                        if (set_is_ctrl) begin
                            ctrl[addr] <= wdata;
                            addr <= addr + 8'd1;
                        end else begin
                            case (rgb_ctr)
                                2'd0: begin red_temp   <= wdata; rgb_ctr <= 2'd1; end
                                2'd1: begin green_temp <= wdata; rgb_ctr <= 2'd2; end
                                default: begin
                                    gamma[addr] <= {wdata, green_temp, red_temp};
                                    rgb_ctr <= 2'd0;
                                    addr    <= addr + 8'd1;
                                end
                            endcase
                        end
                    end
                    3'd3: begin set_is_ctrl <= wdata[0]; rgb_ctr <= 2'd0; end
                    default: ;
                endcase
            end else if (crs == 3'd2) begin
                if (set_is_ctrl) begin
                    addr <= addr + 8'd1;
                end else if (rgb_ctr == 2'd2) begin
                    rgb_ctr <= 2'd0;
                    addr    <= addr + 8'd1;
                end else begin
                    rgb_ctr <= rgb_ctr + 2'd1;
                end
            end
        end
    end

endmodule
