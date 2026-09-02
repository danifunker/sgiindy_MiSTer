//============================================================================
//  fb_fetch_arb - two burst readers on the DDR3 mux's one burst port.
//
//  The display fetches two plane sets per line - the drawing planes and the
//  auxiliary planes, each through its own fb_linecache - and ddr3_mux has one
//  burst read port. This puts the two in front of it. Strictly one burst in
//  flight: a request is forwarded, `fbr_taken` comes back to whoever asked,
//  and every `fbr_dout_valid` word until the burst is complete belongs to
//  that requester. The mux itself serialises bursts the same way, so the data
//  stream is never ambiguous.
//
//  THE SELECTION IS LATCHED WHEN THE REQUEST IS PRESENTED, AND THAT IS THE
//  WHOLE CONTRACT. ddr3_mux latches the address and the burst count on the
//  first cycle it sees `fbr_req` and issues them some cycles later; the
//  requester holds its request until `fbr_taken`. The first version of this
//  file chose the winner combinationally right up to the taken cycle, so when
//  the auxiliary cache asked first and the drawing cache arrived a cycle
//  later, the mux issued the auxiliary burst while this file credited the
//  drawing cache with it - and then waited for a word count the burst was
//  never going to deliver. Both caches stalled in their data phase, the
//  restart at vertical sync never got a look in, and build 17 showed one
//  stale line on a black screen. A winner chosen here stays chosen until
//  the mux takes it.
//
//  Port A has priority when both ask at the same moment. It is the drawing
//  planes, without which there is no picture at all; the auxiliary cache
//  usually has nothing to fetch (see TRACK_ZERO in fb_linecache.sv) and can
//  wait a burst when it does.
//============================================================================

module fb_fetch_arb (
    input  logic        clk,
    input  logic        reset,

    // ---- reader A (drawing planes) ---------------------------------------
    input  logic        a_req,
    input  logic [31:0] a_addr,
    input  logic  [7:0] a_burst,
    output logic        a_taken,
    output logic [63:0] a_dout,
    output logic        a_dout_valid,

    // ---- reader B (auxiliary planes) -------------------------------------
    input  logic        b_req,
    input  logic [31:0] b_addr,
    input  logic  [7:0] b_burst,
    output logic        b_taken,
    output logic [63:0] b_dout,
    output logic        b_dout_valid,

    // ---- the mux's burst port ----------------------------------------------
    output logic        fbr_req,
    output logic [31:0] fbr_addr,
    output logic  [7:0] fbr_burst,
    input  logic        fbr_taken,
    input  logic [63:0] fbr_dout,
    input  logic        fbr_dout_valid
);

    // `sel_valid`: a request is being presented to the mux, for reader
    // `sel_b`, and stays presented until taken. `busy`: that burst is in
    // flight and owned by `owner_b`; `left` words are still to come.
    logic       sel_valid, sel_b;
    logic       busy, owner_b;
    logic [8:0] left;

    assign fbr_req   = sel_valid;
    assign fbr_addr  = sel_b ? b_addr  : a_addr;
    assign fbr_burst = sel_b ? b_burst : a_burst;

    assign a_taken = fbr_taken && sel_valid && !sel_b;
    assign b_taken = fbr_taken && sel_valid &&  sel_b;

    assign a_dout = fbr_dout;
    assign b_dout = fbr_dout;
    assign a_dout_valid = fbr_dout_valid && busy && !owner_b;
    assign b_dout_valid = fbr_dout_valid && busy &&  owner_b;

    always_ff @(posedge clk) begin
        if (reset) begin
            sel_valid <= 1'b0;
            sel_b     <= 1'b0;
            busy      <= 1'b0;
            owner_b   <= 1'b0;
            left      <= 9'd0;
        end else begin
            if (sel_valid) begin
                if (fbr_taken) begin
                    sel_valid <= 1'b0;
                    busy      <= 1'b1;
                    owner_b   <= sel_b;
                    left      <= {1'b0, fbr_burst};
                end
            end else if (!busy && (a_req || b_req)) begin
                sel_valid <= 1'b1;
                sel_b     <= !a_req;
            end

            if (busy && fbr_dout_valid) begin
                left <= left - 9'd1;
                if (left <= 9'd1) busy <= 1'b0;
            end
        end
    end

endmodule
