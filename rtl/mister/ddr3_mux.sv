//============================================================================
//  ddr3_mux - the core's four memory ports, on the DE10-Nano's one DDR3.
//
//  WHY THERE IS NO CHOICE ABOUT THIS. An Indy has 64 MB of main memory and
//  Newport has 16 MB of frame buffer, against about 688 KB of M10K on a
//  Cyclone V - and the CPU's two primary caches are already in that. So every
//  byte the machine stores is external memory, and MiSTer gives a core exactly
//  one external memory it can reach at that size: the HPS's DDR3, through the
//  `DDRAM_*` bridge, in a 256 MB window selected by ADDR[28:25].
//
//  N64_MiSTer's rtl/DDR3Mux.vhd is the precedent and a close one - same board,
//  same CPU, nine masters including its video interface on one port - and this
//  is the same idea with four.
//
//  THE ADDRESS IS IN 64-BIT WORDS, NOT BYTES. `DDRAM_ADDR[28:0]` counts
//  doublewords, so the region select is ADDR[28:25] and a byte address is
//  shifted right by three to reach it. Getting that wrong is an eight-times
//  address error, which does not look like an address error: it looks like
//  memory that reads back a value written somewhere else entirely.
//
//  EVERY MASTER HERE PULSES ITS REQUEST. `sgi_indy.sv` drives `ram_req` from
//  the CPU, which asserts for one cycle because on that bus it is the only
//  master and the port is always its to take; the simulation harness answers
//  in the next cycle, so nothing has ever had to hold it. DDR3 answers in
//  neither one cycle nor a fixed number of them, so each port latches the
//  request the cycle it appears and holds it here instead. A master that
//  dropped its own request into a variable-latency memory would wait forever
//  for an answer nobody had heard - which is exactly the bug the HPC3 DMA
//  engine had, and it is written up in docs/13-scsi-dma-plan.md.
//
//  ONE TRANSACTION AT A TIME, AND BURSTS ONLY FOR THE DISPLAY. The CPU and the
//  rasteriser both stall on their own bus and are latency-tolerant, so a
//  single 64-bit word per transaction is the honest shape for them.
//
//  THE DISPLAY IS DIFFERENT AND THE ARITHMETIC IS WHY. A visible line is 1318
//  pixels of eight bytes each, and it has one line time to arrive. Single-word
//  transactions are latency-bound - one outstanding, so roughly one word per
//  round trip - and a round trip through this bridge is tens of cycles, which
//  is an order of magnitude short of what a line needs. Bursts are not an
//  optimisation here: without them the display cannot be fed at all, whatever
//  its priority. `fbr_*` is therefore a BURST port and behaves differently
//  from the other four: request a run of words, then take them as they
//  stream back. rtl/mister/fb_linecache.sv is its only user.
//============================================================================

module ddr3_mux #(
    // DDRAM_ADDR[28:25]. MiSTer reserves 0x30000000 upward for the core, which
    // is 4'b0011, and every core in the tree uses it.
    parameter logic [3:0] REGION = 4'b0011,

    // BYTE offsets within that 256 MB window, and they are byte offsets on
    // purpose: written as the word addresses the bridge actually wants, 64 MB
    // is 25'h080_0000 and one digit of carelessness puts the frame buffer on
    // top of main memory. The first version of this file did exactly that -
    // 25'h400_0000 does not fit in 25 bits, truncated to zero, and the frame
    // buffer aliased the whole of RAM. The unit test caught it as a display
    // read returning data the rasteriser had never written.
    //
    // MAIN MEMORY GETS 64 MB WHETHER OR NOT IT IS USING IT. The OSD offers 32,
    // 48 and 64, and the region is sized for the largest rather than for the
    // selection: a map that moved with the menu would put the frame buffer at
    // a different address for every entry, which the guest never sees and
    // every debugging session would. 80.5 MB of the 256 is spoken for.
    parameter logic [31:0] BASE_RAM  = 32'h0000_0000,  //  64 MB
    parameter logic [31:0] BASE_FB   = 32'h0400_0000,  //  16 MB
    parameter logic [31:0] BASE_PROM = 32'h0500_0000   // 512 KB
) (
    input  logic        clk,
    input  logic        reset,

    // ---- master 0: the display's serial port, highest priority -----------
    // First because it is the only one with a deadline. It is still not fast
    // enough on its own - see the header - but nothing else should ever be
    // ahead of it in the queue.
    input  logic        fbr_req,      // held until fbr_taken
    input  logic [31:0] fbr_addr,
    input  logic  [7:0] fbr_burst,    // 64-bit words, 1..255
    output logic        fbr_taken,    // the burst has been issued
    output logic [63:0] fbr_dout,
    output logic        fbr_dout_valid,

    // ---- master 1: the PROM image download -------------------------------
    // Only ever active while the CPU is held in reset, so its priority costs
    // nothing; it is above main memory so that a download cannot be starved by
    // a core that is somehow running.
    input  logic        dl_req,
    input  logic [31:0] dl_addr,
    input  logic [63:0] dl_wdata,
    input  logic  [7:0] dl_be,
    output logic        dl_ack,

    // ---- master 2: main memory, the CPU and the HPC3 DMA engine ----------
    input  logic        ram_req,
    input  logic        ram_we,
    input  logic [31:0] ram_addr,
    input  logic [63:0] ram_wdata,
    input  logic  [7:0] ram_be,
    output logic [63:0] ram_rdata,
    output logic        ram_ack,

    // ---- master 3: the PROM, read only -----------------------------------
    input  logic        prom_req,
    input  logic [31:0] prom_addr,
    output logic [63:0] prom_rdata,
    output logic        prom_ack,

    // ---- master 4: the rasteriser's random port --------------------------
    // Last. REX3 fills the screen one pixel per transaction and will happily
    // take every cycle there is; it is the one master that should give way.
    input  logic        fbw_req,
    input  logic        fbw_we,
    input  logic [31:0] fbw_addr,
    input  logic [63:0] fbw_wdata,
    input  logic  [7:0] fbw_be,
    output logic [63:0] fbw_rdata,
    output logic        fbw_ack,

    // ---- master 5: the SCSI debug beacon, strictly last -------------------
    // Write-only pulses into the window above the PROM (0x05800000, ARM
    // 0x35800000). Taken only on cycles where nothing else is pending, so
    // observing the machine cannot change what it observes. No ack: the
    // writer never waits, it just streams status words.
    input  logic        bcn_req,
    input  logic [31:0] bcn_addr,
    input  logic [63:0] bcn_wdata,

    // ---- the DE10-Nano's DDR3 bridge --------------------------------------
    input  logic        DDRAM_BUSY,
    output logic  [7:0] DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY,
    output logic        DDRAM_RD,
    output logic [63:0] DDRAM_DIN,
    output logic  [7:0] DDRAM_BE,
    output logic        DDRAM_WE
);

    localparam int NM = 6;
    localparam int M_FBR = 0, M_DL = 1, M_RAM = 2, M_PROM = 3, M_FBW = 4,
                   M_BCN = 5;

    // ---- one latched request per master ----------------------------------
    logic          [NM-1:0] pend;
    // Whether the request currently asserted by each master has already been
    // taken. Cleared when its request line goes low, so a master that pulses
    // is always caught and one that holds is never taken twice. See the latch
    // loop below, which is where the whole of this file's difficulty lives.
    logic          [NM-1:0] rq_seen;
    logic          [NM-1:0] p_we;
    logic [24:0]            p_addr [NM];   // already a DDR3 word address
    logic [63:0]            p_wdata[NM];
    logic  [7:0]            p_be   [NM];
    logic  [7:0]            p_burst;      // the display's only

    // A byte offset within a region becomes a word address by dropping the low
    // three bits of both, which is the only place the byte/word distinction
    // lives.
    function automatic logic [24:0] wordaddr(input logic [31:0] base,
                                             input logic [31:0] byteaddr);
        wordaddr = base[27:3] + byteaddr[27:3];
    endfunction

    // The request each master is presenting this cycle, before it is latched.
    logic          [NM-1:0] rq;
    logic          [NM-1:0] rq_we;
    logic [24:0]            rq_addr [NM];
    logic [63:0]            rq_wdata[NM];
    logic  [7:0]            rq_be   [NM];

    always_comb begin
        rq[M_FBR]       = fbr_req;
        rq_we[M_FBR]    = 1'b0;
        rq_addr[M_FBR]  = wordaddr(BASE_FB, fbr_addr);
        rq_wdata[M_FBR] = 64'h0;
        rq_be[M_FBR]    = 8'h0;

        rq[M_DL]        = dl_req;
        rq_we[M_DL]     = 1'b1;
        rq_addr[M_DL]   = wordaddr(BASE_PROM, dl_addr);
        rq_wdata[M_DL]  = dl_wdata;
        rq_be[M_DL]     = dl_be;

        rq[M_RAM]       = ram_req;
        rq_we[M_RAM]    = ram_we;
        rq_addr[M_RAM]  = wordaddr(BASE_RAM, ram_addr);
        rq_wdata[M_RAM] = ram_wdata;
        rq_be[M_RAM]    = ram_be;

        rq[M_PROM]       = prom_req;
        rq_we[M_PROM]    = 1'b0;
        rq_addr[M_PROM]  = wordaddr(BASE_PROM, prom_addr);
        rq_wdata[M_PROM] = 64'h0;
        rq_be[M_PROM]    = 8'h0;

        rq[M_FBW]       = fbw_req;
        rq_we[M_FBW]    = fbw_we;
        rq_addr[M_FBW]  = wordaddr(BASE_FB, fbw_addr);
        rq_wdata[M_FBW] = fbw_wdata;
        rq_be[M_FBW]    = fbw_be;

        // The beacon's address is already a byte offset in the region.
        rq[M_BCN]       = bcn_req;
        rq_we[M_BCN]    = 1'b1;
        rq_addr[M_BCN]  = wordaddr(32'h0, bcn_addr);
        rq_wdata[M_BCN] = bcn_wdata;
        rq_be[M_BCN]    = 8'hFF;
    end

    // ---- the transaction in flight ----------------------------------------
    typedef enum logic [1:0] { T_IDLE, T_ISSUE, T_WAIT } tstate_t;
    tstate_t          tst;
    logic [$clog2(NM)-1:0] cur;

    // THE DISPLAY GOES FIRST AND EVERYTHING ELSE TAKES TURNS, and the second
    // half of that is not politeness. Straight fixed priority was the first
    // version and the unit test measured what it does: at four masters all
    // asking, the rasteriser - last in the list - got 62 transactions against
    // the display's 3707 and waited 5370 cycles for one of them. On hardware
    // that is a screen that fills at a crawl whenever anything else is using
    // memory, which is always.
    //
    // So the display keeps absolute priority, because it is the only master
    // with a deadline, and the other four rotate. `rr` is the last one served
    // among them, as an index into 1..NM-1.
    logic [1:0] rr;
    logic [$clog2(NM)-1:0] pick;
    logic                  any;
    always_comb begin
        pick = '0;
        any  = 1'b0;
        if (pend[M_FBR]) begin
            pick = $clog2(NM)'(M_FBR);
            any  = 1'b1;
        end else begin
            // k counts forward from the one after `rr`; scanning k downward
            // and letting the last assignment win picks the nearest. The
            // bound is the ROTATING GROUP's size (masters 1..4), not NM-2:
            // the beacon master below is not in the rotation.
            for (int k = 3; k >= 0; k--) begin
                automatic logic [$clog2(NM)-1:0] cand =
                    $clog2(NM)'(1 + ((rr + k[1:0]) & 2'b11));
                if (pend[cand]) begin
                    pick = cand;
                    any  = 1'b1;
                end
            end
        end
        // The beacon goes ONLY when nobody else is asking: strictly last, so
        // the observation cannot cost the observed machine a cycle it would
        // otherwise have had.
        if (!any && pend[M_BCN]) begin
            pick = $clog2(NM)'(M_BCN);
            any  = 1'b1;
        end
    end

    logic [63:0] rdata_q;
    logic  [NM-1:0] ack_q;

    // The burst's remaining word count. Non-zero means the display's data is
    // streaming and every DOUT_READY belongs to it.
    logic  [8:0] burst_left;

    assign ram_rdata  = rdata_q;
    assign prom_rdata = rdata_q;
    assign fbw_rdata  = rdata_q;
    assign dl_ack     = ack_q[M_DL];
    assign ram_ack    = ack_q[M_RAM];
    assign prom_ack   = ack_q[M_PROM];
    assign fbw_ack    = ack_q[M_FBW];

    // THE DISPLAY DOES NOT GET AN `ack` AND A LATCHED WORD, it gets a stream.
    // `fbr_taken` says the burst was issued so the requester may stop holding
    // its request; every DOUT_READY while the display owns the bus is one of
    // its words.
    // `fbr_taken` IS ASSERTED WHEN THE BURST IS ISSUED, NOT WHEN IT FINISHES,
    // and the difference is the whole handshake. The requester holds its
    // request until this, then counts words; if it only came at the end, the
    // requester would still be waiting to be told to start while its data was
    // streaming past it.
    //
    // This was wrong in exactly that way, and the two unit tests did not catch
    // it between them - tb_ddr3 drove the port and never checked when the
    // handshake arrived, and tb_linecache modelled a bridge that asserted it
    // at issue, which is the contract this file did not implement. Two tests,
    // one on each side, both passing, and the sides disagreeing.
    logic fbr_taken_q;
    assign fbr_dout       = DDRAM_DOUT;
    assign fbr_dout_valid = DDRAM_DOUT_READY && (tst == T_WAIT) &&
                            (cur == $clog2(NM)'(M_FBR));
    assign fbr_taken      = fbr_taken_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            burst_left     <= 9'd0;
            fbr_taken_q    <= 1'b0;
            pend           <= '0;
            rq_seen        <= '0;
            ack_q          <= '0;
            tst            <= T_IDLE;
            cur            <= '0;
            rr             <= 2'd0;
            rdata_q        <= 64'h0;
            DDRAM_RD       <= 1'b0;
            DDRAM_WE       <= 1'b0;
            DDRAM_ADDR     <= 29'h0;
            DDRAM_DIN      <= 64'h0;
            DDRAM_BE       <= 8'h0;
            DDRAM_BURSTCNT <= 8'd1;
        end else begin
            ack_q       <= '0;
            fbr_taken_q <= 1'b0;

            // Latch every request the cycle it appears. A master that pulses
            // and walks away is why this exists at all.
            //
            // BUT "APPEARS" IS NOT THE SAME AS "IS ASSERTED", AND TELLING THEM
            // APART IS WHAT MAKES THE RASTERISER WORK. Two shapes of master
            // share this port. sgi_indy.sv's CPU PULSES: one cycle, gone,
            // catch it or lose it. REX3 HOLDS: `fb_req` is combinational from
            // its state machine, so in the cycle it is acknowledged it is
            // still presenting the request that ack belongs to - it cannot
            // have reacted yet - and it goes from a destination read straight
            // into the write with the line never dropping at all.
            //
            // Reading that held line as a new request takes the same
            // transaction twice. For memory a duplicate is invisible: the same
            // word read, or the same word written with the same data. For REX3
            // it is fatal, because REX3 alternates reads and writes on one
            // port and counts acknowledgements to know which is which. One
            // duplicate puts it permanently one behind - it takes the
            // duplicate's ack as its write's, then takes the write's ack as
            // its next destination READ's, latching `rdata_q` while that
            // register holds whatever the last read by ANY master returned.
            // Measured on hardware: a frame buffer written entirely with the
            // CPU's own instruction fetches, the words of the REX3WAIT poll
            // loop the PROM was spinning in, and a black screen.
            //
            // So a request is new if the line has just RISEN, or if what it is
            // presenting has CHANGED since the transaction taken from it. The
            // first half serves the pulsing masters and the second serves the
            // read-then-write transition that never drops the line. Guarding
            // on the acknowledgement instead is the obvious fix and it is
            // wrong: a pulse that lands in its own ack cycle is then dropped
            // and its master waits for an answer forever. tb_ddr3 fails that
            // way in seconds, which is the only reason this comment is right.
            //
            // NO SIMULATION SAW THE ORIGINAL. The headless harness has its own
            // one-cycle memory and never instantiates this file, and tb_ddr3
            // drove every master as a pulse. Its phase 3 is REX3's shape now.
            for (int i = 0; i < NM; i++) begin
                // Blocked only in the cycle that carries the master's own
                // acknowledgement, and only when what it is presenting is the
                // transaction just completed. Leaving `ack_q` out of it - "a
                // held request that has not changed is never new" - hangs
                // REX3's screen-to-screen copy, where DR_SRC_RD and DR_DST_RD
                // are two reads of the SAME address with the line never
                // dropping between them: the second would never be taken and
                // the rasteriser would wait for ever.
                if (!rq[i]) rq_seen[i] <= 1'b0;
                else if (!pend[i] && !(rq_seen[i] && ack_q[i]
                                       && rq_we[i]   == p_we[i]
                                       && rq_addr[i] == p_addr[i])) begin
                    pend[i]    <= 1'b1;
                    rq_seen[i] <= 1'b1;
                    if (i == M_FBR) p_burst <= fbr_burst;
                    p_we[i]    <= rq_we[i];
                    p_addr[i]  <= rq_addr[i];
                    p_wdata[i] <= rq_wdata[i];
                    p_be[i]    <= rq_be[i];
                end
            end

            case (tst)
                T_IDLE: if (any) begin
                    cur            <= pick;
                    burst_left     <= (pick == $clog2(NM)'(M_FBR))
                                      ? {1'b0, p_burst} : 9'd1;
                    // Only the rotating group advances the pointer; the
                    // display is not in it and must not push anyone's turn.
                    if (pick != $clog2(NM)'(M_FBR) &&
                        pick != $clog2(NM)'(M_BCN)) rr <= 2'(pick - 1);
                    DDRAM_ADDR     <= {REGION, p_addr[pick]};
                    DDRAM_BURSTCNT <= (pick == $clog2(NM)'(M_FBR)) ? p_burst : 8'd1;
                    DDRAM_DIN      <= p_wdata[pick];
                    DDRAM_BE       <= p_we[pick] ? p_be[pick] : 8'hFF;
                    DDRAM_RD       <= ~p_we[pick];
                    DDRAM_WE       <=  p_we[pick];
                    tst            <= T_ISSUE;
                end

                // THE BRIDGE TAKES THE REQUEST ON A CYCLE WHERE IT IS NOT
                // BUSY, and until then RD/WE and the address have to be held
                // exactly as presented. Dropping them for a cycle does not
                // retry the transaction, it loses it.
                T_ISSUE: if (!DDRAM_BUSY) begin
                    DDRAM_RD <= 1'b0;
                    DDRAM_WE <= 1'b0;
                    if (p_we[cur]) begin
                        // A write needs no answer. Acknowledge it now: the
                        // bridge has taken it and ordering against a later
                        // read of the same address is the bridge's problem,
                        // which is what makes it a bridge.
                        pend[cur]  <= 1'b0;
                        ack_q[cur] <= 1'b1;
                        tst        <= T_IDLE;
                    end else begin
                        if (cur == $clog2(NM)'(M_FBR)) fbr_taken_q <= 1'b1;
                        tst <= T_WAIT;
                    end
                end

                // A burst returns burst_left words, in order, one per
                // DOUT_READY. Everything else returns exactly one, so the
                // same counter serves both.
                default: if (DDRAM_DOUT_READY) begin
                    rdata_q    <= DDRAM_DOUT;
                    burst_left <= burst_left - 9'd1;
                    if (burst_left <= 9'd1) begin
                        pend[cur]  <= 1'b0;
                        ack_q[cur] <= 1'b1;
                        tst        <= T_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
