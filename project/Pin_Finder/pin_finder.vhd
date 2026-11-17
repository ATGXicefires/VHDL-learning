----------------------------------------------------------------------------------
-- Module Name: pin_finder - Behavioral
-- Description: 找出 EGO-XZ7 排針 (Pi-CON JA2 / GPIO J11 / XADC J6) 上的腳接到哪支 PL package pin
--   目標板: E-Elements EGO-XZ7 (xc7z020clg484-1, sys_clk = 100 MHz)
--   廠商沒有公開電路圖, 所以把板上還沒用到的 PL 腳全部設成輸入 + 內部上拉 (腳位與編號見 pin_map.txt),
--   用 1 kΩ 電阻把排針上的一支腳碰 GND, 從靜止值變掉的那支 probe 的編號就顯示在 LD7..LD0
--
--   全部只當輸入: 不知道每支腳外面接了什麼 (HDMI 晶片、FMC、振盪器 ...), 設成輸出可能跟別的晶片對打
--
--   SW7 = RST: 撥下 = 校正 (記下每支腳的靜止值), 撥上 = 偵測
--     上電後前 10 ms 會自動校正一次, 所以燒完 SW7 在上面也能直接用
--   LD7..LD0 = 最後碰到的腳的編號 (1..N, 二進位), 0 = 還沒碰到; 放開後保持, 碰下一支腳就更新
--     同時碰到兩支腳時編號會是兩者 OR 起來的錯誤值
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;

entity pin_finder is
    Generic ( N : integer := 178 );                               -- probe 腳數, build.tcl 依實際找到的腳傳入
    Port ( CLK   : in  STD_LOGIC;
           RST   : in  STD_LOGIC;
           probe : in  STD_LOGIC_VECTOR (N - 1 downto 0);
           led   : out STD_LOGIC_VECTOR (7 downto 0));
end pin_finder;

architecture Behavioral of pin_finder is
    -- 2^20 個 CLK 約 10 ms, 讓上電後不用撥 SW7 也有一次校正
    constant WARM_BIT : integer := 20;
    constant ZERO     : STD_LOGIC_VECTOR (N - 1 downto 0) := (others => '0');

    -- 每支腳的編號用 OR 疊起來而不是優先編碼: OR 樹只有幾層 LUT, 178 支腳的優先鏈在 100 MHz 會太長
    -- 代價是兩支腳同時變化時結果錯誤, 一次只碰一支腳就沒問題
    function encode(v : STD_LOGIC_VECTOR) return STD_LOGIC_VECTOR is
        variable r : STD_LOGIC_VECTOR (7 downto 0) := (others => '0');
    begin
        for i in v'range loop
            if v(i) = '1' then
                r := r or conv_std_logic_vector(i + 1, 8);        -- +1 讓 0 保留給「還沒碰到」
            end if;
        end loop;
        return r;
    end function;

    signal p_a, p_b, p_c : STD_LOGIC_VECTOR (N - 1 downto 0) := (others => '0');
    signal base   : STD_LOGIC_VECTOR (N - 1 downto 0) := (others => '0');
    signal noisy  : STD_LOGIC_VECTOR (N - 1 downto 0) := (others => '0');
    signal diff   : STD_LOGIC_VECTOR (N - 1 downto 0) := (others => '0');

    signal rst_a, rst_s : STD_LOGIC := '0';                       -- 初值 0: 上電時當作校正中
    signal warm_cnt : STD_LOGIC_VECTOR (WARM_BIT downto 0) := (others => '0');
    signal settled  : STD_LOGIC;
    signal cal      : STD_LOGIC;

    signal hit : STD_LOGIC_VECTOR (7 downto 0) := (others => '0');
begin
    -- 排針和開關都是非同步輸入, 先過 2 級 FF; p_c 再多 1 拍給 noisy 比較前後值
    sync_a: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                p_a <= probe;
            end if;
        end process;

    sync_b: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                p_b <= p_a;
            end if;
        end process;

    sync_c: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                p_c <= p_b;
            end if;
        end process;

    rst_sync_a: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                rst_a <= RST;
            end if;
        end process;

    rst_sync_b: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                rst_s <= rst_a;
            end if;
        end process;

    warm: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                if warm_cnt(WARM_BIT) = '0' then
                    warm_cnt <= warm_cnt + '1';                   -- 數到最高位元就停, 之後一直維持暖機完成
                end if;
            end if;
        end process;

    -- 同步鏈要 3 拍才填滿, 在那之前 p_b / p_c 還是初值, 拿來比較會把所有上拉的腳誤判成 noisy
    settled <= '0' when warm_cnt(WARM_BIT downto 2) = 0 else '1';
    cal     <= '1' when rst_s = '0' or warm_cnt(WARM_BIT) = '0' else '0';

    base_reg: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                if cal = '1' then
                    base <= p_b;
                end if;
            end if;
        end process;

    -- 校正期間沒人碰排針還會自己跳的腳 (接到振盪器、別的晶片輸出 ...) 永久遮掉, 不然會一直蓋掉 LED 上的結果
    -- 不在每次校正時清除: 跳得慢的腳要累積多次校正才抓得到; 校正時誤碰到的腳要重新燒錄才會解除
    noisy_reg: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                if cal = '1' and settled = '1' then
                    noisy <= noisy or (p_b xor p_c);
                end if;
            end if;
        end process;

    -- 先打一拍再編碼, 讓跨 4 個 bank 拉過來的線和 OR 樹分在兩個 clock 週期
    diff_reg: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                diff <= (p_b xor base) and not noisy;
            end if;
        end process;

    hit_reg: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                if cal = '1' then
                    hit <= (others => '0');
                elsif diff /= ZERO then
                    hit <= encode(diff);
                end if;
            end if;
        end process;

    led <= hit;
end Behavioral;
