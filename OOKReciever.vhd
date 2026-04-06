----------------------------------
-- Step 4f: OOK via Differential Energy
-- Replaces Peak-to-Peak with adjacent-sample differentiation.
-- Automatically immune to DC drift. Uses all 116 samples for noise filtering.
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
    type rx_state_t is (ST_WAIT_SYNC, ST_DIAG, ST_FIND_SYNC, ST_PREAMBLE, ST_PAYLOAD, ST_PRINT);
    signal rx_state : rx_state_t := ST_WAIT_SYNC;

    -- ADC
    signal adc_raw    : unsigned(11 downto 0) := (others => '0');
    signal adc_valid  : std_logic := '0';

    -- Differential Energy DSP
    signal prev_adc   : unsigned(11 downto 0) := (others => '0');
    signal diff_energy: unsigned(19 downto 0) := (others => '0');
    signal sample_n   : unsigned(7 downto 0) := (others => '0');

    -- SYNC_CLK
    signal sd1, sd2, sd3 : std_logic := '0';
    signal deb : unsigned(11 downto 0) := (others => '0');
    signal bit_edge : std_logic := '0';

    -- Wait counter 
    signal wait_cnt : unsigned(9 downto 0) := (others => '0');

    -- Diagnostic phase
    signal diag_cnt    : unsigned(5 downto 0) := (others => '0');
    signal snap_energy : unsigned(19 downto 0) := (others => '0');
    signal snap_spb    : unsigned(7 downto 0) := (others => '0');
    signal snap_ready  : std_logic := '0';

    -- OOK threshold (adaptive, frozen during payload)
    signal e_max         : unsigned(19 downto 0) := (others => '0');
    signal e_min         : unsigned(19 downto 0) := x"FFFFF";
    signal e_thresh      : unsigned(19 downto 0) := to_unsigned(100, 20);
    signal thresh_frozen : std_logic := '0';

    -- Bit decision
    signal bit_val   : std_logic := '0';
    signal bit_rdy   : std_logic := '0';
    signal diag_spb  : unsigned(7 downto 0) := (others => '0');

    -- Sync
    signal sr      : std_logic_vector(7 downto 0) := (others => '0');
    signal sr_run  : unsigned(3 downto 0) := (others => '0');

    -- BER
    signal pay_idx   : unsigned(12 downto 0) := (others => '0');
    signal ber_sr_n  : std_logic_vector(14 downto 0) := (others => '0');
    signal ber_sr_i  : std_logic_vector(14 downto 0) := (others => '0');
    signal err_n     : unsigned(12 downto 0) := (others => '0');
    signal err_i     : unsigned(12 downto 0) := (others => '0');
    signal ber_final : unsigned(12 downto 0) := (others => '0');
    signal frame_n   : unsigned(7 downto 0) := (others => '0');

    -- UART
    signal tx_reg    : std_logic := '1';
    signal tx_shift  : std_logic_vector(9 downto 0) := "1111111111";
    signal tx_busy   : std_logic := '0';
    signal tx_bcnt   : unsigned(3 downto 0) := (others => '0');
    signal tx_ccnt   : unsigned(9 downto 0) := (others => '0');

    -- Print
    signal pr_step   : unsigned(4 downto 0) := (others => '0');
    signal pr_active : std_logic := '0';
    signal pr_done   : std_logic := '0';
    signal pr_is_diag: std_logic := '0'; 

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
    begin
        if rising_edge(CLK) then
            if BTNC = '1' then
                rx_state <= ST_WAIT_SYNC;
                adc_valid <= '0';
                prev_adc <= (others => '0'); diff_energy <= (others => '0'); sample_n <= (others => '0');
                sd1 <= '0'; sd2 <= '0'; sd3 <= '0'; deb <= (others => '0');
                wait_cnt <= (others => '0'); diag_cnt <= (others => '0');
                snap_ready <= '0';
                e_max <= (others => '0'); e_min <= x"FFFFF";
                e_thresh <= to_unsigned(100, 20); thresh_frozen <= '0';
                bit_val <= '0'; bit_rdy <= '0';
                sr <= (others => '0'); sr_run <= (others => '0');
                pay_idx <= (others => '0');
                err_n <= (others => '0'); err_i <= (others => '0');
                ber_final <= (others => '0'); frame_n <= (others => '0');
                tx_reg <= '1'; tx_busy <= '0'; tx_shift <= "1111111111";
                pr_step <= (others => '0'); pr_active <= '0'; pr_done <= '0';
                pr_is_diag <= '0'; hb <= (others => '0');
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

                -- ===== Differential Energy Integrator =====
                if adc_valid = '1' and rx_state /= ST_PRINT then
                    if adc_raw > prev_adc then
                        diff_energy <= diff_energy + (adc_raw - prev_adc);
                    else
                        diff_energy <= diff_energy + (prev_adc - adc_raw);
                    end if;
                    prev_adc <= adc_raw;
                    sample_n <= sample_n + 1;
                end if;

                -- ===== Bit boundary =====
                bit_rdy <= '0';
                if bit_edge = '1' and rx_state /= ST_PRINT then
                    diag_spb <= sample_n;

                    case rx_state is
                        when ST_WAIT_SYNC =>
                            wait_cnt <= wait_cnt + 1;
                            if wait_cnt = 499 then rx_state <= ST_DIAG; end if;

                        when ST_DIAG =>
                            snap_energy <= diff_energy;
                            snap_spb <= sample_n;
                            snap_ready <= '1';
                            diag_cnt <= diag_cnt + 1;
                            if diag_cnt = 49 then rx_state <= ST_FIND_SYNC; end if;

                        when ST_FIND_SYNC | ST_PREAMBLE | ST_PAYLOAD =>
                            if thresh_frozen = '0' then
                                if diff_energy > e_max then e_max <= diff_energy; end if;
                                if diff_energy < e_min then e_min <= diff_energy; end if;
                                e_thresh <= shift_right(e_max + e_min, 1);
                            end if;

                            if diff_energy > e_thresh then bit_val <= '1';
                            else bit_val <= '0'; end if;
                            bit_rdy <= '1';

                        when others => null;
                    end case;
                    
                    diff_energy <= (others => '0');
                    sample_n <= (others => '0');
                end if;

                -- ===== State machine (sync/preamble/payload) =====
                case rx_state is
                    when ST_FIND_SYNC =>
                        thresh_frozen <= '0';
                        if bit_rdy = '1' then
                            sr <= sr(6 downto 0) & bit_val;
                            if (sr(6 downto 0) & bit_val) = x"AA" or (sr(6 downto 0) & bit_val) = x"55" then
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
                                pr_active <= '1'; pr_done <= '0'; pr_is_diag <= '0';
                            end if;
                        end if;

                    when others => null;
                end case;

                -- ===== Diagnostic print trigger =====
                if snap_ready = '1' and pr_active = '0' then
                    pr_active <= '1'; pr_step <= (others => '0');
                    snap_ready <= '0'; pr_is_diag <= '1'; pr_done <= '0';
                end if;

                -- ===== Print done → return to appropriate state =====
                if pr_done = '1' and pr_active = '1' then
                    pr_active <= '0'; pr_done <= '0';
                    if pr_is_diag = '0' then
                        rx_state <= ST_FIND_SYNC;
                        sr <= (others => '0'); sr_run <= (others => '0');
                        e_max <= (others => '0'); e_min <= x"FFFFF";
                        thresh_frozen <= '0';
                    end if;
                end if;

                -- ===== Print engine =====
                if pr_active = '1' and tx_busy = '0' and pr_done = '0' then
                    tx_byte := x"00";
                    if pr_is_diag = '1' then
                        -- Diagnostic: "PNNNN SNNN\r\n"
                        case to_integer(pr_step) is
                            when 0  => tx_byte := x"50";  -- P
                            when 1  => d4 := resize(snap_energy / 1000, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                            when 2  => d4 := resize((snap_energy / 100) mod 10, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                            when 3  => d4 := resize((snap_energy / 10) mod 10, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                            when 4  => d4 := resize(snap_energy mod 10, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                            when 5  => tx_byte := x"20";
                            when 6  => tx_byte := x"53";
                            when 7  => d4 := resize(snap_spb / 100, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                            when 8  => d4 := resize((snap_spb / 10) mod 10, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                            when 9  => d4 := resize(snap_spb mod 10, 4); tx_byte := std_logic_vector(x"30" + resize(d4, 8));
                            when 10 => tx_byte := x"0D";
                            when 11 => tx_byte := x"0A";
                            when 12 => pr_done <= '1'; tx_byte := x"00";
                            when others => pr_done <= '1'; tx_byte := x"00";
                        end case;
                    else
                        -- BER: "F=NNN E=NNNN/4096 S=NNN\r\n"
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
                    end if;
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
    LED(1)  <= '1' when rx_state /= ST_WAIT_SYNC else '0';
    LED(0)  <= std_logic(hb(25));

end Behavioral;