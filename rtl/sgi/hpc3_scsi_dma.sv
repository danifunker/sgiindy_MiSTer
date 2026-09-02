//============================================================================
//  hpc3_scsi_dma - the HPC3's SCSI channel 0 DMA engine.
//
//  This is HPC3's channel 8, the one behind the WD33C93B at 0x1FBC0000. It is
//  the first bus master in this core: everything else issues cycles only when
//  the CPU asks for them. The registers live at HPC3 + 0x10000 (0x1FB90000)
//  and the whole map, the descriptor format and every bit below is from the
//  HPC3 chip specification, sections 2.2, 2.5 and 3.3 - not from a secondary
//  source. Where IRIS's src/hpc3.rs disagrees with the spec that is noted at
//  the point of disagreement, because IRIS is the tiebreaker for what software
//  expects and the spec is the authority for what the part does.
//
//  THE REGISTERS, from the spec's section 3.0 address map:
//
//    +0x0000  cbp      current buffer pointer   R/W for PIO
//    +0x0004  nbdp     next buffer descriptor   R/W
//    +0x1000  bc       byte count and flags     count read-only for PIO
//    +0x1004  control  see below
//    +0x1008  gio      gio-side fifo pointer    storage
//    +0x100C  dev      device-side fifo pointer storage
//    +0x1010  dmacfg   DMA configuration
//    +0x1014  piocfg   PIO timing
//
//  THE CONTROL REGISTER, spec section 3.3:
//
//    0x01 interrupt     read-only; set on a descriptor with XIE, or on a
//                       parity error. CLEARED BY READING THIS PORT.
//    0x02 endian        1 = little endian for this channel's data. NOT a
//                       16-bit byte swap - that is dma_swap in dmacfg.
//    0x04 dir           1 = main memory to device, 0 = device to main memory.
//    0x08 flush         drain the fifo to memory and stop. See below.
//    0x10 ch_active     0->1 starts the channel; HPC3 clears it when the
//                       transfer completes. Writable only when ch_active_mask
//                       is 0 in the same write.
//    0x20 ch_active_mask write-only; when set, this write leaves ch_active
//                       alone. That is how a driver changes dir or endian
//                       without disturbing a running channel.
//    0x40 ch_reset      resets the channel and the external controller. SET
//                       ON POWER-ON RESET, and "must be programmed to a 0
//                       before the ch_active bit becomes active".
//    0x80 parity_error  read-only, cleared on a read of this port. Always 0
//                       here: nothing models SCSI bus parity.
//
//  THE DESCRIPTOR is THREE words, not four (spec 2.2). Quadword aligned in
//  main memory and it may not cross a page boundary, which is why the fourth
//  word exists as padding and why nothing reads it:
//
//    +0x00  BP  buffer physical address
//    +0x04  BC  EOX(31) EOXP(30) XIE(29) ... count(13:0)
//    +0x08  DP  next descriptor physical address
//
//  EOXP is the Ethernet transmitter's end-of-packet and means nothing here.
//  XIE asks for an interrupt when this descriptor finishes; EOX says this is
//  the last one in the chain.
//
//  A ZERO BYTE COUNT IS NOT A TRANSFER. With EOX it ends the chain; without,
//  it is a link and the next descriptor is fetched immediately. That is not a
//  corner case, it is the normal shape of a receive chain: the spec carries a
//  "**** BUG ****" note saying HPC3 refuses the last byte of a receive chain,
//  and tells drivers to always tack a zero-count descriptor onto the end. The
//  IP24 PROM does exactly that - it builds one descriptor with the real count
//  and a second holding nothing but EOX. Getting the zero-count case wrong
//  hangs the transfer on its second descriptor, which is where every receive
//  chain ends.
//
//  DIRECTION. The spec says `dir` decides it - "from main memory to device
//  when dir = '1'". IRIS ignores `dir` and takes the direction from the SCSI
//  bus phase. The phase wins here, because it is what the target is actually
//  driving and a driver that lies about `dir` still has to be right about the
//  wire. `dir` is stored and reads back; nothing has been seen to disagree
//  with the phase, and this is where to look if something ever does.
//
//  FLUSH MUST NOT RAISE AN INTERRUPT. The spec is explicit - "an interrupt
//  does not occur automatically when the flush is complete" - and IRIS carries
//  the scar from the other direction: IRIX's SCSI teardown acks the real
//  interrupt and then writes FLUSH, and a model that interrupts again leaves
//  the bit set and the line in a storm.
//
//  WHAT IS NOT MODELLED, deliberately:
//    - The fifo. The spec's high water mark, the gio/dev fifo pointers and the
//      whole burst-sizing apparatus exist to keep a 64-bit GIO64 burst busy;
//      this engine moves one byte per handshake and the pointers are storage.
//    - 16-bit DMA (dmacfg bit 12). The PROM writes 0x00034801, which has it
//      clear, and the WD33C93B is an 8-bit device. The Fujitsu 86603 is what
//      needs it and this machine does not have one.
//    - Parity, in either direction.
//
//  CH_RESET IS A PULSE HERE AND A LEVEL IN THE SPEC. "Resets both external
//  controller and this DMA channel... This bit is active (=1, channel is
//  reset) upon power-on reset. This must be programmed to a 0 before the
//  ch_active bit becomes active." Read literally, the WD33C93B is held in
//  reset from power-on until the PROM's first write clears the bit. IRIS
//  instead pulses the controller's reset on the FALLING edge, and that is what
//  is done here: it is the behaviour that boots IRIX, and a held reset raises
//  a question about the state of a chip nobody has answered. The gating half
//  of the rule is real and is enforced - ch_active cannot go active while
//  ch_reset is set.
//
//  This is not a corner case any more. The PROM's recovery path writes 0x40
//  then 0x00 and prints "resetting SCSI bus", and until this existed the bus
//  stayed wedged with a target holding BSY and every command after it failed.
//============================================================================

module hpc3_scsi_dma (
    input  logic        clk,
    input  logic        reset,

    // ---- PIO register access, from sgi_hpc3's decode ---------------------
    // reg_idx is {is_ctrl_block, register within the block}:
    //   0x0 cbp   0x1 nbdp                    (the +0x0000 pair)
    //   0x8 bc    0x9 control  0xA gio  0xB dev  0xC dmacfg  0xD piocfg
    input  logic        pio_sel,      // one-cycle pulse, this channel addressed
    input  logic  [3:0] pio_reg,      // the register the CPU actually addressed
    input  logic        pio_we,
    input  logic [31:0] pio_wdata,
    // Two combinational read ports, because one CPU cycle covers a pair of
    // registers: the doubleword at +0x1000 is the byte count and the control
    // register at once, and sgi_hpc3 reads both to answer it and to merge a
    // partial byte write against the current value. Neither port has a side
    // effect - the interrupt-clearing read is taken from pio_sel/pio_reg,
    // which is the register the CPU actually addressed.
    input  logic  [3:0] rd_reg0,
    output logic [31:0] rd_data0,
    input  logic  [3:0] rd_reg1,
    output logic [31:0] rd_data1,

    // ---- bus master, into main memory ------------------------------------
    // NOT the shape of the CPU's port. The CPU pulses `req` for one cycle
    // because it is the only master and the port is always its to take; this
    // one is the loser of every tie, so `req` is HELD until `ack`. A pulse
    // here is dropped on any cycle the CPU wanted memory, and the engine then
    // waits forever for an answer to a request nobody heard - which presents
    // as a transfer that moves a handful of bytes and stops, at a different
    // byte every run. Addresses are physical; sgi_indy runs them through the
    // same MEMCFG decode the CPU's go through.
    output logic        dma_req,
    output logic        dma_we,
    output logic [31:0] dma_addr,     // physical, 8-byte aligned
    output logic [63:0] dma_wdata,
    output logic  [7:0] dma_be,
    input  logic [63:0] dma_rdata,
    input  logic        dma_ack,

    // ---- the device side, to the WD33C93B --------------------------------
    input  logic        dev_req,      // the chip has, or wants, a byte
    input  logic        dev_dir_in,   // 1 = DATA IN, device -> memory
    input  logic  [7:0] dev_wdata,    // the byte the chip took off the bus
    input  logic        dev_eop,      // pulse: the target ended the data phase
    output logic        dev_ack,      // pulse: the byte has been moved
    output logic  [7:0] dev_rdata,    // the byte from memory, valid with ack

    // Falling edge of ch_reset: reset the WD33C93B and the bus behind it.
    output logic        dev_reset,

    // ---- interrupt -------------------------------------------------------
    output logic        irq,          // control[0], the XIE interrupt

    // SGI: DDR3 debug beacon (docs/29) - the DMA channel's live state, to see
    // whether IRIX's segmented-read completion interrupt is firing. Pure tap.
    //   [63:60] dstate [59] ctrl_active [58] ctrl_int [57] ctrl_dir
    //   [56] desc_eox  [55] desc_xie    [54] dev_req  [53] dev_ack
    //   [52] dev_dir_in [51] dev_eop    [50] dma_req  [49] dma_ack [48] dma_we
    //   [47:32] bc[15:0]  [31:0] cbp
    output logic [63:0] dbg_dma
);

    // ---- register file ----------------------------------------------------
    logic [31:0] cbp, nbdp, bc, gio, dev, dmacfg, piocfg;
    logic        ctrl_int;      // control[0]
    logic        ctrl_endian;   // control[1]
    logic        ctrl_dir;      // control[2]
    logic        ctrl_active;   // control[4]
    logic        ctrl_reset;    // control[6]

    // Power-on values from the spec: ch_reset is set, and dmacfg's high water
    // mark comes up at "100" with everything else clear.
    localparam logic [31:0] DMACFG_POR = 32'h0000_0800;

    wire [31:0] control = {24'h0, 1'b0,         // 7 parity_error, never set
                                  ctrl_reset,   // 6
                                  1'b0,         // 5 ch_active_mask, write only
                                  ctrl_active,  // 4
                                  1'b0,         // 3 flush, self-clearing
                                  ctrl_dir,     // 2
                                  ctrl_endian,  // 1
                                  ctrl_int};    // 0

    // The descriptor's flags, as fetched. Held separately from `bc` because
    // the count in bc[13:0] is decremented as the transfer runs and the flags
    // must survive that.
    logic desc_eox, desc_xie;

    localparam logic [31:0] DESC_EOX = 32'h8000_0000;
    localparam logic [31:0] DESC_XIE = 32'h2000_0000;

    // ---- register indices -------------------------------------------------
    localparam logic [3:0] R_CBP    = 4'h0;
    localparam logic [3:0] R_NBDP   = 4'h1;
    localparam logic [3:0] R_BC     = 4'h8;
    localparam logic [3:0] R_CTRL   = 4'h9;
    localparam logic [3:0] R_GIO    = 4'hA;
    localparam logic [3:0] R_DEV    = 4'hB;
    localparam logic [3:0] R_DMACFG = 4'hC;
    localparam logic [3:0] R_PIOCFG = 4'hD;

    function automatic logic [31:0] reg_read(input logic [3:0] a);
        case (a)
            R_CBP:    reg_read = cbp;
            R_NBDP:   reg_read = nbdp;
            R_BC:     reg_read = bc;
            R_CTRL:   reg_read = control;
            R_GIO:    reg_read = gio;
            R_DEV:    reg_read = dev;
            R_DMACFG: reg_read = dmacfg;
            R_PIOCFG: reg_read = piocfg;
            default:  reg_read = 32'h0;
        endcase
    endfunction

    assign rd_data0 = reg_read(rd_reg0);
    assign rd_data1 = reg_read(rd_reg1);

    assign irq = ctrl_int;

    // ---- the engine -------------------------------------------------------
    typedef enum logic [3:0] {
        D_IDLE,
        D_FETCH_LO,    // descriptor words 0 and 1: BP and BC
        D_FETCH_LO_W,
        D_FETCH_HI,    // descriptor word 2: DP
        D_FETCH_HI_W,
        D_EVAL,        // zero count is a link or the end of the chain
        D_RUN,         // wait for the controller to want a byte
        D_MEM_RD,      // DATA OUT: fetch the byte from main memory
        D_MEM_RD_W,
        D_MEM_WR,      // DATA IN: store the byte into main memory
        D_MEM_WR_W,
        D_ADVANCE,     // a byte moved: cbp++, bc--, and decide what comes next
        D_DESC_END,    // this descriptor is finished, whatever the count says
        D_COMPLETE     // clear ch_active
    } dstate_t;

    dstate_t dstate;

    // The descriptor being fetched. `nbdp` is overwritten by the fetch itself,
    // so the address it is read from has to be held somewhere else.
    logic [31:0] fetch_ptr;

    // A chain of zero-count link descriptors that never reaches an EOX one is
    // a driver bug, and in a simulator it is an infinite loop that looks like
    // a hang three layers away. Bail out and stop the channel instead - the
    // real part has no such limit, but it also cannot lock up a test run.
    localparam int LINK_LIMIT = 16;
    logic [4:0] link_count;

    // The device ended the phase. Latched because it can arrive while the
    // engine is in the middle of a descriptor fetch, and losing it means the
    // descriptor never completes.
    logic eop_lat;
    // The byte the controller handed over, taken when its request is accepted.
    // It has to be latched: the phase can move on while the memory cycle it
    // belongs to is still outstanding.
    logic [7:0] dev_byte;

    wire [13:0] count = bc[13:0];

    // A byte at physical address A lives in lane A[2:0] of the doubleword at
    // A & ~7, and on this bus lane i is data[63-8i -: 8] guarded by be[7-i].
    // lane_q is the same thing widened, so the indexed part select below has a
    // base expression every tool agrees on.
    wire  [2:0] lane = cbp[2:0];
    wire  [5:0] lane_q = {3'b000, lane};

    integer i;

    always_ff @(posedge clk) begin
        // Held until the arbiter answers - see the port comment above.
        if (dma_ack) dma_req <= 1'b0;
        dev_ack   <= 1'b0;
        dev_reset <= 1'b0;

        if (reset) begin
            cbp <= 32'h0; nbdp <= 32'h0; bc <= 32'h0;
            gio <= 32'h0; dev <= 32'h0;
            dmacfg <= DMACFG_POR; piocfg <= 32'h0;
            ctrl_int <= 1'b0; ctrl_endian <= 1'b0; ctrl_dir <= 1'b0;
            ctrl_active <= 1'b0;
            ctrl_reset  <= 1'b1;      // set on power-on reset, per the spec
            desc_eox <= 1'b0; desc_xie <= 1'b0;
            dstate <= D_IDLE;
            fetch_ptr <= 32'h0;
            link_count <= 5'h0;
            eop_lat <= 1'b0;
            dev_byte <= 8'h0;
            dev_reset <= 1'b0;
            dev_rdata <= 8'h0;
            dma_we <= 1'b0; dma_addr <= 32'h0; dma_wdata <= 64'h0; dma_be <= 8'h0;
        end else begin
            if (dev_eop) eop_lat <= 1'b1;
// One line per cycle of engine state, and the tool that found the held-request
// bug: build with +define+DMA_DEBUG. Silent and free without it.
`ifdef DMA_DEBUG
            if (pio_sel) $display("[DBG] pio sel reg=%h we=%b data=%h", pio_reg, pio_we, pio_wdata);
            if (dstate != D_IDLE || ctrl_active) $display("[DBG] st=%0d act=%b cbp=%h bc=%h nbdp=%h eox=%b devreq=%b dirin=%b", dstate, ctrl_active, cbp, bc, nbdp, desc_eox, dev_req, dev_dir_in);
`endif

            // ---- PIO ------------------------------------------------------
            // The driver is told not to write these while the channel is
            // active, so a PIO write simply wins any race with the engine.
            if (pio_sel && pio_we) begin
                case (pio_reg)
                    R_CBP:  cbp  <= pio_wdata;
                    R_NBDP: nbdp <= pio_wdata;
                    R_BC: begin
                        // The count is read-only to PIO but the flags are not,
                        // and a driver adding to a live chain updates EOX
                        // through this register. IRIS keeps the whole word.
                        bc       <= pio_wdata;
                        desc_eox <= (pio_wdata & DESC_EOX) != 0;
                        desc_xie <= (pio_wdata & DESC_XIE) != 0;
                    end
                    R_CTRL: begin
                        ctrl_endian <= pio_wdata[1];
                        ctrl_dir    <= pio_wdata[2];
                        ctrl_reset  <= pio_wdata[6];
                        // The falling edge, and the only thing that resets the
                        // controller and the SCSI bus behind it.
                        if (ctrl_reset && !pio_wdata[6]) dev_reset <= 1'b1;

                        // ch_active_mask makes this write leave ch_active
                        // alone, so a driver can change dir or endian without
                        // stopping a running transfer.
                        if (!pio_wdata[5]) begin
                            if (pio_wdata[4] && !ctrl_active && !pio_wdata[6]) begin
                                // The go edge. ch_reset must be clear first;
                                // the spec requires it and the PROM obeys.
                                ctrl_active <= 1'b1;
                                fetch_ptr   <= nbdp;
                                link_count  <= 5'h0;
                                eop_lat     <= 1'b0;
                                dstate      <= D_FETCH_LO;
                            end else if (!pio_wdata[4]) begin
                                ctrl_active <= 1'b0;
                                dstate      <= D_IDLE;
                            end
                        end

                        if (pio_wdata[6]) begin
                            // Channel reset: stop, whatever else this write
                            // said.
                            ctrl_active <= 1'b0;
                            dstate      <= D_IDLE;
                        end

                        // FLUSH. There is no fifo to drain, so all this can do
                        // is stop the channel - and it must NOT interrupt. See
                        // the header.
                        if (pio_wdata[3]) begin
                            ctrl_active <= 1'b0;
                            dstate      <= D_IDLE;
                        end
                    end
                    R_GIO:    gio    <= pio_wdata;
                    R_DEV:    dev    <= pio_wdata;
                    R_DMACFG: dmacfg <= pio_wdata;
                    R_PIOCFG: piocfg <= pio_wdata;
                    default: ;
                endcase
            end

            // Reading the control port is how the interrupt is acknowledged.
            // Only a read that actually addressed +0x1004 counts: the CPU's
            // doubleword cycle covers the byte count as well, and clearing the
            // interrupt when a driver reads the count would lose it.
            if (pio_sel && !pio_we && pio_reg == R_CTRL) ctrl_int <= 1'b0;

            // ---- the descriptor engine ------------------------------------
            case (dstate)
                D_IDLE: ;

                D_FETCH_LO: begin
                    dma_req  <= 1'b1;
                    dma_we   <= 1'b0;
                    dma_addr <= {fetch_ptr[31:3], 3'b000};
                    dma_be   <= 8'hFF;
                    dstate   <= D_FETCH_LO_W;
                end

                // Descriptors are quadword aligned, so BP and BC are the two
                // words of one doubleword: BP at +0 is the high half on this
                // big-endian bus, BC at +4 the low half.
                D_FETCH_LO_W:
                    if (dma_ack) begin
                        cbp      <= dma_rdata[63:32];
                        bc       <= dma_rdata[31:0];
                        desc_eox <= dma_rdata[31] ;
                        desc_xie <= dma_rdata[29];
                        dstate   <= D_FETCH_HI;
                    end

                D_FETCH_HI: begin
                    dma_req  <= 1'b1;
                    dma_we   <= 1'b0;
                    dma_addr <= {fetch_ptr[31:3], 3'b000} + 32'd8;
                    dma_be   <= 8'hFF;
                    dstate   <= D_FETCH_HI_W;
                end

                D_FETCH_HI_W:
                    if (dma_ack) begin
                        nbdp   <= dma_rdata[63:32];
                        dstate <= D_EVAL;
                    end

                D_EVAL: begin
                    if (count == 14'd0) begin
                        if (desc_eox) begin
                            // The end of the chain, and the shape every
                            // receive chain ends in - see the header.
                            if (desc_xie) ctrl_int <= 1'b1;
                            dstate <= D_COMPLETE;
                        end else if (link_count == LINK_LIMIT[4:0]) begin
                            dstate <= D_COMPLETE;
                        end else begin
                            // A link. Take the next descriptor without moving
                            // a byte.
                            link_count <= link_count + 5'd1;
                            fetch_ptr  <= nbdp;
                            dstate     <= D_FETCH_LO;
                        end
                    end else begin
                        link_count <= 5'h0;
                        dstate     <= D_RUN;
                    end
                end

                D_RUN: begin
                    if (eop_lat) begin
                        // The target ended the phase with bytes still asked
                        // for - a MODE SENSE answer shorter than the
                        // allocation length does this. The descriptor is
                        // finished either way, which is what IRIS forces with
                        // bc_done on caller_eop for channels 8 and 9.
                        eop_lat <= 1'b0;
                        dstate  <= D_DESC_END;
                    end else if (dev_req) begin
                        dev_byte <= dev_wdata;
                        // The spec says control[2] decides the direction, IRIS
                        // takes it from the phase. The phase wins here: it is
                        // what the target is actually driving, and a driver
                        // that lies about `dir` still has to be right about
                        // the wire. Nothing has been seen to disagree; if
                        // something ever does, `ctrl_dir != !dev_dir_in` in a
                        // waveform is where it will show.
                        dstate <= dev_dir_in ? D_MEM_WR : D_MEM_RD;
                    end
                end

                D_MEM_RD: begin
                    dma_req  <= 1'b1;
                    dma_we   <= 1'b0;
                    dma_addr <= {cbp[31:3], 3'b000};
                    dma_be   <= 8'hFF;
                    dstate   <= D_MEM_RD_W;
                end

                D_MEM_RD_W:
                    if (dma_ack) begin
                        dev_rdata <= dma_rdata[63 - 8*lane_q -: 8];
                        dev_ack   <= 1'b1;
                        dstate    <= D_ADVANCE;
                    end

                D_MEM_WR: begin
                    dma_req  <= 1'b1;
                    dma_we   <= 1'b1;
                    dma_addr <= {cbp[31:3], 3'b000};
                    // The byte goes out on every lane and the byte enable
                    // picks the one that lands.
                    dma_wdata <= {8{dev_byte}};
                    dma_be    <= 8'h80 >> lane;
                    dstate    <= D_MEM_WR_W;
                end

                D_MEM_WR_W:
                    if (dma_ack) begin
                        dev_ack <= 1'b1;
                        dstate  <= D_ADVANCE;
                    end

                // Reached only after a byte has actually moved, so the
                // pointer and count always advance here. An end-of-phase that
                // arrives in the same cycle as the last byte is therefore not
                // able to swallow that byte's advance: it is still latched in
                // eop_lat and D_RUN picks it up on the next pass.
                D_ADVANCE: begin
                    cbp      <= cbp + 32'd1;
                    bc[13:0] <= count - 14'd1;
                    dstate   <= (count == 14'd1) ? D_DESC_END : D_RUN;
                end

                // XIE fires on descriptor completion, whether or not this was
                // the last descriptor in the chain - the two flags are
                // orthogonal and the spec describes them separately.
                D_DESC_END: begin
                    if (desc_xie) ctrl_int <= 1'b1;
                    if (desc_eox) begin
                        dstate <= D_COMPLETE;
                    end else begin
                        fetch_ptr  <= nbdp;
                        link_count <= 5'h0;
                        dstate     <= D_FETCH_LO;
                    end
                end

                D_COMPLETE: begin
                    // "HPC3 will turn ch_active to a '0' when the transfer is
                    // complete."
                    ctrl_active <= 1'b0;
                    dstate      <= D_IDLE;
                end

                default: dstate <= D_IDLE;
            endcase
        end
    end

    // SGI: DDR3 debug beacon tap (docs/29). Pure observation.
    assign dbg_dma = { dstate, ctrl_active, ctrl_int, ctrl_dir,
                       desc_eox, desc_xie, dev_req, dev_ack, dev_dir_in,
                       dev_eop, dma_req, dma_ack, dma_we,
                       bc[15:0], cbp };

endmodule
