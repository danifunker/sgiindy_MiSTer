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
//  WHAT IS NOT BUILT: line address modes (I_LINE, F_LINE, A_LINE), the line
//  stipple pattern, alpha blending, dithering, colour compare, and the
//  colour DDAs' interpolation. Nothing on the PROM's console path uses any
//  of them - see the table in docs/16-newport-plan.md - and each is a
//  self-contained addition. A command that asks for one draws with the
//  interpolators held, which is wrong but visible, rather than hanging.
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

    // ---- from VC2 ---------------------------------------------------------
    input  logic        vert_int,
    output logic        gfx_busy
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
    localparam logic [12:0] R_XENDI       = 13'h014C;
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

    // The slope registers are sign-magnitude, not two's complement, and the
    // diagnostic checks the conversion: a negative value comes back as the
    // sign bit set and the magnitude below it. Doing it at write time means
    // the stored value is what the chip actually holds.
    function automatic logic [31:0] to_sign_mag(input logic [31:0] v,
                                                input int nbits);
        logic [31:0] mag;
        begin
            mag = v[31] ? (~v + 32'd1) : v;
            to_sign_mag = (v[31] ? (32'd1 << (nbits - 1)) : 32'd0)
                        | (mag & ((32'd1 << (nbits - 1)) - 32'd1));
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
    logic [31:0] wrmask, colori, colorx;
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
    wire        dm0_stoponx = drawmode0[8];
    wire        dm0_stopony = drawmode0[9];
    wire        dm0_skipfirst = drawmode0[10];
    wire        dm0_skiplast  = drawmode0[11];
    wire        dm0_enzpattern = drawmode0[12];
    wire        dm0_length32 = drawmode0[15];
    wire        dm0_zpopaque = drawmode0[16];
    wire        dm0_xyoffset = drawmode0[20];
    wire        dm0_ystride  = drawmode0[23];

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
    // blendalpha [27], logicop [31:28]. Everything not decoded below is
    // accepted and read back and does nothing: YFLIP, the blend pipeline,
    // dither and fast clear are all unused by the PROM's console.
    wire  [2:0] dm1_planes    = drawmode1[2:0];
    wire  [1:0] dm1_drawdepth = drawmode1[4:3];
    wire        dm1_dblsrc    = drawmode1[5];
    wire        dm1_rwpacked  = drawmode1[7];
    wire  [1:0] dm1_hostdepth = drawmode1[9:8];
    wire        dm1_rwdouble  = drawmode1[10];
    // COMPARE is the colour/alpha function: three relation bits, all set
    // meaning "always pass". Nothing here implements the comparison, and the
    // PROM disables it in every command, so it is decoded to be visible in a
    // trace rather than acted on.
    wire  [2:0] dm1_compare   = drawmode1[14:12];
    wire        dm1_rgbmode   = drawmode1[15];
    wire  [3:0] dm1_logicop   = drawmode1[31:28];

    localparam logic [1:0] OP_NOOP    = 2'd0;
    localparam logic [1:0] OP_READ    = 2'd1;
    localparam logic [1:0] OP_DRAW    = 2'd2;
    localparam logic [1:0] OP_SCR2SCR = 2'd3;

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
    typedef enum logic [2:0] {
        DR_IDLE, DR_SETUP, DR_SRC_RD, DR_DST_RD, DR_WR, DR_STEP, DR_FILL, DR_DRAIN
    } dr_state_t;

    dr_state_t   dr;
    logic signed [16:0] cx, cy;          // running integer position
    logic signed [16:0] cx_end, cy_end;
    logic signed [16:0] cx_save;
    logic  [4:0] zbit;                   // z-pattern bit index, 31 down
    logic  [5:0] span_left;              // LENGTH32 clamp
    logic        span_clamped;
    logic        first_pix;
    logic [23:0] src_pix;                // pixel read for SCR2SCR
    logic [63:0] dst_word;
    logic  [2:0] host_left;              // pixels remaining in a host word
    logic [63:0] host_shift;
    // Writes issued into the frame buffer that have not been acknowledged.
    // The fill path below does not wait for each one, so this is what says the
    // engine is finished.
    logic  [3:0] wr_outstanding;

    assign gfx_busy = (dr != DR_IDLE) || (dcbst != DCB_IDLE) || (wr_outstanding != 0);

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

    // The walk has reached the far edge in x or in y. Both comparisons follow
    // the octant, because a copy that overlaps its source has to run towards
    // the overlap rather than away from it - which is the whole reason
    // Ng1TpBmove picks its start and end corners the way it does.
    wire x_at_end = oct_xdec ? (cx <= cx_end) : (cx >= cx_end);
    wire y_at_end = oct_ydec ? (cy <= cy_end) : (cy >= cy_end);

    // One pixel per host word unless RWPACKED; the primitive then ends after
    // that many pixels and the next GO carries the next word.
    wire host_mode = (dm0_opcode == OP_READ) || dm0_colorhost;

    // Where the walk goes for the next pixel of a primitive.
    dr_state_t next_pixel_state;
    assign next_pixel_state = (dm0_opcode == OP_SCR2SCR) ? DR_SRC_RD
                            : need_dst_read              ? DR_DST_RD
                            :                              DR_WR;

    // Where the walk goes next, and whether this pixel ended the span.
    wire signed [16:0] x_step = oct_xdec ? cx - 17'sd1 : cx + 17'sd1;
    wire signed [16:0] y_incr = dm0_ystride ? 17'sd2 : 17'sd1;
    wire signed [16:0] y_step = oct_ydec ? cy - y_incr : cy + y_incr;
    // Host mode forces STOPONX: a READ or a host-sourced DRAW moves one word
    // per GO, and the walk has to keep going until that word is full or empty
    // whatever the flag says. getfbdepth writes two 12-bit pixels with a
    // single write to HOSTRW0 and no STOPONX at all, and without this it
    // would place one of them, read back 0x0abc0000, and conclude the frame
    // buffer is 8 planes deep.
    wire eff_stoponx = dm0_stoponx || host_mode;
    wire row_done = eff_stoponx
                  && (x_at_end || (span_clamped && span_left <= 6'd1));

    // DOSETUP's inputs, in integer pixels.
    wire signed [16:0] setup_dx = fp_int(xend) - fp_int(xstart);
    wire signed [16:0] setup_dy = fp_int(yend) - fp_int(ystart);
    wire signed [16:0] setup_adx = setup_dx[16] ? -setup_dx : setup_dx;
    wire signed [16:0] setup_ady = setup_dy[16] ? -setup_dy : setup_dy;
    wire setup_xdec   = setup_dx[16];
    wire setup_ydec   = setup_dy[16];
    wire setup_xmajor = setup_adx > setup_ady;

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

    // Eight bytes per pixel: the drawing planes and the auxiliary planes are
    // 24 bits each and share one 64-bit word, which is the width of every
    // other port in this core. The top byte of each half is unused - a real
    // Newport pixel is 48 bits and this rounds it up rather than packing two
    // pixels across a word boundary.
    function automatic logic [31:0] fb_byte_addr(input logic signed [16:0] x,
                                                 input logic [10:0] y);
        fb_byte_addr = FB_BASE
                     + (((({21'b0, y}) << FB_STRIDE_LOG2) + {21'b0, x[10:0]}) << 3);
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
        if (ensmask[0] && !in_box(cx, cy, smask0x, smask0y)) clip_ok = 1'b0;
        if (|ensmask[4:1]) begin
            any = 1'b0;
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
    // A frame buffer word is {8'b0, aux[23:0], 8'b0, rgb[23:0]}. The aux half
    // carries the overlay at [23:8], the popup at [7:6]/[3:2] and the window
    // ID at [5:4]/[1:0], two buffers of each, which is the layout the PROM's
    // plane write masks describe: OLAY 0xFFFF00, PUP 0x0000CC, CID 0x000033.
    wire is_aux_plane = (dm1_planes == 3'd4) || (dm1_planes == 3'd5)
                     || (dm1_planes == 3'd6);
    wire [23:0] dst_rgb = dst_word[23:0];
    wire [23:0] dst_aux = dst_word[55:32];
    wire [23:0] dst_plane = is_aux_plane ? dst_aux : dst_rgb;

    // The destination value the logic op sees, in the plane's own units.
    logic [23:0] dst_val;
    always_comb begin
        case (dm1_planes)
            3'd4:    dst_val = dm1_dblsrc ? {16'b0, dst_aux[23:16]} : {16'b0, dst_aux[15:8]};
            3'd5:    dst_val = dm1_dblsrc ? {22'b0, dst_aux[7:6]}   : {22'b0, dst_aux[3:2]};
            3'd6:    dst_val = dm1_dblsrc ? {22'b0, dst_aux[5:4]}   : {22'b0, dst_aux[1:0]};
            default: case (dm1_drawdepth)
                        2'd0:    dst_val = {20'b0, dst_rgb[3:0]};
                        2'd1:    dst_val = dm1_dblsrc ? {16'b0, dst_rgb[15:8]}
                                                      : {16'b0, dst_rgb[7:0]};
                        2'd2:    dst_val = {12'b0, dst_rgb[11:0]};
                        default: dst_val = dst_rgb;
                     endcase
        endcase
    end

    // Source colour. CI mode takes COLORI; RGB mode takes the integer parts of
    // the three colour DDAs, which are o12.11 with the integer at [23:11].
    logic [23:0] draw_src;
    always_comb begin
        if (dm0_opcode == OP_SCR2SCR)      draw_src = src_pix;
        else if (dm0_colorhost)            draw_src = host_pix;
        else if (dm1_rgbmode)              draw_src = {colorblue[18:11], colorgrn[18:11],
                                                      colorred[18:11]};
        else                               draw_src = colori[23:0];
    end

    // The pixel at the top of the host shifter, in its slot. 4bpp and 8bpp
    // share an 8-bit slot; 12bpp sits in the low 12 bits of a 16-bit slot,
    // which is what makes getfbdepth's 0x0abc0def two pixels and not three
    // bytes of tightly packed data.
    logic [23:0] host_pix;
    always_comb begin
        case (dm1_hostdepth)
            2'd0:    host_pix = {20'b0, host_shift[59:56]};
            2'd1:    host_pix = {16'b0, host_shift[63:56]};
            2'd2:    host_pix = {12'b0, host_shift[59:48]};
            default: host_pix = host_shift[55:32];
        endcase
    end

    logic [23:0] logic_out;
    always_comb begin
        case (dm1_logicop)
            4'h0:    logic_out = 24'h000000;
            4'h1:    logic_out =  draw_src &  dst_val;
            4'h2:    logic_out =  draw_src & ~dst_val;
            4'h3:    logic_out =  draw_src;
            4'h4:    logic_out = ~draw_src &  dst_val;
            4'h5:    logic_out =  dst_val;
            4'h6:    logic_out =  draw_src ^  dst_val;
            4'h7:    logic_out =  draw_src |  dst_val;
            4'h8:    logic_out = ~(draw_src | dst_val);
            4'h9:    logic_out = ~(draw_src ^ dst_val);
            4'hA:    logic_out = ~dst_val;
            4'hB:    logic_out =  draw_src | ~dst_val;
            4'hC:    logic_out = ~draw_src;
            4'hD:    logic_out = ~draw_src |  dst_val;
            4'hE:    logic_out = ~(draw_src & dst_val);
            default: logic_out = 24'hFFFFFF;
        endcase
    end

    // "Amplify" replicates the value into both buffers of its plane so one
    // write mask can reach either or both. The mask constants in ng1_init.c
    // are the check: OLAY 0xFFFF00 covers both overlay buffers, PUP 0x0000CC
    // both popup buffers, CID 0x000033 both window-ID buffers.
    logic [23:0] amplified;
    always_comb begin
        case (dm1_planes)
            3'd4:    amplified = {logic_out[7:0], logic_out[7:0], 8'h00};
            3'd5:    amplified = {18'b0, logic_out[1:0], 2'b0, logic_out[1:0], 2'b0}
                               & 24'h0000CC;
            3'd6:    amplified = {18'b0, logic_out[1:0], 2'b0, logic_out[1:0]}
                               & 24'h000033;
            default: case (dm1_drawdepth)
                        2'd0:    amplified = {logic_out[3:0], logic_out[3:0],
                                              logic_out[3:0], logic_out[3:0],
                                              logic_out[3:0], logic_out[3:0]};
                        2'd1:    amplified = {logic_out[7:0], logic_out[7:0],
                                              logic_out[7:0]};
                        2'd2:    amplified = {logic_out[11:0], logic_out[11:0]};
                        default: amplified = logic_out;
                     endcase
        endcase
    end

    wire [23:0] plane_new = (dst_plane & ~wrmask[23:0]) | (amplified & wrmask[23:0]);

    // A read before every write is only needed when the write cannot say what
    // it leaves alone. Two things can make it unnecessary: a write mask whose
    // every byte is all-ones or all-zero, which the frame buffer's byte
    // enables can express on their own, and a logic op that ignores the
    // destination. rex3Clear's 24-bit and overlay passes are both of those;
    // its CID and popup passes are not, because 0x33 and 0xCC split a byte.
    wire mask_byte_clean = (wrmask[7:0]   == 8'h00 || wrmask[7:0]   == 8'hFF)
                        && (wrmask[15:8]  == 8'h00 || wrmask[15:8]  == 8'hFF)
                        && (wrmask[23:16] == 8'h00 || wrmask[23:16] == 8'hFF);
    wire logic_needs_dst = !(dm1_logicop == 4'h0 || dm1_logicop == 4'h3
                          || dm1_logicop == 4'hC || dm1_logicop == 4'hF);
    wire need_dst_read = (dm0_opcode == OP_READ) || logic_needs_dst
                      || !mask_byte_clean;

    wire [23:0] plane_val = need_dst_read ? plane_new : amplified;
    wire [63:0] fb_word_new = is_aux_plane
                            ? {dst_word[63:56], plane_val, dst_word[31:0]}
                            : {dst_word[63:24], plane_val};

    // Byte enables for the skip-the-read path. The 64-bit pixel word is
    // {8'b0, aux[23:0], 8'b0, rgb[23:0]}, so the auxiliary planes are bytes
    // 1..3 and the drawing planes bytes 5..7, and `be[7-i]` guards byte i.
    wire [2:0] plane_be = {|wrmask[23:16], |wrmask[15:8], |wrmask[7:0]};
    wire [7:0] fb_be_masked = need_dst_read
                            ? 8'hFF
                            : (is_aux_plane ? {1'b0, plane_be, 4'b0}
                                            : {5'b0, plane_be});

    // ---- host pixel packing ------------------------------------------------
    // HOSTDEPTH picks the slot width: 12bpp and 32bpp use 16- and 32-bit
    // slots, 4bpp and 8bpp both use an 8-bit slot. Without RWPACKED a word
    // carries one pixel. Which is why getfbdepth's 0x0abc0def is two 12-bit
    // pixels in two 16-bit halves rather than 24 bits of tightly packed data.
    logic [2:0] host_count;
    logic [5:0] host_step;
    always_comb begin
        if (!dm1_rwpacked) begin
            host_count = 3'd1;
            host_step  = 6'd0;
        end else begin
            case (dm1_hostdepth)
                2'd0, 2'd1: begin host_step = 6'd8;
                                  host_count = dm1_rwdouble ? 3'd8 : 3'd4; end
                2'd2:       begin host_step = 6'd16;
                                  host_count = dm1_rwdouble ? 3'd4 : 3'd2; end
                default:    begin host_step = 6'd32;
                                  host_count = dm1_rwdouble ? 3'd2 : 3'd1; end
            endcase
        end
    end

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
        case (reg_off)
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
            R_XENDI:       rdata_c = {16'h0, xend[26:11]};
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
            R_COLORI:      rdata_c = colori;
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
    wire acc_dcbdata0 = sel && (reg_off == R_DCBDATA0);
    wire need_dcb_rd  = acc_dcbdata0 && !we;

    logic go_pending;

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

    wire engine_busy = (dr != DR_IDLE) || go_pending
                    || (dcbst != DCB_IDLE) || dcb_start_wr || dcb_start_rd;
    wire        wr_apply = (wr_held || (sel && we)) && !engine_busy;
    wire [12:0] wr_reg   = wr_held ? wr_off  : reg_off;
    wire [31:0] wr_val   = wr_held ? wr_data : wdata;
    wire        wr_isgo  = wr_held ? wr_go   : is_go;
    wire  [3:0] wr_be    = wr_held ? wr_lanes : be;

`ifdef REX3_DEBUG
    logic [31:0] rex3_gos;
`ifndef REX3_DEBUG_MAX
`define REX3_DEBUG_MAX 1000000
`endif
`endif

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
            slopered1 <= 32'h0; wrmask <= 32'h0; colori <= 32'h0; colorx <= 32'h0;
            hostrw0 <= 32'h0; hostrw1 <= 32'h0;
            dcbmode <= {21'h0, 4'hF, 7'h0};   // DCBADDR powers up at 0xF
            dcbdata0 <= 32'h0; dcbdata1 <= 32'h0;
            smask1x <= 32'h0; smask1y <= 32'h0; smask2x <= 32'h0; smask2y <= 32'h0;
            smask3x <= 32'h0; smask3y <= 32'h0; smask4x <= 32'h0; smask4y <= 32'h0;
            topscan <= 32'h0; xywin <= 32'h0; clipmode <= 32'h0; stall1 <= 32'h0;
            dr <= DR_IDLE; cx <= 17'sd0; cy <= 17'sd0; cx_end <= 17'sd0;
            cy_end <= 17'sd0; cx_save <= 17'sd0; zbit <= 5'd31;
            span_left <= 6'd32; span_clamped <= 1'b0; first_pix <= 1'b0;
            src_pix <= 24'h0; dst_word <= 64'h0; host_left <= 3'd0;
            host_shift <= 64'h0; wr_outstanding <= 4'd0;
            config_r <= 32'h0;
            vrint <= 1'b0; videoint <= 1'b0;
            ack <= 1'b0; rdata <= 32'h0;
            go_pending <= 1'b0;
            wr_held <= 1'b0; wr_off <= 13'h0; wr_data <= 32'h0;
            wr_lanes <= 4'h0; wr_go <= 1'b0;
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
                        R_ZPATTERN:    zpattern  <= wr_val;
                        R_COLORBACK:   colorback <= wr_val;
                        R_COLORVRAM:   colorvram <= wr_val;
                        R_ALPHAREF:    alpharef  <= wr_val & M_ALPHAREF;
                        R_STALL0:      stall0    <= wr_val;
                        R_SMASK0X:     smask0x   <= wr_val;
                        R_SMASK0Y:     smask0y   <= wr_val;
                        R_SETUP:       setup_r   <= wr_val;
                        R_STEPZ:       stepz     <= wr_val;
                        R_LSRESTORE:   lsrestore <= wr_val;
                        R_LSSAVE:      lssave    <= wr_val;
                        // Writing any form of XSTART also writes XSAVE, which
                        // is what the block walker returns x to at the start
                        // of each row.
                        R_XSTART,
                        R_XSTARTF:     begin xstart <= wr_val & M_COORD;
                                             xsave  <= wr_val & M_COORD; end
                        R_YSTART,
                        R_YSTARTF:     ystart <= wr_val & M_COORD;
                        R_XEND,
                        R_XENDF:       xend   <= wr_val & M_COORD;
                        R_YEND,
                        R_YENDF:       yend   <= wr_val & M_COORD;
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
                        R_XENDI:       xend <= {5'b0, wr_val[15:0], 11'b0};
                        R_XYSTARTI:    begin xstart <= {5'b0, wr_val[31:16], 11'b0};
                                             xsave  <= {5'b0, wr_val[31:16], 11'b0};
                                             ystart <= {5'b0, wr_val[15:0],  11'b0}; end
                        R_XYENDI:      begin xend <= {5'b0, wr_val[31:16], 11'b0};
                                             yend <= {5'b0, wr_val[15:0],  11'b0}; end
                        R_XSTARTENDI:  begin xstart <= {5'b0, wr_val[31:16], 11'b0};
                                             xsave  <= {5'b0, wr_val[31:16], 11'b0};
                                             xend   <= {5'b0, wr_val[15:0],  11'b0}; end
                        R_COLORRED:    colorred   <= wr_val & M_COLOR24;
                        R_COLORALPHA:  coloralpha <= wr_val & M_COLOR20;
                        R_COLORGRN:    colorgrn   <= wr_val & M_COLOR20;
                        R_COLORBLUE:   colorblue  <= wr_val & M_COLOR20;
                        R_SLOPERED:    slopered   <= to_sign_mag(wr_val, 24);
                        R_SLOPEALPHA:  slopealpha <= to_sign_mag(wr_val, 20);
                        R_SLOPEGRN:    slopegrn   <= to_sign_mag(wr_val, 20);
                        R_SLOPEBLUE:   slopeblue  <= to_sign_mag(wr_val, 20);
                        R_WRMASK:      wrmask <= wr_val & M_COLOR24;
                        R_COLORI:      colori <= wr_val;
                        R_COLORX:      colorx <= wr_val;
                        R_SLOPERED1:   slopered1 <= wr_val;
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
            // A READ IS NEVER HELD. REX3WAIT and BFIFOWAIT poll the status
            // register while the engine is running, so stalling a read would
            // deadlock the machine against itself. A read that carries the GO
            // bit still queues its command - that is safe where a write is
            // not, because a read changes no register the command will use.
            if (sel && !we) begin
                    // Reading STATUS acknowledges the vertical interrupt, as
                    // it does on the part.
                    if (reg_off == R_STATUS) vrint <= 1'b0;
                    if (need_dcb_rd) begin
                        dcb_start_rd <= 1'b1;
                    end else begin
                        rdata <= rdata_c;
                        ack   <= 1'b1;
                    end
                    if (is_go && reg_off != R_DCBDATA0) go_pending <= 1'b1;
            end

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
                DR_IDLE: if (go_pending) begin
                    go_pending <= 1'b0;
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
                                 bresoctinc1[26:24], zpattern, colori,
                                 wrmask, clipmode, smask0x, smask0y,
                                 xymove, xywin, topscan[10:0]);
`endif
                end

                DR_SETUP: begin
                    // DOSETUP derives the octant from the two endpoints; a
                    // command that does not set it uses whatever BRESOCTINC1
                    // already holds, which is how Ng1TpDrawbitmap makes a
                    // glyph walk upwards by writing 0x1000000 once.
                    if (dm0_dosetup)
                        bresoctinc1[26:24] <= {setup_xmajor, setup_xdec, setup_ydec};
                    cx         <= fp_int(xstart);
                    cy         <= fp_int(ystart);
                    cx_save    <= fp_int(xsave);
                    cx_end     <= fp_int(xend);
                    cy_end     <= fp_int(yend);
                    zbit       <= 5'd31;
                    first_pix  <= 1'b1;
                    // LENGTH32 clamps a span to 32 pixels, but only when the
                    // span is at least that wide.
                    span_left  <= 6'd32;
                    span_clamped <= dm0_length32 && (setup_adx >= 17'sd32);
                    host_left  <= host_count;
                    host_shift <= dm1_rwdouble ? {hostrw0, hostrw1} : {hostrw0, 32'h0};
                    // NOOP moves the position without touching a pixel, which
                    // is what a setup-only GO is for.
                    dr <= (dm0_opcode == OP_NOOP) ? DR_IDLE
                        : (dm0_opcode == OP_SCR2SCR) ? DR_SRC_RD
                        : need_dst_read ? DR_DST_RD
                        : ((dm0_opcode == OP_DRAW) && !host_mode) ? DR_FILL
                        : DR_WR;
                end

                // One pixel per clock. The position advances every cycle
                // whether or not the previous write has retired, because a
                // write returns nothing and the frame buffer port takes one
                // per clock.
                DR_FILL: begin
                    first_pix <= 1'b0;
                    if (span_left != 6'd0) span_left <= span_left - 6'd1;
                    if (row_done) begin
                        cx        <= cx_save;
                        zbit      <= 5'd31;
                        cy        <= y_step;
                        span_left <= 6'd32;
                        ystart    <= {5'b0, y_step[15:0], 11'b0};
                        xstart    <= xsave;
                        if (!dm0_stopony || y_at_end) dr <= DR_DRAIN;
                    end else begin
                        zbit   <= (zbit == 5'd0) ? 5'd31 : zbit - 5'd1;
                        cx     <= x_step;
                        xstart <= {5'b0, x_step[15:0], 11'b0};
                        if (!eff_stoponx) dr <= DR_DRAIN;
                    end
                end

                DR_DRAIN: if (wr_outstanding == 4'd0 ||
                              (wr_outstanding == 4'd1 && fb_ack)) dr <= DR_IDLE;

                DR_SRC_RD: if (fb_ack) begin
                    src_pix <= fb_rdata[23:0];
                    dr      <= need_dst_read ? DR_DST_RD : DR_WR;
                end

                DR_DST_RD: if (fb_ack) begin
                    dst_word <= fb_rdata;
                    dr       <= DR_WR;
                end

                DR_WR: if (fb_ack || !fb_req) begin
                    // READ packs the pixel into the host word, low end first
                    // so the first pixel ends up at the top; a host-sourced
                    // DRAW consumes one slot from the top instead.
                    if (dm0_opcode == OP_READ)
                        host_shift <= (host_shift << host_step) | {40'h0, dst_val};
                    else if (dm0_colorhost)
                        host_shift <= host_shift << host_step;
                    if (host_mode) host_left <= host_left - 3'd1;
                    dr <= DR_STEP;
                end

                DR_STEP: begin
                    first_pix <= 1'b0;
                    if (span_left != 6'd0) span_left <= span_left - 6'd1;

                    // A whole host word has been moved: flush it and end the
                    // primitive, whatever the span says. The next GO carries
                    // the next word.
                    if (host_mode && host_left == 3'd0) begin
                        if (dm0_opcode == OP_READ) begin
                            hostrw0 <= dm1_rwdouble ? host_shift[63:32] : host_shift[31:0];
                            hostrw1 <= dm1_rwdouble ? host_shift[31:0]  : hostrw1;
                        end
                        cx     <= x_step;
                        xstart <= {5'b0, x_step[15:0], 11'b0};
                        dr     <= DR_IDLE;
                    end else if (row_done) begin
                        // End of the span. x returns to XSAVE and y advances;
                        // the z-pattern restarts at bit 31, which is why each
                        // scanline of a glyph starts from the top of its word.
                        cx   <= cx_save;
                        zbit <= 5'd31;
                        cy   <= y_step;
                        span_left <= 6'd32;
                        // Without STOPONY each row is its own primitive and
                        // the next GO starts the next one - exactly how
                        // Ng1TpDrawbitmap paints a glyph, one write to
                        // ZPATTERN per scanline.
                        if (!dm0_stopony || y_at_end) begin
                            ystart <= {5'b0, y_step[15:0], 11'b0};
                            xstart <= xsave;
                            dr     <= DR_IDLE;
                        end else begin
                            ystart <= {5'b0, y_step[15:0], 11'b0};
                            xstart <= xsave;
                            dr     <= next_pixel_state;
                        end
                    end else begin
                        zbit   <= (zbit == 5'd0) ? 5'd31 : zbit - 5'd1;
                        cx     <= x_step;
                        xstart <= {5'b0, x_step[15:0], 11'b0};
                        // Without STOPONX one pixel is the whole primitive.
                        dr     <= eff_stoponx ? next_pixel_state : DR_IDLE;
                    end
                end

                default: dr <= DR_IDLE;
            endcase

            // One counter for both write paths. The general one issues at
            // most one write at a time so it never exceeds one; the fill path
            // can be several deep.
            case ({(dr == DR_FILL) && fb_req && fb_we,
                   fb_ack && (dr == DR_FILL || dr == DR_DRAIN)})
                2'b10:   wr_outstanding <= wr_outstanding + 4'd1;
                2'b01:   wr_outstanding <= wr_outstanding - 4'd1;
                default: ;
            endcase
        end
    end

    // ---- frame buffer port -------------------------------------------------
    wire zpat_hit = !dm0_enzpattern || zpattern[zbit];
    wire skip_pix = (first_pix && dm0_skipfirst)
                 || (row_done && dm0_skiplast)
                 || (!clip_ok)
                 || (!zpat_hit && !dm0_zpopaque);

    always_comb begin
        fb_req   = 1'b0;
        fb_we    = 1'b0;
        fb_addr  = 32'h0;
        fb_wdata = 64'h0;
        fb_be    = 8'hFF;
        case (dr)
            DR_SRC_RD: begin
                fb_req  = 1'b1;
                fb_addr = fb_byte_addr(src_x, src_y);
            end
            DR_DST_RD: begin
                fb_req  = 1'b1;
                fb_addr = fb_byte_addr(dst_x, dst_y);
            end
            DR_FILL: begin
                fb_req   = !skip_pix;
                fb_we    = 1'b1;
                fb_addr  = fb_byte_addr(dst_x, dst_y);
                fb_wdata = fb_word_new;
                fb_be    = fb_be_masked;
            end
            DR_WR: begin
                fb_req   = (dm0_opcode != OP_READ) && !skip_pix;
                fb_we    = 1'b1;
                fb_addr  = fb_byte_addr(dst_x, dst_y);
                fb_wdata = fb_word_new;
                fb_be    = fb_be_masked;
            end
            default: ;
        endcase
    end

endmodule
