
--------------------------------------------------------------------------------
-- FSK-Only Receiver
-- Built on Gemini's proven architecture
--
-- Algorithm: Zero-crossing count per bit period
-- For each ADC sample, track sign of (sample - DC).
-- Each sign change = one zero crossing.
-- Higher frequency = more crossings = bit 1
-- Lower frequency = fewer crossings = bit 0
--
-- DC tracked via unsigned average (same as Gemini's approach).
-- Alternatively, we can use the differential method:
--   track sign of (sample[n] - sample[n-1]) changes,
--   but zero-crossings of the raw waveform are more standard for FSK.
--
-- We use a simple running DC estimate to center the signal,
-- with a slow IIR that won't chase the carrier.
--
-- TX must be set to SW="10" (FSK mode)
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity basys3_receiver is
    Port (
        CLK         : in  STD_LOGIC;
        BTNC        : in  STD_LOGIC;
        LED         : out STD_LOGIC_VECTOR(11 downto 0);
        vauxp6      : in  STD_LOGIC;
        vauxn6      : in  STD_LOGIC;
        SYNC_CLK_IN : in  STD_LOGIC;
        UART_TX     : out STD_LOGIC
    );
end basys3_receiver;

architecture Behavioral of basys3_receiver is
    component xadc_wiz_0 is
        port (
            daddr_in : in STD_LOGIC_VECTOR(6 downto 0); den_in : in STD_LOGIC;
            di_in : in STD_LOGIC_VECTOR(15 downto 0); dwe_in : in STD_LOGIC;
            do_out : out STD_LOGIC_VECTOR(15 downto 0); drdy_out : out STD_LOGIC;
            dclk_in : in STD_LOGIC; reset_in : in STD_LOGIC;
            vauxp6 : in STD_LOGIC; vauxn6 : in STD_LOGIC;
            busy_out : out STD_LOGIC; channel_out : out STD_LOGIC_VECTOR(4 downto 0);
            eoc_out : out STD_LOGIC; eos_out : out STD_LOGIC;
            alarm_out : out STD_LOGIC; vp_in : in STD_LOGIC; vn_in : in STD_LOGIC
        );
    end component;

    constant UART_DIV    : integer := 868;
    constant PAYLOAD_LEN : integer := 4096;

    signal xadc_data : std_logic_vector(15 downto 0);
    signal xadc_drdy, xadc_eoc : std_logic;

    -- State
    type rx_state_t is (ST_WAIT, ST_LEARN_DC, ST_FIND_SYNC, ST_PREAMBLE, ST_PAYLOAD, ST_PRINT);
    signal rx_state : rx_state_t := ST_WAIT;

    -- ADC
    signal adc_raw   : unsigned(11 downto 0) := (others => '0');
    signal adc_valid : std_logic := '0';

    -- DC learning (unsigned, average of 50000 samples)
    signal dc_sum    : unsigned(31 downto 0) := (others => '0');
    signal dc_cnt    : unsigned(15 downto 0) := (others => '0');
    signal dc_done   : std_logic := '0';
    signal dc_level  : unsigned(11 downto 0) := to_unsigned(50, 12);

    -- Zero-crossing detection
    signal zc_count  : unsigned(7 downto 0) := (others => '0');
    signal last_above: std_logic := '0';  -- '1' if last sample was above DC
    signal zc_valid  : std_logic := '0';  -- has at least one sample been classified

    -- Sample counter
    signal sample_n  : unsigned(7 downto 0) := (others => '0');
    signal diag_spb  : unsigned(7 downto 0) := (others => '0');

    -- SYNC_CLK
    signal sd1, sd2, sd3 : std_logic := '0';
    signal deb : unsigned(11 downto 0) := (others => '0');
    signal bit_edge : std_logic := '0';

    -- Wait
    signal wait_cnt : unsigned(9 downto 0) := (others => '0');

    -- FSK threshold (adaptive, frozen during payload)
    signal zc_max      : unsigned(7 downto 0) := (others => '0');
    signal zc_min      : unsigned(7 downto 0) := x"FF";
    signal zc_thresh   : unsigned(7 downto 0) := to_unsigned(10, 8);
    signal thresh_frozen : std_logic := '0';

    -- Bit decision
    signal bit_val : std_logic := '0';
    signal bit_rdy : std_logic := '0';

    -- Sync
    signal sr     : std_logic_vector(7 downto 0) := (others => '0');
    signal sr_run : unsigned(3 downto 0) := (others => '0');

    -- BER
    signal pay_idx  : unsigned(12 downto 0) := (others => '0');
    signal ber_sr_n : std_logic_vector(14 downto 0) := (others => '0');
    signal ber_sr_i : std_logic_vector(14 downto 0) := (others => '0');
    signal err_n    : unsigned(12 downto 0) := (others => '0');
    signal err_i    : unsigned(12 downto 0) := (others => '0');
    signal ber_final: unsigned(12 downto 0) := (others => '0');
    signal frame_n  : unsigned(7 downto 0) := (others => '0');

    -- UART
    signal tx_reg   : std_logic := '1';
    signal tx_shift : std_logic_vector(9 downto 0) := "1111111111";
    signal tx_busy  : std_logic := '0';
    signal tx_bcnt  : unsigned(3 downto 0) := (others => '0');
    signal tx_ccnt  : unsigned(9 downto 0) := (others => '0');

    -- Print
    signal pr_step   : unsigned(4 downto 0) := (others => '0');
    signal pr_active : std_logic := '0';
    signal pr_done   : std_logic := '0';

    signal hb : unsigned(25 downto 0) := (others => '0');

begin

    U_XADC : xadc_wiz_0 port map (
        daddr_in => "0010110", den_in => xadc_eoc, di_in => x"0000", dwe_in => '0',
        do_out => xadc_data, drdy_out => xadc_drdy, dclk_in => CLK, reset_in => BTNC,
        vauxp6 => vauxp6, vauxn6 => vauxn6, busy_out => open, channel_out => open,
        eoc_out => xadc_eoc, eos_out => open, alarm_out => open, vp_in => '0', vn_in => '0'
    );

    process(CLK)
        variable tx_byte : std_logic_vector(7 downto 0);
        variable d4      : unsigned(3 downto 0);
        variable exp_bit : std_logic;
        variable cur_above : std_logic;
    begin
        if rising_edge(CLK) then
            if BTNC = '1' then
                rx_state <= ST_WAIT;
                adc_valid <= '0';
                dc_sum <= (others => '0'); dc_cnt <= (others => '0'); dc_done <= '0';
                dc_level <= to_unsigned(50, 12);
                zc_count <= (others => '0'); last_above <= '0'; zc_valid <= '0';
                sample_n <= (others => '0');
                sd1 <= '0'; sd2 <= '0'; sd3 <= '0'; deb <= (others => '0');
                wait_cnt <= (others => '0');
                zc_max <= (others => '0'); zc_min <= x"FF";
                zc_thresh <= to_unsigned(10, 8); thresh_frozen <= '0';
                bit_val <= '0'; bit_rdy <= '0';
                sr <= (others => '0'); sr_run <= (others => '0');
                pay_idx <= (others => '0');
                err_n <= (others => '0'); err_i <= (others => '0');
                ber_final <= (others => '0'); frame_n <= (others => '0');
                tx_reg <= '1'; tx_busy <= '0'; tx_shift <= "1111111111";
                pr_step <= (others => '0'); pr_active <= '0'; pr_done <= '0';
                hb <= (others => '0');
            else
                -- ===== ADC =====
                adc_valid <= '0';
                if xadc_drdy = '1' then
                    adc_raw <= unsigned(xadc_data(15 downto 4));
                    adc_valid <= '1';
                end if;

                -- ===== SYNC_CLK =====
                sd1 <= SYNC_CLK_IN; sd2 <= sd1; sd3 <= sd2;
                bit_edge <= '0';
                if deb > 0 then deb <= deb - 1; end if;
                if sd2 = '1' and sd3 = '0' and deb = 0 then
                    bit_edge <= '1';
                    deb <= to_unsigned(1000, 12);
                end if;

                -- ===== Per-sample processing =====
                if adc_valid = '1' and rx_state /= ST_PRINT and rx_state /= ST_WAIT then
                    if dc_done = '0' then
                        -- DC learning: accumulate sum
                        dc_sum <= dc_sum + resize(adc_raw, 32);
                        dc_cnt <= dc_cnt + 1;
                        if dc_cnt = 49999 then
                            dc_level <= resize(dc_sum / 50000, 12);
                            dc_done <= '1';
                        end if;
                    else
                        -- Zero-crossing detection with hysteresis
                        -- Use deadband: only count if clearly above or below DC
                        if adc_raw > dc_level + 50 then
                            cur_above := '1';
                        elsif adc_raw < dc_level - 50 then
                            cur_above := '0';
                        else
                            -- In deadband, keep previous state
                            cur_above := last_above;
                        end if;

                        if zc_valid = '1' then
                            if cur_above /= last_above then
                                zc_count <= zc_count + 1;
                            end if;
                        end if;
                        last_above <= cur_above;
                        zc_valid <= '1';

                        sample_n <= sample_n + 1;
                    end if;
                end if;

                -- ===== Bit boundary =====
                bit_rdy <= '0';
                if bit_edge = '1' and rx_state /= ST_PRINT then
                    diag_spb <= sample_n;

                    if rx_state = ST_WAIT then
                        wait_cnt <= wait_cnt + 1;
                        if wait_cnt = 499 then rx_state <= ST_LEARN_DC; end if;

                    elsif rx_state = ST_LEARN_DC then
                        if dc_done = '1' then rx_state <= ST_FIND_SYNC; end if;

                    else
                        -- FSK: adaptive threshold on zero-crossing count
                        if thresh_frozen = '0' then
                            if zc_count > zc_max then zc_max <= zc_count; end if;
                            if zc_count < zc_min and zc_count > 0 then zc_min <= zc_count; end if;
                            zc_thresh <= shift_right(zc_max + zc_min, 1)(7 downto 0);
                        end if;

                        -- Bit decision: more crossings = higher freq = bit 1
                        if zc_count > zc_thresh then bit_val <= '1';
                        else bit_val <= '0'; end if;
                        bit_rdy <= '1';
                    end if;

                    -- Reset for next bit
                    zc_count <= (others => '0');
                    zc_valid <= '0';
                    sample_n <= (others => '0');
                end if;

                -- ===== State machine =====
                case rx_state is
                    when ST_FIND_SYNC =>
                        thresh_frozen <= '0';
                        if bit_rdy = '1' then
                            sr <= sr(6 downto 0) & bit_val;
                            if (sr(6 downto 0) & bit_val) = x"AA" or
                               (sr(6 downto 0) & bit_val) = x"55" then
                                sr_run <= sr_run + 1;
                            else
                                sr_run <= (others => '0');
                            end if;
                            if sr_run >= 3 then rx_state <= ST_PREAMBLE; end if;
                        end if;

                    when ST_PREAMBLE =>
                        if bit_rdy = '1' then
                            sr <= sr(6 downto 0) & bit_val;
                            if sr(0) = bit_val then
                                rx_state <= ST_PAYLOAD;
                                thresh_frozen <= '1';
                                pay_idx <= to_unsigned(1, 13);
                                ber_sr_n <= (0 => bit_val, others => '0');
                                ber_sr_i <= (0 => (not bit_val), others => '0');
                                err_n <= (others => '0'); err_i <= (others => '0');
                            end if;
                        end if;

                    when ST_PAYLOAD =>
                        if bit_rdy = '1' then
                            if pay_idx >= 15 then
                                exp_bit := ber_sr_n(14) xor ber_sr_n(13);
                                if bit_val /= exp_bit then err_n <= err_n + 1; end if;
                                exp_bit := ber_sr_i(14) xor ber_sr_i(13);
                                if (not bit_val) /= exp_bit then err_i <= err_i + 1; end if;
                            end if;
                            ber_sr_n <= ber_sr_n(13 downto 0) & bit_val;
                            ber_sr_i <= ber_sr_i(13 downto 0) & (not bit_val);
                            pay_idx <= pay_idx + 1;
                            if pay_idx = PAYLOAD_LEN - 1 then
                                if err_i < err_n then ber_final <= err_i;
                                else ber_final <= err_n; end if;
                                frame_n <= frame_n + 1;
                                rx_state <= ST_PRINT;
                                pr_step <= (others => '0');
                                pr_active <= '1'; pr_done <= '0';
                            end if;
                        end if;

                    when ST_PRINT =>
                            if pr_done = '1' then
                                rx_state <= ST_FIND_SYNC;
                                sr <= (others => '0'); 
                                sr_run <= (others => '0');
                                -- DO NOT reset zc_max and zc_min here
                                -- Let threshold persist across frames
                                thresh_frozen <= '0';
                                pr_active <= '0'; 
                                pr_done <= '0';
                            end if;
                        
                    when others => null;
                end case;

                -- ===== Print =====
                if pr_active = '1' and tx_busy = '0' and pr_done = '0' then
                    tx_byte := x"00";
                    case to_integer(pr_step) is
                        when 0  => tx_byte := x"46";
                        when 1  => tx_byte := x"3D";
                        when 2  => d4 := resize(frame_n / 100, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                        when 3  => d4 := resize((frame_n / 10) mod 10, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                        when 4  => d4 := resize(frame_n mod 10, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                        when 5  => tx_byte := x"20";
                        when 6  => tx_byte := x"45";
                        when 7  => tx_byte := x"3D";
                        when 8  => d4 := resize(ber_final / 1000, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                        when 9  => d4 := resize((ber_final / 100) mod 10, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                        when 10 => d4 := resize((ber_final / 10) mod 10, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                        when 11 => d4 := resize(ber_final mod 10, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                        when 12 => tx_byte := x"2F";
                        when 13 => tx_byte := x"34";
                        when 14 => tx_byte := x"30";
                        when 15 => tx_byte := x"39";
                        when 16 => tx_byte := x"36";
                        when 17 => tx_byte := x"20";
                        when 18 => tx_byte := x"53";
                        when 19 => tx_byte := x"3D";
                        when 20 => d4 := resize(diag_spb / 100, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                        when 21 => d4 := resize((diag_spb / 10) mod 10, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                        when 22 => d4 := resize(diag_spb mod 10, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                        when 23 => tx_byte := x"0D";
                        when 24 => tx_byte := x"0A";
                        when 25 => pr_done <= '1'; tx_byte := x"00";
                        when others => pr_done <= '1'; tx_byte := x"00";
                    end case;
                    if tx_byte /= x"00" then
                        tx_shift <= '1' & tx_byte & '0';
                        tx_busy <= '1'; tx_bcnt <= (others => '0'); tx_ccnt <= (others => '0');
                    end if;
                    pr_step <= pr_step + 1;
                end if;

                -- UART shift
                if tx_busy = '1' then
                    if tx_ccnt = UART_DIV - 1 then
                        tx_ccnt <= (others => '0'); tx_reg <= tx_shift(0);
                        tx_shift <= '1' & tx_shift(9 downto 1);
                        tx_bcnt <= tx_bcnt + 1;
                        if tx_bcnt = 9 then tx_busy <= '0'; end if;
                    else tx_ccnt <= tx_ccnt + 1; end if;
                else tx_reg <= '1'; end if;

                hb <= hb + 1;
            end if;
        end if;
    end process;

    UART_TX <= tx_reg;
    LED(11) <= '1' when rx_state = ST_FIND_SYNC else '0';
    LED(10) <= '1' when rx_state = ST_PREAMBLE else '0';
    LED(9)  <= '1' when rx_state = ST_PAYLOAD else '0';
    LED(8)  <= '1' when rx_state = ST_PRINT else '0';
    LED(7)  <= bit_val;
    LED(6 downto 2) <= std_logic_vector(ber_final(4 downto 0));
    LED(1)  <= dc_done;
    LED(0)  <= std_logic(hb(25));

end Behavioral;