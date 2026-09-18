//============================================================================
//  np_rex3 - Newport's rasteriser, and the only chip on the GIO bus.
//
//  Everything else on the board - VC2, two XMAP9s, two CMAPs and the RAMDAC -
//  is reached through the Display Control Bus, which REX3 masters. There is no
//  second address window, so those four are children of this module rather
//  than peers, and `dcb_*` below is the fan-out.
//
//  BIT 11 OF THE REGISTER OFFSET IS THE GO BIT. Writing `reg | 0x800` writes
//  the register and starts the drawing command in one access; there is no
//  command register to kick afterwards. `rex3SetAndGo` in the PROM's driver
//  is exactly that, and it is why the offset decode strips 0x800 before
//  naming a register.
//
//  COORDINATES ARE 21.11 FIXED POINT WITH A 4096 BIAS. The integer registers
//  (`xstarti`, `xystarti`, `xyendi`) are views onto the same storage as the
//  fixed-point ones, shifted left by 11 - which is what makes Ng1Probe's
//  identity test work: write 0x12348765 to xstarti at 0x0148, read
//  0x43B28000 back from xstart at 0x0100. The bias is subtracted when a
//  coordinate becomes a frame buffer address, so the PROM's xywin of
//  0x10001000 is the identity rather than a 4096-pixel offset.
//
//  THE ENGINE IS ONE PIXEL AT A TIME, read-modify-write. Real REX3 does two
//  pixels per clock out of a VRAM with a 256-bit internal path; this walks
//  the frame buffer port. That is slow - rex3Clear is four passes over
//  1343 x 1024 pixels - but it is the honest shape for a design whose frame
//  buffer is external memory, and correctness comes first. A span cache or a
//  wide fill path is the obvious later win and is not needed to boot.
//
//  THE WHOLE COMMAND SET IS BUILT. It was not always: for the first
//  twenty-odd builds this engine drew flat colour-index spans and blocks and
//  nothing else, which is everything the PROM console and the X server's
//  window furniture ask for and none of what a GL program asks for. The gap
//  was measured rather than guessed - iris/src/rex3_shaders.rs carries a
//  corpus of 462 distinct (DRAWMODE0, DRAWMODE1, CLIPMODE) triples collected
//  from a real IRIX desktop, and counting its feature bits says what a
//  screen saver actually needs: dither in 197 of them, the three line
//  address modes in 137, the colour DDAs in 85, line stipple in 49, alpha
//  blending in 46. docs/design/rex3-rendering.md has the table.
//
//  So: colour DDAs with per-pixel slopes and the CI and RGB clamps, the
//  24-bit-to-plane-depth compression with the Bayer dither, alpha blending
//  with both factor selectors, the alpha compare, the host alpha, LRONLY,
//  the SPAN address mode as distinct from BLOCK, all three line address
//  modes with their Bresenham state in the registers where a continuation GO
//  can find it, the line stipple with its repeat counter, and the A_LINE
//  endpoint filter. IRIS's rex3_generic.rs is the oracle for every one of
//  them and verilator/tb_rex3draw.cpp is its transcription: that bench runs
//  the corpus's own draw modes through both and compares the frame buffers.
//
//  STILL NOT BUILT: YFLIP and SWAPENDIAN (no shape in the corpus sets
//  either) and the anti-aliased line's per-pixel coverage weighting - A_LINE
//  draws as a fractional line, and the AWEIGHT tables are read for the
//  endpoint filter and nothing else. Both are accepted, read back and
//  ignored.
//============================================================================

module np_rex3 #(
    // Frame buffer geometry. The stride is a power of two so an address is a
    // shift rather than a multiply; 2048 covers 1280 with the black bias
    // pixels the PROM keeps to the left of every scanline.
    parameter int FB_STRIDE_LOG2 = 11,
    parameter int FB_LINES       = 1024,
    parameter logic [31:0] FB_BASE = 32'h0000_0000,
    parameter logic  [2:0] VERSION = 3'd1
) (
    input  logic        clk,
    input  logic        reset,

    // ---- GIO register interface, 32 bits, from newport.sv ----------------
    input  logic        sel,
    input  logic        we,
    input  logic [12:0] off,          // byte offset in the 8 KB window
    input  logic [31:0] wdata,
    // The byte lanes this write actually carries, [3] the most significant.
    // Only DCBDATA0 uses them, and it has to: see `dcb_align` below.
    input  logic  [3:0] be,
    output logic [31:0] rdata,
    output logic        ack,

    // ---- the VDMA host port, 64 bits wide -----------------------------------
    // The MC's GIO64 DMA engine lands here: every pixel X draws arrives as a
    // 64-bit beat at HOSTRW0 with the GO bit (offset 0xA30 - the kernel's
    // Ng1PixelDma computes that GIO address from the offset X passes in, and
    // it is the only address IRIS's dma path accepts either). A write beat is
    // IRIS's REX3_HOSTRW64 push: both host words and a GO in one go. A read
    // beat is its dma_read64: GO FIRST, wait for the engine, then take the
    // host words - the inverse of the CPU's read-then-advance, because the
    // engine has no discard loop on the far side.
    //
    // `nd_req` is held until `nd_ack`, like every master port in this core.
    // Beats wait for the drawing engine exactly as a held CPU write does -
    // each one starts a primitive, and the next may not land on top of it.
    input  logic        nd_req,
    input  logic        nd_we,
    input  logic [12:0] nd_off,       // byte offset in the 8 KB window
    input  logic [63:0] nd_wdata,
    output logic [63:0] nd_rdata,
    output logic        nd_ack,
    // {write beats[15:0], read beats[7:0], drops[3:0], ndst, engine flags} -
    // one beacon word half; "did any beat reach REX3" answered from the board.
    output logic [31:0] dbg_nd,

    // ---- Display Control Bus ---------------------------------------------
    output logic        dcb_sel,
    output logic        dcb_we,
    output logic  [3:0] dcb_addr,
    output logic  [2:0] dcb_crs,
    output logic  [1:0] dcb_width,
    output logic [31:0] dcb_wdata,
    input  logic [31:0] dcb_rdata,

    // ---- frame buffer, the VRAM random port ------------------------------
    output logic        fb_req,
    output logic        fb_we,
    output logic [31:0] fb_addr,
    output logic [63:0] fb_wdata,
    output logic  [7:0] fb_be,
    input  logic [63:0] fb_rdata,
    input  logic        fb_ack,
    // A visible value (overlay or popup bits) was just written into the
    // auxiliary planes of frame buffer line `aux_mark_line`. The display
    // side's flag table (rtl/mister/fb_linecache.sv, TRACK_ZERO) needs it.
    output logic        aux_mark,
    output logic [10:0] aux_mark_line,

    // ---- from VC2 ---------------------------------------------------------
    input  logic        vert_int,
    output logic        gfx_busy,
    // THE RETRACE INTERRUPT LINE IS THE VRINT LATCH, NOT A TIMING LEVEL.
    // Set at the start of each vertical retrace, held until the CPU reads
    // STATUS (0x1338, not USERSTATUS), which is what deasserts INT2 LOCAL1
    // bit 7 - IRIS and MAME both model exactly this, and the driver's ISR
    // depends on it: build 12 wired the raw vblank level there instead, the
    // ISR could never retire it, and the machine spent ~80% of its cycles
    // in exception_ip12/VEC_int - a boot that crawled for half an hour and
    // never reached X (docs/design/newport-vdma.md).
    output logic        vrint_irq
);

    // ---- register offsets -------------------------------------------------
    localparam logic [12:0] R_DRAWMODE1   = 13'h0000;
    localparam logic [12:0] R_DRAWMODE0   = 13'h0004;
    localparam logic [12:0] R_LSMODE      = 13'h0008;
    localparam logic [12:0] R_LSPATTERN   = 13'h000C;
    localparam logic [12:0] R_LSPATSAVE   = 13'h0010;
    localparam logic [12:0] R_ZPATTERN    = 13'h0014;
    localparam logic [12:0] R_COLORBACK   = 13'h0018;
    localparam logic [12:0] R_COLORVRAM   = 13'h001C;
    localparam logic [12:0] R_ALPHAREF    = 13'h0020;
    localparam logic [12:0] R_STALL0      = 13'h0024;
    localparam logic [12:0] R_SMASK0X     = 13'h0028;
    localparam logic [12:0] R_SMASK0Y     = 13'h002C;
    localparam logic [12:0] R_SETUP       = 13'h0030;
    localparam logic [12:0] R_STEPZ       = 13'h0034;
    localparam logic [12:0] R_LSRESTORE   = 13'h0038;
    localparam logic [12:0] R_LSSAVE      = 13'h003C;
    localparam logic [12:0] R_XSTART      = 13'h0100;
    localparam logic [12:0] R_YSTART      = 13'h0104;
    localparam logic [12:0] R_XEND        = 13'h0108;
    localparam logic [12:0] R_YEND        = 13'h010C;
    localparam logic [12:0] R_XSAVE       = 13'h0110;
    localparam logic [12:0] R_XYMOVE      = 13'h0114;
    localparam logic [12:0] R_BRESD       = 13'h0118;
    localparam logic [12:0] R_BRESS1      = 13'h011C;
    localparam logic [12:0] R_BRESOCTINC1 = 13'h0120;
    localparam logic [12:0] R_BRESRNDINC2 = 13'h0124;
    localparam logic [12:0] R_BRESE1      = 13'h0128;
    localparam logic [12:0] R_BRESS2      = 13'h012C;
    localparam logic [12:0] R_AWEIGHT0    = 13'h0130;
    localparam logic [12:0] R_AWEIGHT1    = 13'h0134;
    localparam logic [12:0] R_XSTARTF     = 13'h0138;
    localparam logic [12:0] R_YSTARTF     = 13'h013C;
    localparam logic [12:0] R_XENDF       = 13'h0140;
    localparam logic [12:0] R_YENDF       = 13'h0144;
    localparam logic [12:0] R_XSTARTI     = 13'h0148;
    localparam logic [12:0] R_XENDF1      = 13'h014C;   // "Same as XENDF"
    localparam logic [12:0] R_XYSTARTI    = 13'h0150;
    localparam logic [12:0] R_XYENDI      = 13'h0154;
    localparam logic [12:0] R_XSTARTENDI  = 13'h0158;
    localparam logic [12:0] R_COLORRED    = 13'h0200;
    localparam logic [12:0] R_COLORALPHA  = 13'h0204;
    localparam logic [12:0] R_COLORGRN    = 13'h0208;
    localparam logic [12:0] R_COLORBLUE   = 13'h020C;
    localparam logic [12:0] R_SLOPERED    = 13'h0210;
    localparam logic [12:0] R_SLOPEALPHA  = 13'h0214;
    localparam logic [12:0] R_SLOPEGRN    = 13'h0218;
    localparam logic [12:0] R_SLOPEBLUE   = 13'h021C;
    localparam logic [12:0] R_WRMASK      = 13'h0220;
    localparam logic [12:0] R_COLORI      = 13'h0224;
    localparam logic [12:0] R_COLORX      = 13'h0228;
    localparam logic [12:0] R_SLOPERED1   = 13'h022C;
    localparam logic [12:0] R_HOSTRW0     = 13'h0230;
    localparam logic [12:0] R_HOSTRW1     = 13'h0234;
    localparam logic [12:0] R_DCBMODE     = 13'h0238;
    localparam logic [12:0] R_DCBDATA0    = 13'h0240;
    localparam logic [12:0] R_DCBDATA1    = 13'h0244;
    localparam logic [12:0] R_SMASK1X     = 13'h1300;
    localparam logic [12:0] R_SMASK1Y     = 13'h1304;
    localparam logic [12:0] R_SMASK2X     = 13'h1308;
    localparam logic [12:0] R_SMASK2Y     = 13'h130C;
    localparam logic [12:0] R_SMASK3X     = 13'h1310;
    localparam logic [12:0] R_SMASK3Y     = 13'h1314;
    localparam logic [12:0] R_SMASK4X     = 13'h1318;
    localparam logic [12:0] R_SMASK4Y     = 13'h131C;
    localparam logic [12:0] R_TOPSCAN     = 13'h1320;
    localparam logic [12:0] R_XYWIN       = 13'h1324;
    localparam logic [12:0] R_CLIPMODE    = 13'h1328;
    localparam logic [12:0] R_STALL1      = 13'h132C;
    localparam logic [12:0] R_CONFIG      = 13'h1330;
    localparam logic [12:0] R_STATUS      = 13'h1338;
    localparam logic [12:0] R_USERSTATUS  = 13'h133C;
    localparam logic [12:0] R_DCBRESET    = 13'h1340;

    // ---- register widths ---------------------------------------------------
    // POST's graphics diagnostic is a register read/write test: it writes each
    // of 0xFFFFFFFF, 0xAAAAAAAA, 0x55555555 and 0 and expects the register's
    // own width back. `test_rex3` in
    // stand/arcs/ide/fforward/graphics/NEWPORT/rex3.c is the list, and these
    // are its masks. Trimming on the way in rather than on the way out keeps
    // the stored value the register's real width, which is what the draw
    // engine should be reading anyway.
    localparam logic [31:0] M_LSMODE      = 32'h0FFF_FFFF;   // 28 bits
    localparam logic [31:0] M_ALPHAREF    = 32'h0000_00FF;   // 8
    localparam logic [31:0] M_COORD       = 32'h07FF_FF80;   // 20 bits << 7
    // The GL-format coordinates (XSTARTF..YENDF, XENDF1) are "12.4(7) GL
    // version of XSTART, (zeros 4 msbs)" - see their write arms.
    localparam logic [31:0] M_GLCOORD     = 32'h007F_FF80;
    localparam logic [31:0] M_BRESD       = 32'h07FF_FFFF;   // 27
    localparam logic [31:0] M_BRESS1      = 32'h0001_FFFF;   // 17
    localparam logic [31:0] M_BRESOCTINC1 = 32'h070F_FFFF;   // 27 less [23:20]
    localparam logic [31:0] M_BRESRNDINC2 = 32'hFF1F_FFFF;   // 32 less [23:21]
    localparam logic [31:0] M_BRESE1      = 32'h0000_FFFF;   // 16
    localparam logic [31:0] M_BRESS2      = 32'h03FF_FFFF;   // 26
    localparam logic [31:0] M_COLOR24     = 32'h00FF_FFFF;   // 24
    localparam logic [31:0] M_COLOR20     = 32'h000F_FFFF;   // 20
    localparam logic [31:0] M_TOPSCAN     = 32'h0000_03FF;   // 10
    localparam logic [31:0] M_CLIPMODE    = 32'h0000_1FFF;   // 13

    // THE SLOPE REGISTERS ARE SIGN-MAGNITUDE ON THE BUS AND TWO'S COMPLEMENT
    // IN THE CHIP, AND THOSE ARE THE SAME BITS. A negative write is bit 31
    // set with the magnitude below it; what is stored is the field-width
    // two's complement of that magnitude, whose own top bit is then set,
    // which is both what the register test reads back and what the colour
    // DDA has to add. IRIS's from_slope_red/from_slope are these two lines.
    // The one case where the old sign-magnitude spelling disagreed is a sign
    // bit over a zero magnitude - a negative zero - and both call that zero.
    function automatic logic [31:0] to_sign_mag(input logic [31:0] v,
                                                input int nbits);
        logic [31:0] mag;
        begin
            mag = v & ((32'd1 << (nbits - 1)) - 32'd1);
            if (mag == 32'd0) to_sign_mag = 32'd0;
            else to_sign_mag = v[31]
                 ? (((32'd1 << (nbits - 1)) - mag) | (32'd1 << (nbits - 1)))
                 : mag;
        end
    endfunction

    // One of those stored slopes, sign-extended to 32 bits for the adder.
    function automatic logic signed [31:0] slope_ext(input logic [31:0] v,
                                                     input int nbits);
        slope_ext = $signed(v | (v[nbits-1] ? ~((32'd1 << nbits) - 32'd1)
                                            : 32'd0));
    endfunction

    // COLOUR COMPONENTS LIVE IN THE DDAs AS o12.11: the integer part is at
    // [22:11], nine bits of it are significant, and the two out-of-range
    // cases are distinguished. Bit 31 set means the DDA has stepped below
    // zero (the accumulator is 32 bits and the slopes are signed), and an
    // integer of 0x180 or more is the same wrap seen from the other side;
    // both read as zero. Anything else above 0xFF saturates. IRIS's
    // clamp_color_component, and the reason a shaded span fades to black at
    // one end rather than wrapping to white.
    function automatic logic [7:0] clamp_comp(input logic [31:0] c);
        logic [8:0] v;
        begin
            v = c[19:11];
            if (c[31] || v >= 9'h180) clamp_comp = 8'h00;
            else if (v > 9'h0FF)      clamp_comp = 8'hFF;
            else                      clamp_comp = v[7:0];
        end
    endfunction

    // The same two out-of-range cases seen by the DDA itself. An RGB
    // component that has stepped out of range is clamped in the accumulator,
    // not just on the way out, so a span that runs off the end of the ramp
    // stays clamped for the rest of its length.
    function automatic logic [31:0] clamp_shade(input logic [31:0] c);
        logic [8:0] v;
        begin
            v = c[19:11];
            if (c[31] || v >= 9'h180) clamp_shade = 32'h0000_0000;
            else if (v > 9'h0FF)      clamp_shade = 32'h0007_FFFF;
            else                      clamp_shade = c;
        end
    endfunction

    // ---- register storage -------------------------------------------------
    logic [31:0] drawmode0, drawmode1;
    logic [31:0] lsmode, lspattern, lspatsave, zpattern;
    logic [31:0] colorback, colorvram, alpharef, stall0;
    logic [31:0] smask0x, smask0y, setup_r, stepz, lsrestore, lssave;
    logic [31:0] xstart, ystart, xend, yend, xsave, xymove;
    logic [31:0] bresd, bress1, bresoctinc1, bresrndinc2, brese1, bress2;
    logic [31:0] aweight0, aweight1;
    logic [31:0] colorred, coloralpha, colorgrn, colorblue;
    logic [31:0] slopered, slopealpha, slopegrn, slopeblue, slopered1;
    logic [31:0] wrmask, colorx;
    logic [31:0] hostrw0, hostrw1;
    logic [31:0] dcbmode, dcbdata0, dcbdata1;
    logic [31:0] smask1x, smask1y, smask2x, smask2y;
    logic [31:0] smask3x, smask3y, smask4x, smask4y;
    logic [31:0] topscan, xywin, clipmode, stall1, config_r;
    logic        vrint, videoint;

    // The GO bit is bit 11 of the offset; the register is what is left.
    wire        is_go   = off[11];
    wire [12:0] reg_off = {off[12], 1'b0, off[10:0]} & 13'h1FFC;

    // ---- drawmode fields --------------------------------------------------
    wire  [1:0] dm0_opcode  = drawmode0[1:0];
    wire  [2:0] dm0_adrmode = drawmode0[4:2];
    wire        dm0_dosetup = drawmode0[5];
    wire        dm0_colorhost = drawmode0[6];
    wire        dm0_alphahost = drawmode0[7];
    wire        dm0_stoponx = drawmode0[8];
    wire        dm0_stopony = drawmode0[9];
    wire        dm0_skipfirst = drawmode0[10];
    wire        dm0_skiplast  = drawmode0[11];
    wire        dm0_enzpattern = drawmode0[12];
    wire        dm0_enlspat   = drawmode0[13];
    wire        dm0_lsadvlast = drawmode0[14];
    wire        dm0_length32 = drawmode0[15];
    wire        dm0_zpopaque = drawmode0[16];
    wire        dm0_lsopaque = drawmode0[17];
    // SHADE is what makes a span a shaded span: without it the colour DDAs
    // hold and every pixel of the primitive takes the same colour, which is
    // the flat fill this engine used to be able to do and nothing else.
    wire        dm0_shade    = drawmode0[18];
    // LRONLY: draw only the left-to-right half of the primitive. A polygon
    // rasteriser hands REX3 both edges of every span and lets the chip throw
    // one away; without the bit the right-to-left ones paint over the fill.
    wire        dm0_lronly   = drawmode0[19];
    wire        dm0_xyoffset = drawmode0[20];
    wire        dm0_ciclamp  = drawmode0[21];
    wire        dm0_endptfilter = drawmode0[22];
    wire        dm0_ystride  = drawmode0[23];

    // The five address modes. SPAN and BLOCK differ in one thing that
    // matters: a span that reaches its right-hand end is over, while a block
    // wraps x back to XSAVE and starts the next row.
    localparam logic [2:0] AM_SPAN  = 3'd0;
    localparam logic [2:0] AM_BLOCK = 3'd1;
    localparam logic [2:0] AM_ILINE = 3'd2;
    localparam logic [2:0] AM_FLINE = 3'd3;
    localparam logic [2:0] AM_ALINE = 3'd4;
    wire dm0_is_line = (dm0_adrmode == AM_ILINE) || (dm0_adrmode == AM_FLINE)
                    || (dm0_adrmode == AM_ALINE);
    wire dm0_is_fract = (dm0_adrmode == AM_FLINE) || (dm0_adrmode == AM_ALINE);

    // DRAWMODE1's layout, from ~/repos/iris's rex3.rs. THE LOGIC OP IS AT THE
    // TOP OF THE WORD, not next to the depth fields, and reading it from
    // [15:12] instead picks up COMPARE - which every drawmode1 the PROM
    // writes sets to 7 to disable it. Seven is OR. So every filled box was
    // OR-ed onto whatever was already in the frame buffer, and the screen
    // came out as bands of nearly-the-right grey that drifted by a bit or two
    // across a span: it read as a smearing rasteriser rather than as a wrong
    // raster op, because OR with the right colour is mostly the right colour.
    // RGBMODE moved with it - it is bit 15, immediately above COMPARE.
    //
    // The whole word: planes [2:0], drawdepth [4:3], dblsrc [5], yflip [6],
    // rwpacked [7], hostdepth [9:8], rwdouble [10], swapendian [11],
    // compare [14:12], rgbmode [15], dither [16], fastclear [17], blend [18],
    // sfactor [21:19], dfactor [24:22], backblend [25], prefetch [26],
    // blendalpha [27], logicop [31:28]. The two still not decoded below are
    // YFLIP and SWAPENDIAN: accepted, read back, and ignored, because no
    // shape in the corpus sets either.
    wire  [2:0] dm1_planes    = drawmode1[2:0];
    wire  [1:0] dm1_drawdepth = drawmode1[4:3];
    wire        dm1_dblsrc    = drawmode1[5];
    wire        dm1_rwpacked  = drawmode1[7];
    wire  [1:0] dm1_hostdepth = drawmode1[9:8];
    wire        dm1_rwdouble  = drawmode1[10];
    // COMPARE is the alpha function: three OR-able relation bits, LT|EQ|GT,
    // tested against ALPHAREF. All three set (7) is "always pass", which is
    // what the PROM writes in every command; `afunc_pass` below is the test.
    wire  [2:0] dm1_compare   = drawmode1[14:12];
    wire        dm1_rgbmode   = drawmode1[15];
    wire        dm1_dither    = drawmode1[16];
    wire        dm1_fastclear = drawmode1[17];
    wire        dm1_blend     = drawmode1[18];
    wire  [2:0] dm1_sfactor   = drawmode1[21:19];
    wire  [2:0] dm1_dfactor   = drawmode1[24:22];
    wire        dm1_backblend = drawmode1[25];
    wire        dm1_blendalpha= drawmode1[27];
    wire  [3:0] dm1_logicop   = drawmode1[31:28];

    localparam logic [1:0] OP_NOOP    = 2'd0;
    localparam logic [1:0] OP_READ    = 2'd1;
    localparam logic [1:0] OP_DRAW    = 2'd2;
    localparam logic [1:0] OP_SCR2SCR = 2'd3;

    // A 12-bit colour index arrives on the bus as o12.9 and is stored as
    // o12.11; every other colour write is a plain mask.
    wire ci12_shift = !dm1_rgbmode && (dm1_drawdepth == 2'd2);

    // Octant, from BRESOCTINC1[26:24]: bit 0 y decrement, bit 1 x decrement.
    wire oct_ydec = bresoctinc1[24];
    wire oct_xdec = bresoctinc1[25];

    // ---- coordinate helpers ------------------------------------------------
    localparam int COORD_BIAS = 4096;
    function automatic logic signed [16:0] fp_int(input logic [31:0] fp);
        fp_int = $signed(fp[26:11]);
    endfunction

    // ======================================================================
    //  Display Control Bus master
    // ======================================================================
    // DCBMODE: [1:0] data width (0 = 4 bytes, 1..3 = that many), [2] pack,
    // [3] CRS auto-increment, [6:4] register select, [10:7] chip address,
    // [28] swap byte ordering.
    wire  [1:0] dcbm_width = dcbmode[1:0];
    wire        dcbm_crsinc = dcbmode[3];
    wire  [2:0] dcbm_crs   = dcbmode[6:4];
    wire  [3:0] dcbm_addr  = dcbmode[10:7];
    wire        dcbm_swap  = dcbmode[28];

    // Bytes in a transfer. A width of zero means the whole 32-bit register in
    // ONE transfer rather than four byte beats - XMAP9's mode table entry is
    // written that way, with the entry index in the top byte and the entry in
    // the rest, and splitting it into bytes would write four unrelated
    // registers. CRS advances by four for it, as it does per byte otherwise.
    wire       dcb_word32 = (dcbm_width == 2'd0);
    wire [2:0] dcb_nbytes = dcb_word32 ? 3'd1 : {1'b0, dcbm_width};

    typedef enum logic [1:0] { DCB_IDLE, DCB_XFER, DCB_READ_W, DCB_DONE } dcb_state_t;
    dcb_state_t  dcbst;
    logic  [2:0] dcb_byte;         // which byte of the transfer
    logic  [2:0] dcb_crs_run;
    logic [31:0] dcb_data;
    logic [31:0] dcb_result;
    logic        dcb_is_read;
    logic        dcb_start_rd, dcb_start_wr;
    logic        dcb_rd_waited;   // one settling cycle per read beat

    // VC2 takes a whole transfer of the declared width in one go; every other
    // chip on the bus is byte-wide and takes them MSB first.
    wire dcb_is_vc2 = (dcbm_addr == 4'd0);

    // DCBMODE[28] reverses the byte order WITHIN THE DATA WIDTH, and the PROM
    // sets it for the two-byte palette-address write - which is the only
    // transfer on the boot path that uses it.
    logic [31:0] dcb_swapped;
    always_comb begin
        case (dcbm_width)
            2'd2:    dcb_swapped = {dcb_data[23:16], dcb_data[31:24],
                                    dcb_data[7:0],   dcb_data[15:8]};
            2'd3:    dcb_swapped = {dcb_data[15:8], dcb_data[23:16],
                                    dcb_data[31:24], dcb_data[7:0]};
            2'd0:    dcb_swapped = {dcb_data[7:0], dcb_data[15:8],
                                    dcb_data[23:16], dcb_data[31:24]};
            default: dcb_swapped = dcb_data;
        endcase
    end
    wire [31:0] dcb_val = dcbm_swap ? dcb_swapped : dcb_data;

    // The byte the current beat carries. THE DATUM IS LEFT-ALIGNED IN DCBDATA0
    // AND THE BUS SHIFTS IT OUT FROM THE TOP, whatever the width.
    //
    // That is not what the register holds when the CPU writes it. A byte store
    // lands in the lane it addressed - the driver uses
    // `rex->set.dcbdata0.bybyte.b3`, the register's least significant byte -
    // and a halfword through `.byword` at the same end, so both arrive
    // right-aligned. `dcb_align` below shifts them back up, which is exactly
    // what IRIS does at its bus layer: write8 calls dcb_write(val << 24) and
    // write16 calls it with val << ((offset & 2) << 3).
    //
    // TAKING THE LOW n BYTES INSTEAD IS ALMOST RIGHT, and that is what made it
    // survive. For a byte transfer the two rules agree. For the halfword the
    // PROM writes the palette address with, they disagree - and the PROM sets
    // DCBMODE's SWAPENDIAN on that transfer, which swapped it back by
    // accident. It is the THREE-byte transfer that has nowhere to hide:
    // cmapSetRGB writes r, g and b as one word, 0xRRGGBB00, and taking the low
    // three bytes sends (r, g, 0). Every colour in the machine lost its blue
    // channel, so the whole screen came out yellow-green - a grey ramp read
    // back as (n, n, 0) - and nothing failed, because a palette is only ever
    // looked at.
    function automatic logic [31:0] dcb_align(input logic [31:0] v,
                                              input logic  [3:0] lanes);
        if      (lanes[3]) dcb_align = v;                  // already at the top
        else if (lanes[2]) dcb_align = {v[23:0],  8'h0};
        else if (lanes[1]) dcb_align = {v[15:0], 16'h0};
        else if (lanes[0]) dcb_align = {v[7:0],  24'h0};
        else               dcb_align = v;
    endfunction

    logic [7:0] dcb_beat;
    always_comb begin
        case (dcb_byte)
            3'd0:    dcb_beat = dcb_val[31:24];
            3'd1:    dcb_beat = dcb_val[23:16];
            3'd2:    dcb_beat = dcb_val[15:8];
            default: dcb_beat = dcb_val[7:0];
        endcase
    end

    assign dcb_addr  = dcbm_addr;
    assign dcb_width = dcbm_width;
    assign dcb_crs   = dcb_crs_run;
    // VC2 takes the whole 32-bit transfer - its 24-bit register write packs
    // the index into [28:24] and the data into [23:8], which is not a byte
    // stream. Every other chip on the bus takes one byte at a time, in the low
    // byte, which is the end its driver stored it at.
    // VC2 takes a whole transfer of the declared width in one go rather than a
    // byte stream, and its own decode expects the datum right-aligned - so the
    // alignment above has to be undone for it, which is what IRIS's dcb_write
    // does with `val >> 24` and `val >> 16` in its VC2 arm.
    logic [31:0] dcb_vc2_val;
    always_comb begin
        case (dcbm_width)
            2'd1:    dcb_vc2_val = {24'h0, dcb_val[31:24]};
            2'd2:    dcb_vc2_val = {16'h0, dcb_val[31:16]};
            default: dcb_vc2_val = dcb_val;
        endcase
    end

    assign dcb_wdata = dcb_is_vc2  ? dcb_vc2_val
                     : dcb_word32  ? dcb_val
                     :               {24'h0, dcb_beat};

    // ======================================================================
    //  Draw engine
    // ======================================================================
    typedef enum logic [3:0] {
        DR_IDLE, DR_SETUP, DR_SRC_RD, DR_DST_RD, DR_WR, DR_STEP, DR_FILL, DR_DRAIN,
        // The second write of an auxiliary pixel: its window-ID nibble into
        // the drawing slot's spare byte. Returns to `dr_after`.
        DR_CID,
        // The fractional-endpoint correction of an F_LINE or an A_LINE, in
        // three clocks: the products, then the decision and the step, then
        // the pixel count from where the step left the position. Its own
        // states because putting any of it in DR_SETUP's cycle would price
        // every flat block at the cost of a line nobody drew - and because
        // all of it in ONE cycle was build 43's critical path.
        DR_FRACT, DR_FRACT2, DR_FRACT3
    } dr_state_t;

    dr_state_t   dr, dr_after;
    dr_state_t   fill_next;              // DR_FILL's next state (assigned below)
    logic signed [16:0] cid_x;           // the pixel DR_CID writes for
    logic [10:0] cid_y;
    logic  [3:0] cid_val;
    logic signed [16:0] cx, cy;          // running integer position
    logic signed [16:0] cx_end, cy_end;
    logic signed [16:0] cx_save;
    // The sub-pixel part of each of the four coordinates, latched for the
    // primitive. The walk's own position keeps its start's fraction - a step
    // of exactly one pixel cannot change it - so this is what the end
    // comparisons need and what a coordinate write-back has to put back.
    logic [10:0] xfrac, yfrac, xefrac, yefrac;
    logic  [4:0] zbit;                   // z-pattern bit index, 31 down
    logic  [4:0] patbit;                 // line-stipple bit index, 31 down
    logic  [5:0] span_left;              // LENGTH32 clamp
    logic        span_clamped;
    logic        first_pix;
    logic [23:0] src_pix;                // pixel read for SCR2SCR
    logic [31:0] dst_half;               // the destination pixel's slot
    logic  [3:0] host_left;              // pixels remaining in a host word
    logic [63:0] host_shift;
    // A LINE IS A COUNT, NOT A COMPARISON. Bresenham's minor axis lands
    // wherever the error term puts it, so "have we arrived" cannot be asked
    // of the coordinates: the walk runs for major + 1 pixels and stops.
    logic [16:0] line_left;
    wire         line_last = (line_left == 17'd1);
    // SKIPFIRST and SKIPLAST as the primitive actually runs: DRAWMODE0's bits,
    // plus A_LINE's endpoint filter, minus the single-step case where neither
    // applies because the one pixel is both.
    logic        skip_first_r, skip_last_r;

    // ---- LSMODE, the line stipple's own register ---------------------------
    // [7:0] the live repeat down-counter, [15:8] its reload, [23:16] the
    // counter's save slot, [27:24] the pattern length less 17. THE COUNTER
    // LIVES INSIDE THE REGISTER, and a GO must not reset it: the ARCS
    // diagnostic writes LSMODE, issues a GO and reads it back expecting what
    // it wrote, and GL carries it across the segments of a connected stippled
    // line through LSSAVE and LSRESTORE.
    wire [7:0] ls_repeat_raw = lsmode[15:8];
    wire [7:0] ls_repeat = (ls_repeat_raw == 8'd0) ? 8'd1 : ls_repeat_raw;
    wire [7:0] ls_rcount = lsmode[7:0];
    wire [5:0] ls_length = {2'b0, lsmode[27:24]} + 6'd17;   // 17..32
    wire [4:0] ls_wrap   = (ls_length >= 6'd32) ? 5'd0 : 5'(6'd32 - ls_length);
    // Writes issued into the frame buffer that have not been acknowledged.
    // The fill path below does not wait for each one, so this is what says the
    // engine is finished.

    // BUSY UNTIL THE LAST WRITE HAS BEEN ACKNOWLEDGED, and `dr` alone now says
    // so. Both write paths wait for `fb_ack` before leaving the pixel, so the
    // engine cannot reach DR_IDLE with a write still in the air and the
    // separate outstanding-write counter this used to carry has nothing left
    // to count. That matters more than it looks: a driver polls this through
    // STATUS and USER_STATUS, and an engine that reports idle early is the bug
    // that let the PROM write registers into running commands for as long as
    // this core has had graphics.
    assign gfx_busy = (dr != DR_IDLE) || (dcbst != DCB_IDLE);
    assign vrint_irq = vrint;

    // THE FILL PATH. A plain painted block with a byte-clean write mask and a
    // logic op that ignores the destination needs no read and returns no data,
    // so nothing has to wait for an acknowledgement: it issues one write per
    // clock and counts what has not retired yet.
    //
    // This is worth the extra state because rex3Clear is four passes over
    // 1343 x 1024 pixels and the PROM runs it twice. At the general path's
    // three clocks a pixel that is 33 million clocks of a boot that used to
    // be 37 million in total.
    // The decision is made once, in DR_SETUP, from the same three conditions.

    // THE STEP COMES FIRST AND THE END TEST LOOKS AT WHERE IT LANDED. IRIS's
    // block walk advances x, then asks whether the advanced x has passed the
    // end - so the pixel that triggers the test is the last one drawn, which
    // is what SKIPLAST has to mean and what makes the row wrap happen after
    // that pixel rather than before it.
    //
    // A SPAN ALWAYS RUNS LEFT TO RIGHT. Only BLOCK and SCR2SCR follow the
    // octant, and they have to: a copy that overlaps its source runs towards
    // the overlap rather than away from it, which is the whole reason
    // Ng1TpBmove picks its start and end corners the way it does.
    wire walk_xdec = (dm0_adrmode == AM_SPAN) ? 1'b0 : oct_xdec;
    wire signed [16:0] x_step = walk_xdec ? cx - 17'sd1 : cx + 17'sd1;
    wire signed [16:0] y_incr = dm0_ystride ? 17'sd2 : 17'sd1;
    wire signed [16:0] y_step = oct_ydec ? cy - y_incr : cy + y_incr;
    // THE COMPARISON IS IN FIXED POINT, and the walk carries the start's own
    // fraction with it for ever - it steps by exactly one, so the fraction
    // never changes. Two coordinates with the same integer part are still
    // ordered by their fractions, and comparing only the integers ends a span
    // one pixel early or late whenever the two endpoints were given different
    // sub-pixel positions.
    wire x_at_end = walk_xdec
                  ? ((x_step <  cx_end) || ((x_step == cx_end) && (xfrac <  xefrac)))
                  : ((x_step >  cx_end) || ((x_step == cx_end) && (xfrac >  xefrac)));
    wire y_at_end = oct_ydec
                  ? ((y_step <  cy_end) || ((y_step == cy_end) && (yfrac <  yefrac)))
                  : ((y_step >  cy_end) || ((y_step == cy_end) && (yfrac >  yefrac)));

    // LRONLY: a right-to-left primitive draws nothing. A polygon rasteriser
    // hands REX3 both edges of every span and expects the chip to keep the
    // one that runs the way the fill does. A SPAN drops out entirely; a BLOCK
    // still walks, because it owes the y advance to the rows after it - "some
    // triangles grow weird tails" without that, in IRIS's own words.
    wire lr_skip = dm0_lronly && oct_xdec && !dm0_is_line;
    // A SPAN DROPS OUT BEFORE IT STARTS, which is not the same as walking it
    // with the writes suppressed: the colour DDAs and the pattern cursors
    // must not advance either, or the next span of the same triangle starts
    // from the wrong colour. The octant this reads is the one DOSETUP is
    // deriving in the same cycle, not the one still in the register.
    wire eff_xdec = (dm0_dosetup || do_resetup) ? setup_xdec : oct_xdec;
    wire span_lr_drop = (dm0_adrmode == AM_SPAN) && dm0_lronly && eff_xdec;

    // One pixel per host word unless RWPACKED; the primitive then ends after
    // that many pixels and the next GO carries the next word.
    wire host_mode = (dm0_opcode == OP_READ) || dm0_colorhost;

    // CLIPMODE's CID-match field, [12:9], IS A MASK OF PERMITTED WINDOW IDs
    // AND NOT AN ID TO EQUAL. The two-bit CID in the auxiliary planes indexes
    // a bit of it; 0xF permits all four and is how the clip is switched off.
    // Reading it as an equality - which this did until build 43 - let a draw
    // through on exactly the windows it should have clipped and clipped the
    // one it should have let through.
    wire  [3:0] cid_match = clipmode[12:9];
    wire        cid_gate  = (cid_match != 4'hF)
                         && ((dm0_opcode == OP_DRAW) || (dm0_opcode == OP_SCR2SCR));

    // FASTCLEAR (DRAWMODE1 bit 17): every drawn pixel takes COLORVRAM,
    // replicated to the plane depth, ignoring the colour source, the logic
    // op and the patterns - IRIS's process_pixel_fastclear, active for DRAW
    // without host data when the CID clip is off. Xsgi fills every large
    // background this way; ignoring the bit painted the login panel with a
    // stale colour source: index 0, black (docs/design/newport-vdma.md).
    wire        fastclear_act = dm1_fastclear && (cid_match == 4'hF)
                              && (dm0_opcode == OP_DRAW) && !host_mode;

    // The logic op the write path actually applies.
    wire  [3:0] eff_logicop = fastclear_act ? 4'h3 : dm1_logicop;

    // Where the walk goes for the next pixel of a primitive.
    dr_state_t next_pixel_state;
    assign next_pixel_state = (dm0_opcode == OP_SCR2SCR) ? DR_SRC_RD
                            : need_dst_read              ? DR_DST_RD
                            :                              DR_WR;

    // The first pixel's state, which is the same choice plus the opaque-fill
    // fast path. A line never takes it: its walk is not a run of adjacent
    // pixels and DR_FILL's row bookkeeping does not apply.
    dr_state_t first_pixel_state;
    assign first_pixel_state =
        (dm0_opcode == OP_SCR2SCR) ? DR_SRC_RD
      : need_dst_read              ? DR_DST_RD
      : ((dm0_opcode == OP_DRAW) && !host_mode && !dm0_is_line) ? DR_FILL
      :                              DR_WR;

    // Host mode forces STOPONX: a READ or a host-sourced DRAW moves one word
    // per GO, and the walk has to keep going until that word is full or empty
    // whatever the flag says. getfbdepth writes two 12-bit pixels with a
    // single write to HOSTRW0 and no STOPONX at all, and without this it
    // would place one of them, read back 0x0abc0000, and conclude the frame
    // buffer is 8 planes deep.
    wire eff_stoponx = dm0_stoponx || host_mode;
    // THE END OF A ROW IS THE END OF A ROW WHATEVER STOPONX SAYS. The flag
    // decides whether the primitive carries on afterwards, not whether the
    // row ended - and the row's end is what SKIPLAST names and what wraps x
    // back to XSAVE. Reading STOPONX into this test left a one-pixel-wide
    // block in step mode stepping sideways for ever instead of dropping to
    // the next row.
    wire row_done = x_at_end;
    // LENGTH32 IS A PAUSE, NOT A ROW END. It clamps a span to 32 pixels and
    // the primitive stops where it stands for the next GO to continue; it
    // does not wrap x back to XSAVE and it does not advance y, which is what
    // treating it as a row end used to do.
    wire len32_stop = span_clamped && (span_left <= 6'd1) && !row_done;
    // The pixel SKIPLAST names: the last of a row, or the last of a line.
    wire prim_last = dm0_is_line ? line_last : row_done;
    // LSADVLAST decides whether the stipple steps off the last pixel of a
    // line. It matters for a connected polyline: without it the joint pixel
    // would take the same stipple bit twice.
    wire pat_advance = !dm0_is_line || !line_last || dm0_lsadvlast;

    // DOSETUP'S DELTAS ARE THE FIXED-POINT DIFFERENCE SHIFTED DOWN, NOT THE
    // DIFFERENCE OF THE INTEGER PARTS, and the two are not the same number.
    // A line from x=123.875 to x=145.625 has a fixed-point difference of
    // 21.75, which truncates to 21, while its integer endpoints are 22 apart.
    // Every Bresenham parameter comes out of that one: the octant, both
    // increments and the decision variable. Taking the integer difference
    // instead put the whole error term one step out, and a fractional line
    // then stepped its minor axis in the wrong places along its whole length
    // - which is exactly what verilator/tb_rex3draw.cpp caught.
    wire signed [27:0] fp_xs = $signed({xstart[26], xstart[26:0]});
    wire signed [27:0] fp_xe = $signed({xend[26],   xend[26:0]});
    wire signed [27:0] fp_ys = $signed({ystart[26], ystart[26:0]});
    wire signed [27:0] fp_ye = $signed({yend[26],   yend[26:0]});
    wire signed [27:0] setup_fdx = fp_xe - fp_xs;
    wire signed [27:0] setup_fdy = fp_ye - fp_ys;
    wire signed [27:0] setup_afdx = setup_fdx[27] ? -setup_fdx : setup_fdx;
    wire signed [27:0] setup_afdy = setup_fdy[27] ? -setup_fdy : setup_fdy;
    wire signed [16:0] setup_adx = setup_afdx[27:11];
    wire signed [16:0] setup_ady = setup_afdy[27:11];
    wire setup_xdec   = setup_fdx[27];
    wire setup_ydec   = setup_fdy[27];
    wire setup_xmajor = setup_adx > setup_ady;
    wire signed [16:0] setup_major = setup_xmajor ? setup_adx : setup_ady;
    wire signed [16:0] setup_minor = setup_xmajor ? setup_ady : setup_adx;

    // AND THE PIXEL COUNT IS THE OTHER ONE. The walk runs for as many pixels
    // as the integer endpoints are apart, the fractional-endpoint correction
    // works in integer pixels too, and the continuation test compares integer
    // axes. Only the Bresenham parameters take the shifted difference. IRIS
    // is inconsistent here in exactly this way and the hardware it was
    // written against evidently is too.
    wire signed [16:0] int_dx = fp_int(xend) - fp_int(xstart);
    wire signed [16:0] int_dy = fp_int(yend) - fp_int(ystart);
    wire signed [16:0] int_adx = int_dx[16] ? -int_dx : int_dx;
    wire signed [16:0] int_ady = int_dy[16] ? -int_dy : int_dy;
    wire signed [16:0] int_major = (int_adx > int_ady) ? int_adx : int_ady;

    // A line continuation whose own two endpoints disagree with the octant
    // about which axis is major re-derives the whole setup.
    wire do_resetup = !dm0_dosetup && dm0_is_line && (int_adx != int_ady)
                    && ((int_adx > int_ady) != bresoctinc1[26]);

    // WITHOUT EITHER STOP FLAG A LINE IS ONE PIXEL PER GO, and the step
    // happens anyway so that the next GO starts where this one left off -
    // which is how a driver walks a line by hand. SKIPFIRST and SKIPLAST do
    // not apply there, because the single pixel is both.
    wire line_step_one = dm0_is_line && !dm0_stoponx && !dm0_stopony;
    wire [16:0] line_full = {1'b0, int_major[15:0]} + 17'd1;
    wire [16:0] line_count = line_step_one ? 17'd1
                           : ((dm0_length32 && (line_full > 17'd32)) ? 17'd32
                                                                    : line_full);

    // ---- the Bresenham registers -------------------------------------------
    // DOSETUP derives all three and the octant; a command without it walks on
    // whatever they already hold, which is how a connected polyline carries
    // one segment's error term into the next. incr1 = 2*minor, incr2 =
    // 2*(minor - major), d = incr1 - major. The field widths are the chip's:
    // 20 bits unsigned, 21 bits signed, 27 bits signed.
    wire signed [20:0] setup_incr1 = $signed({4'b0, setup_minor}) <<< 1;
    wire signed [20:0] setup_incr2 = ($signed({4'b0, setup_minor})
                                    - $signed({4'b0, setup_major})) <<< 1;
    wire signed [26:0] setup_d     = $signed({6'b0, setup_incr1})
                                   - $signed({10'b0, setup_major});

    wire signed [31:0] bres_incr1 = $signed({12'b0, bresoctinc1[19:0]});
    wire signed [31:0] bres_incr2 = $signed({{11{bresrndinc2[20]}}, bresrndinc2[20:0]});
    wire signed [31:0] bres_d     = $signed({{5{bresd[26]}}, bresd[26:0]});

    // The octant's four increments. y-major steps y every pixel and x only on
    // the diagonal; x-major the other way round. `incry` is subtracted, which
    // is why a y that is increasing carries -1 here.
    wire signed [16:0] oct_xs = oct_xdec ? -17'sd1 : 17'sd1;
    wire signed [16:0] oct_ys = oct_ydec ?  17'sd1 : -17'sd1;
    wire oct_ymajor = !bresoctinc1[26];
    wire signed [16:0] incrx1 = oct_ymajor ? 17'sd0 : oct_xs;
    wire signed [16:0] incrx2 = oct_xs;
    wire signed [16:0] incry1 = oct_ymajor ? oct_ys : 17'sd0;
    wire signed [16:0] incry2 = oct_ys;

    wire bres_diag = !bres_d[31];       // d >= 0 takes the diagonal step
    wire signed [16:0] line_x_step = cx + (bres_diag ? incrx2 : incrx1);
    wire signed [16:0] line_y_step = cy - (bres_diag ? incry2 : incry1);
    wire signed [31:0] line_d_step = bres_d + (bres_diag ? bres_incr2 : bres_incr1);

    // ---- the fractional endpoint -------------------------------------------
    // F_LINE and A_LINE are given endpoints with four fractional bits, at
    // [10:7] of the 21.11 coordinate. The sub-pixel position biases the
    // initial error term, which is how a fan of lines from one point comes
    // out evenly spaced instead of quantised into steps. The eight octants
    // fold into the first by reflecting the two fractions and swapping the
    // axes; this is IRIS's fline_apply_fract, whose own comment records that
    // the base d differs from I_LINE's by exactly (minor - major) and that
    // leaving the correction out flips d's sign on the first step of a
    // near-degenerate line and loses a row for the rest of it.
    wire [3:0] frac_xs = xstart[10:7];
    wire [3:0] frac_ys = ystart[10:7];
    wire [3:0] frac_xe = xend[10:7];
    wire [3:0] frac_ye = yend[10:7];
    wire [2:0] fr_oct  = bresoctinc1[26:24];
    wire fr_swap = (fr_oct <= 3'd3);    // every y-major octant swaps the axes

    logic [5:0] fr_xf, fr_yf;
    always_comb begin
        case (fr_oct)
            3'd0: begin fr_xf = 6'h10 - {2'b0, frac_ys}; fr_yf = {2'b0, frac_xs}; end
            3'd1: begin fr_xf = {2'b0, frac_ys};         fr_yf = {2'b0, frac_xs}; end
            3'd2: begin fr_xf = 6'h10 - {2'b0, frac_ys}; fr_yf = 6'h10 - {2'b0, frac_xs}; end
            3'd3: begin fr_xf = {2'b0, frac_ys};         fr_yf = 6'h10 - {2'b0, frac_xs}; end
            3'd4: begin fr_xf = {2'b0, frac_xs};         fr_yf = 6'h10 - {2'b0, frac_ys}; end
            3'd6: begin fr_xf = 6'h10 - {2'b0, frac_xs}; fr_yf = 6'h10 - {2'b0, frac_ys}; end
            3'd7: begin fr_xf = 6'h10 - {2'b0, frac_xs}; fr_yf = {2'b0, frac_ys}; end
            default: begin fr_xf = {2'b0, frac_xs};      fr_yf = {2'b0, frac_ys}; end
        endcase
    end

    wire signed [17:0] fr_dxa = $signed({1'b0, int_adx});
    wire signed [17:0] fr_dya = $signed({1'b0, int_ady});
    wire signed [17:0] fr_dx  = fr_swap ? fr_dya : fr_dxa;
    wire signed [17:0] fr_dy  = fr_swap ? fr_dxa : fr_dya;
    wire signed [23:0] fr_tx  = ($signed({6'b0, fr_dx}) * $signed({18'b0, fr_yf})) >>> 4;
    wire signed [23:0] fr_ty  = ($signed({6'b0, fr_dy}) * $signed({18'b0, fr_xf})) >>> 4;
    wire signed [16:0] fr_x2 = cx + incrx2;
    wire signed [16:0] fr_y2 = cy - incry2;

    // THE CORRECTION TAKES THREE CLOCKS, AND THAT IS WHY. Written as one
    // expression it is: two coordinate subtractions and their absolute
    // values, a fold through the octant, two multiplies, four adds, a
    // comparison, a conditional step, and then - because the step can move
    // the start a whole pixel along the major axis - another subtraction,
    // absolute value, maximum, increment and clamp to get the pixel count.
    // Build 43's first fit put all of that between two flip-flops and missed
    // the core clock by 5.48 ns on that path alone, with every one of the
    // four hundred worst paths in the design ending at `line_left`.
    //
    // So: stage one folds the fractions and takes the two products, stage two
    // makes the decision and moves the position, stage three counts the
    // pixels from where the position ended up. Three clocks once per
    // fractional line primitive is not a cost anything can measure.
    logic signed [23:0] frq_tx, frq_ty;
    logic signed [17:0] frq_dx, frq_dy, frq_maj;

    wire signed [31:0] fr2_d = bres_d
                             + {{14{frq_dy[17]}}, frq_dy} - {{14{frq_dx[17]}}, frq_dx}
                             + (({{8{frq_tx[23]}}, frq_tx} - {{8{frq_ty[23]}}, frq_ty}) <<< 1);
    wire signed [31:0] fr2_e = fr2_d - ({{14{frq_maj[17]}}, frq_maj} <<< 1);
    wire fr_takes_step = (fr2_e > 32'sd0);

    // Stage three: the pixel count, from the settled position. Every input
    // here is a register, which is the whole point of the split.
    wire signed [16:0] pc_dx  = cx_end - cx;
    wire signed [16:0] pc_dy  = cy_end - cy;
    wire signed [16:0] pc_adx = pc_dx[16] ? -pc_dx : pc_dx;
    wire signed [16:0] pc_ady = pc_dy[16] ? -pc_dy : pc_dy;
    wire signed [16:0] pc_maj = (pc_adx > pc_ady) ? pc_adx : pc_ady;
    wire [16:0] pc_full  = {1'b0, pc_maj[15:0]} + 17'd1;
    wire [16:0] pc_count = line_step_one ? 17'd1
                         : ((dm0_length32 && (pc_full > 17'd32)) ? 17'd32
                                                                 : pc_full);

    // A_LINE's endpoint filter: a sub-pixel endpoint whose AWEIGHT entry is
    // zero contributes nothing, so the line skips it. The weight tables are
    // read for this and for nothing else - the coverage they describe would
    // need a blend per pixel that no shape in the corpus asks for.
    wire [4:0] aw_first_i = (({1'b0, frac_xs} + {1'b0, frac_ys}) > 5'd15)
                          ? 5'd15 : ({1'b0, frac_xs} + {1'b0, frac_ys});
    wire [4:0] aw_last_i  = (({1'b0, frac_xe} + {1'b0, frac_ye}) > 5'd15)
                          ? 5'd15 : ({1'b0, frac_xe} + {1'b0, frac_ye});
    // THE TABLE IS EIGHT NIBBLES AND THE INDEX GOES TO FIFTEEN. Two
    // fractions of four bits each add to thirty, clamped to fifteen, and a
    // 32-bit register only holds eight entries - so the top half of the index
    // wraps. That is what IRIS does (a Rust shift past the width masks its
    // count) and what this matches; whether the part reads the same entry
    // twice or a second table nobody has documented is open, and it only ever
    // decides whether one endpoint pixel of an anti-aliased line is drawn.
    wire [31:0] aw0_sh = aweight0 >> {aw_first_i[2:0], 2'b0};
    wire [31:0] aw1_sh = aweight1 >> {aw_last_i[2:0],  2'b0};
    // The first endpoint's test is read AFTER the setup has spent its
    // fraction, so a command that ran one never filters its first pixel.
    wire aline_skip_first = dm0_endptfilter && (dm0_adrmode == AM_ALINE)
                         && !(dm0_dosetup || do_resetup)
                         && ((frac_xs != 4'd0) || (frac_ys != 4'd0))
                         && (aw0_sh[3:0] == 4'd0);
    wire aline_skip_last  = dm0_endptfilter && (dm0_adrmode == AM_ALINE)
                         && ((frac_xe != 4'd0) || (frac_ye != 4'd0))
                         && (aw1_sh[3:0] == 4'd0);

    // Screen coordinates. XYMOVE offsets the destination of a screen-to-screen
    // copy unconditionally and any other primitive only when XYOFFSET is set.
    wire apply_move = (dm0_opcode == OP_SCR2SCR) || dm0_xyoffset;
    wire signed [16:0] win_x  = $signed(xywin[31:16]);
    wire signed [16:0] win_y  = $signed(xywin[15:0]);
    wire signed [16:0] move_x = $signed(xymove[31:16]);
    wire signed [16:0] move_y = $signed(xymove[15:0]);

    // TOPSCAN is the scan line at the top of the display, and the frame buffer
    // wraps at its own height rather than at a power of two of the address.
    // Taking the low eleven bits instead of the low ten put every row of a
    // clear 1024 lines below the screen, where the frame buffer store simply
    // dropped the writes - the machine cleared nothing and read back zero.
    localparam int FB_LINES_LOG2 = $clog2(FB_LINES);
    function automatic logic [10:0] fb_row(input logic signed [16:0] y_raw,
                                           input logic move);
        logic signed [20:0] t;
        begin
            t = $signed({4'b0, y_raw}) + $signed({4'b0, win_y})
              + (move ? $signed({4'b0, move_y}) : 21'sd0)
              - COORD_BIAS - $signed({10'b0, topscan[10:0]}) - 21'sd1;
            fb_row = {{(11 - FB_LINES_LOG2){1'b0}}, t[FB_LINES_LOG2-1:0]};
        end
    endfunction

    function automatic logic signed [16:0] fb_col(input logic signed [16:0] x_raw,
                                                  input logic move);
        fb_col = x_raw + win_x + (move ? move_x : 17'sd0) - COORD_BIAS;
    endfunction

    wire signed [16:0] dst_x = fb_col(cx, apply_move);
    wire        [10:0] dst_y = fb_row(cy, apply_move);
    wire signed [16:0] src_x = fb_col(cx, 1'b0);
    wire        [10:0] src_y = fb_row(cy, 1'b0);

    // FOUR BYTES PER PIXEL PER PLANE SET, IN TWO REGIONS. The drawing planes
    // and the auxiliary planes are 24 bits each; each lives in its own region
    // as a 32-bit slot per pixel on the 2048-pixel stride, two pixels to a
    // 64-bit word - pixel x in the low half when x is even, the high half when
    // it is odd, picked with the port's byte enables. The auxiliary region
    // starts 8 MB above the drawing one. This is IRIS's shape (rex3.rs keeps
    // fb_rgb and fb_aux as two arrays), and it is what lets the display fetch
    // half as much per pixel: see rtl/mister/fb_linecache.sv and docs/reference/mister-integration.md.
    //
    // THE SPARE BYTE OF A DRAWING SLOT CARRIES A COPY OF THE WINDOW-ID NIBBLE
    // (aux[3:0], the same four bits the CID clip compares), kept current by a
    // second write whenever byte 0 of the auxiliary slot changes. It is there
    // so that a CID-clipped draw into the drawing planes - which is most of
    // what X does under an overlapping window - still costs one read and one
    // write per pixel rather than two reads. Popup and window-ID writes are
    // rare next to that and pay the extra write.
    localparam logic [31:0] AUX_OFF = 32'h0080_0000;
    function automatic logic [31:0] fb_slot_addr(input logic signed [16:0] x,
                                                 input logic [10:0] y,
                                                 input logic aux);
        fb_slot_addr = FB_BASE + (aux ? AUX_OFF : 32'h0)
                     + (((({21'b0, y}) << FB_STRIDE_LOG2) + {21'b0, x[10:0]}) << 2);
    endfunction

    // ---- clipping ---------------------------------------------------------
    wire [4:0] ensmask = clipmode[4:0];
    function automatic logic in_box(input logic signed [16:0] x,
                                    input logic signed [16:0] y,
                                    input logic [31:0] mx, input logic [31:0] my);
        in_box = (x >= $signed(mx[31:16])) && (x <= $signed(mx[15:0]))
              && (y >= $signed(my[31:16])) && (y <= $signed(my[15:0]));
    endfunction

    logic clip_ok;
    always_comb begin
        automatic logic signed [16:0] ax, ay;
        automatic logic any;
        // SMASK0 is window relative: it tests the raw coordinate. SMASK1..4
        // are screen absolute, and the host pre-biases them by the same 4096
        // the coordinates carry, so they test the biased value.
        ax = cx + win_x + (apply_move ? move_x : 17'sd0);
        ay = cy + win_y + (apply_move ? move_y : 17'sd0);
        clip_ok = 1'b1;
        any = 1'b0;
        if (ensmask[0] && !in_box(cx, cy, smask0x, smask0y)) clip_ok = 1'b0;
        if (|ensmask[4:1]) begin
            if (ensmask[1] && in_box(ax, ay, smask1x, smask1y)) any = 1'b1;
            if (ensmask[2] && in_box(ax, ay, smask2x, smask2y)) any = 1'b1;
            if (ensmask[3] && in_box(ax, ay, smask3x, smask3y)) any = 1'b1;
            if (ensmask[4] && in_box(ax, ay, smask4x, smask4y)) any = 1'b1;
            if (!any) clip_ok = 1'b0;
        end
        // Off the frame buffer entirely.
        if (dst_x < 0 || dst_x >= (1 << FB_STRIDE_LOG2)) clip_ok = 1'b0;
    end

    // ---- plane read/write --------------------------------------------------
    // A drawing slot is {4'b0, cid[3:0], rgb[23:0]}; an auxiliary slot is
    // {8'b0, aux[23:0]}. The aux value carries the overlay at [23:8], the
    // popup at [7:6]/[3:2] and the window ID at [5:4]/[1:0], two buffers of
    // each, which is the layout the PROM's plane write masks describe: OLAY
    // 0xFFFF00, PUP 0x0000CC, CID 0x000033. A destination read fetches the
    // slot of whichever plane set is being drawn; `dst_half` is that slot.
    wire is_aux_plane = (dm1_planes == 3'd4) || (dm1_planes == 3'd5)
                     || (dm1_planes == 3'd6);
    wire [23:0] dst_rgb = dst_half[23:0];
    wire [23:0] dst_aux = dst_half[23:0];
    wire [23:0] dst_plane = dst_half[23:0];
    // The window-ID nibble the CID clip compares: aux[3:0], read from the
    // auxiliary slot itself or from its copy in the drawing slot.
    wire  [3:0] cid_nib = is_aux_plane ? dst_half[3:0] : dst_half[27:24];

    // ONE SLOT, ONE PLANE VALUE. The shift and mask a plane selection reads
    // and writes with - IRIS's plane_shift_mask, and the same extraction for
    // the destination slot and for a screen-to-screen source.
    //
    // THE DEVIATION FROM IRIS IS PLANES 0, 3 AND 7. IRIS maps only 1 (RGB)
    // and 2 (RGBA) onto the drawing planes and drops a write through any
    // other unmapped selection; this maps every non-auxiliary selection onto
    // them, because that is what the PROM's own console path and
    // its own tb_rex3.cpp bench have always drawn through. No corpus shape
    // uses one, so nothing observes the difference.
    function automatic logic [23:0] plane_of(input logic [23:0] slot);
        case (dm1_planes)
            3'd4:    plane_of = dm1_dblsrc ? {16'b0, slot[23:16]} : {16'b0, slot[15:8]};
            3'd5:    plane_of = dm1_dblsrc ? {22'b0, slot[7:6]}   : {22'b0, slot[3:2]};
            3'd6:    plane_of = dm1_dblsrc ? {22'b0, slot[5:4]}   : {22'b0, slot[1:0]};
            default: case (dm1_drawdepth)
                        2'd0:    plane_of = dm1_dblsrc ? {20'b0, slot[7:4]}
                                                       : {20'b0, slot[3:0]};
                        2'd1:    plane_of = dm1_dblsrc ? {16'b0, slot[15:8]}
                                                       : {16'b0, slot[7:0]};
                        2'd2:    plane_of = {12'b0, slot[11:0]};
                        default: plane_of = slot;
                     endcase
        endcase
    endfunction

    wire [23:0] dst_val = plane_of(dst_plane);
    wire [23:0] src_val = plane_of(src_pix);

    // ---- colour depth conversion -------------------------------------------
    // RGB MODE CARRIES 24-BIT BGR THROUGH THE PIPELINE AND THE PLANES DO NOT.
    // 8 bits is 3-3-2, 12 is 4-4-4, 4 is 1-2-1, and all three packings are
    // irregular enough that a shift would get them wrong. `compress` is the
    // way down and `expand` the way back up for a blend destination or a
    // screen-to-screen source; in colour-index mode both are the identity,
    // because the value already is the plane's own.
    function automatic logic [23:0] expand_rgb(input logic [23:0] v);
        logic [7:0] r, g, b;
        logic [2:0] r3, g3;
        logic [1:0] g2, b2;
        begin
            if (!dm1_rgbmode) expand_rgb = v;
            else case (dm1_drawdepth)
                2'd0: begin
                    g2 = v[2:1];
                    r  = v[0] ? 8'hFF : 8'h00;
                    g  = {g2, g2, g2, g2};
                    b  = v[3] ? 8'hFF : 8'h00;
                    expand_rgb = {b, g, r};
                end
                2'd1: begin
                    r3 = v[2:0];  g3 = v[5:3];  b2 = v[7:6];
                    r  = {r3, r3, r3[2:1]};
                    g  = {g3, g3, g3[2:1]};
                    b  = {b2, b2, b2, b2};
                    expand_rgb = {b, g, r};
                end
                2'd2: expand_rgb = {{2{v[11:8]}}, {2{v[7:4]}}, {2{v[3:0]}}};
                default: expand_rgb = v;
            endcase
        end
    endfunction

    // The Bayer cell for this pixel. Threshold table
    // [0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5] indexed by (y&3)<<2 | (x&3),
    // packed as sixteen nibbles - IRIS's BAYER_PACKED, same order.
    localparam logic [63:0] BAYER_PACKED = 64'h5D7F91B36E4CA280;
    // THE CELL IS INDEXED BY THE WALKER'S OWN COORDINATE, not by the frame
    // buffer address: IRIS passes the pre-window x and y into compress, so a
    // window that moves by an odd number of pixels moves its dither pattern
    // with it rather than shimmering against the screen.
    wire [3:0] bayer_idx = {cy[1:0], cx[1:0]};
    wire [63:0] bayer_sh = BAYER_PACKED >> {bayer_idx, 2'b0};
    wire  [3:0] bayer    = bayer_sh[3:0];

    // One dithered channel: `s` is the scaled 8-bit value, its top nibble is
    // the quantised result, and the Bayer cell decides whether the remainder
    // rounds up. The saturate is IRIS's `.min()` - a channel already at its
    // maximum does not wrap round to black on a high cell.
    function automatic logic [3:0] dith(input logic [7:0] s,
                                        input logic [3:0] maxv);
        logic [3:0] d;
        begin
            d = s[7:4] & maxv;
            if ((s[3:0] > bayer) && (d != maxv)) d = d + 4'd1;
            dith = d;
        end
    endfunction

    function automatic logic [23:0] compress_rgb(input logic [31:0] v);
        logic [7:0] r, g, b, sr, sg, sb;
        logic [3:0] dr, dg, db;
        begin
            r = v[7:0];  g = v[15:8];  b = v[23:16];
            if (!dm1_rgbmode) compress_rgb = v[23:0];
            else if (!dm1_dither) case (dm1_drawdepth)
                2'd0:    compress_rgb = {20'b0, b[7], g[7:6], r[7]};
                2'd1:    compress_rgb = {16'b0, b[7:6], g[7:5], r[7:5]};
                2'd2:    compress_rgb = {12'b0, b[7:4], g[7:4], r[7:4]};
                default: compress_rgb = v[23:0];
            endcase
            else case (dm1_drawdepth)
                2'd0: begin
                    sr = (r >> 3) - (r >> 4);
                    sg = (g >> 2) - (g >> 4);
                    sb = (b >> 3) - (b >> 4);
                    dr = dith(sr, 4'd1);
                    dg = dith(sg, 4'd3);
                    db = dith(sb, 4'd1);
                    compress_rgb = {20'b0, db[0], dg[1:0], dr[0]};
                end
                2'd1: begin
                    sr = (r >> 1) - (r >> 4);
                    sg = (g >> 1) - (g >> 4);
                    sb = (b >> 2) - (b >> 4);
                    dr = dith(sr, 4'd7);
                    dg = dith(sg, 4'd7);
                    db = dith(sb, 4'd3);
                    compress_rgb = {16'b0, db[1:0], dg[2:0], dr[2:0]};
                end
                2'd2: begin
                    sr = r - (r >> 4);
                    sg = g - (g >> 4);
                    sb = b - (b >> 4);
                    dr = dith(sr, 4'd15);
                    dg = dith(sg, 4'd15);
                    db = dith(sb, 4'd15);
                    compress_rgb = {12'b0, db, dg, dr};
                end
                // 24 bits is already the pipeline's own depth: nothing to
                // quantise, so nothing to dither.
                default: compress_rgb = v[23:0];
            endcase
        end
    endfunction

    // ---- the source colour --------------------------------------------------
    // The pixel at the top of the host shifter, in its slot, expanded to
    // 24-bit BGR when the pipeline is carrying colour rather than an index.
    // 4bpp and 8bpp share an 8-bit slot; 12bpp sits in the low 12 bits of a
    // 16-bit slot, which is what makes getfbdepth's 0x0abc0def two pixels and
    // not three bytes of tightly packed data. HOSTDEPTH's encoding is
    // 4/8/12/32 and DRAWDEPTH's is 4/8/12/24 - not the same order, and not
    // the same last entry.
    logic [31:0] host_pix;
    always_comb begin
        logic [7:0] hr, hg, hb;
        logic [1:0] q;
        case (dm1_hostdepth)
            2'd0: begin
                if (!dm1_rgbmode) host_pix = {28'b0, host_shift[59:56]};
                else begin
                    q = host_shift[58:57];
                    host_pix = {8'h0,
                                host_shift[59] ? 8'hFF : 8'h00,
                                {q, q, q, q},
                                host_shift[56] ? 8'hFF : 8'h00};
                end
            end
            2'd1: begin
                if (!dm1_rgbmode) host_pix = {24'b0, host_shift[63:56]};
                else begin
                    hr = {host_shift[58:56], host_shift[58:56], host_shift[58:57]};
                    hg = {host_shift[61:59], host_shift[61:59], host_shift[61:60]};
                    hb = {host_shift[63:62], host_shift[63:62],
                          host_shift[63:62], host_shift[63:62]};
                    host_pix = {8'h0, hb, hg, hr};
                end
            end
            2'd2: begin
                if (!dm1_rgbmode) host_pix = {20'b0, host_shift[59:48]};
                else host_pix = {8'h0, {2{host_shift[59:56]}},
                                 {2{host_shift[55:52]}}, {2{host_shift[51:48]}}};
            end
            default: host_pix = host_shift[63:32];
        endcase
    end

    // ZPATTERN and the line stipple both have an opaque mode: a bit that
    // misses does not drop the pixel, it draws it in COLORBACK. That is how a
    // stippled line paints its own background and how Ng1TpDrawbitmap paints
    // a glyph cell rather than just its ink.
    // FASTCLEAR COLLAPSES THE WHOLE PIXEL PIPELINE - "no support for any per
    // pixel operation, flat fill only, via COLORVRAM" (rex3.pdf 3.5.5). It
    // switches off both patterns, the dither, the shade DDAs, the alpha
    // function, the blend and the logic op, which is what IRIS's unpack folds
    // away and why a fastclear costs one write and no read.
    //
    // THE PATTERNS AND THE ALPHA FUNCTION ARE THE DRAW OPCODE'S ALONE. A
    // screen-to-screen copy runs neither: IRIS's process_pixel_scr2scr has no
    // pattern prologue and no afunction, so a copy under a live ZPATTERN
    // copies every pixel rather than a stippled subset. The DDAs and the
    // pattern cursors still advance, because the walk advances them whatever
    // the pixel body was.
    wire pixel_is_draw = (dm0_opcode == OP_DRAW);
    wire zpat_en  = dm0_enzpattern && !fastclear_act;
    wire lspat_en = dm0_enlspat    && !fastclear_act;
    wire shade_en = dm0_shade      && !fastclear_act;
    wire zpat_bit_set = zpattern[zbit];
    wire lspat_bit_set = lspattern[patbit];
    wire zpat_miss  = zpat_en  && !zpat_bit_set && pixel_is_draw;
    wire lspat_miss = lspat_en && !lspat_bit_set && pixel_is_draw;
    wire use_bg = (zpat_miss && dm0_zpopaque) || (lspat_miss && dm0_lsopaque);
    // A miss with no opaque bit behind it drops the pixel entirely.
    wire pat_drop = (zpat_miss && !dm0_zpopaque) || (lspat_miss && !dm0_lsopaque);

    // Whether this pixel consumes a word from the host shifter: only when the
    // patterns let it through and the mode says the colour or the alpha comes
    // from the host. IRIS fetches in the same place, after the patterns and
    // before the address.
    wire host_consume = !use_bg && !pat_drop
                     && (dm0_colorhost || dm0_alphahost);

    // Source colour, 32 bits: BGR in the low three bytes and the alpha the
    // compare and the blend use in the top one. The alpha comes from the DDA
    // or from the host independently of the colour, which is what lets a
    // colour-index program stream a host alpha alongside its indices.
    wire [7:0] src_alpha = dm0_alphahost ? host_pix[31:24]
                                         : clamp_comp(coloralpha);
    logic [31:0] raw_src;
    always_comb begin
        if (dm0_opcode == OP_SCR2SCR) raw_src = {8'h0, expand_rgb(src_val)};
        else if (use_bg)              raw_src = colorback;
        else begin
            // COLORI is the red DDA in colour-index mode and all three in
            // RGB mode, each clamped on the way out.
            raw_src = dm0_colorhost
                    ? {src_alpha, host_pix[23:0]}
                    : (dm1_rgbmode
                       ? {src_alpha, clamp_comp(colorblue), clamp_comp(colorgrn),
                          clamp_comp(colorred)}
                       : {src_alpha, 3'b0, colorred[31:11]});
        end
    end

    // ---- the alpha function -------------------------------------------------
    // Three OR-able relations against ALPHAREF; all three set is the disable
    // the PROM writes in every command.
    logic afunc_pass;
    always_comb begin
        case (dm1_compare)
            3'd0:    afunc_pass = 1'b0;
            3'd1:    afunc_pass = raw_src[31:24] <  alpharef[7:0];
            3'd2:    afunc_pass = raw_src[31:24] == alpharef[7:0];
            3'd3:    afunc_pass = raw_src[31:24] <= alpharef[7:0];
            3'd4:    afunc_pass = raw_src[31:24] >  alpharef[7:0];
            3'd5:    afunc_pass = raw_src[31:24] != alpharef[7:0];
            3'd6:    afunc_pass = raw_src[31:24] >= alpharef[7:0];
            default: afunc_pass = 1'b1;
        endcase
    end

    // ---- alpha blending -----------------------------------------------------
    // Four channels of s*sf + d*df over 255. The two selectors name each
    // other's colour - BF_OC is the destination channel when it is the source
    // multiplier and the source channel when it is the destination one - and
    // BLENDALPHA decides whether the source multiplier sees the real source
    // alpha or a flat one, leaving DFACTOR's own definition alone (spec 3.8,
    // and the trailing clause of it is load-bearing).
    //
    // THE DIVIDE BY 255 IS EXACT, not a shift. (n * 131587) >> 25 equals
    // n / 255 for every n a channel can produce - the largest is
    // 255*255 + 255*255 = 130050 - and 131587 is 0x20203, three shifts and
    // two adds. A plain >> 8 would darken every blended pixel by a part in
    // 256, which over a screen full of translucent windows is visible.
    wire [31:0] blend_dst = dm1_backblend ? colorback : {8'h0, expand_rgb(dst_val)};
    wire  [7:0] sa_real = raw_src[31:24];
    wire  [7:0] sa_src  = dm1_blendalpha ? sa_real : 8'hFF;

    function automatic logic [7:0] bfactor(input logic [2:0] sel,
                                           input logic [7:0] c,
                                           input logic [7:0] a);
        case (sel)
            3'd0:    bfactor = 8'h00;
            3'd1:    bfactor = 8'hFF;
            3'd2:    bfactor = c;
            3'd3:    bfactor = 8'hFF - c;
            3'd4:    bfactor = a;
            3'd5:    bfactor = 8'hFF - a;
            default: bfactor = 8'h00;
        endcase
    endfunction

    function automatic logic [7:0] blend_chan(input logic [7:0] s,
                                              input logic [7:0] d);
        logic [16:0] acc;
        logic [41:0] scaled;
        logic [16:0] q;
        begin
            acc    = ({9'b0, s} * {9'b0, bfactor(dm1_sfactor, d, sa_src)})
                   + ({9'b0, d} * {9'b0, bfactor(dm1_dfactor, s, sa_real)});
            scaled = {25'b0, acc} * 42'd131587;
            q      = scaled[41:25];
            blend_chan = (q > 17'd255) ? 8'hFF : q[7:0];
        end
    endfunction

    wire [31:0] blended = {blend_chan(raw_src[31:24], blend_dst[31:24]),
                           blend_chan(raw_src[23:16], blend_dst[23:16]),
                           blend_chan(raw_src[15:8],  blend_dst[15:8]),
                           blend_chan(raw_src[7:0],   blend_dst[7:0])};

    // ---- the logic op and the plane write -----------------------------------
    // "Amplify" replicates a plane-depth value into both buffers of its plane
    // so one write mask can reach either or both. The mask constants in
    // ng1_init.c are the check: OLAY 0xFFFF00 covers both overlay buffers,
    // PUP 0x0000CC both popup buffers, CID 0x000033 both window-ID buffers.
    function automatic logic [23:0] amplify(input logic [23:0] v);
        case (dm1_planes)
            3'd4:    amplify = {v[7:0], v[7:0], 8'h00};
            3'd5:    amplify = {16'b0, v[1:0], 2'b0, v[1:0], 2'b0};
            3'd6:    amplify = {18'b0, v[1:0], 2'b0, v[1:0]};
            default: case (dm1_drawdepth)
                        2'd0:    amplify = {16'b0, v[3:0], v[3:0]};
                        2'd1:    amplify = {8'b0, v[7:0], v[7:0]};
                        2'd2:    amplify = {v[11:0], v[11:0]};
                        default: amplify = v;
                     endcase
        endcase
    endfunction

    wire [23:0] src_amp = amplify(compress_rgb(raw_src));
    wire [23:0] dst_amp = amplify(dst_val);

    logic [23:0] logic_out;
    always_comb begin
        case (eff_logicop)
            4'h0:    logic_out = 24'h000000;
            4'h1:    logic_out =  src_amp &  dst_amp;
            4'h2:    logic_out =  src_amp & ~dst_amp;
            4'h3:    logic_out =  src_amp;
            4'h4:    logic_out = ~src_amp &  dst_amp;
            4'h5:    logic_out =  dst_amp;
            4'h6:    logic_out =  src_amp ^  dst_amp;
            4'h7:    logic_out =  src_amp |  dst_amp;
            4'h8:    logic_out = ~(src_amp | dst_amp);
            4'h9:    logic_out = ~(src_amp ^ dst_amp);
            4'hA:    logic_out = ~dst_amp;
            4'hB:    logic_out =  src_amp | ~dst_amp;
            4'hC:    logic_out = ~src_amp;
            4'hD:    logic_out = ~src_amp |  dst_amp;
            4'hE:    logic_out = ~(src_amp & dst_amp);
            default: logic_out = 24'hFFFFFF;
        endcase
    end

    // FASTCLEAR replicates COLORVRAM across the plane's slots and writes it
    // with no per-pixel operation at all. At 12 bits it takes nibbles out of
    // COLORVRAM in RGB mode and the low twelve bits in colour-index mode.
    logic [23:0] fc_color;
    always_comb begin
        case (dm1_drawdepth)
            2'd0:    fc_color = {4'h0, colorvram[3:0], 4'h0, colorvram[3:0],
                                 colorvram[3:0], colorvram[3:0]};
            2'd1:    fc_color = {3{colorvram[7:0]}};
            2'd2:    fc_color = dm1_rgbmode
                              ? {2{colorvram[23:20], colorvram[15:12], colorvram[7:4]}}
                              : {2{colorvram[11:0]}};
            default: fc_color = colorvram[23:0];
        endcase
    end

    // The value that reaches the plane. SCR2SCR's blend arm does not amplify
    // after compressing, which is IRIS's process_pixel_scr2scr and is kept
    // because the comparison bench enforces it.
    logic [23:0] pixel_out;
    always_comb begin
        if (fastclear_act)      pixel_out = fc_color;
        else if (dm1_blend)     pixel_out = (dm0_opcode == OP_SCR2SCR)
                                          ? compress_rgb(blended)
                                          : amplify(compress_rgb(blended));
        else                    pixel_out = logic_out;
    end

    wire [23:0] plane_new = (dst_plane & ~wrmask[23:0]) | (pixel_out & wrmask[23:0]);

    // A read before every write is only needed when the write cannot say what
    // it leaves alone. Two things can make it unnecessary: a write mask whose
    // every byte is all-ones or all-zero, which the frame buffer's byte
    // enables can express on their own, and a logic op that ignores the
    // destination. rex3Clear's 24-bit and overlay passes are both of those;
    // its CID and popup passes are not, because 0x33 and 0xCC split a byte.
    wire mask_byte_clean = (wrmask[7:0]   == 8'h00 || wrmask[7:0]   == 8'hFF)
                        && (wrmask[15:8]  == 8'h00 || wrmask[15:8]  == 8'hFF)
                        && (wrmask[23:16] == 8'h00 || wrmask[23:16] == 8'hFF);
    wire logic_live = !dm1_blend && !fastclear_act;
    wire logic_needs_dst = logic_live
                        && !(eff_logicop == 4'h0 || eff_logicop == 4'h3
                          || eff_logicop == 4'hC || eff_logicop == 4'hF);
    // A blend reads the destination as its second operand - unless BACKBLEND
    // names COLORBACK instead, which is the one blend that needs no read.
    // The CID clip needs the auxiliary planes of every destination pixel, so
    // it forces the read path too - which is also what keeps it out of
    // DR_FILL.
    wire need_dst_read = (dm0_opcode == OP_READ) || logic_needs_dst
                      || (dm1_blend && !dm1_backblend)
                      || !mask_byte_clean || cid_gate;

    wire [23:0] plane_val = need_dst_read ? plane_new : pixel_out;
    // The new slot, in both halves of the port word so that the byte enables
    // alone decide which pixel it lands on. Byte 3 of a drawing slot is never
    // written here - that is the window-ID copy, which DR_CID maintains.
    wire [31:0] slot_new    = {8'h00, plane_val};
    wire [63:0] fb_word_new = {slot_new, slot_new};

    // Byte enables: `be[k]` guards bits [8k+7:8k] of the port word. With the
    // read path the whole 24-bit plane value is exact and all three plane
    // bytes go; without it only the bytes the write mask covers completely.
    wire [2:0] plane_be = {|wrmask[23:16], |wrmask[15:8], |wrmask[7:0]};
    wire [3:0] slot_be  = need_dst_read ? 4'b0111 : {1'b0, plane_be};
    wire [7:0] fb_be_masked = dst_x[0] ? {slot_be, 4'b0000} : {4'b0000, slot_be};

    // An auxiliary write that touches byte 0 changes aux[3:0], so the copy in
    // the drawing slot has to follow (DR_CID). And one that puts anything the
    // display can see - overlay or popup bits - into a line tells the display
    // side's flag table about it (fb_linecache's TRACK_ZERO).
    wire cid_copy_need = is_aux_plane && slot_be[0];
    wire aux_visible   = is_aux_plane
                       && ((slot_be[2] && (plane_val[23:16] != 8'h0))
                        || (slot_be[1] && (plane_val[15:8]  != 8'h0))
                        || (slot_be[0] && (plane_val[3:2]   != 2'b0)));

    // A READ's pixel on its way into the host word: the plane value in
    // colour-index mode, and the 24-bit colour quantised to the host's own
    // depth in RGB mode. HOSTDEPTH's last encoding is 32 bits and carries a
    // full alpha byte, which DRAWDEPTH's 24 has nowhere to put.
    wire [23:0] rd_expanded = expand_rgb(dst_val);
    logic [31:0] host_pack_val;
    always_comb begin
        if (!dm1_rgbmode) case (dm1_hostdepth)
            2'd0:    host_pack_val = {28'b0, dst_val[3:0]};
            2'd1:    host_pack_val = {24'b0, dst_val[7:0]};
            2'd2:    host_pack_val = {20'b0, dst_val[11:0]};
            default: host_pack_val = {8'b0,  dst_val};
        endcase
        else case (dm1_hostdepth)
            2'd0:    host_pack_val = {28'b0, rd_expanded[23], rd_expanded[15:14],
                                      rd_expanded[7]};
            2'd1:    host_pack_val = {24'b0, rd_expanded[23:22], rd_expanded[15:13],
                                      rd_expanded[7:5]};
            2'd2:    host_pack_val = {20'b0, rd_expanded[23:20], rd_expanded[15:12],
                                      rd_expanded[7:4]};
            default: host_pack_val = {8'hFF,  rd_expanded};
        endcase
    end

    // ---- host pixel packing ------------------------------------------------
    // HOSTDEPTH picks the slot width: 12bpp and 32bpp use 16- and 32-bit
    // slots, 4bpp and 8bpp both use an 8-bit slot. Without RWPACKED a word
    // carries one pixel. Which is why getfbdepth's 0x0abc0def is two 12-bit
    // pixels in two 16-bit halves rather than 24 bits of tightly packed data.
    logic [3:0] host_count;
    logic [5:0] host_step;
    always_comb begin
        if (!dm1_rwpacked) begin
            host_count = 4'd1;
            host_step  = 6'd0;
        end else begin
            case (dm1_hostdepth)
                2'd0, 2'd1: begin host_step = 6'd8;
                                  host_count = dm1_rwdouble ? 4'd8 : 4'd4; end
                2'd2:       begin host_step = 6'd16;
                                  host_count = dm1_rwdouble ? 4'd4 : 4'd2; end
                default:    begin host_step = 6'd32;
                                  host_count = dm1_rwdouble ? 4'd2 : 4'd1; end
            endcase
        end
    end

    // A READ'S WORD IS LEFT-JUSTIFIED. "Each data value resides in a field of
    // 8, 16, or 32 bits as programmed by HOSTDEPTH; the leftmost field is the
    // first one to be used" (§3.10). Pixels are packed in at the bottom, so a
    // word that ends early - the last one of a row, or the single pixel of an
    // unpacked read - is shifted up by its empty fields when it is published.
    // It used to be published as it stood, first pixel low and the previous
    // word's bits above it; the X server keeps the TOP bytes of a row's last
    // word and the kernel's frame buffer depth probe tests bits 31:24.
    logic  [5:0] rd_fstep;              // field width
    logic  [3:0] rd_fcount;             // fields in the host word
    always_comb begin
        case (dm1_hostdepth)
            2'd0, 2'd1: begin rd_fstep = 6'd8;  rd_fcount = dm1_rwdouble ? 4'd8 : 4'd4; end
            2'd2:       begin rd_fstep = 6'd16; rd_fcount = dm1_rwdouble ? 4'd4 : 4'd2; end
            default:    begin rd_fstep = 6'd32; rd_fcount = dm1_rwdouble ? 4'd2 : 4'd1; end
        endcase
    end
    wire  [3:0] rd_used  = dm1_rwpacked ? (host_count - host_left) : 4'd1;
    wire  [3:0] rd_empty = rd_fcount - rd_used;
    // Always whole bytes, so the shifter is three byte-wide stages.
    wire  [2:0] rd_jbytes = (rd_fstep == 6'd8)  ? rd_empty[2:0]
                          : (rd_fstep == 6'd16) ? {rd_empty[1:0], 1'b0}
                          :                       {rd_empty[0], 2'b00};
    wire [63:0] rd_word  = host_shift << {rd_jbytes, 3'b000};

    // ---- GIO register read -------------------------------------------------
    // [2:0] version, [3] gfx busy, [4] backend busy, [5] vertical retrace
    // interrupt, [6] video interrupt, [12:7] graphics FIFO level, [17:13]
    // backend FIFO level. Both FIFOs read empty: this engine has none, and an
    // empty answer is what BFIFOWAIT and REX3WAIT are waiting for.
    // USER_STATUS AT 0x133C IS AN ALIAS OF STATUS, not a register of its own,
    // and this is the single most load-bearing line in the file. REX3WAIT -
    // which every drawing routine in ng1_tp.c calls before it touches a
    // register - polls 0x133C, not 0x1338. Answering it with a writable
    // register that read back zero told the PROM the engine was never busy,
    // so it never waited for anything: register writes landed in the middle
    // of running commands and a full-screen clear was overwritten while it
    // was still walking. IRIS answers both offsets from the same word and
    // clears VRINT only on 0x1338, which is what this does.
    logic [31:0] status_val;
    assign status_val = {14'h0, 5'd0, 6'd0, videoint, vrint, 1'b0,
                         gfx_busy, VERSION};

    // REGISTERED, not combinational. The address and `aoff` are only valid
    // during the `sel` cycle, and `ack` comes back the cycle after; a
    // combinational read decode is stale by the time the CPU samples it, and
    // the whole window reads zero. That is exactly how Ng1Probe failed: the
    // write to XSTARTI landed, and the read of XSTART answered nothing.
    logic [31:0] rdata_c;
    always_comb begin
        case (rd_reg)
            R_DRAWMODE1:   rdata_c = drawmode1;
            R_DRAWMODE0:   rdata_c = drawmode0;
            R_LSMODE:      rdata_c = lsmode;
            R_LSPATTERN:   rdata_c = lspattern;
            R_LSPATSAVE:   rdata_c = lspatsave;
            R_ZPATTERN:    rdata_c = zpattern;
            R_COLORBACK:   rdata_c = colorback;
            R_COLORVRAM:   rdata_c = colorvram;
            R_ALPHAREF:    rdata_c = alpharef;
            R_STALL0:      rdata_c = stall0;
            R_SMASK0X:     rdata_c = smask0x;
            R_SMASK0Y:     rdata_c = smask0y;
            R_SETUP:       rdata_c = setup_r;
            R_STEPZ:       rdata_c = stepz;
            R_LSRESTORE:   rdata_c = lsrestore;
            R_LSSAVE:      rdata_c = lssave;
            R_XSTART:      rdata_c = xstart;
            R_YSTART:      rdata_c = ystart;
            R_XEND:        rdata_c = xend;
            R_YEND:        rdata_c = yend;
            R_XSAVE:       rdata_c = {16'h0, xsave[26:11]};
            R_XYMOVE:      rdata_c = xymove;
            R_BRESD:       rdata_c = bresd;
            R_BRESS1:      rdata_c = bress1;
            R_BRESOCTINC1: rdata_c = bresoctinc1;
            R_BRESRNDINC2: rdata_c = bresrndinc2;
            R_BRESE1:      rdata_c = brese1;
            R_BRESS2:      rdata_c = bress2;
            R_AWEIGHT0:    rdata_c = aweight0;
            R_AWEIGHT1:    rdata_c = aweight1;
            R_XSTARTF:     rdata_c = xstart;
            R_YSTARTF:     rdata_c = ystart;
            R_XENDF:       rdata_c = xend;
            R_YENDF:       rdata_c = yend;
            R_XSTARTI:     rdata_c = {16'h0, xstart[26:11]};
            R_XENDF1:      rdata_c = xend;
            R_XYSTARTI:    rdata_c = {xstart[26:11], ystart[26:11]};
            R_XYENDI:      rdata_c = {xend[26:11], yend[26:11]};
            R_XSTARTENDI:  rdata_c = {xstart[26:11], xend[26:11]};
            R_COLORRED:    rdata_c = colorred;
            R_COLORALPHA:  rdata_c = coloralpha;
            R_COLORGRN:    rdata_c = colorgrn;
            R_COLORBLUE:   rdata_c = colorblue;
            R_SLOPERED:    rdata_c = slopered;
            R_SLOPEALPHA:  rdata_c = slopealpha;
            R_SLOPEGRN:    rdata_c = slopegrn;
            R_SLOPEBLUE:   rdata_c = slopeblue;
            R_WRMASK:      rdata_c = wrmask;
            // COLORI READS BACK OUT OF THE DDAs, clamped, because that is
            // where it was written to: a colour-index shade leaves the
            // iterated index in the red DDA and the driver reads it from
            // here.
            R_COLORI:      rdata_c = dm1_rgbmode
                                   ? {8'h0, clamp_comp(colorblue),
                                      clamp_comp(colorgrn), clamp_comp(colorred)}
                                   : {11'h0, colorred[31:11]};
            R_COLORX:      rdata_c = colorx;
            R_SLOPERED1:   rdata_c = slopered1;
            R_HOSTRW0:     rdata_c = hostrw0;
            R_HOSTRW1:     rdata_c = hostrw1;
            R_DCBMODE:     rdata_c = dcbmode;
            R_DCBDATA0:    rdata_c = dcb_result;
            R_DCBDATA1:    rdata_c = dcbdata1;
            R_SMASK1X:     rdata_c = smask1x;
            R_SMASK1Y:     rdata_c = smask1y;
            R_SMASK2X:     rdata_c = smask2x;
            R_SMASK2Y:     rdata_c = smask2y;
            R_SMASK3X:     rdata_c = smask3x;
            R_SMASK3Y:     rdata_c = smask3y;
            R_SMASK4X:     rdata_c = smask4x;
            R_SMASK4Y:     rdata_c = smask4y;
            R_TOPSCAN:     rdata_c = topscan;
            R_XYWIN:       rdata_c = xywin;
            R_CLIPMODE:    rdata_c = clipmode;
            R_STALL1:      rdata_c = stall1;
            R_CONFIG:      rdata_c = config_r;
            R_STATUS:      rdata_c = status_val;
            R_USERSTATUS:  rdata_c = status_val;
            default:       rdata_c = 32'h0;
        endcase
    end

    // A read of DCBDATA0 runs a DCB read transfer, and a write to it runs a
    // write; the register itself is a port rather than storage. Everything
    // else answers in the cycle after the request.
    // ---- the read path -------------------------------------------------------
    // A READ SEES EVERYTHING WRITTEN AND STARTED BEFORE IT. On the part a read
    // is a GFIFO entry (GF_READ) and the bus waits until its answer exists;
    // this engine used to answer at once, from whatever the registers held.
    // The X server's PIO GetImage primes HOSTRW0|GO, waits for GFXBUSY once
    // and then reads HOSTRW0|GO back to back, and IRIS GL's lrectread and
    // libGLcore's ReadPixels do the same - so every word after the first was
    // the previous one, and back-to-back GOs merged into `go_pending`'s one
    // bit (docs/design/rex3-source-audit.md 4.4). Now a read waits: the status registers never (the
    // REX3WAIT/BFIFOWAIT polls must not deadlock against the engine they are
    // waiting for), the display-bus registers for the display bus only, and
    // everything else for the engine. A read's GO fires as it is answered -
    // the word the last GO packed goes back, and the next one starts.
    logic        rd_held;
    logic [12:0] rd_off;
    logic        rd_go;
    wire  [12:0] rd_reg  = rd_held ? rd_off : reg_off;
    wire         rd_isgo = rd_held ? rd_go  : is_go;
    wire         rd_immediate = (rd_reg == R_STATUS) || (rd_reg == R_USERSTATUS)
                             || (rd_reg == R_CONFIG);
    wire         rd_dcbclass  = (rd_reg == R_DCBMODE) || (rd_reg == R_DCBDATA0)
                             || (rd_reg == R_DCBDATA1);
    wire         dcb_quiet    = (dcbst == DCB_IDLE) && !dcb_start_wr && !dcb_start_rd;
    wire         rd_ready     = rd_immediate || (rd_dcbclass ? dcb_quiet : !engine_busy);
    wire         rd_fire      = (rd_held || (sel && !we)) && rd_ready;

    logic go_pending;
    // A SETUP write waiting for the engine, and the setup-only pass it runs.
    logic setup_pending;
    logic setup_only;

    // THE REAL PART HAS A GRAPHICS FIFO AND THIS ONE DOES NOT, so a register
    // write that arrives while a drawing command is running has to wait
    // rather than land on top of it. Ng1TpDrawbitmap fires sixteen
    // rex3SetAndGo(zpattern, ...) in a row with one REX3WAIT before them and
    // none in between: on the part they queue, and here the second one
    // overwrote ZPATTERN in the middle of the first one's span. The symptom
    // was a glyph whose rows had each picked up a pixel or two from the row
    // drawn before them - text that was legible and visibly wrong, which
    // reads as a rasteriser bug rather than as a missing queue.
    //
    // Holding the acknowledgement is what the part does when its FIFO fills:
    // the GIO cycle stalls. What it costs is the overlap of drawing with the
    // next command's bus cycle, which is the whole point of the FIFO; what it
    // buys is that no register can change under a running command. The status
    // register reports both FIFOs empty either way.
    //
    // ONE HELD WRITE IS ENOUGH. REX3 has a single master and the CPU is
    // stalled waiting for this one's acknowledgement, so a second cannot
    // arrive.
    logic        wr_held;
    logic [12:0] wr_off;
    logic [31:0] wr_data;
    logic  [3:0] wr_lanes;
    logic        wr_go;

    wire engine_busy = (dr != DR_IDLE) || go_pending || setup_pending
                    || (dcbst != DCB_IDLE) || dcb_start_wr || dcb_start_rd;
    wire        wr_apply = (wr_held || (sel && we)) && !engine_busy;
    wire [12:0] wr_reg   = wr_held ? wr_off  : reg_off;
    wire [31:0] wr_val   = wr_held ? wr_data : wdata;
    wire        wr_isgo  = wr_held ? wr_go   : is_go;
    wire  [3:0] wr_be    = wr_held ? wr_lanes : be;

    // ---- the VDMA host port's decode and gate ------------------------------
    // Same offset convention as the CPU's: bit 11 is GO, the register is
    // what is left. Only HOSTRW0 is a DMA target; anything else is accepted
    // and dropped so a misprogrammed descriptor cannot wedge the engine.
    wire        nd_go   = nd_off[11];
    // THE LOW THREE BITS ARE THE START BYTE, NOT THE REGISTER. Ng1PixelDma
    // builds the GIO address as (phys & ~7) | (memaddr & 7) (/unix
    // 0x88190440): a buffer at 4..7 mod 8 used to decode as HOSTRW1 and
    // every beat of it was dropped - PutImage drew nothing and GetImage read
    // zeros (docs/design/rex3-source-audit.md 4.4). The MC's engine has already realigned the data.
    wire [12:0] nd_reg  = {nd_off[12], 1'b0, nd_off[10:0]} & 13'h1FF8;
    wire        nd_host = (nd_reg == R_HOSTRW0);

    typedef enum logic [0:0] { ND_IDLE, ND_RD_WAIT } nd_state_t;
    nd_state_t ndst;

    // A beat applies under the same conditions a held CPU write does, and
    // never on the same cycle as one - the CPU's held write wins the tie.
    wire nd_apply = !engine_busy && !wr_held && !(sel && we) && !rd_held;

    logic [15:0] nd_wr_beats;
    logic  [7:0] nd_rd_beats;
    logic  [3:0] nd_drops;
    assign dbg_nd = { nd_wr_beats, nd_rd_beats, nd_drops,
                      (ndst == ND_RD_WAIT), engine_busy, go_pending, wr_held };

`ifdef REX3_DEBUG
    logic [31:0] rex3_gos;
`ifndef REX3_DEBUG_MAX
`define REX3_DEBUG_MAX 1000000
`endif
`endif

    // ======================================================================
    //  Leaving a pixel
    // ======================================================================
    // THE COLOUR DDAs ADVANCE WHETHER OR NOT THE PIXEL WAS DRAWN, and so do
    // the pattern cursors. A clipped pixel still consumed its place in the
    // span, and a shaded span whose DDAs only stepped on the pixels that
    // survived the scissor would come out with a colour discontinuity at
    // every window edge. IRIS calls iterate_shade and iterate_pattern
    // unconditionally after `pixel`, and this is that call.
    //
    // Both walkers - the fill path and the general one - leave a pixel
    // through here, which is the only way the two can be guaranteed to shade
    // and stipple the same.
    task automatic walk_advance;
        logic [31:0] nr, ng, nb, na;
        begin
            first_pix <= 1'b0;

            // ---- the colour DDAs -----------------------------------------
            nr = colorred   + slope_ext(slopered,   24);
            ng = colorgrn   + slope_ext(slopegrn,   20);
            nb = colorblue  + slope_ext(slopeblue,  20);
            na = coloralpha + slope_ext(slopealpha, 20);
            if (shade_en) begin
                if (dm1_rgbmode) begin
                    colorred   <= clamp_shade(nr);
                    colorgrn   <= clamp_shade(ng);
                    colorblue  <= clamp_shade(nb);
                    coloralpha <= clamp_shade(na);
                end else begin
                    // COLOUR-INDEX SHADING ITERATES THE RED DDA AND NOTHING
                    // ELSE, and clamps it only under CICLAMP - by watching one
                    // bit above the index's own width, which is the overflow
                    // the spec names for each depth.
                    colorred <= (dm0_ciclamp && (dm1_drawdepth == 2'd1) && nr[19])
                                  ? 32'h0007_FFFF
                              : (dm0_ciclamp && (dm1_drawdepth == 2'd2) && nr[21])
                                  ? 32'h001F_FFFF
                              :   nr;
                    colorgrn   <= ng;
                    colorblue  <= nb;
                    coloralpha <= na;
                end
            end

            // ---- the pattern cursors -------------------------------------
            // ZPATTERN is a plain 32-bit rotate downwards. The stipple is the
            // same walk slowed by LSREPEAT and cut short by LSLENGTH, and its
            // repeat counter lives in LSMODE so that LSSAVE and LSRESTORE can
            // carry it from one segment of a connected line to the next.
            // BOTH CURSORS OBEY LSADVLAST, not just the stipple's: IRIS calls
            // one iterate_pattern for the pair behind a single `!is_last ||
            // lsadvlast` test. Advancing the z pattern on a line's last pixel
            // and the stipple not leaves the two a step apart for the rest of
            // the primitive's life, and the next continuation GO then paints
            // a different set of pixels - one position out, with the right
            // colours, which is the hardest kind of wrong to see.
            if (zpat_en && pat_advance)
                zbit <= (zbit == 5'd0) ? 5'd31 : zbit - 5'd1;
            if (lspat_en && pat_advance) begin
                if (ls_rcount == 8'd0) begin
                    lsmode[7:0] <= ls_repeat - 8'd1;
                    patbit <= (patbit == ls_wrap) ? 5'd31 : (patbit - 5'd1);
                end else begin
                    lsmode[7:0] <= ls_rcount - 8'd1;
                end
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if (reset) begin
            drawmode0 <= 32'h0; drawmode1 <= 32'h0;
            lsmode <= 32'h0; lspattern <= 32'h0; lspatsave <= 32'h0; zpattern <= 32'h0;
            colorback <= 32'h0; colorvram <= 32'h0; alpharef <= 32'h0; stall0 <= 32'h0;
            smask0x <= 32'h0; smask0y <= 32'h0; setup_r <= 32'h0; stepz <= 32'h0;
            lsrestore <= 32'h0; lssave <= 32'h0;
            xstart <= 32'h0; ystart <= 32'h0; xend <= 32'h0; yend <= 32'h0;
            xsave <= 32'h0; xymove <= 32'h0;
            bresd <= 32'h0; bress1 <= 32'h0; bresoctinc1 <= 32'h0; bresrndinc2 <= 32'h0;
            brese1 <= 32'h0; bress2 <= 32'h0; aweight0 <= 32'h0; aweight1 <= 32'h0;
            colorred <= 32'h0; coloralpha <= 32'h0; colorgrn <= 32'h0; colorblue <= 32'h0;
            slopered <= 32'h0; slopealpha <= 32'h0; slopegrn <= 32'h0; slopeblue <= 32'h0;
            slopered1 <= 32'h0; wrmask <= 32'h0; colorx <= 32'h0;
            patbit <= 5'd31; line_left <= 17'd0;
            frq_tx <= 24'd0; frq_ty <= 24'd0;
            frq_dx <= 18'd0; frq_dy <= 18'd0; frq_maj <= 18'd0;
            skip_first_r <= 1'b0; skip_last_r <= 1'b0;
            xfrac <= 11'd0; yfrac <= 11'd0;
            xefrac <= 11'd0; yefrac <= 11'd0;
            hostrw0 <= 32'h0; hostrw1 <= 32'h0;
            dcbmode <= {21'h0, 4'hF, 7'h0};   // DCBADDR powers up at 0xF
            dcbdata0 <= 32'h0; dcbdata1 <= 32'h0;
            smask1x <= 32'h0; smask1y <= 32'h0; smask2x <= 32'h0; smask2y <= 32'h0;
            smask3x <= 32'h0; smask3y <= 32'h0; smask4x <= 32'h0; smask4y <= 32'h0;
            topscan <= 32'h0; xywin <= 32'h0; clipmode <= 32'h0; stall1 <= 32'h0;
            dr <= DR_IDLE; cx <= 17'sd0; cy <= 17'sd0; cx_end <= 17'sd0;
            cy_end <= 17'sd0; cx_save <= 17'sd0; zbit <= 5'd31;
            span_left <= 6'd32; span_clamped <= 1'b0; first_pix <= 1'b0;
            src_pix <= 24'h0; dst_half <= 32'h0; host_left <= 4'd0;
            dr_after <= DR_IDLE; cid_x <= 17'sd0; cid_y <= 11'd0; cid_val <= 4'h0;
            host_shift <= 64'h0;
            config_r <= 32'h0;
            vrint <= 1'b0; videoint <= 1'b0;
            ack <= 1'b0; rdata <= 32'h0;
            go_pending <= 1'b0;
            setup_pending <= 1'b0;
            setup_only <= 1'b0;
            wr_held <= 1'b0; wr_off <= 13'h0; wr_data <= 32'h0;
            rd_held <= 1'b0; rd_off <= 13'h0; rd_go <= 1'b0;
            wr_lanes <= 4'h0; wr_go <= 1'b0;
            ndst <= ND_IDLE; nd_ack <= 1'b0; nd_rdata <= 64'h0;
            nd_wr_beats <= 16'h0; nd_rd_beats <= 8'h0; nd_drops <= 4'h0;
`ifdef REX3_DEBUG
            rex3_gos <= 32'd0;
`endif
            dcbst <= DCB_IDLE; dcb_sel <= 1'b0; dcb_we <= 1'b0;
            dcb_byte <= 3'd0; dcb_crs_run <= 3'd0; dcb_data <= 32'h0;
            dcb_result <= 32'h0; dcb_is_read <= 1'b0;
            dcb_start_rd <= 1'b0; dcb_start_wr <= 1'b0;
            dcb_rd_waited <= 1'b0;
        end else begin
            ack          <= 1'b0;
            dcb_start_rd <= 1'b0;
            dcb_start_wr <= 1'b0;
            if (vert_int) vrint <= 1'b1;

            // ---- register access -------------------------------------------
            // A write that arrives while a command is running has to WAIT.
            // See the note on the graphics FIFO above `engine_busy`.
            if (sel && we && engine_busy) begin
                wr_held <= 1'b1;
                wr_off   <= reg_off;
                wr_data  <= wdata;
                wr_lanes <= be;
                wr_go    <= is_go;
            end
            if (wr_apply) begin
                    wr_held <= 1'b0;
                    case (wr_reg)
                        R_DRAWMODE1:   drawmode1 <= wr_val;
                        R_DRAWMODE0:   drawmode0 <= wr_val;
                        R_LSMODE:      lsmode    <= wr_val & M_LSMODE;
                        R_LSPATTERN:   lspattern <= wr_val;
                        R_LSPATSAVE:   lspatsave <= wr_val;
                        // A WRITE RESTARTS THE PATTERN AT ITS MSB - "Pattern
                        // register, (msb = first pixel)". Glyphs, GL bitmaps,
                        // polygon stipple and software-z spans all load a
                        // fresh word per GO and mean it from its top; the
                        // index used to carry on from wherever the last
                        // primitive left it.
                        R_ZPATTERN:    begin zpattern <= wr_val;
                                             zbit     <= 5'd31; end
                        R_COLORBACK:   colorback <= wr_val;
                        R_COLORVRAM:   colorvram <= wr_val;
                        R_ALPHAREF:    alpharef  <= wr_val & M_ALPHAREF;
                        R_STALL0:      stall0    <= wr_val;
                        R_SMASK0X:     smask0x   <= wr_val;
                        R_SMASK0Y:     smask0y   <= wr_val;
                        // SETUP IS A COMMAND, NOT STORAGE: "Performs
                        // line/span setup without iteration (ignore
                        // DOSETUP)". The engine runs DOSETUP's derivation -
                        // octant, both Bresenham increments, the error term,
                        // and a fractional line's endpoint correction - and
                        // draws nothing. GL's glBitmap, IRIS GL's lrectwrite
                        // and both libraries' depth-buffered lines write it and
                        // then GO without DOSETUP (docs/design/rex3-source-audit.md 4.1, 4.2).
                        R_SETUP:       begin setup_r <= wr_val;
                                             setup_pending <= 1'b1; end
                        R_STEPZ:       stepz     <= wr_val;
                        R_LSRESTORE:   lsrestore <= wr_val;
                        R_LSSAVE:      lssave    <= wr_val;
                        // Writing any form of XSTART also writes XSAVE, which
                        // is what the block walker returns x to at the start
                        // of each row.
                        R_XSTART:      begin xstart <= wr_val & M_COORD;
                                             xsave  <= wr_val & M_COORD; end
                        R_YSTART:      ystart <= wr_val & M_COORD;
                        R_XEND:        xend   <= wr_val & M_COORD;
                        R_YEND:        yend   <= wr_val & M_COORD;
                        // THE GL-FORMAT COORDINATES KEEP BITS 22:7 AND NOTHING
                        // ELSE - "12.4(7) GL version of XSTART, (zeros 4
                        // msbs)" (Table 7). GL computes a coordinate as the
                        // float 4096 + x (IRIS GL biases by 5472 and the
                        // kernel's XYWIN takes the difference back out) and
                        // stores the float's raw bits: the mantissa is then x
                        // in 12.11 fixed point, and the exponent - 139 - puts
                        // 0xB in bits 26:23. These used to share the 16.4(7)
                        // registers' mask, kept those four bits, and turned
                        // every GL coordinate into x - 20480: GL's clear, its
                        // lines and its points were all culled off the left
                        // of the frame buffer (docs/design/rex3-source-audit.md 4.1). IRIS and MAME
                        // both mask with 0x007FFF80.
                        R_XSTARTF:     begin xstart <= wr_val & M_GLCOORD;
                                             xsave  <= wr_val & M_GLCOORD; end
                        R_YSTARTF:     ystart <= wr_val & M_GLCOORD;
                        // XENDF1 IS XENDF AGAIN, at the address after XSTARTI,
                        // so that one 64-bit store sets both ends of a span:
                        // every IRIS GL polygon span is `sdc1` XSTARTI+XENDF1
                        // with GO. It held an integer here until build 44.
                        R_XENDF,
                        R_XENDF1:      xend   <= wr_val & M_GLCOORD;
                        R_YENDF:       yend   <= wr_val & M_GLCOORD;
                        R_XSAVE:       xsave  <= {5'b0, wr_val[15:0], 11'b0};
                        R_XYMOVE:      xymove <= wr_val;
                        R_BRESD:       bresd  <= wr_val & M_BRESD;
                        R_BRESS1:      bress1 <= wr_val & M_BRESS1;
                        R_BRESOCTINC1: bresoctinc1 <= wr_val & M_BRESOCTINC1;
                        R_BRESRNDINC2: bresrndinc2 <= wr_val & M_BRESRNDINC2;
                        R_BRESE1:      brese1 <= wr_val & M_BRESE1;
                        R_BRESS2:      bress2 <= wr_val & M_BRESS2;
                        R_AWEIGHT0:    aweight0 <= wr_val;
                        R_AWEIGHT1:    aweight1 <= wr_val;
                        R_XSTARTI:     begin xstart <= {5'b0, wr_val[15:0], 11'b0};
                                             xsave  <= {5'b0, wr_val[15:0], 11'b0}; end
                        R_XYSTARTI:    begin xstart <= {5'b0, wr_val[31:16], 11'b0};
                                             xsave  <= {5'b0, wr_val[31:16], 11'b0};
                                             ystart <= {5'b0, wr_val[15:0],  11'b0}; end
                        R_XYENDI:      begin xend <= {5'b0, wr_val[31:16], 11'b0};
                                             yend <= {5'b0, wr_val[15:0],  11'b0}; end
                        R_XSTARTENDI:  begin xstart <= {5'b0, wr_val[31:16], 11'b0};
                                             xsave  <= {5'b0, wr_val[31:16], 11'b0};
                                             xend   <= {5'b0, wr_val[15:0],  11'b0}; end
                        // 12-BIT COLOUR INDEX ARRIVES AS o12.9 AND IS STORED
                        // AS o12.11, which is the one place the bus value and
                        // the register's value differ by anything but a mask.
                        R_COLORRED:    colorred   <= ci12_shift
                                                   ? ((wr_val << 2) & M_COLOR24)
                                                   :  (wr_val       & M_COLOR24);
                        R_COLORALPHA:  coloralpha <= wr_val & M_COLOR20;
                        R_COLORGRN:    colorgrn   <= wr_val & M_COLOR20;
                        R_COLORBLUE:   colorblue  <= wr_val & M_COLOR20;
                        R_SLOPERED:    slopered   <= to_sign_mag(wr_val, 24);
                        R_SLOPEALPHA:  slopealpha <= to_sign_mag(wr_val, 20);
                        R_SLOPEGRN:    slopegrn   <= to_sign_mag(wr_val, 20);
                        R_SLOPEBLUE:   slopeblue  <= to_sign_mag(wr_val, 20);
                        R_WRMASK:      wrmask <= wr_val & M_COLOR24;
                        // COLORI IS A WINDOW ONTO THE COLOUR DDAs, NOT A
                        // REGISTER. It has to be: CI shading iterates the red
                        // DDA and reads the index back out of it, so a
                        // separate store would hold the un-shaded colour and
                        // every Gouraud span would come out flat. In RGB mode
                        // the three bytes land in the three DDAs; in CI mode
                        // the whole value lands in red, shifted into the
                        // integer part at [22:11]. IRIS's set_colori.
                        R_COLORI:      if (dm1_rgbmode) begin
                                           colorred  <= {13'b0, wr_val[7:0],  11'b0};
                                           colorgrn  <= {13'b0, wr_val[15:8], 11'b0};
                                           colorblue <= {13'b0, wr_val[23:16],11'b0};
                                       end else begin
                                           colorred  <= wr_val << 11;
                                       end
                        R_COLORX:      colorx <= ci12_shift
                                               ? ((wr_val << 2) & M_COLOR24)
                                               :  (wr_val       & M_COLOR24);
                        // SLOPERED1 IS THE RED SLOPE AGAIN - the CI shading
                        // alias. The separate storage stays only so the
                        // read-back keeps the width the register test has
                        // always seen from it.
                        R_SLOPERED1:   begin slopered1 <= wr_val;
                                             slopered  <= to_sign_mag(wr_val, 24); end
                        R_HOSTRW0:     hostrw0 <= wr_val;
                        R_HOSTRW1:     hostrw1 <= wr_val;
                        R_DCBMODE:     dcbmode <= wr_val;
                        // Aligned on the way in, so the DCB sequencer and a
                        // read-back both see what the bus will actually send.
                        R_DCBDATA0:    begin dcbdata0 <= dcb_align(wr_val, wr_be);
                                             dcb_start_wr <= 1'b1; end
                        R_DCBDATA1:    dcbdata1 <= wr_val;
                        R_SMASK1X:     smask1x <= wr_val;
                        R_SMASK1Y:     smask1y <= wr_val;
                        R_SMASK2X:     smask2x <= wr_val;
                        R_SMASK2Y:     smask2y <= wr_val;
                        R_SMASK3X:     smask3x <= wr_val;
                        R_SMASK3Y:     smask3y <= wr_val;
                        R_SMASK4X:     smask4x <= wr_val;
                        R_SMASK4Y:     smask4y <= wr_val;
                        R_TOPSCAN:     topscan  <= wr_val & M_TOPSCAN;
                        R_XYWIN:       xywin    <= wr_val;
                        R_CLIPMODE:    clipmode <= wr_val & M_CLIPMODE;
                        R_STALL1:      stall1   <= wr_val;
                        R_CONFIG:      config_r <= wr_val;
                        // USER_STATUS is read-only; IRIS accepts and drops
                        // the write, and so does this.
                        R_USERSTATUS:  ;
                        // Writing DCBRESET aborts a transfer, which here means
                        // returning the sequencer to idle.
                        R_DCBRESET:    dcbst <= DCB_IDLE;
                        default: ;
                    endcase
                    if (wr_isgo) go_pending <= 1'b1;
                    ack <= 1'b1;
            end
            // A read waits until what it reads is settled - see "the read
            // path" above. It is latched when it cannot be answered at once.
            if (sel && !we && !rd_ready) begin
                rd_held <= 1'b1;
                rd_off  <= reg_off;
                rd_go   <= is_go;
            end
            if (rd_fire) begin
                rd_held <= 1'b0;
                // Reading STATUS acknowledges the vertical interrupt, as it
                // does on the part.
                if (rd_reg == R_STATUS) vrint <= 1'b0;
                if (rd_reg == R_DCBDATA0) begin
                    dcb_start_rd <= 1'b1;
                end else begin
                    rdata <= rdata_c;
                    ack   <= 1'b1;
                end
                if (rd_isgo && rd_reg != R_DCBDATA0) go_pending <= 1'b1;
            end

            // ---- VDMA host port ---------------------------------------------
            // A write beat is both host words and the GO in one edge; a read
            // beat fires the GO first and takes the words when the engine has
            // finished packing them into HOSTRW - which is the moment
            // `engine_busy` falls again. `!nd_ack` keeps the one-cycle window
            // between our ack and the master dropping its request from being
            // mistaken for a second beat.
            nd_ack <= 1'b0;
            case (ndst)
                ND_IDLE: if (nd_req && !nd_ack) begin
                    if (!nd_host) begin
                        nd_rdata <= 64'h0;
                        nd_ack   <= 1'b1;
                        nd_drops <= nd_drops + 4'h1;
                    end else if (nd_apply) begin
                        if (nd_we) begin
                            hostrw0 <= nd_wdata[63:32];
                            hostrw1 <= nd_wdata[31:0];
                            if (nd_go) go_pending <= 1'b1;
                            nd_ack  <= 1'b1;
                            nd_wr_beats <= nd_wr_beats + 16'h1;
                        end else begin
                            if (nd_go) go_pending <= 1'b1;
                            ndst <= ND_RD_WAIT;
                        end
                    end
                end
                ND_RD_WAIT: if (!engine_busy) begin
                    nd_rdata <= {hostrw0, hostrw1};
                    nd_ack   <= 1'b1;
                    ndst     <= ND_IDLE;
                    nd_rd_beats <= nd_rd_beats + 8'h1;
                end
                default: ndst <= ND_IDLE;
            endcase

            // ---- DCB sequencer ----------------------------------------------
            dcb_sel <= 1'b0;
            case (dcbst)
                DCB_IDLE: begin
`ifdef DCB_DEBUG
                    if (dcb_start_wr || dcb_start_rd)
                        $display("[DCB] %s addr=%0d crs=%0d width=%0d crsinc=%b data=%08h",
                                 dcb_start_wr ? "WR" : "RD", dcbm_addr, dcbm_crs,
                                 dcbm_width, dcbm_crsinc, dcbdata0);
`endif
                    if (dcb_start_wr || dcb_start_rd) begin
                        dcb_is_read <= dcb_start_rd;
                        dcb_we      <= dcb_start_wr;
                        // From the latched register: `wdata` belongs to a
                        // bus cycle that ended the clock before this one.
                        dcb_data    <= dcb_start_wr ? dcbdata0 : 32'h0;
                        dcb_byte    <= 3'd0;
                        dcb_crs_run <= dcbm_crs;
                        dcb_result  <= 32'h0;
                        dcb_sel     <= 1'b1;
                        dcbst       <= DCB_XFER;
                    end
                end
                // EVERY CHIP ON THIS BUS ANSWERS A READ ONE CYCLE AFTER
                // `sel`, so a read waits a cycle here before it samples. That
                // used to be true of VC2 alone; it is true of all four now,
                // because their register arrays had to become real memories
                // and a memory read is registered by definition. See
                // np_cmap.sv for what that cost and why.
                //
                // A WRITE DOES NOT WAIT. Only reads pay the cycle, so loading
                // a timing table or a palette runs at the speed it always did.
                DCB_XFER: if (dcb_is_read && !dcb_is_vc2 && !dcb_rd_waited) begin
                    dcb_rd_waited <= 1'b1;
                end else begin
                    dcb_rd_waited <= 1'b0;
                    // The byte-wide chips take one beat per byte, with CRS
                    // advancing when DCBMODE asks for it. A read accumulates
                    // exactly one byte per beat, so the last one lands in the
                    // low byte - which is where `dcbdata0.bybyte.b3` reads it
                    // from.
                    if (dcb_is_read && !dcb_is_vc2)
                        dcb_result <= {dcb_result[23:0], dcb_rdata[7:0]};
                    if (dcb_is_vc2) begin
                        // VC2's RAM port answers from a registered read, so it
                        // needs a cycle to settle before the value is taken.
                        dcbst <= dcb_is_read ? DCB_READ_W : DCB_DONE;
                    end else if (dcb_byte + 3'd1 >= dcb_nbytes) begin
                        dcbst <= DCB_DONE;
                    end else begin
                        dcb_byte    <= dcb_byte + 3'd1;
                        if (dcbm_crsinc) dcb_crs_run <= dcb_crs_run + 3'd1;
                        dcb_sel     <= 1'b1;
                    end
                end
                DCB_READ_W: begin
                    dcb_result <= dcb_rdata;
                    dcbst      <= DCB_DONE;
                end
                default: begin
                    if (dcbm_crsinc)
                        dcbmode[6:4] <= dcb_crs_run + (dcb_word32 ? 3'd4 : 3'd1);
                    if (dcb_is_read) begin
                        rdata <= dcb_result;
                        ack   <= 1'b1;
                    end
                    dcbst <= DCB_IDLE;
                end
            endcase

            // ---- draw engine -------------------------------------------------
            case (dr)
                // A SETUP write is served before a GO: when both are
                // waiting, the setup was written first (a write waits while
                // either is pending, so nothing can overtake it).
                DR_IDLE: if (setup_pending) begin
                    setup_pending <= 1'b0;
                    setup_only    <= 1'b1;
                    dr            <= DR_SETUP;
                end else if (go_pending) begin
                    go_pending <= 1'b0;
                    setup_only <= 1'b0;
                    dr <= DR_SETUP;
`ifdef REX3_DEBUG
                    // One line per accepted GO. A wrong picture is nearly
                    // always a command this engine was given rather than one
                    // it mishandled, and the driver is in the IRIX source, so
                    // the useful comparison is against what ng1_tp.c asked
                    // for. Build with +define+REX3_DEBUG; silent without it.
                    // Every field a software replay of this command needs, and
                    // no more: tests/rex3_replay.py is the consumer. The
                    // octant is the one BRESOCTINC1 holds *before* DOSETUP
                    // overwrites it, which is what a command without DOSETUP
                    // actually uses; the replay derives the other case from
                    // the two corners exactly as DR_SETUP does.
                    rex3_gos <= rex3_gos + 32'd1;
                    if (rex3_gos < 32'd`REX3_DEBUG_MAX)
                        $display("[REX3] %0d dm0=%08h dm1=%08h xy=(%0d,%0d)-(%0d,%0d) sav=%0d oct=%0d zp=%08h ci=%08h wm=%08h clip=%08h s0x=%08h s0y=%08h mv=%08h win=%08h ts=%0d",
                                 rex3_gos, drawmode0, drawmode1,
                                 fp_int(xstart), fp_int(ystart),
                                 fp_int(xend),   fp_int(yend), fp_int(xsave),
                                 bresoctinc1[26:24], zpattern, (colorred >> 11),
                                 wrmask, clipmode, smask0x, smask0y,
                                 xymove, xywin, topscan[10:0]);
`endif
                end

                DR_SETUP: begin
                    // DOSETUP derives the octant and the three Bresenham
                    // registers from the two endpoints; a command that does
                    // not set it walks on whatever they already hold, which is
                    // how Ng1TpDrawbitmap makes a glyph go upwards by writing
                    // 0x1000000 once and how a connected polyline carries one
                    // segment's error term into the next.
                    //
                    // A LINE CONTINUATION RE-DERIVES WHEN THE AXES DISAGREE.
                    // A degenerate setup GO followed by a horizontal
                    // continuation leaves a persisted octant that calls the
                    // wrong axis major, and the walk then steps the wrong way
                    // for the whole segment.
                    if (dm0_dosetup || do_resetup || setup_only) begin
                        bresoctinc1[26:24] <= {setup_xmajor, setup_xdec, setup_ydec};
                        bresoctinc1[19:0]  <= setup_incr1[19:0];
                        bresrndinc2[20:0]  <= setup_incr2[20:0];
                        bresd              <= {5'b0, setup_d[26:0]};
                    end
                    // The pattern cursors restart only on a new primitive -
                    // not on a setup-only pass, which IRIS's setup() leaves
                    // them alone for too.
                    if (dm0_dosetup && !setup_only) begin
                        zbit   <= 5'd31;
                        patbit <= 5'd31;
                    end
                    cx         <= fp_int(xstart);
                    cy         <= fp_int(ystart);
                    cx_save    <= fp_int(xsave);
                    cx_end     <= fp_int(xend);
                    cy_end     <= fp_int(yend);
                    // A LINE DROPS THE SUB-PIXEL PART. Its setup consumed the
                    // fractions and then wrote the integer position back, so
                    // everything downstream of it works in whole pixels.
                    xfrac      <= dm0_is_line ? 11'd0 : xstart[10:0];
                    yfrac      <= dm0_is_line ? 11'd0 : ystart[10:0];
                    xefrac     <= dm0_is_line ? 11'd0 : xend[10:0];
                    yefrac     <= dm0_is_line ? 11'd0 : yend[10:0];
                    first_pix  <= 1'b1;
                    // LENGTH32 clamps a span to 32 pixels, but only when the
                    // span is at least that wide.
                    span_left  <= 6'd32;
                    span_clamped <= dm0_length32 && (setup_adx >= 17'sd32);
                    host_left  <= host_count;
                    host_shift <= dm1_rwdouble ? {hostrw0, hostrw1} : {hostrw0, 32'h0};
                    line_left  <= line_count;
                    skip_first_r <= line_step_one ? 1'b0
                                  : (dm0_skipfirst || aline_skip_first);
                    skip_last_r  <= line_step_one ? 1'b0
                                  : (dm0_skiplast  || aline_skip_last);
                    // NOOP moves the position without touching a pixel, which
                    // is what a setup-only GO is for.
                    dr <= setup_only ? (dm0_is_fract ? DR_FRACT : DR_IDLE)
                        : (dm0_opcode == OP_NOOP) ? DR_IDLE
                        : span_lr_drop ? DR_IDLE
                        : (dm0_is_fract && (dm0_dosetup || do_resetup)) ? DR_FRACT
                        : first_pixel_state;
                end

                // The fractional-endpoint correction, one cycle, only for
                // F_LINE and A_LINE and only behind a DOSETUP.
                // THE SETUP SPENDS THE SUB-PIXEL PART AND WRITES THE INTEGER
                // POSITION BACK. That is IRIS's `ctx.xstart = x << 11`, and
                // it is load-bearing beyond tidiness: the endpoint filter
                // below reads XSTART's fraction, and by the time it runs the
                // fraction is gone, so a DOSETUP line never filters its first
                // endpoint however the weights are set.
                DR_FRACT: begin
                    frq_dx  <= fr_dx;
                    frq_dy  <= fr_dy;
                    frq_tx  <= fr_tx;
                    frq_ty  <= fr_ty;
                    frq_maj <= oct_ymajor ? fr_dy : fr_dx;
                    dr      <= DR_FRACT2;
                end

                DR_FRACT2: begin
                    bresd <= fr_takes_step ? {5'b0, fr2_e[26:0]} : {5'b0, fr2_d[26:0]};
                    if (fr_takes_step && oct_ymajor) begin
                        cx     <= fr_x2;
                        xstart <= {5'b0, fr_x2[15:0], 11'b0};
                    end else begin
                        xstart <= {5'b0, cx[15:0], 11'b0};
                    end
                    if (fr_takes_step && !oct_ymajor) begin
                        cy     <= fr_y2;
                        ystart <= {5'b0, fr_y2[15:0], 11'b0};
                    end else begin
                        ystart <= {5'b0, cy[15:0], 11'b0};
                    end
                    dr <= DR_FRACT3;
                end

                DR_FRACT3: begin
                    line_left <= pc_count;
                    dr        <= setup_only ? DR_IDLE : first_pixel_state;
                end

                // One pixel per clock. The position advances every cycle
                // whether or not the previous write has retired, because a
                // write returns nothing and the frame buffer port takes one
                // per clock.
                // ONE PIXEL PER ACKNOWLEDGEMENT, NOT ONE PER CLOCK. This
                // state used to advance every cycle and fire a write on each
                // of them, tracking what it had asserted in `wr_outstanding`.
                // Against a memory that accepts a write per clock that is
                // right, and sim_top's frame buffer is exactly such a memory.
                // Against rtl/mister/ddr3_mux.sv it is a disaster: the mux
                // holds ONE transaction at a time and takes tens of cycles
                // over it, so every request asserted while one is in flight is
                // latched by nobody. The pixels are never written, the count
                // never comes back down, and DR_DRAIN waits for ever.
                //
                // On a DE10-Nano that was a rasteriser that drew almost
                // nothing and then wedged. verilator/tb_rex3.cpp measures it:
                // at a forty-cycle acknowledgement, 249 of a 256-pixel
                // rectangle never reached memory and the engine never returned
                // to idle. At a zero-cycle one - the memory every other test
                // in this tree uses - none are lost, which is why nothing
                // caught it.
                //
                // Waiting costs nothing that was ever real: the port serves
                // one transaction at a time whatever this state does, so the
                // writes it used to throw away were never going to happen.
                DR_FILL: if (!fb_req || fb_ack) begin
                    walk_advance();
                    if (span_left != 6'd0) span_left <= span_left - 6'd1;
                    if (row_done) begin
                        zbit   <= 5'd31;
                        patbit <= 5'd31;
                        span_left <= 6'd32;
                        // A SPAN THAT REACHES ITS END IS OVER. Only a block
                        // wraps x back to XSAVE and drops to the next row.
                        if (dm0_adrmode != AM_SPAN) begin
                            cx     <= cx_save;
                            cy     <= y_step;
                            ystart <= {5'b0, y_step[15:0], yfrac};
                            xstart <= xsave;
                            // SKIPFIRST is per row in a block; see the
                            // note on the general walker's row end.
                            first_pix <= 1'b1;
                        end
                    end else begin
                        cx     <= x_step;
                        xstart <= {5'b0, x_step[15:0], xfrac};
                    end
                    // Where the walk goes next; through DR_CID first if the
                    // pixel just written needs its window-ID copy refreshed.
                    if (fb_req && cid_copy_need) begin
                        cid_x    <= dst_x;
                        cid_y    <= dst_y;
                        cid_val  <= plane_val[3:0];
                        dr_after <= fill_next;
                        dr       <= DR_CID;
                    end else begin
                        dr <= fill_next;
                    end
                end

                // Nothing left to drain: DR_FILL does not leave a pixel until
                // its write has been acknowledged, so by the time the walk
                // ends there is never a write in flight. The state is kept
                // because every path into "the primitive is over" goes through
                // it and because a future engine with more than one write
                // outstanding will want it back.
                DR_DRAIN: dr <= DR_IDLE;

                DR_SRC_RD: if (fb_ack) begin
                    src_pix <= src_x[0] ? fb_rdata[55:32] : fb_rdata[23:0];
                    dr      <= need_dst_read ? DR_DST_RD : DR_WR;
                end

                DR_DST_RD: if (fb_ack) begin
                    dst_half <= dst_x[0] ? fb_rdata[63:32] : fb_rdata[31:0];
                    dr       <= DR_WR;
                end

                DR_WR: if (fb_ack || !fb_req) begin
                    // READ packs the pixel into the host word, low end first
                    // so the first pixel ends up at the top; a host-sourced
                    // DRAW consumes one slot from the top instead. A pixel the
                    // patterns dropped consumes nothing: IRIS fetches the host
                    // word only after the pattern test, so a stippled
                    // host-sourced draw spends one word per drawn pixel and
                    // not one per position.
                    if (dm0_opcode == OP_READ) begin
                        host_shift <= (host_shift << rd_fstep)
                                    | {32'h0, host_pack_val};
                        host_left  <= host_left - 4'd1;
                    end else if (host_consume) begin
                        host_shift <= host_shift << host_step;
                        host_left  <= host_left - 4'd1;
                    end
                    if (fb_req && cid_copy_need) begin
                        cid_x    <= dst_x;
                        cid_y    <= dst_y;
                        cid_val  <= plane_val[3:0];
                        dr_after <= DR_STEP;
                        dr       <= DR_CID;
                    end else begin
                        dr <= DR_STEP;
                    end
                end

                DR_CID: if (fb_ack) dr <= dr_after;

                DR_STEP: begin
                    walk_advance();
                    if (span_left != 6'd0) span_left <= span_left - 6'd1;

                    // A LINE COUNTS ITS PIXELS. It cannot ask the coordinates
                    // whether it has arrived: Bresenham's minor axis lands on
                    // whichever side of the true line the error term puts it,
                    // and for a fractional line that is not the requested
                    // endpoint at all. The step is skipped on the last pixel
                    // so that XSTART and YSTART are left on it rather than one
                    // past it - a following XYENDI GO re-derives the setup
                    // from XSTART, and one pixel of drift there walks the next
                    // segment of a polyline off the joint.
                    if (dm0_is_line) begin
                        line_left <= line_left - 17'd1;
                        if (!line_last || line_step_one) begin
                            cx     <= line_x_step;
                            cy     <= line_y_step;
                            xstart <= {5'b0, line_x_step[15:0], 11'b0};
                            ystart <= {5'b0, line_y_step[15:0], 11'b0};
                            bresd  <= {5'b0, line_d_step[26:0]};
                        end else begin
                            // The walk is over and did not step. XSTART and
                            // YSTART still have to be published - in whole
                            // pixels, the sub-pixel part spent - because a
                            // following GO derives its setup from them.
                            xstart <= {5'b0, cx[15:0], 11'b0};
                            ystart <= {5'b0, cy[15:0], 11'b0};
                        end
                        dr <= line_last ? DR_IDLE : next_pixel_state;
                    end

                    // ROW END IS CHECKED BEFORE WORD END, because IRIS's walk
                    // does the y-advance and the x-wrap before it looks at the
                    // host count - and in host mode a row boundary is a FORCED
                    // word boundary, full word or not: the primitive pauses
                    // with the position already wrapped to the next row's
                    // start, a partial word's leftover is discarded, and the
                    // next GO's word starts the next row. The old order ended
                    // the primitive with x stepped PAST the row instead, which
                    // put every DMA'd image row after the first off the right
                    // edge of its rectangle. The PROM never saw it - its
                    // host-mode transfers are one-word primitives - but X's
                    // pixel DMA hits it on every row of every blit.
                    else if (row_done) begin
                        // End of the row. The pattern cursors restart at bit
                        // 31, which is why each scanline of a glyph starts
                        // from the top of its word.
                        zbit   <= 5'd31;
                        patbit <= 5'd31;
                        span_left <= 6'd32;
                        // A SPAN IS ONE ROW AND ENDS HERE; a block wraps x
                        // back to XSAVE and drops to the next.
                        if (dm0_adrmode != AM_SPAN) begin
                            cx     <= cx_save;
                            cy     <= y_step;
                            ystart <= {5'b0, y_step[15:0], yfrac};
                            xstart <= xsave;
                            // SKIPFIRST IS PER ROW IN A BLOCK, which is what
                            // makes it useful: a polygon hands the chip both
                            // halves of every span and the flag drops the
                            // shared edge pixel of each one. IRIS's block
                            // walker sets this flag at every row and never
                            // clears it, so under SKIPFIRST it draws nothing
                            // at all - its span and line walkers both clear
                            // it, and nothing in the corpus sets SKIPFIRST,
                            // so that arm has never run against real
                            // software. verilator/tb_rex3draw.cpp leaves the
                            // combination out and says so.
                            first_pix <= 1'b1;
                        end
                        if (host_mode && dm0_opcode == OP_READ) begin
                            hostrw0 <= dm1_rwdouble ? rd_word[63:32] : rd_word[31:0];
                            hostrw1 <= dm1_rwdouble ? rd_word[31:0]  : hostrw1;
                        end
                        // Without STOPONY each row is its own primitive and
                        // the next GO starts the next one - exactly how
                        // Ng1TpDrawbitmap paints a glyph, one write to
                        // ZPATTERN per scanline. Host mode ends the GO's work
                        // here too, whatever the count says.
                        if ((dm0_adrmode == AM_SPAN) || !dm0_stopony || y_at_end
                            || host_mode)
                            dr <= DR_IDLE;
                        else
                            dr <= next_pixel_state;
                    end else if (len32_stop) begin
                        // LENGTH32's thirty-second pixel. The primitive pauses
                        // where it stands, x already stepped, for the next GO.
                        cx     <= x_step;
                        xstart <= {5'b0, x_step[15:0], xfrac};
                        dr     <= DR_IDLE;
                    end else if (host_mode && host_left == 4'd0) begin
                        // A whole host word mid-row: flush it and pause the
                        // primitive where it stands. The next GO carries the
                        // next word.
                        if (dm0_opcode == OP_READ) begin
                            hostrw0 <= dm1_rwdouble ? rd_word[63:32] : rd_word[31:0];
                            hostrw1 <= dm1_rwdouble ? rd_word[31:0]  : hostrw1;
                        end
                        cx     <= x_step;
                        xstart <= {5'b0, x_step[15:0], xfrac};
                        dr     <= DR_IDLE;
                    end else begin
                        cx     <= x_step;
                        xstart <= {5'b0, x_step[15:0], xfrac};
                        // Without STOPONX one pixel is the whole primitive.
                        dr     <= eff_stoponx ? next_pixel_state : DR_IDLE;
                    end
                end

                default: dr <= DR_IDLE;
            endcase

        end
    end

    // ---- frame buffer port -------------------------------------------------
    // FASTCLEAR writes through the patterns; the CID clip skips any pixel
    // whose window-ID nibble in the auxiliary planes does not match.
    // THE CID IS TWO BITS AND CIDMATCH IS A MASK OF THE FOUR THEY NAME.
    wire cid_ok = cid_match[cid_nib[1:0]];
    // The alpha function only runs where there is an alpha to test: a
    // fastclear writes through it, as it writes through everything.
    wire afunc_drop = !fastclear_act && pixel_is_draw
                   && (dm1_compare != 3'd7) && !afunc_pass;
    wire skip_pix = (first_pix && skip_first_r)
                 || (prim_last && skip_last_r)
                 || lr_skip
                 || (!clip_ok)
                 || pat_drop
                 || afunc_drop
                 || (cid_gate && !cid_ok);

    // DR_FILL's next state, kept apart so that a detour through DR_CID can
    // come back to it. Without STOPONX one pixel is the whole primitive.
    always_comb begin
        if (row_done)
            fill_next = ((dm0_adrmode == AM_SPAN) || !dm0_stopony || y_at_end)
                      ? DR_DRAIN : DR_FILL;
        else if (len32_stop) fill_next = DR_DRAIN;
        else                 fill_next = eff_stoponx ? DR_FILL : DR_DRAIN;
    end

    // The window-ID copy: byte 3 of the drawing slot of the pixel DR_CID was
    // entered for, and nothing else.
    wire [31:0] cid_slot = {4'b0, cid_val, 24'h0};

    always_comb begin
        fb_req   = 1'b0;
        fb_we    = 1'b0;
        fb_addr  = 32'h0;
        fb_wdata = 64'h0;
        fb_be    = 8'hFF;
        case (dr)
            DR_SRC_RD: begin
                fb_req  = 1'b1;
                fb_addr = fb_slot_addr(src_x, src_y, is_aux_plane);
            end
            DR_DST_RD: begin
                fb_req  = 1'b1;
                fb_addr = fb_slot_addr(dst_x, dst_y, is_aux_plane);
            end
            DR_FILL: begin
                fb_req   = !skip_pix;
                fb_we    = 1'b1;
                fb_addr  = fb_slot_addr(dst_x, dst_y, is_aux_plane);
                fb_wdata = fb_word_new;
                fb_be    = fb_be_masked;
            end
            DR_WR: begin
                fb_req   = (dm0_opcode != OP_READ) && !skip_pix;
                fb_we    = 1'b1;
                fb_addr  = fb_slot_addr(dst_x, dst_y, is_aux_plane);
                fb_wdata = fb_word_new;
                fb_be    = fb_be_masked;
            end
            DR_CID: begin
                fb_req   = 1'b1;
                fb_we    = 1'b1;
                fb_addr  = fb_slot_addr(cid_x, cid_y, 1'b0);
                fb_wdata = {cid_slot, cid_slot};
                fb_be    = cid_x[0] ? 8'h80 : 8'h08;
            end
            default: ;
        endcase
    end

    // To the display side's per-line flag table: this line now holds
    // something the compositor can see in the auxiliary planes.
    always_ff @(posedge clk) begin
        if (reset) begin
            aux_mark      <= 1'b0;
            aux_mark_line <= 11'd0;
        end else begin
            aux_mark      <= fb_req && fb_ack && fb_we && aux_visible
                          && (dr == DR_FILL || dr == DR_WR);
            aux_mark_line <= dst_y;
        end
    end

endmodule
