----------------------------------------------------------------------------------
-- Module Name: adv7511_cfg - Behavioral
-- Description: HDMI 版 - 用 I2C 設定板上的 ADV7511, 之後定期讀它的 HPD (有沒有插螢幕)
--   流程: 重置 -> 等 T_POWER (ADV7511 上電) -> bus clear (9 個 SCL + STOP) -> 讀 0x42 -> 依序寫 INIT_TABLE
--         -> 每隔 T_POLL 讀一次 0x42; HPD 從 0 變 1 (螢幕剛插上) 時整張表重寫
--   任何一個 byte 沒收到 ACK: cfg_ok = '0', 等 T_RETRY 後從 bus clear 重來
--   vid_en: 第一次設定成功後就一直是 '1' (到下次重置); 在那之前 hdmi_top 讓影像腳保持高阻抗,
--     HDMI 腳位一開始是照 ZedBoard 推定的 (後來上板確認無誤); 腳位不對時 ADV7511 不會回 ACK,
--     也就不會去推不明的腳
--   跑在像素時脈上 (25 ~ 108.33 MHz), 不用跨時脈域; QUARTER 依 108.33 MHz 算, SCL 最快 100 kHz,
--     640x480 時約 23 kHz (I2C 沒有最低速度), 等待時間也跟著變長 4.3 倍
--   T_POWER / T_POLL / T_RETRY 的單位是 1/4 個 SCL 週期 (108.33 MHz 時 2.5 us), 預設 20 ms / 100 ms / 1 s
--   SCL、SDA 都只會拉低或放開 (open drain, 外部上拉); 不支援 clock stretching
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;
use work.adv7511_pkg.all;

entity adv7511_cfg is
    Generic ( QUARTER : integer := 271;
              T_POWER : integer := 8000;
              T_POLL  : integer := 40000;
              T_RETRY : integer := 400000 );
    Port ( CLK    : in    STD_LOGIC;
           RST    : in    STD_LOGIC;
           scl    : out   STD_LOGIC;
           sda    : inout STD_LOGIC;
           cfg_ok : out   STD_LOGIC;
           hpd    : out   STD_LOGIC;
           vid_en : out   STD_LOGIC);
end adv7511_cfg;

architecture Behavioral of adv7511_cfg is
    -- 每個狀態都由 bit 時段組成: 1 個時段 = 4 個 1/4 SCL 週期 (qph 0..3)
    subtype state_type is STD_LOGIC_VECTOR (3 downto 0);
    constant ST_POWER : state_type := "0000";
    constant ST_CLEAR : state_type := "0001";   -- 9 個時段: 讓卡在半個 byte 的 slave 把 SDA 放開
    constant ST_START : state_type := "0010";   -- 也當 repeated START 用
    constant ST_TX    : state_type := "0011";   -- 8 個時段
    constant ST_ACK   : state_type := "0100";   -- 放開 SDA, 讀 slave 的 ACK
    constant ST_RX    : state_type := "0101";   -- 8 個時段
    constant ST_NAK   : state_type := "0110";   -- 讀完 1 byte, 回 NACK 結束讀取
    constant ST_STOP  : state_type := "0111";
    constant ST_POLL  : state_type := "1000";   -- 等下一次讀 HPD
    constant ST_RETRY : state_type := "1001";   -- 沒收到 ACK, 等一下再重來

    subtype job_type is STD_LOGIC_VECTOR (1 downto 0);
    constant JOB_CLEAR : job_type := "00";
    constant JOB_READ  : job_type := "01";      -- 讀 REG_STATUS (HPD)
    constant JOB_WRITE : job_type := "10";      -- 寫 INIT_TABLE(tidx)

    constant LAST  : integer := INIT_TABLE'high;
    constant T_SUM : integer := T_POWER + T_POLL + T_RETRY;

    signal qcnt     : integer range 0 to QUARTER - 1;
    signal qtick    : STD_LOGIC;
    signal qph      : STD_LOGIC_VECTOR (1 downto 0);
    signal step     : STD_LOGIC;                                   -- bit 時段結束
    signal smp      : STD_LOGIC;                                   -- SCL 高電位的後半, 取樣 SDA
    signal waiting  : STD_LOGIC;
    signal wcnt     : integer range 0 to T_SUM;
    signal wlim     : integer range 0 to T_SUM;
    signal wdone    : STD_LOGIC;
    signal state    : state_type;
    signal nxt      : state_type;
    signal job      : job_type;
    signal bitcnt   : STD_LOGIC_VECTOR (3 downto 0);
    signal bidx     : STD_LOGIC_VECTOR (1 downto 0);               -- 這次交易已經載入幾個 byte
    signal tidx     : integer range 0 to LAST;
    signal load     : STD_LOGIC;
    signal tx_byte  : STD_LOGIC_VECTOR (7 downto 0);
    signal tx_sh    : STD_LOGIC_VECTOR (7 downto 0);
    signal rx_sh    : STD_LOGIC_VECTOR (7 downto 0);
    signal sda_in   : STD_LOGIC;
    signal sda_s1   : STD_LOGIC;
    signal sda_s2   : STD_LOGIC;
    signal nak      : STD_LOGIC;
    signal ok_r     : STD_LOGIC;
    signal hpd_r    : STD_LOGIC;
    signal hpd_rise : STD_LOGIC;
    signal en_r     : STD_LOGIC;
    signal scl_n    : STD_LOGIC;
    signal sda_n    : STD_LOGIC;
    signal scl_r    : STD_LOGIC;
    signal sda_r    : STD_LOGIC;
begin
    q_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                qcnt <= 0;
            elsif CLK'event and CLK = '1' then
                if qcnt = QUARTER - 1 then
                    qcnt <= 0;
                else
                    qcnt <= qcnt + 1;
                end if;
            end if;
        end process;

    qtick <= '1' when qcnt = QUARTER - 1 else '0';

    waiting <= '1' when state = ST_POWER or state = ST_POLL or state = ST_RETRY else '0';

    -- 等待中固定在 0, 離開等待時下一個時段才會從 qph = 0 開始
    ph_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                qph <= "00";
            elsif CLK'event and CLK = '1' then
                if waiting = '1' then
                    qph <= "00";
                elsif qtick = '1' then
                    qph <= qph + '1';
                end if;
            end if;
        end process;

    step <= '1' when qtick = '1' and qph = "11" else '0';
    smp  <= '1' when qtick = '1' and qph = "10" else '0';

    w_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                wcnt <= 0;
            elsif CLK'event and CLK = '1' then
                if waiting = '0' then
                    wcnt <= 0;
                elsif qtick = '1' then
                    wcnt <= wcnt + 1;
                end if;
            end if;
        end process;

    wlim  <= T_POWER - 1 when state = ST_POWER else
             T_POLL - 1  when state = ST_POLL else
             T_RETRY - 1;
    wdone <= '1' when qtick = '1' and wcnt = wlim else '0';

    hpd_rise <= '1' when rx_sh(HPD_BIT) = '1' and hpd_r = '0' else '0';

    -- 寫入: START, 0x72, 暫存器, 數值, STOP
    -- 讀取: START, 0x72, 0x42, repeated START, 0x73, 收 1 byte, NACK, STOP
    nxt <= ST_CLEAR when waiting = '1' and state /= ST_POLL and wdone = '1' else
           ST_START when state = ST_POLL and wdone = '1' else
           ST_STOP  when state = ST_CLEAR and step = '1' and bitcnt = 8 else
           ST_TX    when state = ST_START and step = '1' else
           ST_ACK   when state = ST_TX and step = '1' and bitcnt = 7 else
           ST_STOP  when state = ST_ACK and step = '1' and nak = '1' else
           ST_STOP  when state = ST_ACK and step = '1' and job = JOB_WRITE and bidx = 3 else
           ST_START when state = ST_ACK and step = '1' and job = JOB_READ and bidx = 2 else
           ST_RX    when state = ST_ACK and step = '1' and job = JOB_READ and bidx = 3 else
           ST_TX    when state = ST_ACK and step = '1' else
           ST_NAK   when state = ST_RX and step = '1' and bitcnt = 7 else
           ST_STOP  when state = ST_NAK and step = '1' else
           ST_RETRY when state = ST_STOP and step = '1' and nak = '1' else
           ST_POLL  when state = ST_STOP and step = '1' and job = JOB_WRITE and tidx = LAST else
           ST_POLL  when state = ST_STOP and step = '1' and job = JOB_READ and ok_r = '1' and hpd_rise = '0' else
           ST_START when state = ST_STOP and step = '1' else
           state;

    fsm: process(CLK, RST)
        begin
            if RST = '0' then
                state <= ST_POWER;
            elsif CLK'event and CLK = '1' then
                state <= nxt;
            end if;
        end process;

    -- 讀 HPD 一律排在寫表之前: 寫表時的 HPD 已經記在 hpd_r, 之後只有真的插上螢幕才會重寫
    job_reg: process(CLK, RST)
        begin
            if RST = '0' then
                job <= JOB_CLEAR;
            elsif CLK'event and CLK = '1' then
                if state = ST_POWER or state = ST_RETRY then
                    job <= JOB_CLEAR;
                elsif state = ST_POLL then
                    job <= JOB_READ;
                elsif state = ST_STOP and step = '1' and nak = '0' then
                    if job = JOB_CLEAR then
                        job <= JOB_READ;
                    elsif job = JOB_READ and (ok_r = '0' or hpd_rise = '1') then
                        job <= JOB_WRITE;
                    end if;
                end if;
            end if;
        end process;

    t_idx: process(CLK, RST)
        begin
            if RST = '0' then
                tidx <= 0;
            elsif CLK'event and CLK = '1' then
                if job /= JOB_WRITE then
                    tidx <= 0;
                elsif state = ST_STOP and step = '1' and tidx /= LAST then
                    tidx <= tidx + 1;
                end if;
            end if;
        end process;

    bit_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                bitcnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if state /= ST_TX and state /= ST_RX and state /= ST_CLEAR then
                    bitcnt <= (others => '0');
                elsif step = '1' then
                    bitcnt <= bitcnt + '1';
                end if;
            end if;
        end process;

    load <= '1' when nxt = ST_TX and state /= ST_TX else '0';

    tx_byte <= ADV_ADDR_W           when bidx = 0 else
               REG_STATUS           when job = JOB_READ and bidx = 1 else
               ADV_ADDR_R           when job = JOB_READ else
               INIT_TABLE(tidx).reg when bidx = 1 else
               INIT_TABLE(tidx).val;

    b_idx: process(CLK, RST)
        begin
            if RST = '0' then
                bidx <= "00";
            elsif CLK'event and CLK = '1' then
                if state = ST_STOP then
                    bidx <= "00";
                elsif load = '1' then
                    bidx <= bidx + '1';
                end if;
            end if;
        end process;

    -- 在時段結束 (SCL 低) 時才移位, SDA 不會在 SCL 高的時候變
    tx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tx_sh <= (others => '1');
            elsif CLK'event and CLK = '1' then
                if load = '1' then
                    tx_sh <= tx_byte;
                elsif state = ST_TX and step = '1' then
                    tx_sh <= tx_sh(6 downto 0) & '1';
                end if;
            end if;
        end process;

    -- 外部上拉在模擬裡是 'H', 先整理成 '0' / '1'
    sda_in <= '0' when sda = '0' else '1';

    sda_sync1: process(CLK, RST)
        begin
            if RST = '0' then
                sda_s1 <= '1';
            elsif CLK'event and CLK = '1' then
                sda_s1 <= sda_in;
            end if;
        end process;

    sda_sync2: process(CLK, RST)
        begin
            if RST = '0' then
                sda_s2 <= '1';
            elsif CLK'event and CLK = '1' then
                sda_s2 <= sda_s1;
            end if;
        end process;

    rx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rx_sh <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if state = ST_RX and smp = '1' then
                    rx_sh <= rx_sh(6 downto 0) & sda_s2;
                end if;
            end if;
        end process;

    nak_flag: process(CLK, RST)
        begin
            if RST = '0' then
                nak <= '0';
            elsif CLK'event and CLK = '1' then
                if waiting = '1' then
                    nak <= '0';
                elsif state = ST_ACK and smp = '1' and sda_s2 = '1' then
                    nak <= '1';
                end if;
            end if;
        end process;

    ok_flag: process(CLK, RST)
        begin
            if RST = '0' then
                ok_r <= '0';
            elsif CLK'event and CLK = '1' then
                if state = ST_RETRY then
                    ok_r <= '0';
                elsif state = ST_STOP and step = '1' and nak = '0' and job = JOB_WRITE and tidx = LAST then
                    ok_r <= '1';
                end if;
            end if;
        end process;

    hpd_flag: process(CLK, RST)
        begin
            if RST = '0' then
                hpd_r <= '0';
            elsif CLK'event and CLK = '1' then
                if state = ST_RETRY then
                    hpd_r <= '0';
                elsif state = ST_STOP and step = '1' and nak = '0' and job = JOB_READ then
                    hpd_r <= rx_sh(HPD_BIT);
                end if;
            end if;
        end process;

    -- 只要 ADV7511 回應過一次, 就確定腳位是對的; 之後晶片暫時沒回應也不用再關掉影像
    en_flag: process(CLK, RST)
        begin
            if RST = '0' then
                en_r <= '0';
            elsif CLK'event and CLK = '1' then
                if ok_r = '1' then
                    en_r <= '1';
                end if;
            end if;
        end process;

    -- 一個 bit 時段: qph 0 = SCL 低 (換 SDA), 1、2 = SCL 高, 3 = SCL 低
    -- START 時 SDA 在 SCL 高的時候拉低 (1 1 0 0), STOP 時 SCL 高的時候放開 (0 0 1 1)
    scl_n <= '1' when waiting = '1' else
             '1' when qph = "01" or qph = "10" else
             '1' when state = ST_STOP and qph = "11" else
             '0';
    sda_n <= not qph(1) when state = ST_START else
             qph(1)     when state = ST_STOP else
             tx_sh(7)   when state = ST_TX else
             '1';

    -- 輸出先經暫存器, 組合邏輯的突波才不會被 slave 當成 SCL 邊緣
    scl_reg: process(CLK, RST)
        begin
            if RST = '0' then
                scl_r <= '1';
            elsif CLK'event and CLK = '1' then
                scl_r <= scl_n;
            end if;
        end process;

    sda_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sda_r <= '1';
            elsif CLK'event and CLK = '1' then
                sda_r <= sda_n;
            end if;
        end process;

    scl <= '0' when scl_r = '0' else 'Z';
    sda <= '0' when sda_r = '0' else 'Z';

    cfg_ok <= ok_r;
    hpd    <= hpd_r;
    vid_en <= en_r;
end Behavioral;
