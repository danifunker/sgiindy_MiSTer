//============================================================================
//  sgi_hpc3 - the High performance Peripheral Controller, third generation.
//
//  HPC3 owns the whole of 0x1FB80000-0x1FBFFFFF and everything hanging off it:
//  the eight PBUS DMA channels, two SCSI ports, the Ethernet port, ten PBUS
//  PIO chip selects (HAL2 is channel 0, INT2/IOC is channel 6) and the
//  battery-backed RAM window that carries the Dallas RTC. Address map from the
//  HPC3 chip specification's section 2 table, which agrees with IRIS's
//  src/hpc3.rs offset constants throughout.
//
//  WHAT THIS IS AND IS NOT. This is the register file, not the DMA engine. It
//  answers PIO accesses to the descriptor, control and configuration
//  registers, which is what the PROM's power-on tests need; no channel moves
//  any data. That is enough to get through POST and is deliberately all that
//  is claimed here.
//
//  Registers are 32 bits at a stride of four, unlike MC's - so both words of
//  every doubleword bus cycle are live, and both are decoded.
//
//  A NOTE ON "READ ONLY". The spec marks cbp, bc, gio and dev read-only, and
//  says of rx_cbp that it "should only be updated through DMA descriptor
//  fetches (and not through PIO)". The PROM disagrees in practice: at
//  0xBFC03E58 it walks a one-bit pattern through 0x1FB94000 - enetr.cbp - and
//  reads each value back, dropping into an endless diagnostic loop if any
//  fails. So the register is writable through PIO on real silicon and the
//  spec's "read only" is advice to drivers, not a property of the hardware.
//  Every register here is therefore plain storage.
//
//  ADDRESSES THIS DOES NOT CLAIM stay unclaimed on the bus rather than reading
//  back zero, so `claimed` is an output. The holes are the map of what is
//  still missing, and the harness prints them on exit; making them silently
//  answer 0 would hide the next thing to build.
//============================================================================

module sgi_hpc3 (
    input  logic        clk,
    input  logic        reset,

    input  logic        sel,          // one-cycle request pulse, address in window
    input  logic        we,
    input  logic [18:0] addr,         // offset into the 512 KB window, 8-aligned
    input  logic  [7:0] be,
    input  logic [63:0] wdata,
    output logic [63:0] rdata,
    output logic        ack,
    // Combinational: 0 means this offset is not decoded here at all, and the
    // access should fall through to the core's unclaimed-cycle path.
    output logic        claimed
);

    // ---- block bases, from the HPC3 spec's address map --------------------
    localparam logic [18:0] PBUS_DMA_BASE = 19'h00000;  // 8 channels, stride 0x2000
    localparam logic [18:0] HD_ENET_BASE  = 19'h10000;  // hd0/hd1/enetr/enetx, stride 0x2000
    localparam logic [18:0] DMA_END       = 19'h20000;
    localparam logic [18:0] GEN_BASE      = 19'h30000;  // intstat, misc, eeprom, bus_error
    localparam logic [18:0] GEN_END       = 19'h30020;
    localparam logic [18:0] HAL2_BASE     = 19'h58000;  // PBUS PIO channel 0
    localparam logic [18:0] HAL2_END      = 19'h58400;
    localparam logic [18:0] CFGDMA_BASE   = 19'h5C000;  // 8 channels, stride 0x200
    localparam logic [18:0] CFGDMA_END    = 19'h5D000;
    localparam logic [18:0] CFGPIO_BASE   = 19'h5D000;  // 10 channels, stride 0x100
    localparam logic [18:0] CFGPIO_END    = 19'h5E000;
    localparam logic [18:0] WRONLY_BASE   = 19'h5E000;  // prom_we, prom_swap, gen_out
    localparam logic [18:0] WRONLY_END    = 19'h60000;

    typedef enum logic [2:0] {
        BLK_NONE,
        BLK_DESC,     // channel + 0x0000 / 0x0004: buffer and descriptor pointers
        BLK_CTRL,     // channel + 0x1000..0x101F: byte count, control, fifo ptrs, config
        BLK_GEN,      // 0x30000: intstat, gio.misc, eeprom.data, gio.bus_error
        BLK_CFGDMA,
        BLK_CFGPIO,
        BLK_HAL2,
        BLK_WRONLY
    } blk_t;

    // 16 DMA sub-blocks of 0x2000: PBUS channels 0-7 then hd0, hd1, enetr,
    // enetx and the four IRIX-only descriptor-pointer windows above them.
    logic [31:0] dma_desc [0:31];      // {sub-block, word}
    logic [31:0] dma_ctrl [0:127];     // {sub-block, register 0..7}
    logic [31:0] gen      [0:7];
    logic [31:0] cfgdma   [0:7];
    logic [31:0] cfgpio   [0:15];

    // ---- decode ----------------------------------------------------------
    blk_t blk;
    always_comb begin
        blk = BLK_NONE;
        if (addr < DMA_END) begin
            // Within a 0x2000 sub-block: 0x0000-0x0FFF is the descriptor pair
            // (only the first doubleword of it exists), 0x1000-0x1FFF is the
            // control group.
            if (addr[12])                        blk = BLK_CTRL;
            else if (addr[11:3] == 9'h000)       blk = BLK_DESC;
        end
        else if (addr >= GEN_BASE    && addr < GEN_END)    blk = BLK_GEN;
        else if (addr >= HAL2_BASE   && addr < HAL2_END)   blk = BLK_HAL2;
        else if (addr >= CFGDMA_BASE && addr < CFGDMA_END) blk = BLK_CFGDMA;
        else if (addr >= CFGPIO_BASE && addr < CFGPIO_END) blk = BLK_CFGPIO;
        else if (addr >= WRONLY_BASE && addr < WRONLY_END) blk = BLK_WRONLY;
    end

    assign claimed = (blk != BLK_NONE);

    // Sub-block and register indices. addr is doubleword aligned, so bit 2 is
    // always zero and the word within the pair comes from `w` instead: w=0 is
    // the register at addr+0, w=1 the one at addr+4.
    wire [3:0] sub = addr[16:13];
    function automatic logic [2:0] ctrl_reg(input logic w);
        ctrl_reg = {addr[4:3], w};
    endfunction

    function automatic logic [31:0] hpc3_rd(input logic w);
        case (blk)
            BLK_DESC:   hpc3_rd = dma_desc[{sub, w}];
            BLK_CTRL:   hpc3_rd = dma_ctrl[{sub, ctrl_reg(w)}];
            BLK_GEN:    hpc3_rd = gen[{addr[4:3], w}];
            BLK_CFGDMA: hpc3_rd = cfgdma[addr[11:9]];
            BLK_CFGPIO: hpc3_rd = cfgpio[addr[11:8]];
            // HAL2 is not modelled. REV reading 0xFFFF is not a placeholder:
            // bit 15 set is how the part says "no audio present", and both the
            // PROM and the IRIX driver then skip the whole audio path instead
            // of spinning on the busy bit of a chip that is not there. Every
            // other register reads 0 so ISR.busy is clear. Same convention as
            // IRIS's hal2_absent_read.
            // The byte offset of the addressed register is addr with bit 2
            // replaced by w, so its 0x10-granular index is addr[7:4] whichever
            // half is being read.
            BLK_HAL2:   hpc3_rd = (addr[7:4] == 4'h2) ? 32'h0000_FFFF
                                                      : 32'h0000_0000;
            default:    hpc3_rd = 32'h0000_0000;
        endcase
    endfunction

    // ---- write data ------------------------------------------------------
    // be[7-i] guards the byte at addr+i: bytes 0..3 are the w=0 register and
    // bytes 4..7 the w=1 one. Partial writes merge against the current value.
    logic [31:0] wval [0:1];
    logic  [1:0] wr_en;

    always_comb begin
        wr_en[0] = sel && we && (|be[7:4]);
        wr_en[1] = sel && we && (|be[3:0]);
        for (int w = 0; w < 2; w++)
            for (int b = 0; b < 4; b++)
                wval[w][24 - 8*b +: 8] =
                    be[7 - 4*w - b] ? wdata[56 - 32*w - 8*b +: 8]
                                    : hpc3_rd(w[0])[24 - 8*b +: 8];
    end

    integer i;
    always_ff @(posedge clk) begin
        ack   <= 1'b0;
        rdata <= 64'h0;

        if (reset) begin
            for (i = 0; i < 32;  i = i + 1) dma_desc[i] <= 32'h0;
            for (i = 0; i < 128; i = i + 1) dma_ctrl[i] <= 32'h0;
            for (i = 0; i < 8;   i = i + 1) gen[i]      <= 32'h0;
            for (i = 0; i < 8;   i = i + 1) cfgdma[i]   <= 32'h0;
            for (i = 0; i < 16;  i = i + 1) cfgpio[i]   <= 32'h0;
        end else begin
            for (int w = 0; w < 2; w++) begin
                if (wr_en[w]) begin
                    case (blk)
                        BLK_DESC:   dma_desc[{sub, w[0]}]            <= wval[w];
                        BLK_CTRL:   dma_ctrl[{sub, ctrl_reg(w[0])}]  <= wval[w];
                        BLK_GEN:    gen[{addr[4:3], w[0]}]           <= wval[w];
                        BLK_CFGDMA: cfgdma[addr[11:9]]               <= wval[w];
                        BLK_CFGPIO: cfgpio[addr[11:8]]               <= wval[w];
                        // HAL2 and the three write-only PBUS registers accept
                        // and discard: nothing reads them back.
                        default:    ;
                    endcase
                end
            end

            if (sel && claimed) begin
                rdata <= {hpc3_rd(1'b0), hpc3_rd(1'b1)};
                ack   <= 1'b1;
            end
        end
    end

endmodule
