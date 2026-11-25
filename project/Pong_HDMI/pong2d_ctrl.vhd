----------------------------------------------------------------------------------
-- Module Name: pong2d_ctrl - Behavioral
-- Description: 2D 乒乓的規則與物理: 左拍 = P1, 右拍 = P2 (two_p = '1') 或電腦, 先得 7 分獲勝
--   每次 tick (平常就是 frame_tick, 在垂直遮沒期間) 用 ph = 1..7 依序算完一步, 畫面掃描時狀態都不變:
--     ph1 取樣按鍵後的球拍速度、電腦的目標
--     ph2 球拍移動
--     ph3 球前進 (發球前球黏在發球方的球拍前)
--     ph4 上下牆反彈 (鏡射, 碰到牆那一下多走的距離折回來, 速度快時才不會卡進牆)
--     ph5 擊球: 這一步球的面「穿過」球拍正面才算 (只看重疊的話, 球速 16 像素時可能一步跳過球拍)
--     ph6 出界得分、階段切換
--   球的位置與速度是 Q.4 (1/16 像素), 慢速斜線才不會鋸齒
--   擊球後的 vy 由擊球點決定 (打在拍緣角度大, 打在中間直直回去), |vx| 每次加速直到 VMAX
--   電腦: 球朝它來才追 (簡單模式等球過半場才動), 有死區和速度上限, 所以斜線快球會漏接
--   BTNC: 發球 (發球方是人時) / 比賽中暫停 / 結束後開新局; 得分方發下一球 (和 LED_PingPong 一樣)
--   enable = '0' (切到 3D) 時整個凍結, 切回來接著玩
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;                                          -- 位置、速度都是有號數
use work.pong_pkg.all;

entity pong2d_ctrl is
    Port ( CLK      : in  STD_LOGIC;
           RST      : in  STD_LOGIC;
           tick     : in  STD_LOGIC;
           enable   : in  STD_LOGIC;
           two_p    : in  STD_LOGIC;
           hard     : in  STD_LOGIC;
           ctrl     : in  ctrl_type;
           pl_y     : out signed (11 downto 0);                    -- 左拍上緣
           pr_y     : out signed (11 downto 0);                    -- 右拍上緣
           ball_x   : out signed (11 downto 0);                    -- 球外框左上角
           ball_y   : out signed (11 downto 0);
           ball_on  : out STD_LOGIC;
           score_l  : out unsigned (2 downto 0);
           score_r  : out unsigned (2 downto 0);
           gphase   : out gphase_type;
           paused   : out STD_LOGIC;
           blink    : out STD_LOGIC);
end pong2d_ctrl;

architecture Behavioral of pong2d_ctrl is
    constant SPD0       : integer := 5;                            -- 球拍剛按下的速度 (像素 / frame)
    constant SPD_MAX    : integer := 14;                           -- 按住約 0.15 秒後的最高速度
    constant V0         : integer := 7 * 16;                       -- 發球速度 (Q.4)
    constant ACC        : integer := 8;                            -- 每次擊球 |vx| 加 0.5 像素
    constant VMAX       : integer := 16 * 16;
    constant SERVE_WAIT : integer := 50;                           -- 電腦發球前等約 0.8 秒
    constant POINT_WAIT : integer := 60;
    -- 發球後這段時間 BTNC 不算暫停: 電腦發球的同時按 BTNC 想發球, 不該一開球就停住
    constant PAUSE_GUARD : integer := 15;

    constant PL_FACE  : signed (15 downto 0) := to_signed((PL_X + PAD_W) * 16, 16);
    constant PR_FACE  : signed (15 downto 0) := to_signed((PR_X - BALL_S) * 16, 16);
    constant TOP_Q    : signed (15 downto 0) := to_signed(FY0 * 16, 16);
    constant BOT_Q    : signed (15 downto 0) := to_signed((FY1 - BALL_S) * 16, 16);
    constant OUT_L    : signed (15 downto 0) := to_signed(-BALL_S * 16, 16);
    constant OUT_R    : signed (15 downto 0) := to_signed(SCR_W * 16, 16);
    constant PAD_MIN  : signed (11 downto 0) := to_signed(FY0, 12);
    constant PAD_MAX  : signed (11 downto 0) := to_signed(FY1 - PAD_H, 12);
    constant PAD_MID  : signed (11 downto 0) := to_signed((FY0 + FY1 - PAD_H) / 2, 12);

    signal ph          : unsigned (2 downto 0);
    signal s1, s2, s3  : STD_LOGIC;
    signal s4, s5, s6  : STD_LOGIC;
    signal ctrl_q      : ctrl_type;
    signal c_prev      : STD_LOGIC;
    signal press_c     : STD_LOGIC;
    signal lfsr        : STD_LOGIC_VECTOR (15 downto 0);
    signal fcnt        : unsigned (4 downto 0);
    signal wcnt        : unsigned (6 downto 0);

    signal gph         : gphase_type;
    signal gph_next    : gphase_type;
    signal paused_r    : STD_LOGIC;
    signal go          : STD_LOGIC;                                -- 比賽中且沒暫停, 球才會動
    signal server_l    : STD_LOGIC;                                -- 下一球由左邊發
    signal human_srv   : STD_LOGIC;
    signal score_l_r   : unsigned (2 downto 0);
    signal score_r_r   : unsigned (2 downto 0);

    signal l_up, l_dn  : STD_LOGIC;
    signal r_up, r_dn  : STD_LOGIC;
    signal spd_l       : unsigned (4 downto 0);
    signal spd_r       : unsigned (4 downto 0);
    signal pl          : signed (11 downto 0);
    signal pr          : signed (11 downto 0);

    signal aim         : signed (11 downto 0);                     -- 電腦想用球拍的哪裡接球
    signal cpu_tgt     : signed (11 downto 0);
    signal cpu_err     : signed (11 downto 0);
    signal cpu_step    : signed (11 downto 0);
    signal cpu_dz      : signed (11 downto 0);

    signal bx, by      : signed (15 downto 0);
    signal bx_old      : signed (15 downto 0);
    signal vx, vy      : signed (11 downto 0);
    signal bx_i, by_i  : signed (11 downto 0);
    signal off_l       : signed (11 downto 0);                     -- 球心相對球拍中心的位置
    signal off_r       : signed (11 downto 0);
    signal hit_l       : STD_LOGIC;
    signal hit_r       : STD_LOGIC;
    signal miss_l      : STD_LOGIC;                                -- 球從左邊出界 = 右邊得分
    signal miss_r      : STD_LOGIC;
    signal vx_fast     : signed (11 downto 0);                     -- 擊球後的 |vx|
    signal serve_vy    : signed (11 downto 0);

    function clamp(v, lo, hi : signed) return signed is
    begin
        if v < lo then
            return lo;
        elsif v > hi then
            return hi;
        end if;
        return v;
    end function;
begin
    ---------------------------------------------------------------- 步驟計數與輸入
    ph_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ph <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if tick = '1' and enable = '1' then
                    ph <= "001";
                elsif ph /= 0 then
                    ph <= ph + 1;                                  -- 7 之後繞回 0, 停下來等下一次 tick
                end if;
            end if;
        end process;

    s1 <= '1' when ph = 1 else '0';
    s2 <= '1' when ph = 2 else '0';
    s3 <= '1' when ph = 3 else '0';
    s4 <= '1' when ph = 4 else '0';
    s5 <= '1' when ph = 5 else '0';
    s6 <= '1' when ph = 6 else '0';

    -- 按鍵只在 tick 取樣: 間隔約 16 ms, 本身就濾掉按鈕彈跳
    ctrl_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ctrl_q <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if tick = '1' and enable = '1' then
                    ctrl_q <= ctrl;
                end if;
            end if;
        end process;

    c_prev_reg: process(CLK, RST)
        begin
            if RST = '0' then
                c_prev <= '0';
            elsif CLK'event and CLK = '1' then
                if tick = '1' and enable = '1' then
                    c_prev <= ctrl_q(K_C);
                end if;
            end if;
        end process;

    press_c <= ctrl_q(K_C) and not c_prev;

    -- 每個 CLK 都跑, 取值的時間點取決於人按鍵的時刻, 對遊戲來說就夠亂了
    lfsr_reg: process(CLK, RST)
        begin
            if RST = '0' then
                lfsr <= x"ACE1";
            elsif CLK'event and CLK = '1' then
                lfsr <= lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
            end if;
        end process;

    fcnt_reg: process(CLK, RST)
        begin
            if RST = '0' then
                fcnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s1 = '1' then
                    fcnt <= fcnt + 1;
                end if;
            end if;
        end process;

    -- 進入新階段時歸 0, 用來數 POINT 停頓和電腦發球前的等待 (單位 = frame)
    wcnt_reg: process(CLK, RST)
        begin
            if RST = '0' then
                wcnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s6 = '1' then
                    if gph_next /= gph then
                        wcnt <= (others => '0');
                    elsif wcnt /= 127 then
                        wcnt <= wcnt + 1;
                    end if;
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- 比賽階段
    human_srv <= server_l or two_p;
    go        <= '1' when gph = GP_PLAY and paused_r = '0' else '0';

    gph_next_comb: process(gph, human_srv, press_c, wcnt, go, miss_l, miss_r, score_l_r, score_r_r)
        begin
            gph_next <= gph;
            case gph is
                when GP_SERVE =>
                    if (human_srv = '1' and press_c = '1') or (human_srv = '0' and wcnt >= SERVE_WAIT) then
                        gph_next <= GP_PLAY;
                    end if;
                when GP_PLAY =>
                    if go = '1' and (miss_l = '1' or miss_r = '1') then
                        gph_next <= GP_POINT;
                    end if;
                when GP_POINT =>
                    if wcnt >= POINT_WAIT then
                        if score_l_r = WIN or score_r_r = WIN then
                            gph_next <= GP_OVER;
                        else
                            gph_next <= GP_SERVE;
                        end if;
                    end if;
                when others =>
                    if press_c = '1' then
                        gph_next <= GP_SERVE;
                    end if;
            end case;
        end process;

    gph_reg: process(CLK, RST)
        begin
            if RST = '0' then
                gph <= GP_SERVE;
            elsif CLK'event and CLK = '1' then
                if s6 = '1' then
                    gph <= gph_next;
                end if;
            end if;
        end process;

    paused_reg: process(CLK, RST)
        begin
            if RST = '0' then
                paused_r <= '0';
            elsif CLK'event and CLK = '1' then
                if s6 = '1' then
                    if gph /= GP_PLAY then
                        paused_r <= '0';
                    elsif press_c = '1' and wcnt >= PAUSE_GUARD then
                        paused_r <= not paused_r;
                    end if;
                end if;
            end if;
        end process;

    -- 得分方發下一球; 開新局由上一局的贏家先發
    server_reg: process(CLK, RST)
        begin
            if RST = '0' then
                server_l <= '1';
            elsif CLK'event and CLK = '1' then
                if s6 = '1' and go = '1' then
                    if miss_r = '1' then
                        server_l <= '1';
                    elsif miss_l = '1' then
                        server_l <= '0';
                    end if;
                end if;
            end if;
        end process;

    score_l_reg: process(CLK, RST)
        begin
            if RST = '0' then
                score_l_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s6 = '1' then
                    if go = '1' and miss_r = '1' then
                        score_l_r <= score_l_r + 1;
                    elsif gph = GP_OVER and press_c = '1' then
                        score_l_r <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    score_r_reg: process(CLK, RST)
        begin
            if RST = '0' then
                score_r_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s6 = '1' then
                    if go = '1' and miss_l = '1' then
                        score_r_r <= score_r_r + 1;
                    elsif gph = GP_OVER and press_c = '1' then
                        score_r_r <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- 球拍
    l_up <= ctrl_q(K_UP) and not ctrl_q(K_DN);
    l_dn <= ctrl_q(K_DN) and not ctrl_q(K_UP);
    r_up <= ctrl_q(K_P2UP) and not ctrl_q(K_P2DN);
    r_dn <= ctrl_q(K_P2DN) and not ctrl_q(K_P2UP);

    -- 按住越久越快: 輕點能微調, 長按能趕到遠處
    spd_l_reg: process(CLK, RST)
        begin
            if RST = '0' then
                spd_l <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s1 = '1' then
                    if (l_up or l_dn) = '0' then
                        spd_l <= (others => '0');
                    elsif spd_l < SPD0 then
                        spd_l <= to_unsigned(SPD0, 5);
                    elsif spd_l < SPD_MAX then
                        spd_l <= spd_l + 1;
                    end if;
                end if;
            end if;
        end process;

    spd_r_reg: process(CLK, RST)
        begin
            if RST = '0' then
                spd_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s1 = '1' then
                    if (r_up or r_dn) = '0' then
                        spd_r <= (others => '0');
                    elsif spd_r < SPD0 then
                        spd_r <= to_unsigned(SPD0, 5);
                    elsif spd_r < SPD_MAX then
                        spd_r <= spd_r + 1;
                    end if;
                end if;
            end if;
        end process;

    pl_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pl <= PAD_MID;
            elsif CLK'event and CLK = '1' then
                if s2 = '1' and paused_r = '0' then
                    if l_up = '1' then
                        pl <= clamp(pl - signed('0' & spd_l), PAD_MIN, PAD_MAX);
                    elsif l_dn = '1' then
                        pl <= clamp(pl + signed('0' & spd_l), PAD_MIN, PAD_MAX);
                    end if;
                end if;
            end if;
        end process;

    -- 電腦接球前隨機挑一個擊球點, 回球角度才會變化 (簡單模式固定用中間)
    aim_reg: process(CLK, RST)
        begin
            if RST = '0' then
                aim <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s5 = '1' and hit_l = '1' and hard = '1' then
                    aim <= resize(signed(lfsr(4 downto 0)), 12);   -- -16 .. 15
                end if;
            end if;
        end process;

    -- 球朝電腦來才追, 否則回中間等; 簡單模式等球過了半場才反應
    cpu_tgt_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cpu_tgt <= PAD_MID;
            elsif CLK'event and CLK = '1' then
                if s1 = '1' then
                    if gph = GP_PLAY and vx > 0 and (hard = '1' or bx_i > SCR_W / 2 - 64) then
                        cpu_tgt <= by_i + BALL_S / 2 - PAD_H / 2 + aim;
                    else
                        cpu_tgt <= PAD_MID;
                    end if;
                end if;
            end if;
        end process;

    cpu_err  <= cpu_tgt - pr;
    cpu_step <= to_signed(7, 12) when hard = '1' else to_signed(5, 12);
    cpu_dz   <= to_signed(4, 12) when hard = '1' else to_signed(12, 12);

    pr_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pr <= PAD_MID;
            elsif CLK'event and CLK = '1' then
                if s2 = '1' and paused_r = '0' then
                    if two_p = '1' then
                        if r_up = '1' then
                            pr <= clamp(pr - signed('0' & spd_r), PAD_MIN, PAD_MAX);
                        elsif r_dn = '1' then
                            pr <= clamp(pr + signed('0' & spd_r), PAD_MIN, PAD_MAX);
                        end if;
                    elsif cpu_err > cpu_dz then
                        if cpu_err > cpu_step then
                            pr <= clamp(pr + cpu_step, PAD_MIN, PAD_MAX);
                        else
                            pr <= clamp(pr + cpu_err, PAD_MIN, PAD_MAX);
                        end if;
                    elsif cpu_err < -cpu_dz then
                        if cpu_err < -cpu_step then
                            pr <= clamp(pr - cpu_step, PAD_MIN, PAD_MAX);
                        else
                            pr <= clamp(pr + cpu_err, PAD_MIN, PAD_MAX);
                        end if;
                    end if;
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- 球
    bx_i <= bx(15 downto 4);
    by_i <= by(15 downto 4);

    off_l <= (by_i + BALL_S / 2) - (pl + PAD_H / 2);
    off_r <= (by_i + BALL_S / 2) - (pr + PAD_H / 2);

    hit_l <= '1' when vx < 0 and bx < PL_FACE and bx_old >= PL_FACE
                      and by_i + BALL_S > pl and by_i < pl + PAD_H else '0';
    hit_r <= '1' when vx > 0 and bx > PR_FACE and bx_old <= PR_FACE
                      and by_i + BALL_S > pr and by_i < pr + PAD_H else '0';

    miss_l <= '1' when bx < OUT_L else '0';
    miss_r <= '1' when bx > OUT_R else '0';

    vx_fast  <= abs(vx) + ACC when abs(vx) + ACC < VMAX else to_signed(VMAX, 12);
    serve_vy <= resize(signed(lfsr(5 downto 0)), 12);              -- +-2 像素 / frame

    bx_old_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bx_old <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    bx_old <= bx;
                end if;
            end if;
        end process;

    bx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bx <= to_signed((PL_X + PAD_W + 2) * 16, 16);
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    if gph = GP_SERVE then
                        if server_l = '1' then
                            bx <= to_signed((PL_X + PAD_W + 2) * 16, 16);
                        else
                            bx <= to_signed((PR_X - BALL_S - 2) * 16, 16);
                        end if;
                    elsif go = '1' then
                        bx <= bx + vx;
                    end if;
                elsif s5 = '1' and go = '1' then
                    if hit_l = '1' then
                        bx <= PL_FACE + PL_FACE - bx;
                    elsif hit_r = '1' then
                        bx <= PR_FACE + PR_FACE - bx;
                    end if;
                end if;
            end if;
        end process;

    by_reg: process(CLK, RST)
        begin
            if RST = '0' then
                by <= (PAD_MID + PAD_H / 2 - BALL_S / 2) & "0000";
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    if gph = GP_SERVE then
                        if server_l = '1' then
                            by <= (pl + PAD_H / 2 - BALL_S / 2) & "0000";
                        else
                            by <= (pr + PAD_H / 2 - BALL_S / 2) & "0000";
                        end if;
                    elsif go = '1' then
                        by <= by + vy;
                    end if;
                elsif s4 = '1' and go = '1' then
                    if by < TOP_Q then
                        by <= TOP_Q + TOP_Q - by;
                    elsif by > BOT_Q then
                        by <= BOT_Q + BOT_Q - by;
                    end if;
                end if;
            end if;
        end process;

    vx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s5 = '1' and go = '1' then
                    if hit_l = '1' then
                        vx <= vx_fast;
                    elsif hit_r = '1' then
                        vx <= -vx_fast;
                    end if;
                elsif s6 = '1' then
                    if gph = GP_SERVE then
                        if server_l = '1' then
                            vx <= to_signed(V0, 12);
                        else
                            vx <= to_signed(-V0, 12);
                        end if;
                    elsif gph /= GP_PLAY then
                        vx <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    -- 擊球點每偏離中心 1 像素, vy 加 3/16 像素: 打在拍緣 (偏 56) 約 10 像素 / frame
    vy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s4 = '1' and go = '1' and (by < TOP_Q or by > BOT_Q) then
                    vy <= -vy;
                elsif s5 = '1' and go = '1' then
                    if hit_l = '1' then
                        vy <= resize(off_l * 3, 12);
                    elsif hit_r = '1' then
                        vy <= resize(off_r * 3, 12);
                    end if;
                elsif s6 = '1' and gph = GP_SERVE then
                    vy <= serve_vy;
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- 輸出
    pl_y    <= pl;
    pr_y    <= pr;
    ball_x  <= bx_i;
    ball_y  <= by_i;
    ball_on <= '1' when gph = GP_SERVE or gph = GP_PLAY else '0';
    score_l <= score_l_r;
    score_r <= score_r_r;
    gphase  <= gph;
    paused  <= paused_r;
    blink   <= fcnt(4);
end Behavioral;
