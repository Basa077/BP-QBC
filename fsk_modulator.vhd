--------------------------------------------------------------------------------
-- Frequency Shift Keying (FSK) Modulator
-- Dual-NCO architecture as specified in Chapter 3
-- Data = '1' → f1 = 1.0 MHz
-- Data = '0' → f0 = 0.9 MHz
-- 100 kHz separation ensures orthogonality over bit period
-- Constant amplitude, frequency encodes data
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity fsk_modulator is
    Port (
        clk         : in  STD_LOGIC;
        reset       : in  STD_LOGIC;
        data_in     : in  STD_LOGIC;
        phase_inc_f0: in  unsigned(31 downto 0);  -- For 0.9 MHz
        phase_inc_f1: in  unsigned(31 downto 0);  -- For 1.0 MHz
        signal_out  : out signed(11 downto 0)
    );
end fsk_modulator;

architecture Behavioral of fsk_modulator is

    -- Two independent phase accumulators (both always run)
    signal phase_acc_f0 : unsigned(31 downto 0) := (others => '0');
    signal phase_acc_f1 : unsigned(31 downto 0) := (others => '0');
    
    -- Sine LUT (shared, same as NCO)
    type sine_lut_type is array (0 to 31) of signed(11 downto 0);
    constant SINE_LUT : sine_lut_type := (
        to_signed(   0, 12),
        to_signed( 402, 12),
        to_signed( 785, 12),
        to_signed(1144, 12),
        to_signed(1448, 12),
        to_signed(1689, 12),
        to_signed(1858, 12),
        to_signed(1948, 12),
        to_signed(2047, 12),
        to_signed(1948, 12),
        to_signed(1858, 12),
        to_signed(1689, 12),
        to_signed(1448, 12),
        to_signed(1144, 12),
        to_signed( 785, 12),
        to_signed( 402, 12),
        to_signed(   0, 12),
        to_signed(-402, 12),
        to_signed(-785, 12),
        to_signed(-1144, 12),
        to_signed(-1448, 12),
        to_signed(-1689, 12),
        to_signed(-1858, 12),
        to_signed(-1948, 12),
        to_signed(-2048, 12),
        to_signed(-1948, 12),
        to_signed(-1858, 12),
        to_signed(-1689, 12),
        to_signed(-1448, 12),
        to_signed(-1144, 12),
        to_signed(-785, 12),
        to_signed(-402, 12)
    );
    
    signal addr_f0 : integer range 0 to 31;
    signal addr_f1 : integer range 0 to 31;
    signal sine_f0 : signed(11 downto 0);
    signal sine_f1 : signed(11 downto 0);

begin

    -- Both phase accumulators run continuously (maintains phase continuity)
    process(clk, reset)
    begin
        if reset = '1' then
            phase_acc_f0 <= (others => '0');
            phase_acc_f1 <= (others => '0');
        elsif rising_edge(clk) then
            phase_acc_f0 <= phase_acc_f0 + phase_inc_f0;
            phase_acc_f1 <= phase_acc_f1 + phase_inc_f1;
        end if;
    end process;
    
    -- LUT addresses from top 5 bits
    addr_f0 <= to_integer(phase_acc_f0(31 downto 27));
    addr_f1 <= to_integer(phase_acc_f1(31 downto 27));
    
    -- LUT lookups
    sine_f0 <= SINE_LUT(addr_f0);
    sine_f1 <= SINE_LUT(addr_f1);
    
    -- Data bit selects which frequency to output (MUX)
    process(clk, reset)
    begin
        if reset = '1' then
            signal_out <= (others => '0');
        elsif rising_edge(clk) then
            if data_in = '1' then
                signal_out <= sine_f1;  -- f1 = 1.0 MHz
            else
                signal_out <= sine_f0;  -- f0 = 0.9 MHz
            end if;
        end if;
    end process;

end Behavioral;