//============================================================================
//  ram_arb - the CPU and the DMA engines sharing main memory's ONE port.
//
//  This is the only arbiter in the core, and it is deliberately not a bus
//  arbiter: it covers the single main-memory port on rtl/mister/ddr3_mux.sv,
//  because the descriptors and buffers the HPC3's SCSI channel and the MC's
//  GIO64 fill engine touch are in main memory and nothing else here masters
//  anything. The Ethernet channels will want the same port and this will
//  serve them; a general crossbar is work nobody has asked for.
//
//  THE TWO MASTERS HAVE DIFFERENT SHAPES AND THAT IS THE WHOLE DIFFICULTY.
//  The CPU PULSES: rtl/cpu/r4300_bus.sv raises `bus_req` for exactly one
//  cycle and then waits in S_BUSY for an acknowledgement, holding its address
//  and write data but not its request. The DMA engines HOLD, because a master
//  that dropped its request into a variable-latency memory would wait forever
//  for an answer nobody had heard. A request that is caught or lost, sharing
//  a port with one that is caught repeatedly.
//
//  WHY THIS IS ITS OWN FILE. It used to be twenty lines inside sgi_indy.sv,
//  and those twenty lines had a bug that no simulation in this repository
//  could see, because `verilator/sim_ram.v` answers in ONE CYCLE and DDR3
//  answers in tens. Pulling it out buys exactly one thing and it is the thing
//  that mattered: it can be driven on its own against a memory that is as slow
//  as the real bridge. `make -C verilator ramarbtest` is that, and it fails
//  against the old logic at any latency above one.
//
//  THE BUG, WRITTEN DOWN SO IT IS NOT REINVENTED. The old version gated the
//  DMA on a transaction being in flight and did not gate the CPU:
//
//      wire cpu_ram_req = bus_req && sel_ram && mem_hit;
//      wire dma_grant   = dma_req && !ram_inflight && !cpu_ram_req && dma_hit;
//      assign ram_req   = cpu_ram_req | dma_grant;
//      ... else if (ram_req) begin
//              ram_inflight  <= 1'b1;
//              ram_owner_dma <= dma_grant;      // <-- clobbered mid-flight
//
//  So a CPU access landing anywhere inside a DMA transaction's round trip
//  asserted `ram_req` again and rewrote `ram_owner_dma` to 0 while the DMA's
//  answer was still coming. Three separate things then went wrong from that
//  one line, and all three were seen on hardware before the cause was:
//
//    * the CPU took the DMA's acknowledgement as its own, with the DMA's data
//      on it - a load returning a descriptor word or a disk byte instead of
//      what was asked for. It showed up as the PROM dereferencing a garbage
//      pointer: `lbu $v0, ($t6)` two instructions after `lw $t6, 0x148($a0)`,
//      panicking with bad addresses of 0xf103, 0x747474 and 0x9fc1dc77 on
//      three different boots - values that appear nowhere in the PROM image.
//    * the DMA never got an acknowledgement at all, so a SCSI command hung.
//      That is what made POST's device/cable diagnostic report the disk as
//      failed while the CD-ROM beside it passed.
//    * ddr3_mux drops a request for a master that already has one pending, so
//      the CPU's access was silently lost and only the misrouted ack ever
//      arrived. Whichever way it fell, the machine wedged or panicked.
//
//  IT WAS INVISIBLE IN SIMULATION FOR A REASON WORTH REMEMBERING. The window
//  is exactly as wide as memory is slow. With sim_ram's one-cycle answer the
//  DMA's transaction is in flight for a single cycle, and in the cycle it is
//  granted the CPU is by definition not asking - `dma_grant` requires
//  `!cpu_ram_req` - so there is very nearly no window at all. Against DDR3 it
//  is tens of cycles wide and gets hit constantly. This is the FOURTH time on
//  this project that a unit test whose memory model was kinder than the bridge
//  hid the whole bug; see the same note in ddr3_mux.sv and fb_linecache.sv.
//
//  THE FIX IS TO GATE BOTH MASTERS ON THE SAME THING AND REMEMBER THE PULSE.
//  One transaction on this port at a time, for either master, which is what
//  ddr3_mux can actually hold. The CPU cannot simply be stalled, because its
//  request is a pulse and stalling it drops it - so a CPU access that arrives
//  during a transaction is latched in `cpu_wait` and issued when the port is
//  free. Its payload needs no latch: r4300_bus.sv holds `bus_addr`, `bus_we`,
//  `bus_wdata` and `bus_be` from the cycle it raises `bus_req` until the cycle
//  it is acknowledged, which is exactly the interval this has to bridge.
//============================================================================

module ram_arb (
    input  logic        clk,
    input  logic        reset,

    // ---- the CPU ---------------------------------------------------------
    // `cpu_req` is a ONE-CYCLE PULSE, already gated by the caller on the
    // access being main memory and inside a valid bank. The payload must stay
    // valid from that pulse until `cpu_ack`, which r4300_bus.sv guarantees.
    input  logic        cpu_req,
    input  logic        cpu_we,
    input  logic [31:0] cpu_addr,
    input  logic [63:0] cpu_wdata,
    input  logic  [7:0] cpu_be,
    output logic        cpu_ack,

    // ---- the DMA engines, already muxed into one ------------------------
    // `dma_req` is HELD until `dma_ack`.
    input  logic        dma_req,
    input  logic        dma_we,
    input  logic [31:0] dma_addr,
    input  logic [63:0] dma_wdata,
    input  logic  [7:0] dma_be,
    output logic        dma_ack,
    // Asserted in the cycle a DMA transaction is issued. The caller tags which
    // of its two engines owns it with this; without that tag the MC's fill
    // acknowledgements land on the SCSI channel as completed descriptor
    // cycles. Same class of mistake as the one above, one level down.
    output logic        dma_granted,

    // ---- the shared port on ddr3_mux -------------------------------------
    output logic        ram_req,
    output logic        ram_we,
    output logic [31:0] ram_addr,
    output logic [63:0] ram_wdata,
    output logic  [7:0] ram_be,
    input  logic        ram_ack
);

    // Whether this port has a transaction outstanding, and whose it is. Both
    // masters are held off by `inflight`; the asymmetry between them was the
    // bug.
    logic inflight;
    logic owner_dma;

    // A CPU access that arrived while the port was busy. The CPU pulses, so
    // there is nothing to stall - the request has to be remembered or it is
    // gone.
    logic cpu_wait;

    // THE CPU WINS EVERY TIE, which is why `dma_go` subtracts it. That is not
    // politeness either: the CPU is the one master here that stalls a pipeline
    // while it waits, and the DMA engines are streaming into buffers nobody is
    // watching yet.
    wire cpu_go = (cpu_req | cpu_wait) & ~inflight;
    wire dma_go = dma_req & ~inflight & ~cpu_go;

    always_ff @(posedge clk) begin
        if (reset) begin
            inflight  <= 1'b0;
            owner_dma <= 1'b0;
            cpu_wait  <= 1'b0;
        end else begin
            // Remember a pulse that could not be issued; forget it once it is.
            if (cpu_req && !cpu_go) cpu_wait <= 1'b1;
            else if (cpu_go)        cpu_wait <= 1'b0;

            if (cpu_go | dma_go) begin
                inflight  <= 1'b1;
                owner_dma <= dma_go;
            end else if (ram_ack) begin
                inflight  <= 1'b0;
            end
        end
    end

    assign ram_req   = cpu_go | dma_go;
    assign ram_we    = dma_go ? dma_we    : cpu_we;
    assign ram_addr  = dma_go ? dma_addr  : cpu_addr;
    assign ram_wdata = dma_go ? dma_wdata : cpu_wdata;
    assign ram_be    = dma_go ? dma_be    : cpu_be;

    assign cpu_ack     = ram_ack & ~owner_dma;
    assign dma_ack     = ram_ack &  owner_dma;
    assign dma_granted = dma_go;

endmodule
