library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity cpu_mul is
   port
   (
      clk       : in  std_logic;
      sign      : in  std_logic;
      value1_in : in  std_logic_vector(63 downto 0);
      value2_in : in  std_logic_vector(63 downto 0);
      result    : out std_logic_vector(127 downto 0)
   );
end entity;

architecture arch of cpu_mul is
begin
   -- The R4300 pipeline expects one registered cycle of multiplier latency.
   process(clk)
   begin
      if rising_edge(clk) then
         if sign = '1' then
            result <= std_logic_vector(signed(value1_in) * signed(value2_in));
         else
            result <= std_logic_vector(unsigned(value1_in) * unsigned(value2_in));
         end if;
      end if;
   end process;
end architecture;
