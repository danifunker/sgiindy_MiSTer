--------------------------------------------------------------------------------
-- r4300_wrap - flat-port wrapper around the MiSTer N64 project's R4300i.
--
-- Two jobs:
--
-- 1. Present a synthesisable, flat port list. cpu.vhd's top level has a
--    `buffer`-mode port, an `unsigned` port and - inside `-- synthesis
--    translate_off` - a record-typed `cpu_export` output. GHDL's synthesis
--    backend crashes outright when asked to make that entity the top of a
--    design (netlists-utils.adb:166), and Quartus would object to the record
--    too. From one level down they are all ordinary internal signals, so the
--    wrapper costs nothing and buys both toolchains.
--
-- 2. Sequence reset, including the boot PC.
--
--    cpu.vhd takes its reset PC from a savestate shadow register, not from a
--    constant: `SS_reset` loads ss_in(0) with 0xFFFFFFFF_BFC00000 and
--    `reset_93` then copies ss_in(0) into PC. Leave SS_reset low and the CPU
--    resets to PC 0. So the sequencer pulses SS_reset first, and - because
--    ss_in(0) is also writable through SS_wren_CPU/SS_Adr=0 - optionally
--    overwrites it with `boot_pc` before releasing reset.
--
--    boot_pc is what lets the bare-metal cpu-tests suite run with no PROM at
--    all: the harness loads the ELF into RAM and starts the CPU at its entry
--    point. On real hardware boot_pc is the MIPS reset vector, 0xBFC00000,
--    which is also where the IP24 PROM lives.
--
-- The MIPS reset PC is sign-extended to 64 bits, hence boot_pc_hi: the CPU's
-- PC is a 64-bit register and 0x00000000BFC00000 is xkuseg, not KSEG1.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity r4300_wrap is
   port
   (
      clk               : in  std_logic;
      ce                : in  std_logic;
      reset             : in  std_logic;

      -- Physical address the CPU starts fetching from after reset.
      -- Sampled while `reset` is asserted; 0xBFC00000 for a PROM boot.
      boot_pc           : in  std_logic_vector(31 downto 0) := x"BFC00000";

      INSTRCACHEON      : in  std_logic := '0';
      DATACACHEON       : in  std_logic := '0';

      -- The five INT2 interrupt lines, Cause.IP[6:2] low to high:
      --   0  IP2  LOCAL0     (SCSI, Ethernet, graphics, MC DMA, MAP_INT0)
      --   1  IP3  LOCAL1     (HPC DMA, vertical retrace, panel, MAP_INT1)
      --   2  IP4  8254 counter 0
      --   3  IP5  8254 counter 1
      --   4  IP6  bus error
      -- Level-sensitive: hold a bit while the source is asserted and drop it
      -- when the ISR clears the device. See rtl/sgi/sgi_ioc.sv.
      irq_lines         : in  std_logic_vector(4 downto 0) := "00000";

      error_instr       : out std_logic;
      error_stall       : out std_logic;
      error_FPU         : out std_logic;
      error_exception   : out std_logic;
      error_fifo        : out std_logic;
      error_TLB         : out std_logic;

      -- The PC entering decode, and a strobe. See cpu.vhd's port of the same
      -- name for why the tap is where it is; it is a simulation instrument
      -- that happens to be synthesisable, so it costs nothing to carry.
      dbg_pc            : out std_logic_vector(31 downto 0);
      dbg_pc_valid      : out std_logic;
      dbg_mode          : out std_logic_vector(3 downto 0);
      dbg_exc           : out std_logic;
      dbg_exc_code      : out std_logic_vector(4 downto 0);
      dbg_exc_epc       : out std_logic_vector(31 downto 0);
      dbg_exc_bad       : out std_logic_vector(31 downto 0);
      dbg_rpc           : out std_logic_vector(31 downto 0);
      dbg_retire        : out std_logic;

      -- Memory port. See rtl/cpu/r4300_bus.sv for the byte-lane contract;
      -- it is not the obvious one and it differs between read and write.
      mem_request       : out std_logic;
      mem_rnw           : out std_logic;
      mem_address       : out std_logic_vector(31 downto 0);
      mem_req64         : out std_logic;
      mem_size          : out std_logic_vector(2 downto 0);
      mem_writeMask     : out std_logic_vector(7 downto 0);
      mem_dataWrite     : out std_logic_vector(63 downto 0);
      mem_dataRead      : in  std_logic_vector(63 downto 0);
      mem_done          : in  std_logic;

      -- Cache line fill response. A fill is an ordinary mem_* read tagged
      -- mem_size = "010"/"100", but its DATA comes back here rather than on
      -- mem_dataRead: cpu_instrcache/cpu_datacache take their lines straight
      -- off what is, upstream, the N64's RDRAM controller. r4300_bus.sv is
      -- the other end and documents the ordering these three have to keep.
      fill_grant        : in  std_logic := '0';
      fill_data         : in  std_logic_vector(63 downto 0) := (others => '0');
      fill_data_ready   : in  std_logic := '0'
   );
end entity;

architecture arch of r4300_wrap is

   signal mem_address_i : unsigned(31 downto 0);
   signal mem_size_i    : unsigned(2 downto 0);

   -- Reset sequencer. Runs on `clk` regardless of `ce`, so a stopped clock
   -- enable cannot strand the CPU mid-reset.
   --   SEEDING  SS_reset high: ss_in := 0, ss_in(0) := 0xFFFFFFFFBFC00000
   --   LOADPC   SS_reset low, SS_wren_CPU high at SS_Adr 0: ss_in(0) := boot_pc
   --   SETTLE   both low, cpu resets still asserted so reset_93 latches PC
   --   RUN      resets released
   type t_rststate is (RS_SEEDING, RS_LOADPC, RS_SETTLE, RS_RUN);
   signal rststate  : t_rststate := RS_SEEDING;

   -- How long SETTLE holds the CPU in reset. It used to be four clocks,
   -- which was enough to latch the boot PC and was all that mattered while
   -- both caches were off.
   --
   -- It is not enough with a cache on. SS_reset starts each cache's tag RAM
   -- clearing, and that clear is a state machine walking 512 entries one per
   -- clock (cpu_instrcache.vhd's CLEARCACHE, cpu_datacache.vhd's likewise) -
   -- neither of them looks at reset_93 at all. Release the pipeline after
   -- four clocks and the first cached access lands while the data cache is
   -- still in CLEARCACHE, where nothing latches it: cpu.vhd waits for a
   -- write_done that never comes and error_stall fires 4096 clocks later.
   -- The instruction cache survives it only because it latches fill_request
   -- separately from its state machine.
   --
   -- So the settle has to outlast the longer of the two clears. 1024 is that
   -- with a factor of two in hand, and it costs a thousand clocks once.
   constant SETTLE_CLOCKS : integer := 1024;
   signal settle    : integer range 0 to SETTLE_CLOCKS := SETTLE_CLOCKS;

   signal ss_reset  : std_logic := '1';
   signal ss_wren   : std_logic := '0';
   signal ss_data   : std_logic_vector(63 downto 0) := (others => '0');
   signal cpu_reset : std_logic := '1';

begin

   mem_address <= std_logic_vector(mem_address_i);
   mem_size    <= std_logic_vector(mem_size_i);

   ss_data <= x"FFFFFFFF" & boot_pc;

   process (clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            rststate  <= RS_SEEDING;
            settle    <= SETTLE_CLOCKS;
            ss_reset  <= '1';
            ss_wren   <= '0';
            cpu_reset <= '1';
         else
            case rststate is
               when RS_SEEDING =>
                  -- One clock of SS_reset is enough: it is a synchronous load.
                  ss_reset <= '0';
                  ss_wren  <= '1';
                  rststate <= RS_LOADPC;

               when RS_LOADPC =>
                  ss_wren  <= '0';
                  rststate <= RS_SETTLE;

               when RS_SETTLE =>
                  -- cpu_reset is still high here, so cpu.vhd's reset_93 block
                  -- re-latches PC from the ss_in(0) just written.
                  if settle = 0 then
                     cpu_reset <= '0';
                     rststate  <= RS_RUN;
                  else
                     settle <= settle - 1;
                  end if;

               when RS_RUN =>
                  null;
            end case;
         end if;
      end if;
   end process;

   icpu : entity work.cpu
   port map
   (
      clk1x                 => clk,
      clk93                 => clk,
      clk2x                 => clk,
      ce_1x                 => ce,
      ce_93                 => ce,
      reset_1x              => cpu_reset,
      reset_93              => cpu_reset,
      preNMI                => '0',

      INSTRCACHEON          => INSTRCACHEON,
      DATACACHEON           => DATACACHEON,
      DATACACHESLOW         => "0000",
      DATACACHEFORCEWEB     => '0',
      -- TLB-mapped data accesses go through the data cache too, honouring the
      -- entry's coherency field. Upstream leaves this off, which is safe on a
      -- machine where nothing important is mapped; here it is not optional.
      -- KSEG0 is cached, so a mapped view of the same physical page that
      -- bypassed the cache would see a different memory than KSEG0 does -
      -- cpu-tests' tlb/translation_works writes through KSEG0 and reads back
      -- through the mapping, and caught exactly that.
      DATACACHETLBON        => '1',
      RANDOMMISS            => "0000",
      DISABLE_BOOTCOUNT     => '1',
      DISABLE_DTLBMINI      => '0',

      irqLines              => irq_lines,
      cpuPaused             => '0',

      error_instr           => error_instr,
      error_stall           => error_stall,
      error_FPU             => error_FPU,
      error_exception       => error_exception,
      error_fifo            => error_fifo,
      error_TLB             => error_TLB,
      dbg_pc                => dbg_pc,
      dbg_pc_valid          => dbg_pc_valid,
      dbg_mode              => dbg_mode,
      dbg_exc               => dbg_exc,
      dbg_exc_code          => dbg_exc_code,
      dbg_exc_epc           => dbg_exc_epc,
      dbg_exc_bad           => dbg_exc_bad,
      dbg_rpc               => dbg_rpc,
      dbg_retire            => dbg_retire,

      mem_request           => mem_request,
      mem_rnw               => mem_rnw,
      mem_address           => mem_address_i,
      mem_req64             => mem_req64,
      mem_size              => mem_size_i,
      mem_writeMask         => mem_writeMask,
      mem_dataWrite         => mem_dataWrite,
      mem_dataRead          => mem_dataRead,
      mem_done              => mem_done,

      -- The fill port, driven by r4300_bus.sv from ordinary SGI bus reads.
      -- rdram_done is dead inside cpu.vhd - the caches finish on ram_done,
      -- which cpu.vhd derives from mem_done - so nothing needs to drive it.
      rdram_granted2x       => fill_grant,
      rdram_done            => '0',
      ddr3_DOUT             => fill_data,
      ddr3_DOUT_READY       => fill_data_ready,

      ram_done              => '0',
      ram_rnw               => '0',
      ram_dataRead          => (others => '0'),

      SS_reset              => ss_reset,
      loading_savestate     => '0',
      SS_DataWrite          => ss_data,
      SS_Adr                => (others => '0'),
      SS_wren_CPU           => ss_wren,
      SS_rden_CPU           => '0',
      SS_DataRead_CPU       => open,
      SS_idle               => open
   );

end architecture;
