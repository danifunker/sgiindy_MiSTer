library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;   
use ieee.math_real.all;  

library mem;
use work.pFunctions.all;

entity cpu_instrcache is
   generic
   (
      LITTLE_ENDIAN : boolean := false
   );
   port 
   (
      clk1x             : in  std_logic;
      clk93             : in  std_logic;
      clk2x             : in  std_logic;
      -- One reset per domain. The fill path below runs on clk1x, so it must be
      -- released by a clk1x-synchronised reset: reset_93 crosses domains
      -- unsynchronised, and once clk93 and clk1x are declared asynchronous
      -- nothing constrains its recovery/removal any more.
      reset_1x          : in  std_logic;
      reset_93          : in  std_logic;
      ce_93             : in  std_logic;

      ram_request       : out std_logic := '0';
      ram_active        : in  std_logic := '0';
      ram_grant         : in  std_logic := '0';
      ram_done          : in  std_logic := '0';
      ddr3_DOUT         : in  std_logic_vector(63 downto 0);
      ddr3_DOUT_READY   : in  std_logic;
      
      read_select       : in  std_logic;
      -- RAM index for the tag and data lookups: bits 12 downto 2 of the
      -- PHYSICAL fetch address (SGI, docs/47: bit 12 is the translated one
      -- from cpu.vhd's FetchIndexPhys1; bits 11:2 are page offset and come
      -- from KI's ONE flattened mux there rather than the forwarding mux
      -- feeding the fetch mux - see FetchIndex1 for why the shorter path
      -- matters). The tag COMPARE still uses read_addrCompare1/2, so a wrong
      -- index can only miss and refill - it cannot return wrong data.
      read_index1       : in  unsigned(12 downto 2);
      read_index2       : in  unsigned(12 downto 2);
      read_addrCompare1 : in  unsigned(31 downto 0);
      read_addrCompare2 : in  unsigned(31 downto 0);
      read_hit          : out std_logic;
      read_data         : out std_logic_vector(31 downto 0) := (others => '0');
      
      fill_request      : in  std_logic;
      -- SGI: both are the PHYSICAL address of the line now (cpu.vhd drives
      -- both from mem1_addrCompare): fill_addrData(31:12) becomes the tag and
      -- fill_addrTag(12:5) the line index. Upstream the index came from the
      -- virtual address, which is what made the cache virtually indexed.
      fill_addrData     : in  unsigned(31 downto 0);
      fill_addrTag      : in  unsigned(31 downto 0);
      fill_done         : out std_logic := '0';
      
      CacheCommandEna   : in  std_logic;
      CacheCommand      : in  unsigned(4 downto 0);
      CacheCommandAddr  : in  unsigned(31 downto 0);
      
      TagLo_Valid       : in  std_logic;
      TagLo_Addr        : in  unsigned(19 downto 0);

      SS_reset          : in  std_logic
   );
end entity;

architecture arch of cpu_instrcache is

   -- SGI: 8 KB, NOT KI's 16 KB - ONE WAY OF AN R4600, and the full 20-bit tag.
   --
   -- IRIX colours user pages for the cache the CPU's PRId implies. For an
   -- R4400 (16 KB direct-mapped) it keeps virtual and physical address bits
   -- 13:12 equal (cachecolormask = 3); for an R4600 (16 KB, two 8 KB ways) it
   -- keeps only bit 12 equal (cachecolormask = 1 - read out of the kernel's
   -- own data at 0x881B9680 in the simulator's RAM dumps for both identities,
   -- docs/45). KI's cache indexes on VIRTUAL bits 13:5 and compares only tag
   -- bits 31:14, which was fine for its identity-mapped games and for us as
   -- an R4400, and is wrong for us as an R4600: half of all user text pages
   -- have virtual bit 13 /= physical bit 13, so a fetch can HIT another 4 KB
   -- page's line (the tag no longer sees bits 13:12) and the kernel's
   -- invalidates by physical address look in the wrong set. Build 23 on the
   -- board: bus errors, segmentation faults and illegal instructions all
   -- through the IRIX boot, while the data cache - physically indexed since
   -- docs/40 - was fine.
   --
   -- So the index is bits 12:5 (256 lines of 32 bytes) and the tag holds
   -- bits 31:12, so a wrong hit is impossible even for an uncoloured mapping.
   -- The kernel's 16 KB index flush loops simply cover it twice.
   --
   -- AND THE INDEX IS PHYSICAL (docs/47). Build 24 indexed on VIRTUAL bit 12
   -- - "the one bit IRIX colours, the exposure a real R4600 way has" - and
   -- still lost init to SIGSEGV about one boot in three: IRIX does not colour
   -- every mapping, a page mapped with virtual bit 12 /= physical bit 12 left
   -- its lines in set(V), and the kernel's Hit_Invalidate_I by the page's K0
   -- address looked in set(P). A real R4600's hit ops search both ways of a
   -- set; this cache has one. So cpu.vhd now hands this cache the physical
   -- bit 12 on the fetch side (FetchIndexPhys1/2, from the instruction
   -- mini-TLB) and the physical address on the fill side (fill_addrTag =
   -- mem1_addrCompare), and translates cache op 0x10 - every line lives in
   -- exactly one set for every mapping. Index ops 0x00/0x08 take their index
   -- from the operand untranslated, as before (IRIX issues them by K0
   -- address). The 16 KB two-way cache with the way selected by physical bit
   -- 13 is the follow-up (docs/45).

   -- tags
   signal tag_address_a    : std_logic_vector(7 downto 0) := (others => '0');   -- SGI: 256 lines
   signal tag_data_a       : std_logic_vector(20 downto 0) := (others => '0');  -- SGI: 20-bit tag + valid
   signal tag_wren_a       : std_logic := '0';
   signal tag_address_b1   : std_logic_vector(7 downto 0);   -- SGI
   signal tag_address_b2   : std_logic_vector(7 downto 0);   -- SGI
   signal tag_q_b1         : std_logic_vector(20 downto 0);  -- SGI
   signal tag_q_b2         : std_logic_vector(20 downto 0);  -- SGI
   signal fill_addrTag_sav : unsigned(13 downto 0) := (others => '0');

   signal read_hit1        : std_logic;
   signal read_hit2        : std_logic;

   -- data
   signal fill_grant       : std_logic;
   signal fill_active_2x   : std_logic := '0';
   signal fill_line_2x     : unsigned(7 downto 0) := (others => '0');   -- SGI
   signal fill_beat_2x     : unsigned(1 downto 0) := (others => '0');
   signal cache_ram_addr_a : std_logic_vector(9 downto 0);   -- SGI: 256 x 4 doublewords
   signal cache_wr_a       : std_logic;
   
   signal cache_address_b  : std_logic_vector(10 downto 0);  -- SGI: 2048 words
   signal cache_q_b        : std_logic_vector(31 downto 0);
   
   -- state machine
   type tState is
   (
      IDLE,
      CLEARCACHE,
      FILL
   );
   signal state : tstate := IDLE;
   
   signal fill_latched : std_logic := '0';

   -- SGI: A CACHE COMMAND THAT ARRIVES WHILE THIS CACHE IS FILLING USED TO BE
   -- DROPPED. The command was only looked at in the IDLE arm of the state
   -- machine below, `cache_commandEnableI` in cpu.vhd is a one-clock pulse,
   -- and unlike cpu_datacache.vhd's CachecommandStall nothing stalls the
   -- pipeline for it - so an `Index_Invalidate` or `Hit_Invalidate` issued
   -- while a line was being filled simply did not happen, and the line it
   -- named stayed valid.
   --
   -- That is a stale-instruction bug and IRIX walks straight into it: its
   -- cache flush is a tight loop of `cache` instructions, the loop's OWN
   -- fetches miss and start fills, and some fraction of the flush is lost
   -- every time. The dynamic linker then executes a page it has just
   -- relocated, gets the bytes that were there before, and `init` dies with
   -- signal 11 - which is what `--no-icache` was booting past.
   signal cmd_pending  : std_logic := '0';
   signal cmd_code     : unsigned(4 downto 0) := (others => '0');
   signal cmd_addr     : unsigned(31 downto 0) := (others => '0');
   signal cmd_code_eff : unsigned(4 downto 0);
   signal cmd_addr_eff : unsigned(31 downto 0);
   signal cmd_ena_eff  : std_logic;

begin 

   fill_grant <= ram_grant and ram_active;

   -- A live command takes priority over the latched one; see cmd_pending.
   cmd_ena_eff  <= CacheCommandEna or cmd_pending;
   cmd_code_eff <= CacheCommand     when (CacheCommandEna = '1') else cmd_code;
   cmd_addr_eff <= CacheCommandAddr when (CacheCommandEna = '1') else cmd_addr;

   -- use two tag rams, so different fetch paths can be calculated in parallel to improve timing

   read_hit <= read_hit2 when (read_select = '1') else read_hit1;

   ------------------ tags
   itagram1 : entity mem.RamMLAB
   generic map
   (
      width      => 21, -- SGI: 20 bits(31..12) of address + 1 bit valid
      widthad    => 8   -- SGI: 256 lines
   )
   port map
   (
      inclock    => clk93,
      wren       => tag_wren_a,
      data       => tag_data_a,
      wraddress  => tag_address_a,
      rdaddress  => tag_address_b1,
      q          => tag_q_b1
   );
   
   tag_address_b1 <= std_logic_vector(read_index1(12 downto 5));   -- SGI
   read_hit1      <= '1' when (unsigned(tag_q_b1(19 downto 0)) = read_addrCompare1(31 downto 12) and tag_q_b1(20) = '1') else '0';   -- SGI
   
   itagram2 : entity mem.RamMLAB
   generic map
   (
      width      => 21, -- SGI: 20 bits(31..12) of address + 1 bit valid
      widthad    => 8   -- SGI: 256 lines
   )
   port map
   (
      inclock    => clk93,
      wren       => tag_wren_a,
      data       => tag_data_a,
      wraddress  => tag_address_a,
      rdaddress  => tag_address_b2,
      q          => tag_q_b2
   );
   
   tag_address_b2 <= std_logic_vector(read_index2(12 downto 5));   -- SGI
   read_hit2      <= '1' when (unsigned(tag_q_b2(19 downto 0)) = read_addrCompare2(31 downto 12) and tag_q_b2(20) = '1') else '0';   -- SGI

   --------- data
   
   -- The KI bridge returns cache-fill beats in the 50 MHz clk1x domain.
   -- Consume each ready pulse once in that same domain before crossing the
   -- completed line into the 75 MHz CPU/tag domain.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (reset_1x = '1') then
            fill_active_2x <= '0';
            fill_line_2x   <= (others => '0');
            fill_beat_2x   <= (others => '0');
         elsif (fill_grant = '1') then
            fill_active_2x <= '1';
            fill_line_2x   <= fill_addrTag_sav(12 downto 5);   -- SGI
            fill_beat_2x   <= (others => '0');
            if (ddr3_DOUT_READY = '1') then
               fill_beat_2x <= 2x"1";
            end if;
         elsif (ram_active = '0') then
            -- The transaction this window belongs to is over. See the note on
            -- cache_wr_a below.
            fill_active_2x <= '0';
         elsif (fill_active_2x = '1' and ddr3_DOUT_READY = '1') then
            if (fill_beat_2x = 2x"3") then
               fill_active_2x <= '0';
            else
               fill_beat_2x <= fill_beat_2x + 1;
            end if;
         end if;
      end if;
   end process;

   cache_ram_addr_a <= std_logic_vector(fill_addrTag_sav(12 downto 5) & "00")   -- SGI
                       when (fill_grant = '1') else
                       std_logic_vector(fill_line_2x & fill_beat_2x);
   cache_wr_a       <= (fill_active_2x or fill_grant) and ddr3_DOUT_READY and ram_active;

   icache: entity work.dpram_dif
   generic map 
   ( 
      addr_width_a  => 10,   -- SGI: 8 KB
      data_width_a  => 64,
      addr_width_b  => 11,   -- SGI
      data_width_b  => 32
   )
   port map
   (
      clock_a     => clk1x,
      address_a   => cache_ram_addr_a,
      data_a      => ddr3_DOUT,
      wren_a      => cache_wr_a,
      
      clock_b     => clk93,
      clken_b     => ce_93,
      address_b   => cache_address_b,
      data_b      => x"00000000",
      wren_b      => '0',
      q_b         => cache_q_b
   );
   
   cache_address_b <= std_logic_vector(fill_addrTag_sav(12 downto 2))  when (state /= IDLE) else   -- SGI: 12:2
                      std_logic_vector(read_index2(12 downto 2)) when (read_select = '1') else
                      std_logic_vector(read_index1(12 downto 2));
   
   read_data       <= cache_q_b when LITTLE_ENDIAN else byteswap32(cache_q_b);
   
   process (clk93)
   begin
      if rising_edge(clk93) then

         tag_wren_a  <= '0';
         fill_done   <= '0';
         ram_request <= '0';
         
         if (fill_request = '1') then
            fill_latched <= '1';
         end if;

         -- SGI: hold a command that arrived while this cache was busy, so the
         -- IDLE arm above can retire it instead of it being lost. One deep:
         -- the caller is a single instruction and cannot have two in flight.
         if (CacheCommandEna = '1' and state /= IDLE) then
            cmd_pending <= '1';
            cmd_code    <= CacheCommand;
            cmd_addr    <= CacheCommandAddr;
         end if;

         if (SS_reset = '1') then
            cmd_pending    <= '0';   -- SGI
            state          <= CLEARCACHE;
            tag_data_a     <= (others => '0');
            tag_address_a  <= (others => '0');
            tag_wren_a     <= '1';
            fill_latched   <= '0';
         else

            case(state) is
            
               when IDLE =>
                  fill_addrTag_sav <= fill_addrTag(13 downto 0);
                  -- SGI: a command retired here clears the latch, whether it
                  -- came from the latch or straight off the bus.
                  if (cmd_ena_eff = '1' and (cmd_code_eff = 5x"00" or cmd_code_eff = 5x"10")) then
                     -- HACK!
                     -- todo: should only clear if tag matches
                     tag_wren_a     <= '1';
                     tag_data_a     <= (others => '0');
                     tag_address_a  <= std_logic_vector(cmd_addr_eff(12 downto 5));   -- SGI
                     cmd_pending    <= '0';
                  elsif (cmd_ena_eff = '1' and cmd_code_eff = 5x"08") then
                     tag_wren_a     <= '1';
                     tag_data_a     <= TagLo_Valid & std_logic_vector(TagLo_Addr(19 downto 0));   -- SGI: full tag
                     tag_address_a  <= std_logic_vector(cmd_addr_eff(12 downto 5));   -- SGI
                     cmd_pending    <= '0';
                  elsif (cmd_ena_eff = '1') then
                     cmd_pending    <= '0';   -- SGI: a code this cache ignores
                  elsif (fill_request = '1' or fill_latched = '1') then
                     state          <= FILL;
                     ram_request    <= '1';
                     fill_latched   <= '0';
                  end if;
                  
               when CLEARCACHE =>
                  tag_wren_a     <= '1';
                  if (tag_address_a /= 8x"FF") then   -- SGI: 256 lines
                     tag_address_a <= std_logic_vector(unsigned(tag_address_a) + 1);
                  else
                     state          <= IDLE;
                  end if;
                  
               when FILL =>
                  if (ram_done = '1') then
                     state          <= IDLE;
                     tag_wren_a     <= '1';
                     tag_data_a     <= '1' & std_logic_vector(fill_addrData(31 downto 12));   -- SGI: full tag
                     tag_address_a  <= std_logic_vector(fill_addrTag_sav(12 downto 5));   -- SGI
                     fill_done      <= '1'; 
                  end if;
                  
            end case;  
            
         end if;

      end if;
   end process;

   
end architecture;




























