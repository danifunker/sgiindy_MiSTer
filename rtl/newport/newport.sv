//============================================================================
//  newport - the Indy's graphics board: REX3, VC2, two XMAP9s, two CMAPs and
//  a BT445 RAMDAC, on GIO64 at 0x1F000000.
//
//  Only REX3 is on the bus. Everything else hangs off the Display Control Bus
//  that REX3 masters, so this module is mostly wiring plus the pixel readout
//  path, which is the one thing no chip here owns on its own:
//
//    VC2 says which pixel and when  ->  frame buffer read port
//    XMAP9's mode table says how to read the word it returns
//    CMAP turns a colour index into 24 bits of colour
//
//  TWO FRAME BUFFER PORTS, and that is not a shortcut. Newport's frame buffer
//  is VRAM: a random port the rasteriser writes and a serial port the display
//  clocks out, at the same time. Modelling one port with an arbiter would be
//  less like the hardware, not more, and would put every drawn pixel behind
//  the display's bandwidth.
//
//  THE WINDOW READS ZERO WHERE NOTHING IS FITTED. 0x1F000000-0x1F0EFFFF is
//  the graphics low window and nothing in this core answers there, but it must
//  not fall through to an unclaimed cycle: an unclaimed read answers all ones,
//  and REX3's STATUS reads busy forever if it does. See sgi_indy.sv.
//============================================================================

module newport #(
    parameter logic [31:0] FB_BASE        = 32'h0000_0000,
    parameter int          FB_STRIDE_LOG2 = 11,
    parameter int          FB_LINES       = 1024,
    parameter int          VC2_RAM_WORDS  = 32768,
    // Core clocks per pixel out of the video timing generator.
    //
    // TWO, AND THE DOUBLING TO ONE WAS NOT FREE AFTER ALL. It was two so that
    // the frame buffer read port was not asked for a word every single clock;
    // it went to one on the argument that rtl/mister/fb_linecache.sv had put a
    // scanline of block RAM in front of it, so the port no longer cared. That
    // argument is wrong, and a DE10-Nano is what said so. The line cache moves
    // WHEN the words are needed, not HOW MANY: a visible line is still
    // LINE_WORDS 64-bit words and it still has one line time to arrive.
    //
    // At one clock per pixel that is 0.80 words a clock, against a MiSTer DDR3
    // port whose absolute peak is 1.00 - eighty per cent of the bus for the
    // display alone, before the CPU or the rasteriser ask for anything. The
    // hardware delivered 0.52 and missed the first 710 pixels of every line,
    // for ever, and the screen was black.
    //
    // THE RASTER'S GEOMETRY DOES NOT CHANGE EITHER WAY - the timing table's
    // durations are in units of two pixel clocks - so this decides when the
    // pixels come out and not which ones. What it costs is the frame rate:
    // about 14 Hz rather than 27. The way back to one is to stop fetching
    // eight bytes per pixel to use one of them; see fb_linecache.sv's header
    // and docs/18-mister-integration.md.
    parameter int          PIX_DIV        = 2
) (
    input  logic        clk,
    input  logic        reset,

    // ---- GIO64 slave, from sgi_indy ---------------------------------------
    input  logic        sel,            // one-cycle pulse, address in window
    input  logic        we,
    input  logic [19:0] addr,           // offset into the 1 MB window
    input  logic  [2:0] aoff,           // which word of the doubleword
    input  logic  [7:0] be,
    input  logic [63:0] wdata,
    output logic [63:0] rdata,
    output logic        ack,

    // ---- frame buffer: the rasteriser's random port -----------------------
    output logic        fbw_req,
    output logic        fbw_we,
    output logic [31:0] fbw_addr,
    output logic [63:0] fbw_wdata,
    output logic  [7:0] fbw_be,
    input  logic [63:0] fbw_rdata,
    input  logic        fbw_ack,

    // ---- frame buffer: the display's serial port --------------------------
    output logic        fbr_req,
    output logic [31:0] fbr_addr,
    input  logic [63:0] fbr_rdata,
    input  logic        fbr_ack,

    // ---- video out ---------------------------------------------------------
    output logic        ce_pix,
    output logic        hsync,
    output logic        vsync,
    output logic        de,
    output logic  [7:0] vid_r,
    output logic  [7:0] vid_g,
    output logic  [7:0] vid_b,

    output logic        gfx_irq,        // REX3's vertical retrace interrupt

    // ---- bring-up instrument, not a feature ------------------------------
    // On hardware the screen came up black with a perfect raster, and a black
    // screen has two causes that look identical from outside: the frame buffer
    // read returning nothing, or the palette answering black for every index.
    // Nothing observable distinguishes them, so this takes CMAP out of the
    // path and shows the frame buffer's own colour index as grey. Then a
    // pattern written into the frame buffer either appears or does not, and
    // the two halves of the display path are finally separable.
    input  logic        dbg_raw_index
);

    // ---- register window ---------------------------------------------------
    // REX3 is 8 KB at 0x1F0F0000, which is offset 0xF0000 into the window -
    // not 0xF000. Getting that wrong makes every REX3 access fall into the
    // "reads zero" path, and Ng1Probe then sees a board whose XSTART will not
    // read back what was written to XSTARTI.
    localparam logic [19:0] REX3_LO = 20'hF0000;
    localparam logic [19:0] REX3_HI = 20'hF2000;

    wire in_rex3 = (addr >= REX3_LO) && (addr < REX3_HI);

    // REX3's registers are 32 bits on a stride of four, so the doubleword the
    // CPU presented has to be split. `aoff[2]` is the only thing that can say
    // which word a read addressed - byte enables are meaningless on a read.
    // See rtl/cpu/r4300_bus.sv.
    wire        hi_word = ~aoff[2];
    wire [12:0] r3_off  = {addr[12:3], aoff[2], 2'b00};
    wire [31:0] r3_wdata = aoff[2] ? wdata[31:0] : wdata[63:32];
    // The four byte enables belonging to that word, [3] the most significant.
    // `be[7-i]` guards byte i of the doubleword, so the high word's lanes are
    // be[7:4] and the low word's are be[3:0]. REX3 needs them for exactly one
    // register - DCBDATA0, whose datum has to be re-aligned to the top of the
    // word before the Display Control Bus shifts it out. See np_rex3.sv.
    wire  [3:0] r3_be   = aoff[2] ? be[3:0] : be[7:4];

    logic [31:0] r3_rdata;
    logic        r3_ack;
    wire         r3_sel = sel && in_rex3;

    // Mirror the 32-bit answer into both halves so the read shift in
    // r4300_bus lands on it whichever word was addressed.
    assign rdata = r3_ack ? {r3_rdata, r3_rdata} : 64'h0;
    assign ack   = r3_ack | gfx_hole_ack;

    // Anything in the window that is not REX3 answers zero, one cycle later.
    logic gfx_hole_ack;
    always_ff @(posedge clk) begin
        gfx_hole_ack <= !reset && sel && !in_rex3;
    end

    // ---- Display Control Bus ------------------------------------------------
    logic        dcb_sel, dcb_we;
    logic  [3:0] dcb_addr;
    logic  [2:0] dcb_crs;
    logic  [1:0] dcb_width;
    logic [31:0] dcb_wdata;
    logic [31:0] dcb_rdata;

    // DCB chip addresses, from the Newport board's wiring: 0 VC2, 1 both
    // CMAPs, 2 and 3 one each, 4 both XMAPs, 5 and 6 one each, 7 the RAMDAC.
    wire vc2_sel   = dcb_sel && (dcb_addr == 4'd0);
    wire cmap0_sel = dcb_sel && (dcb_addr == 4'd1 || dcb_addr == 4'd2);
    wire cmap1_sel = dcb_sel && (dcb_addr == 4'd1 || dcb_addr == 4'd3);
    wire xmap0_sel = dcb_sel && (dcb_addr == 4'd4 || dcb_addr == 4'd5);
    wire xmap1_sel = dcb_sel && (dcb_addr == 4'd4 || dcb_addr == 4'd6);
    wire dac_sel   = dcb_sel && (dcb_addr == 4'd7);

    logic [15:0] vc2_rdata;
    logic  [7:0] cmap0_rdata, cmap1_rdata, xmap0_rdata, xmap1_rdata, dac_rdata;

    // A read of a paired address answers from chip 0; the PROM only reads the
    // pair to fetch a revision, and both chips have their own address for
    // when it wants the other one.
    always_comb begin
        case (dcb_addr)
            4'd0:    dcb_rdata = {16'h0, vc2_rdata};
            4'd1,
            4'd2:    dcb_rdata = {24'h0, cmap0_rdata};
            4'd3:    dcb_rdata = {24'h0, cmap1_rdata};
            4'd4,
            4'd5:    dcb_rdata = {24'h0, xmap0_rdata};
            4'd6:    dcb_rdata = {24'h0, xmap1_rdata};
            4'd7:    dcb_rdata = {24'h0, dac_rdata};
            default: dcb_rdata = 32'h0;
        endcase
    end

    // ---- video timing --------------------------------------------------------
    logic        vc2_hsync, vc2_vsync, vc2_de, vc2_hblank, vc2_vblank, vc2_vint;
    logic [10:0] vc2_x, vc2_y;

    np_vc2 #(.RAM_WORDS(VC2_RAM_WORDS), .PIX_DIV(PIX_DIV)) u_vc2 (
        .clk    (clk),
        .reset  (reset),
        .sel    (vc2_sel),
        .we     (dcb_we),
        .crs    (dcb_crs[1:0]),
        .width  (dcb_width),
        .wdata  (dcb_wdata),
        .rdata  (vc2_rdata),
        .ce_pix (ce_pix),
        .hsync  (vc2_hsync),
        .vsync  (vc2_vsync),
        .de     (vc2_de),
        .hblank (vc2_hblank),
        .vblank (vc2_vblank),
        .pix_x  (vc2_x),
        .pix_y  (vc2_y),
        .vert_int (vc2_vint),
        .cursor_pix (vc2_cursor)
    );

    // ---- the rasteriser --------------------------------------------------------
    np_rex3 #(
        .FB_STRIDE_LOG2 (FB_STRIDE_LOG2),
        .FB_LINES       (FB_LINES),
        .FB_BASE        (FB_BASE)
    ) u_rex3 (
        .clk       (clk),
        .reset     (reset),
        .sel       (r3_sel),
        .we        (we),
        .off       (r3_off),
        .wdata     (r3_wdata),
        .be        (r3_be),
        .rdata     (r3_rdata),
        .ack       (r3_ack),
        .dcb_sel   (dcb_sel),
        .dcb_we    (dcb_we),
        .dcb_addr  (dcb_addr),
        .dcb_crs   (dcb_crs),
        .dcb_width (dcb_width),
        .dcb_wdata (dcb_wdata),
        .dcb_rdata (dcb_rdata),
        .fb_req    (fbw_req),
        .fb_we     (fbw_we),
        .fb_addr   (fbw_addr),
        .fb_wdata  (fbw_wdata),
        .fb_be     (fbw_be),
        .fb_rdata  (fbw_rdata),
        .fb_ack    (fbw_ack),
        .vert_int  (vc2_vint),
        .gfx_busy  ()
    );

    // ---- the display chain -----------------------------------------------------
    logic  [4:0] did;
    logic  [1:0] vc2_cursor, cursor_q;
    logic  [7:0] xmap0_curs_cmap;
    logic [23:0] xmap0_mode, xmap1_mode;
    logic [12:0] cmap_index;
    logic [23:0] cmap0_rgb, cmap1_rgb;

    // The display ID selects a mode-table entry per pixel. The DID generator
    // is not built; the PROM loads a table that says "entry 0 for the whole
    // scanline", so a constant zero is what that table would produce.
    assign did = 5'd0;

    np_xmap9 #(.REVISION(8'd3)) u_xmap0 (
        .clk (clk), .reset (reset),
        .sel (xmap0_sel), .we (dcb_we), .crs (dcb_crs),
        .wdata (dcb_wdata), .rdata (xmap0_rdata),
        .look_did (did), .look_mode (xmap0_mode), .curs_cmap (xmap0_curs_cmap)
    );
    np_xmap9 #(.REVISION(8'd3)) u_xmap1 (
        .clk (clk), .reset (reset),
        .sel (xmap1_sel), .we (dcb_we), .crs (dcb_crs),
        .wdata (dcb_wdata), .rdata (xmap1_rdata),
        .look_did (did), .look_mode (xmap1_mode), .curs_cmap ()
    );

    // CMAP 0's revision carries the board revision in [6:4] and the frame
    // buffer depth in [7] - clear for 24 planes. Board revision 4 keeps
    // ng1_init.c's getfbdepth out of the "must probe" path while still
    // selecting a timing table set that exists.
    // CMAP 1's revision carries the MONITOR TYPE in [7:4], and that number is
    // the resolution: Ng1DacInit switches on it to pick which of
    // np_timing.h's tables to load. 10 is the 16-inch Mitsubishi at
    // 1280x1024 60 Hz, which is what ~/repos/iris reports. Zero means
    // "unknown", and on a Guinness that is not a harmless default - the PROM
    // falls back to 1024x768 and the machine comes up at the wrong
    // resolution with nothing on the console to say that it did.
    np_cmap #(.REVISION(8'h42)) u_cmap0 (
        .clk (clk), .reset (reset),
        .sel (cmap0_sel), .we (dcb_we), .crs (dcb_crs),
        .wdata (dcb_wdata[7:0]), .rdata (cmap0_rdata),
        .look_addr (cmap_index), .look_rgb (cmap0_rgb)
    );
    np_cmap #(.REVISION(8'hA2)) u_cmap1 (
        .clk (clk), .reset (reset),
        .sel (cmap1_sel), .we (dcb_we), .crs (dcb_crs),
        .wdata (dcb_wdata[7:0]), .rdata (cmap1_rdata),
        .look_addr (cmap_index), .look_rgb (cmap1_rgb)
    );

    np_bt445 u_dac (
        .clk (clk), .reset (reset),
        .sel (dac_sel), .we (dcb_we), .crs (dcb_crs),
        .wdata (dcb_wdata[7:0]), .rdata (dac_rdata),
        .curs_color1 (), .curs_color2 (), .curs_color3 ()
    );

    // ---- pixel readout ----------------------------------------------------------
    // One read per pixel out of the serial port. A real board clocks a whole
    // scanline out of the VRAM shift register at once; a line buffer here
    // would do the same job and cost a block RAM, and is the obvious change
    // if this port ever becomes the bottleneck.
    logic [63:0] pix_word;
    logic        pix_valid;

    assign fbr_req  = ce_pix && vc2_de;
    assign fbr_addr = FB_BASE
                    + (((({21'b0, vc2_y}) << FB_STRIDE_LOG2) + {21'b0, vc2_x}) << 3);

    always_ff @(posedge clk) begin
        if (reset) begin
            pix_word  <= 64'h0;
            pix_valid <= 1'b0;
        end else if (fbr_ack) begin
            pix_word  <= fbr_rdata;
            pix_valid <= 1'b1;
        end
    end

    // THE CURSOR IS ONE STAGE AHEAD AND HAS TO BE HELD BACK. It is generated
    // from VC2's own counters, which is where the frame buffer ADDRESS comes
    // from; the word for that address arrives a cycle later. Combining them
    // without this register puts the pointer one pixel left of everything it
    // is drawn over, which is exactly the kind of thing that survives a glance.
    always_ff @(posedge clk) begin
        if (reset)        cursor_q <= 2'd0;
        else if (ce_pix)  cursor_q <= vc2_cursor;
    end

    // The mode table entry: [1] overlay enable, [7:3] colour map page,
    // [9:8] pixel mode (0 = colour index), [11:10] pixel size.
    wire  [1:0] pix_mode = xmap0_mode[9:8];
    wire  [1:0] pix_size = xmap0_mode[11:10];
    wire  [4:0] cmap_msb = xmap0_mode[7:3];
    wire [23:0] fb_rgb   = pix_word[23:0];

    // 12bpp indexes only the top page of the map; every other index size uses
    // the mode table's page directly.
    // THE CURSOR TAKES PRIORITY OVER THE PIXEL UNDER IT, and it indexes the
    // map somewhere else entirely: (XMAP's cursor page << 5) | its two bits,
    // which is what IRIS's compositor does. Zero is transparent, so a cursor
    // that is off, or off this pixel, changes nothing.
    wire [12:0] cmap_index_fb = (pix_size == 2'd2)
                              ? {cmap_msb[4], 12'h0} | {5'b0, fb_rgb[7:0]}
                              : {cmap_msb, fb_rgb[7:0]};
    assign cmap_index = (cursor_q != 2'd0)
                      ? {xmap0_curs_cmap, 5'b0} | {11'b0, cursor_q}
                      : cmap_index_fb;

    logic [23:0] pix_rgb;
    always_comb begin
        if (dbg_raw_index) begin
            // The index itself, as grey - and the cursor as white, so that the
            // debug view does not report a pointer-shaped hole.
            pix_rgb = (cursor_q != 2'd0) ? 24'hFFFFFF : {3{fb_rgb[7:0]}};
        end else if (pix_mode == 2'd0) begin
            // Colour index: 0x00BBGGRR out of the map.
            pix_rgb = cmap0_rgb;
        end else begin
            // Packed RGB straight out of the frame buffer.
            pix_rgb = {fb_rgb[7:0], fb_rgb[15:8], fb_rgb[23:16]};
        end
    end

    assign vid_r = de ? pix_rgb[7:0]   : 8'h00;
    assign vid_g = de ? pix_rgb[15:8]  : 8'h00;
    assign vid_b = de ? pix_rgb[23:16] : 8'h00;

    // TWO STAGES, NOT ONE, and the second one is CMAP's. The pixel is one read
    // behind the timing generator - that is the frame buffer - and now one
    // more behind it again, because the palette lookup had to become a
    // registered read for the array to infer as M10K rather than as 393 Kbit
    // of flip-flops (see np_cmap.sv). The syncs are delayed to match rather
    // than the data being pushed forward, so the picture moves as a whole.
    //
    // Getting this wrong is a one-pixel horizontal shift of the entire image,
    // which is exactly the kind of thing that survives a glance and fails
    // tests/run-rex3.sh's replay.
    logic hs_d, vs_d, de_d;
    logic hs_q, vs_q, de_q;
    always_ff @(posedge clk) begin
        if (reset) begin
            hs_d <= 1'b0; vs_d <= 1'b0; de_d <= 1'b0;
            hs_q <= 1'b0; vs_q <= 1'b0; de_q <= 1'b0;
        end else if (ce_pix) begin
            hs_d <= vc2_hsync; vs_d <= vc2_vsync; de_d <= vc2_de;
            hs_q <= hs_d;      vs_q <= vs_d;      de_q <= de_d;
        end
    end
    assign hsync = hs_q;
    assign vsync = vs_q;
    assign de    = de_q;

    assign gfx_irq = vc2_vint;

endmodule
