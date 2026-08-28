//============================================================================
//  sgi_memmap - where main memory appears, as MEMCFG0/1 say it does.
//
//  On an IP22/IP24 the DRAM banks are not at a fixed address. The MC compares
//  address bits [29:22] against a per-bank base field and answers only if that
//  bank is marked valid, and the PROM uses that to SIZE the memory: `szmem`
//  maps a bank at high memory, writes a pattern at one offset, and looks for
//  it reappearing at another. Where it reappears is the real SIMM size. A core
//  with RAM hardwired at 0x08000000 fails every one of those probes and the
//  PROM concludes there is no usable memory - which is exactly what this core
//  did before this module existed.
//
//  MEMCFG ENCODING, from the MC spec's section 5.12. Each register holds two
//  banks, high half first:
//
//     [15]    undefined            [14] BNK   two subbanks on the SIMM
//     [13]    VLD  bank installed  [12:8] MSIZE  SIMM size code
//     [7:0]   BASE address bits [29:22]
//
//  MSIZE is "megabytes minus one" per SIMM and there are always four SIMMs to
//  a bank, so the bank spans (MSIZE + 1) * 4 MB. A two-subbank SIMM (the 512Kx36,
//  2Mx36 and 8Mx36 parts) has BNK set and each subbank is placed separately,
//  so the window at BASE is half the bank.
//
//  SUBBANKS ARE NOT MODELLED. This core carries one contiguous block of RAM
//  and presents it as a single-subbank bank - four SIMMs of 1Mx36, 4Mx36 or
//  the like, which is a configuration a real Indy shipped in. The sizes that
//  need BNK set (8, 32 and 128 MB banks) are not offered, so the wrap below is
//  always "wrap at the installed size" and never has to place two subbanks at
//  different addresses. IRIS's memcfg_bank_info carries the general case if it
//  is ever needed.
//
//  READS OUTSIDE A VALID BANK RETURN ZERO, and writes are dropped. That is
//  IRIS's behaviour and the PROM depends on it: the probe at 0xBFC016EC zeroes
//  four words and then requires them to read back zero after writing a pattern
//  somewhere else, so unmapped memory answering 0xFFFFFFFF fails the data test
//  before the size test even starts. The MC spec would instead raise ADDR in
//  CPU_ERROR_STAT ("address does not map to a valid bank of memory"); nothing
//  yet turns that into a bus error, so returning zero is both simpler and what
//  the working emulator does.
//============================================================================

module sgi_memmap #(
    // Installed size of each bank in megabytes, 0 for an empty bank. Must be
    // a multiple of 4 and at most 128, and must be one of the single-subbank
    // sizes - see the note above.
    parameter int BANK0_MB = 64,
    parameter int BANK1_MB = 0,
    parameter int BANK2_MB = 0,
    parameter int BANK3_MB = 0
)(
    input  logic [31:0] memcfg0,      // banks 0 (high half) and 1 (low half)
    input  logic [31:0] memcfg1,      // banks 2 and 3

    input  logic [31:0] addr,         // physical address
    output logic        hit,          // inside a valid bank
    output logic [31:0] offset        // byte offset into this core's RAM
);

    localparam int unsigned BANK_MB [4] = '{BANK0_MB, BANK1_MB, BANK2_MB, BANK3_MB};
    // Where each bank starts inside the one block of RAM the core actually has.
    localparam int unsigned BANK_OFF [4] = '{
        0,
        BANK0_MB * 1024 * 1024,
        (BANK0_MB + BANK1_MB) * 1024 * 1024,
        (BANK0_MB + BANK1_MB + BANK2_MB) * 1024 * 1024
    };

    logic [15:0] half [4];
    assign half[0] = memcfg0[31:16];
    assign half[1] = memcfg0[15:0];
    assign half[2] = memcfg1[31:16];
    assign half[3] = memcfg1[15:0];

    // Per-bank decode, as plain combinational logic rather than variables
    // declared inside the loop below: this file is compiled by Quartus as well
    // as Verilator, and block-scoped `automatic` declarations are the kind of
    // construct that works everywhere except the one tool you need.
    logic        vld   [4];
    logic [31:0] base  [4];
    logic [31:0] limit [4];
    logic [31:0] amask [4];
    logic        bhit  [4];

    for (genvar b = 0; b < 4; b++) begin : g_bank
        // (MSIZE + 1) * 4 MB, halved when the SIMM carries two subbanks.
        wire [31:0] conf = ({27'b0, half[b][12:8]} + 32'd1) << 22;
        assign vld[b]   = half[b][13] && (BANK_MB[b] != 0);
        assign base[b]  = {2'b00, half[b][7:0], 22'b0};
        assign limit[b] = half[b][14] ? (conf >> 1) : conf;
        // The installed SIMMs wrap within their own size, which is how the
        // PROM's alias probe measures them: configure the bank larger than it
        // is and the pattern written high reappears low.
        assign amask[b] = (BANK_MB[b] * 32'd1048576) - 32'd1;
        assign bhit[b]  = vld[b] && (addr >= base[b]) && ((addr - base[b]) < limit[b]);
    end

    always_comb begin
        hit    = 1'b0;
        offset = 32'h0;
        // Lowest-numbered valid bank wins if two overlap. The PROM never
        // programs an overlap; a real MC would answer with whichever bank's
        // comparator matched and is not specified for the ambiguous case.
        for (int b = 3; b >= 0; b--) begin
            if (bhit[b]) begin
                hit    = 1'b1;
                offset = BANK_OFF[b] + ((addr - base[b]) & amask[b]);
            end
        end
    end

endmodule
