-- Behavioural stand-in for RamMLAB.vhd's altdpram (MLAB LUTRAM).
--   write port : synchronous on inclock (indata/wraddress/wrcontrol = INCLOCK)
--   read  port : asynchronous (rdaddress_reg/outdata_reg = UNREGISTERED)
-- read_during_write_mode_mixed_ports = CONSTRAINED_DONT_CARE, so the
-- same-cycle write-then-read value is unspecified; old data is what an
-- MLAB actually returns and what this models.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity RamMLAB is
   generic
   (
      width           :  natural;
      width_byteena   :  natural := 1;
      widthad         :  natural
   );
   port
   (
      inclock         : in std_logic;
      wren            : in std_logic;
      data            : in std_logic_vector(width-1 downto 0);
      wraddress       : in std_logic_vector(widthad-1 downto 0);
      rdaddress       : in std_logic_vector(widthad-1 downto 0);
      q               : out std_logic_vector(width-1 downto 0)
   );
end entity;

architecture rtl of RamMLAB is
   type mem_t is array(0 to (2**widthad)-1) of std_logic_vector(width-1 downto 0);
   signal mem : mem_t := (others => (others => '0'));
begin
   process (inclock)
   begin
      if rising_edge(inclock) then
         if wren = '1' then
            mem(to_integer(unsigned(wraddress))) <= data;
         end if;
      end if;
   end process;

   q <= mem(to_integer(unsigned(rdaddress)));
end architecture;
