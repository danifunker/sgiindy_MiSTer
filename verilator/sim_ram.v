//============================================================================
//  sim_ram.v - memory and device models for the Verilator harness.
//
//  The storage lives in C++ (sim_devices.cpp) and is reached through DPI,
//  which is what makes an ELF loader, a memory dump and a bus trace cheap.
//  The prior DE1 sandbox did the same thing for the same reason.
//
//  Every port speaks the core's bus convention: addresses are doubleword
//  aligned, `data[63-8*i -: 8]` is the byte at `addr + i`, and `be[7-i]`
//  guards it. The C++ side stores bytes in that order too, so a memory dump
//  reads like the machine's address space rather than like a byte-swap.
//
//  Reads are registered, so a request presented in one cycle is answered in
//  the next. That is a deliberate one-cycle latency rather than a
//  combinational answer: it keeps the ack edge that r4300_bus hands to
//  cpu.vhd's mem_done clean, and it means nothing here accidentally depends
//  on zero-delay memory.
//============================================================================

`ifndef SIM_LATENCY
`define SIM_LATENCY 1
`endif

module sim_ram
(
    input  wire        clk,
    input  wire [31:0] space,     // which C++ backing store: 0 RAM, 1 PROM, 2 GIO

    input  wire        req,
    input  wire        we,
    input  wire [31:0] addr,
    input  wire [63:0] wdata,
    input  wire  [7:0] be,
    output reg  [63:0] rdata,
    output reg         ack
);

    import "DPI-C" function longint unsigned sgi_dpi_read
        (input int unsigned space, input int unsigned addr);
    import "DPI-C" function void sgi_dpi_write
        (input int unsigned space, input int unsigned addr,
         input longint unsigned data, input byte unsigned be);

    always @(posedge clk) begin
        ack <= 1'b0;
        if (req) begin
            if (we) sgi_dpi_write(space, addr, wdata, be);
            else    rdata <= sgi_dpi_read(space, addr);
            ack <= 1'b1;
        end
    end

endmodule
