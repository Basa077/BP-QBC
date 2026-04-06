--------------------------------------------------------------------------------
-- Clock Divider
-- Input:  100 MHz (Basys 3 system clock)
-- Output: ~8.33 MHz (100 MHz / 12) for 8x oversampling of 1 MHz carrier
-- Method: Counter divides by 6, toggle output => divide by 12 total
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity clk_divider is
    Port (
        clk_in  : in  STD_LOGIC;
        reset   : in  STD_LOGIC;
        clk_out : out STD_LOGIC
    );
end clk_divider;

architecture Behavioral of clk_divider is
    signal counter : unsigned(2 downto 0) := (others => '0');
    signal clk_reg : STD_LOGIC := '0';
begin 
    process(clk_in, reset)
    begin
        if reset = '1' then
            counter <= (others => '0');
            clk_reg <= '0';
        elsif rising_edge(clk_in) then
            if counter = 5 then
                counter <= (others => '0');
                clk_reg <= not clk_reg;
            else
                counter <= counter + 1;
            end if;
        end if;
    end process;
    
    clk_out <= clk_reg;
end Behavioral;