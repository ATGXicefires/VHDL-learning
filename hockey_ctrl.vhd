----------------------------------------------------------------------------------
-- Module Name: hockey_ctrl - Behavioral
-- Description: 單人空氣曲棍球 (mode = "111") 的規則與物理: 玩家 (左半場) 對電腦 (右半場), 先得 7 分獲勝
--   座標是邏輯座標 (big = '1' 時畫面當成一半大, 和 3D、CD 一樣); 球的位置、速度是 Q.8
--   每個 CLK 都從目前狀態算出「下一個 frame」, 逐級暫存約 30 拍, frame_tick 時一次寫回
--   (狀態整個 frame 都不變, 中間各級不用對齊延遲):
--     1. 玩家球槌: 用上一個 frame_tick 取樣的按鈕, 按住越久越快 (2 -> 6 像素 / frame), 微調和大力擊球都能做
--     2. 電腦: 球在右半場且在電腦球槌左邊就衝過去打, 球在它右邊就繞過去, 否則回到球門前;
--        球在右半場時 y 跟著球, 在左半場時守中間 (反應慢一點, 斜射才有機會進); 速度: 守門 2 / 出擊 4 (hard = 1 時 4 / 6)
--     3. 球位置 += 速度, 再用 puck_hit 先算玩家、再算電腦的碰撞
--     4. 牆壁鏡射反彈 (保留 7/8 速度); 球門開口沒有牆:
--        球心在 H/2 +- 68 內 (整顆球塞得進 160 像素的開口) 才進得去, 進了開口後上下被門柱擋住, 球心出了畫面就是進球
--     5. 摩擦: |v| 每 frame 減 |v| / 256 + 1, 只按比例減的話慢速時會因為截斷永遠停不下來
--   比賽階段: PLAY -> 進球 -> GOAL (停約 1 秒, 被進球的球門閃爍, 然後失分方開球) -> 有人到 7 分 -> OVER
--   BTNC: PLAY 時暫停 / 繼續, OVER 時開新的一局; 換解析度時重新擺位 (保留比分); enable = '0' 時整個凍結
--   obj_x / obj_y: 0 = 球, 1 = 玩家球槌, 2 = 電腦球槌
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;                                          -- 位置、速度都是有號數
use work.vga_pkg.all;

entity hockey_ctrl is
    Port ( CLK        : in  STD_LOGIC;
           RST        : in  STD_LOGIC;
           frame_tick : in  STD_LOGIC;
           enable     : in  STD_LOGIC;
           btn        : in  STD_LOGIC_VECTOR (4 downto 0);
           h_size     : in  coord_type;
           v_size     : in  coord_type;
           big        : in  STD_LOGIC;
           hard       : in  STD_LOGIC;
           obj_x      : out coord3_type;
           obj_y      : out coord3_type;
           score_p    : out STD_LOGIC_VECTOR (2 downto 0);
           score_c    : out STD_LOGIC_VECTOR (2 downto 0);
           puck_show  : out STD_LOGIC;
           goal_l     : out STD_LOGIC;
           goal_r     : out STD_LOGIC;
           win_p      : out STD_LOGIC;
           win_c      : out STD_LOGIC;
           blink      : out STD_LOGIC;
           hit        : out STD_LOGIC;
           paused     : out STD_LOGIC);
end hockey_ctrl;

architecture Behavioral of hockey_ctrl is
    -- 尺寸要和 hockey_draw / puck_hit 一致
    constant WALL      : integer := 8;
    constant RP        : integer := 12;
    constant RM        : integer := 20;
    constant GOAL_HALF : integer := 80;                            -- 畫出來的球門開口半高
    constant POST      : integer := GOAL_HALF - RP;                -- 球心離 H/2 這麼近, 整顆球才進得了開口
    constant HOME_D    : integer := 40;                            -- 球槌原位離邊牆的距離
    constant AROUND    : integer := 44;
    constant M_MIN     : integer := WALL + RM;
    constant PK_MIN    : integer := WALL + RP;
    constant WIN       : integer := 7;
    constant GOAL_WAIT : integer := 60;

    subtype phase_type is STD_LOGIC_VECTOR (1 downto 0);
    constant PH_PLAY : phase_type := "00";
    constant PH_GOAL : phase_type := "01";
    constant PH_OVER : phase_type := "10";

    signal w_log, h_log       : signed (11 downto 0);
    signal mid_x, mid_y       : signed (11 downto 0);
    signal pm_x_max           : signed (11 downto 0);
    signal cm_x_min, cm_x_max : signed (11 downto 0);
    signal m_y_max            : signed (11 downto 0);
    signal pk_x_max, pk_y_max : signed (11 downto 0);
    signal mouth_lo, mouth_hi : signed (11 downto 0);
    signal home_c             : signed (11 downto 0);
    signal serve_c            : signed (11 downto 0);
    signal size_q             : coord_type;
    signal res_changed        : STD_LOGIC;

    signal btn_q              : STD_LOGIC_VECTOR (4 downto 0);
    signal press_c            : STD_LOGIC;
    signal moving             : STD_LOGIC;
    signal phase              : phase_type;
    signal phase_cnt          : unsigned (5 downto 0);
    signal paused_r           : STD_LOGIC;
    signal run                : STD_LOGIC;
    signal score_p_r          : unsigned (2 downto 0);
    signal score_c_r          : unsigned (2 downto 0);
    signal p_scored           : STD_LOGIC;                         -- 最近一球是玩家進的, 換電腦開球
    signal blink_cnt          : unsigned (3 downto 0);
    signal spd                : unsigned (4 downto 0);             -- 玩家球槌速度, Q.2 像素 / frame

    signal pmx, pmy           : signed (11 downto 0);
    signal cmx, cmy           : signed (11 downto 0);
    signal pux, puy           : signed (19 downto 0);
    signal pvx, pvy           : signed (15 downto 0);
    signal pux_i, puy_i       : signed (11 downto 0);

    signal step               : signed (11 downto 0);
    signal pm_tx, pm_ty       : signed (11 downto 0);
    signal pm_nx, pm_ny       : signed (11 downto 0);
    signal pm_vx, pm_vy       : signed (15 downto 0);
    signal cpu_half           : STD_LOGIC;
    signal deep               : STD_LOGIC;
    signal behind, attack     : STD_LOGIC;
    signal cs                 : signed (11 downto 0);
    signal tgt_x, tgt_y       : signed (11 downto 0);
    signal err_x, err_y       : signed (11 downto 0);
    signal cm_tx, cm_ty       : signed (11 downto 0);
    signal cm_nx, cm_ny       : signed (11 downto 0);
    signal cm_vx, cm_vy       : signed (15 downto 0);

    signal h1_px, h1_py       : signed (19 downto 0);
    signal h1_vx, h1_vy       : signed (15 downto 0);
    signal h2_px, h2_py       : signed (19 downto 0);
    signal h2_vx, h2_vy       : signed (15 downto 0);
    signal h1_hit, h2_hit     : STD_LOGIC;

    signal qx, qy             : signed (19 downto 0);
    signal ex_i, ey_i         : signed (11 downto 0);
    signal pk_x_max_q         : signed (19 downto 0);
    signal pk_y_max_q         : signed (19 downto 0);
    signal chan_l, chan_r     : STD_LOGIC;                         -- 球已經在左 / 右球門開口裡
    signal y_top_q, y_bot_q   : signed (19 downto 0);
    signal in_mouth           : STD_LOGIC;
    signal wall_l, wall_r     : STD_LOGIC;
    signal wall_t, wall_b     : STD_LOGIC;
    signal goal_lf, goal_rf   : STD_LOGIC;                         -- 球進了左 (玩家) / 右 (電腦) 球門
    signal rx, ry             : signed (19 downto 0);
    signal rvx, rvy           : signed (15 downto 0);
    signal mag_x, mag_y       : unsigned (15 downto 0);
    signal magd_x, magd_y     : unsigned (15 downto 0);
    signal fvx, fvy           : signed (15 downto 0);

    signal goal_now           : STD_LOGIC;
    signal goal_done          : STD_LOGIC;
    signal new_game           : STD_LOGIC;
    signal do_step, do_goal   : STD_LOGIC;
    signal do_serve           : STD_LOGIC;
begin
    w_log <= signed(resize(unsigned(h_size(10 downto 1)), 12)) when big = '1' else
             signed(resize(unsigned(h_size), 12));
    h_log <= signed(resize(unsigned(v_size(10 downto 1)), 12)) when big = '1' else
             signed(resize(unsigned(v_size), 12));
    mid_x <= shift_right(w_log, 1);
    mid_y <= shift_right(h_log, 1);

    -- 場地邊界只在換解析度時改變, 先存起來, 後面的比較才不會串上 解析度表 -> 加減法 這段路徑
    pm_x_max_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pm_x_max <= (others => '0');
            elsif CLK'event and CLK = '1' then
                pm_x_max <= mid_x - RM;
            end if;
        end process;

    cm_x_min_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cm_x_min <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cm_x_min <= mid_x + RM;
            end if;
        end process;

    cm_x_max_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cm_x_max <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cm_x_max <= w_log - M_MIN;
            end if;
        end process;

    m_y_max_reg: process(CLK, RST)
        begin
            if RST = '0' then
                m_y_max <= (others => '0');
            elsif CLK'event and CLK = '1' then
                m_y_max <= h_log - M_MIN;
            end if;
        end process;

    pk_x_max_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pk_x_max <= (others => '0');
            elsif CLK'event and CLK = '1' then
                pk_x_max <= w_log - PK_MIN;
            end if;
        end process;

    pk_y_max_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pk_y_max <= (others => '0');
            elsif CLK'event and CLK = '1' then
                pk_y_max <= h_log - PK_MIN;
            end if;
        end process;

    mouth_lo_reg: process(CLK, RST)
        begin
            if RST = '0' then
                mouth_lo <= (others => '0');
            elsif CLK'event and CLK = '1' then
                mouth_lo <= mid_y - POST;
            end if;
        end process;

    mouth_hi_reg: process(CLK, RST)
        begin
            if RST = '0' then
                mouth_hi <= (others => '0');
            elsif CLK'event and CLK = '1' then
                mouth_hi <= mid_y + POST;
            end if;
        end process;

    home_c_reg: process(CLK, RST)
        begin
            if RST = '0' then
                home_c <= (others => '0');
            elsif CLK'event and CLK = '1' then
                home_c <= w_log - (WALL + HOME_D);
            end if;
        end process;

    serve_c_reg: process(CLK, RST)
        begin
            if RST = '0' then
                serve_c <= (others => '0');
            elsif CLK'event and CLK = '1' then
                serve_c <= mid_x + shift_right(w_log, 2);
            end if;
        end process;

    -- 重置值 0 不是任何解析度的寬度: 第一個 frame_tick 一定會開球, 物件位置才會配合實際解析度
    size_prev: process(CLK, RST)
        begin
            if RST = '0' then
                size_q <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    size_q <= h_size;
                end if;
            end if;
        end process;

    res_changed <= '1' when size_q /= h_size else '0';

    btn_prev: process(CLK, RST)
        begin
            if RST = '0' then
                btn_q <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    btn_q <= btn;
                end if;
            end if;
        end process;

    press_c <= btn(BTN_C) and not btn_q(BTN_C);
    moving  <= btn_q(BTN_U) or btn_q(BTN_D) or btn_q(BTN_L) or btn_q(BTN_R);

    run       <= '1' when enable = '1' and paused_r = '0' and phase = PH_PLAY else '0';
    goal_now  <= goal_lf or goal_rf;
    goal_done <= '1' when enable = '1' and phase = PH_GOAL and phase_cnt = 0 else '0';
    new_game  <= '1' when enable = '1' and phase = PH_OVER and press_c = '1' else '0';
    do_step   <= frame_tick and run and not goal_now;
    do_goal   <= frame_tick and run and goal_now;
    do_serve  <= frame_tick and (res_changed or goal_done or new_game);

    phase_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                phase <= PH_PLAY;
            elsif CLK'event and CLK = '1' then
                if do_goal = '1' then
                    phase <= PH_GOAL;
                elsif frame_tick = '1' and goal_done = '1' then
                    if score_p_r = WIN or score_c_r = WIN then
                        phase <= PH_OVER;
                    else
                        phase <= PH_PLAY;
                    end if;
                elsif frame_tick = '1' and new_game = '1' then
                    phase <= PH_PLAY;
                end if;
            end if;
        end process;

    phase_cnt_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                phase_cnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if do_goal = '1' then
                    phase_cnt <= to_unsigned(GOAL_WAIT, 6);
                elsif frame_tick = '1' and enable = '1' and phase = PH_GOAL and phase_cnt /= 0 then
                    phase_cnt <= phase_cnt - 1;
                end if;
            end if;
        end process;

    paused_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                paused_r <= '0';
            elsif CLK'event and CLK = '1' then
                -- 和進球同一拍按下的暫停不算, 不然會一路暫停到下一局
                if do_goal = '1' then
                    paused_r <= '0';
                elsif frame_tick = '1' and enable = '1' and phase = PH_PLAY and press_c = '1' then
                    paused_r <= not paused_r;
                end if;
            end if;
        end process;

    score_p_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                score_p_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and new_game = '1' then
                    score_p_r <= (others => '0');
                elsif do_goal = '1' and goal_rf = '1' then
                    score_p_r <= score_p_r + 1;
                end if;
            end if;
        end process;

    score_c_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                score_c_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and new_game = '1' then
                    score_c_r <= (others => '0');
                elsif do_goal = '1' and goal_lf = '1' then
                    score_c_r <= score_c_r + 1;
                end if;
            end if;
        end process;

    p_scored_reg: process(CLK, RST)
        begin
            if RST = '0' then
                p_scored <= '0';
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and new_game = '1' then
                    p_scored <= '0';
                elsif do_goal = '1' then
                    p_scored <= goal_rf;
                end if;
            end if;
        end process;

    blink_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                blink_cnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and enable = '1' then
                    blink_cnt <= blink_cnt + 1;
                end if;
            end if;
        end process;

    spd_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                spd <= to_unsigned(8, 5);
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and run = '1' then
                    if moving = '0' then
                        spd <= to_unsigned(8, 5);
                    elsif spd < 24 then
                        spd <= spd + 1;
                    end if;
                end if;
            end if;
        end process;

    step <= signed(resize(spd(4 downto 2), 12));

    pm_tx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pm_tx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if btn_q(BTN_R) = '1' and btn_q(BTN_L) = '0' then
                    pm_tx <= pmx + step;
                elsif btn_q(BTN_L) = '1' and btn_q(BTN_R) = '0' then
                    pm_tx <= pmx - step;
                else
                    pm_tx <= pmx;
                end if;
            end if;
        end process;

    pm_ty_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pm_ty <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if btn_q(BTN_D) = '1' and btn_q(BTN_U) = '0' then
                    pm_ty <= pmy + step;
                elsif btn_q(BTN_U) = '1' and btn_q(BTN_D) = '0' then
                    pm_ty <= pmy - step;
                else
                    pm_ty <= pmy;
                end if;
            end if;
        end process;

    pm_nx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pm_nx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if pm_tx < M_MIN then
                    pm_nx <= to_signed(M_MIN, 12);
                elsif pm_tx > pm_x_max then
                    pm_nx <= pm_x_max;
                else
                    pm_nx <= pm_tx;
                end if;
            end if;
        end process;

    pm_ny_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pm_ny <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if pm_ty < M_MIN then
                    pm_ny <= to_signed(M_MIN, 12);
                elsif pm_ty > m_y_max then
                    pm_ny <= m_y_max;
                else
                    pm_ny <= pm_ty;
                end if;
            end if;
        end process;

    -- 碰撞要用球槌實際的位移, 撞到邊被夾住時就不算有速度
    pm_vx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pm_vx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                pm_vx <= shift_left(resize(pm_nx - pmx, 16), 8);
            end if;
        end process;

    pm_vy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pm_vy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                pm_vy <= shift_left(resize(pm_ny - pmy, 16), 8);
            end if;
        end process;

    pux_i <= pux(19 downto 8);
    puy_i <= puy(19 downto 8);

    -- 球在電腦球槌左邊才打得出去; 球跑到球槌和球門之間 (behind) 時硬推只會推進自己球門,
    -- 要從上或下繞過球 (間距 AROUND > 碰撞距離 32) 到它右邊再打
    -- 球貼著右牆 (deep) 時球槌繞不到它右邊, 只能直接推, 不然兩邊都不動會卡死
    -- 球正快速飛向電腦球門時先守門, 等球慢下來或往回走才出擊
    cpu_half <= '1' when pux_i > mid_x else '0';
    deep     <= '1' when pux_i >= cm_x_max - 4 else '0';
    behind   <= '1' when cpu_half = '1' and pux_i >= cmx - 4 and deep = '0' else '0';
    attack   <= '1' when cpu_half = '1' and ((pux_i < cmx - 4 and pvx < 2 * 256) or deep = '1') else '0';
    -- 出擊比守門快 2: 球槌速度決定擊球力道 (約 1.75 倍), 太慢的話電腦的球根本進不了
    cs       <= to_signed(6, 12) when hard = '1' and attack = '1' else
                to_signed(4, 12) when hard = '1' or attack = '1' else
                to_signed(2, 12);

    tgt_x_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tgt_x <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if behind = '1' then
                    tgt_x <= cm_x_max;
                elsif attack = '1' then
                    tgt_x <= pux_i;
                else
                    tgt_x <= home_c;
                end if;
            end if;
        end process;

    tgt_y_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tgt_y <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if behind = '1' then
                    if cmy < puy_i then
                        tgt_y <= puy_i - AROUND;
                    else
                        tgt_y <= puy_i + AROUND;
                    end if;
                elsif attack = '1' then
                    tgt_y <= puy_i;
                elsif cpu_half = '0' then
                    tgt_y <= mid_y;
                elsif puy_i < mouth_lo then
                    tgt_y <= mouth_lo;
                elsif puy_i > mouth_hi then
                    tgt_y <= mouth_hi;
                else
                    tgt_y <= puy_i;
                end if;
            end if;
        end process;

    err_x_reg: process(CLK, RST)
        begin
            if RST = '0' then
                err_x <= (others => '0');
            elsif CLK'event and CLK = '1' then
                err_x <= tgt_x - cmx;
            end if;
        end process;

    err_y_reg: process(CLK, RST)
        begin
            if RST = '0' then
                err_y <= (others => '0');
            elsif CLK'event and CLK = '1' then
                err_y <= tgt_y - cmy;
            end if;
        end process;

    cm_tx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cm_tx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if err_x > cs then
                    cm_tx <= cmx + cs;
                elsif err_x < -cs then
                    cm_tx <= cmx - cs;
                else
                    cm_tx <= cmx + err_x;
                end if;
            end if;
        end process;

    cm_ty_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cm_ty <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if err_y > cs then
                    cm_ty <= cmy + cs;
                elsif err_y < -cs then
                    cm_ty <= cmy - cs;
                else
                    cm_ty <= cmy + err_y;
                end if;
            end if;
        end process;

    cm_nx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cm_nx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if cm_tx < cm_x_min then
                    cm_nx <= cm_x_min;
                elsif cm_tx > cm_x_max then
                    cm_nx <= cm_x_max;
                else
                    cm_nx <= cm_tx;
                end if;
            end if;
        end process;

    cm_ny_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cm_ny <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if cm_ty < M_MIN then
                    cm_ny <= to_signed(M_MIN, 12);
                elsif cm_ty > m_y_max then
                    cm_ny <= m_y_max;
                else
                    cm_ny <= cm_ty;
                end if;
            end if;
        end process;

    cm_vx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cm_vx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cm_vx <= shift_left(resize(cm_nx - cmx, 16), 8);
            end if;
        end process;

    cm_vy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cm_vy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cm_vy <= shift_left(resize(cm_ny - cmy, 16), 8);
            end if;
        end process;

    -- 先移動再判斷碰撞: 碰到就把球放回球槌邊緣, 畫面上球才不會陷進球槌一格
    qx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                qx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                qx <= pux + pvx;
            end if;
        end process;

    qy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                qy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                qy <= puy + pvy;
            end if;
        end process;

    hit_player: entity work.puck_hit
        generic map ( PUSH_LEFT => false )
        port map ( CLK  => CLK,
                   RST  => RST,
                   px   => qx,
                   py   => qy,
                   vx   => pvx,
                   vy   => pvy,
                   mx   => pm_nx,
                   my   => pm_ny,
                   mvx  => pm_vx,
                   mvy  => pm_vy,
                   px_o => h1_px,
                   py_o => h1_py,
                   vx_o => h1_vx,
                   vy_o => h1_vy,
                   hit  => h1_hit );

    hit_cpu: entity work.puck_hit
        generic map ( PUSH_LEFT => true )
        port map ( CLK  => CLK,
                   RST  => RST,
                   px   => h1_px,
                   py   => h1_py,
                   vx   => h1_vx,
                   vy   => h1_vy,
                   mx   => cm_nx,
                   my   => cm_ny,
                   mvx  => cm_vx,
                   mvy  => cm_vy,
                   px_o => h2_px,
                   py_o => h2_py,
                   vx_o => h2_vx,
                   vy_o => h2_vy,
                   hit  => h2_hit );

    ex_i       <= h2_px(19 downto 8);
    ey_i       <= h2_py(19 downto 8);
    pk_x_max_q <= shift_left(resize(pk_x_max, 20), 8);
    pk_y_max_q <= shift_left(resize(pk_y_max, 20), 8);
    in_mouth   <= '1' when ey_i > mouth_lo and ey_i < mouth_hi else '0';

    -- 球已經進了開口: 左右不再有牆, 改由門柱擋上下 (球心夾在 H/2 +- POST);
    -- 不這樣做的話, 球在開口裡往上下偏出去時會被當成撞到邊牆, 從牆裡整段鏡射彈回來
    chan_l  <= '1' when pux < PK_MIN * 256 else '0';
    chan_r  <= '1' when pux > pk_x_max_q else '0';
    y_top_q <= shift_left(resize(mouth_lo, 20), 8) when chan_l = '1' or chan_r = '1' else
               to_signed(PK_MIN * 256, 20);
    y_bot_q <= shift_left(resize(mouth_hi, 20), 8) when chan_l = '1' or chan_r = '1' else
               pk_y_max_q;

    wall_l_reg: process(CLK, RST)
        begin
            if RST = '0' then
                wall_l <= '0';
            elsif CLK'event and CLK = '1' then
                if chan_l = '0' and h2_px < PK_MIN * 256 and in_mouth = '0' then
                    wall_l <= '1';
                else
                    wall_l <= '0';
                end if;
            end if;
        end process;

    wall_r_reg: process(CLK, RST)
        begin
            if RST = '0' then
                wall_r <= '0';
            elsif CLK'event and CLK = '1' then
                if chan_r = '0' and h2_px > pk_x_max_q and in_mouth = '0' then
                    wall_r <= '1';
                else
                    wall_r <= '0';
                end if;
            end if;
        end process;

    wall_t_reg: process(CLK, RST)
        begin
            if RST = '0' then
                wall_t <= '0';
            elsif CLK'event and CLK = '1' then
                if h2_py < y_top_q then
                    wall_t <= '1';
                else
                    wall_t <= '0';
                end if;
            end if;
        end process;

    wall_b_reg: process(CLK, RST)
        begin
            if RST = '0' then
                wall_b <= '0';
            elsif CLK'event and CLK = '1' then
                if h2_py > y_bot_q then
                    wall_b <= '1';
                else
                    wall_b <= '0';
                end if;
            end if;
        end process;

    goal_lf_reg: process(CLK, RST)
        begin
            if RST = '0' then
                goal_lf <= '0';
            elsif CLK'event and CLK = '1' then
                if ex_i < 0 and (in_mouth = '1' or chan_l = '1') then
                    goal_lf <= '1';
                else
                    goal_lf <= '0';
                end if;
            end if;
        end process;

    goal_rf_reg: process(CLK, RST)
        begin
            if RST = '0' then
                goal_rf <= '0';
            elsif CLK'event and CLK = '1' then
                if ex_i >= w_log and (in_mouth = '1' or chan_r = '1') then
                    goal_rf <= '1';
                else
                    goal_rf <= '0';
                end if;
            end if;
        end process;

    rx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if wall_l = '1' then
                    rx <= to_signed(2 * PK_MIN * 256, 20) - h2_px;
                elsif wall_r = '1' then
                    rx <= shift_left(pk_x_max_q, 1) - h2_px;
                else
                    rx <= h2_px;
                end if;
            end if;
        end process;

    ry_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ry <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if wall_t = '1' then
                    ry <= shift_left(y_top_q, 1) - h2_py;
                elsif wall_b = '1' then
                    ry <= shift_left(y_bot_q, 1) - h2_py;
                else
                    ry <= h2_py;
                end if;
            end if;
        end process;

    -- 只有往牆裡跑才反向: 球也可能是被球槌擠進牆裡的, 那時速度已經朝外了
    rvx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rvx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if (wall_l = '1' and h2_vx < 0) or (wall_r = '1' and h2_vx > 0) then
                    rvx <= shift_right(h2_vx, 3) - h2_vx;
                else
                    rvx <= h2_vx;
                end if;
            end if;
        end process;

    rvy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rvy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if (wall_t = '1' and h2_vy < 0) or (wall_b = '1' and h2_vy > 0) then
                    rvy <= shift_right(h2_vy, 3) - h2_vy;
                else
                    rvy <= h2_vy;
                end if;
            end if;
        end process;

    mag_x <= unsigned(abs(rvx));
    mag_y <= unsigned(abs(rvy));

    magd_x_reg: process(CLK, RST)
        begin
            if RST = '0' then
                magd_x <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if mag_x > shift_right(mag_x, 8) + 1 then
                    magd_x <= mag_x - shift_right(mag_x, 8) - 1;
                else
                    magd_x <= (others => '0');
                end if;
            end if;
        end process;

    magd_y_reg: process(CLK, RST)
        begin
            if RST = '0' then
                magd_y <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if mag_y > shift_right(mag_y, 8) + 1 then
                    magd_y <= mag_y - shift_right(mag_y, 8) - 1;
                else
                    magd_y <= (others => '0');
                end if;
            end if;
        end process;

    fvx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                fvx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if rvx < 0 then
                    fvx <= -signed(magd_x);
                else
                    fvx <= signed(magd_x);
                end if;
            end if;
        end process;

    fvy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                fvy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if rvy < 0 then
                    fvy <= -signed(magd_y);
                else
                    fvy <= signed(magd_y);
                end if;
            end if;
        end process;

    pmx_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                pmx <= to_signed(WALL + HOME_D, 12);
            elsif CLK'event and CLK = '1' then
                if do_serve = '1' then
                    pmx <= to_signed(WALL + HOME_D, 12);
                elsif do_step = '1' then
                    pmx <= pm_nx;
                end if;
            end if;
        end process;

    pmy_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                pmy <= to_signed(240, 12);
            elsif CLK'event and CLK = '1' then
                if do_serve = '1' then
                    pmy <= mid_y;
                elsif do_step = '1' then
                    pmy <= pm_ny;
                end if;
            end if;
        end process;

    cmx_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                cmx <= to_signed(640 - WALL - HOME_D, 12);
            elsif CLK'event and CLK = '1' then
                if do_serve = '1' then
                    cmx <= home_c;
                elsif do_step = '1' then
                    cmx <= cm_nx;
                end if;
            end if;
        end process;

    cmy_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                cmy <= to_signed(240, 12);
            elsif CLK'event and CLK = '1' then
                if do_serve = '1' then
                    cmy <= mid_y;
                elsif do_step = '1' then
                    cmy <= cm_ny;
                end if;
            end if;
        end process;

    -- 失分方開球: 球放在失分方半場的中央, 靜止
    pux_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                pux <= to_signed(160 * 256, 20);
            elsif CLK'event and CLK = '1' then
                if do_serve = '1' then
                    if p_scored = '1' and new_game = '0' then
                        pux <= shift_left(resize(serve_c, 20), 8);
                    else
                        pux <= shift_left(resize(shift_right(w_log, 2), 20), 8);
                    end if;
                elsif do_step = '1' then
                    pux <= rx;
                end if;
            end if;
        end process;

    puy_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                puy <= to_signed(240 * 256, 20);
            elsif CLK'event and CLK = '1' then
                if do_serve = '1' then
                    puy <= shift_left(resize(mid_y, 20), 8);
                elsif do_step = '1' then
                    puy <= ry;
                end if;
            end if;
        end process;

    pvx_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                pvx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if do_serve = '1' then
                    pvx <= (others => '0');
                elsif do_step = '1' then
                    pvx <= fvx;
                end if;
            end if;
        end process;

    pvy_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                pvy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if do_serve = '1' then
                    pvy <= (others => '0');
                elsif do_step = '1' then
                    pvy <= fvy;
                end if;
            end if;
        end process;

    obj_x(0) <= std_logic_vector(pux(18 downto 8));
    obj_y(0) <= std_logic_vector(puy(18 downto 8));
    obj_x(1) <= std_logic_vector(pmx(10 downto 0));
    obj_y(1) <= std_logic_vector(pmy(10 downto 0));
    obj_x(2) <= std_logic_vector(cmx(10 downto 0));
    obj_y(2) <= std_logic_vector(cmy(10 downto 0));

    score_p   <= std_logic_vector(score_p_r);
    score_c   <= std_logic_vector(score_c_r);
    puck_show <= '1' when phase /= PH_GOAL else '0';
    goal_l    <= '1' when phase = PH_GOAL and p_scored = '0' else '0';
    goal_r    <= '1' when phase = PH_GOAL and p_scored = '1' else '0';
    win_p     <= '1' when phase = PH_OVER and score_p_r = WIN else '0';
    win_c     <= '1' when phase = PH_OVER and score_c_r = WIN else '0';
    blink     <= blink_cnt(3);
    hit       <= h1_hit or h2_hit;
    paused    <= paused_r;
end Behavioral;
