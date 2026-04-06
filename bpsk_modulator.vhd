--------------------------------------------------------------------------------
-- Binary Phase Shift Keying (BPSK) Modulator
-- Data = '1' → carrier at 0° phase   (+sin)
-- Data = '0' → carrier at 180° phase (-sin)
-- Constant amplitude, phase encodes data
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity bpsk_modulator is
    Port (
        clk         : in  STD_LOGIC;
        reset       : in  STD_LOGIC;
        data_in     : in  STD_LOGIC;
        carrier_in  : in  signed(11 downto 0);
        signal_out  : out signed(11 downto 0)
    );
end bpsk_modulator;

architecture Behavioral of bpsk_modulator is
begin
    process(clk, reset)
    begin
        if reset = '1' then
            signal_out <= (others => '0');
        elsif rising_edge(clk) then
            if data_in = '1' then
                signal_out <= carrier_in;       -- 0° phase
            else
                signal_out <= -carrier_in;      -- 180° phase (invert)
            end if;
        end if;
    end process;
end Behavioral;