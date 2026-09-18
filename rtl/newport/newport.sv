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
    // about 14 Hz at two rather than 27 at one.
    //
    // ONE AGAIN, AND THIS TIME THE FETCH WAS HALVED FIRST: the frame buffer is
    // two plane sets of four bytes a pixel, the display fetches the drawing
    // planes at 0.39 words a clock and the auxiliary planes only on lines
    // that hold something (fb_linecache.sv's TRACK_ZERO). tb_linecache.cpp
    // is built with the same PIX_DIV and must keep passing at it.
    parameter int          PIX_DIV        = 1
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

    // ---- the MC's VDMA beats, 64 bits at a time ---------------------------
    // Held-until-ack, from sgi_indy's routing of the DMA engine's GIO master.
    // Only REX3 answers; the rest of the window acks and drops, for the same
    // reason the CPU window does - nothing may wedge on an unanswered cycle.
    input  logic        nd_req,
    input  logic        nd_we,
    input  logic [19:0] nd_addr,      // offset into the 1 MB window
    input  logic [63:0] nd_wdata,
    output logic [63:0] nd_rdata,
    output logic        nd_ack,

    // ---- frame buffer: the rasteriser's random port -----------------------
    output logic        fbw_req,
    output logic        fbw_we,
    output logic [31:0] fbw_addr,
    output logic [63:0] fbw_wdata,
    output logic  [7:0] fbw_be,
    input  logic [63:0] fbw_rdata,
    input  logic        fbw_ack,

    // ---- frame buffer: the display's serial ports -------------------------
    // One per plane set: `fbr` reads the drawing planes, `fba` the auxiliary
    // planes 8 MB above them. Both answer a cycle after the request.
    output logic        fbr_req,
    output logic [31:0] fbr_addr,
    input  logic [63:0] fbr_rdata,
    input  logic        fbr_ack,
    output logic        fba_req,
    output logic [31:0] fba_addr,
    input  logic [63:0] fba_rdata,
    input  logic        fba_ack,
    // The rasteriser wrote something visible into the auxiliary planes of
    // this line - for the per-line flag table in front of `fba` on MiSTer.
    output logic        aux_mark,
    output logic [10:0] aux_mark_line,

    // ---- video out ---------------------------------------------------------
    output logic        ce_pix,
    output logic        hsync,
    output logic        vsync,
    output logic        de,
    output logic  [7:0] vid_r,
    output logic  [7:0] vid_g,
    output logic  [7:0] vid_b,

    output logic        gfx_irq,        // REX3's vertical retrace interrupt
    // The vertical retrace line for INT2 LOCAL1 bit 7: REX3's VRINT latch,
    // set at each retrace and held until the CPU reads STATUS - the read is
    // what deasserts the line, in IRIS and MAME both. NOT the raw vblank
    // timing level: build 12 wired that here and the un-retirable interrupt
    // starved the whole machine (docs/design/newport-vdma.md).
    output logic        vblank_irq,
    output logic [31:0] dbg_nd,       // np_rex3's VDMA beat counters
    // The display-interpretation beacon word (docs/design/newport-vdma.md): the live DID and the
    // mode entry the visible pixel is being read through, plus the walker
    // state - a sampled answer to "what is the screen being decoded AS".
    output logic [63:0] dbg_disp,

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
    //
    // A DOUBLEWORD STORE IS TWO REGISTER WRITES AND ONE GO. GL writes REX3's
    // registers in pairs with 64-bit `sdc1` stores - XYSTARTI+XYENDI,
    // XSTARTF+YSTARTF, XSTARTI+XENDF1 with GO, the colour and slope pairs,
    // HOSTRW0+HOSTRW1 with GO: 215 of them between libGLcore.so and libgl.so,
    // none in the X server (docs/design/rex3-source-audit.md 3.1, 4.4, 4.6). The Indy really sends them
    // as single 64-bit transfers - the kernel sets the MC's GRX_SIZE_64 and
    // CONFIG.BUSWIDTH - and REX3 takes a whole transfer as one GFIFO entry
    // (GF_DATA 63:0, GF_D32 marking the 32-bit ones, one GF_GO), so the even
    // register gets bits 63:32, the odd one 31:0, and the primitive starts
    // after both. IRIS's write64 and MAME's rex3_w do exactly that.
    //
    // This used to keep the even word and drop the odd one - and because the
    // GO bit is address bit 11, which the even word's offset carried, the GO
    // fired with the second register stale: XYSTARTI+XYENDI|GO drew to the
    // PREVIOUS end point. That is the whole of "GL draws things it
    // shouldn't".
    //
    // So a store with bytes in both words becomes two beats into np_rex3's
    // 32-bit port: the even register with the GO stripped, then the odd one
    // carrying the address's own GO. The first beat's acknowledgement stays
    // here; the CPU is acknowledged by the second. The second beat is issued
    // in the very cycle the first is acknowledged, so there is no cycle in
    // which np_rex3 sees neither - and it refuses a VDMA beat in any cycle
    // that carries a CPU write, so nothing can land between the halves.
    // Loads are untouched: nothing in IRIX, X or GL issues a doubleword load
    // to REX3, and the bus does not carry a load's size.
    wire        dword_st = we && (|be[7:4]) && (|be[3:0]);

    typedef enum logic [0:0] { DW_IDLE, DW_ODD } dw_state_t;
    dw_state_t   dw;
    logic [12:0] dw_off;        // the odd register's offset, GO included
    logic [31:0] dw_data;
    logic  [3:0] dw_be;

    logic [31:0] r3_rdata;
    logic        r3_ack;
    wire         r3_first = sel && in_rex3;               // a CPU access arrives
    wire         r3_second = (dw == DW_ODD) && r3_ack;    // its even half is done

    logic        r3_sel;
    logic [12:0] r3_off;
    logic [31:0] r3_wdata;
    // The four byte enables belonging to that word, [3] the most significant.
    // `be[7-i]` guards byte i of the doubleword, so the high word's lanes are
    // be[7:4] and the low word's are be[3:0]. REX3 needs them for exactly one
    // register - DCBDATA0, whose datum has to be re-aligned to the top of the
    // word before the Display Control Bus shifts it out. See np_rex3.sv.
    logic  [3:0] r3_be;
    always_comb begin
        r3_sel = r3_first || r3_second;
        if (r3_second) begin
            r3_off   = dw_off;
            r3_wdata = dw_data;
            r3_be    = dw_be;
        end else if (dword_st) begin
            r3_off   = {addr[12], 1'b0, addr[10:3], 3'b000};
            r3_wdata = wdata[63:32];
            r3_be    = be[7:4];
        end else begin
            r3_off   = {addr[12:3], aoff[2], 2'b00};
            r3_wdata = aoff[2] ? wdata[31:0] : wdata[63:32];
            r3_be    = aoff[2] ? be[3:0] : be[7:4];
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            dw <= DW_IDLE;
        end else if (r3_first && dword_st) begin
            dw      <= DW_ODD;
            dw_off  <= {addr[12:3], 3'b100};
            dw_data <= wdata[31:0];
            dw_be   <= be[3:0];
        end else if (r3_second) begin
            dw <= DW_IDLE;
        end
    end

    // Mirror the 32-bit answer into both halves so the read shift in
    // r4300_bus lands on it whichever word was addressed. The even half of a
    // doubleword store is acknowledged to this module, not to the CPU.
    assign rdata = r3_ack ? {r3_rdata, r3_rdata} : 64'h0;
    assign ack   = (r3_ack && (dw != DW_ODD)) | gfx_hole_ack;

    // Anything in the window that is not REX3 answers zero, one cycle later.
    logic gfx_hole_ack;
    always_ff @(posedge clk) begin
        gfx_hole_ack <= !reset && sel && !in_rex3;
    end

    // ---- the VDMA port's decode -------------------------------------------
    // Beats inside REX3's 8 KB go to its host port; the rest of the window
    // acks and drops. `!nd_hole_ack` keeps the master's request-drop cycle
    // from double-answering, the same shape as np_rex3's own guard.
    wire nd_in_rex3 = (nd_addr >= REX3_LO) && (nd_addr < REX3_HI);

    logic [63:0] nd_r3_rdata;
    logic        nd_r3_ack;
    logic        nd_hole_ack;
    always_ff @(posedge clk)
        nd_hole_ack <= !reset && nd_req && !nd_in_rex3 && !nd_hole_ack;

    assign nd_rdata = nd_r3_ack ? nd_r3_rdata : 64'h0;
    assign nd_ack   = nd_r3_ack | nd_hole_ack;

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
    // VC2's pixel enable, undelayed: what the frame buffer fetch runs on. The
    // `ce_pix` port is this, delayed to match the colour (see the syncs).
    logic        vc2_ce;
    logic [10:0] vc2_x, vc2_y;
    logic  [3:0] vc2_dbg_did;

    np_vc2 #(.RAM_WORDS(VC2_RAM_WORDS), .PIX_DIV(PIX_DIV)) u_vc2 (
        .clk    (clk),
        .reset  (reset),
        .sel    (vc2_sel),
        .we     (dcb_we),
        .crs    (dcb_crs[1:0]),
        .width  (dcb_width),
        .wdata  (dcb_wdata),
        .rdata  (vc2_rdata),
        .ce_pix (vc2_ce),
        .hsync  (vc2_hsync),
        .vsync  (vc2_vsync),
        .de     (vc2_de),
        .hblank (vc2_hblank),
        .vblank (vc2_vblank),
        .pix_x  (vc2_x),
        .pix_y  (vc2_y),
        .vert_int (vc2_vint),
        .cursor_pix (vc2_cursor),
        .did      (vc2_did),
        .dbg_did  (vc2_dbg_did)
    );

    // ---- the rasteriser --------------------------------------------------------
    logic r3_vrint;
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
        .nd_req    (nd_req && nd_in_rex3),
        .nd_we     (nd_we),
        .nd_off    (nd_addr[12:0]),
        .nd_wdata  (nd_wdata),
        .nd_rdata  (nd_r3_rdata),
        .nd_ack    (nd_r3_ack),
        .dbg_nd    (dbg_nd),
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
        .aux_mark      (aux_mark),
        .aux_mark_line (aux_mark_line),
        .vert_int  (vc2_vint),
        .gfx_busy  (),
        .vrint_irq (r3_vrint)
    );

    // ---- the display chain -----------------------------------------------------
    logic  [4:0] vc2_did, did_q;
    logic  [1:0] vc2_cursor, cursor_q;
    logic  [7:0] xmap0_curs_cmap, xmap0_pup_cmap;
    logic [23:0] xmap0_mode, xmap1_mode;
    logic [12:0] cmap_index;
    logic [23:0] cmap0_rgb, cmap1_rgb;

    // The display ID selects a mode-table entry per pixel. It comes from
    // VC2's DID table walker - the per-window mechanism X uses to give every
    // window its own pixel mode. It is delayed TWO pixels, exactly as the
    // cursor is, so it pairs with the frame buffer word it describes: the
    // frame buffer answers the cycle after the request and `slot_rgb`
    // registers that answer, so the word for the address VC2 emits in cycle
    // t is in `slot_rgb` in cycle t+2. See "THE PIXEL IS TWO CYCLES BEHIND"
    // at the syncs below.
    //
    // Two CLOCKS, not two pixel enables - see "THE DELAYS ARE CLOCKS" at the
    // syncs below.
    logic [4:0] did_q1;
    always_ff @(posedge clk) begin
        if (reset) begin did_q1 <= 5'd0; did_q <= 5'd0; end
        else       begin did_q1 <= vc2_did; did_q <= did_q1; end
    end

    np_xmap9 #(.REVISION(8'd3)) u_xmap0 (
        .clk (clk), .reset (reset),
        .sel (xmap0_sel), .we (dcb_we), .crs (dcb_crs),
        .wdata (dcb_wdata), .rdata (xmap0_rdata),
        .look_did (did_q), .look_mode (xmap0_mode),
        .curs_cmap (xmap0_curs_cmap), .pup_cmap (xmap0_pup_cmap)
    );
    np_xmap9 #(.REVISION(8'd3)) u_xmap1 (
        .clk (clk), .reset (reset),
        .sel (xmap1_sel), .we (dcb_we), .crs (dcb_crs),
        .wdata (dcb_wdata), .rdata (xmap1_rdata),
        .look_did (did_q), .look_mode (xmap1_mode),
        .curs_cmap (), .pup_cmap ()
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
    // Two reads per pixel out of the serial ports - one from each plane set,
    // four bytes a pixel, two pixels to a word (np_rex3.sv has the layout).
    // A real board clocks a whole scanline out of the VRAM shift registers at
    // once; on MiSTer rtl/mister/fb_linecache.sv does that job behind each of
    // these ports, and the auxiliary one is mostly served without a fetch.
    // Neither port is waited for: the answer lands a cycle after the request,
    // and the pixel's half of the word is picked with the x bit remembered
    // from the request. `pix_word` keeps the old {aux, rgb} shape so that the
    // compositor below reads exactly what it always did.
    logic [63:0] pix_word;
    logic        pix_valid;
    logic [23:0] slot_rgb, slot_aux;
    logic        req_x0;

    wire [31:0] slot_off = (((({21'b0, vc2_y}) << FB_STRIDE_LOG2) + {21'b0, vc2_x}) << 2);
    assign fbr_req  = vc2_ce && vc2_de;
    assign fbr_addr = FB_BASE + slot_off;
    assign fba_req  = vc2_ce && vc2_de;
    assign fba_addr = FB_BASE + 32'h0080_0000 + slot_off;

    always_ff @(posedge clk) begin
        if (reset) begin
            slot_rgb  <= 24'h0;
            slot_aux  <= 24'h0;
            pix_valid <= 1'b0;
            req_x0    <= 1'b0;
        end else begin
            if (vc2_ce) req_x0 <= vc2_x[0];
            if (fbr_ack) begin
                slot_rgb  <= req_x0 ? fbr_rdata[55:32] : fbr_rdata[23:0];
                pix_valid <= 1'b1;
            end
            if (fba_ack)
                slot_aux  <= req_x0 ? fba_rdata[55:32] : fba_rdata[23:0];
        end
    end
    assign pix_word = {8'h00, slot_aux, 8'h00, slot_rgb};

    // THE CURSOR IS TWO STAGES AHEAD AND HAS TO BE HELD BACK. It is generated
    // from VC2's own counters, which is where the frame buffer ADDRESS comes
    // from; the word for that address is in `slot_rgb` two cycles later (the
    // answer, then its register). With one stage here - as it was until
    // build 44 - the pointer was drawn over the pixel one to its left.
    logic [1:0] cursor_q1;
    always_ff @(posedge clk) begin
        if (reset) begin cursor_q1 <= 2'd0; cursor_q <= 2'd0; end
        else       begin cursor_q1 <= vc2_cursor; cursor_q <= cursor_q1; end
    end

    // The mode table entry, per IRIS's ModeEntry: [0] buffer select,
    // [1] overlay buffer select, [7:3] colour map page, [9:8] pixel mode
    // (0 = colour index), [11:10] pixel size, [18:16] auxiliary pixel mode,
    // [23:19] the overlay's colour map page.
    wire        m_buf_sel  = xmap0_mode[0];
    wire        m_ovl_bsel = xmap0_mode[1];
    wire  [4:0] m_msb_cmap = xmap0_mode[7:3];
    wire  [1:0] pix_mode   = xmap0_mode[9:8];
    wire  [1:0] pix_size   = xmap0_mode[11:10];
    wire  [2:0] m_aux_mode = xmap0_mode[18:16];
    wire  [4:0] m_aux_cmap = xmap0_mode[23:19];

    wire [23:0] fb_rgb = pix_word[23:0];
    wire [23:0] fb_aux = pix_word[55:32];

    // The main pixel, extracted by size with the buffer select - the double
    // buffer's second copy sits above the first at every depth.
    logic [23:0] main_pix;
    always_comb begin
        case (pix_size)
            2'd0:    main_pix = {20'b0, m_buf_sel ? fb_rgb[7:4]   : fb_rgb[3:0]};
            2'd1:    main_pix = {16'b0, m_buf_sel ? fb_rgb[15:8]  : fb_rgb[7:0]};
            2'd2:    main_pix = {12'b0, m_buf_sel ? fb_rgb[23:12] : fb_rgb[11:0]};
            default: main_pix = fb_rgb;
        endcase
    end

    // The auxiliary planes' contribution: the popup's two bits, and the
    // overlay byte from whichever of its two buffers the mode selects.
    wire  [1:0] pup      = fb_aux[3:2];
    wire  [7:0] overlay  = m_ovl_bsel ? fb_aux[23:16] : fb_aux[15:8];
    wire        ovl_on   = (m_aux_mode == 3'd2 || m_aux_mode == 3'd6
                            || m_aux_mode == 3'd7) && (overlay != 8'h0);

    // Packed-RGB expansion, IRIS's expand_4/8/12: 2- and 3-bit fields spread
    // by repetition, nibbles by 0x11. R lands in [7:0] because that is the
    // lane `vid_r` reads, the same end CMAP's answer keeps it at.
    function automatic logic [7:0] exp2(input logic [1:0] v);
        exp2 = {4{v}};
    endfunction
    function automatic logic [7:0] exp3(input logic [2:0] v);
        exp3 = {v, v, v[2:1]};
    endfunction
    logic [23:0] direct_rgb_c;
    always_comb begin
        case (pix_size)
            2'd0:    direct_rgb_c = {{8{main_pix[3]}},
                                     exp2({main_pix[2], main_pix[1]}),
                                     {8{main_pix[0]}}};
            2'd1:    direct_rgb_c = {exp2(main_pix[7:6]),
                                     exp3(main_pix[5:3]),
                                     exp3(main_pix[2:0])};
            2'd2:    direct_rgb_c = {main_pix[11:8], main_pix[11:8],
                                     main_pix[7:4],  main_pix[7:4],
                                     main_pix[3:0],  main_pix[3:0]};
            // 24-bit pixels are ABGR with red in the low byte, which is the
            // identity in this convention. The byte swap that used to be
            // here predates any consumer of this path.
            default: direct_rgb_c = main_pix;
        endcase
    end

    // Source priority, IRIS's compose loop: cursor, then popup, then the
    // overlay, then the main pixel. Everything but packed RGB goes through
    // CMAP; the direct path is registered one clock to pair with CMAP's
    // registered answer.
    logic [12:0] cmap_index_c;
    logic        direct_c;
    always_comb begin
        direct_c = 1'b0;
        if (cursor_q != 2'd0)
            cmap_index_c = {xmap0_curs_cmap, 5'b0} | {11'b0, cursor_q};
        else if (pup != 2'd0)
            cmap_index_c = {xmap0_pup_cmap, 5'b0} | {11'b0, pup};
        else if (ovl_on)
            cmap_index_c = {m_aux_cmap, overlay};
        else if (pix_mode == 2'd0) begin
            case (pix_size)
                2'd0,
                2'd1:    cmap_index_c = {m_msb_cmap, main_pix[7:0]};
                // 12bpp indexes only the top half of the map: the page's
                // high bit plus the twelve pixel bits.
                2'd2:    cmap_index_c = {m_msb_cmap[4], main_pix[11:0]};
                default: cmap_index_c = main_pix[12:0];
            endcase
        end else begin
            direct_c     = 1'b1;
            cmap_index_c = 13'h0;
        end
    end
    assign cmap_index = cmap_index_c;

    logic        direct_q;
    logic [23:0] direct_rgb_q;
    always_ff @(posedge clk) begin
        direct_q     <= direct_c;
        direct_rgb_q <= direct_rgb_c;
    end

    // The raw view is registered like CMAP's answer and the direct path, so
    // all three arrive in the same cycle as the delayed display enable.
    logic [23:0] raw_rgb_q;
    always_ff @(posedge clk)
        raw_rgb_q <= (cursor_q != 2'd0) ? 24'hFFFFFF : {3{fb_rgb[7:0]}};

    logic [23:0] pix_rgb;
    always_comb begin
        if (dbg_raw_index) begin
            // The index itself, as grey - and the cursor as white, so that the
            // debug view does not report a pointer-shaped hole.
            pix_rgb = raw_rgb_q;
        end else if (direct_q) begin
            pix_rgb = direct_rgb_q;
        end else begin
            // 0x00BBGGRR out of the map.
            pix_rgb = cmap0_rgb;
        end
    end

    assign vid_r = de ? pix_rgb[7:0]   : 8'h00;
    assign vid_g = de ? pix_rgb[15:8]  : 8'h00;
    assign vid_b = de ? pix_rgb[23:16] : 8'h00;

    // THE PIXEL IS TWO CYCLES BEHIND THE ADDRESS AND ITS COLOUR THREE, so the
    // syncs are delayed three stages. VC2 emits a column's address in cycle
    // t; the frame buffer (sim_ram, and fb_linecache on the board - "one
    // cycle after the request") answers in t+1; `slot_rgb` registers the
    // answer, so the pixel is there in t+2; CMAP's lookup is a registered
    // read (it had to be, for the array to infer as M10K rather than 393 Kbit
    // of flip-flops - see np_cmap.sv), so the colour is there in t+3. The
    // syncs are delayed to match rather than the data being pushed forward,
    // so the picture moves as a whole.
    //
    // THIS WAS TWO STAGES UNTIL BUILD 44, which counted the answer and not
    // its register, and it put every column one place to the right: the
    // display enable's first pixel showed whatever the previous line had
    // fetched last. Nothing saw it while the window opened on IRIX's black
    // 8-pixel margin; cropping the window to the desktop's own columns put
    // the previous line's last pixel at the left edge of every line, and
    // tests/vidshift.py caught it on the boot gradient (docs/design/rex3-source-audit.md).
    //
    // THE DELAYS ARE CLOCKS, AND THE PIXEL ENABLE GOES WITH THEM. The colour
    // path above runs every clock, but VC2's pixel enable does not: it pauses
    // at the timing generator's table-fetch stalls, which fall at run
    // boundaries INSIDE the visible window (columns 251/252, 759/760,
    // 1013/1014 and 1267/1268 on IRIX's 1280x1024 table). Delays counted in
    // pixel enables slipped against the data at every stall, and a pair of
    // pixels showed its right-hand neighbour - verilator/tb_newport.cpp's
    // test 9, which samples the pins the way the MiSTer scaler does, on the
    // pixel enable (sgiindy.sv: CE_PIXEL). So VC2's own enable, the syncs and
    // the display enable travel together down a plain three-clock line, and
    // the scaler samples each colour on the enable that belongs to it.
    logic [3:0] vd1, vd2, vd3;      // {ce, hsync, vsync, de}
    always_ff @(posedge clk) begin
        if (reset) begin
            vd1 <= 4'b0; vd2 <= 4'b0; vd3 <= 4'b0;
        end else begin
            vd1 <= {vc2_ce, vc2_hsync, vc2_vsync, vc2_de};
            vd2 <= vd1;
            vd3 <= vd2;
        end
    end
    assign ce_pix = vd3[3];
    assign hsync  = vd3[2];
    assign vsync  = vd3[1];
    assign de     = vd3[0];

    assign gfx_irq    = vc2_vint;
    assign vblank_irq = r3_vrint;

    // The display-interpretation beacon word. Sampled asynchronously by the
    // beacon writer, so what it usually catches is whatever mode entry the
    // bulk of the screen renders through - which is exactly the question
    // when the screen is black over a full frame buffer.
    assign dbg_disp = { 8'h4D,                    // magic
                        vc2_dbg_did,              // {DID_EN, walker state}
                        did_q,                    // the DID in use
                        xmap0_mode,               // the mode entry it selects
                        pup, ovl_on, direct_q,
                        cmap_index_c, 6'b0 };

endmodule
