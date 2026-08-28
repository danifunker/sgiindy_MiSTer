-- Behavioural stand-ins for dpram.vhd's altsyncram instances.
--
-- All four entities keep the original port lists byte-for-byte so the CPU's
-- instantiations bind unchanged. The altsyncram generics they replace are:
--
--   operation_mode                = BIDIR_DUAL_PORT   (both ports read+write)
--   address_reg_b / indata_reg_b  = CLOCK1            (port B on its own clock)
--   outdata_reg_a / outdata_reg_b = UNREGISTERED      (one-cycle read latency)
--   read_during_write_mode_port_* = NEW_DATA_NO_NBE_READ
--
-- NEW_DATA_NO_NBE_READ is the load-bearing one: a port that writes and reads
-- the same address in the same cycle sees the NEW data, not the old. Modelling
-- it as read-old (the naive `q <= mem(addr)` after the write) is a silent
-- one-cycle-stale bug in the cache tag path, so the write-first bypass below
-- is deliberate.
--
-- Read-during-write ACROSS ports is undefined in the hardware; these models
-- resolve it by process order, which is arbitrary but harmless because the
-- CPU never writes both ports at one address.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram is
   generic (
      addr_width : integer := 8;
      data_width : integer := 8
   );
   port (
      clock_a   : in  std_logic;
      clken_a   : in  std_logic := '1';
      address_a : in  std_logic_vector(addr_width-1 downto 0);
      data_a    : in  std_logic_vector(data_width-1 downto 0);
      wren_a    : in  std_logic := '0';
      q_a       : out std_logic_vector(data_width-1 downto 0);

      clock_b   : in  std_logic;
      clken_b   : in  std_logic := '1';
      address_b : in  std_logic_vector(addr_width-1 downto 0);
      data_b    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
      wren_b    : in  std_logic := '0';
      q_b       : out std_logic_vector(data_width-1 downto 0)
   );
end entity;

architecture sim of dpram is
   type mem_t is array(0 to (2**addr_width)-1) of std_logic_vector(data_width-1 downto 0);
   shared variable mem : mem_t := (others => (others => '0'));
begin
   process (clock_a)
   begin
      if rising_edge(clock_a) then
         if clken_a = '1' then
            if wren_a = '1' then
               mem(to_integer(unsigned(address_a))) := data_a;   -- write-first
            end if;
            q_a <= mem(to_integer(unsigned(address_a)));
         end if;
      end if;
   end process;

   process (clock_b)
   begin
      if rising_edge(clock_b) then
         if clken_b = '1' then
            if wren_b = '1' then
               mem(to_integer(unsigned(address_b))) := data_b;   -- write-first
            end if;
            q_b <= mem(to_integer(unsigned(address_b)));
         end if;
      end if;
   end process;
end architecture;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_1clk is
   generic (
      addr_width : integer := 8;
      data_width : integer := 8
   );
   port (
      clock     : in  std_logic;
      clken_a   : in  std_logic := '1';
      address_a : in  std_logic_vector(addr_width-1 downto 0);
      data_a    : in  std_logic_vector(data_width-1 downto 0);
      wren_a    : in  std_logic := '0';
      q_a       : out std_logic_vector(data_width-1 downto 0);

      clken_b   : in  std_logic := '1';
      address_b : in  std_logic_vector(addr_width-1 downto 0);
      data_b    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
      wren_b    : in  std_logic := '0';
      q_b       : out std_logic_vector(data_width-1 downto 0)
   );
end entity;

architecture sim of dpram_1clk is
begin
   idpram : entity work.dpram
   generic map (addr_width => addr_width, data_width => data_width)
   port map (
      clock_a => clock, clken_a => clken_a, address_a => address_a,
      data_a => data_a, wren_a => wren_a, q_a => q_a,
      clock_b => clock, clken_b => clken_b, address_b => address_b,
      data_b => data_b, wren_b => wren_b, q_b => q_b
   );
end architecture;


--------------------------------------------------------------------------
-- Mixed-width dual port.
--
-- Altera's mixed-width altsyncram maps the narrow port's word i onto the
-- LEAST significant slice of the wide word: for a 64-bit A / 32-bit B pair,
-- B address 2k is bits 31:0 of A word k and 2k+1 is bits 63:32. That is the
-- convention modelled here. It only becomes observable once the caches are
-- turned on, and it is worth re-deriving against a cache test then.
--------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_dif is
   generic (
      addr_width_a : integer := 8;
      data_width_a : integer := 8;
      addr_width_b : integer := 8;
      data_width_b : integer := 8
   );
   port (
      clock_a   : in  std_logic;
      address_a : in  std_logic_vector(addr_width_a-1 downto 0);
      data_a    : in  std_logic_vector(data_width_a-1 downto 0) := (others => '0');
      clken_a   : in  std_logic := '1';
      wren_a    : in  std_logic := '0';
      q_a       : out std_logic_vector(data_width_a-1 downto 0);
      cs_a      : in  std_logic := '1';

      clock_b   : in  std_logic;
      address_b : in  std_logic_vector(addr_width_b-1 downto 0) := (others => '0');
      data_b    : in  std_logic_vector(data_width_b-1 downto 0) := (others => '0');
      clken_b   : in  std_logic := '1';
      wren_b    : in  std_logic := '0';
      q_b       : out std_logic_vector(data_width_b-1 downto 0);
      cs_b      : in  std_logic := '1'
   );
end entity;

architecture sim of dpram_dif is
   -- `minimum`/`maximum` over integers are VHDL-2008 additions to
   -- std.standard. GHDL implements them, Quartus 17.0's VHDL-2008 mode does
   -- not, and reports `object "minimum" is used but not declared` - which
   -- reads like a missing `use` clause and is not one. Declared locally, so
   -- this file asks nothing of the standard library beyond VHDL-93.
   function imin (a, b : integer) return integer is
   begin
      if a < b then return a; else return b; end if;
   end function;

   function imax (a, b : integer) return integer is
   begin
      if a > b then return a; else return b; end if;
   end function;

   function clog2 (n : integer) return integer is
      variable r : integer := 0;
      variable v : integer := 1;
   begin
      while v < n loop v := v * 2; r := r + 1; end loop;
      return r;
   end function;

   -- BUILT OUT OF EQUAL-WIDTH RAMS ON PURPOSE, and that is the whole reason
   -- this entity is structural rather than behavioural.
   --
   -- Quartus 17.0 will not infer a mixed-width memory. Written the obvious
   -- way - one array, mem(addr*RATIO + i) - it does not match the RAM
   -- inference pass, so mem becomes registers, and two clocked processes may
   -- not both drive a register array:
   --    Error (10028): Can't resolve multiple constant drivers for net
   --                   "mem[0][31]" at dpram.vhd(206)
   -- Intel's own two-dimensional mixed-width template does no better here: it
   -- has a single writer, so it raises no error at all and quietly builds
   -- 128 Kbit of the instruction cache out of flip-flops, announced only as
   --    Info (10008): EDA Netlist Writer cannot regroup multidimensional
   --                  array "ram" into its bus
   -- The silent one is the dangerous one - it costs the fit, not the compile.
   -- Both were confirmed against 17.0.2 Lite before this was rewritten; do
   -- not fold it back into a behavioural model without re-checking that the
   -- fit report still shows M10Ks.
   --
   -- What does infer, reliably, is the plain equal-width true-dual-port
   -- template - which `dpram` above already is. So a mixed-width memory is
   -- RATIO of those side by side: the wide port writes every slice of one
   -- word at once, and the narrow port picks one slice with the low bits of
   -- its address. Same storage, same slice mapping, same one-cycle latency.
   constant UNIT  : integer := imin(data_width_a, data_width_b);
   constant RATIO : integer := imax(data_width_a, data_width_b) / UNIT;
   constant AWIDE : integer := imin(addr_width_a, addr_width_b);
   constant SELW  : integer := clog2(RATIO);

   type addr_arr is array(0 to RATIO-1) of std_logic_vector(AWIDE-1 downto 0);
   type unit_arr is array(0 to RATIO-1) of std_logic_vector(UNIT-1 downto 0);
   type bit_arr  is array(0 to RATIO-1) of std_logic;

   -- Per-slice connections. sa_* is always the outer port A's side of every
   -- slice and sb_* the outer port B's, whichever of the two is the wide one.
   signal sa_addr, sb_addr : addr_arr;
   signal sa_data, sb_data : unit_arr;
   signal sa_wr,   sb_wr   : bit_arr := (others => '0');
   signal sa_q,    sb_q    : unit_arr;

   signal q0 : std_logic_vector(data_width_a-1 downto 0) := (others => '0');
   signal q1 : std_logic_vector(data_width_b-1 downto 0) := (others => '0');
begin
   q_a <= q0 when cs_a = '1' else (others => '1');
   q_b <= q1 when cs_b = '1' else (others => '1');

   g_slices : for i in 0 to RATIO-1 generate
      u_slice : entity work.dpram
      generic map (addr_width => AWIDE, data_width => UNIT)
      port map (
         clock_a => clock_a, clken_a => clken_a, address_a => sa_addr(i),
         data_a  => sa_data(i), wren_a => sa_wr(i), q_a => sa_q(i),
         clock_b => clock_b, clken_b => clken_b, address_b => sb_addr(i),
         data_b  => sb_data(i), wren_b => sb_wr(i), q_b => sb_q(i));
   end generate;

   -- Which port is the wide one is a generic, so both wirings are written out
   -- and one is elaborated away. `if generate` twice with complementary
   -- conditions rather than VHDL-2008's `else generate`, which Quartus 17.0
   -- does not take. Equal widths make RATIO 1 and SELW 0: both ports take
   -- their _wide branch, the narrow branches - whose slice-select vectors
   -- would be null ranges - are never elaborated, and the whole thing
   -- degenerates to one plain dual-port RAM.

   -- ---- port A ----------------------------------------------------------
   ga_wide : if data_width_a >= data_width_b generate
      gw : for i in 0 to RATIO-1 generate
         sa_addr(i) <= address_a;
         sa_data(i) <= data_a((i+1)*UNIT-1 downto i*UNIT);
         sa_wr(i)   <= wren_a and cs_a;
         q0((i+1)*UNIT-1 downto i*UNIT) <= sa_q(i);
      end generate;
   end generate;

   ga_narrow : if data_width_a < data_width_b generate
      signal sel   : std_logic_vector(SELW-1 downto 0);
      signal sel_r : std_logic_vector(SELW-1 downto 0) := (others => '0');
   begin
      -- Slice from the LOW address bits: narrow word 2k is the least
      -- significant slice of wide word k, the altsyncram convention
      -- documented above the entity.
      sel <= address_a(SELW-1 downto 0);
      gn : for i in 0 to RATIO-1 generate
         sa_addr(i) <= address_a(addr_width_a-1 downto SELW);
         sa_data(i) <= data_a;
         sa_wr(i)   <= (wren_a and cs_a) when unsigned(sel) = i else '0';
      end generate;
      -- The select has to be delayed to meet the registered read data, and
      -- gated by the same clock enable or it slips whenever the port stalls.
      process (clock_a)
      begin
         if rising_edge(clock_a) then
            if clken_a = '1' then sel_r <= sel; end if;
         end if;
      end process;
      q0 <= sa_q(to_integer(unsigned(sel_r)));
   end generate;

   -- ---- port B ----------------------------------------------------------
   gb_wide : if data_width_b >= data_width_a generate
      gw : for i in 0 to RATIO-1 generate
         sb_addr(i) <= address_b;
         sb_data(i) <= data_b((i+1)*UNIT-1 downto i*UNIT);
         sb_wr(i)   <= wren_b and cs_b;
         q1((i+1)*UNIT-1 downto i*UNIT) <= sb_q(i);
      end generate;
   end generate;

   gb_narrow : if data_width_b < data_width_a generate
      signal sel   : std_logic_vector(SELW-1 downto 0);
      signal sel_r : std_logic_vector(SELW-1 downto 0) := (others => '0');
   begin
      sel <= address_b(SELW-1 downto 0);
      gn : for i in 0 to RATIO-1 generate
         sb_addr(i) <= address_b(addr_width_b-1 downto SELW);
         sb_data(i) <= data_b;
         sb_wr(i)   <= (wren_b and cs_b) when unsigned(sel) = i else '0';
      end generate;
      process (clock_b)
      begin
         if rising_edge(clock_b) then
            if clken_b = '1' then sel_r <= sel; end if;
         end if;
      end process;
      q1 <= sb_q(to_integer(unsigned(sel_r)));
   end generate;
end architecture;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_dif_be is
   generic (
      addr_width_a    : integer := 8;
      data_width_a    : integer := 8;
      addr_width_b    : integer := 8;
      data_width_b    : integer := 8;
      width_byteena_a : integer := 1;
      width_byteena_b : integer := 1
   );
   port (
      clock_a   : in  std_logic;
      address_a : in  std_logic_vector(addr_width_a-1 downto 0);
      data_a    : in  std_logic_vector(data_width_a-1 downto 0) := (others => '0');
      clken_a   : in  std_logic := '1';
      byteena_a : in  std_logic_vector(width_byteena_a-1 downto 0) := (others => '1');
      wren_a    : in  std_logic := '0';
      q_a       : out std_logic_vector(data_width_a-1 downto 0);
      cs_a      : in  std_logic := '1';

      clock_b   : in  std_logic;
      address_b : in  std_logic_vector(addr_width_b-1 downto 0) := (others => '0');
      data_b    : in  std_logic_vector(data_width_b-1 downto 0) := (others => '0');
      clken_b   : in  std_logic := '1';
      byteena_b : in  std_logic_vector(width_byteena_b-1 downto 0) := (others => '1');
      wren_b    : in  std_logic := '0';
      q_b       : out std_logic_vector(data_width_b-1 downto 0);
      cs_b      : in  std_logic := '1'
   );
end entity;

architecture sim of dpram_dif_be is
   -- `minimum`/`maximum` over integers are VHDL-2008 additions to
   -- std.standard. GHDL implements them, Quartus 17.0's VHDL-2008 mode does
   -- not, and reports `object "minimum" is used but not declared` - which
   -- reads like a missing `use` clause and is not one. Declared locally, so
   -- this file asks nothing of the standard library beyond VHDL-93.
   function imin (a, b : integer) return integer is
   begin
      if a < b then return a; else return b; end if;
   end function;

   function imax (a, b : integer) return integer is
   begin
      if a > b then return a; else return b; end if;
   end function;

   constant UNIT  : integer := imin(data_width_a, data_width_b);
   constant NSLICES : integer := imax(2**addr_width_a, 2**addr_width_b);
   constant RA    : integer := data_width_a / UNIT;
   constant RB    : integer := data_width_b / UNIT;
   constant BEA   : integer := data_width_a / width_byteena_a;
   constant BEB   : integer := data_width_b / width_byteena_b;

   type mem_t is array(0 to NSLICES-1) of std_logic_vector(UNIT-1 downto 0);
   shared variable mem : mem_t := (others => (others => '0'));

   signal q0 : std_logic_vector(data_width_a-1 downto 0) := (others => '0');
   signal q1 : std_logic_vector(data_width_b-1 downto 0) := (others => '0');
begin
   q_a <= q0 when cs_a = '1' else (others => '1');
   q_b <= q1 when cs_b = '1' else (others => '1');

   process (clock_a)
      variable base : integer;
      variable w    : std_logic_vector(data_width_a-1 downto 0);
   begin
      if rising_edge(clock_a) then
         if clken_a = '1' then
            base := to_integer(unsigned(address_a)) * RA;
            if wren_a = '1' and cs_a = '1' then
               for i in 0 to RA-1 loop
                  w((i+1)*UNIT-1 downto i*UNIT) := mem(base + i);
               end loop;
               for b in 0 to width_byteena_a-1 loop
                  if byteena_a(b) = '1' then
                     w((b+1)*BEA-1 downto b*BEA) := data_a((b+1)*BEA-1 downto b*BEA);
                  end if;
               end loop;
               for i in 0 to RA-1 loop
                  mem(base + i) := w((i+1)*UNIT-1 downto i*UNIT);
               end loop;
            end if;
            for i in 0 to RA-1 loop
               q0((i+1)*UNIT-1 downto i*UNIT) <= mem(base + i);
            end loop;
         end if;
      end if;
   end process;

   process (clock_b)
      variable base : integer;
      variable w    : std_logic_vector(data_width_b-1 downto 0);
   begin
      if rising_edge(clock_b) then
         if clken_b = '1' then
            base := to_integer(unsigned(address_b)) * RB;
            if wren_b = '1' and cs_b = '1' then
               for i in 0 to RB-1 loop
                  w((i+1)*UNIT-1 downto i*UNIT) := mem(base + i);
               end loop;
               for b in 0 to width_byteena_b-1 loop
                  if byteena_b(b) = '1' then
                     w((b+1)*BEB-1 downto b*BEB) := data_b((b+1)*BEB-1 downto b*BEB);
                  end if;
               end loop;
               for i in 0 to RB-1 loop
                  mem(base + i) := w((i+1)*UNIT-1 downto i*UNIT);
               end loop;
            end if;
            for i in 0 to RB-1 loop
               q1((i+1)*UNIT-1 downto i*UNIT) <= mem(base + i);
            end loop;
         end if;
      end if;
   end process;
end architecture;
