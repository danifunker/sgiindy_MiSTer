library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all; 
use ieee.math_real.all;   

entity SyncFifoFallThroughMLAB is
   generic 
   (
      SIZE              : integer;
      DATAWIDTH         : integer;
      NEARFULLDISTANCE  : integer;
      NEAREMPTYDISTANCE : integer := 0
   );
   port 
   ( 
      clk         : in  std_logic;
      reset       : in  std_logic;
                  
      Din         : in  std_logic_vector(DATAWIDTH - 1 downto 0);
      Wr          : in  std_logic; 
      Full        : out std_logic := '0';
      NearFull    : out std_logic := '0';
         
      Dout        : out std_logic_vector(DATAWIDTH - 1 downto 0) := (others => '0');
      Rd          : in  std_logic;
      Empty       : out std_logic := '1';
      NearEmpty   : out std_logic := '0'
   );
end;

architecture arch of SyncFifoFallThroughMLAB is

   constant SIZEBITS : integer := integer(ceil(log2(real(SIZE))));

   signal wrcnt   : unsigned(SIZEBITS - 1 downto 0) := (others => '0');
   signal rdcnt   : unsigned(SIZEBITS - 1 downto 0) := (others => '0');
 
   signal fifocnt : unsigned(SIZEBITS - 1 downto 0) := (others => '0');
 
   signal full_wire     : std_logic;
   signal empty_wire    : std_logic;
   signal wr_accept     : std_logic;
   signal rd_accept     : std_logic;

begin

   iRamMLAB: entity work.RamMLAB
   generic map
   (
      width           => DATAWIDTH,
      widthad         => SIZEBITS
   )
   port map
   (
      inclock         => clk,
      wren            => wr_accept,
      data            => Din,
      wraddress       => std_logic_vector(wrcnt),
      rdaddress       => std_logic_vector(rdcnt),
      q               => Dout
   );


   full_wire      <= '1' when fifocnt = (SIZEBITS - 1 downto 0 => '1')  else '0';
   empty_wire     <= '1' when fifocnt = 0                               else '0';
   rd_accept      <= Rd and not empty_wire;
   -- A simultaneous read frees the current head, so a full FIFO may replace
   -- it on the same edge without overwriting any unread entry.
   wr_accept      <= Wr and (not full_wire or rd_accept);

   process(clk)
      variable newCount : unsigned(SIZEBITS - 1 downto 0);
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            wrcnt   <= (others => '0');
            rdcnt   <= (others => '0');
            fifocnt <= (others => '0');
            Full    <= '0';
            Empty   <= '1';
            NearFull  <= '0';
            NearEmpty <= '0';
         else
            newCount := fifocnt;
            if (wr_accept = '1') then
               if (rd_accept = '0') then
                  newCount := newCount + 1;
               end if;
            elsif (rd_accept = '1') then
               newCount := newCount - 1;
            end if;
            
            if (newCount < NEARFULLDISTANCE) then
               NearFull <= '0';
            else
               NearFull <= '1';
            end if;            
            
            if (newCount >= NEAREMPTYDISTANCE) then
               NearEmpty <= '0';
            else
               NearEmpty <= '1';
            end if;
         
            if (wr_accept = '1') then
               wrcnt <= wrcnt+1;
            end if;
            
            if (rd_accept = '1') then
               rdcnt <= rdcnt+1;
            end if;
            
            if (newCount = 0) then
               Empty <= '1'; 
            else
               Empty <= '0';
            end if;
            
            if (newCount = (SIZEBITS - 1 downto 0 => '1')) then
               Full <= '1'; 
            else
               Full <= '0';
            end if;
            
            fifocnt <= newCount;
            
         end if;
      end if;
   end process;

end architecture;
