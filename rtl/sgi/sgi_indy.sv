//============================================================================
//  sgi_indy - the IP24 core: R4300i + address decode + on-chip devices.
//
//  Board-independent. `sgiindy.sv` wires it to MiSTer's SDRAM/HPS, and the
//  simulation harness wires it to C++ models instead. Main memory and the
//  boot PROM are external ports because on hardware they are external chips.
//
//  BUS CONVENTION (see rtl/cpu/r4300_bus.sv for the CPU-side conversion):
//  addresses are physical byte addresses, always 8-byte aligned; data is
//  big-endian, so `data[63-8*i -: 8]` is the byte at `addr + i` and
//  `be[7-i]` guards it. Every device below sees natural big-endian words:
//  the 32-bit register at `addr+0` is `data[63:32]`, the one at `addr+4` is
//  `data[31:0]`.
//
//  Physical map, as far as it is implemented (docs/02-address-map.md has the
//  full IP22/IP24 map; cpu-tests/docs/memory-map.md explains the low alias):
//
//    0x00000000-0x0007FFFF  512 KB alias of the bottom of main memory
//    0x00080000-0x07FFFFFF  unmapped - reads 0, swallows writes
//    0x08000000-...         main memory (MEM_MB)
//    0x1F400000-0x1F5FFFFF  GIO64 expansion slot 0
//    0x1FBD9800-0x1FBD98FF  IOC2, with the SCC at +0x30..+0x3F
//    0x1FC00000-0x1FC7FFFF  boot PROM
//
//  Anything else answers as an unclaimed bus cycle and raises `bus_unclaimed`
//  for one cycle so the harness can log it. On real hardware an unclaimed
//  GIO cycle times out into a bus error; wiring that to the CPU is an
//  interrupt-era job, not a bring-up one.
//============================================================================

module sgi_indy #(
    parameter int MEM_MB = 64
)(
    input  logic        clk,
    input  logic        ce,
    input  logic        reset,
    // Serial-side clock for the SCC: 3.6864 MHz on a real machine, and the
    // only thing that sets the console's bit rate. The console tap does not
    // depend on it, so simulation is free to run it fast.
    input  logic        sclk,

    // Physical address the CPU starts fetching from. 0xBFC00000 on hardware;
    // the harness points it straight at an ELF entry for bare-metal tests.
    input  logic [31:0] boot_pc,

    // ---- main memory -----------------------------------------------------
    output logic        ram_req,
    output logic        ram_we,
    output logic [31:0] ram_addr,     // offset from the base of RAM
    output logic [63:0] ram_wdata,
    output logic  [7:0] ram_be,
    input  logic [63:0] ram_rdata,
    input  logic        ram_ack,

    // ---- boot PROM (read-only) ------------------------------------------
    output logic        prom_req,
    output logic [31:0] prom_addr,    // offset from the base of the PROM
    input  logic [63:0] prom_rdata,
    input  logic        prom_ack,

    // ---- GIO64 expansion slot 0 -----------------------------------------
    output logic        gio_req,
    output logic        gio_we,
    output logic [31:0] gio_addr,     // offset from the base of the window
    output logic [63:0] gio_wdata,
    output logic  [7:0] gio_be,
    input  logic [63:0] gio_rdata,
    input  logic        gio_ack,
    input  logic        gio_present,  // 0 = empty slot, answer without a device

    // ---- serial console --------------------------------------------------
    input  logic        rxda,        // channel A / tty2 receive
    output logic        txda,
    input  logic        rxdb,        // channel B / tty1 receive - the console
    output logic        txdb,
    output logic        scc_int_n,
    // Byte-level tap on the transmitter, for a harness that would rather read
    // what the machine printed than decode a waveform.
    output logic        tx_valid,
    output logic  [7:0] tx_data,
    output logic        tx_chan,

    // ---- observability ---------------------------------------------------
    output logic        bus_req_o,
    output logic        bus_we_o,
    output logic [31:0] bus_addr_o,
    output logic [63:0] bus_wdata_o,
    output logic  [7:0] bus_be_o,
    output logic [63:0] bus_rdata_o,
    output logic        bus_ack_o,
    output logic        bus_unclaimed,
    output logic  [5:0] cpu_error
);

    localparam logic [31:0] RAM_BASE   = 32'h0800_0000;
    localparam logic [31:0] RAM_SIZE   = MEM_MB * 32'h0010_0000;
    localparam logic [31:0] ALIAS_SIZE = 32'h0008_0000;   // 512 KB
    localparam logic [31:0] GIO0_BASE  = 32'h1F40_0000;
    localparam logic [31:0] GIO0_SIZE  = 32'h0020_0000;
    localparam logic [31:0] IOC_BASE   = 32'h1FBD_9800;
    localparam logic [31:0] IOC_SIZE   = 32'h0000_0100;
    localparam logic [31:0] PROM_BASE  = 32'h1FC0_0000;
    localparam logic [31:0] PROM_SIZE  = 32'h0008_0000;   // 512 KB

    //------------------------------------------------------------------
    // CPU
    //------------------------------------------------------------------
    logic        mem_request, mem_rnw, mem_req64, mem_done;
    logic [31:0] mem_address;
    logic  [7:0] mem_writeMask;
    logic [63:0] mem_dataWrite, mem_dataRead;
    logic  [2:0] mem_size_unused;

    r4300_wrap u_cpu (
        .clk              (clk),
        .ce               (ce),
        .reset            (reset),
        .boot_pc          (boot_pc),

        // Both caches stay off until the fill path has somewhere to fill
        // from: cpu_instrcache/cpu_datacache pull lines straight off the N64's
        // RDRAM/DDR3 port, which is tied off in r4300_wrap.vhd.
        .INSTRCACHEON     (1'b0),
        .DATACACHEON      (1'b0),
        .irqRequest       (1'b0),

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
        .mem_size         (mem_size_unused),
        .mem_writeMask    (mem_writeMask),
        .mem_dataWrite    (mem_dataWrite),
        .mem_dataRead     (mem_dataRead),
        .mem_done         (mem_done)
    );

    logic        bus_req, bus_we, bus_ack;
    logic [31:0] bus_addr;
    logic [63:0] bus_wdata, bus_rdata;
    logic  [7:0] bus_be;
    logic  [2:0] bus_aoff;

    r4300_bus u_bus (
        .clk           (clk),
        .reset         (reset),
        .mem_request   (mem_request),
        .mem_rnw       (mem_rnw),
        .mem_address   (mem_address),
        .mem_req64     (mem_req64),
        .mem_writeMask (mem_writeMask),
        .mem_dataWrite (mem_dataWrite),
        .mem_dataRead  (mem_dataRead),
        .mem_done      (mem_done),
        .bus_req       (bus_req),
        .bus_we        (bus_we),
        .bus_addr      (bus_addr),
        .bus_wdata     (bus_wdata),
        .bus_be        (bus_be),
        .bus_aoff      (bus_aoff),
        .bus_rdata     (bus_rdata),
        .bus_ack       (bus_ack)
    );

    //------------------------------------------------------------------
    // Address decode
    //------------------------------------------------------------------
    logic sel_ram, sel_alias, sel_gio, sel_ioc, sel_prom, sel_none;

    assign sel_alias = (bus_addr < ALIAS_SIZE);
    assign sel_ram   = (bus_addr >= RAM_BASE)  && (bus_addr < RAM_BASE + RAM_SIZE);
    assign sel_gio   = (bus_addr >= GIO0_BASE) && (bus_addr < GIO0_BASE + GIO0_SIZE);
    assign sel_ioc   = (bus_addr >= IOC_BASE)  && (bus_addr < IOC_BASE + IOC_SIZE);
    assign sel_prom  = (bus_addr >= PROM_BASE) && (bus_addr < PROM_BASE + PROM_SIZE);
    assign sel_none  = !(sel_alias | sel_ram | sel_gio | sel_ioc | sel_prom);

    // The bottom 512 KB is the same RAM as the bottom of the real bank, which
    // is where the exception vectors live: KSEG0 0x80000000 and 0x88000000
    // reach the same bytes. Folding it here rather than in the memory model
    // keeps the alias visible in a bus trace.
    assign ram_req   = bus_req && (sel_ram || sel_alias);
    assign ram_we    = bus_we;
    assign ram_addr  = sel_alias ? bus_addr : (bus_addr - RAM_BASE);
    assign ram_wdata = bus_wdata;
    assign ram_be    = bus_be;

    assign prom_req  = bus_req && sel_prom;
    assign prom_addr = bus_addr - PROM_BASE;

    assign gio_req   = bus_req && sel_gio && gio_present;
    assign gio_we    = bus_we;
    assign gio_addr  = bus_addr - GIO0_BASE;
    assign gio_wdata = bus_wdata;
    assign gio_be    = bus_be;

    //------------------------------------------------------------------
    // IOC2 / SCC
    //------------------------------------------------------------------
    // The SCC's four ports sit at IOC +0x30..+0x3F on a stride of 4. A
    // doubleword cycle therefore covers two of them at once, so the enabled
    // byte lanes pick which one is actually being addressed - the CPU never
    // touches both halves in one access.
    logic        scc_sel;
    logic  [1:0] scc_reg;
    logic  [3:0] scc_be;
    logic [31:0] scc_wdata, scc_rdata;
    logic        scc_ack;
    logic        hi_word;     // the access is in the upper word of the pair

    assign scc_sel = bus_req && sel_ioc
                     && (bus_addr[7:0] >= 8'h30) && (bus_addr[7:0] < 8'h40);
    assign hi_word = bus_aoff[2];
    assign scc_reg = {bus_addr[3], hi_word};
    assign scc_be    = hi_word ? bus_be[3:0]         : bus_be[7:4];
    assign scc_wdata = hi_word ? bus_wdata[31:0]     : bus_wdata[63:32];

    sgi_scc u_scc (
        .clk      (clk),
        .reset    (reset),
        .sclk     (sclk),
        .sel      (scc_sel),
        .port     (scc_reg),
        .we       (bus_we),
        .be       (scc_be),
        .wdata    (scc_wdata),
        .rdata    (scc_rdata),
        .ack      (scc_ack),
        .rxda     (rxda),
        .txda     (txda),
        .rxdb     (rxdb),
        .txdb     (txdb),
        .int_n    (scc_int_n),
        .tx_valid (tx_valid),
        .tx_data  (tx_data),
        .tx_chan  (tx_chan)
    );

    //------------------------------------------------------------------
    // Response mux
    //------------------------------------------------------------------
    // Devices that answer combinationally get their ack generated here, one
    // cycle after the request, which keeps the CPU's mem_done edge clean.
    logic        ioc_ack, none_ack;
    logic [63:0] ioc_rdata_r;
    logic        gio_absent_ack;

    always_ff @(posedge clk) begin
        ioc_ack        <= 1'b0;
        none_ack       <= 1'b0;
        gio_absent_ack <= 1'b0;
        bus_unclaimed  <= 1'b0;

        if (!reset && bus_req) begin
            // The SCC takes four clocks to run its strobe handshake and acks
            // for itself; the rest of the IOC window is a register read.
            if (sel_ioc && !scc_sel) begin
                ioc_ack     <= 1'b1;
                ioc_rdata_r <= 64'h0;
            end
            if (sel_gio && !gio_present) gio_absent_ack <= 1'b1;
            if (sel_none) begin
                none_ack      <= 1'b1;
                bus_unclaimed <= 1'b1;
            end
        end
    end

    assign bus_ack   = ram_ack | prom_ack | gio_ack | ioc_ack | scc_ack
                     | none_ack | gio_absent_ack;
    // Mirror the SCC's 32-bit answer into both halves of the doubleword so the
    // read shift in r4300_bus lands on it whichever word was addressed.
    assign bus_rdata = ram_ack  ? ram_rdata
                     : prom_ack ? prom_rdata
                     : gio_ack  ? gio_rdata
                     : scc_ack  ? {scc_rdata, scc_rdata}
                     : ioc_ack  ? ioc_rdata_r
                     :            64'hFFFF_FFFF_FFFF_FFFF;

    // ---- observability ----
    assign bus_req_o   = bus_req;
    assign bus_we_o    = bus_we;
    assign bus_addr_o  = bus_addr;
    assign bus_wdata_o = bus_wdata;
    assign bus_be_o    = bus_be;
    assign bus_rdata_o = bus_rdata;
    assign bus_ack_o   = bus_ack;

endmodule
