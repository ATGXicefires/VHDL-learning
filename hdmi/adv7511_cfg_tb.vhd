----------------------------------------------------------------------------------
-- Module Name: adv7511_cfg_tb - Behavioral
-- Description: adv7511_cfg 的自我檢查 testbench, 用行為模型代替 ADV7511 的 I2C slave (位址 0x72)
--   NACK = 0: 寫入的順序與數值要和 INIT_TABLE 一模一樣、CSC 係數要等於 CSC_COEF、cfg_ok / vid_en 會變 '1';
--             HPD 低的時候只輪詢不重寫, 螢幕插上 (HPD 0 -> 1) 時整張表重寫一次;
--             晶片暫時沒回應時 cfg_ok 掉下來但 vid_en 不變, 晶片回來後重新設定
--   NACK = 1: 晶片完全沒回應, cfg_ok / vid_en 一直是 '0', 而且會定期重試
--   QUARTER 與等待時間改小, 模擬才不會跑太久 (I2C 的行為不受影響)
--   有錯會以 severity error 報出, 全部通過最後印出 "adv7511_cfg_tb PASS"
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use work.adv7511_pkg.all;

entity adv7511_cfg_tb is
    Generic ( NACK : integer := 0 );
end adv7511_cfg_tb;

architecture Behavioral of adv7511_cfg_tb is
    constant QUARTER    : integer := 4;
    constant T_POWER    : integer := 20;
    constant T_POLL     : integer := 100;
    constant T_RETRY    : integer := 300;
    constant CLK_PERIOD : time := 10 ns;
    constant N_INIT     : integer := INIT_TABLE'length;

    signal CLK    : STD_LOGIC := '0';
    signal RST    : STD_LOGIC := '0';
    signal scl    : STD_LOGIC;
    signal sda    : STD_LOGIC;
    signal scl_b  : STD_LOGIC;
    signal sda_b  : STD_LOGIC;
    signal cfg_ok : STD_LOGIC;
    signal hpd    : STD_LOGIC;
    signal vid_en : STD_LOGIC;

    -- ADV7511 模型
    type reg_file_type is array (0 to 255) of STD_LOGIC_VECTOR (7 downto 0);
    type log_type is array (0 to 255) of STD_LOGIC_VECTOR (15 downto 0);
    signal sda_drv : STD_LOGIC := 'Z';
    signal hpd_pin : STD_LOGIC := '0';
    signal absent  : boolean := NACK = 1;
    signal regs    : reg_file_type := (others => (others => '0'));
    signal wr_log  : log_type;                                     -- 暫存器 & 數值, 依寫入順序
    signal wr_cnt  : integer := 0;
    signal polls   : integer := 0;                                 -- 讀 REG_STATUS 的次數
    signal starts  : integer := 0;

    signal ok_seen  : boolean := false;
    signal en_early : boolean := false;
    signal done     : boolean := false;
begin
    uut: entity work.adv7511_cfg
        generic map ( QUARTER => QUARTER,
                      T_POWER => T_POWER,
                      T_POLL  => T_POLL,
                      T_RETRY => T_RETRY )
        port map ( CLK    => CLK,
                   RST    => RST,
                   scl    => scl,
                   sda    => sda,
                   cfg_ok => cfg_ok,
                   hpd    => hpd,
                   vid_en => vid_en );

    -- 板上的上拉電阻
    scl <= 'H';
    sda <= 'H';
    sda <= sda_drv;
    scl_b <= To_X01(scl);
    sda_b <= To_X01(sda);

    clk_process: process
        begin
            while not done loop
                CLK <= '0';
                wait for CLK_PERIOD / 2;
                CLK <= '1';
                wait for CLK_PERIOD / 2;
            end loop;
            wait;
        end process;

    -- I2C slave: SCL 上升緣取樣、下降緣才改 SDA; SCL 高的時候 SDA 變化 = START / STOP
    -- 讀取時位址自動遞增; REG_STATUS 的 bit 6 = hpd_pin
    adv_model: process(scl_b, sda_b)
        constant M_IDLE  : integer := 0;
        constant M_ADDR  : integer := 1;
        constant M_REG   : integer := 2;
        constant M_WDATA : integer := 3;
        constant M_ACK   : integer := 4;                           -- 送 ACK 中 (第 9 個 SCL)
        constant M_RDATA : integer := 5;
        constant M_RACK  : integer := 6;                           -- 等 master 的 ACK / NACK
        variable st      : integer := M_IDLE;
        variable next_st : integer := M_IDLE;
        variable bits    : integer := 0;
        variable sh      : STD_LOGIC_VECTOR (7 downto 0);
        variable ptr     : integer := 0;
        variable rbyte   : STD_LOGIC_VECTOR (7 downto 0);
        variable m_nack  : boolean := false;

        procedure drive(v : STD_LOGIC) is
            begin
                if v = '0' then
                    sda_drv <= '0';
                else
                    sda_drv <= 'Z';
                end if;
            end procedure;

        procedure fetch is
            begin
                if ptr = 16#42# then
                    rbyte := (HPD_BIT => hpd_pin, others => '0');
                    polls <= polls + 1;
                else
                    rbyte := regs(ptr);
                end if;
            end procedure;
        begin
            if scl_b = '1' and sda_b'event then
                sda_drv <= 'Z';
                if sda_b = '0' then
                    st     := M_ADDR;
                    bits   := 0;
                    starts <= starts + 1;
                else
                    st := M_IDLE;
                end if;
            elsif scl_b'event and scl_b = '1' then
                if st = M_ADDR or st = M_REG or st = M_WDATA then
                    sh   := sh(6 downto 0) & sda_b;
                    bits := bits + 1;
                elsif st = M_RACK then
                    m_nack := sda_b = '1';
                end if;
            elsif scl_b'event and scl_b = '0' then
                if (st = M_ADDR or st = M_REG or st = M_WDATA) and bits = 8 then
                    bits := 0;
                    if st = M_ADDR then
                        if sh(7 downto 1) = ADV_ADDR_W(7 downto 1) and not absent then
                            sda_drv <= '0';
                            if sh(0) = '1' then
                                next_st := M_RDATA;
                            else
                                next_st := M_REG;
                            end if;
                            st := M_ACK;
                        else
                            st := M_IDLE;
                        end if;
                    elsif st = M_REG then
                        ptr     := conv_integer(unsigned(sh));
                        sda_drv <= '0';
                        next_st := M_WDATA;
                        st      := M_ACK;
                    else
                        regs(ptr)      <= sh;
                        wr_log(wr_cnt) <= conv_std_logic_vector(ptr, 8) & sh;
                        wr_cnt         <= wr_cnt + 1;
                        ptr            := ptr + 1;
                        sda_drv        <= '0';
                        next_st        := M_WDATA;
                        st             := M_ACK;
                    end if;
                elsif st = M_ACK then
                    sda_drv <= 'Z';
                    st      := next_st;
                    if st = M_RDATA then
                        fetch;
                        drive(rbyte(7));
                        bits := 1;
                    end if;
                elsif st = M_RDATA then
                    if bits = 8 then
                        sda_drv <= 'Z';
                        st      := M_RACK;
                    else
                        drive(rbyte(7 - bits));
                        bits := bits + 1;
                    end if;
                elsif st = M_RACK then
                    if m_nack then
                        st := M_IDLE;
                    else
                        ptr := ptr + 1;
                        fetch;
                        drive(rbyte(7));
                        bits := 1;
                        st   := M_RDATA;
                    end if;
                end if;
            end if;
        end process;

    -- 影像腳要等設定成功才開: vid_en 不可以比 cfg_ok 先出現
    watch: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                if cfg_ok = '1' then
                    ok_seen <= true;
                end if;
                if vid_en = '1' and not ok_seen then
                    en_early <= true;
                end if;
            end if;
        end process;

    stim_process: process
        variable errors : integer := 0;
        variable p0     : integer;
        variable t0     : time;
        variable coef   : integer;
        variable c13    : STD_LOGIC_VECTOR (12 downto 0);
        variable expect : STD_LOGIC_VECTOR (15 downto 0);

        procedure check(name : string; ok : boolean) is
            begin
                if not ok then
                    report name severity error;
                    errors := errors + 1;
                end if;
            end procedure;

        -- 從第 first 筆起的 N_INIT 筆寫入要和 INIT_TABLE 一模一樣
        procedure check_table(first : integer) is
            begin
                for i in 0 to N_INIT - 1 loop
                    expect := INIT_TABLE(i).reg & INIT_TABLE(i).val;
                    check("write " & integer'image(first + i) & " differs from INIT_TABLE("
                              & integer'image(i) & ")",
                          wr_log(first + i) = expect);
                end loop;
            end procedure;

        procedure wait_polls(n : integer) is
            begin
                p0 := polls;
                wait until polls >= p0 + n for 200 us;
                check("HPD polling stopped", polls >= p0 + n);
            end procedure;
        begin
            wait for CLK_PERIOD * 5;
            RST <= '1';

            if NACK = 0 then
                wait until cfg_ok = '1' for 1 ms;
                check("cfg_ok never rose", cfg_ok = '1');
                check("HPD should be read once before the table", polls = 1);
                check("write count after config = " & integer'image(wr_cnt), wr_cnt = N_INIT);
                check_table(0);
                for i in 0 to 11 loop
                    c13  := regs(16#18# + 2 * i)(4 downto 0) & regs(16#19# + 2 * i);
                    coef := conv_integer(unsigned(c13));
                    if coef >= 4096 then
                        coef := coef - 8192;
                    end if;
                    check("CSC coefficient " & integer'image(i) & " = " & integer'image(coef), coef = CSC_COEF(i));
                end loop;
                check("CSC should be enabled with x4 scaling", regs(16#18#)(7 downto 5) = "110");
                check("CSC update mode left on", regs(16#1A#)(5) = '0');
                check("bus not released after config", scl_b = '1' and sda_b = '1');
                wait for CLK_PERIOD * 2;
                check("vid_en did not follow cfg_ok", vid_en = '1');
                check("hpd should be 0", hpd = '0');

                wait_polls(2);
                check("table rewritten while HPD stayed low", wr_cnt = N_INIT);

                -- 插上螢幕: 下一次輪詢看到 HPD 0 -> 1, 整張表重寫
                hpd_pin <= '1';
                wait until wr_cnt = 2 * N_INIT for 1 ms;
                check("no rewrite after HPD rose", wr_cnt = 2 * N_INIT);
                check_table(N_INIT);
                check("hpd should be 1", hpd = '1');
                wait_polls(2);
                check("table rewritten again while HPD stayed high", wr_cnt = 2 * N_INIT);

                -- 晶片暫時沒回應
                absent <= true;
                wait until cfg_ok = '0' for 200 us;
                check("cfg_ok did not drop on NACK", cfg_ok = '0');
                check("hpd should clear on NACK", hpd = '0');
                absent <= false;
                wait until cfg_ok = '1' for 1 ms;
                check("no reconfig after the chip came back", cfg_ok = '1');
                check("write count after reconfig = " & integer'image(wr_cnt), wr_cnt = 3 * N_INIT);
                check_table(2 * N_INIT);
                check("vid_en should stay on", vid_en = '1');
            else
                -- 位址就收不到 ACK: 每次嘗試只有 1 個 START, 下一次至少要等 T_RETRY
                wait until starts = 1 for 100 us;
                check("no START at all", starts = 1);
                t0 := now;
                for n in 2 to 4 loop
                    wait until starts = n for 100 us;
                    check("retry " & integer'image(n) & " missing or too early",
                          starts = n and now - t0 >= T_RETRY * QUARTER * CLK_PERIOD);
                    t0 := now;
                end loop;
                check("cfg_ok / vid_en rose without ACK", not ok_seen and vid_en = '0');
                check("writes without ACK", wr_cnt = 0);
            end if;
            check("vid_en rose before cfg_ok", not en_early);

            if errors = 0 then
                report "adv7511_cfg_tb PASS" severity note;
            else
                report "adv7511_cfg_tb FAIL: " & integer'image(errors) & " error(s)" severity error;
            end if;
            done <= true;
            wait;
        end process;
end Behavioral;
