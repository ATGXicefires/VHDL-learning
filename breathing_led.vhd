----------------------------------------------------------------------------------
-- Module Name: breathing_led - Behavioral
-- Description: HW2 呼吸燈 (PWM) - 可調呼吸頻率 / 可調明暗解析度
--   目標板: ZedBoard Zynq (GCLK = 100 MHz), 目前先在 Vivado 上模擬
--
--   架構: step_div 產生亮度更新節拍 step_tick, FSM 決定變亮/變暗,
--         duty 計數器依 state 上/下數, 經解析度遮罩後與 pwm_cnt 比較輸出 LED
--
--      freq_sel                     res_sel
--         |                            |
--         v                            v
--   +----------+  step_tick  +-----+  +------+  duty_q  +------------+
--   | step_div |------------>| FSM |  | mask |--------->| PWM 比較器 |---> led
--   +----------+      |      +--+--+  +------+          +------------+
--                     |   state |  ^      ^                   ^
--                     |         v  |duty  |                   | pwm_cnt
--                     |      +-----+----+ |             +-----+-----+
--                     +----->|   duty   |-+             |  pwm_cnt  |
--                            +----------+               +-----------+
--
--   UP   : 每個 step_tick duty + 1, 到 255 後換 DOWN (變亮)
--   DOWN : 每個 step_tick duty - 1, 到 0   後換 UP   (變暗)
--   一次呼吸 (暗 -> 亮 -> 暗) = 512 個 step_tick
--
--   freq_sel (呼吸週期): "00" = 1 s, "01" = 2 s, "10" = 3 s, "11" = 4 s
--   res_sel  (明暗解析度, 亮度刻度數):
--     "000" = 256 階, "001" = 128 階, "010" = 64 階, "011" = 32 階,
--     "100" = 16 階,  "101" = 8 階,   "110" = 4 階,  "111" = 2 階
--     做法: duty 仍以 8 bit 平滑計數, 輸出前把低位元遮掉 (量化),
--           所以改解析度不會影響呼吸週期
--
--   PWM: pwm_cnt 每個 CLK 加 1 (0 -> 255 循環), led = (pwm_cnt < duty_q)
--        PWM 頻率 = CLK_FREQ / 256 (100 MHz 時約 390.6 kHz, 遠高於人眼 30 Hz 極限)
--        亮度 P(t) = duty_q / 256, 0 <= P(t) < 1
--
--   CLK_FREQ 為 generic: 板上用 100_000_000, 模擬時可設小值加速
--
--   RST = '0' 時重置: state = UP, duty = 0, 計數器歸 0, led = '0'
--
--   規定: 1 個 process 只更動 1 個訊號
--     step_div -> 只改 step_cnt
--     fsm      -> 只改 state
--     duty_ctr -> 只改 duty
--     pwm_ctr  -> 只改 pwm_cnt
--     pwm_out  -> 只改 led_r
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;

entity breathing_led is
    Generic ( CLK_FREQ : integer := 100_000_000 );                 -- 系統時脈 (Hz)
    Port ( CLK      : in  STD_LOGIC;
           RST      : in  STD_LOGIC;
           freq_sel : in  STD_LOGIC_VECTOR (1 downto 0);          -- 呼吸頻率選擇
           res_sel  : in  STD_LOGIC_VECTOR (2 downto 0);          -- 明暗解析度選擇
           led      : out STD_LOGIC;                              -- PWM 輸出
           duty_o   : out STD_LOGIC_VECTOR (7 downto 0));         -- 目前亮度 (觀察用)
end breathing_led;

architecture Behavioral of breathing_led is
    type state_type is (UP, DOWN);                                 -- UP: 變亮, DOWN: 變暗
    signal state : state_type;

    -- 1 s 呼吸週期時, 每個 step_tick 間隔的 CLK 數 (一次呼吸 512 個 step)
    constant STEP_BASE : integer := CLK_FREQ / 512;

    signal step_max  : STD_LOGIC_VECTOR (23 downto 0);            -- step_cnt 上限 (依 freq_sel)
    signal step_cnt  : STD_LOGIC_VECTOR (23 downto 0);
    signal step_tick : STD_LOGIC;                                  -- 亮度更新節拍 (ΔT)

    signal duty      : STD_LOGIC_VECTOR (7 downto 0);             -- 8 bit 平滑亮度
    signal res_mask  : STD_LOGIC_VECTOR (7 downto 0);             -- 解析度遮罩
    signal duty_q    : STD_LOGIC_VECTOR (7 downto 0);             -- 量化後亮度

    signal pwm_cnt   : STD_LOGIC_VECTOR (7 downto 0);
    signal led_r     : STD_LOGIC;
begin
    -- 呼吸頻率: 呼吸週期 = (freq_sel + 1) 秒
    with freq_sel select
        step_max <= conv_std_logic_vector(STEP_BASE * 1 - 1, 24) when "00",
                    conv_std_logic_vector(STEP_BASE * 2 - 1, 24) when "01",
                    conv_std_logic_vector(STEP_BASE * 3 - 1, 24) when "10",
                    conv_std_logic_vector(STEP_BASE * 4 - 1, 24) when others;

    -- step_div: 數到 step_max 歸 0, 只改 step_cnt
    -- 用 >= 是為了 freq_sel 由慢切快時, step_cnt 已超過新上限也能歸 0
    step_div: process(CLK, RST)
        begin
            if RST = '0' then
                step_cnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if step_cnt >= step_max then
                    step_cnt <= (others => '0');
                else
                    step_cnt <= step_cnt + '1';
                end if;
            end if;
        end process;

    step_tick <= '1' when step_cnt = step_max else '0';

    -- FSM: 看 duty 到頂/到底決定換方向, 只改 state
    fsm: process(CLK, RST)
        begin
            if RST = '0' then
                state <= UP;                                       -- 先從暗變亮
            elsif CLK'event and CLK = '1' then
                if step_tick = '1' then
                    case state is
                        when UP =>
                            if duty = "11111111" then              -- 最亮 -> 開始變暗
                                state <= DOWN;
                            end if;
                        when DOWN =>
                            if duty = "00000000" then              -- 最暗 -> 開始變亮
                                state <= UP;
                            end if;
                    end case;
                end if;
            end if;
        end process;

    -- duty_ctr: 每個 step_tick, UP 上數 / DOWN 下數, 到頂/到底停住等 FSM 換向
    duty_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                duty <= "00000000";
            elsif CLK'event and CLK = '1' then
                if step_tick = '1' then
                    if state = UP then
                        if duty /= "11111111" then
                            duty <= duty + '1';
                        end if;
                    else
                        if duty /= "00000000" then
                            duty <= duty - '1';
                        end if;
                    end if;
                end if;
            end if;
        end process;

    -- 明暗解析度: 遮掉 duty 低位元, 階數 = 2^(8 - res_sel)
    with res_sel select
        res_mask <= "11111111" when "000",                        -- 256 階
                    "11111110" when "001",                        -- 128 階
                    "11111100" when "010",                        -- 64 階
                    "11111000" when "011",                        -- 32 階
                    "11110000" when "100",                        -- 16 階
                    "11100000" when "101",                        -- 8 階
                    "11000000" when "110",                        -- 4 階
                    "10000000" when others;                       -- 2 階 (亮/滅)

    duty_q <= duty and res_mask;

    -- pwm_ctr: 0 -> 255 循環計數, 只改 pwm_cnt
    pwm_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                pwm_cnt <= "00000000";
            elsif CLK'event and CLK = '1' then
                pwm_cnt <= pwm_cnt + '1';                          -- 255 + 1 自然溢位回 0
            end if;
        end process;

    -- pwm_out: pwm_cnt < duty_q 時亮, 用暫存器輸出避免組合邏輯毛刺, 只改 led_r
    pwm_out: process(CLK, RST)
        begin
            if RST = '0' then
                led_r <= '0';
            elsif CLK'event and CLK = '1' then
                if pwm_cnt < duty_q then
                    led_r <= '1';
                else
                    led_r <= '0';
                end if;
            end if;
        end process;

    -- 內部訊號接到輸出
    led    <= led_r;
    duty_o <= duty_q;
end Behavioral;
