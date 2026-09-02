//============================================================================
//  tb_fetcharb - the display's fetch path as MiSTer builds it: two line
//  caches (drawing planes, auxiliary planes with the flag table) behind
//  fb_fetch_arb, on one burst port. tb_fetcharb.cpp drives it with the
//  display's real pattern against a bridge model that behaves like
//  ddr3_mux - it latches the address and burst count the first cycle it sees
//  a request and issues them later - which is the behaviour that deadlocked
//  the first arbiter and that no single-cache test could see.
//============================================================================
module tb_fetcharb (
    input  logic        clk,
    input  logic        reset,

    // the display side: one request per pixel, into both caches
    input  logic        px_req,
    input  logic [31:0] px_addr_rgb,
    input  logic [31:0] px_addr_aux,
    output logic [63:0] rgb_rdata,
    output logic        rgb_ack,
    output logic        rgb_miss,
    output logic [63:0] aux_rdata,
    output logic        aux_ack,
    output logic        aux_miss,
    input  logic        vs,
    input  logic        mark,
    input  logic [10:0] mark_line,
    output logic [31:0] aux_skips,

    // the mux's burst port
    output logic        fbr_req,
    output logic [31:0] fbr_addr,
    output logic  [7:0] fbr_burst,
    input  logic        fbr_taken,
    input  logic [63:0] fbr_dout,
    input  logic        fbr_dout_valid
);
    logic        lr_req, lr_taken, lr_valid, la_req, la_taken, la_valid;
    logic [31:0] lr_addr, la_addr;
    logic  [7:0] lr_burst, la_burst;
    logic [63:0] lr_dout, la_dout;

    fb_linecache #(.TRACK_ZERO(1'b0)) u_rgb (
        .clk(clk), .reset(reset),
        .px_req(px_req), .px_addr(px_addr_rgb), .px_rdata(rgb_rdata), .px_ack(rgb_ack),
        .vs(vs), .mark(1'b0), .mark_line(11'd0),
        .fbr_req(lr_req), .fbr_addr(lr_addr), .fbr_burst(lr_burst),
        .fbr_taken(lr_taken), .fbr_dout(lr_dout), .fbr_dout_valid(lr_valid),
        .miss(rgb_miss), .dbg_skips(), .dbg_miss_mark(1'b0));

    fb_linecache #(.TRACK_ZERO(1'b1), .REGION_BASE(32'h0080_0000)) u_aux (
        .clk(clk), .reset(reset),
        .px_req(px_req), .px_addr(px_addr_aux), .px_rdata(aux_rdata), .px_ack(aux_ack),
        .vs(vs), .mark(mark), .mark_line(mark_line),
        .fbr_req(la_req), .fbr_addr(la_addr), .fbr_burst(la_burst),
        .fbr_taken(la_taken), .fbr_dout(la_dout), .fbr_dout_valid(la_valid),
        .miss(aux_miss), .dbg_skips(aux_skips), .dbg_miss_mark(1'b0));

    fb_fetch_arb u_arb (
        .clk(clk), .reset(reset),
        .a_req(lr_req), .a_addr(lr_addr), .a_burst(lr_burst),
        .a_taken(lr_taken), .a_dout(lr_dout), .a_dout_valid(lr_valid),
        .b_req(la_req), .b_addr(la_addr), .b_burst(la_burst),
        .b_taken(la_taken), .b_dout(la_dout), .b_dout_valid(la_valid),
        .fbr_req(fbr_req), .fbr_addr(fbr_addr), .fbr_burst(fbr_burst),
        .fbr_taken(fbr_taken), .fbr_dout(fbr_dout), .fbr_dout_valid(fbr_dout_valid));
endmodule
