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
//  WHAT THIS IS AND IS NOT. This is the register file plus the decode in front
//  of it. Exactly one channel behind it is real: SCSI channel 0 (sub-block 8,
//  0x1FB90000), whose registers and descriptor engine live in
//  hpc3_scsi_dma.sv and which is this core's only bus master. Every other
//  channel is plain storage that reads back what was written - enough for the
//  PROM's power-on tests, and honest about moving no data.
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
    // Which word of the doubleword the CPU actually addressed. Byte enables
    // cannot answer that on a read, and SCSI channel 0's control register
    // clears its interrupt when it is read - so a driver reading the byte
    // count beside it must not clear anything. See rtl/cpu/r4300_bus.sv.
    input  logic  [2:0] aoff,
    input  logic  [7:0] be,
    input  logic [63:0] wdata,
    output logic [63:0] rdata,
    output logic        ack,

    // ---- SCSI channel 0's bus master port, out to main memory ------------
    output logic        dma_req,
    output logic        dma_we,
    output logic [31:0] dma_addr,
    output logic [63:0] dma_wdata,
    output logic  [7:0] dma_be,
    input  logic [63:0] dma_rdata,
    input  logic        dma_ack,

    // ---- SCSI channel 0's device side, to the WD33C93B -------------------
    input  logic        scsi_dev_req,
    input  logic        scsi_dev_dir_in,
    input  logic  [7:0] scsi_dev_wdata,
    input  logic        scsi_dev_eop,
    output logic        scsi_dev_ack,
    output logic  [7:0] scsi_dev_rdata,
    output logic        scsi_dev_reset,

    output logic        scsi_dma_irq,
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

    //------------------------------------------------------------------
    // SCSI channel 0 - the one channel that is a real DMA engine
    //------------------------------------------------------------------
    // 0x1FB90000 is sub-block 8, and hpc3_scsi_dma.sv owns all eight of its
    // registers: the arrays below never see them.
    localparam logic [3:0] SUB_SCSI0 = 4'd8;
    wire scsi0_blk = (blk == BLK_DESC || blk == BLK_CTRL) && (sub == SUB_SCSI0);

    // The engine indexes its registers as {is_control_block, index}: 0x0 cbp,
    // 0x1 nbdp, 0x8 bc, 0x9 control, 0xA gio, 0xB dev, 0xC dmacfg, 0xD piocfg.
    function automatic logic [3:0] scsi0_reg(input logic w);
        scsi0_reg = (blk == BLK_CTRL) ? {1'b1, ctrl_reg(w)}
                                      : {3'b000, w};
    endfunction

    logic [31:0] scsi0_rd0, scsi0_rd1;
    // Which word of the doubleword the access is really for. A 64-bit store
    // covering both registers of a pair would need two write ports and no
    // driver issues one - the PROM uses `sw` throughout - so the addressed
    // word is the one that is written.
    wire         scsi0_word = aoff[2];

    // Declared before use in the write-merge below.
    logic [31:0] wval [0:1];
    logic  [1:0] wr_en;

    hpc3_scsi_dma u_scsi0_dma (
        .clk        (clk),
        .reset      (reset),

        .pio_sel    (sel && scsi0_blk),
        .pio_reg    (scsi0_reg(scsi0_word)),
        .pio_we     (we && wr_en[scsi0_word]),
        .pio_wdata  (wval[scsi0_word]),
        .rd_reg0    (scsi0_reg(1'b0)),
        .rd_data0   (scsi0_rd0),
        .rd_reg1    (scsi0_reg(1'b1)),
        .rd_data1   (scsi0_rd1),

        .dma_req    (dma_req),
        .dma_we     (dma_we),
        .dma_addr   (dma_addr),
        .dma_wdata  (dma_wdata),
        .dma_be     (dma_be),
        .dma_rdata  (dma_rdata),
        .dma_ack    (dma_ack),

        .dev_req    (scsi_dev_req),
        .dev_dir_in (scsi_dev_dir_in),
        .dev_wdata  (scsi_dev_wdata),
        .dev_eop    (scsi_dev_eop),
        .dev_ack    (scsi_dev_ack),
        .dev_rdata  (scsi_dev_rdata),
        .dev_reset  (scsi_dev_reset),

        .irq        (scsi_dma_irq)
    );

    // ---- the DMA interrupt status register -------------------------------
    // gen.intstat, spec section 3.1: bits 7:0 are the PBUS channels, bit 8 is
    // SCSI channel 0 and bit 9 SCSI channel 1. It is read-only and reading it
    // does not disturb the status - the interrupt is acknowledged at the
    // channel's own control port.
    //
    // *** SPEC BUG ***, quoted: "Instead of being in one piece, it is broken
    // and can only be read in two pieces. Bits 4:0 can be read from
    // 0x1fbb0000. Bits 9:5 can be read from 0x1fbb000c. All other bits in both
    // registers should be ignored as they are indeterminate." SCSI0 is bit 8,
    // so it only ever appears at +0x000C. Nothing has tested this: the PROM
    // polls the WD33C93 and never looks here, and the descriptors it builds do
    // not set XIE, so this whole path can be wrong without the boot noticing.
    wire [9:0] intstat = {1'b0, scsi_dma_irq, 8'h00};

    // AN IF/ELSE CHAIN, NOT A CASE, and it has to stay one.
    //
    // This function is reached with a constant argument - hpc3_rd(1'b0)
    // and hpc3_rd(1'b1) - so Quartus 17.0 tries to CONSTANT-EVALUATE the
    // body rather than elaborate it. Its evaluator then meets
    // `case (blk)`, where blk is a non-constant 3-bit enum while the case
    // items evaluate at integer width, and asserts on the mismatch:
    //
    //    Internal Error: Sub-system: VRFX, File: verivalue_elab.cpp,
    //                    Line: 1789
    //    case_expr && case_expr->Size() == Size()
    //
    // That is a tool crash, not an error message: no line number, no file,
    // and a stack trace naming only Verific internals. The width mismatch
    // is what does it - the same case over a plain `enum` compiles - and
    // comparisons are evaluated by a different path, so the chain below is
    // the fix. It is exactly equivalent: the labels are distinct constants
    // and `default` is the final else.
    //
    // ioc_rd in sgi_ioc.sv is the same shape for the same reason. Anything
    // that cases a sized expression against differently sized items, in a
    // function called with constants, will crash Quartus the same way.
    function automatic logic [31:0] hpc3_rd(input logic w);
        if (blk == BLK_DESC)
            hpc3_rd = scsi0_blk ? (w ? scsi0_rd1 : scsi0_rd0)
                                : dma_desc[{sub, w}];
        else if (blk == BLK_CTRL)
            hpc3_rd = scsi0_blk ? (w ? scsi0_rd1 : scsi0_rd0)
                                : dma_ctrl[{sub, ctrl_reg(w)}];
        // 0x1FBB0000 and 0x1FBB000C are the two halves of intstat and are
        // generated, not stored; 0x1FBB0004 and 0x1FBB0008 are storage.
        else if (blk == BLK_GEN)
            hpc3_rd = ({addr[4:3], w} == 3'd0) ? {27'h0, intstat[4:0]}
                    : ({addr[4:3], w} == 3'd3) ? {22'h0, intstat[9:5], 5'h0}
                    :                            gen[{addr[4:3], w}];
        else if (blk == BLK_CFGDMA)
            hpc3_rd = cfgdma[addr[11:9]];
        else if (blk == BLK_CFGPIO)
            hpc3_rd = cfgpio[addr[11:8]];
        // HAL2 ANSWERS ITS REVISION REGISTER AND NOTHING ELSE, and that
        // is enough to be listed. There is no audio path behind this and
        // there is not meant to be yet: `hinv` prints the audio line out
        // of HAL2_REV, not out of anything that makes a sound.
        //
        //   0x4010, the value IRIS returns (src/hal2.rs). The PROM's node
        //   printer at 0xBFC41664 splits it as
        //     (v >> 12) & 7  .  (v >> 4) & 0xF  .  v & 0xF
        //   so 0x4010 is revision 4.1.0, and the "A2" beside it is a
        //   hardcoded string at 0xBFC54B58 rather than anything this chip
        //   reports. That is the whole of
        //     Audio: Iris Audio Processor: version A2 revision 4.1.0
        //
        // BIT 15 IS THE SWITCH. Set, it means "no audio present", and both
        // the PROM and the IRIX driver skip the audio path entirely -
        // which is what this returned before, deliberately, as IRIS's
        // hal2_absent_read does. Clearing it commits to answering the
        // init sequence at 0xBFC00BD0, which writes IAR/IDR and then spins
        // on ISR bit 0 three times. Every register other than REV reads 0,
        // so busy is always clear and each spin exits on its first pass;
        // the init does not read indirect data back, so discarding the
        // writes costs nothing. **If that ever stops being true this hangs
        // the boot rather than skipping audio**, which is the risk bit 15
        // was buying off.
        //
        // The byte offset of the addressed register is addr with bit 2
        // replaced by w, so its 0x10-granular index is addr[7:4] whichever
        // half is being read.
        else if (blk == BLK_HAL2)
            hpc3_rd = (addr[7:4] == 4'h2) ? 32'h0000_4010
                                          : 32'h0000_0000;
        else
            hpc3_rd = 32'h0000_0000;
    endfunction

    // ---- write data ------------------------------------------------------
    // be[7-i] guards the byte at addr+i: bytes 0..3 are the w=0 register and
    // bytes 4..7 the w=1 one. Partial writes merge against the current value.
    // The function's result goes into a variable before it is indexed, because
    // Quartus 17.0 will not bit-select a function call - `f(x)[7:0]` is a
    // syntax error there, reported as "near text '['; expecting ';'". Verilator
    // accepts it, which is how it got written this way.
    logic [31:0] rd_cur;
    always_comb begin
        wr_en[0] = sel && we && (|be[7:4]);
        wr_en[1] = sel && we && (|be[3:0]);
        rd_cur   = 32'h0;
        for (int w = 0; w < 2; w++) begin
            rd_cur = hpc3_rd(w[0]);
            for (int b = 0; b < 4; b++)
                wval[w][24 - 8*b +: 8] =
                    be[7 - 4*w - b] ? wdata[56 - 32*w - 8*b +: 8]
                                    : rd_cur[24 - 8*b +: 8];
        end
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
                        // SCSI channel 0's registers live in the engine, so
                        // the arrays must not shadow them.
                        BLK_DESC:   if (!scsi0_blk) dma_desc[{sub, w[0]}]           <= wval[w];
                        BLK_CTRL:   if (!scsi0_blk) dma_ctrl[{sub, ctrl_reg(w[0])}] <= wval[w];
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
