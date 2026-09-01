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
//    0x08000000-0x17FFFFFF  low local memory   } wherever MEMCFG0/1 place the
//    0x20000000-0x2FFFFFFF  high local memory  } banks inside these windows
//    0x1F000000-0x1F0FFFFF  Newport graphics - not fitted, reads 0
//    0x1F400000-0x1F5FFFFF  GIO64 expansion slot 0
//    0x1FA00000-0x1FA1FFFF  MC, the memory and GIO64 arbiter controller
//    0x1FB80000-0x1FBFFFFF  HPC3, as far as sgi_hpc3.sv claims it
//    0x1FBE0000-0x1FBE7FFF  DS1386 RTC and NVRAM (HPC3's bbram window)
//    0x1FBD9800-0x1FBD98FF  IOC2 and INT2, with the SCC at +0x30..+0x3F
//                           (inside HPC3's window: PBUS PIO channel 6,
//                           decoded ahead of it)
//    0x1FC00000-0x1FC7FFFF  boot PROM
//
//  Anything else answers as an unclaimed bus cycle and raises `bus_unclaimed`
//  for one cycle so the harness can log it. On real hardware an unclaimed
//  GIO cycle times out into a bus error; wiring that to the CPU is an
//  interrupt-era job, not a bring-up one.
//============================================================================

module sgi_indy #(
    // Power-on default only; the live size arrives on mem_mb below. Kept as a
    // parameter because MEMCFG0_POR has to be a constant.
    parameter int MEM_MB = 64,
    // System clocks per RTC centisecond. 500000 is real time at the 50 MHz
    // R4000 bus clock the MC's RPSS divider implies. Simulation overrides it
    // for the same reason it runs the SCC's serial clock fast: the PROM waits
    // for the seconds register to roll over during boot, and at the true ratio
    // that one wait is fifty million clocks of nothing happening.
    parameter int RTC_TICK_DIV = 500_000,
    // System clocks per count of IOC2's 8254 timer. 50 is the 1 MHz the PROM's
    // calibrate_delay assumes, so one count is one microsecond. Simulation
    // shortens it, which shortens every DELAY() proportionally - see sim_top.sv.
    parameter int PIT_TICK_DIV = 50
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

    // Primary caches. Sampled continuously, not only at reset - cpu.vhd
    // gates on them per access - so clearing one mid-run leaves whatever it
    // already holds valid but unread, which is exactly what is wanted for
    // bisecting a failure onto one of them. Both are on for a normal build.
    input  logic        icache_en,
    input  logic        dcache_en,

    // ---- SCSI block device ----------------------------------------------
    // One hps_io slot per target. On hardware these come from the HPS; in
    // simulation from sim_blkdevice.
    input  logic  [6:0] scsi_img_mounted,
    input  logic [31:0] scsi_img_blocks,
    output logic [31:0] scsi_sd_lba,
    output logic  [6:0] scsi_sd_rd,
    output logic  [6:0] scsi_sd_wr,
    input  logic  [6:0] scsi_sd_ack,
    input  logic  [7:0] scsi_sd_buff_addr,
    input  logic [15:0] scsi_sd_buff_dout,
    output logic [15:0] scsi_sd_buff_din,

    // Megabytes of DRAM actually fitted. Drives the MC's bank decode; on
    // hardware this is a constant and folds away.
    input  logic [31:0] mem_mb,
    input  logic        scsi_sd_buff_wr,

    // ---- host input devices ---------------------------------------------
    // MiSTer's decoded PS/2 forms, straight from hps_io. Both are edge-coded
    // on their top bit; i8042.sv turns them back into what a PC keyboard and
    // mouse put on the wire.
    input  logic [10:0] ps2_key,
    input  logic [24:0] ps2_mouse,

    // ---- the machine's Ethernet address ---------------------------------
    // Not a parameter, because it has to differ per board. sgiindy.sv latches
    // it from the file MiSTer uploads at ioctl index 0x40; sgi_ds1386.sv
    // seeds it into the NVRAM at reset, which is where the PROM reads it to
    // build `eaddr`. See eeprom_93c56.sv for why a machine without one
    // panics the IRIX installer.
    input  logic [47:0] mac_addr,

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

    // Whether a graphics board is fitted. A real Indy always has one, and on
    // hardware this is tied high; the harness can clear it because the PROM
    // moves its console to the graphics head the moment it finds Newport, and
    // every serial-console regression in tests/ would otherwise be testing a
    // machine that has stopped talking to it. A board-less Indy is a real
    // configuration, not a fiction - it is what every boot log in this
    // repository before now was showing.
    input  logic        gfx_present,

    // Takes CMAP out of the pixel path so the frame buffer's index shows
    // directly. A bring-up instrument; see rtl/newport/newport.sv.
    input  logic        dbg_raw_index,

    // ---- Newport's frame buffer -----------------------------------------
    // Two ports, because the frame buffer is VRAM: the rasteriser owns the
    // random port and the display owns the serial one, and they run at the
    // same time. See rtl/newport/newport.sv.
    output logic        fbw_req,
    output logic        fbw_we,
    output logic [31:0] fbw_addr,
    output logic [63:0] fbw_wdata,
    output logic  [7:0] fbw_be,
    input  logic [63:0] fbw_rdata,
    input  logic        fbw_ack,
    output logic        fbr_req,
    output logic [31:0] fbr_addr,
    input  logic [63:0] fbr_rdata,
    input  logic        fbr_ack,

    // ---- video out -------------------------------------------------------
    output logic        vid_ce_pix,
    output logic        vid_hsync,
    output logic        vid_vsync,
    output logic        vid_de,
    output logic  [7:0] vid_r,
    output logic  [7:0] vid_g,
    output logic  [7:0] vid_b,

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
    // WHO ANSWERED. A write main memory took and a write that was dropped
    // because MEMCFG has no bank covering it are the same three signals on
    // the tap above - same address, same data, same ack - and only the second
    // one is a lost store. `bus_mem_o` says the RAM model took the cycle;
    // `bus_hole_o` says sgi_memmap declined it and it was retired here with
    // zeros. Observability only; nothing on hardware reads either.
    output logic        bus_mem_o,
    output logic        bus_hole_o,
    output logic  [5:0] cpu_error,
    output logic  [4:0] irq_lines_o,   // Cause.IP[6:2], as INT2 drives them
    output logic [39:0] int2_state_o,  // see sgi_ioc.sv
    // The CPU's decode-stage PC and a strobe. See rtl/cpu/r4300/cpu.vhd's
    // dbg_pc: it is the only view of what the CPU is doing when the failure
    // stops producing bus cycles, which is what an IRIX kernel wedged in a
    // cached loop looks like.
    output logic [31:0] dbg_pc,
    output logic        dbg_pc_valid,
    output logic  [3:0] dbg_mode,
    output logic        dbg_exc,
    output logic  [4:0] dbg_exc_code,
    output logic [31:0] dbg_exc_epc,
    output logic [31:0] dbg_exc_bad,
    output logic [31:0] dbg_rpc,
    output logic        dbg_retire
);

    localparam logic [31:0] RAM_BASE   = 32'h0800_0000;   // low local memory
    localparam logic [31:0] RAM_SIZE   = MEM_MB * 32'h0010_0000;
    localparam logic [31:0] LOMEM_END  = 32'h1800_0000;   // 256 MB of it
    localparam logic [31:0] HIMEM_BASE = 32'h2000_0000;
    localparam logic [31:0] HIMEM_END  = 32'h3000_0000;
    localparam logic [31:0] ALIAS_SIZE = 32'h0008_0000;   // 512 KB

    // Power-on MEMCFG0: bank 0 valid, single subbank, MEM_MB of SIMMs based at
    // 0x08000000 (base field 0x20 = address bits [29:22]). The real MC comes
    // out of reset with every bank invalid and the PROM's POST fills them in -
    // and it still does here, because init_memconfig zeroes both registers
    // before it starts probing. This value exists for the other way the core
    // is used: a bare-metal image loaded straight into RAM with no PROM, which
    // has to find memory already mapped or its first instruction fetch lands
    // in a hole. IRIS solves the same problem with MemoryController::
    // post_map_banks(), just later.
    localparam logic [15:0] MEMCFG0_BANK0 =
        16'h2000 | (16'((MEM_MB / 4) - 1) << 8) | 16'h0020;
    localparam logic [31:0] MEMCFG0_POR = {MEMCFG0_BANK0, 16'h0000};
    localparam logic [31:0] GFX_BASE   = 32'h1F00_0000;
    localparam logic [31:0] GFX_SIZE   = 32'h0010_0000;   // VC2/XMAP/DAC + REX3
    localparam logic [31:0] GIO0_BASE  = 32'h1F40_0000;
    localparam logic [31:0] GIO0_SIZE  = 32'h0020_0000;
    localparam logic [31:0] MC_BASE    = 32'h1FA0_0000;
    localparam logic [31:0] MC_SIZE    = 32'h0002_0000;   // 128 KB
    localparam logic [31:0] HPC3_BASE  = 32'h1FB8_0000;
    localparam logic [31:0] HPC3_SIZE  = 32'h0008_0000;   // 512 KB
    localparam logic [31:0] RTC_BASE   = 32'h1FBE_0000;
    localparam logic [31:0] RTC_SIZE   = 32'h0000_8000;   // 8 KB at stride 4
    localparam logic [31:0] IOC_BASE   = 32'h1FBD_9800;
    // WD33C93B controller 0. The PROM's descriptor table at 0xBFC7B410 puts
    // the address port at 0x1FBC0003 and the data port at 0x1FBC0007, i.e.
    // the low bytes of the two words at the base. Controller 1 lives at
    // 0x1FBC8000 and is not fitted.
    localparam logic [31:0] SCSI0_BASE = 32'h1FBC_0000;
    localparam logic [31:0] SCSI0_SIZE = 32'h0000_0008;
    localparam logic [31:0] IOC_SIZE   = 32'h0000_0100;
    localparam logic [31:0] PROM_BASE  = 32'h1FC0_0000;
    localparam logic [31:0] PROM_SIZE  = 32'h0008_0000;   // 512 KB

    //------------------------------------------------------------------
    // CPU
    //------------------------------------------------------------------
    // Cause.IP[6:2], from INT2 inside the IOC. Declared here because the CPU
    // is instantiated first and the IOC is most of the way down the file.
    logic  [4:0] irq_lines;

    logic        mem_request, mem_rnw, mem_req64, mem_done;
    logic [31:0] mem_address;
    logic  [7:0] mem_writeMask;
    logic [63:0] mem_dataWrite, mem_dataRead;
    logic  [2:0] mem_size;
    logic        fill_grant, fill_data_ready;
    logic [63:0] fill_data;

    r4300_wrap u_cpu (
        .clk              (clk),
        .ce               (ce),
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
        .dbg_pc           (dbg_pc),
        .dbg_pc_valid     (dbg_pc_valid),
        .dbg_mode         (dbg_mode),
        .dbg_exc          (dbg_exc),
        .dbg_exc_code     (dbg_exc_code),
        .dbg_exc_epc      (dbg_exc_epc),
        .dbg_exc_bad      (dbg_exc_bad),
        .dbg_rpc          (dbg_rpc),
        .dbg_retire       (dbg_retire),

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
        .mem_size      (mem_size),
        .mem_writeMask (mem_writeMask),
        .mem_dataWrite (mem_dataWrite),
        .mem_dataRead  (mem_dataRead),
        .mem_done      (mem_done),
        .fill_grant      (fill_grant),
        .fill_data       (fill_data),
        .fill_data_ready (fill_data_ready),
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
    logic sel_ram, sel_alias, sel_gio, sel_gfx, sel_mc, sel_hpc3, sel_ioc, sel_rtc, sel_scsi0,
          sel_prom, sel_none;
    logic hpc3_claimed;

    // The bottom 512 KB is an alias of the bottom of low local memory, so it
    // is decoded by adding the base rather than by a rule of its own: whatever
    // MEMCFG has placed at 0x08000000 is what shows through it, and when POST
    // has moved bank 0 out to high memory the alias is a hole, exactly as on
    // hardware.
    logic [31:0] mem_addr;
    logic        mem_hit;
    logic [31:0] mem_off;
    logic [31:0] mc_memcfg0, mc_memcfg1;   // driven by the MC, below

    // HPC3's SCSI DMA channel, as a master on the memory port and as a
    // consumer of the WD33C93B's data phases. Declared here because both ends
    // are instantiated further down and the arbiter sits between them.
    logic        sdma_req, sdma_we, sdma_ack;
    logic [31:0] sdma_addr;
    logic [63:0] sdma_wdata;
    logic  [7:0] sdma_be;
    logic [63:0] dma_rdata;

    // The MC's GIO64 DMA engine is the second master on this port. It fills
    // memory - the PROM's boot memory clear runs through it - so it is bulk
    // work with nothing waiting on the other end of a bus phase.
    logic        mcd_req, mcd_we, mcd_ack;
    logic [31:0] mcd_addr;
    logic [63:0] mcd_wdata;
    logic  [7:0] mcd_be;

    // TWO MASTERS, ONE PORT, AND SCSI WINS EVERY TIE. The SCSI channel is
    // servicing a live bus phase with a target waiting on it; the MC's fill
    // can be held off for any number of cycles and only takes longer. Written
    // this way round for a second reason as well: when the MC engine is idle -
    // which is every cycle of every SCSI transfer - `mc_owns` is 0 and every
    // signal below is exactly the SCSI channel's, unchanged. That property is
    // what makes this safe to add without being able to run tests/run-dma.sh,
    // whose 31 checks cover this port and need a Verilator that can build the
    // whole design.
    wire        mc_owns   = mcd_req && !sdma_req;
    wire        dma_req   = sdma_req | mcd_req;
    wire        dma_we    = mc_owns ? mcd_we    : sdma_we;
    wire [31:0] dma_addr  = mc_owns ? mcd_addr  : sdma_addr;
    wire [63:0] dma_wdata = mc_owns ? mcd_wdata : sdma_wdata;
    wire  [7:0] dma_be    = mc_owns ? mcd_be    : sdma_be;
    logic        scsi_dev_req, scsi_dev_dir_in, scsi_dev_eop, scsi_dev_ack;
    logic        scsi_dev_reset;
    logic  [7:0] scsi_dev_wdata, scsi_dev_rdata;
    logic        scsi_dma_irq;

    assign sel_alias = (bus_addr < ALIAS_SIZE);
    assign mem_addr  = sel_alias ? (bus_addr + RAM_BASE) : bus_addr;
    assign sel_ram   = sel_alias
                     || ((bus_addr >= RAM_BASE)   && (bus_addr < LOMEM_END))
                     || ((bus_addr >= HIMEM_BASE) && (bus_addr < HIMEM_END));

    sgi_memmap u_memmap (
        .mem_mb (mem_mb),
        .memcfg0 (mc_memcfg0),
        .memcfg1 (mc_memcfg1),
        .addr    (mem_addr),
        .hit     (mem_hit),
        .offset  (mem_off)
    );
    assign sel_scsi0 = (bus_addr >= SCSI0_BASE) && (bus_addr < SCSI0_BASE + SCSI0_SIZE);
    assign sel_gio   = (bus_addr >= GIO0_BASE) && (bus_addr < GIO0_BASE + GIO0_SIZE);
    assign sel_mc    = (bus_addr >= MC_BASE)   && (bus_addr < MC_BASE + MC_SIZE);
    assign sel_ioc   = (bus_addr >= IOC_BASE)  && (bus_addr < IOC_BASE + IOC_SIZE);
    assign sel_prom  = (bus_addr >= PROM_BASE) && (bus_addr < PROM_BASE + PROM_SIZE);
    // IOC2 sits inside HPC3's window - it is PBUS PIO channel 6 - so it has to
    // be taken out of HPC3's range rather than sitting beside it. `claimed`
    // then subtracts the parts of HPC3 that are not modelled yet, so they keep
    // showing up as unclaimed cycles instead of quietly reading back zero.
    // Newport claims the whole 1 MB window. Only REX3 at 0x1F0F0000 is real;
    // the rest of it answers zero from inside newport.sv rather than being
    // left unclaimed, because an unclaimed read answers all ones and REX3's
    // STATUS at 0x1F0F1338 would then read busy forever - the PROM polls it
    // 100000 times before giving up. See docs/16-newport-plan.md.
    assign sel_gfx   = (bus_addr >= GFX_BASE)  && (bus_addr < GFX_BASE + GFX_SIZE);
    assign sel_rtc   = (bus_addr >= RTC_BASE)  && (bus_addr < RTC_BASE + RTC_SIZE);
    assign sel_hpc3  = (bus_addr >= HPC3_BASE) && (bus_addr < HPC3_BASE + HPC3_SIZE)
                       && !sel_ioc && !sel_rtc && hpc3_claimed;
    assign sel_none  = !(sel_ram | sel_gio | sel_gfx | sel_mc | sel_hpc3
                       | sel_ioc | sel_rtc | sel_prom | sel_scsi0);

    //------------------------------------------------------------------
    // The main memory port, and the two masters on it
    //------------------------------------------------------------------
    // THE ONE ARBITER IN THE CORE IS rtl/sgi/ram_arb.sv, and it is its own
    // file rather than twenty lines here because the twenty lines had a bug
    // that no simulation in this repository could reach: the window it opens
    // is exactly as wide as memory is slow, and verilator/sim_ram.v answers in
    // one cycle where DDR3 takes tens. A module can be driven against a slow
    // memory on its own; an inline `always_ff` cannot. Read that file before
    // touching this instantiation - it has the whole diagnosis, including the
    // three different hardware symptoms that came out of the one line.
    //
    // A memory cycle only reaches the RAM model when MEMCFG has a valid bank
    // covering it. Everything else in the two memory windows is answered here
    // as zero - see sgi_memmap.sv on why that matters to POST.
    wire cpu_ram_req = bus_req && sel_ram && mem_hit;
    wire cpu_ram_ack;
    wire dma_port_ack;
    wire dma_grant;

    ram_arb u_ram_arb (
        .clk        (clk),
        .reset      (reset),

        .cpu_req    (cpu_ram_req),
        .cpu_we     (bus_we),
        .cpu_addr   (mem_off),
        .cpu_wdata  (bus_wdata),
        .cpu_be     (bus_be),
        .cpu_ack    (cpu_ram_ack),

        .dma_req    (dma_req && dma_hit),
        .dma_we     (dma_we),
        .dma_addr   (dma_off),
        .dma_wdata  (dma_wdata),
        .dma_be     (dma_be),
        .dma_ack    (dma_port_ack),
        .dma_granted(dma_grant),

        .ram_req    (ram_req),
        .ram_we     (ram_we),
        .ram_addr   (ram_addr),
        .ram_wdata  (ram_wdata),
        .ram_be     (ram_be),
        .ram_ack    (ram_ack)
    );

    // The engine's addresses are physical, so they go through the same MEMCFG
    // decode the CPU's do. A second instance rather than a mux on one: the
    // CPU's `mem_hit` feeds the grant, so feeding the grant back into the
    // address would close a combinational loop.
    logic        dma_hit;
    logic [31:0] dma_off;

    sgi_memmap u_memmap_dma (
        .mem_mb (mem_mb),
        .memcfg0 (mc_memcfg0),
        .memcfg1 (mc_memcfg1),
        .addr    (dma_addr),
        .hit     (dma_hit),
        .offset  (dma_off)
    );

    // A DMA address outside any valid bank is a descriptor chain pointing at
    // nothing. It is answered here with zeros - the same thing sgi_memmap does
    // for a CPU access outside a valid bank - so that the engine keeps walking
    // instead of wedging on an ack that never comes. A real HPC3 would take a
    // GIO64 timeout; what must not happen is a hang three layers from its
    // cause, and `tests/run-dma.sh` points a chain at 0x40000000 to check it.
    //
    // One shot: the engine holds `dma_req` until it is answered, so without
    // the self-clear this would ack the same request on every cycle until the
    // engine noticed the first one.
    logic dma_miss_ack;
    always_ff @(posedge clk)
        dma_miss_ack <= !reset && dma_req && !dma_hit && !dma_miss_ack;

    // `ram_owner_dma` says a DMA owns the answer; this says which one. Without
    // it the MC's fill acks would land on the SCSI channel as completed
    // descriptor cycles.
    logic dma_owner_mc;
    always_ff @(posedge clk) begin
        if (reset)        dma_owner_mc <= 1'b0;
        else if (ram_req) dma_owner_mc <= dma_grant && mc_owns;
    end

    wire dma_ack_any = dma_port_ack | dma_miss_ack;
    wire dma_ack_mc  = dma_miss_ack ? mc_owns : dma_owner_mc;

    assign sdma_ack  = dma_ack_any && !dma_ack_mc;
    assign mcd_ack   = dma_ack_any &&  dma_ack_mc;
    assign dma_rdata = dma_miss_ack ? 64'h0 : ram_rdata;

    assign prom_req  = bus_req && sel_prom;
    assign prom_addr = bus_addr - PROM_BASE;

    assign gio_req   = bus_req && sel_gio && gio_present;
    assign gio_we    = bus_we;
    assign gio_addr  = bus_addr - GIO0_BASE;
    assign gio_wdata = bus_wdata;
    assign gio_be    = bus_be;

    //------------------------------------------------------------------
    // MC - memory controller
    //------------------------------------------------------------------
    // Its registers are 64-bit and only the low half exists, so the module
    // takes the whole doubleword and picks the half itself; see sgi_mc.sv on
    // why the low half is the only one a big-endian CPU may use.
    logic [63:0] mc_rdata;
    logic        mc_ack;
    logic        ee_cs, ee_sk, ee_di, ee_do;

    sgi_mc #(.MEMCFG0_RESET(MEMCFG0_POR)) u_mc (
        .clk     (clk),
        .reset   (reset),
        .ce      (ce),
        .sel     (bus_req && sel_mc),
        .we      (bus_we),
        .addr    (bus_addr[16:0]),
        .be      (bus_be),
        .wdata   (bus_wdata),
        .rdata   (mc_rdata),
        .ack     (mc_ack),
        .ee_cs   (ee_cs),
        .ee_sk   (ee_sk),
        .ee_di   (ee_di),
        .ee_do   (ee_do),
        .memcfg0 (mc_memcfg0),
        .memcfg1 (mc_memcfg1),

        .dma_m_req   (mcd_req),
        .dma_m_we    (mcd_we),
        .dma_m_addr  (mcd_addr),
        .dma_m_wdata (mcd_wdata),
        .dma_m_be    (mcd_be),
        .dma_m_ack   (mcd_ack)
    );

    // The R4000 configuration EEPROM. On hardware this is a real chip on the
    // CPU daughtercard; here it is volatile, which costs nothing yet because
    // the PROM rewrites the one word it cares about on every boot.
    eeprom_93c56 u_eeprom (
        .clk    (clk),
        .reset  (reset),
        .mac_addr(mac_addr),
        .cs     (ee_cs),
        .sk     (ee_sk),
        .di     (ee_di),
        .do_out (ee_do)
    );

    //------------------------------------------------------------------
    // HPC3
    //------------------------------------------------------------------
    logic [63:0] hpc3_rdata;
    logic        hpc3_ack;

    sgi_hpc3 u_hpc3 (
        .clk     (clk),
        .reset   (reset),
        .sel     (bus_req && (bus_addr >= HPC3_BASE)
                           && (bus_addr < HPC3_BASE + HPC3_SIZE)
                           && !sel_ioc && !sel_rtc),
        .we      (bus_we),
        .addr    (bus_addr[18:0]),
        .aoff    (bus_aoff),
        .be      (bus_be),
        .wdata   (bus_wdata),
        .rdata   (hpc3_rdata),
        .ack     (hpc3_ack),
        .claimed (hpc3_claimed),

        .dma_req   (sdma_req),
        .dma_we    (sdma_we),
        .dma_addr  (sdma_addr),
        .dma_wdata (sdma_wdata),
        .dma_be    (sdma_be),
        .dma_rdata (dma_rdata),
        .dma_ack   (sdma_ack),

        .scsi_dev_req    (scsi_dev_req),
        .scsi_dev_dir_in (scsi_dev_dir_in),
        .scsi_dev_wdata  (scsi_dev_wdata),
        .scsi_dev_eop    (scsi_dev_eop),
        .scsi_dev_ack    (scsi_dev_ack),
        .scsi_dev_rdata  (scsi_dev_rdata),
        .scsi_dev_reset  (scsi_dev_reset),

        .scsi_dma_irq    (scsi_dma_irq)
    );

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

    // ---- the PC keyboard/mouse controller, at +0x40/+0x44 ---------------
    // Carved out of the IOC window for the same reason the SCC is: reading
    // its data port pops a byte, so it needs the access decoded down to one
    // word rather than sgi_ioc's read-both-halves-and-let-the-CPU-choose.
    // +0x40 is the data port and +0x44 the command/status port, so the word
    // within the doubleword is which of the two - and on a big-endian bus
    // the word at +0 is the high half.
    logic       kbd_sel;
    logic       kbd_is_cmd;
    logic [7:0] kbd_din, kbd_dout;
    logic       kbd_irq, mouse_irq;

    assign kbd_sel    = bus_req && sel_ioc
                        && (bus_addr[7:0] >= 8'h40) && (bus_addr[7:0] < 8'h48);
    assign kbd_is_cmd = bus_aoff[2];
    assign kbd_din    = kbd_is_cmd ? bus_wdata[7:0] : bus_wdata[39:32];

    i8042 u_kbd (
        .clk       (clk),
        .reset     (reset),
        .ce        (ce),
        .sel       (kbd_sel),
        .we        (bus_we),
        .is_cmd    (kbd_is_cmd),
        .din       (kbd_din),
        .dout      (kbd_dout),
        .ps2_key   (ps2_key),
        .ps2_mouse (ps2_mouse),
        .irq_kbd   (kbd_irq),
        .irq_mouse (mouse_irq)
    );

    // One cycle of latency, to match every other device's registered ack.
    logic kbd_ack;
    always_ff @(posedge clk) kbd_ack <= reset ? 1'b0 : kbd_sel;

    // ---- SCSI controller 0 ----------------------------------------------
    logic [63:0] scsi_rdata;
    logic        scsi_ack, scsi_irq;

    sgi_scsi u_scsi0 (
        .clk          (clk),
        .reset        (reset),
        .ce           (ce),
        .sel          (bus_req && sel_scsi0),
        .we           (bus_we),
        .aoff         (bus_aoff),
        .wdata        (bus_wdata),
        .rdata        (scsi_rdata),
        .ack          (scsi_ack),
        .irq          (scsi_irq),
        .chip_reset   (scsi_dev_reset),
        .dma_req      (scsi_dev_req),
        .dma_dir_in   (scsi_dev_dir_in),
        .dma_wdata    (scsi_dev_wdata),
        .dma_eop      (scsi_dev_eop),
        .dma_ack      (scsi_dev_ack),
        .dma_rdata    (scsi_dev_rdata),
        .img_mounted  (scsi_img_mounted),
        .img_blocks   (scsi_img_blocks),
        .sd_lba       (scsi_sd_lba),
        .sd_rd        (scsi_sd_rd),
        .sd_wr        (scsi_sd_wr),
        .sd_ack       (scsi_sd_ack),
        .sd_buff_addr (scsi_sd_buff_addr),
        .sd_buff_dout (scsi_sd_buff_dout),
        .sd_buff_din  (scsi_sd_buff_din),
        .sd_buff_wr   (scsi_sd_buff_wr)
    );

    // The rest of the IOC window: panel, SYS_ID, reset/LED, and the INT2
    // interrupt controller at +0x80.
    logic [63:0] ioc_rdata;
    logic        ioc_ack;

    sgi_ioc #(.PIT_TICK_DIV(PIT_TICK_DIV)) u_ioc (
        .clk       (clk),
        .reset     (reset),
        .ce        (ce),
        .sel       (bus_req && sel_ioc && !scc_sel && !kbd_sel),
        .we        (bus_we),
        .addr      (bus_addr[7:0]),
        .aoff      (bus_aoff),
        .be        (bus_be),
        .wdata     (bus_wdata),
        .rdata     (ioc_rdata),
        .ack       (ioc_ack),
        // INT2's sources. Everything not listed is a device this core does
        // not have yet, and reads as an interrupt that never fires:
        //   L0  0 FIFO full, 2 SCSI1, 3 Ethernet, 4 MC DMA, 5 parallel,
        //       6 graphics
        //   L1  0/2 general purpose, 1 panel, 4 HPC DMA, 5 AC fail,
        //       6 video vsync, 7 vertical retrace
        //   MAP 6/7 the two GIO expansion slots
        // Bit 7 of L0 and bit 3 of L1 are the mappable summaries and are
        // generated inside the IOC, so what is passed there does not matter.
        // SCSI0's INT2 line is the OR of the controller's own interrupt and
        // the HPC3 channel's DMA interrupt, which is what IRIS's callback
        // does: `Scsi0 => intstat & (SCSI0_DEV | SCSI0_DMA) != 0`. Nothing has
        // exercised the DMA half - the PROM polls and its descriptors do not
        // set XIE - so this is wiring, not a tested path.
        .l0_source ({7'h0, scsi_irq | scsi_dma_irq, 1'b0}),
        .l1_source (8'h00),
        // The SCC and the keyboard controller are mappable sources, not local
        // ones: they arrive through MAP_STAT and reach the CPU only if
        // software has pointed MAP_MASK0 or MAP_MASK1 at them. `int_n` is
        // active low, as the Z8530's INT pin is.
        .map_source ({2'b00, ~scc_int_n, kbd_irq | mouse_irq, 4'h0}),
        .irq_lines (irq_lines),
        .int2_state (int2_state_o)
    );

    assign irq_lines_o = irq_lines;

    // The Dallas RTC and the NVRAM the PROM keeps its environment in. Also
    // inside HPC3's window - it is the battery-backed-RAM chip select.
    logic [63:0] rtc_rdata;
    logic        rtc_ack;

    sgi_ds1386 #(.TICK_DIV(RTC_TICK_DIV)) u_rtc (
        .clk   (clk),
        .reset (reset),
        .mac_addr(mac_addr),
        .ce    (ce),
        .sel   (bus_req && sel_rtc),
        .we    (bus_we),
        .addr  (bus_addr[14:0]),
        .be    (bus_be),
        .wdata (bus_wdata),
        .rdata (rtc_rdata),
        .ack   (rtc_ack)
    );

    //------------------------------------------------------------------
    // Newport graphics
    //------------------------------------------------------------------
    logic [63:0] gfx_rdata;
    logic        gfx_ack;
    logic        gfx_absent_ack;

    // With no board fitted the window still answers zero rather than being
    // left unclaimed: REX3's STATUS reads busy forever if an unclaimed cycle
    // answers all ones, and the PROM polls it 100000 times before giving up.
    always_ff @(posedge clk)
        gfx_absent_ack <= !reset && bus_req && sel_gfx && !gfx_present;

    newport #(.FB_BASE(32'h0000_0000)) u_newport (
        .clk       (clk),
        .reset     (reset),
        .sel       (bus_req && sel_gfx && gfx_present),
        .we        (bus_we),
        .addr      (bus_addr[19:0]),
        .aoff      (bus_aoff),
        .be        (bus_be),
        .wdata     (bus_wdata),
        .rdata     (gfx_rdata),
        .ack       (gfx_ack),
        .fbw_req   (fbw_req),
        .fbw_we    (fbw_we),
        .fbw_addr  (fbw_addr),
        .fbw_wdata (fbw_wdata),
        .fbw_be    (fbw_be),
        .fbw_rdata (fbw_rdata),
        .fbw_ack   (fbw_ack),
        .fbr_req   (fbr_req),
        .fbr_addr  (fbr_addr),
        .fbr_rdata (fbr_rdata),
        .fbr_ack   (fbr_ack),
        .ce_pix    (vid_ce_pix),
        .hsync     (vid_hsync),
        .vsync     (vid_vsync),
        .de        (vid_de),
        .vid_r     (vid_r),
        .vid_g     (vid_g),
        .vid_b     (vid_b),
        .gfx_irq   (),
        .dbg_raw_index (dbg_raw_index)
    );

    //------------------------------------------------------------------
    // Response mux
    //------------------------------------------------------------------
    // Devices that answer combinationally get their ack generated here, one
    // cycle after the request, which keeps the CPU's mem_done edge clean.
    logic        none_ack;
    logic        gio_absent_ack;
    logic        mem_hole_ack;

    always_ff @(posedge clk) begin
        none_ack       <= 1'b0;
        gio_absent_ack <= 1'b0;
        mem_hole_ack   <= 1'b0;
        bus_unclaimed  <= 1'b0;

        if (!reset && bus_req) begin
            if (sel_ram && !mem_hit) mem_hole_ack <= 1'b1;
            if (sel_gio && !gio_present) gio_absent_ack <= 1'b1;
            if (sel_none) begin
                none_ack      <= 1'b1;
                bus_unclaimed <= 1'b1;
            end
        end
    end

    // `cpu_ram_ack` comes from ram_arb, which is the only thing that knows
    // whose answer `ram_ack` is. Letting a DMA cycle's ack through here would
    // finish a CPU cycle that is still waiting, with the DMA's data on it.
    assign bus_ack   = cpu_ram_ack | prom_ack | gio_ack | mc_ack | hpc3_ack
                     | ioc_ack | rtc_ack | scc_ack | kbd_ack | scsi_ack | none_ack | gio_absent_ack
                     | mem_hole_ack | gfx_ack | gfx_absent_ack;

    // Mirror the SCC's 32-bit answer into both halves of the doubleword so the
    // read shift in r4300_bus lands on it whichever word was addressed.
    assign bus_rdata = (mem_hole_ack | gfx_absent_ack) ? 64'h0
                     : gfx_ack  ? gfx_rdata
                     : cpu_ram_ack ? ram_rdata
                     : prom_ack ? prom_rdata
                     : gio_ack  ? gio_rdata
                     : mc_ack   ? mc_rdata
                     : hpc3_ack ? hpc3_rdata
                     : scsi_ack ? scsi_rdata
                     : kbd_ack  ? {24'h0, kbd_dout, 24'h0, kbd_dout}
                     : scc_ack  ? {scc_rdata, scc_rdata}
                     : ioc_ack  ? ioc_rdata
                     : rtc_ack  ? rtc_rdata
                     :            64'hFFFF_FFFF_FFFF_FFFF;

    // ---- observability ----
    assign bus_req_o   = bus_req;
    assign bus_we_o    = bus_we;
    assign bus_addr_o  = bus_addr;
    assign bus_wdata_o = bus_wdata;
    assign bus_be_o    = bus_be;
    assign bus_rdata_o = bus_rdata;
    assign bus_ack_o   = bus_ack;
    assign bus_mem_o   = cpu_ram_ack;
    assign bus_hole_o  = mem_hole_ack;

endmodule
