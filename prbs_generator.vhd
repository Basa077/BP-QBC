--------------------------------------------------------------------------------
-- PRBS-15 Generator
-- Polynomial: x^15 + x^14 + 1
-- Seed: "111111111111111"
-- Generates 32,767-bit pseudo-random sequence for BER testing
-- Includes startup counter to ensure clean initialization
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity prbs15_generator is
    Port (
        clk      : in  STD_LOGIC;
        reset    : in  STD_LOGIC;
        enable   : in  STD_LOGIC;
        data_out : out STD_LOGIC
    );
end prbs15_generator;

architecture Behavioral of prbs15_generator is
    signal lfsr : STD_LOGIC_VECTOR(14 downto 0) := "111111111111111";
    signal startup_counter : unsigned(3 downto 0) := (others => '0');
    signal running : STD_LOGIC := '0';
begin
    process(clk, reset)
    begin
        if reset = '1' then
            lfsr <= "111111111111111";
            startup_counter <= (others => '0');
            running <= '0';
        elsif rising_edge(clk) then
            -- Wait 10 cycles after reset before starting
            if startup_counter < 10 then
                startup_counter <= startup_counter + 1;
                running <= '0';
            else
                running <= '1';
                -- Counter holds at 10 (no further assignment), no overflow
            end if;
            
            -- Only shift when running and enabled
            if enable = '1' and running = '1' then
                lfsr <= lfsr(13 downto 0) & (lfsr(14) xor lfsr(13));
            end if;
        end if;
    end process;
    
    data_out <= lfsr(14);
end Behavioral;