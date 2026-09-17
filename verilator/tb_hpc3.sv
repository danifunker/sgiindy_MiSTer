//============================================================================
//  tb_hpc3 -- sgi_hpc3's register file against a shadow copy of what the HPC3
//  spec's address map says each access does.  `make -C verilator tb_hpc3`.
//
//  The shadow here is written from the map, not from the module: a register
//  key per block (descriptor pair, control group, gen, cfgdma, cfgpio), the
//  byte-enable merge for a partial write, and the rule that a doubleword
//  access covers TWO registers - +0 in the high half of the bus and +4 in the
//  low half. CFGDMA and CFGPIO are the awkward pair: their stride puts one
//  register in both halves of a doubleword, so a 64-bit write lands twice and
//  the +4 half wins, merged against the value before either.
//
//  What it does not model: SCSI channel 0's registers (hpc3_scsi_dma owns
//  them, and reading its control port clears an interrupt), HAL2's file, and
//  the two generated halves of gen.intstat - those accesses are driven anyway,
//  to check they neither disturb the storage nor stop acknowledging, and only
//  their read data is left unchecked.
//
//  ACK LATENCY IS NOT CHECKED, deliberately: the bench waits for `ack` for as
//  long as `ACK_LIMIT` clocks and the CPU's bus does the same (r4300_bus holds
//  its request in S_BUSY until the answer comes). That is what lets the same
//  bench, with the same stimulus, run against a version whose storage is
//  flip-flops and one whose storage is an M10K a clock further away.
//
//    T1  every storage register written and read back, one 32-bit word at a time
//    T2  64-bit writes covering both registers of a pair
//    T3  partial byte writes merged against the current value
//    T4  reset clears the storage, and writes after it stick
//    T5  SCSI channel 0, HAL2 and the write-only ports interleaved with storage
//    T6  addresses the block does not claim: no ack, claimed low
//    T7  20,000 random accesses of every shape above
//============================================================================
`timescale 1ns/1ps
module tb_hpc3;

localparam int ACK_LIMIT = 64;

reg clk = 0;
always #5 clk = ~clk;

reg          reset = 1;
reg          sel = 0, we = 0;
reg [18:0]   addr = 0;
reg  [2:0]   aoff = 0;
reg  [7:0]   be = 8'hFF;
reg [63:0]   wdata = 0;
wire [63:0]  rdata;
wire         ack, claimed;

sgi_hpc3 dut (
    .clk (clk), .reset (reset),
    .sel (sel), .we (we), .addr (addr), .aoff (aoff), .be (be),
    .wdata (wdata), .rdata (rdata), .ack (ack), .claimed (claimed),
    // the SCSI channel's master port and device side: idle throughout
    .dma_req (), .dma_we (), .dma_addr (), .dma_wdata (), .dma_be (),
    .dma_rdata (64'd0), .dma_ack (1'b0),
    .scsi_dev_req (1'b0), .scsi_dev_dir_in (1'b0), .scsi_dev_wdata (8'd0),
    .scsi_dev_eop (1'b0), .scsi_dev_ack (), .scsi_dev_rdata (), .scsi_dev_reset (),
    .scsi_dma_irq (), .dbg_scsi0_dma ()
);

// ---- the map, as the spec gives it ----------------------------------------
localparam logic [18:0] DMA_END     = 19'h20000;
localparam logic [18:0] GEN_BASE    = 19'h30000, GEN_END    = 19'h30020;
localparam logic [18:0] HAL2_BASE   = 19'h58000, HAL2_END   = 19'h58400;
localparam logic [18:0] CFGDMA_BASE = 19'h5C000, CFGDMA_END = 19'h5D000;
localparam logic [18:0] CFGPIO_BASE = 19'h5D000, CFGPIO_END = 19'h5E000;
localparam logic [18:0] WRONLY_BASE = 19'h5E000, WRONLY_END = 19'h60000;

localparam int B_NONE = 0, B_DESC = 1, B_CTRL = 2, B_GEN = 3,
               B_CFGDMA = 4, B_CFGPIO = 5, B_HAL2 = 6, B_WRONLY = 7;

function automatic int blk_of(input logic [18:0] a);
    if (a < DMA_END)
        blk_of = a[12] ? B_CTRL : ((a[11:3] == 9'h000) ? B_DESC : B_NONE);
    else if (a >= GEN_BASE    && a < GEN_END)    blk_of = B_GEN;
    else if (a >= HAL2_BASE   && a < HAL2_END)   blk_of = B_HAL2;
    else if (a >= CFGDMA_BASE && a < CFGDMA_END) blk_of = B_CFGDMA;
    else if (a >= CFGPIO_BASE && a < CFGPIO_END) blk_of = B_CFGPIO;
    else if (a >= WRONLY_BASE && a < WRONLY_END) blk_of = B_WRONLY;
    else                                         blk_of = B_NONE;
endfunction

// The shadow's key for the register a doubleword's half w addresses. One flat
// space, wide enough that no two blocks share a key.
function automatic int key_of(input logic [18:0] a, input int blk, input bit w);
    case (blk)
        B_DESC:   key_of = 32'h000 + {a[16:13], w};             // {sub, word}
        B_CTRL:   key_of = 32'h100 + {a[16:13], a[4:3], w};     // {sub, register}
        B_GEN:    key_of = 32'h200 + {a[4:3], w};
        B_CFGDMA: key_of = 32'h300 + a[11:9];                   // one register in both halves
        B_CFGPIO: key_of = 32'h400 + a[11:8];                   // ditto
        default:  key_of = -1;
    endcase
endfunction

// SCSI channel 0 is sub-block 8 of the DMA space: hpc3_scsi_dma answers for it.
function automatic bit scsi0(input logic [18:0] a, input int blk);
    scsi0 = (blk == B_DESC || blk == B_CTRL) && (a[16:13] == 4'd8);
endfunction

// Is the half's read data something this bench can predict?
function automatic bit known(input logic [18:0] a, input int blk, input bit w);
    if (blk == B_HAL2 || scsi0(a, blk)) known = 0;
    else if (blk == B_GEN && ({a[4:3], w} == 3'd0 || {a[4:3], w} == 3'd3))
        known = 0;                                   // the two halves of intstat
    else known = 1;
endfunction

logic [31:0] sh [0:2047];
int errors = 0, checks = 0;

function automatic logic [31:0] sh_read(input logic [18:0] a, input int blk, input bit w);
    int k;
    k = key_of(a, blk, w);
    sh_read = (k < 0) ? 32'h0 : sh[k];
endfunction

// be[7-4w-b] guards byte b of the register in half w; byte 0 is the register's
// most significant.
function automatic logic [31:0] merge(input logic [31:0] cur, input logic [63:0] wd,
                                      input logic [7:0] ben, input bit w);
    logic [31:0] v;
    v = cur;
    for (int b = 0; b < 4; b++)
        if (ben[7 - 4*int'(w) - b]) v[24 - 8*b +: 8] = wd[56 - 32*int'(w) - 8*b +: 8];
    merge = v;
endfunction

// ---- driving one access ---------------------------------------------------
logic [63:0] last_rdata;
bit          last_ack, last_claimed;

task automatic access(input bit we_i, input logic [18:0] a, input logic [2:0] aoff_i,
                      input logic [7:0] ben, input logic [63:0] wd);
    int waited;
    @(negedge clk);
    sel = 1'b1; we = we_i; addr = a; aoff = aoff_i; be = ben; wdata = wd;
    @(negedge clk);
    last_claimed = claimed;                       // combinational, valid with sel
    sel = 1'b0;
    last_ack = 1'b0;
    waited = 0;
    while (!last_ack && waited < ACK_LIMIT) begin
        @(posedge clk);
        if (ack) begin last_ack = 1'b1; last_rdata = rdata; end
        waited++;
    end
    @(negedge clk);
    we = 1'b0;
endtask

// One access against the shadow: check the read data, then apply the write.
task automatic go(input bit we_i, input logic [18:0] a, input logic [2:0] aoff_i,
                  input logic [7:0] ben, input logic [63:0] wd);
    int blk;
    bit wr0, wr1;
    logic [31:0] cur0, cur1, new0, new1;
    blk = blk_of(a);
    cur0 = sh_read(a, blk, 1'b0);
    cur1 = sh_read(a, blk, 1'b1);
    access(we_i, a, aoff_i, ben, wd);

    if (blk == B_NONE) begin
        if (last_claimed || last_ack) begin
            errors++;
            $display("FAIL %05x: unclaimed address answered (claimed=%b ack=%b)", a, last_claimed, last_ack);
        end
        return;
    end
    if (!last_claimed || !last_ack) begin
        errors++;
        $display("FAIL %05x: claimed=%b ack=%b (no answer in %0d clocks)", a, last_claimed, last_ack, ACK_LIMIT);
        return;
    end
    // read data: the halves this bench can predict
    if (known(a, blk, 1'b0)) begin
        checks++;
        if (last_rdata[63:32] !== cur0) begin
            errors++;
            $display("FAIL %05x half 0: read %08x, shadow %08x", a, last_rdata[63:32], cur0);
        end
    end
    if (known(a, blk, 1'b1)) begin
        checks++;
        if (last_rdata[31:0] !== cur1) begin
            errors++;
            $display("FAIL %05x half 1: read %08x, shadow %08x", a, last_rdata[31:0], cur1);
        end
    end
    // the write, exactly as the module's two write ports take it
    if (!we_i) return;
    wr0 = |ben[7:4];
    wr1 = |ben[3:0];
    new0 = merge(cur0, wd, ben, 1'b0);
    new1 = merge(cur1, wd, ben, 1'b1);
    if (blk == B_HAL2 || blk == B_WRONLY || scsi0(a, blk)) return;   // not storage here
    if (wr0) sh[key_of(a, blk, 1'b0)] = new0;
    if (wr1) sh[key_of(a, blk, 1'b1)] = new1;     // cfgdma/cfgpio: same key, this one wins
endtask

task automatic do_reset();
    @(negedge clk);
    reset = 1'b1;
    repeat (4) @(negedge clk);
    reset = 1'b0;
    // The storage is cleared; give a version that sweeps it room to finish
    // before the next access (the bench's accesses wait for ack anyway).
    repeat (300) @(negedge clk);
    for (int k = 0; k < 2048; k++) sh[k] = 32'h0;
endtask

// ---- an address of each kind ----------------------------------------------
logic [7:0] be_kinds [0:5];
initial begin be_kinds[0] = 8'hFF; be_kinds[1] = 8'hF0; be_kinds[2] = 8'h0F;
              be_kinds[3] = 8'h80; be_kinds[4] = 8'h01; be_kinds[5] = 8'h3C; end

// A function call cannot be bit-selected here (the simulator reads `//` plus
// its own name as a directive, so this sentence starts elsewhere) - neither
// this tool nor Quartus takes `f(x)[3:0]`, so every random field lands in a
// variable first.
function automatic logic [18:0] rnd_addr(input int kind);
    logic [18:0] a;
    logic  [3:0] sub, c4;
    logic  [1:0] reg2;
    logic  [2:0] c3;
    logic  [5:0] h6;
    logic  [7:0] w8;
    logic  [8:0] hole;
    sub  = $urandom_range(0, 15);
    c4   = $urandom_range(0, 15);
    reg2 = $urandom_range(0, 3);
    c3   = $urandom_range(0, 7);
    h6   = $urandom_range(0, 63);
    w8   = $urandom_range(0, 255);
    hole = $urandom_range(1, 511);
    case (kind)
        0: a = {3'b000, sub, 1'b0, 12'h000};                        // descriptor pair
        1: a = {3'b000, sub, 1'b1, 7'h00, reg2, 3'b000};            // control group
        2: a = GEN_BASE + {reg2, 3'b000};
        3: a = HAL2_BASE + {h6, 3'b000};
        4: a = CFGDMA_BASE + {c3, 9'h000};
        5: a = CFGPIO_BASE + {c4, 8'h00};
        6: a = WRONLY_BASE + {w8, 3'b000};
        7: a = {3'b000, sub, 1'b0, hole, 3'b000};                   // unclaimed hole
        default: a = 19'h70000;                                     // past everything
    endcase
    rnd_addr = a;
endfunction

function automatic bit rnd_bit();
    logic [1:0] v;
    v = $urandom_range(0, 1);
    rnd_bit = v[0];
endfunction

function automatic logic [7:0] rnd_be();
    logic [2:0] k;
    k = $urandom_range(0, 5);
    rnd_be = be_kinds[k];
endfunction

// A write to SCSI channel 0's control register must not start the channel or
// flush it: both take the engine away on its own clock and neither model would
// then be answering the same question. Everything else about it is fair game.
function automatic logic [63:0] safe_wd(input logic [18:0] a, input logic [63:0] wd);
    safe_wd = wd;
    if ((a[18:13] == {2'b00, 4'd8}) && a[12] && (a[4:3] == 2'b00))
        safe_wd[31:0] = wd[31:0] & ~32'h0000_0018;
endfunction

// ---- the tests ------------------------------------------------------------
logic [18:0] a;
logic [63:0] wd;
logic [7:0]  ben;
int kind;

initial begin
    for (int k = 0; k < 2048; k++) sh[k] = 32'h0;
    do_reset();

    // T1: every storage register, one 32-bit word at a time, then read back
    for (int sub = 0; sub < 16; sub++) begin
        go(1'b1, {3'b000, sub[3:0], 1'b0, 12'h000}, 3'd0, 8'hF0, {32'h1000_0000 + sub, 32'h0});
        go(1'b1, {3'b000, sub[3:0], 1'b0, 12'h000}, 3'd4, 8'h0F, {32'h0, 32'h2000_0000 + sub});
        for (int r = 0; r < 4; r++) begin
            go(1'b1, {3'b000, sub[3:0], 1'b1, 7'h00, r[1:0], 3'b000}, 3'd0, 8'hF0,
               {32'h3000_0000 + sub*16 + r, 32'h0});
            go(1'b1, {3'b000, sub[3:0], 1'b1, 7'h00, r[1:0], 3'b000}, 3'd4, 8'h0F,
               {32'h0, 32'h4000_0000 + sub*16 + r});
        end
    end
    for (int g = 0; g < 4; g++) begin
        go(1'b1, GEN_BASE + {g[1:0], 3'b000}, 3'd0, 8'hF0, {32'h5000_0000 + g, 32'h0});
        go(1'b1, GEN_BASE + {g[1:0], 3'b000}, 3'd4, 8'h0F, {32'h0, 32'h6000_0000 + g});
    end
    for (int c = 0; c < 8; c++)
        go(1'b1, CFGDMA_BASE + {c[2:0], 9'h000}, 3'd0, 8'hF0, {32'h7000_0000 + c, 32'h0});
    for (int c = 0; c < 16; c++)
        go(1'b1, CFGPIO_BASE + {c[3:0], 8'h00}, 3'd0, 8'hF0, {32'h8000_0000 + c, 32'h0});
    // read everything back
    for (int sub = 0; sub < 16; sub++) begin
        go(1'b0, {3'b000, sub[3:0], 1'b0, 12'h000}, 3'd0, 8'h00, 64'h0);
        for (int r = 0; r < 4; r++)
            go(1'b0, {3'b000, sub[3:0], 1'b1, 7'h00, r[1:0], 3'b000}, 3'd0, 8'h00, 64'h0);
    end
    for (int g = 0; g < 4; g++) go(1'b0, GEN_BASE + {g[1:0], 3'b000}, 3'd0, 8'h00, 64'h0);
    for (int c = 0; c < 8; c++)  go(1'b0, CFGDMA_BASE + {c[2:0], 9'h000}, 3'd0, 8'h00, 64'h0);
    for (int c = 0; c < 16; c++) go(1'b0, CFGPIO_BASE + {c[3:0], 8'h00}, 3'd0, 8'h00, 64'h0);
    $display("T1 done: %0d checks, %0d errors", checks, errors);

    // T2: 64-bit writes, both registers of a pair at once
    for (int sub = 0; sub < 16; sub++) begin
        go(1'b1, {3'b000, sub[3:0], 1'b0, 12'h000}, 3'd0, 8'hFF, {32'hAAAA_0000 + sub, 32'h5555_0000 + sub});
        go(1'b1, {3'b000, sub[3:0], 1'b1, 7'h00, 2'd1, 3'b000}, 3'd0, 8'hFF, {32'hC0DE_0000 + sub, 32'hBEEF_0000 + sub});
    end
    for (int c = 0; c < 8; c++)
        go(1'b1, CFGDMA_BASE + {c[2:0], 9'h000}, 3'd0, 8'hFF, {32'h1111_1111, 32'h2222_0000 + c});
    for (int sub = 0; sub < 16; sub++) begin
        go(1'b0, {3'b000, sub[3:0], 1'b0, 12'h000}, 3'd0, 8'h00, 64'h0);
        go(1'b0, {3'b000, sub[3:0], 1'b1, 7'h00, 2'd1, 3'b000}, 3'd0, 8'h00, 64'h0);
    end
    for (int c = 0; c < 8; c++) go(1'b0, CFGDMA_BASE + {c[2:0], 9'h000}, 3'd0, 8'h00, 64'h0);
    $display("T2 done: %0d checks, %0d errors", checks, errors);

    // T3: partial byte writes merged against what is there
    for (int i = 0; i < 200; i++) begin
        kind = $urandom_range(0, 5);
        a = rnd_addr(kind == 3 ? 4 : kind);           // storage blocks only
        if (blk_of(a) == B_HAL2 || blk_of(a) == B_WRONLY) a = CFGPIO_BASE;
        ben = rnd_be();
        wd = {$urandom, $urandom};
        go(1'b1, a, 3'd0, ben, safe_wd(a, wd));
        go(1'b0, a, 3'd0, 8'h00, 64'h0);
    end
    $display("T3 done: %0d checks, %0d errors", checks, errors);

    // T4: reset clears the storage; writes after it stick
    go(1'b1, CFGPIO_BASE, 3'd0, 8'hF0, {32'hDEAD_BEEF, 32'h0});
    do_reset();
    for (int c = 0; c < 16; c++) go(1'b0, CFGPIO_BASE + {c[3:0], 8'h00}, 3'd0, 8'h00, 64'h0);
    for (int sub = 0; sub < 16; sub++) go(1'b0, {3'b000, sub[3:0], 1'b0, 12'h000}, 3'd0, 8'h00, 64'h0);
    go(1'b1, CFGPIO_BASE, 3'd0, 8'hF0, {32'h0BAD_F00D, 32'h0});
    go(1'b0, CFGPIO_BASE, 3'd0, 8'h00, 64'h0);
    $display("T4 done: %0d checks, %0d errors", checks, errors);

    // T5: the blocks this bench does not model, interleaved with storage
    for (int i = 0; i < 200; i++) begin
        a = rnd_addr($urandom_range(0, 6));
        wd = {$urandom, $urandom};
        go(rnd_bit(), a, 3'd0, rnd_be(), safe_wd(a, wd));
        go(1'b0, rnd_addr(4), 3'd0, 8'h00, 64'h0);
    end
    $display("T5 done: %0d checks, %0d errors", checks, errors);

    // T6: the holes
    for (int i = 0; i < 40; i++) begin
        a = rnd_addr($urandom_range(7, 8));
        go(rnd_bit(), a, 3'd0, 8'hFF, {$urandom, $urandom});
    end
    $display("T6 done: %0d checks, %0d errors", checks, errors);

    // T7: a random mix of everything
    for (int i = 0; i < 20000; i++) begin
        a = rnd_addr($urandom_range(0, 8));
        wd = {$urandom, $urandom};
        go(rnd_bit(), a, {rnd_bit(), 2'b00}, rnd_be(), safe_wd(a, wd));
        if (i % 4096 == 0) $display("  T7 %0d/20000: %0d checks, %0d errors", i, checks, errors);
    end

    $display("T7 done: %0d checks, %0d errors", checks, errors);
    if (errors == 0) $display("TB_HPC3 PASS (%0d checks)", checks);
    else             $display("TB_HPC3 FAIL (%0d errors in %0d checks)", errors, checks);
    $finish;
end

endmodule
