----------------------------------------------------------------------------------
-- Module Name: led_pingpong - Behavioral
-- Description: 板載 LED 雙人來回擊球遊戲
--   目標板: E-Elements EGO-XZ7 (xc7z020clg484-1, sys_clk = 100 MHz)
--   腳位見 led_pingpong.xdc: SW7 = RST,
--                            BTNU = 上方玩家 (守 LD7), BTND = 下方玩家 (守 LD0)
--
--   架構:
--     btn_u/d -> 2 級 FF 同步 -> 每 10 ms 取樣 (順便濾掉彈跳) -> press_u/d (1 CLK 脈衝)
--                                                                    |
--     step_cnt / step_max -> step_tick (球走一格) --------------------+--> 判定 hit / early / miss
--                                                                    |
--     state (SERVE -> PLAY -> SCORE -> SERVE | OVER) <---------------+
--     ball (8 bit one-hot, 移位前進) / bar_u / bar_d (4 bit, 得分移入 '1') ---> led_r ---> led
--
--   球和分數條直接存成 LED 圖樣: 球每走一格移位 1 bit, 每得 1 分移入一個 '1',
--   不需要再從位置 / 分數解碼成 LED
--
--   玩法:
--     SERVE: 球停在發球方那端閃爍, 發球方按自己的鍵發球 (開機由下方先發, 之後由得分方發)
--     PLAY : 球走到自己那端 (LD7 / LD0) 時按自己的鍵打回去, 每打回一次球速加快 1/8
--            太早按 (球還沒到) 或球到了沒按 (下一格時間到) 都算失分
--     SCORE: 顯示比分約 1 秒, 上半 4 顆 = 上方玩家, 下半 4 顆 = 下方玩家
--     OVER : 先得 4 分獲勝, 贏家那半邊閃爍, 贏家按自己的鍵清分開新局
--
--   CLK_FREQ 為 generic: 板上用 100_000_000, 模擬時可設小值加速
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;

entity led_pingpong is
    Generic ( CLK_FREQ : integer := 100_000_000 );                 -- 系統時脈 (Hz)
    Port ( CLK   : in  STD_LOGIC;
           RST   : in  STD_LOGIC;
           btn_u : in  STD_LOGIC;
           btn_d : in  STD_LOGIC;
           led   : out STD_LOGIC_VECTOR (7 downto 0));
end led_pingpong;

architecture Behavioral of led_pingpong is
    type state_type is (SERVE, PLAY, SCORE, OVER);
    signal state : state_type;

    constant BU : integer := 0;
    constant BD : integer := 1;

    constant SAMP_MAX   : integer := CLK_FREQ / 100 - 1;
    constant STEP_INIT  : integer := CLK_FREQ / 4;
    -- 最快一格 1/12 s: 再快人的反應就跟不上擊球窗口了
    constant STEP_MIN   : integer := CLK_FREQ / 12;
    constant SHOW_MAX   : integer := CLK_FREQ - 1;
    constant BLINK_MAX  : integer := CLK_FREQ / 2 - 1;

    signal btn_raw   : STD_LOGIC_VECTOR (1 downto 0);
    signal btn_meta  : STD_LOGIC_VECTOR (1 downto 0);
    signal btn_sync  : STD_LOGIC_VECTOR (1 downto 0);
    signal samp_cnt  : STD_LOGIC_VECTOR (23 downto 0);
    signal samp_tick : STD_LOGIC;
    signal btn_q     : STD_LOGIC_VECTOR (1 downto 0);
    signal press_u   : STD_LOGIC;
    signal press_d   : STD_LOGIC;
    signal press_srv : STD_LOGIC;                                  -- 發球方 (= 上一分得分方) 按鍵

    signal step_cnt  : STD_LOGIC_VECTOR (26 downto 0);
    signal step_max  : STD_LOGIC_VECTOR (26 downto 0);
    signal step_next : STD_LOGIC_VECTOR (26 downto 0);
    signal step_tick : STD_LOGIC;

    signal ball      : STD_LOGIC_VECTOR (7 downto 0);             -- one-hot, bit 7 = LD7
    signal dir       : STD_LOGIC;                                  -- '1' = 往上 (往 LD7)
    signal server    : STD_LOGIC;                                  -- '1' = 上方發球

    signal hit_u, hit_d     : STD_LOGIC;
    signal early_u, early_d : STD_LOGIC;
    signal miss_u, miss_d   : STD_LOGIC;
    signal hit              : STD_LOGIC;
    signal point_u, point_d : STD_LOGIC;                           -- 上方 / 下方得分

    signal bar_u     : STD_LOGIC_VECTOR (3 downto 0);             -- 接 LD7..LD4, 從 LD7 往下長
    signal bar_d     : STD_LOGIC_VECTOR (3 downto 0);             -- 接 LD3..LD0, 從 LD0 往上長
    signal game_end  : STD_LOGIC;
    signal new_game  : STD_LOGIC;

    signal show_cnt  : STD_LOGIC_VECTOR (26 downto 0);
    signal show_done : STD_LOGIC;
    signal blink_cnt : STD_LOGIC_VECTOR (26 downto 0);
    signal blink_slow : STD_LOGIC;                                 -- 2 Hz
    signal blink_fast : STD_LOGIC;                                 -- 4 Hz

    signal mask_u    : STD_LOGIC_VECTOR (3 downto 0);
    signal mask_d    : STD_LOGIC_VECTOR (3 downto 0);
    signal led_r     : STD_LOGIC_VECTOR (7 downto 0);
begin
    btn_raw <= btn_d & btn_u;

    -- 按鍵與 CLK 非同步, 2 級 FF 避免亞穩態擴散到遊戲邏輯
    sync_meta: process(CLK, RST)
        begin
            if RST = '0' then
                btn_meta <= "00";
            elsif CLK'event and CLK = '1' then
                btn_meta <= btn_raw;
            end if;
        end process;

    sync_reg: process(CLK, RST)
        begin
            if RST = '0' then
                btn_sync <= "00";
            elsif CLK'event and CLK = '1' then
                btn_sync <= btn_meta;
            end if;
        end process;

    samp_div: process(CLK, RST)
        begin
            if RST = '0' then
                samp_cnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if samp_cnt >= SAMP_MAX then
                    samp_cnt <= (others => '0');
                else
                    samp_cnt <= samp_cnt + '1';
                end if;
            end if;
        end process;

    samp_tick <= '1' when samp_cnt = SAMP_MAX else '0';

    -- 只在 10 ms 取樣一次: 彈跳 (通常 < 5 ms) 夾在兩次取樣之間, 不會被當成多次按下
    btn_prev: process(CLK, RST)
        begin
            if RST = '0' then
                btn_q <= "00";
            elsif CLK'event and CLK = '1' then
                if samp_tick = '1' then
                    btn_q <= btn_sync;
                end if;
            end if;
        end process;

    press_u <= samp_tick and btn_sync(BU) and not btn_q(BU);
    press_d <= samp_tick and btn_sync(BD) and not btn_q(BD);

    -- 得分方發下一球, 所以遊戲結束時 server 也正好是贏家: 發球和開新局都看同一顆鍵
    press_srv <= press_u when server = '1' else press_d;

    -- 判定: 只有球朝自己飛來時按鍵才有作用, 球飛走時亂按不算犯規
    hit_u   <= '1' when state = PLAY and dir = '1' and ball(7) = '1' and press_u = '1' else '0';
    hit_d   <= '1' when state = PLAY and dir = '0' and ball(0) = '1' and press_d = '1' else '0';
    early_u <= '1' when state = PLAY and dir = '1' and ball(7) = '0' and press_u = '1' else '0';
    early_d <= '1' when state = PLAY and dir = '0' and ball(0) = '0' and press_d = '1' else '0';
    miss_u  <= '1' when state = PLAY and dir = '1' and ball(7) = '1' and step_tick = '1'
                        and press_u = '0' else '0';
    miss_d  <= '1' when state = PLAY and dir = '0' and ball(0) = '1' and step_tick = '1'
                        and press_d = '0' else '0';

    hit     <= hit_u or hit_d;
    point_d <= early_u or miss_u;
    point_u <= early_d or miss_d;

    -- 擊中時歸 0: 打回去之後要給對方完整一格的時間, 不能沿用打之前剩下的計數
    step_div: process(CLK, RST)
        begin
            if RST = '0' then
                step_cnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if state /= PLAY or hit = '1' or step_cnt >= step_max then
                    step_cnt <= (others => '0');
                else
                    step_cnt <= step_cnt + '1';
                end if;
            end if;
        end process;

    step_tick <= '1' when state = PLAY and step_cnt >= step_max else '0';

    step_next <= step_max - ("000" & step_max(26 downto 3));

    -- 離開 PLAY 就回初速, 所以失分後下一球從頭開始加速
    speed_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                step_max <= conv_std_logic_vector(STEP_INIT, 27);
            elsif CLK'event and CLK = '1' then
                if state /= PLAY then
                    step_max <= conv_std_logic_vector(STEP_INIT, 27);
                elsif hit = '1' then
                    if step_next < STEP_MIN then
                        step_max <= conv_std_logic_vector(STEP_MIN, 27);
                    else
                        step_max <= step_next;
                    end if;
                end if;
            end if;
        end process;

    -- 球在端點時這一拍不移位: miss 由 state 轉去 SCORE; 擊中和 step_tick 同拍時
    -- dir 還沒反向, 若照舊移位, 唯一的 '1' 會被移出去, 球就消失了
    ball_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                ball <= "00000001";
            elsif CLK'event and CLK = '1' then
                if state = SERVE then
                    if server = '1' then
                        ball <= "10000000";
                    else
                        ball <= "00000001";
                    end if;
                elsif step_tick = '1' and hit = '0' and miss_u = '0' and miss_d = '0' then
                    if dir = '1' then
                        ball <= ball(6 downto 0) & '0';
                    else
                        ball <= '0' & ball(7 downto 1);
                    end if;
                end if;
            end if;
        end process;

    dir_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                dir <= '1';
            elsif CLK'event and CLK = '1' then
                if state = SERVE then
                    dir <= not server;
                elsif hit = '1' then
                    dir <= not dir;
                end if;
            end if;
        end process;

    -- 開新局時不重設, 上一局贏家先發
    server_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                server <= '0';
            elsif CLK'event and CLK = '1' then
                if point_u = '1' then
                    server <= '1';
                elsif point_d = '1' then
                    server <= '0';
                end if;
            end if;
        end process;

    new_game <= '1' when state = OVER and press_srv = '1' else '0';

    bar_u_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                bar_u <= "0000";
            elsif CLK'event and CLK = '1' then
                if new_game = '1' then
                    bar_u <= "0000";
                elsif point_u = '1' then
                    bar_u <= '1' & bar_u(3 downto 1);
                end if;
            end if;
        end process;

    bar_d_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                bar_d <= "0000";
            elsif CLK'event and CLK = '1' then
                if new_game = '1' then
                    bar_d <= "0000";
                elsif point_d = '1' then
                    bar_d <= bar_d(2 downto 0) & '1';
                end if;
            end if;
        end process;

    -- 分數條長到另一端 (第 4 分) 就結束: 獲勝分數由分數條長度 (半邊 4 顆 LED) 決定
    game_end <= bar_u(0) or bar_d(3);

    show_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                show_cnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if state /= SCORE then
                    show_cnt <= (others => '0');
                else
                    show_cnt <= show_cnt + '1';
                end if;
            end if;
        end process;

    show_done <= '1' when show_cnt = SHOW_MAX else '0';

    fsm: process(CLK, RST)
        begin
            if RST = '0' then
                state <= SERVE;
            elsif CLK'event and CLK = '1' then
                case state is
                    when SERVE =>
                        if press_srv = '1' then
                            state <= PLAY;
                        end if;
                    when PLAY =>
                        if point_u = '1' or point_d = '1' then
                            state <= SCORE;
                        end if;
                    when SCORE =>
                        if show_done = '1' then
                            if game_end = '1' then
                                state <= OVER;
                            else
                                state <= SERVE;
                            end if;
                        end if;
                    when OVER =>
                        if new_game = '1' then
                            state <= SERVE;
                        end if;
                end case;
            end if;
        end process;

    blink_div: process(CLK, RST)
        begin
            if RST = '0' then
                blink_cnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if blink_cnt >= BLINK_MAX then
                    blink_cnt <= (others => '0');
                else
                    blink_cnt <= blink_cnt + '1';
                end if;
            end if;
        end process;

    blink_slow <= '1' when blink_cnt < CLK_FREQ / 4 else '0';
    blink_fast <= '1' when blink_cnt < CLK_FREQ / 8
                        or (blink_cnt >= CLK_FREQ / 4 and blink_cnt < CLK_FREQ * 3 / 8) else '0';

    mask_u <= "0000" when state = OVER and bar_u(0) = '1' and blink_fast = '0' else "1111";
    mask_d <= "0000" when state = OVER and bar_d(3) = '1' and blink_fast = '0' else "1111";

    -- 用暫存器輸出, 避免狀態切換瞬間的組合邏輯毛刺讓 LED 閃一下
    led_out: process(CLK, RST)
        begin
            if RST = '0' then
                led_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                case state is
                    when SERVE =>
                        if blink_slow = '1' then
                            led_r <= ball;
                        else
                            led_r <= (others => '0');
                        end if;
                    when PLAY =>
                        led_r <= ball;
                    when others =>
                        led_r <= (bar_u and mask_u) & (bar_d and mask_d);
                end case;
            end if;
        end process;

    -- 內部訊號接到輸出
    led <= led_r;
end Behavioral;
