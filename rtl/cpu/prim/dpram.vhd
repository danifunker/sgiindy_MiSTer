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
   -- Store at the narrower granularity; the wider port is a slice gather.
   constant UNIT     : integer := minimum(data_width_a, data_width_b);
   constant NSLICES    : integer := maximum(2**addr_width_a, 2**addr_width_b);
   constant RATIO_A  : integer := data_width_a / UNIT;
   constant RATIO_B  : integer := data_width_b / UNIT;

   type mem_t is array(0 to NSLICES-1) of std_logic_vector(UNIT-1 downto 0);
   shared variable mem : mem_t := (others => (others => '0'));

   signal q0 : std_logic_vector(data_width_a-1 downto 0) := (others => '0');
   signal q1 : std_logic_vector(data_width_b-1 downto 0) := (others => '0');
begin
   q_a <= q0 when cs_a = '1' else (others => '1');
   q_b <= q1 when cs_b = '1' else (others => '1');

   process (clock_a)
      variable base : integer;
   begin
      if rising_edge(clock_a) then
         if clken_a = '1' then
            base := to_integer(unsigned(address_a)) * RATIO_A;
            if wren_a = '1' and cs_a = '1' then
               for i in 0 to RATIO_A-1 loop
                  mem(base + i) := data_a((i+1)*UNIT-1 downto i*UNIT);
               end loop;
            end if;
            for i in 0 to RATIO_A-1 loop
               q0((i+1)*UNIT-1 downto i*UNIT) <= mem(base + i);
            end loop;
         end if;
      end if;
   end process;

   process (clock_b)
      variable base : integer;
   begin
      if rising_edge(clock_b) then
         if clken_b = '1' then
            base := to_integer(unsigned(address_b)) * RATIO_B;
            if wren_b = '1' and cs_b = '1' then
               for i in 0 to RATIO_B-1 loop
                  mem(base + i) := data_b((i+1)*UNIT-1 downto i*UNIT);
               end loop;
            end if;
            for i in 0 to RATIO_B-1 loop
               q1((i+1)*UNIT-1 downto i*UNIT) <= mem(base + i);
            end loop;
         end if;
      end if;
   end process;
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
   constant UNIT  : integer := minimum(data_width_a, data_width_b);
   constant NSLICES : integer := maximum(2**addr_width_a, 2**addr_width_b);
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
