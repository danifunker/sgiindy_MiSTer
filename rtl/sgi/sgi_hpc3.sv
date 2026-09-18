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

    // SGI: DDR3 debug beacon (docs/29) - the SCSI0 DMA channel's live state.
    output logic [63:0] dbg_scsi0_dma,

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

    // ---- the store -------------------------------------------------------
    // EVERY REGISTER THAT IS PLAIN STORAGE LIVES IN ONE 256-WORD MEMORY, and
    // it is a memory rather than 6,144 flip-flops because that is what those
    // flip-flops cost: 3,637 ALMs of build 41's fit, a tenth of the device,
    // for a register file nothing reads twice a second.
    //
    //   0x00-0x1F  descriptor pairs   {sub-block, word}
    //   0x20-0x27  gen                {addr[4:3], word}
    //   0x28-0x2F  cfgdma             channel 0..7
    //   0x30-0x3F  cfgpio             channel 0..15
    //   0x80-0xFF  control groups     {sub-block, register 0..7}
    //
    // TWO COPIES, BECAUSE ONE BUS CYCLE READS TWO REGISTERS. A doubleword
    // covers the register at +0 and the one at +4 and the CPU may address
    // either, so the read is two ports; a memory has one. Both copies take
    // every write, and each answers one half. They are 2 M10Ks against 483
    // already in use.
    //
    // A read now lands a clock after its address instead of in the same
    // clock, and a partial write costs one more on top - the byte that is not
    // written has to be merged against the word as it is, which is the same
    // read. The bus waits for `ack` however long it takes (r4300_bus holds its
    // request in S_BUSY), nothing here has a deadline, and one PIO access to
    // these registers per boot phase is the traffic. SCSI channel 0, HAL2 and
    // the write-only ports are NOT in the store and still answer in the clock
    // after `sel`, which is what matters: the channel's registers are read on
    // every disk interrupt, and reading its control port clears one.
    localparam int ST_N = 256;
    logic [31:0] st0 [0:ST_N-1];       // answers the +0 half
    logic [31:0] st1 [0:ST_N-1];       // answers the +4 half
    logic  [7:0] st_ra0, st_ra1, st_wa;
    logic [31:0] st_q0, st_q1, st_wd;
    logic        st_we;

    always_ff @(posedge clk) begin
        if (st_we) begin
            st0[st_wa] <= st_wd;
            st1[st_wa] <= st_wd;
        end
        st_q0 <= st0[st_ra0];
        st_q1 <= st1[st_ra1];
    end

    // Power-up contents: Quartus turns this into the M10K's initial value and
    // the simulator runs it at time zero. (Starting the line with the
    // simulator's own name after `//` would make it read the sentence as a
    // directive.) The reset sweep below is what clears the store again on a
    // warm reset, as the `for` loops used to.
    integer ini;
    initial begin
        for (ini = 0; ini < ST_N; ini = ini + 1) begin
            st0[ini] = 32'h0;
            st1[ini] = 32'h0;
        end
    end

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

        .irq        (scsi_dma_irq),
        .dbg_dma    (dbg_scsi0_dma)
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
    // WHICH BLOCKS ARE IN THE STORE. SCSI channel 0's sub-block is not: the
    // engine owns those registers. Neither are HAL2's file, the write-only
    // PBUS ports or an address this module does not claim.
    wire stored = (blk == BLK_GEN) || (blk == BLK_CFGDMA) || (blk == BLK_CFGPIO)
               || (((blk == BLK_DESC) || (blk == BLK_CTRL)) && !scsi0_blk);

    // The store's index for the register this access's half w addresses. An
    // if/else chain for the same reason hpc3_rd below is one.
    function automatic logic [7:0] st_idx(input logic w);
        if (blk == BLK_CTRL)        st_idx = {1'b1, sub, ctrl_reg(w)};
        else if (blk == BLK_DESC)   st_idx = {3'b000, sub, w};
        else if (blk == BLK_GEN)    st_idx = {5'b00100, addr[4:3], w};
        else if (blk == BLK_CFGDMA) st_idx = {5'b00101, addr[11:9]};
        else                        st_idx = {4'b0011, addr[11:8]};   // BLK_CFGPIO
    endfunction

    assign st_ra0 = st_idx(1'b0);
    assign st_ra1 = st_idx(1'b1);

    // What a stored half reads: the word out of the store, except for the two
    // halves of intstat. 0x1FBB0000 and 0x1FBB000C are generated, not stored;
    // 0x1FBB0004 and 0x1FBB0008 are storage. The store still holds a word for
    // the generated pair and a write still lands in it - nothing reads it, and
    // keeping the write unconditional keeps the write port's address one
    // function of the address.
    function automatic logic [31:0] st_rd(input logic w, input logic [31:0] q);
        if (blk == BLK_GEN)
            st_rd = ({addr[4:3], w} == 3'd0) ? {27'h0, intstat[4:0]}
                  : ({addr[4:3], w} == 3'd3) ? {22'h0, intstat[9:5], 5'h0}
                  :                            q;
        else st_rd = q;
    endfunction

    function automatic logic [31:0] hpc3_rd(input logic w);
        // Only the blocks that are not in the store reach this: SCSI channel
        // 0's registers, HAL2's revision, and everything else as zero.
        if ((blk == BLK_DESC) || (blk == BLK_CTRL))
            hpc3_rd = w ? scsi0_rd1 : scsi0_rd0;
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
        // BIT 15 IS THE SWITCH, AND IT IS SET AGAIN (hal2.sv REV_VALUE,
        // 2026-09-02): with it clear IRIX loads the kdsp_a2 audio driver,
        // which wedges the kernel in an endless bzero the first time
        // anything plays a sound (docs/design/scsi-fit-and-framebuffer-layout.md). Set, it means "no audio
        // present", and both the PROM and the IRIX driver skip the audio
        // path entirely - which is what this returned before, deliberately,
        // as IRIS's hal2_absent_read does. Clearing it commits to answering the
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
            hpc3_rd = {16'h0, hal2_rdata};
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

    // The same two things for a stored access, a clock later: what the halves
    // read, and what a write leaves behind once the bytes it does not carry
    // are merged against that. `sel` is long gone by then - the bus holds the
    // address, the write enables and the data until the acknowledge - so these
    // are the enables without it.
    logic [31:0] st_rdv [0:1];
    logic [31:0] st_wv  [0:1];
    wire         acc_wr0 = we && (|be[7:4]);
    wire         acc_wr1 = we && (|be[3:0]);
    always_comb begin
        st_rdv[0] = st_rd(1'b0, st_q0);
        st_rdv[1] = st_rd(1'b1, st_q1);
        for (int w = 0; w < 2; w++)
            for (int b = 0; b < 4; b++)
                st_wv[w][24 - 8*b +: 8] =
                    be[7 - 4*w - b] ? wdata[56 - 32*w - 8*b +: 8]
                                    : st_rdv[w][24 - 8*b +: 8];
    end

    // ---- HAL2 -------------------------------------------------------------
    // The audio processor's register file. It used to be a constant here -
    // REV and nothing else - and the PROM's init at 0xBFC00BD0 wrote IAR and
    // IDR into a hole. Those land in real registers now. See rtl/sgi/hal2.sv,
    // and read its header before touching ISR: bit 0 is what that init spins
    // on, and it has to stay clear.
    //
    // A HAL2 register is 16 bytes from the next, so addr[7:4] names one
    // whichever half of the doubleword the CPU addressed - which is also why
    // the read above replicates it into both halves, as the constant did.
    // Writes take whichever half carries byte enables.
    wire        hal2_sel = sel && (blk == BLK_HAL2);
    wire        hal2_we  = hal2_sel && we && (wr_en[0] || wr_en[1]);
    wire [15:0] hal2_wd  = wr_en[0] ? wval[0][15:0] : wval[1][15:0];
    wire [15:0] hal2_rdata;

    hal2 u_hal2 (
        .clk    (clk),
        .reset  (reset),
        .sel    (hal2_sel),
        .we     (hal2_we),
        .regsel (addr[7:4]),
        .wdata  (hal2_wd),
        .rdata  (hal2_rdata)
    );

    //------------------------------------------------------------------
    // The store's one access at a time
    //------------------------------------------------------------------
    // A stored access takes the clock after `sel` to read both halves out of
    // the memories, and answers at the end of it. A write of ONE half is made
    // in that same clock, from the merge above. A write of BOTH - a 64-bit
    // store covering the register at +0 and the one at +4 - needs the write
    // port twice, so the second half waits one clock more; it is the +4 half
    // that goes second, which is also the one that wins when both halves
    // address the same register. THAT IS NOT A CORNER CASE: cfgdma's stride is
    // 0x200 and cfgpio's 0x100, so a doubleword there covers one register
    // twice, and the flip-flop version's `for` loop left the +4 half's value
    // behind for exactly the same reason.
    //
    // ST_CLR is the reset sweep, 256 clocks of zeros through the write port,
    // in place of the `for` loops this replaces. A stored access that arrives
    // while it runs is remembered in `pend` and served when it is over; the
    // blocks outside the store are answered throughout, as they are in every
    // other state.
    typedef enum logic [1:0] { ST_IDLE, ST_ACC, ST_WR1, ST_CLR } st_t;
    st_t         ststate;
    logic  [7:0] clr_idx, idx1_r;
    logic [31:0] wv1_r;
    logic        pend;

    always_comb begin
        st_we = 1'b0;
        st_wa = 8'h00;
        st_wd = 32'h0;
        if (ststate == ST_CLR) begin
            st_we = 1'b1;
            st_wa = clr_idx;
        end
        else if (ststate == ST_ACC) begin
            if (acc_wr0) begin
                st_we = 1'b1; st_wa = st_idx(1'b0); st_wd = st_wv[0];
            end
            else if (acc_wr1) begin
                st_we = 1'b1; st_wa = st_idx(1'b1); st_wd = st_wv[1];
            end
        end
        else if (ststate == ST_WR1) begin
            st_we = 1'b1; st_wa = idx1_r; st_wd = wv1_r;
        end
    end

    always_ff @(posedge clk) begin
        ack <= 1'b0;

        if (reset) begin
            ststate <= ST_CLR;
            clr_idx <= 8'h00;
            pend    <= 1'b0;
            rdata   <= 64'h0;
        end else begin
            // The blocks that are not in the store answer in the clock after
            // `sel`, whatever the store is doing - including during the reset
            // sweep. HAL2 takes its write from `hal2_we` and the three
            // write-only PBUS registers accept and discard; nothing reads
            // them back.
            if (sel && claimed && !stored) begin
                rdata <= {hpc3_rd(1'b0), hpc3_rd(1'b1)};
                ack   <= 1'b1;
            end
            if (sel && stored && (ststate != ST_IDLE)) pend <= 1'b1;

            case (ststate)
                ST_CLR: begin
                    clr_idx <= clr_idx + 8'd1;
                    if (&clr_idx) ststate <= ST_IDLE;
                end

                ST_IDLE:
                    if (pend || (sel && stored)) begin
                        ststate <= ST_ACC;
                        pend    <= 1'b0;
                    end

                ST_ACC: begin
                    // Both halves are out of the memories now, and the write
                    // above is taking the first of them.
                    rdata  <= {st_rdv[0], st_rdv[1]};
                    idx1_r <= st_idx(1'b1);
                    wv1_r  <= st_wv[1];
                    if (acc_wr0 && acc_wr1) ststate <= ST_WR1;
                    else begin
                        ack     <= 1'b1;
                        ststate <= ST_IDLE;
                    end
                end

                ST_WR1: begin
                    ack     <= 1'b1;
                    ststate <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
