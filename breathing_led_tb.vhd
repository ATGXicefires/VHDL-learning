----------------------------------------------------------------------------------
-- Module Name: breathing_led_tb - Behavioral
-- Description: HW2 呼吸燈 breathing_led 的 testbench
--   產生 10ns 週期的 CLK, CLK_FREQ 設為 5120 讓模擬加速:
--     STEP_BASE = 5120 / 512 = 10 -> freq_sel = "00" 時每 10 個 CLK 更新一次亮度
--     一次呼吸 = 512 * 10 CLK = 51.2 us (模擬時間)
--   依序測試: 預設 (1x, 256 階) -> 16 階 -> 2 階 -> 4 倍週期 (256 階)
--   觀察 uut/duty_q 呈三角波, led 的 PWM 脈寬隨 duty_q 改變
--   (duty_q 是內部訊號: Scope 視窗選 uut, 把 duty_q 拖進波形)
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

entity breathing_led_tb is
-- testbench 沒有 port
end breathing_led_tb;

architecture Behavioral of breathing_led_tb is
    -- 受測元件宣告
    component breathing_led
        Generic ( CLK_FREQ : integer := 100_000_000 );
        Port ( CLK      : in  STD_LOGIC;
               RST      : in  STD_LOGIC;
               freq_sel : in  STD_LOGIC_VECTOR (1 downto 0);
               res_sel  : in  STD_LOGIC_VECTOR (2 downto 0);
               led      : out STD_LOGIC);
    end component;

    -- 輸入訊號
    signal CLK      : STD_LOGIC := '0';
    signal RST      : STD_LOGIC := '0';
    signal freq_sel : STD_LOGIC_VECTOR (1 downto 0) := "00";
    signal res_sel  : STD_LOGIC_VECTOR (2 downto 0) := "000";

    -- 輸出訊號
    signal led      : STD_LOGIC;

    constant CLK_PERIOD : time := 10 ns;
    constant BREATH     : time := CLK_PERIOD * 5120;           -- freq_sel = "00" 時一次呼吸
begin
    -- 接上受測元件 (模擬用小時脈值)
    uut: breathing_led
        generic map ( CLK_FREQ => 5120 )
        port map ( CLK      => CLK,
                   RST      => RST,
                   freq_sel => freq_sel,
                   res_sel  => res_sel,
                   led      => led );

    -- 時脈產生
    clk_process: process
        begin
            CLK <= '0';
            wait for CLK_PERIOD / 2;
            CLK <= '1';
            wait for CLK_PERIOD / 2;
        end process;

    -- 刺激訊號
    stim_process: process
        begin
            RST <= '0';                      -- 先重置
            wait for CLK_PERIOD * 2;
            RST <= '1';                      -- 解除重置, 開始呼吸

            -- 1. 預設: 1 s 週期, 256 階, 跑 2 次呼吸
            wait for BREATH * 2;

            -- 2. 解析度改 16 階: duty_q 變成階梯狀, 週期不變
            res_sel <= "100";
            wait for BREATH;

            -- 3. 解析度改 2 階: 只剩 0% / 50% 兩種亮度
            res_sel <= "111";
            wait for BREATH;

            -- 4. 解析度回 256 階, 週期改 4 s: 三角波變為 4 倍寬
            res_sel  <= "000";
            freq_sel <= "11";
            wait for BREATH * 4;

            wait;                            -- 模擬結束, 停在這裡
        end process;
end Behavioral;
