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
//  PIPELINED SINCE docs/design/cpu-speed-tlb-icache.md. Every master still has at most one transaction
//  outstanding, but the bridge takes a new command while earlier reads are
//  still answering (the scaler's own Avalon master relies on the same thing),
//  so the display, the CPU and the rasteriser no longer wait out each other's
//  round trips - only each other's words, and the display's words come in
//  short sub-bursts. See `rf_*` and `fbr_*` below. The CPU's CACHE LINE FILLS
//  ARE BURSTS: `ram_burst` asks for 1..4 consecutive words and the port
//  answers with one `ram_ack` per word, `ram_last` on the final one. Measured
//  on the board before that existed (docs/39), a line fill was one full round
//  trip PER WORD - 36 cycles for a 16-byte data line, ~72 for a 32-byte
//  instruction line - and the round trip, not the word, is what a DDR3 access
//  costs. A burst pays it once.
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
    parameter logic [31:0] BASE_PROM = 32'h0500_0000,  // 512 KB

    // The display's bursts go to the bridge as reads of at most FBR_SUB words,
    // at most FBR_AHEAD of them outstanding at once (docs/design/cpu-speed-tlb-icache.md). tb_ddr3 runs a
    // second build with small values so the splitting is exercised.
    //
    // 4, NOT 16 (docs/design/r4600-accuracy-clock-disk.md). The bridge answers reads in the order it took
    // them, so a CPU cache fill taken while the display has its sub-bursts
    // outstanding waits for all of their words first: up to FBR_AHEAD x
    // FBR_SUB = 32 of them at 16. Build 31 on the board spent 24 clocks per
    // line fill on the bus, against 8 in the simulator, which has no display
    // behind the mux. At 4 the wait is at most 8 words. The display's stream
    // stays continuous - FBR_AHEAD sub-bursts still overlap - and in tb_ddr3
    // its worst wait went from 45 clocks to 83, against ~5000 clocks of
    // line-cache slack; perfprobe's line-cache miss counts are the check.
    parameter int FBR_SUB   = 4,
    parameter int FBR_AHEAD = 2
) (
    input  logic        clk,
    input  logic        reset,

    // ---- master 0: the display's serial port -----------------------------
    // The only master with a deadline. Second in line since docs/design/cpu-speed-tlb-icache.md, behind
    // main memory, which never has more than one short transaction out; its
    // bursts go to the bridge as sub-bursts (FBR_SUB) so nothing waits long
    // behind them either.
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
    // Words per READ, 1..4 (0 reads as 1; a write is always one word). Held
    // with the rest of the payload until the transaction is taken.
    input  logic  [2:0] ram_burst,
    // A LINE WRITE (build 38): ram_we with ram_burst = 4 writes ram_wdata at
    // ram_addr and ram_wdata3's three words at the next three, acknowledged
    // once, with ram_last. See the take branch below.
    input  logic [191:0] ram_wdata3,
    output logic [63:0] ram_rdata,
    // One per word of a burst, not one per transaction; `ram_last` marks the
    // final word. A write is acknowledged once, with `ram_last` set.
    output logic        ram_ack,
    output logic        ram_last,

    // ---- master 3: the PROM, read only -----------------------------------
    input  logic        prom_req,
    input  logic [31:0] prom_addr,
    output logic [63:0] prom_rdata,
    output logic        prom_ack,

    // ---- master 4: the rasteriser's random port --------------------------
    // Rotates with the download and the PROM, after main memory and the
    // display. REX3 fills the screen one pixel per transaction and will happily
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

    // ---- observation only: the performance counters in sgiindy.sv --------
    // (docs/design/cpu-speed-tlb-icache.md). Who is outstanding, who is waiting, and what the bridge took
    // this clock; nothing here feeds back into the scheduling.
    output logic  [5:0] dbg_busy,     // masters with a transaction outstanding
    output logic  [5:0] dbg_pend,     // masters with a request latched, not yet presented
    output logic        dbg_take,     // the bridge took a command this clock
    output logic  [2:0] dbg_take_m,   // ...for this master
    output logic        dbg_take_rd,  // ...and it was a read
    output logic        dbg_gap,      // reads are owed and no word came back this clock
    output logic        dbg_cmdwait,  // a command is waiting on DDRAM_BUSY
    // Where a main-memory read's latency goes (build 37), three beacon words;
    // see the accounting block at the end.
    //   [0] {clocks from a RAM read's take to its first word /64, RAM reads taken}
    //   [1] {words owed to earlier reads when a RAM read was taken /64,
    //        clocks a RAM burst's words stopped coming after its first /64}
    //   [2] {clocks from take to first word, reads taken with nothing owed /64,
    //        reads taken with nothing owed}
    output logic [63:0] dbg_rdlat [3],

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
    logic  [2:0]            p_rburst;     // the CPU's, 1..4
    logic                   p_wline;      // the CPU's write is a 4-word line
    logic [191:0]           p_wdata3;     // ...and these are its words 1..3

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

    // ---- the display's burst, served as sub-bursts ---------------------------
    // fb_linecache asks for up to 128 words at a time and counts them as they
    // stream back; that contract is unchanged. What changed (docs/design/cpu-speed-tlb-icache.md) is how
    // the bridge is asked: the burst goes out as FBR_SUB-word reads, each one
    // presented while the one before it is still answering, never more than
    // FBR_AHEAD outstanding. The display's stream stays continuous - the next
    // read's latency runs while the previous read's words arrive - and any
    // other master's command can be taken between two sub-bursts instead of
    // waiting out 128 words and a round trip.
    logic        fbr_act;        // a display burst is being served
    logic [24:0] fbr_nxt;        // word address of the next sub-burst
    logic  [7:0] fbr_isl;        // words not yet asked for
    logic  [8:0] fbr_rxl;        // words not yet delivered
    logic  [2:0] fbr_out;        // sub-bursts asked for and not finished
    logic        fbr_first;      // no sub-burst of this burst taken yet
    wire   [7:0] fbr_n = (fbr_isl < 8'(FBR_SUB)) ? fbr_isl : 8'(FBR_SUB);

    // ---- who goes next --------------------------------------------------------
    // PIPELINED, SO PRIORITY DECIDES ORDER AND NOT WHO WAITS FOR WHOM. Every
    // master has at most one transaction outstanding - a pulsing master waits
    // for its acknowledgement before it asks again, the latch below refuses a
    // master that is still `busy`, and the display's sub-bursts are capped at
    // FBR_AHEAD - so no master can take turn after turn: while one master's
    // transaction is outstanding the others are the only candidates. That is
    // what makes a fixed order safe here, where one transaction at a time made
    // it starve the rasteriser (62 rasteriser transactions against the
    // display's 3707 in tb_ddr3 under fixed priority, before the rotation).
    //
    // The order: MAIN MEMORY FIRST, because the CPU stalls its whole pipeline
    // on every one of its transactions and never has more than one; then THE
    // DISPLAY, the only master with a deadline; then the download, the PROM
    // and the rasteriser, rotating; the beacon only when nobody else is
    // asking, so observing the machine cannot cost it a clock.
    logic [1:0]            rr;
    logic [$clog2(NM)-1:0] pick;
    logic                  any;
    logic         [NM-1:0] busy_m;     // taken or presented, not yet finished
    logic         [NM-1:0] cand;
    logic                  cmd_v;
    logic [$clog2(NM)-1:0] cmd_m;
    // A MAIN-MEMORY REQUEST GOES IN FRONT OF THE BRIDGE IN THE CLOCK IT ARRIVES
    // (build 38), not a clock later out of the latch. `ram_arrive` is exactly
    // the condition under which the latch loop below would take it; when main
    // memory is then the pick - it always is, it goes first - the command is
    // loaded from the port itself (`ram_now`) and the latch's `pend` is
    // cleared on the same edge that would have set it. The CPU and the DMA
    // engines each wait for their acknowledgement, so nearly every request
    // arrives to an idle main-memory slot: a clock off every transaction.
    wire ram_arrive = rq[M_RAM] && !pend[M_RAM] && !busy_m[M_RAM]
                      && !(rq_seen[M_RAM] && ack_q[M_RAM]
                           && rq_we[M_RAM] == p_we[M_RAM]
                           && rq_addr[M_RAM] == p_addr[M_RAM]);
    wire [2:0] rq_rburst = (ram_we || ram_burst == 3'd0) ? 3'd1 : ram_burst;

    always_comb begin
        cand = pend & ~busy_m;
        cand[M_RAM] = (pend[M_RAM] | ram_arrive) & ~busy_m[M_RAM];
        cand[M_FBR] = fbr_act && (fbr_isl != 8'd0)
                   && (fbr_out < 3'(FBR_AHEAD))
                   && !(cmd_v && cmd_m == $clog2(NM)'(M_FBR));
    end
    always_comb begin
        pick = '0;
        any  = 1'b0;
        if (cand[M_RAM]) begin
            pick = $clog2(NM)'(M_RAM);
            any  = 1'b1;
        end else if (cand[M_FBR]) begin
            pick = $clog2(NM)'(M_FBR);
            any  = 1'b1;
        end else begin
            // DL, PROM, FBW rotate: slot k+1 after `rr` first, scanning
            // downward so the nearest wins.
            for (int k = 2; k >= 0; k--) begin
                automatic logic [1:0] slot = 2'((32'(rr) + k + 1) % 3);
                automatic logic [$clog2(NM)-1:0] c =
                    (slot == 2'd0) ? $clog2(NM)'(M_DL)
                  : (slot == 2'd1) ? $clog2(NM)'(M_PROM)
                  :                  $clog2(NM)'(M_FBW);
                if (cand[c]) begin
                    pick = c;
                    any  = 1'b1;
                end
            end
            if (!any && cand[M_BCN]) begin
                pick = $clog2(NM)'(M_BCN);
                any  = 1'b1;
            end
        end
    end
    wire [1:0] pick_slot = (pick == $clog2(NM)'(M_DL))   ? 2'd0
                         : (pick == $clog2(NM)'(M_PROM)) ? 2'd1 : 2'd2;
    wire       ram_now   = (pick == $clog2(NM)'(M_RAM)) && !pend[M_RAM];
    wire       pick_we   = (pick == $clog2(NM)'(M_FBR)) ? 1'b0
                         : ram_now ? ram_we : p_we[pick];

    logic [63:0] rdata_q;
    logic  [NM-1:0] ack_q;

    assign ram_rdata  = rdata_q;
    assign prom_rdata = rdata_q;
    assign fbw_rdata  = rdata_q;
    assign dl_ack     = ack_q[M_DL];
    assign ram_ack    = ack_q[M_RAM];
    logic ram_last_q;
    assign ram_last   = ram_last_q;
    assign prom_ack   = ack_q[M_PROM];
    assign fbw_ack    = ack_q[M_FBW];

    // ---- the command in front of the bridge, and the reads behind it -------
    // `cmd_v`: RD or WE is being presented, for `cmd_m`. The bridge takes it on
    // a clock where it is not busy, and from that clock on a WRITE is done (it
    // needs no answer - ordering against a later read of the same address is
    // the bridge's, as it always was) and a READ is owed words.
    //
    // THE BRIDGE ANSWERS READS IN THE ORDER IT TOOK THEM, AND THIS KEEPS THAT
    // ORDER: `rf_*` is a queue of {master, words} for every read taken and not
    // yet answered, oldest at `rf_rd`, and each DOUT_READY belongs to the head.
    // At most FBR_AHEAD display sub-bursts plus one read each for main memory,
    // the PROM and the rasteriser can be in it.
    //
    // WHY NOT ONE TRANSACTION AT A TIME, as this file did until build 28. The
    // bridge answers a read ~10 clocks after taking it and the display fetches
    // every line of every frame, holding the port about 41 % of the time. One
    // transaction at a time meant a CPU cache fill, or a writeback, arriving
    // during a display burst queued behind the whole burst AND its round trip:
    // 15-20 clocks waiting for 8-11 held, on every CPU transaction, measured on
    // the board (docs/design/cpu-speed-tlb-icache.md). The scaler's own Avalon master (sys/ascal.vhd)
    // already relies on the bridge taking commands while reads are owed.
    logic                  cmd_we;
    logic  [7:0]           cmd_n;

    // THE LINE WRITE GOES TO THE BRIDGE AS FOUR SINGLE-WORD WRITES, BACK TO
    // BACK (build 38). The CPU hands a dirty data cache line over as one
    // transaction; the bridge is given what it has always been given - one
    // write command, one word - four times, each presented in the clock the
    // one before it is taken, so no other master's command falls between
    // them and the words need no burst protocol from the bridge. `wl_left`
    // counts the words still to present after the one in front of it.
    logic  [1:0]           wl_left;
    logic [191:0]          wl_data;
    logic [24:0]           wl_addr;
    wire                   wl_cont = cmd_we && (cmd_m == $clog2(NM)'(M_RAM))
                                     && (wl_left != 2'd0);

    localparam int RF = 8;
    logic [15:0] ob_now;          // observation only: a clock count, see the end
    logic [$clog2(NM)-1:0] rf_m [RF];
    logic  [7:0]           rf_n [RF];
    logic  [2:0]           rf_rd, rf_wr;
    logic  [3:0]           rf_cnt;

    wire                  take      = cmd_v && !DDRAM_BUSY;
    wire                  push      = take && !cmd_we;
    wire                  rf_head_v = (rf_cnt != 4'd0);
    wire [$clog2(NM)-1:0] rf_head_m = rf_m[rf_rd];
    wire                  word      = DDRAM_DOUT_READY && rf_head_v;
    wire                  word_end  = word && (rf_n[rf_rd] <= 8'd1);   // the head read is done
    wire                  fbr_word  = word && (rf_head_m == $clog2(NM)'(M_FBR));

    // THE DISPLAY DOES NOT GET AN `ack` AND A LATCHED WORD, it gets a stream.
    // `fbr_taken` says the burst was issued so the requester may stop holding
    // its request; every DOUT_READY the read queue says is the display's is one
    // of its words.
    // `fbr_taken` IS ASSERTED WHEN THE BURST IS ISSUED, NOT WHEN IT FINISHES,
    // and the difference is the whole handshake. The requester holds its
    // request until this, then counts words; if it only came at the end, the
    // requester would still be waiting to be told to start while its data was
    // streaming past it. Sub-bursts do not change it: it comes when the FIRST
    // sub-burst is taken, which is before any word of the burst can arrive.
    //
    // This was wrong in exactly that way, and the two unit tests did not catch
    // it between them - tb_ddr3 drove the port and never checked when the
    // handshake arrived, and tb_linecache modelled a bridge that asserted it
    // at issue, which is the contract this file did not implement. Two tests,
    // one on each side, both passing, and the sides disagreeing.
    logic fbr_taken_q;
    assign fbr_dout       = DDRAM_DOUT;
    assign fbr_dout_valid = fbr_word;
    assign fbr_taken      = fbr_taken_q;

    // observation (docs/design/cpu-speed-tlb-icache.md)
    logic [NM-1:0] busy_obs;
    always_comb begin
        busy_obs = busy_m;
        busy_obs[M_FBR] = fbr_act;
    end
    assign dbg_busy    = busy_obs;
    assign dbg_pend    = pend;
    assign dbg_take    = take;
    assign dbg_take_m  = cmd_m;
    assign dbg_take_rd = push;
    assign dbg_gap     = rf_head_v && !DDRAM_DOUT_READY;
    assign dbg_cmdwait = cmd_v && DDRAM_BUSY;

    always_ff @(posedge clk) begin
        if (reset) begin
            fbr_taken_q    <= 1'b0;
            pend           <= '0;
            rq_seen        <= '0;
            busy_m         <= '0;
            ack_q          <= '0;
            ram_last_q     <= 1'b1;
            cmd_v          <= 1'b0;
            cmd_m          <= '0;
            cmd_we         <= 1'b0;
            cmd_n          <= 8'd1;
            rf_rd          <= 3'd0;
            rf_wr          <= 3'd0;
            rf_cnt         <= 4'd0;
            ob_now         <= 16'd0;
            wl_left        <= 2'd0;
            fbr_act        <= 1'b0;
            fbr_nxt        <= 25'd0;
            fbr_isl        <= 8'd0;
            fbr_rxl        <= 9'd0;
            fbr_out        <= 3'd0;
            fbr_first      <= 1'b0;
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
            ram_last_q  <= 1'b1;
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
            //
            // Pipelined, "still in flight" is `busy_m` (presented or taken,
            // owed an answer) - or, for the display, `fbr_act` - rather than
            // `pend` (latched, not yet presented): a master is refused while
            // either is set, exactly as the one-transaction version refused it
            // while `pend` covered both.
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
                else if (!pend[i] && !busy_m[i]
                         && !(i == M_FBR && fbr_act)
                         && !(rq_seen[i] && ack_q[i]
                              && rq_we[i]   == p_we[i]
                              && rq_addr[i] == p_addr[i])) begin
                    rq_seen[i] <= 1'b1;
                    if (i == M_FBR) begin
                        // The display's burst goes straight into service;
                        // its sub-bursts become candidates from the next clock.
                        fbr_act   <= 1'b1;
                        fbr_nxt   <= rq_addr[i];
                        fbr_isl   <= (fbr_burst == 8'd0) ? 8'd1 : fbr_burst;
                        fbr_rxl   <= (fbr_burst == 8'd0) ? 9'd1 : {1'b0, fbr_burst};
                        fbr_first <= 1'b1;
                    end else begin
                        pend[i] <= 1'b1;
                    end
                    if (i == M_RAM) begin
                        p_rburst <= (ram_we || ram_burst == 3'd0) ? 3'd1 : ram_burst;
                        p_wline  <= ram_we && (ram_burst == 3'd4);
                        p_wdata3 <= ram_wdata3;
                    end
                    p_we[i]    <= rq_we[i];
                    p_addr[i]  <= rq_addr[i];
                    p_wdata[i] <= rq_wdata[i];
                    p_be[i]    <= rq_be[i];
                end
            end

            // ---- a word back from the bridge: the oldest read's -------------
            if (word) begin
                rdata_q     <= DDRAM_DOUT;
                rf_n[rf_rd] <= rf_n[rf_rd] - 8'd1;
                // The CPU takes its burst word by word, each with an ack, the
                // way the display takes its stream: the requester counts, and
                // `ram_last` closes the count. The PROM and the rasteriser
                // read single words.
                if (rf_head_m == $clog2(NM)'(M_RAM)) begin
                    ack_q[M_RAM] <= 1'b1;
                    ram_last_q   <= word_end;
                end
                if (word_end) begin
                    rf_rd <= rf_rd + 3'd1;
                    if (rf_head_m != $clog2(NM)'(M_FBR)) begin
                        busy_m[rf_head_m] <= 1'b0;
                        ack_q[rf_head_m]  <= 1'b1;
                    end
                end
            end
            if (fbr_word) begin
                fbr_rxl <= fbr_rxl - 9'd1;
                if (fbr_rxl <= 9'd1) fbr_act <= 1'b0;
            end
            fbr_out <= fbr_out
                     + ((push && cmd_m == $clog2(NM)'(M_FBR)) ? 3'd1 : 3'd0)
                     - ((word_end && rf_head_m == $clog2(NM)'(M_FBR)) ? 3'd1 : 3'd0);

            // ---- the bridge takes the command in front of it ---------------
            // THE BRIDGE TAKES THE REQUEST ON A CYCLE WHERE IT IS NOT BUSY, and
            // until then RD/WE and the address have to be held exactly as
            // presented. Dropping them for a cycle does not retry the
            // transaction, it loses it.
            if (take) begin
                cmd_v    <= 1'b0;
                DDRAM_RD <= 1'b0;
                DDRAM_WE <= 1'b0;
                if (wl_cont) begin
                    // The next word of a line write, in front of the bridge
                    // at once. Not acknowledged: the line is one transaction.
                    cmd_v      <= 1'b1;
                    DDRAM_WE   <= 1'b1;
                    DDRAM_ADDR <= {REGION, wl_addr};
                    DDRAM_DIN  <= wl_data[63:0];
                    wl_data    <= {64'h0, wl_data[191:64]};
                    wl_addr    <= wl_addr + 25'd1;
                    wl_left    <= wl_left - 2'd1;
                end else if (cmd_we) begin
                    // A write needs no answer. Acknowledge it now.
                    ack_q[cmd_m]  <= 1'b1;
                    busy_m[cmd_m] <= 1'b0;
                end else begin
                    rf_m[rf_wr] <= cmd_m;
                    rf_n[rf_wr] <= cmd_n;
                    rf_wr       <= rf_wr + 3'd1;
                    if (cmd_m == $clog2(NM)'(M_FBR) && fbr_first) begin
                        fbr_taken_q <= 1'b1;
                        fbr_first   <= 1'b0;
                    end
                end
            end

            rf_cnt <= rf_cnt + (push ? 4'd1 : 4'd0) - (word_end ? 4'd1 : 4'd0);
            ob_now <= ob_now + 16'd1;
`ifdef DDR3MUX_DEBUG
            if (take || word)
                $display("[mux] take=%0d m=%0d we=%0d n=%0d | word=%0d head_m=%0d head_n=%0d end=%0d | rd=%0d wr=%0d cnt=%0d | fbr act=%0d isl=%0d rxl=%0d out=%0d",
                         take, cmd_m, cmd_we, cmd_n, word, rf_head_m, rf_n[rf_rd], word_end,
                         rf_rd, rf_wr, rf_cnt, fbr_act, fbr_isl, fbr_rxl, fbr_out);
`endif

            // ---- and the next command goes in front of it ------------------
            // The same clock the last one is taken, so a command waits for the
            // bridge and nothing else. A read needs room in the queue, which
            // the caps above keep it from ever lacking; the check is a guard.
            if ((!cmd_v || take) && any && !(take && wl_cont)
                && (pick_we || rf_cnt + (push ? 4'd1 : 4'd0) < 4'(RF))) begin
                cmd_v          <= 1'b1;
                cmd_m          <= pick;
                cmd_we         <= pick_we;
                DDRAM_RD       <= ~pick_we;
                DDRAM_WE       <=  pick_we;
                if (pick == $clog2(NM)'(M_FBR)) begin
                    cmd_n          <= fbr_n;
                    DDRAM_ADDR     <= {REGION, fbr_nxt};
                    DDRAM_BURSTCNT <= fbr_n;
                    DDRAM_DIN      <= 64'h0;
                    DDRAM_BE       <= 8'hFF;
                    fbr_nxt        <= fbr_nxt + 25'(fbr_n);
                    fbr_isl        <= fbr_isl - fbr_n;
                end else begin
                    cmd_n          <= (pick == $clog2(NM)'(M_RAM))
                                      ? {5'b0, ram_now ? rq_rburst : p_rburst} : 8'd1;
                    DDRAM_ADDR     <= {REGION, ram_now ? rq_addr[M_RAM] : p_addr[pick]};
                    DDRAM_BURSTCNT <= (pick == $clog2(NM)'(M_RAM))
                                      ? {5'b0, ram_now ? rq_rburst : p_rburst} : 8'd1;
                    DDRAM_DIN      <= ram_now ? ram_wdata : p_wdata[pick];
                    DDRAM_BE       <= pick_we ? (ram_now ? ram_be : p_be[pick]) : 8'hFF;
                    pend[pick]     <= 1'b0;
                    busy_m[pick]   <= 1'b1;
                    wl_left        <= (pick == $clog2(NM)'(M_RAM) && pick_we
                                       && (ram_now ? (ram_burst == 3'd4) : p_wline))
                                      ? 2'd3 : 2'd0;
                    wl_data        <= ram_now ? ram_wdata3 : p_wdata3;
                    wl_addr        <= (ram_now ? rq_addr[M_RAM] : p_addr[M_RAM]) + 25'd1;
                    if (pick != $clog2(NM)'(M_RAM) && pick != $clog2(NM)'(M_BCN))
                        rr <= pick_slot;
                end
            end
        end
    end

    // ---- observation: a main-memory read's latency, split (build 37) --------
    // docs/design/cpu-speed-tlb-icache.md measured the bridge answering a read 9.7 clocks after taking it,
    // with one transaction at a time; since the mux is pipelined a read also
    // waits for every word owed to reads taken before it, most of them the
    // display's. A line fill costs ~20 clocks on the bus on the board and ~8 in
    // the simulator. These say how much of the difference is the bridge and how
    // much is the queue:
    //   * each queued read keeps the clock it was taken (ob_t) and whether its
    //     first word is still to come; the head's first word closes it.
    //   * `ob_owed` counts the words every queued read is still owed, so a RAM
    //     read's take can add up what it is behind.
    //   * a read taken with nothing owed at all measures the bridge alone
    //     (ob_clean) - any master's, since the bridge does not know whose.
    //   * a RAM burst whose words stop coming after the first adds its gaps.
    // Nothing here feeds back into the scheduling. A 16-bit clock stamp wraps
    // after 1.3 ms, far beyond any latency the queue can reach.
    logic [15:0]   ob_t [RF];
    logic [RF-1:0] ob_first, ob_clean;
    logic  [7:0]   ob_owed;
    logic [37:0]   ob_lat_ram, ob_ahead, ob_gap_ram, ob_lat_clean;
    logic [31:0]   ob_n_ram, ob_n_clean;
    wire   [7:0]   ob_owed_now = ob_owed - (word ? 8'd1 : 8'd0);
    wire  [15:0]   ob_lat      = ob_now - ob_t[rf_rd];

    always_ff @(posedge clk) begin
        if (reset) begin
            ob_first     <= '0;
            ob_clean     <= '0;
            ob_owed      <= 8'd0;
            ob_lat_ram   <= '0;
            ob_ahead     <= '0;
            ob_gap_ram   <= '0;
            ob_lat_clean <= '0;
            ob_n_ram     <= '0;
            ob_n_clean   <= '0;
        end else begin
            ob_owed <= ob_owed_now + (push ? cmd_n : 8'd0);
            if (push) begin
                ob_t[rf_wr]     <= ob_now;
                ob_first[rf_wr] <= 1'b1;
                ob_clean[rf_wr] <= (ob_owed_now == 8'd0);
                if (cmd_m == $clog2(NM)'(M_RAM)) begin
                    ob_n_ram <= ob_n_ram + 32'd1;
                    ob_ahead <= ob_ahead + 38'(ob_owed_now);
                end
            end
            if (word && ob_first[rf_rd]) begin
                ob_first[rf_rd] <= 1'b0;
                if (rf_head_m == $clog2(NM)'(M_RAM))
                    ob_lat_ram <= ob_lat_ram + 38'(ob_lat);
                if (ob_clean[rf_rd]) begin
                    ob_lat_clean <= ob_lat_clean + 38'(ob_lat);
                    ob_n_clean   <= ob_n_clean + 32'd1;
                end
            end
            if (rf_head_v && !DDRAM_DOUT_READY && !ob_first[rf_rd]
                && rf_head_m == $clog2(NM)'(M_RAM))
                ob_gap_ram <= ob_gap_ram + 38'd1;
        end
    end

    assign dbg_rdlat[0] = { ob_lat_ram[37:6],   ob_n_ram };
    assign dbg_rdlat[1] = { ob_ahead[37:6],     ob_gap_ram[37:6] };
    assign dbg_rdlat[2] = { ob_lat_clean[37:6], ob_n_clean };

endmodule
