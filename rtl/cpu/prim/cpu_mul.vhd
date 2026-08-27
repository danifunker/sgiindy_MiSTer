-- Behavioural stand-in for cpu_mul.vhd's altera_mult_add (64x64 -> 128).
--
-- The megafunction is configured with input_a0/b0_latency_clock = CLOCK0 and
-- output_register = CLOCK0, i.e. two register stages: operands in, product
-- out. cpu.vhd sets hiloWait <= 4 when it latches the operands and reads
-- mulResult when hiloWait reaches 1 -- four clocks later -- so any latency up
-- to four is safe. Two keeps the model faithful to the hardware it replaces.
--
-- `sign` is wired to both signa and signb, so the operands are either both
-- signed or both unsigned; there is no mixed case to model.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_mul is
   port (
      clk       : in  std_logic;
      sign      : in  std_logic;
      value1_in : in  std_logic_vector(63 downto 0);
      value2_in : in  std_logic_vector(63 downto 0);
      result    : out std_logic_vector(127 downto 0)
   );
end entity;

architecture sim of cpu_mul is
   signal prod : std_logic_vector(127 downto 0) := (others => '0');
begin
   process (clk)
      variable p : std_logic_vector(127 downto 0);
   begin
      if rising_edge(clk) then
         if sign = '1' then
            p := std_logic_vector(signed(value1_in) * signed(value2_in));
         else
            p := std_logic_vector(unsigned(value1_in) * unsigned(value2_in));
         end if;
         prod   <= p;
         result <= prod;
      end if;
   end process;
end architecture;
