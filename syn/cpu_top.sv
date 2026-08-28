//============================================================================
//  cpu_top - the R4300i on its own, for a timing number. NOT the MiSTer core.
//
//  WHY THIS EXISTS SEPARATELY FROM syn_top. The whole design does not fit:
//  the fitter wants 7,598 LABs and a 5CSEBA6U23I7 has 4,191, so it never
//  places, and a design that never places has no Fmax. That leaves the second
//  question syn/README.md asks - "and at what clock?" - unanswerable from the
//  full harness until the logic comes down.
//
//  The CPU on its own is about 22.8k ALUTs and does fit, so it can be placed
//  and timed on the real device. That is also the one number with something to
//  compare against: the MiSTer N64 core runs this same R4300i at 93.75 MHz, so
//  what this closes at says whether the CPU or the SGI chipset is the problem.
//
//  WHAT THIS NUMBER IS NOT. It is the CPU in isolation, with its memory port
//  hanging off an LFSR instead of r4300_bus and the chipset. The real core's
//  Fmax can only be lower - it adds paths into and out of this block, and the
//  critical path may well end up somewhere else entirely. Read it as an upper
//  bound on the CPU, not as the core's clock.
//
//  The LFSR and the output XOR are here for the same reason as in syn_top.sv:
//  constant inputs and unread outputs optimise away, and the report then says
//  the design is free.
//============================================================================

module cpu_top (
    input  logic       CLK_50,
    input  logic       RESET_N,
    input  logic       SEED,
    output logic       OUT_BIT,
    output logic       LOCKED
);

    logic reset = 1'b1;
    always_ff @(posedge CLK_50) reset <= ~RESET_N;

    logic [63:0] lfsr = 64'h1;
    always_ff @(posedge CLK_50)
        lfsr <= {lfsr[62:0], lfsr[63] ^ lfsr[62] ^ lfsr[60] ^ lfsr[59] ^ SEED};

    logic        error_instr, error_stall, error_FPU;
    logic        error_exception, error_fifo, error_TLB;
    logic        mem_request, mem_rnw, mem_req64;
    logic [31:0] mem_address;
    logic  [2:0] mem_size;
    logic  [7:0] mem_writeMask;
    logic [63:0] mem_dataWrite;

    r4300_wrap u_cpu (
        .clk             (CLK_50),
        .ce              (lfsr[0]),
        .reset           (reset),
        .boot_pc         ({lfsr[31:1], 1'b0}),
        .INSTRCACHEON    (lfsr[1]),
        .DATACACHEON     (lfsr[2]),
        .irq_lines       (lfsr[7:3]),

        .error_instr     (error_instr),
        .error_stall     (error_stall),
        .error_FPU       (error_FPU),
        .error_exception (error_exception),
        .error_fifo      (error_fifo),
        .error_TLB       (error_TLB),

        .mem_request     (mem_request),
        .mem_rnw         (mem_rnw),
        .mem_address     (mem_address),
        .mem_req64       (mem_req64),
        .mem_size        (mem_size),
        .mem_writeMask   (mem_writeMask),
        .mem_dataWrite   (mem_dataWrite),
        .mem_dataRead    (lfsr),
        .mem_done        (lfsr[8]),

        .fill_grant      (lfsr[9]),
        .fill_data       (~lfsr),
        .fill_data_ready (lfsr[10])
    );

    always_ff @(posedge CLK_50)
        OUT_BIT <= ^{error_instr, error_stall, error_FPU, error_exception,
                     error_fifo, error_TLB,
                     mem_request, mem_rnw, mem_address, mem_req64, mem_size,
                     mem_writeMask, mem_dataWrite};

    assign LOCKED = ~reset;

endmodule
