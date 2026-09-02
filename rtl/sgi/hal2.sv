//============================================================================
//  hal2 - the Indy's audio processor, its register file.
//
//  WHAT THIS IS AND IS NOT, SAID UP FRONT. This is the register half of HAL2:
//  the five direct registers and the indirect file behind IAR/IDR. It does not
//  move samples and it does not make a sound. Audio on an Indy is three
//  pieces - this file, an HPC3 PBUS DMA channel to feed it, and a sample
//  pipeline out to the DAC - and building them in one go would mean none of
//  them could be tested separately. This one can: THE PROM ALREADY DRIVES IT.
//
//  `sgi_hpc3.sv` returns 0x4010 for HAL2_REV with bit 15 CLEAR, which tells
//  the PROM and the IRIX driver that audio is present, and the PROM's init at
//  0xBFC00BD0 then writes IAR and IDR and spins on ISR bit 0 three times.
//  Until now those writes went into a hole and every read came back zero. They
//  land in real registers now, and the init reads them back.
//
//  THE HAZARD THAT COMES WITH THAT, and it is a boot-stopper rather than a
//  wrong note. ISR bit 0 is TSTATUS, "transaction busy", and the PROM spins on
//  it. This model completes every indirect transaction in the cycle the IAR
//  write lands, so TSTATUS reads 0 always and each spin exits on its first
//  pass. **If TSTATUS is ever made to stick, the boot hangs**, and it will
//  look like the machine died in POST rather than in the audio chip. The
//  comment in sgi_hpc3.sv that bit 15 was buying that risk off is still the
//  right thing to read before changing any of this.
//
//  THE ORACLE IS IRIS's src/hal2.rs. The IAR decode is a type/number/parameter
//  split that no datasheet in reference/specs/ covers, and every constant and
//  every reset value below is that file's. Where a register's reset value
//  looks arbitrary - the Bresenham clocks come up as sel=1, inc=1,
//  modctrl=0xFFFF - it is arbitrary, and it is what IRIS does.
//============================================================================

module hal2 (
    input  logic        clk,
    input  logic        reset,

    // ---- register port ---------------------------------------------------
    // A HAL2 access, already decoded by sgi_hpc3. `regsel` is the register's
    // 0x10-granular index - the chip's registers are 16 bytes apart, so
    // addr[7:4] names one whichever half of the doubleword is addressed.
    input  logic        sel,
    input  logic        we,
    input  logic  [3:0] regsel,
    input  logic [15:0] wdata,
    output logic [15:0] rdata
);

    // ---- direct registers, at 0x10-granular offsets ----------------------
    localparam logic [3:0] R_ISR  = 4'h1;
    localparam logic [3:0] R_REV  = 4'h2;
    localparam logic [3:0] R_IAR  = 4'h3;
    localparam logic [3:0] R_IDR0 = 4'h4;
    localparam logic [3:0] R_IDR1 = 4'h5;
    localparam logic [3:0] R_IDR2 = 4'h6;
    localparam logic [3:0] R_IDR3 = 4'h7;

    // REV. Bit 15 clear means "audio present"; the PROM's node printer splits
    // the rest as (v>>12)&7 . (v>>4)&F . v&F, so 0x4010 prints as 4.1.0 and
    // the "A2" beside it in hinv is a string in the PROM, not a field here.
    // BIT 15 IS SET AGAIN - "no audio present" - since 2026-09-02 (docs/36).
    // With it clear, IRIX's audio.sm probe (exprobe of this register with
    // mask 0x8000) passes and the kernel loads the kdsp_a2 audio driver into
    // mapped kernel space, and that driver runs against a HAL2 with no DMA
    // engine and no sample path behind it. Its timer callback derives the
    // number of samples to move from the DMA position, gets a negative count,
    // and transfer_samps then calls bzero on its ring for ever with interrupts
    // off: the desktop freezes the moment anything plays a sound - the System
    // Shutdown confirmation, the console bell. That was the "shutdown hang"
    // on the board. Absent is honest until the DMA channel and the sample
    // pipeline exist; the PROM then skips its HAL2 init and hinv prints no
    // audio line (tests/run-scsi.sh and run-cdrom.sh stop on the CD-ROM line
    // instead). The register file below stays, ready for when it is 0x4010
    // again.
    localparam logic [15:0] REV_VALUE = 16'hC010;

    // ---- IAR decode ------------------------------------------------------
    // iar[7]    1 = read the indirect register into IDR, 0 = write it from IDR
    // iar[15:12] type      iar[11:8] number      iar[3:2] parameter
    localparam logic [3:0] TYPE_DMA        = 4'h1;   // codec / AES control
    localparam logic [3:0] TYPE_BRES       = 4'h2;   // Bresenham clock generators
    localparam logic [3:0] TYPE_GLOBAL_DMA = 4'h9;   // enable / drive / endian / relay

    localparam logic [3:0] NUM_AES_RX = 4'h2;
    localparam logic [3:0] NUM_AES_TX = 4'h3;
    localparam logic [3:0] NUM_CODECA = 4'h4;
    localparam logic [3:0] NUM_CODECB = 4'h5;

    // ---- state -----------------------------------------------------------
    // Only the three writable ISR bits are stored. TSTATUS and USTATUS are
    // read-only and hardwired low, and there is nothing above bit 4, so
    // keeping a full 16 bits would be twelve flops that can never be read.
    logic  [2:0] isr;      // {CODEC_RESET_N, GLOBAL_RESET_N, CODEC_MODE}
    logic [15:0] iar;
    logic [15:0] idr [0:3];

    // ctrl[0] is CTRL1 (from IDR0); ctrl[1] and ctrl[2] are CTRL2's two
    // halves, which arrive together in IDR0 and IDR1.
    logic [15:0] codeca_ctrl [0:2];
    logic [15:0] codecb_ctrl [0:2];
    logic [15:0] aestx_ctrl  [0:2];
    logic [15:0] aesrx_ctrl  [0:2];

    logic [15:0] bres_sel     [0:2];
    logic [15:0] bres_inc     [0:2];
    logic [15:0] bres_modctrl [0:2];

    logic [15:0] dma_enable, dma_drive, dma_endian, dma_relay;

    // The decode reads the value being WRITTEN to IAR rather than the stored
    // register, because the transaction happens on that write - by the time
    // `iar` holds it the edge has passed. The Bresenham generators are
    // numbered 1..3 in the number field and indexed 0..2 here; anything else
    // is not a clock and is ignored.

    // ISR is read-only in its low two bits and read/write in the three above.
    // TSTATUS and USTATUS are hardwired to zero: every transaction here
    // finishes in the cycle it starts, so there is never one in flight to
    // report. See the header - this is the bit the PROM spins on.
    wire [15:0] isr_rd = {11'h0, isr, 2'b00};

    always_comb begin
        case (regsel)
            R_ISR:   rdata = isr_rd;
            R_REV:   rdata = REV_VALUE;
            R_IAR:   rdata = iar;
            R_IDR0:  rdata = idr[0];
            R_IDR1:  rdata = idr[1];
            R_IDR2:  rdata = idr[2];
            R_IDR3:  rdata = idr[3];
            default: rdata = 16'h0;
        endcase
    end

    integer i;

    always_ff @(posedge clk) begin
        if (reset) begin
            isr        <= 3'h0;
            iar        <= 16'h0;
            dma_enable <= 16'h0;
            dma_drive  <= 16'h0;
            dma_endian <= 16'h0;
            dma_relay  <= 16'h0;
            for (i = 0; i < 4; i = i + 1) idr[i] <= 16'h0;
            for (i = 0; i < 3; i = i + 1) begin
                codeca_ctrl[i] <= 16'h0;
                codecb_ctrl[i] <= 16'h0;
                aestx_ctrl[i]  <= 16'h0;
                aesrx_ctrl[i]  <= 16'h0;
                // IRIS's reset values: 44100 Hz master, inc 1, mod 1 encoded
                // as 1-1-1 = 0xFFFF.
                bres_sel[i]     <= 16'h0001;
                bres_inc[i]     <= 16'h0001;
                bres_modctrl[i] <= 16'hFFFF;
            end
        end else if (sel && we) begin
            case (regsel)
                R_ISR:  isr <= wdata[4:2];
                R_IDR0: idr[0] <= wdata;
                R_IDR1: idr[1] <= wdata;
                R_IDR2: idr[2] <= wdata;
                R_IDR3: idr[3] <= wdata;

                // THE WRITE TO IAR IS THE TRANSACTION. Everything else is a
                // plain register; this one moves data between IDR and the
                // indirect file, in the direction bit 7 selects.
                R_IAR: begin
                    iar <= wdata;
                    if (wdata[7]) begin
                        // read: indirect -> IDR
                        case (wdata[15:12])
                            TYPE_GLOBAL_DMA:
                                case (wdata[3:2])
                                    2'd0: idr[0] <= dma_relay;
                                    2'd1: idr[0] <= dma_enable;
                                    2'd2: idr[0] <= dma_endian;
                                    2'd3: idr[0] <= dma_drive;
                                endcase
                            TYPE_DMA:
                                case (wdata[11:8])
                                    NUM_CODECA:
                                        if (wdata[3:2] == 2'd1) idr[0] <= codeca_ctrl[0];
                                        else if (wdata[3:2] == 2'd2) begin
                                            idr[0] <= codeca_ctrl[1];
                                            idr[1] <= codeca_ctrl[2];
                                        end
                                    NUM_CODECB:
                                        if (wdata[3:2] == 2'd1) idr[0] <= codecb_ctrl[0];
                                        else if (wdata[3:2] == 2'd2) begin
                                            idr[0] <= codecb_ctrl[1];
                                            idr[1] <= codecb_ctrl[2];
                                        end
                                    NUM_AES_TX:
                                        if (wdata[3:2] == 2'd1) idr[0] <= aestx_ctrl[0];
                                        else if (wdata[3:2] == 2'd2) begin
                                            idr[0] <= aestx_ctrl[1];
                                            idr[1] <= aestx_ctrl[2];
                                        end
                                    NUM_AES_RX:
                                        if (wdata[3:2] == 2'd1) idr[0] <= aesrx_ctrl[0];
                                        else if (wdata[3:2] == 2'd2) begin
                                            idr[0] <= aesrx_ctrl[1];
                                            idr[1] <= aesrx_ctrl[2];
                                        end
                                    default: ;
                                endcase
                            TYPE_BRES:
                                if (wdata[11:8] >= 4'd1 && wdata[11:8] <= 4'd3)
                                    case (wdata[3:2])
                                        2'd1: idr[0] <= bres_sel    [wdata[9:8] - 2'd1];
                                        2'd2: idr[0] <= bres_inc    [wdata[9:8] - 2'd1];
                                        2'd3: idr[0] <= bres_modctrl[wdata[9:8] - 2'd1];
                                        default: ;
                                    endcase
                            default: ;
                        endcase
                    end else begin
                        // write: IDR -> indirect
                        case (wdata[15:12])
                            TYPE_GLOBAL_DMA:
                                case (wdata[3:2])
                                    2'd0: dma_relay  <= idr[0];
                                    2'd1: dma_enable <= idr[0];
                                    2'd2: dma_endian <= idr[0];
                                    2'd3: dma_drive  <= idr[0];
                                endcase
                            TYPE_DMA:
                                case (wdata[11:8])
                                    NUM_CODECA:
                                        if (wdata[3:2] == 2'd1) codeca_ctrl[0] <= idr[0];
                                        else if (wdata[3:2] == 2'd2) begin
                                            codeca_ctrl[1] <= idr[0];
                                            codeca_ctrl[2] <= idr[1];
                                        end
                                    NUM_CODECB:
                                        if (wdata[3:2] == 2'd1) codecb_ctrl[0] <= idr[0];
                                        else if (wdata[3:2] == 2'd2) begin
                                            codecb_ctrl[1] <= idr[0];
                                            codecb_ctrl[2] <= idr[1];
                                        end
                                    NUM_AES_TX:
                                        if (wdata[3:2] == 2'd1) aestx_ctrl[0] <= idr[0];
                                        else if (wdata[3:2] == 2'd2) begin
                                            aestx_ctrl[1] <= idr[0];
                                            aestx_ctrl[2] <= idr[1];
                                        end
                                    NUM_AES_RX:
                                        if (wdata[3:2] == 2'd1) aesrx_ctrl[0] <= idr[0];
                                        else if (wdata[3:2] == 2'd2) begin
                                            aesrx_ctrl[1] <= idr[0];
                                            aesrx_ctrl[2] <= idr[1];
                                        end
                                    default: ;
                                endcase
                            TYPE_BRES:
                                if (wdata[11:8] >= 4'd1 && wdata[11:8] <= 4'd3)
                                    case (wdata[3:2])
                                        2'd1: bres_sel    [wdata[9:8] - 2'd1] <= idr[0];
                                        2'd2: bres_inc    [wdata[9:8] - 2'd1] <= idr[0];
                                        2'd3: bres_modctrl[wdata[9:8] - 2'd1] <= idr[0];
                                        default: ;
                                    endcase
                            default: ;
                        endcase
                    end
                end
                default: ;
            endcase
        end
    end

    // Not consumed yet - the DMA channel and the sample path are the next two
    // pieces. Named here so that when they arrive the register file does not
    // have to change shape, and so a reader can see what this holds for them.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [15:0] unused_cfg = dma_enable | dma_drive | dma_endian | dma_relay
                           | codeca_ctrl[0] | codecb_ctrl[0]
                           | aestx_ctrl[0]  | aesrx_ctrl[0]
                           | bres_sel[0] | bres_inc[0] | bres_modctrl[0];
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
