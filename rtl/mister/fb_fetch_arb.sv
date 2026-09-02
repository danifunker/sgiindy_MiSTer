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
//  Port A has priority when both ask. It is the drawing planes, without which
//  there is no picture at all; the auxiliary cache usually has nothing to
//  fetch (see TRACK_ZERO in fb_linecache.sv) and can wait a burst when it
//  does.
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

    // Which reader owns the burst in flight, and how many words are still
    // to come. `busy` falls with the last word.
    logic       busy, owner_b;
    logic [8:0] left;

    // Present the winner's request while nothing is in flight. The mux holds
    // the request until it is taken, and so do the caches (fbr_req is a state
    // in each), so nothing here needs to latch.
    wire pick_b = !a_req && b_req;
    assign fbr_req   = !busy && (a_req || b_req);
    assign fbr_addr  = pick_b ? b_addr  : a_addr;
    assign fbr_burst = pick_b ? b_burst : a_burst;

    assign a_taken = fbr_taken && !busy && !pick_b;
    assign b_taken = fbr_taken && !busy &&  pick_b;

    assign a_dout = fbr_dout;
    assign b_dout = fbr_dout;
    assign a_dout_valid = fbr_dout_valid && busy && !owner_b;
    assign b_dout_valid = fbr_dout_valid && busy &&  owner_b;

    always_ff @(posedge clk) begin
        if (reset) begin
            busy    <= 1'b0;
            owner_b <= 1'b0;
            left    <= 9'd0;
        end else begin
            if (!busy) begin
                if (fbr_taken) begin
                    busy    <= 1'b1;
                    owner_b <= pick_b;
                    left    <= {1'b0, fbr_burst};
                end
            end else if (fbr_dout_valid) begin
                left <= left - 9'd1;
                if (left <= 9'd1) busy <= 1'b0;
            end
        end
    end

endmodule
