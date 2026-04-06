--------------------------------------------------------------------------------
-- On-Off Keying (OOK) Modulator
-- Data = '1' → carrier (sine wave) output
-- Data = '0' → zero (silence)
-- Simplest modulation scheme, amplitude-based
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ook_modulator is
    Port (
        clk         : in  STD_LOGIC;
        reset       : in  STD_LOGIC;
        data_in     : in  STD_LOGIC;
        carrier_in  : in  signed(11 downto 0);
        signal_out  : out signed(11 downto 0)
    );
end ook_modulator;

architecture Behavioral of ook_modulator is
begin
    process(clk, reset)
    begin
        if reset = '1' then
            signal_out <= (others => '0');
        elsif rising_edge(clk) then
            if data_in = '1' then
                signal_out <= carrier_in;           -- Transmit carrier
            else
                signal_out <= to_signed(0, 12);     -- Silence (zero)
            end if;
        end if;
    end process;
end Behavioral;