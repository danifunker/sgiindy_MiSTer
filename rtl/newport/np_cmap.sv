//============================================================================
//  np_cmap - the Newport colour map, one of two.
//
//  A CI pixel leaves the frame buffer as an 8-bit index; XMAP9's mode table
//  supplies a 5-bit page above it, and the 13-bit result addresses this
//  palette. That is why the array is 8192 entries and not 256: the mode table
//  can put each window's colours on its own page.
//
//  TWO CHIPS, because Newport's pixel pipeline is two pixels wide and each
//  CMAP serves one of them. They are written together through DCB address 1
//  and separately through 2 and 3, and the PROM loads them identically - but
//  they are not interchangeable, because CMAP 1 carries the MONITOR TYPE in
//  the upper nibble of its revision register and that is what picks which of
//  np_timing.h's tables the PROM loads. See Ng1InitInfo in ng1_init.c.
//
//  THE MONITOR TYPE IS THE RESOLUTION, and reporting the wrong one does not
//  look like a configuration mistake - it looks like a broken timing
//  generator. Ng1DacInit switches on it: 10, 12 and 13 are 1280x1024 at
//  60 Hz, 9 is 1280x1024 at 72, 1/2/11 are 1280x1024 at 76, 6 is 1024x768 at
//  70. Zero is *Unknown*, and on a Guinness - which is this machine -
//  Ng1DacInit's default arm reads the `monitor` environment variable and,
//  finding nothing in a blank NVRAM, "defaults to low-res": 1024x768. This
//  model reported zero, so the PROM loaded n1024_r3, and the core faithfully
//  produced a 1024x768 raster that read as a 1280x1024 one gone wrong.
//
//  The palette is written a byte at a time - red, green, blue - and the
//  address auto-increments after blue. `rgb_ctr` is that sequencer; writing
//  either address byte, or CRS 7, resets it, which is how software recovers
//  from a partial triple.
//============================================================================

module np_cmap #(
    // 8192 is the real part. A build that never uses a mode-table page above
    // zero can cut this to 256 and lose nothing but the diagnostics.
    parameter int ENTRIES  = 8192,
    // CMAP 0: bits [2:0] revision, [6:4] board revision, [7] set = 8 planes.
    //   Board revision >= 2 with bit 7 clear is what makes hinv say 24-bit
    //   without the frame-buffer depth probe having to run.
    // CMAP 1: bits [7:4] monitor type. 10 is the 16-inch Mitsubishi, which
    //   Ng1DacInit maps to 1280x1024 at 60 Hz - the same value ~/repos/iris
    //   reports, and it boots IRIX 6.5 to a desktop on it.
    parameter logic [7:0] REVISION = 8'h02
) (
    input  logic        clk,
    input  logic        reset,

    // ---- Display Control Bus, from REX3 ----------------------------------
    input  logic        sel,          // one-cycle strobe
    input  logic        we,
    input  logic  [2:0] crs,
    input  logic  [7:0] wdata,
    output logic  [7:0] rdata,

    // ---- read port for the display, one pixel per pixel clock ------------
    input  logic [12:0] look_addr,
    output logic [23:0] look_rgb
);

    localparam int AW = $clog2(ENTRIES);

    // 0x00BBGGRR, the order the palette is written in.
    logic [23:0] palette [ENTRIES];

    logic [7:0]  addr_lo, addr_hi;
    logic [1:0]  rgb_ctr;
    logic [7:0]  red_temp, green_temp;
    logic [7:0]  command;

    wire [12:0]  paddr     = {addr_hi[4:0], addr_lo};
    wire [12:0]  paddr_inc = paddr + 13'd1;      // wraps at 13 bits, as the part does

    // ---- read ------------------------------------------------------------
    // BOTH READS OF THE PALETTE ARE REGISTERED, AND THAT IS NOT A STYLE
    // CHOICE. This array is 8192 x 24, and Quartus infers a memory only when
    // the read goes straight into a register: with `assign look_rgb =
    // palette[...]` for the display and `rd_entry = palette[...]` in an
    // always_comb for the host, both were asynchronous, both CMAPs became
    // flip-flops, and Analysis & Synthesis stopped with
    //
    //   Error (276003): Cannot convert all sets of registers into RAM
    //   megafunctions ... exceeds the number of registers in the device
    //
    // Two read ports and one write port is a shape Quartus builds by keeping
    // two copies of the memory, which is 393 Kbit of M10K per CMAP and cheap
    // against the alternative.
    //
    // The cost is a cycle on each side. The display's is absorbed by an extra
    // delay stage on the syncs in newport.sv; the host's is why the Display
    // Control Bus now waits a cycle before sampling a read - see np_rex3.sv.
    logic [23:0] rd_entry;
    logic [23:0] look_q;
    always_comb begin
        case (crs)
            3'd0:    rdata = addr_lo;
            3'd1:    rdata = addr_hi;
            3'd2:    rdata = (rgb_ctr == 2'd0) ? rd_entry[7:0]
                           : (rgb_ctr == 2'd1) ? rd_entry[15:8]
                           :                     rd_entry[23:16];
            3'd3:    rdata = command;
            // [1:0] follow the RGB sequencer; [2] is the FIFO empty flag,
            // active low, and this model has no FIFO so it reads empty.
            // [4:3] are "not half full" and "not full", both high.
            3'd4:    rdata = {3'b0, 1'b1, 1'b1, 1'b0, rgb_ctr};
            3'd5:    rdata = (rgb_ctr == 2'd0) ? red_temp : green_temp;
            3'd6:    rdata = REVISION;
            default: rdata = 8'h00;
        endcase
    end

    assign look_rgb = look_q;

    always_ff @(posedge clk) begin
        // Above the reset, so nothing sits between the array and the flop.
        look_q   <= palette[look_addr[AW-1:0]];
        rd_entry <= palette[paddr[AW-1:0]];

        if (reset) begin
            addr_lo    <= 8'h00;
            addr_hi    <= 8'h00;
            rgb_ctr    <= 2'd0;
            red_temp   <= 8'h00;
            green_temp <= 8'h00;
            command    <= 8'h00;
        end else if (sel) begin
`ifdef DCB_DEBUG
            if (ENTRIES == 8192)
                $display("[CMAP%0d] %s crs=%0d data=%02h ctr=%0d addr=%04h",
                         REVISION[7:4], we ? "WR" : "RD", crs, wdata, rgb_ctr, paddr);
`endif
            if (we) begin
                case (crs)
                    3'd0: begin addr_lo <= wdata; rgb_ctr <= 2'd0; end
                    3'd1: begin addr_hi <= wdata; rgb_ctr <= 2'd0; end
                    3'd2: begin
                        case (rgb_ctr)
                            2'd0: begin red_temp   <= wdata; rgb_ctr <= 2'd1; end
                            2'd1: begin green_temp <= wdata; rgb_ctr <= 2'd2; end
                            default: begin
                                palette[paddr[AW-1:0]] <= {wdata, green_temp, red_temp};
                                rgb_ctr <= 2'd0;
                                {addr_hi[4:0], addr_lo} <= paddr_inc;
                            end
                        endcase
                    end
                    3'd3: command <= wdata;
                    3'd7: rgb_ctr <= 2'd0;
                    default: ;
                endcase
            end else begin
                // A palette read walks the same three-byte sequence.
                if (crs == 3'd2) begin
                    if (rgb_ctr == 2'd2) begin
                        rgb_ctr <= 2'd0;
                        {addr_hi[4:0], addr_lo} <= paddr_inc;
                    end else begin
                        rgb_ctr <= rgb_ctr + 2'd1;
                    end
                end else if (crs == 3'd5 && rgb_ctr == 2'd0) begin
                    rgb_ctr <= 2'd1;
                end
            end
        end
    end

endmodule
