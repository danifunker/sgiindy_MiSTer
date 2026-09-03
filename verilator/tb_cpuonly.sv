//============================================================================
//  tb_cpuonly.sv - the CPU, its bus adapter, and a memory whose latency you
//  choose. Nothing else.
//
//  WHY THIS EXISTS AND WHY IT IS NOT `cputest`. The full harness pulls in the
//  whole chipset, and `rtl/scsi/scsi.v` in it is what Verilator 5.020 dies on
//  (V3Gate.cpp:693). That takes the only simulator available on some of the
//  machines this is developed on off the table for every CPU question. This
//  top is CPU + r4300_bus + RAM, which builds where the full one does not.
//
//  THE MEMORY'S LATENCY IS A RUNTIME INPUT, and that is the whole point. On
//  hardware the CPU's memory answers after a number of clocks that nobody
//  controls: DDR3 refresh, the HPS's own traffic, and Newport's frame buffer
//  reads all move it around. A fault that appears on about one boot in three
//  and always in the same instruction is what a latency-sensitive handshake
//  looks like, so this lets a test sweep the latency instead of hoping to hit
//  the bad one. `lat` is the number of idle clocks between the request being
//  taken and `bus_ack`; 0 means answer on the next clock.
//
//  The memory is flat, 1 MB, and aliases every address into it - `addr[19:3]`
//  indexes it. A CPU-level test cares which bytes come back from an address,
//  not where that address lives in the machine's map.
//============================================================================

module tb_cpuonly
(
    input  logic        clk,
    input  logic        reset,
    input  logic [31:0] boot_pc,
    input  logic        icache_en,
    input  logic        dcache_en,
    input  logic  [4:0] irq_lines,
    input  logic  [7:0] lat,
    // Whether the memory streams a line fill (one request, N words, `last`
    // on the final one) or answers every request with one word and lets
    // r4300_bus fetch the rest one at a time. Both are legitimate responders
    // on the SGI bus - main memory is the first kind, the PROM the second -
    // so every case runs both ways and must agree.
    input  logic        burst_en,

    output logic  [5:0] cpu_error,
    // Requests taken and words acknowledged. With bursts on and a cache on,
    // the second outruns the first; that is how the C++ side knows a burst
    // actually happened rather than being quietly answered word by word.
    output logic [31:0] n_req_o,
    output logic [31:0] n_ack_o,
    // Exposed so a test can watch the bus rather than infer it from results.
    output logic        bus_req_o,
    output logic        bus_we_o,
    output logic [31:0] bus_addr_o,
    output logic [63:0] bus_rdata_o,
    output logic        bus_ack_o
);

    logic        mem_request, mem_rnw, mem_req64, mem_done;
    logic [31:0] mem_address;
    logic  [7:0] mem_writeMask;
    logic [63:0] mem_dataWrite, mem_dataRead;
    logic  [2:0] mem_size;
    logic        fill_grant, fill_data_ready;
    logic [63:0] fill_data;

    r4300_wrap u_cpu (
        .clk              (clk),
        .ce               (1'b1),
        .reset            (reset),
        .boot_pc          (boot_pc),
        .INSTRCACHEON     (icache_en),
        .DATACACHEON      (dcache_en),
        .irq_lines        (irq_lines),
        .error_instr      (cpu_error[0]),
        .error_stall      (cpu_error[1]),
        .error_FPU        (cpu_error[2]),
        .error_exception  (cpu_error[3]),
        .error_fifo       (cpu_error[4]),
        .error_TLB        (cpu_error[5]),
        .mem_request      (mem_request),
        .mem_rnw          (mem_rnw),
        .mem_address      (mem_address),
        .mem_req64        (mem_req64),
        .mem_size         (mem_size),
        .mem_writeMask    (mem_writeMask),
        .mem_dataWrite    (mem_dataWrite),
        .mem_dataRead     (mem_dataRead),
        .mem_done         (mem_done),
        .fill_grant       (fill_grant),
        .fill_data        (fill_data),
        .fill_data_ready  (fill_data_ready)
    );

    logic        bus_req, bus_we, bus_ack, bus_last;
    logic [31:0] bus_addr;
    logic [63:0] bus_wdata, bus_rdata;
    logic  [7:0] bus_be;
    logic  [2:0] bus_aoff, bus_burst;

    r4300_bus u_bus (
        .clk             (clk),
        .reset           (reset),
        .mem_request     (mem_request),
        .mem_rnw         (mem_rnw),
        .mem_address     (mem_address),
        .mem_req64       (mem_req64),
        .mem_size        (mem_size),
        .mem_writeMask   (mem_writeMask),
        .mem_dataWrite   (mem_dataWrite),
        .mem_dataRead    (mem_dataRead),
        .mem_done        (mem_done),
        .fill_grant      (fill_grant),
        .fill_data       (fill_data),
        .fill_data_ready (fill_data_ready),
        .bus_req         (bus_req),
        .bus_we          (bus_we),
        .bus_addr        (bus_addr),
        .bus_wdata       (bus_wdata),
        .bus_be          (bus_be),
        .bus_aoff        (bus_aoff),
        .bus_burst       (bus_burst),
        .bus_rdata       (bus_rdata),
        .bus_ack         (bus_ack),
        .bus_last        (bus_last)
    );

    assign bus_req_o   = bus_req;
    assign bus_we_o    = bus_we;
    assign bus_addr_o  = bus_addr;
    assign bus_rdata_o = bus_rdata;
    assign bus_ack_o   = bus_ack;

    // ---- the memory ---------------------------------------------------
    // Byte order is the core's: mem[n][63-8*i -: 8] is the byte at
    // (n*8 + i), and be[7-i] guards it. C++ loads it the same way, so a
    // dump reads like the address space rather than like a byte swap.
    localparam int WORDS = 1 << 17;          // 1 MB
    logic [63:0] mem [0:WORDS-1] /* verilator public_flat_rw */;

    // A request is taken on the cycle bus_req is high - it is a one-clock
    // pulse from r4300_bus and holding is not part of that contract - then
    // answered `lat` idle clocks later.
    logic        busy;
    logic [31:0] held_addr;
    logic  [7:0] cnt;
    logic  [2:0] left;       // words still owed after the one being answered
    logic [31:0] n_req, n_ack;
    assign n_req_o = n_req;
    assign n_ack_o = n_ack;

    always_ff @(posedge clk) begin
        if (reset) begin
            busy     <= 1'b0;
            bus_ack  <= 1'b0;
            bus_last <= 1'b1;
            left     <= 3'd0;
            n_req    <= 32'd0;
            n_ack    <= 32'd0;
        end else begin
            bus_ack  <= 1'b0;
            bus_last <= 1'b1;
            if (!busy) begin
                if (bus_req) begin
                    n_req     <= n_req + 32'd1;
                    held_addr <= bus_addr;
                    cnt       <= lat;
                    busy      <= 1'b1;
                    left      <= (burst_en && !bus_we && bus_burst > 3'd1)
                                 ? bus_burst - 3'd1 : 3'd0;
                    if (bus_we) begin
                        for (int i = 0; i < 8; i++)
                            if (bus_be[7-i])
                                mem[bus_addr[19:3]][63-8*i -: 8] <= bus_wdata[63-8*i -: 8];
                    end
                end
            end else if (cnt != 0) begin
                cnt <= cnt - 8'd1;
            end else begin
                // The first word after `lat` idle clocks, the rest of a
                // burst on the clocks straight after it, as DDR3 streams.
                bus_rdata <= mem[held_addr[19:3]];
                bus_ack   <= 1'b1;
                n_ack     <= n_ack + 32'd1;
                if (left != 3'd0) begin
                    bus_last  <= 1'b0;
                    left      <= left - 3'd1;
                    held_addr <= held_addr + 32'd8;
                end else begin
                    busy      <= 1'b0;
                end
            end
        end
    end

endmodule
