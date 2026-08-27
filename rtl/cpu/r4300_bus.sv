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
//  KNOWN GAP - the unaligned load family with caches off. cpu.vhd aligns the
//  address it gives the *cache* for LWL/LWR/LDL/LDR (EXECacheAddr at
//  cpu.vhd:2329-2331 forces bits 2:0 to 0 or to addr[2]&"00"), but the
//  address it puts on mem_* is the raw unaligned one. Those loads then want
//  the whole aligned word in lanes[3:0] while the shift rule delivers bytes
//  starting at the unaligned address. Upstream never hits this because N64
//  software does not do unaligned loads from uncached space. The cpu-tests
//  `mem` group exercises exactly this, at every offset, so the tests are the
//  place to settle it rather than guesswork here - see docs/09-cpu-validation.md.
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
    input  logic  [7:0] mem_writeMask,
    input  logic [63:0] mem_dataWrite,
    output logic [63:0] mem_dataRead,
    output logic        mem_done,

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
    input  logic [63:0] bus_rdata,
    input  logic        bus_ack
);

    // Byte-reverse: little-endian lanes <-> big-endian bus.
    function automatic logic [63:0] bswap64(input logic [63:0] v);
        for (int i = 0; i < 8; i++) bswap64[8*i +: 8] = v[8*(7-i) +: 8];
    endfunction

    typedef enum logic [1:0] { S_IDLE, S_BUSY } state_t;
    state_t state;

    logic [2:0] aoff;     // byte offset of the request within its doubleword
    assign bus_aoff = aoff;

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
            state    <= S_IDLE;
            bus_req  <= 1'b0;
            mem_done <= 1'b0;
        end else begin
            mem_done <= 1'b0;
            bus_req  <= 1'b0;

            case (state)
                S_IDLE:
                    if (mem_request) begin
                        aoff      <= mem_address[2:0];
                        bus_req   <= 1'b1;
                        bus_we    <= ~mem_rnw;
                        bus_addr  <= {mem_address[31:3], 3'b000};
                        bus_wdata <= bswap64(wdata_le);
                        // be[7-L] guards bus_wdata[63-8L -: 8], which carries
                        // lane L, so the mask reverses along with the data.
                        for (int L = 0; L < 8; L++) bus_be[7-L] <= wmask_le[L];
                        state     <= S_BUSY;
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
            endcase
        end
    end

endmodule
