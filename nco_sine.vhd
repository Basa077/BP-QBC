--------------------------------------------------------------------------------
-- Numerically Controlled Oscillator (NCO) / Direct Digital Synthesis (DDS)
-- 32-entry sine Look-Up Table, 12-bit signed output
-- Phase accumulator driven by configurable phase increment
-- For 1 MHz output at 8.33 MHz sampling: phase_inc = 2^32 * 1/8.33 ≈ 515,396,076
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity nco_sine is
    Port (
        clk        : in  STD_LOGIC;
        reset      : in  STD_LOGIC;
        phase_inc  : in  unsigned(31 downto 0);
        sine_out   : out signed(11 downto 0)
    );
end nco_sine;

architecture Behavioral of nco_sine is
    signal phase_acc : unsigned(31 downto 0) := (others => '0');
    
    -- Sine LUT: 32 entries covering 0 to 2π
    -- Values are 12-bit signed: -2048 to +2047
    -- Formula: round(2047 * sin(2*pi*i/32))
    type sine_lut_type is array (0 to 31) of signed(11 downto 0);
    constant SINE_LUT : sine_lut_type := (
        to_signed(   0, 12),  -- 0°
        to_signed( 402, 12),  -- 11.25°
        to_signed( 785, 12),  -- 22.5°
        to_signed(1144, 12),  -- 33.75°
        to_signed(1448, 12),  -- 45°
        to_signed(1689, 12),  -- 56.25°
        to_signed(1858, 12),  -- 67.5°
        to_signed(1948, 12),  -- 78.75°
        to_signed(2047, 12),  -- 90°   (PEAK)
        to_signed(1948, 12),  -- 101.25°
        to_signed(1858, 12),  -- 112.5°
        to_signed(1689, 12),  -- 123.75°
        to_signed(1448, 12),  -- 135°
        to_signed(1144, 12),  -- 146.25°
        to_signed( 785, 12),  -- 157.5°
        to_signed( 402, 12),  -- 168.75°
        to_signed(   0, 12),  -- 180°  (zero crossing)
        to_signed(-402, 12),  -- 191.25°
        to_signed(-785, 12),  -- 202.5°
        to_signed(-1144, 12), -- 213.75°
        to_signed(-1448, 12), -- 225°
        to_signed(-1689, 12), -- 236.25°
        to_signed(-1858, 12), -- 247.5°
        to_signed(-1948, 12), -- 258.75°
        to_signed(-2048, 12), -- 270°  (VALLEY)
        to_signed(-1948, 12), -- 281.25°
        to_signed(-1858, 12), -- 292.5°
        to_signed(-1689, 12), -- 303.75°
        to_signed(-1448, 12), -- 315°
        to_signed(-1144, 12), -- 326.25°
        to_signed(-785, 12),  -- 337.5°
        to_signed(-402, 12)   -- 348.75°
    );
    
    signal lut_addr : integer range 0 to 31;
    
begin
    -- Phase accumulator
    process(clk, reset)
    begin
        if reset = '1' then
            phase_acc <= (others => '0');
        elsif rising_edge(clk) then
            phase_acc <= phase_acc + phase_inc;
        end if;
    end process;
    
    -- Use top 5 bits of phase accumulator as LUT address
    lut_addr <= to_integer(phase_acc(31 downto 27));
    
    -- Output sine value from LUT
    sine_out <= SINE_LUT(lut_addr);
    
end Behavioral;