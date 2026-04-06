--------------------------------------------------------------------------------
-- Basys 3 Transmitter - Top Level Module
-- BP-QBC Modulation Comparison System
-- v2: Added 256-bit preamble (1010...) before 4096-bit PRBS payload
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity basys3_transmitter is
    Port (
        CLK         : in  STD_LOGIC;
        BTNC        : in  STD_LOGIC;
        SW          : in  STD_LOGIC_VECTOR(15 downto 0);
        LED         : out STD_LOGIC_VECTOR(15 downto 0);
        JA          : out STD_LOGIC_VECTOR(7 downto 0);
        SYNC_CLK    : out STD_LOGIC
    );
end basys3_transmitter;

architecture Behavioral of basys3_transmitter is
    
    -- =========================================================================
    -- Component declarations
    -- =========================================================================
    component clk_divider is
        Port (clk_in : in STD_LOGIC; reset : in STD_LOGIC; clk_out : out STD_LOGIC);
    end component;
    
    component prbs15_generator is
        Port (clk : in STD_LOGIC; reset : in STD_LOGIC; enable : in STD_LOGIC; data_out : out STD_LOGIC);
    end component;
    
    component nco_sine is
        Port (clk : in STD_LOGIC; reset : in STD_LOGIC; phase_inc : in unsigned(31 downto 0); sine_out : out signed(11 downto 0));
    end component;
    
    component ook_modulator is
        Port (clk : in STD_LOGIC; reset : in STD_LOGIC; data_in : in STD_LOGIC; carrier_in : in signed(11 downto 0); signal_out : out signed(11 downto 0));
    end component;
    
    component bpsk_modulator is
        Port (clk : in STD_LOGIC; reset : in STD_LOGIC; data_in : in STD_LOGIC; carrier_in : in signed(11 downto 0); signal_out : out signed(11 downto 0));
    end component;
    
    component fsk_modulator is
        Port (clk : in STD_LOGIC; reset : in STD_LOGIC; data_in : in STD_LOGIC; 
              phase_inc_f0 : in unsigned(31 downto 0); phase_inc_f1 : in unsigned(31 downto 0);
              signal_out : out signed(11 downto 0));
    end component;
    
    -- =========================================================================
    -- Constants
    -- =========================================================================
    constant PHASE_INC_1M0  : unsigned(31 downto 0) := x"03333333";
    constant PHASE_INC_0M9  : unsigned(31 downto 0) := x"02E147AE";
    
    -- Frame structure: 256-bit preamble + 4096-bit PRBS payload
    constant PREAMBLE_LEN : unsigned(15 downto 0) := to_unsigned(256, 16);
    constant PAYLOAD_LEN  : unsigned(15 downto 0) := to_unsigned(4096, 16);
    
    -- =========================================================================
    -- Internal signals
    -- =========================================================================
    signal reset_internal : STD_LOGIC;
    signal clk_8mhz      : STD_LOGIC;
    
    -- Sync Clock
    signal sync_clk_reg : STD_LOGIC := '0';
    
    signal data_clk_counter : unsigned(9 downto 0) := (others => '0');
    signal data_clk_enable  : STD_LOGIC := '0';
    signal current_data_bit : STD_LOGIC := '0';
    
    -- PRBS
    signal prbs_data    : STD_LOGIC;
    
    -- Frame generator
    signal frame_cnt     : unsigned(15 downto 0) := (others => '0');
    signal tx_bit        : std_logic := '0';
    signal preamble_bit  : std_logic := '0';
    
    
    
    -- NCO carrier
    signal carrier_sine : signed(11 downto 0);
    
    -- Modulator outputs
    signal ook_output   : signed(11 downto 0);
    signal bpsk_output  : signed(11 downto 0);
    signal fsk_output   : signed(11 downto 0);
    
    -- Selected output
    signal modulated_12bit : signed(11 downto 0);
    signal modulated_8bit  : signed(7 downto 0);
    signal dac_unsigned    : unsigned(7 downto 0);
    
    -- Slow PRBS indicator
    signal slow_counter : unsigned(23 downto 0) := (others => '0');
    signal slow_prbs    : STD_LOGIC := '0';

begin

    reset_internal <= BTNC;

    -- =========================================================================
    -- Clock divider: 100 MHz -> 8.33 MHz
    -- =========================================================================
    U_CLK_DIV: clk_divider 
        port map (clk_in => CLK, reset => reset_internal, clk_out => clk_8mhz);

    -- =========================================================================
    -- Data rate: 8.33 MHz / 200 = 41.67 kbps
    -- Now latches tx_bit (framed) instead of prbs_data directly
    -- =========================================================================
    process(clk_8mhz, reset_internal)
    begin
        if reset_internal = '1' then
            data_clk_counter <= (others => '0');
            data_clk_enable  <= '0';
            current_data_bit <= '0';
        elsif rising_edge(clk_8mhz) then
            if data_clk_counter = 999 then
                data_clk_counter <= (others => '0');
                data_clk_enable  <= '1';
                current_data_bit <= tx_bit;
            else
                data_clk_counter <= data_clk_counter + 1;
                data_clk_enable  <= '0';
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Frame generator: 256-bit preamble (1010...) + 4096-bit PRBS payload
    -- Repeats continuously
    process(clk_8mhz, reset_internal)
      variable pb : std_logic;
    begin
        if reset_internal = '1' then
            frame_cnt    <= (others => '0');
            preamble_bit <= '0';
            tx_bit       <= '0';
        elsif rising_edge(clk_8mhz) then
            if data_clk_enable = '1' then
                pb := not preamble_bit;
                preamble_bit <= pb;

                if frame_cnt < PREAMBLE_LEN then
                    tx_bit <= pb;
                else
                    tx_bit <= prbs_data;
                end if;

                if frame_cnt = (PREAMBLE_LEN + PAYLOAD_LEN - 1) then
                    frame_cnt <= (others => '0');
                    preamble_bit <= '0';
                else
                    frame_cnt <= frame_cnt + 1;
                end if;
            end if;
        end if;
    end process;
     
  -- =========================================================================
    -- Synchronization Clock Generation (For STM32 Interrupt)
    -- Toggles exactly on the bit boundaries.
    -- =========================================================================
 -- CORRECT SYNC CLOCK (pulse, don't toggle!)
        process(clk_8mhz, reset_internal)
        begin
            if reset_internal = '1' then
                sync_clk_reg <= '0';
            elsif rising_edge(clk_8mhz) then
                if data_clk_enable = '1' then
                    sync_clk_reg <= '1';    -- SHORT PULSE START
                else
                    sync_clk_reg <= '0';    -- PULSE END
                end if;
            end if;
        end process;
        SYNC_CLK <= sync_clk_reg;
        
    -- Assign the register to the physical output pin
    SYNC_CLK <= sync_clk_reg;

    -- =========================================================================
    -- PRBS-15 generator (shifts once per data bit via enable)
    -- =========================================================================
    U_PRBS: prbs15_generator 
        port map (
            clk    => clk_8mhz, 
            reset  => reset_internal, 
            enable => data_clk_enable, 
            data_out => prbs_data
        );

    -- =========================================================================
    -- NCO: carrier (used by OOK and BPSK)
    -- =========================================================================
    U_NCO: nco_sine 
        port map (
            clk       => clk_8mhz, 
            reset     => reset_internal, 
            phase_inc => PHASE_INC_1M0, 
            sine_out  => carrier_sine
        );

    -- =========================================================================
    -- Three modulators running in parallel
    -- =========================================================================
    U_OOK: ook_modulator 
        port map (
            clk => clk_8mhz, reset => reset_internal, 
            data_in => current_data_bit, carrier_in => carrier_sine, 
            signal_out => ook_output
        );
    
    U_BPSK: bpsk_modulator 
        port map (
            clk => clk_8mhz, reset => reset_internal, 
            data_in => current_data_bit, carrier_in => carrier_sine, 
            signal_out => bpsk_output
        );
    
    U_FSK: fsk_modulator 
        port map (
            clk => clk_8mhz, reset => reset_internal, 
            data_in => current_data_bit, 
            phase_inc_f0 => PHASE_INC_0M9, 
            phase_inc_f1 => PHASE_INC_1M0, 
            signal_out => fsk_output
        );

    -- =========================================================================
    -- Modulation output MUX (SW1:SW0 selects scheme)
    -- =========================================================================
    process(clk_8mhz, reset_internal)
    begin
        if reset_internal = '1' then
            modulated_12bit <= (others => '0');
        elsif rising_edge(clk_8mhz) then
            case SW(1 downto 0) is
                when "00"   => modulated_12bit <= ook_output;
                when "01"   => modulated_12bit <= bpsk_output;
                when "10"   => modulated_12bit <= fsk_output;
                when others => modulated_12bit <= fsk_output;
            end case;
        end if;
    end process;

    -- =========================================================================
    -- 12-bit signed -> 8-bit unsigned for R2R DAC
    -- =========================================================================
    modulated_8bit <= modulated_12bit(11 downto 4);
    
    -- NEW line:
    dac_unsigned <= unsigned(std_logic_vector(modulated_8bit) xor x"80");  -- flips sign bit = perfect offset binary
    JA <= std_logic_vector(dac_unsigned);
    
    --what i changed
   -- dac_unsigned   <= unsigned(modulated_8bit) + 128;
   -- JA <= std_logic_vector(dac_unsigned);

    -- =========================================================================
    -- Slow PRBS sampler for visible LED blinking
    -- =========================================================================
    process(CLK)
    begin
        if rising_edge(CLK) then
            if reset_internal = '1' then
                slow_counter <= (others => '0');
                slow_prbs <= '0';
            else
                slow_counter <= slow_counter + 1;
                if slow_counter = 0 then
                    slow_prbs <= prbs_data;
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- LED debug outputs
    -- =========================================================================
    LED(15)          <= prbs_data;
    LED(14)          <= SW(1);
    LED(13)          <= SW(0);
    LED(12)          <= slow_prbs;
    LED(11 downto 4) <= std_logic_vector(dac_unsigned);
    LED(3 downto 0)  <= std_logic_vector(modulated_12bit(3 downto 0));

end Behavioral;