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
    // No parameters: the size is a runtime input. See bank_mb below.
    parameter int UNUSED_PARAM = 0
)(
    input  logic [31:0] memcfg0,      // banks 0 (high half) and 1 (low half)
    input  logic [31:0] memcfg1,      // banks 2 and 3

    input  logic [31:0] addr,         // physical address
    output logic        hit,          // inside a valid bank
    input  logic [31:0] mem_mb,       // total megabytes actually fitted
    output logic [31:0] offset        // byte offset into this core's RAM
);

    // RUNTIME, not a parameter. The simulator picks the size on the command
    // line and the RTL has to agree with the memory actually behind it: a core
    // elaborated for 64 MB in front of a 32 MB host buffer advertises memory
    // that is not there, and the PROM's own memory test finds out - "Bank 0
    // memory probe *FAILED* ... No usable memory found". On hardware this ties
    // to a constant and folds away.
    //
    // BANKS COME IN 64, 16 AND 4 MB, largest first, and that list is not
    // arbitrary. A bank is four SIMMs, so it spans four times the SIMM size,
    // and the SIMMs that do NOT need BNK - the single-subbank parts - are the
    // 1Mx36, 4Mx36 and 16Mx36, giving 4, 16 and 64 MB banks. The two-subbank
    // parts (512Kx36, 2Mx36, 8Mx36) give 8, 32 and 128 MB banks and are the
    // case the note at the top of this file says is not modelled.
    //
    // So a size is expressible here exactly when it is a sum of 64s, 16s and
    // 4s across at most four banks:
    //
    //     32 MB  = 16 + 16          two banks
    //     48 MB  = 16 + 16 + 16     three banks   (the MiSTer single-SDRAM fit)
    //     64 MB  = 64               one bank
    //    128 MB  = 64 + 64          two banks
    //    256 MB  = 64 x 4           four banks
    //
    // Asking for 32 as a single 32 MB bank is what made `--ram-mb 32` fail
    // before this: it needs BNK, the PROM probed a bank that could not answer,
    // and its own diagnostic said so.
    logic [31:0] bank_mb  [4];
    logic [31:0] bank_off [4];
    logic [31:0] rem_mb   [5];
    logic [31:0] off_by   [5];
    always_comb begin
        rem_mb[0] = mem_mb;
        off_by[0] = 32'd0;
        for (int b = 0; b < 4; b++) begin
            bank_mb[b]  = (rem_mb[b] >= 32'd64) ? 32'd64
                        : (rem_mb[b] >= 32'd16) ? 32'd16
                        : (rem_mb[b] >= 32'd4 ) ? 32'd4
                        :                         32'd0;
            bank_off[b] = off_by[b];
            rem_mb[b+1] = rem_mb[b] - bank_mb[b];
            off_by[b+1] = off_by[b] + (bank_mb[b] << 20);
        end
    end

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
        assign vld[b]   = half[b][13] && (bank_mb[b] != 32'd0);
        assign base[b]  = {2'b00, half[b][7:0], 22'b0};
        assign limit[b] = half[b][14] ? (conf >> 1) : conf;
        // The installed SIMMs wrap within their own size, which is how the
        // PROM's alias probe measures them: configure the bank larger than it
        // is and the pattern written high reappears low.
        assign amask[b] = (bank_mb[b] * 32'd1048576) - 32'd1;
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
                offset = bank_off[b] + ((addr - base[b]) & amask[b]);
            end
        end
    end

endmodule
