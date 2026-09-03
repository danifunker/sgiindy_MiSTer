//============================================================================
//  r4300_bus - bridge between the N64 R4300i's mem_* port and the SGI bus.
//
//  THE BYTE-LANE CONTRACT. Read this before touching anything below; it is
//  not symmetric and it is not obvious, and getting it wrong looks like the
//  CPU executing garbage rather than like a bus bug.
//
//  On the CPU side, `mem_dataRead` / `mem_dataWrite` are little-endian byte
//  lanes: lane L means bits [8*L+7 : 8*L]. On the SGI side everything is
//  big-endian, because every SGI register and every PROM structure is:
//  `bus_wdata[63-8*i -: 8]` is the byte at `bus_addr + i`, guarded by
//  `bus_be[7-i]`. The conversion happens here and nowhere else.
//
//  READ. cpu.vhd expects the addressed data at the BOTTOM of mem_dataRead,
//  i.e. the aligned doubleword shifted right by the address's byte offset.
//  This is not a guess - cpu_datacache.vhd:296-303 spells the same rule out
//  for the cached path:
//
//      read_data = cache_q_b >> (8 * RW_addr(2:0))
//
//  and every load type in cpu.vhd's writeback table is consistent with it:
//  LB takes lanes[7:0], LH takes byteswap16(lanes[15:0]), LW takes
//  byteswap32(lanes[31:0]), LD takes both halves byteswapped, and instruction
//  fetch takes byteswap32(lanes[31:0]).
//
//  WRITE. Here the halves swap. cpu.vhd hands the write data over with the
//  low-address word in bits [63:32] whenever the access is 64-bit or lands in
//  the upper half of the doubleword, and both memorymux.vhd:307-314 and
//  cpu_datacache.vhd:275-277 undo it the same way:
//
//      if (req64 or addr[2]) { data = {data[31:0], data[63:32]};
//                              mask = {mask[3:0], mask[7:4]}; }
//
//  after which lane L is simply the byte at (addr & ~7) + L. The SDR-at-
//  offset-0 case pins this down: mask "00010000" (lane 4) with the register's
//  LSB in bits [39:32], for a store of one byte to doubleword offset 0.
//
//  CACHE LINE FILLS. cpu.vhd asks for a line by putting an ordinary read on
//  mem_* and tagging it with mem_size: "100" is a 32-byte line (both caches,
//  since the data cache grew to 32-byte lines - docs/39) and "010" a 16-byte
//  one; everything else is "001", a single access. The address is already
//  aligned to the line by the write FIFO (cpu.vhd:749-770), and it is a
//  normal physical address, so a fill goes through the same decode as
//  everything else.
//
//  A FILL IS ONE BURST REQUEST, AND FALLS BACK TO WORD-AT-A-TIME. `bus_burst`
//  carries the number of doublewords wanted (1, 2 or 4). Main memory streams
//  them back with one bus_ack per word and `bus_last` on the final one; any
//  other responder - the PROM, a hole in MEMCFG - answers one word with
//  bus_last set, and this module then asks for the remainder one word at a
//  time, exactly as every fill used to be done. Measured on the board
//  (docs/39): each word of a fill used to cost a whole DDR3 round trip, ~18
//  cycles, so a 32-byte line was ~72 cycles; a burst pays the trip once.
//
//  The DATA comes back on a different port. The caches do not read
//  mem_dataRead; they take four (or two) beats on ddr3_DOUT/ddr3_DOUT_READY,
//  armed by rdram_granted2x, because upstream fills straight out of the N64's
//  RDRAM controller. cpu_instrcache.vhd:145-161 is the receiver, and it
//  imposes the order this module has to keep:
//
//    1. one cycle of fill_grant, while the fill is the active transaction.
//       It latches the cache's line index and arms the write path. It must
//       NOT overlap a data beat - grant takes priority over the beat counter
//       and the beat would be dropped.
//    2. one fill_data_ready pulse per doubleword, in address order. The cache
//       counts them and disarms itself after the last one.
//    3. mem_done, at least one clock AFTER the last beat - never in the same
//       clock. The data cache answers the access out of the line in the very
//       cycle it sees ram_done, reading port B of a RAM whose port A is still
//       writing the last beat on that edge; and for a store it MERGES the
//       write into the line on port B on that same edge. Read-during-write
//       across ports is undefined (rtl/cpu/prim/dpram.vhd says so), so
//       overlapping them makes the answer depend on process order - a load of
//       the second doubleword of a line comes back stale, which presents as
//       the program jumping through a garbage pointer. One idle clock between
//       the last beat and mem_done is enough, because cpu.vhd registers
//       mem_done into ram_done anyway. The instruction cache never showed
//       this: its fill_done is registered, so it already had the extra clock.
//
//  fill_data is byte-lane data, the same convention as mem_dataRead before
//  the address shift: lane L is the byte at (line base + 8*beat + L). That is
//  what makes the mixed-width cache RAM read back correctly - see
//  rtl/cpu/prim/dpram.vhd on the sub-word ordering it assumes.
//
//  KNOWN GAP - the unaligned load family on the UNCACHED path. cpu.vhd aligns the
//  address it gives the *cache* for LWL/LWR/LDL/LDR (EXECacheAddr at
//  cpu.vhd:2329-2331 forces bits 2:0 to 0 or to addr[2]&"00"), but the
//  address it puts on mem_* is the raw unaligned one. Those loads then want
//  the whole aligned word in lanes[3:0] while the shift rule delivers bytes
//  starting at the unaligned address. Upstream never hits this because N64
//  software does not do unaligned loads from uncached space. The cpu-tests
//  `mem` group exercises exactly this, at every offset, and settles it: all
//  eighteen pass, with the caches on and with `--no-icache --no-dcache`. The
//  concern was real and the answer is that it works; both are recorded here
//  rather than one of them - see docs/09-cpu-validation.md.
//============================================================================

module r4300_bus
(
    input  logic        clk,
    input  logic        reset,

    // ---- CPU side (cpu.vhd mem_* port) -----------------------------------
    input  logic        mem_request,
    input  logic        mem_rnw,
    input  logic [31:0] mem_address,
    input  logic        mem_req64,
    input  logic  [2:0] mem_size,
    input  logic  [7:0] mem_writeMask,
    input  logic [63:0] mem_dataWrite,
    output logic [63:0] mem_dataRead,
    output logic        mem_done,

    // ---- cache line fill response (cpu.vhd's rdram/ddr3 port) -------------
    output logic        fill_grant,       // -> rdram_granted2x
    output logic [63:0] fill_data,        // -> ddr3_DOUT
    output logic        fill_data_ready,  // -> ddr3_DOUT_READY

    // ---- SGI side (big-endian, doubleword) -------------------------------
    output logic        bus_req,
    output logic        bus_we,
    output logic [31:0] bus_addr,     // always 8-byte aligned
    output logic [63:0] bus_wdata,    // [63-8i -: 8] = byte at bus_addr+i
    output logic  [7:0] bus_be,       // be[7-i] guards the byte at +i
    // Byte offset of the access within its doubleword. Byte enables are
    // meaningless on a read - cpu.vhd leaves mem_writeMask at whatever the
    // last write set - so a device with more than one register per doubleword
    // has to select on this instead.
    output logic  [2:0] bus_aoff,
    // Doublewords wanted, 1..4; held with the rest of the payload until the
    // first bus_ack. See "CACHE LINE FILLS" above for the contract.
    output logic  [2:0] bus_burst,
    input  logic [63:0] bus_rdata,
    input  logic        bus_ack,
    // With bus_ack: this is the responder's final word for the request. A
    // responder that cannot burst sets it on its only word.
    input  logic        bus_last
);

    // Byte-reverse: little-endian lanes <-> big-endian bus.
    function automatic logic [63:0] bswap64(input logic [63:0] v);
        for (int i = 0; i < 8; i++) bswap64[8*i +: 8] = v[8*(7-i) +: 8];
    endfunction

    typedef enum logic [1:0] { S_IDLE, S_BUSY, S_FILL, S_FILLEND } state_t;
    state_t state;

    logic [2:0] aoff;     // byte offset of the request within its doubleword
    assign bus_aoff = aoff;

    // The two mem_size values that mean "line fill"; anything else is "001".
    localparam logic [2:0] SZ_DLINE = 3'b010;   // 16 bytes, two beats
    localparam logic [2:0] SZ_ILINE = 3'b100;   // 32 bytes, four beats

    logic       is_fill;
    logic [1:0] fill_beat;   // beat in flight
    logic [1:0] fill_last;   // index of the last beat of this line

    assign is_fill = mem_rnw && (mem_size == SZ_DLINE || mem_size == SZ_ILINE);

    // Write-side half swap, exactly as memorymux.vhd and cpu_datacache.vhd do it.
    logic        swap_halves;
    logic [63:0] wdata_le;
    logic  [7:0] wmask_le;

    assign swap_halves = mem_req64 | mem_address[2];
    assign wdata_le    = swap_halves ? {mem_dataWrite[31:0], mem_dataWrite[63:32]}
                                     :  mem_dataWrite;
    assign wmask_le    = swap_halves ? {mem_writeMask[3:0], mem_writeMask[7:4]}
                                     :  mem_writeMask;

    always_ff @(posedge clk) begin
        if (reset) begin
            state           <= S_IDLE;
            bus_req         <= 1'b0;
            mem_done        <= 1'b0;
            fill_grant      <= 1'b0;
            fill_data_ready <= 1'b0;
        end else begin
            mem_done        <= 1'b0;
            bus_req         <= 1'b0;
            fill_grant      <= 1'b0;
            fill_data_ready <= 1'b0;

            case (state)
                S_IDLE:
                    if (mem_request) begin
                        bus_req   <= 1'b1;
                        bus_we    <= ~mem_rnw;
                        if (is_fill) begin
                            // Every beat is a whole doubleword, so the offset
                            // within one is zero for all of them.
                            aoff       <= 3'b000;
                            bus_be     <= 8'hFF;
                            bus_addr   <= (mem_size == SZ_ILINE)
                                            ? {mem_address[31:5], 5'b00000}
                                            : {mem_address[31:4], 4'b0000};
                            fill_beat  <= 2'd0;
                            fill_last  <= (mem_size == SZ_ILINE) ? 2'd3 : 2'd1;
                            bus_burst  <= (mem_size == SZ_ILINE) ? 3'd4 : 3'd2;
                            // Safe to raise here: no device answers in the
                            // cycle it is asked, so the first beat cannot
                            // arrive before this has been taken and dropped.
                            fill_grant <= 1'b1;
                            state      <= S_FILL;
                        end else begin
                            aoff      <= mem_address[2:0];
                            bus_addr  <= {mem_address[31:3], 3'b000};
                            bus_burst <= 3'd1;
                            bus_wdata <= bswap64(wdata_le);
                            // be[7-L] guards bus_wdata[63-8L -: 8], which
                            // carries lane L, so the mask reverses with it.
                            for (int L = 0; L < 8; L++) bus_be[7-L] <= wmask_le[L];
                            state     <= S_BUSY;
                        end
                    end

                S_BUSY:
                    if (bus_ack) begin
                        // Data must be valid in the same cycle mem_done goes
                        // high: cpu.vhd latches mem_dataRead into
                        // mem_finished_dataRead on that very edge.
                        mem_dataRead <= bswap64(bus_rdata) >> {aoff, 3'b000};
                        mem_done     <= 1'b1;
                        state        <= S_IDLE;
                    end

                S_FILL:
                    if (bus_ack) begin
                        fill_data       <= bswap64(bus_rdata);
                        fill_data_ready <= 1'b1;
                        // The cache takes the line from fill_data; nothing
                        // reads mem_dataRead for a fill. Driven anyway so a
                        // trace of the last beat is not stale data.
                        mem_dataRead    <= bswap64(bus_rdata);
                        if (fill_beat == fill_last) begin
                            // One clock of daylight before mem_done; see the
                            // ordering note at the top of this file.
                            state     <= S_FILLEND;
                        end else begin
                            fill_beat <= fill_beat + 2'd1;
                            // The address tracks the word in flight whether
                            // it is streaming or not, so a re-issue starts
                            // where the responder stopped and a bus trace
                            // shows every word at its own address.
                            bus_addr  <= bus_addr + 32'd8;
                            if (bus_last) begin
                                // The responder stopped short of the line:
                                // ask for what is left, one request for all
                                // of it, and let it decide again.
                                bus_req   <= 1'b1;
                                bus_burst <= 3'(fill_last - fill_beat);
                            end
                        end
                    end

                S_FILLEND: begin
                    mem_done <= 1'b1;
                    state    <= S_IDLE;
                end
            endcase
        end
    end

endmodule
