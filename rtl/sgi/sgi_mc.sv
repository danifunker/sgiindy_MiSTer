//============================================================================
//  sgi_mc - the IP22/IP24 Memory Controller register file.
//
//  Everything here comes from the MC chip specification (reference/specs/
//  mc.pdf), cross-checked against IRIS's src/mc.rs and against what the PROM
//  actually does at 0xBFC003C0. Where the spec and the PROM's own annotated
//  disassembly disagreed, the spec won and the disassembly's register names
//  turned out to be shifted by one slot; docs/02-address-map.md records that.
//
//  REGISTER ADDRESSING - the thing to get right first.
//
//  MC registers are architecturally 64 bits and the chip is wired to the
//  LEAST significant 32 bits of the R4000's SysAD bus, so every register
//  answers at two addresses and which one is correct depends on the CPU's
//  endian mode. The spec is explicit: "If the processor is running in big
//  endian mode the odd word addresses, (addresses that end in 4 and 0xc), are
//  used." Big-endian is the only mode this machine runs in, so the register
//  at offset X is read and written at X+4, and that is the half this module
//  drives. On this core's doubleword bus that is `rdata[31:0]`.
//
//  A big-endian access to X+0 is not simply "the other half": the real MC
//  raises the ADDR bit in CPU_ERROR_STAT for it ("the address for a MC
//  register read or write was not correct for MC's endian mode"). This model
//  returns zero there instead of raising an error, because a spurious bus
//  error during bring-up is a far worse trap than a zero, and the PROM never
//  does it - all 190-odd MC references in the image end in 4 or 0xc.
//
//  WHAT IS NOT HERE YET: the GIO64 DMA engine. Its registers exist and hold
//  what is written to them, and a start completes instantly, but no data
//  moves. See the DMA section below - that is the next piece of M2.
//============================================================================

module sgi_mc #(
    // SYSID. Bits [3:0] are the MC revision (spec: 0 = Rev A, 1 = Rev B) and
    // bit 4 is "EISA bus present, determined by the eisa_present_n pin".
    //
    // 0x13 is what IRIS reports and what MAME's mc.cpp hardcodes: revision 3
    // (Rev C, later than the spec's table), with the EISA bit set. On an Indy
    // there is no EISA bus, so the spec would have that bit clear - but IRIS
    // sets it deliberately because the IRIX 5.3 vino driver gates its whole
    // probe on it and silently gives up when it is clear. The PROM only ever
    // reads bits [3:0] (setup_regs at 0xBFC01B08 and 0xBFC0AB64, both mask
    // with 0xF), and both branch on `rev < 5`, so the revision is free; the
    // EISA bit only starts mattering under IRIX. Matching IRIS keeps a golden
    // -log diff against it clean.
    parameter logic [31:0] SYSID_VALUE = 32'h0000_0013,

    // GIO64_ARB. Indy is a single-GIO64-bus machine, so ONE_GIO is set; bit 0
    // is HPC_SIZE. The PROM overwrites this with 0x401 in realstart anyway.
    parameter logic [31:0] GIO64_ARB_RESET = 32'h0000_0400,

    // Power-on MEMCFG0/1. The spec's reset value is zero - every bank invalid,
    // to be filled in by POST - and that is right for a PROM boot. A core
    // running a bare-metal image with no PROM has nothing to fill them in, so
    // the top level overrides MEMCFG0 with the bank it actually has. See
    // sgi_indy.sv's MEMCFG0_POR.
    parameter logic [31:0] MEMCFG0_RESET = 32'h0000_0000,
    parameter logic [31:0] MEMCFG1_RESET = 32'h0000_0000
)(
    input  logic        clk,
    input  logic        reset,
    // Clock enable, shared with the CPU. The RPSS divider is specified in CPU
    // clocks, so it has to advance at the CPU's rate and not the raw clk rate.
    input  logic        ce,

    // ---- register port ---------------------------------------------------
    input  logic        sel,          // one-cycle request pulse, address in window
    input  logic        we,
    input  logic [16:0] addr,         // offset into the 128 KB window, 8-aligned
    input  logic  [7:0] be,
    input  logic [63:0] wdata,
    output logic [63:0] rdata,
    output logic        ack,

    // ---- serial EEPROM pins ---------------------------------------------
    output logic        ee_cs,
    output logic        ee_sk,
    output logic        ee_di,
    input  logic        ee_do,

    // ---- what the rest of the machine needs to see -----------------------
    // Bank descriptors, for a memory decoder that follows what the PROM
    // programmed rather than a hardwired map. Nothing consumes these yet.
    output logic [31:0] memcfg0,
    output logic [31:0] memcfg1,

    // ---- the GIO64 DMA engine's bus master -------------------------------
    // Same byte-lane convention as every other master here: `wdata[63-8i -: 8]`
    // is the byte at `addr+i` and `be[7-i]` guards it. Held until `ack`.
    output logic        dma_m_req,
    output logic        dma_m_we,
    output logic [31:0] dma_m_addr,
    output logic [63:0] dma_m_wdata,
    output logic  [7:0] dma_m_be,
    input  logic        dma_m_ack
);

    // ---- register offsets, verbatim from the MC spec's table -------------
    localparam logic [16:0] REG_CPUCTRL0       = 17'h00000;
    localparam logic [16:0] REG_CPUCTRL1       = 17'h00008;
    localparam logic [16:0] REG_DOG            = 17'h00010;  // DOGC read / DOGR write
    localparam logic [16:0] REG_SYSID          = 17'h00018;
    localparam logic [16:0] REG_RPSS_DIVIDER   = 17'h00028;
    localparam logic [16:0] REG_EEROM          = 17'h00030;
    localparam logic [16:0] REG_CTRLD          = 17'h00040;
    localparam logic [16:0] REG_REF_CTR        = 17'h00048;
    localparam logic [16:0] REG_GIO64_ARB      = 17'h00080;
    localparam logic [16:0] REG_CPU_TIME       = 17'h00088;
    localparam logic [16:0] REG_LB_TIME        = 17'h00098;
    localparam logic [16:0] REG_MEMCFG0        = 17'h000C0;
    localparam logic [16:0] REG_MEMCFG1        = 17'h000C8;
    localparam logic [16:0] REG_CPU_MEMACC     = 17'h000D0;
    localparam logic [16:0] REG_GIO_MEMACC     = 17'h000D8;
    localparam logic [16:0] REG_CPU_ERROR_ADDR = 17'h000E0;
    localparam logic [16:0] REG_CPU_ERROR_STAT = 17'h000E8;
    localparam logic [16:0] REG_GIO_ERROR_ADDR = 17'h000F0;
    localparam logic [16:0] REG_GIO_ERROR_STAT = 17'h000F8;
    localparam logic [16:0] REG_SYS_SEMAPHORE  = 17'h00100;
    localparam logic [16:0] REG_LOCK_MEMORY    = 17'h00108;
    localparam logic [16:0] REG_EISA_LOCK      = 17'h00110;
    localparam logic [16:0] REG_DMA_GIO_MASK   = 17'h00150;
    localparam logic [16:0] REG_DMA_GIO_SUB    = 17'h00158;
    localparam logic [16:0] REG_DMA_CAUSE      = 17'h00160;
    localparam logic [16:0] REG_DMA_CTL        = 17'h00168;
    localparam logic [16:0] REG_RPSS_CTR       = 17'h01000;
    localparam logic [16:0] REG_DMA_MEMADR     = 17'h02000;
    localparam logic [16:0] REG_DMA_MEMADRD    = 17'h02008;
    localparam logic [16:0] REG_DMA_SIZE       = 17'h02010;
    localparam logic [16:0] REG_DMA_STRIDE     = 17'h02018;
    localparam logic [16:0] REG_DMA_GIO_ADR    = 17'h02020;
    localparam logic [16:0] REG_DMA_GIO_ADRS   = 17'h02028;
    localparam logic [16:0] REG_DMA_MODE       = 17'h02030;
    localparam logic [16:0] REG_DMA_COUNT      = 17'h02038;
    localparam logic [16:0] REG_DMA_STDMA      = 17'h02040;
    localparam logic [16:0] REG_DMA_RUN        = 17'h02048;
    localparam logic [16:0] REG_DMA_MEMADRDS   = 17'h02070;

    // DMA_CAUSE / DMA_RUN bits, from vdma.pdf.
    localparam logic [31:0] DMA_CAUSE_COMPLETE = 32'h0000_0008;
    localparam logic [31:0] DMA_RUN_RUNNING    = 32'h0000_0040;

    // ---- the registers ---------------------------------------------------
    logic [31:0] cpuctrl0, cpuctrl1, rpss_div, eerom;
    logic [31:0] ctrld, ref_ctr, gio64_arb, cpu_time, lb_time;
    logic [31:0] cpu_memacc, gio_memacc;
    logic [31:0] cpu_err_addr, cpu_err_stat, gio_err_addr, gio_err_stat;
    logic [31:0] lock_memory, eisa_lock;
    logic [31:0] dma_gio_mask, dma_gio_sub, dma_cause, dma_ctl;
    logic [31:0] dma_tlb  [0:7];        // entry n hi at 2n, lo at 2n+1
    logic [31:0] dma_memadr, dma_size, dma_stride, dma_gio_adr;
    logic [31:0] dma_mode, dma_count, dma_stdma, dma_run;

    // START IS DELAYED BY ONE CYCLE ON PURPOSE. All three start registers also
    // WRITE part of the descriptor - GIO_ADRS carries the fill value, MEMADRDS
    // rewrites five registers - and those writes land on the same edge the
    // engine would latch on. Sampling a cycle later is what makes the engine
    // see the descriptor the CPU just wrote rather than the one before it.
    logic dma_start_q, dma_busy, dma_done, dma_mode_unsup;
    wire  dma_start_now = wr_lo && !sem_sel && !tlb_sel
                       && (addr == REG_DMA_GIO_ADRS
                           || (addr == REG_DMA_STDMA && wr_word[0])
                           || addr == REG_DMA_MEMADRDS);

    mc_gio_dma u_gio_dma (
        .clk              (clk),
        .reset            (reset),
        .start            (dma_start_q),
        .d_memadr         (dma_memadr),
        .d_size           (dma_size),
        .d_stride         (dma_stride),
        .d_gio_adr        (dma_gio_adr),
        .d_mode           (dma_mode),
        .d_count          (dma_count),
        .d_ctl            (dma_ctl),
        .busy             (dma_busy),
        .done             (dma_done),
        .mode_unsupported (dma_mode_unsup),
        .m_req            (dma_m_req),
        .m_we             (dma_m_we),
        .m_addr           (dma_m_addr),
        .m_wdata          (dma_m_wdata),
        .m_be             (dma_m_be),
        .m_ack            (dma_m_ack)
    );
    logic [31:0] rpss_ctr;
    logic [19:0] dogc;
    logic        sys_semaphore;
    logic [15:0] user_semaphore;

    // The DMA TLB occupies 0x180..0x1BF as four hi/lo pairs on a stride of
    // 0x10; index it rather than naming eight registers. 0x180 >> 6 == 6 and
    // 0x1BF >> 6 == 6, so the top bits alone select the whole block.
    wire        tlb_sel = (addr[16:6] == 11'h006);
    wire  [2:0] tlb_idx = addr[5:3];

    // Sixteen user semaphores, one per 4 KB page from 0x10000 (spec 5.18).
    wire        sem_sel = addr[16] && (addr[11:0] == 12'h000);
    wire  [3:0] sem_idx = addr[15:12];

    //------------------------------------------------------------------
    // Read mux
    //------------------------------------------------------------------
    // Combinational, because a write with only some byte enables set has to
    // merge against the register's current value, and this is where that
    // value comes from.
    logic [31:0] rd_word;

    always_comb begin
        rd_word = 32'h0000_0000;
        if (sem_sel)      rd_word = {31'h0, user_semaphore[sem_idx]};
        else if (tlb_sel) rd_word = dma_tlb[tlb_idx];
        else case (addr)
            REG_CPUCTRL0:       rd_word = cpuctrl0;
            REG_CPUCTRL1:       rd_word = cpuctrl1;
            REG_DOG:            rd_word = {12'h0, dogc};
            REG_SYSID:          rd_word = SYSID_VALUE;
            REG_RPSS_DIVIDER:   rd_word = rpss_div;
            // Only five bits exist. Bit 4 is SI, driven by the part, and the
            // rest read back what was last written - which is what makes the
            // PROM's read-modify-write bit-bang work.
            REG_EEROM:          rd_word = {27'h0, ee_do, eerom[3:0]};
            REG_CTRLD:          rd_word = ctrld;
            REG_REF_CTR:        rd_word = ref_ctr;
            REG_GIO64_ARB:      rd_word = gio64_arb;
            REG_CPU_TIME:       rd_word = cpu_time;
            REG_LB_TIME:        rd_word = lb_time;
            REG_MEMCFG0:        rd_word = memcfg0;
            REG_MEMCFG1:        rd_word = memcfg1;
            REG_CPU_MEMACC:     rd_word = cpu_memacc;
            REG_GIO_MEMACC:     rd_word = gio_memacc;
            REG_CPU_ERROR_ADDR: rd_word = cpu_err_addr;
            REG_CPU_ERROR_STAT: rd_word = cpu_err_stat;
            REG_GIO_ERROR_ADDR: rd_word = gio_err_addr;
            REG_GIO_ERROR_STAT: rd_word = gio_err_stat;
            REG_SYS_SEMAPHORE:  rd_word = {31'h0, sys_semaphore};
            REG_LOCK_MEMORY:    rd_word = lock_memory;
            REG_EISA_LOCK:      rd_word = eisa_lock;
            REG_DMA_GIO_MASK:   rd_word = dma_gio_mask;
            REG_DMA_GIO_SUB:    rd_word = dma_gio_sub;
            REG_DMA_CAUSE:      rd_word = dma_cause;
            REG_DMA_CTL:        rd_word = dma_ctl;
            REG_RPSS_CTR:       rd_word = rpss_ctr;
            REG_DMA_MEMADR,
            REG_DMA_MEMADRD,
            REG_DMA_MEMADRDS:   rd_word = dma_memadr;
            REG_DMA_SIZE:       rd_word = dma_size;
            REG_DMA_STRIDE:     rd_word = dma_stride;
            REG_DMA_GIO_ADR,
            REG_DMA_GIO_ADRS:   rd_word = dma_gio_adr;
            REG_DMA_MODE:       rd_word = dma_mode;
            REG_DMA_COUNT:      rd_word = dma_count;
            REG_DMA_STDMA:      rd_word = dma_stdma;
            REG_DMA_RUN:        rd_word = dma_run;
            default:            rd_word = 32'h0000_0000;
        endcase
    end

    // Byte-granular merge. The PROM only ever uses sw here, but a device that
    // silently widened a byte store into a word store would be a bug waiting
    // for the first driver that does one.
    logic [31:0] wr_word;
    always_comb
        for (int b = 0; b < 4; b++)
            // be[7-i] guards the byte at addr+i, and the low word is at +4,
            // so byte b of the word (MSB first) is guarded by be[3-b].
            wr_word[24 - 8*b +: 8] = be[3-b] ? wdata[24 - 8*b +: 8]
                                             : rd_word[24 - 8*b +: 8];

    wire wr_lo = sel &&  we && (|be[3:0]);   // the big-endian half - see header
    wire rd_lo = sel && !we;

    //------------------------------------------------------------------
    // EEPROM pins
    //------------------------------------------------------------------
    // Bit assignment confirmed against the PROM's own bit-bang routines:
    // 0xBFC0A83C sets bit 1 then bit 2 to open a transfer, 0xBFC0A89C sets and
    // clears bit 3 per data bit and pulses bit 2 around it, and 0xBFC0A99C
    // samples bit 4 for the reply.
    assign ee_cs = eerom[1];
    assign ee_sk = eerom[2];
    assign ee_di = eerom[3];

    //------------------------------------------------------------------
    // Free-running counters
    //------------------------------------------------------------------
    // RPSS_CTR is the counter the PROM's DELAY() and calibrate_delay() spin
    // on, and the first thing in realstart that needs a chipset at all: at
    // 0xBFC00500 it samples the counter and waits for it to advance by 0x271
    // before touching anything else. A counter that does not count hangs the
    // machine there, before a single character reaches the console.
    //
    // The divider is exactly as specified: DIV (bits 7:0) is "the amount to
    // divide the CPU minus one", INC (bits 15:8) is what to add on each tick.
    // The PROM writes 0x104 - divide by five, increment by one - which the
    // spec gives as the setting for a 50 MHz processor, i.e. one count per
    // 100 ns. That is a statement about this core's intended clock: the R4000
    // SysAD bus on these machines is 50 MHz, and this is the register that
    // says so.
    wire [7:0] rpss_div_field = rpss_div[7:0];
    wire [7:0] rpss_inc_field = rpss_div[15:8];
    logic [7:0] rpss_tick;

    // The refresh counter counts down from CTRLD and reloads; each wrap is one
    // refresh burst, and the watchdog counts bursts. Nothing in the PROM reads
    // either, but they are cheap and a stuck REF_CTR would be a confusing
    // thing to discover later.
    wire ref_wrap = (ref_ctr == 32'h0);

    //------------------------------------------------------------------
    always_ff @(posedge clk) begin
        ack   <= 1'b0;
        rdata <= 64'h0;

        if (reset) begin
            // Reset values are the spec's, register by register (section 5.x
            // "Reset Value" columns); IRIS's init_registers agrees on every
            // one of them.
            cpuctrl0       <= 32'h0010_0012;   // REFS=2, RFE=1, MUX_HWM=1
            cpuctrl1       <= 32'h0000_000C;   // MC_HWM=0xC
            dogc           <= 20'h0;
            rpss_div       <= 32'h0000_0104;   // divide by 5, increment by 1
            eerom          <= 32'h0;
            ctrld          <= 32'h0000_0C30;
            ref_ctr        <= 32'h0000_0C30;
            gio64_arb      <= GIO64_ARB_RESET;
            cpu_time       <= 32'h0000_0100;
            lb_time        <= 32'h0000_0200;
            memcfg0        <= MEMCFG0_RESET;
            memcfg1        <= MEMCFG1_RESET;
            cpu_memacc     <= 32'h0145_4333;
            gio_memacc     <= 32'h0000_4333;
            cpu_err_addr   <= 32'h0;
            cpu_err_stat   <= 32'h0;
            gio_err_addr   <= 32'h0;
            gio_err_stat   <= 32'h0;
            lock_memory    <= 32'h0000_0001;   // LOCK_N reset 1 = unlocked
            eisa_lock      <= 32'h0000_0001;
            dma_gio_mask   <= 32'h0;
            dma_gio_sub    <= 32'h0;
            dma_cause      <= 32'h0;
            dma_ctl        <= 32'h0;
            dma_memadr     <= 32'h0;
            dma_size       <= 32'h0;
            dma_stride     <= 32'h0;
            dma_gio_adr    <= 32'h0;
            dma_mode       <= 32'h0;
            dma_count      <= 32'h0;
            dma_stdma      <= 32'h0;
            dma_run        <= 32'h0;
            rpss_ctr       <= 32'h0;
            rpss_tick      <= 8'h0;
            sys_semaphore  <= 1'b0;
            user_semaphore <= 16'h0;
            for (int k = 0; k < 8; k++) dma_tlb[k] <= 32'h0;
        end else begin
            //---------------- timers ----------------
            if (ce) begin
                if (rpss_tick >= rpss_div_field) begin
                    rpss_tick <= 8'h0;
                    rpss_ctr  <= rpss_ctr + {24'h0, rpss_inc_field};
                end else begin
                    rpss_tick <= rpss_tick + 8'h1;
                end

                if (ref_wrap) begin
                    ref_ctr <= ctrld;
                    dogc    <= dogc + 20'h1;
                end else begin
                    ref_ctr <= ref_ctr - 32'h1;
                end
            end

            //---------------- reads with side effects ----------------
            if (rd_lo) begin
                // A semaphore read returns the bit and sets it: this is the
                // machine's only atomic test-and-set primitive (spec 5.18).
                if (sem_sel)                        user_semaphore[sem_idx] <= 1'b1;
                else if (addr == REG_SYS_SEMAPHORE) sys_semaphore           <= 1'b1;
            end

            //---------------- writes ----------------
            if (wr_lo) begin
                if (sem_sel) begin
                    user_semaphore[sem_idx] <= wr_word[0];
                end else if (tlb_sel) begin
                    dma_tlb[tlb_idx] <= wr_word;
                end else case (addr)
                    REG_CPUCTRL0:     cpuctrl0    <= wr_word;
                    REG_CPUCTRL1:     cpuctrl1    <= wr_word;
                    REG_DOG:          dogc        <= 20'h0;   // DOGR: any write clears
                    REG_SYSID:        ;                       // read-only
                    REG_RPSS_DIVIDER: rpss_div    <= wr_word;
                    REG_EEROM:        eerom       <= wr_word;
                    REG_CTRLD:        ctrld       <= wr_word;
                    REG_REF_CTR:      ref_ctr     <= wr_word;
                    REG_GIO64_ARB:    gio64_arb   <= wr_word;
                    REG_CPU_TIME:     cpu_time    <= wr_word;
                    REG_LB_TIME:      lb_time     <= wr_word;
                    REG_MEMCFG0:      memcfg0     <= wr_word;
                    REG_MEMCFG1:      memcfg1     <= wr_word;
                    REG_CPU_MEMACC:   cpu_memacc  <= wr_word;
                    REG_GIO_MEMACC:   gio_memacc  <= wr_word;
                    REG_CPU_ERROR_ADDR: cpu_err_addr <= wr_word;
                    // CLR_ERROR_STAT shares the address: any write clears the
                    // status, and the address register with it, so the pair
                    // can latch the next error (spec 5.15/5.17).
                    REG_CPU_ERROR_STAT: begin
                        cpu_err_stat <= 32'h0;
                        cpu_err_addr <= 32'h0;
                    end
                    REG_GIO_ERROR_ADDR: gio_err_addr <= wr_word;
                    REG_GIO_ERROR_STAT: begin
                        gio_err_stat <= 32'h0;
                        gio_err_addr <= 32'h0;
                    end
                    REG_SYS_SEMAPHORE: sys_semaphore <= wr_word[0];
                    REG_LOCK_MEMORY:   lock_memory   <= wr_word;
                    REG_EISA_LOCK:     eisa_lock     <= wr_word;
                    REG_RPSS_CTR:      ;                      // read-only
                    REG_DMA_GIO_MASK:  dma_gio_mask  <= wr_word;
                    REG_DMA_GIO_SUB:   dma_gio_sub   <= wr_word;
                    REG_DMA_CAUSE:     dma_cause     <= wr_word;
                    REG_DMA_CTL:       dma_ctl       <= wr_word;

                    //-------- GIO64 DMA engine --------
                    // STUB. The registers behave, and every "start" address
                    // reports an instantly-finished transfer, but nothing is
                    // copied. That is deliberate: the alternative stub - never
                    // asserting DMA_RUN - wedges the PROM in a poll, whereas
                    // this one lets it run on and report the memory it finds,
                    // which is the more useful failure to look at. The real
                    // engine needs a bus master and is the next piece of M2.
                    REG_DMA_MEMADR:    dma_memadr <= wr_word;
                    REG_DMA_SIZE: begin
                        dma_size  <= wr_word;
                        dma_count <= {dma_count[31:16], wr_word[15:0]};
                    end
                    REG_DMA_STRIDE: begin
                        dma_stride <= wr_word;
                        dma_count  <= {6'h0, wr_word[25:16], dma_count[15:0]};
                    end
                    REG_DMA_GIO_ADR:   dma_gio_adr <= wr_word;
                    REG_DMA_MODE:      dma_mode    <= wr_word;
                    REG_DMA_COUNT:     dma_count   <= wr_word;
                    REG_DMA_MEMADRD: begin
                        dma_memadr <= wr_word;
                        dma_size   <= 32'h0001_000C;
                        dma_stride <= 32'h0001_0000;
                        dma_count  <= 32'h0001_000C;
                        dma_mode   <= 32'h0000_0008;   // FILL
                    end
                    // The three start registers only write their own fields
                    // now. `dma_start_now` above decodes the same three and
                    // the engine reports completion for itself.
                    REG_DMA_GIO_ADRS:  dma_gio_adr <= wr_word;
                    REG_DMA_STDMA:     dma_stdma   <= wr_word;
                    REG_DMA_MEMADRDS: begin
                        dma_memadr <= wr_word;
                        dma_size   <= 32'h0001_000C;
                        dma_stride <= 32'h0001_0000;
                        dma_count  <= 32'h0001_000C;
                        dma_mode   <= 32'h0000_0008;
                    end
                    REG_DMA_RUN:       ;                      // read-only
                    default:           ;
                endcase
            end

            // DMA_RUN NOW MEANS WHAT IT SAYS. It used to latch "running" on a
            // start and clear on the read that observed it, because the engine
            // was a stub that finished instantly and would otherwise never be
            // seen to have started at all. There is a real engine behind it
            // now, so the bit is set while it is busy and cleared when it is
            // done, and the PROM's poll waits for an actual transfer.
            if (dma_start_q) dma_run <= dma_run | DMA_RUN_RUNNING;
            if (dma_done) begin
                dma_run   <= dma_run & ~DMA_RUN_RUNNING;
                dma_cause <= dma_cause | DMA_CAUSE_COMPLETE;
            end
            // A start written while the previous transfer is still finishing
            // wins, which is why this sits after the two above.
            dma_start_q <= dma_start_now && !dma_busy;

            //---------------- response ----------------
            if (sel) begin
                rdata <= {32'h0000_0000, rd_word};
                ack   <= 1'b1;
            end
        end
    end

endmodule
