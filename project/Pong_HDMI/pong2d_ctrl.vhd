----------------------------------------------------------------------------------
-- Module Name: pong2d_ctrl - Behavioral
-- Description: 2D 側視桌球的規則與物理: 左拍 = P1, 右拍 = P2 (two_p = '1') 或電腦, 先得 7 分獲勝
--   從側面看球桌 (尺寸見 pong_pkg): 球有重力, 在桌上彈跳, 中間有網; 球拍在桌子兩端外面, 只能上下移
--   這是 pong3d_ctrl 的側面版 (3D 的 Z 就是這裡的 X), 每次 tick 一樣用 ph = 1..7 依序算完一步:
--     ph1 球拍速度、電腦的目標
--     ph2 算出這一步球拍要移多少 (擊球時拿來決定落點)
--     ph3 球拍移動; 球前進、受重力 (發球前球停在發球方球拍的斜上方)
--     ph4 碰網、碰桌面
--     ph5 球到了接球方的擊球面: 彈過、球拍又碰得到就回擊, 決定落點
--     ph6 依落點算出新速度; 得分與階段切換
--   擊球和 3D 一樣先決定落點再反推速度 v = (落點 - 現在位置) / T, 除法換成乘上 RECIP = 4096 / T
--   發球照真的規則分兩段: 先打到自己半場的固定點, 彈到那裡的那一步再發射一次到對方半場,
--     所以彈起來一定是往上的拋物線, 也一定過網; srv_leg = 還在第一段
--   死球判定 (owner = 最後擊球的是左邊, bounced = 已經在接球方半場彈過):
--     擊球方失誤 (接球方得分): 撞網、撞到桌緣、第一次落地不在對方半場或出界、沒落地就飛過接球方的擊球面
--     接球方失誤 (擊球方得分): 球拍沒碰到、在自己半場彈第二次、球掉到地板
--   得分方發下一球 (和 LED_PingPong 一樣); 發球方是人時按自己的「上」發球 (左 = BTNU, 右 = P2 上),
--     兩個人各用各的鍵, 不會搞不清楚現在該誰發; BTNC 只管比賽中暫停和結束後開新局
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
           pl_y     : out signed (11 downto 0);                    -- 左拍中心 (x 固定在 PL2_X)
           pr_y     : out signed (11 downto 0);                    -- 右拍中心
           ball_x   : out signed (11 downto 0);                    -- 球心
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
    constant G          : integer := GRAV;
    constant SERVE_WAIT : integer := 50;                           -- 電腦發球前等約 0.8 秒
    constant POINT_WAIT : integer := 60;
    constant SRV_DX     : integer := 40;                           -- 發球前球在拍心的斜上方
    constant SRV_DY     : integer := 56;
    -- 球拍放得很低時球也不能低於這裡, 否則第一段會從桌緣底下撞進桌子
    constant SRV_YMAX   : integer := TBL2_Y - 72;
    constant SRV1_D     : integer := 128;                          -- 發球第一跳離自己的桌端
    constant SRV2_D     : integer := 128;                          -- 人發球第二跳離對方的桌端
    constant D_BASE     : integer := 192;                          -- 回球的基本落點離網多遠
    constant REACH_R    : integer := PAD2_R + RB2;                 -- 球心離拍心這麼近都算接到

    -- 飛行時間表: 0..7 是回球的速度級 (人每回一球升一級, 得分後回到 0), 8、9 是發球的兩段
    type t_table is array (0 to 9) of integer;
    constant T_FLY : t_table := (48, 45, 42, 39, 36, 34, 32, 30, 16, 30);
    constant T_SRV1 : integer := 8;
    constant T_SRV2 : integer := 9;

    function make_recip return t_table is
        variable r : t_table;
    begin
        for i in 0 to 9 loop
            r(i) := (4096 + T_FLY(i) / 2) / T_FLY(i);
        end loop;
        return r;
    end function;

    -- ph3 是 by += vy 之後才 vy += G, T 步共多落 G T (T - 1) / 2, 起始 vy 要先扣掉平均值 G (T - 1) / 2
    function make_gcomp return t_table is
        variable r : t_table;
    begin
        for i in 0 to 9 loop
            r(i) := G * (T_FLY(i) - 1) / 2;
        end loop;
        return r;
    end function;

    constant RECIP : t_table := make_recip;
    constant GCOMP : t_table := make_gcomp;

    -- Q.4 的比較值
    constant TLQ    : signed (15 downto 0) := to_signed((TBL2_Y - RB2) * 16, 16);   -- 球碰到桌面時的球心高度
    constant NETTQ  : signed (15 downto 0) := to_signed((TBL2_Y - NET2_H - RB2) * 16, 16);
    constant FLOORQ : signed (15 downto 0) := to_signed((FLOOR2_Y - RB2) * 16, 16);
    constant TX0Q   : signed (15 downto 0) := to_signed(TX0 * 16, 16);
    constant TX1Q   : signed (15 downto 0) := to_signed(TX1 * 16, 16);
    constant NETQ   : signed (15 downto 0) := to_signed(NET2_X * 16, 16);
    constant LXQ    : signed (15 downto 0) := to_signed(PL2_X * 16, 16);             -- 左擊球面
    constant RXQ    : signed (15 downto 0) := to_signed(PR2_X * 16, 16);
    constant OFF_LQ : signed (15 downto 0) := to_signed(-RB2 * 16, 16);              -- 出了畫面
    constant OFF_RQ : signed (15 downto 0) := to_signed((SCR_W + RB2) * 16, 16);
    constant YMIN   : signed (11 downto 0) := to_signed(P2_YMIN, 12);
    constant YMAX   : signed (11 downto 0) := to_signed(P2_YMAX, 12);
    constant HOME   : signed (11 downto 0) := to_signed(P2_HOME, 12);

    signal ph          : unsigned (2 downto 0);
    signal s1, s2, s3  : STD_LOGIC;
    signal s4, s5, s6  : STD_LOGIC;
    signal ctrl_q      : ctrl_type;
    signal k_prev      : ctrl_type;                                -- 上一個 tick 的按鍵, 抓「剛按下」
    signal press_c     : STD_LOGIC;
    signal press_srv   : STD_LOGIC;                                -- 發球方的「上」剛按下
    signal lfsr        : STD_LOGIC_VECTOR (15 downto 0);
    signal fcnt        : unsigned (4 downto 0);
    signal wcnt        : unsigned (6 downto 0);

    signal gph         : gphase_type;
    signal gph_next    : gphase_type;
    signal paused_r    : STD_LOGIC;
    signal go          : STD_LOGIC;                                -- 比賽中且沒暫停, 球才會動
    signal serving     : STD_LOGIC;
    signal server_l    : STD_LOGIC;                                -- 下一球由左邊發
    signal human_srv   : STD_LOGIC;
    signal score_l_r   : unsigned (2 downto 0);
    signal score_r_r   : unsigned (2 downto 0);

    signal l_up, l_dn  : STD_LOGIC;
    signal r_up, r_dn  : STD_LOGIC;
    signal spd_l       : unsigned (4 downto 0);
    signal spd_r       : unsigned (4 downto 0);
    signal pl, pr      : signed (11 downto 0);
    signal dpl, dpr    : signed (11 downto 0);                     -- 這一步球拍移了多少

    signal track       : STD_LOGIC;                                -- 電腦正在追球
    signal dxr         : signed (15 downto 0);                     -- 球離電腦擊球面還有多遠 (Q.4)
    signal vx16, vy16  : signed (15 downto 0);
    signal lead_q      : signed (15 downto 0);
    signal lead_y      : signed (11 downto 0);
    signal tgt         : signed (11 downto 0);
    signal cerr        : signed (11 downto 0);
    signal cstep       : signed (11 downto 0);

    signal bx, by      : signed (15 downto 0);
    signal vx, vy      : signed (11 downto 0);
    signal bx_i, by_i  : signed (11 downto 0);
    signal srv_y       : signed (11 downto 0);                     -- 發球前球的高度
    signal owner       : STD_LOGIC;                                -- 最後擊球的是左邊
    signal bounced     : STD_LOGIC;                                -- 已經在接球方半場彈過
    signal srv_leg     : STD_LOGIC;                                -- 發球的第一段 (要先彈在自己半場)
    signal srv_bnc     : STD_LOGIC;                                -- 這一步發球彈在自己半場, 要發射第二段
    signal lvl         : unsigned (2 downto 0);
    signal tsel        : unsigned (3 downto 0);                    -- 這次發射用哪一項飛行時間
    signal cpu_fast    : STD_LOGIC;                                -- 困難模式電腦這一球用最快的速度級
    signal land        : signed (11 downto 0);                     -- 這一段的落點 x
    signal launch      : STD_LOGIC;                                -- ph6 要依落點重算速度
    signal drift       : STD_LOGIC;                                -- 這一分是漏接 (球飛過擊球面)
    signal fly         : STD_LOGIC;                                -- 這一步球要前進
    signal pt_end      : STD_LOGIC;                                -- 這一步成了死球
    signal pt_l        : STD_LOGIC;                                -- 這一分給左邊

    -- ph4
    signal by_prev     : signed (15 downto 0);
    signal bx_prev     : signed (15 downto 0);
    signal cross_tbl   : STD_LOGIC;                                -- 這一步往下穿過桌面高度
    signal on_tbl      : STD_LOGIC;
    signal rcv_half    : STD_LOGIC;                                -- 球在接球方的半場
    signal net_hit     : STD_LOGIC;
    signal bounce_ok   : STD_LOGIC;
    signal dead4       : STD_LOGIC;
    signal pwin4       : STD_LOGIC;

    -- ph5
    signal off_l       : signed (11 downto 0);                     -- 球心相對拍心 (正 = 球在拍心下方)
    signal off_r       : signed (11 downto 0);
    signal at_l        : STD_LOGIC;                                -- 球飛過了左擊球面
    signal at_r        : STD_LOGIC;
    signal hit_l       : STD_LOGIC;
    signal hit_r       : STD_LOGIC;
    signal human_hit   : STD_LOGIC;
    signal dead5       : STD_LOGIC;
    signal pwin5       : STD_LOGIC;
    signal dist_l      : signed (11 downto 0);                     -- 人回球的落點離網多遠
    signal dist_r      : signed (11 downto 0);
    signal rand_r      : signed (11 downto 0);
    signal rand_d      : signed (11 downto 0);                     -- 電腦回球的落點離網多遠
    signal srv2_land   : signed (11 downto 0);

    -- ph6
    signal recip_t     : signed (10 downto 0);
    signal dvx, dvy    : signed (16 downto 0);                     -- 到落點的距離 (Q.4)

    function clamp(v, lo, hi : signed) return signed is
    begin
        if v < lo then
            return lo;
        elsif v > hi then
            return hi;
        end if;
        return v;
    end function;

    -- 球拍每 frame 最多移 step, 差距小於死區就不動 (免得電腦抖個不停)
    function chase(pos, err, step, dz, lo, hi : signed) return signed is
    begin
        if err > dz then
            if err > step then
                return clamp(pos + step, lo, hi);
            end if;
            return clamp(pos + err, lo, hi);
        elsif err < -dz then
            if err < -step then
                return clamp(pos - step, lo, hi);
            end if;
            return clamp(pos + err, lo, hi);
        end if;
        return pos;
    end function;

    -- d / T: d 乘上 RECIP = 4096 / T 再右移 12 位; 先加 2048 四捨五入, 每個 frame 的誤差才不會都往同一邊累積
    function per_frame(d : signed (16 downto 0); r : signed (10 downto 0)) return signed is
        variable p : signed (27 downto 0);
    begin
        p := d * r + 2048;
        return resize(shift_right(p, 12), 12);
    end function;

    -- 落點離網 = D_BASE - 3 off - 2 dp: 打在拍子上半部 (off < 0) 球比較長, 擊球時球拍往上帶 (dp < 0) 也比較長;
    --   打在拍緣 (|off| = 36) 是 84 或 300, 再帶一點拍就出界或很靠近網
    function hit_dist(off, dp : signed (11 downto 0)) return signed is
    begin
        return to_signed(D_BASE, 12) - shift_left(off, 1) - off - shift_left(dp, 1);
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

    k_prev_reg: process(CLK, RST)
        begin
            if RST = '0' then
                k_prev <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if tick = '1' and enable = '1' then
                    k_prev <= ctrl_q;
                end if;
            end if;
        end process;

    press_c <= ctrl_q(K_C) and not k_prev(K_C);
    -- 要剛按下才發: 得分停頓時按著「上」移拍子, 進入發球狀態時不會馬上被發出去
    press_srv <= ctrl_q(K_UP) and not k_prev(K_UP) when server_l = '1' else
                 ctrl_q(K_P2UP) and not k_prev(K_P2UP);

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
    serving   <= '1' when gph = GP_SERVE else '0';

    gph_next_comb: process(gph, human_srv, press_srv, press_c, wcnt, go, pt_end, score_l_r, score_r_r)
        begin
            gph_next <= gph;
            case gph is
                when GP_SERVE =>
                    if (human_srv = '1' and press_srv = '1') or (human_srv = '0' and wcnt >= SERVE_WAIT) then
                        gph_next <= GP_PLAY;
                    end if;
                when GP_PLAY =>
                    if go = '1' and pt_end = '1' then
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
                    elsif press_c = '1' then
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
                if s6 = '1' and go = '1' and pt_end = '1' then
                    server_l <= pt_l;
                end if;
            end if;
        end process;

    score_l_reg: process(CLK, RST)
        begin
            if RST = '0' then
                score_l_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s6 = '1' then
                    if go = '1' and pt_end = '1' and pt_l = '1' then
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
                    if go = '1' and pt_end = '1' and pt_l = '0' then
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

    dpl_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dpl <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s2 = '1' then
                    if paused_r = '1' then
                        dpl <= (others => '0');
                    elsif l_up = '1' then
                        dpl <= clamp(pl - signed('0' & spd_l), YMIN, YMAX) - pl;
                    elsif l_dn = '1' then
                        dpl <= clamp(pl + signed('0' & spd_l), YMIN, YMAX) - pl;
                    else
                        dpl <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    dpr_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dpr <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s2 = '1' then
                    if paused_r = '1' then
                        dpr <= (others => '0');
                    elsif two_p = '0' then
                        dpr <= chase(pr, cerr, cstep, to_signed(4, 12), YMIN, YMAX) - pr;
                    elsif r_up = '1' then
                        dpr <= clamp(pr - signed('0' & spd_r), YMIN, YMAX) - pr;
                    elsif r_dn = '1' then
                        dpr <= clamp(pr + signed('0' & spd_r), YMIN, YMAX) - pr;
                    else
                        dpr <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    -- dpl / dpr 在 ph2 算好, ph3 才加上去, 擊球時用的移動量和實際移動一定一致
    pl_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pl <= HOME;
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    pl <= pl + dpl;
                end if;
            end if;
        end process;

    pr_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pr <= HOME;
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    pr <= pr + dpr;
                end if;
            end if;
        end process;

    -- 電腦: 球落地前高高低低, 跟著跑只會白忙, 所以在自己半場彈起來之後才追
    --   簡單模式只看 4 個 frame 後 (球上下動得快時會跟不上); 困難模式先看球還要飛幾個 frame 才到擊球面 (取 16 / 8 / 4 / 2 裡
    --   不超過的最大值, 只要位移和比較), 照重力推算那時的高度, 越接近越準
    track  <= '1' when gph = GP_PLAY and owner = '1' and bounced = '1' else '0';
    dxr    <= RXQ - bx;
    vx16   <= resize(vx, 16);
    vy16   <= resize(vy, 16);

    lead_comb: process(hard, by, vy16, vx16, dxr)
        begin
            if hard = '0' then
                lead_q <= by + shift_left(vy16, 2) + G * 6;
            elsif dxr >= shift_left(vx16, 4) then
                lead_q <= by + shift_left(vy16, 4) + G * 120;     -- k frame 後: by + k vy + G k (k - 1) / 2
            elsif dxr >= shift_left(vx16, 3) then
                lead_q <= by + shift_left(vy16, 3) + G * 28;
            elsif dxr >= shift_left(vx16, 2) then
                lead_q <= by + shift_left(vy16, 2) + G * 6;
            elsif dxr >= shift_left(vx16, 1) then
                lead_q <= by + shift_left(vy16, 1) + G;
            else
                lead_q <= by;
            end if;
        end process;

    lead_y <= lead_q(15 downto 4);

    tgt_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tgt <= HOME;
            elsif CLK'event and CLK = '1' then
                if s1 = '1' then
                    if track = '1' then
                        tgt <= lead_y;
                    else
                        tgt <= HOME;
                    end if;
                end if;
            end if;
        end process;

    cerr  <= tgt - pr;
    cstep <= to_signed(9, 12) when hard = '1' else to_signed(4, 12);

    ---------------------------------------------------------------- ph4: 網子與桌面
    bx_i <= bx(15 downto 4);
    by_i <= by(15 downto 4);

    -- ph3 先 by += vy 再 vy += G, 所以上一步的 by = by - (vy - G)
    by_prev   <= by - vy + G;
    bx_prev   <= bx - vx;
    cross_tbl <= '1' when by >= TLQ and by_prev < TLQ else '0';
    on_tbl    <= '1' when bx >= TX0Q and bx <= TX1Q else '0';
    rcv_half  <= '1' when (owner = '1' and bx >= NETQ) or (owner = '0' and bx < NETQ) else '0';
    net_hit   <= '1' when ((bx_prev < NETQ) xor (bx < NETQ)) and by > NETTQ else '0';
    -- 發球第一段要彈在自己半場, 其餘 (第二段和回球) 要第一次就彈在接球方半場
    bounce_ok <= cross_tbl and on_tbl and not net_hit
                 and ((srv_leg and not rcv_half) or (not srv_leg and rcv_half and not bounced));

    -- 死球與得分方: 擊球方失誤 -> 接球方 (not owner) 得分; 接球方失誤 -> 擊球方 (owner) 得分
    --   球在桌面以下又在桌子範圍內: 落在不該落的半場、兩跳, 或從桌緣側面撞進桌子
    dead_comb: process(net_hit, cross_tbl, on_tbl, bounced, bounce_ok, by)
        begin
            dead4 <= '0';
            if net_hit = '1' then
                dead4 <= '1';
            elsif on_tbl = '1' and by >= TLQ and bounce_ok = '0' then
                dead4 <= '1';
            elsif cross_tbl = '1' and on_tbl = '0' and bounced = '0' then  -- 沒落在桌上: 出界
                dead4 <= '1';
            elsif by > FLOORQ then
                dead4 <= '1';
            end if;
        end process;

    -- 只有接球方失誤 (兩跳、彈過之後掉到地板) 才是擊球方得分, 其餘都是擊球方自己失誤
    pwin_comb: process(net_hit, on_tbl, rcv_half, bounced, bounce_ok, by, owner)
        begin
            pwin4 <= not owner;
            if net_hit = '1' then
                pwin4 <= not owner;
            elsif on_tbl = '1' and by >= TLQ and bounce_ok = '0' then
                if rcv_half = '1' and bounced = '1' then           -- 接球方半場第二次落地: 兩跳
                    pwin4 <= owner;
                end if;
            elsif by > FLOORQ and bounced = '1' then
                pwin4 <= owner;
            end if;
        end process;

    ---------------------------------------------------------------- ph5: 擊球面
    off_l <= by_i - pl;
    off_r <= by_i - pr;

    at_l  <= '1' when owner = '0' and bx < LXQ else '0';
    at_r  <= '1' when owner = '1' and bx > RXQ else '0';
    hit_l <= '1' when at_l = '1' and bounced = '1' and abs(off_l) <= REACH_R else '0';
    hit_r <= '1' when at_r = '1' and bounced = '1' and abs(off_r) <= REACH_R else '0';
    human_hit <= hit_l or (hit_r and two_p);
    -- 沒彈過就到了: 球太長, 擊球方失誤; 彈過但沒碰到拍: 擊球方得分
    dead5 <= (at_l or at_r) and not (hit_l or hit_r);
    pwin5 <= owner when bounced = '1' else not owner;

    dist_l <= hit_dist(off_l, dpl);
    dist_r <= hit_dist(off_r, dpr);
    -- 電腦的落點離網多遠 (r = 0 .. 255 隨機):
    --   困難模式 96 + 11/16 r = 96 .. 271: 深淺都打, 但不打太短 (速度快時短球會掛網), 也不貼著桌端打
    --     (貼桌端的快球彈起來幾個 frame 就到擊球面, 人根本來不及)
    --   簡單模式 112 + 15/16 r = 112 .. 351: 約 12% 打出界, 像新手會失誤, 對打才不會沒完沒了
    rand_r <= signed(resize(unsigned(lfsr(7 downto 0)), 12));
    --   困難模式也有約 1/32 的球打長出界 (再強的人也會失誤), 不然穩穩回球的人可以跟它打到天荒地老
    rand_d <= to_signed(336, 12) when hard = '1' and lfsr(15 downto 11) = "11111" else
              to_signed(96, 12) + rand_r - shift_right(rand_r, 2) - shift_right(rand_r, 4) when hard = '1' else
              to_signed(112, 12) + rand_r - shift_right(rand_r, 4);
    -- 發球第二跳: 人固定打深, 電腦離對方桌端 64 .. 191 隨機
    srv2_land <= to_signed(TX1 - SRV2_D, 12) when server_l = '1' else
                 to_signed(TX0 + SRV2_D, 12) when two_p = '1' else
                 to_signed(TX0 + 64, 12) + signed(resize(unsigned(lfsr(6 downto 0)), 12));

    pt_end_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pt_end <= '0';
            elsif CLK'event and CLK = '1' then
                if s1 = '1' then
                    pt_end <= '0';
                elsif go = '1' and pt_end = '0' and ((s4 = '1' and dead4 = '1') or (s5 = '1' and dead5 = '1')) then
                    pt_end <= '1';
                end if;
            end if;
        end process;

    pt_l_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pt_l <= '0';
            elsif CLK'event and CLK = '1' then
                if go = '1' and pt_end = '0' then
                    if s4 = '1' and dead4 = '1' then
                        pt_l <= pwin4;
                    elsif s5 = '1' and dead5 = '1' then
                        pt_l <= pwin5;
                    end if;
                end if;
            end if;
        end process;

    owner_reg: process(CLK, RST)
        begin
            if RST = '0' then
                owner <= '1';
            elsif CLK'event and CLK = '1' then
                if s5 = '1' then
                    if serving = '1' then
                        owner <= server_l;
                    elsif go = '1' and pt_end = '0' and hit_l = '1' then
                        owner <= '1';
                    elsif go = '1' and pt_end = '0' and hit_r = '1' then
                        owner <= '0';
                    end if;
                end if;
            end if;
        end process;

    bounced_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bounced <= '0';
            elsif CLK'event and CLK = '1' then
                if s4 = '1' and go = '1' and pt_end = '0' and bounce_ok = '1' and srv_leg = '0' then
                    bounced <= '1';
                elsif s5 = '1' and (serving = '1' or (go = '1' and pt_end = '0' and (hit_l or hit_r) = '1')) then
                    bounced <= '0';
                end if;
            end if;
        end process;

    srv_leg_reg: process(CLK, RST)
        begin
            if RST = '0' then
                srv_leg <= '0';
            elsif CLK'event and CLK = '1' then
                if s4 = '1' and go = '1' and pt_end = '0' and bounce_ok = '1' then
                    srv_leg <= '0';
                elsif s5 = '1' and serving = '1' then
                    srv_leg <= '1';
                end if;
            end if;
        end process;

    -- ph4 算好, ph5 決定第二段的落點、ph6 發射時都還看得到
    srv_bnc_reg: process(CLK, RST)
        begin
            if RST = '0' then
                srv_bnc <= '0';
            elsif CLK'event and CLK = '1' then
                if s4 = '1' then
                    srv_bnc <= go and not pt_end and bounce_ok and srv_leg;
                end if;
            end if;
        end process;

    lvl_reg: process(CLK, RST)
        begin
            if RST = '0' then
                lvl <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s5 = '1' then
                    if serving = '1' then
                        lvl <= (others => '0');
                    elsif go = '1' and pt_end = '0' and human_hit = '1' and lvl /= 7 then
                        lvl <= lvl + 1;                            -- 只有人回球會加速, 節奏由人決定
                    end if;
                end if;
            end if;
        end process;

    land_reg: process(CLK, RST)
        begin
            if RST = '0' then
                land <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s5 = '1' then
                    if serving = '1' then
                        if server_l = '1' then
                            land <= to_signed(TX0 + SRV1_D, 12);
                        else
                            land <= to_signed(TX1 - SRV1_D, 12);
                        end if;
                    elsif go = '1' and pt_end = '0' then
                        if srv_bnc = '1' then
                            land <= srv2_land;
                        elsif hit_l = '1' then
                            land <= NET2_X + dist_l;
                        elsif hit_r = '1' and two_p = '1' then
                            land <= NET2_X - dist_r;
                        elsif hit_r = '1' then
                            land <= NET2_X - rand_d;
                        end if;
                    end if;
                end if;
            end if;
        end process;

    -- 發球期間每個 frame 都依球拍位置重算, 開球那一刻速度就已經是對的
    launch_reg: process(CLK, RST)
        begin
            if RST = '0' then
                launch <= '0';
            elsif CLK'event and CLK = '1' then
                if s5 = '1' then
                    launch <= serving or (go and not pt_end and (srv_bnc or hit_l or hit_r));
                end if;
            end if;
        end process;

    -- 困難模式電腦一半的深球用最快那級回, 不讓人一直慢慢對打 (rand_d 用 lfsr 低 8 位, 這裡用另外一位);
    --   短球又快, 弧線太平會掛網, 所以只有離網 160 以上才快攻
    cpu_fast_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cpu_fast <= '0';
            elsif CLK'event and CLK = '1' then
                if s5 = '1' then
                    if rand_d >= 160 then
                        cpu_fast <= hit_r and not two_p and hard and lfsr(12);
                    else
                        cpu_fast <= '0';
                    end if;
                end if;
            end if;
        end process;

    tsel <= to_unsigned(T_SRV1, 4) when serving = '1' else
            to_unsigned(T_SRV2, 4) when srv_bnc = '1' else
            to_unsigned(7, 4) when cpu_fast = '1' else
            resize(lvl, 4);

    ---------------------------------------------------------------- 球
    srv_y <= clamp(pl + dpl - SRV_DY, YMIN - SRV_DY, to_signed(SRV_YMAX, 12)) when server_l = '1'
             else clamp(pr + dpr - SRV_DY, YMIN - SRV_DY, to_signed(SRV_YMAX, 12));

    -- 漏接時球不停在擊球面上 (那裡和拍子重疊, 看起來像接到了), 得分的停頓期間繼續飛過去、往下掉,
    --   出了畫面或落到地板才停; 其他死球 (撞網、出界) 停在原地, 看得出是怎麼丟分的
    drift_reg: process(CLK, RST)
        begin
            if RST = '0' then
                drift <= '0';
            elsif CLK'event and CLK = '1' then
                if s5 = '1' then
                    if serving = '1' then
                        drift <= '0';
                    elsif go = '1' and pt_end = '0' and dead5 = '1' then
                        drift <= '1';
                    end if;
                end if;
            end if;
        end process;

    fly <= '1' when go = '1' or (drift = '1' and gph = GP_POINT and bx > OFF_LQ and bx < OFF_RQ and by < FLOORQ)
           else '0';

    bx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bx <= to_signed((PL2_X + SRV_DX) * 16, 16);
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    if serving = '1' then
                        if server_l = '1' then
                            bx <= to_signed((PL2_X + SRV_DX) * 16, 16);
                        else
                            bx <= to_signed((PR2_X - SRV_DX) * 16, 16);
                        end if;
                    elsif fly = '1' then
                        bx <= bx + vx;
                    end if;
                elsif s5 = '1' and go = '1' and pt_end = '0' then
                    if hit_l = '1' then                            -- 回擊從擊球面出發
                        bx <= LXQ;
                    elsif hit_r = '1' then
                        bx <= RXQ;
                    end if;
                end if;
            end if;
        end process;

    by_reg: process(CLK, RST)
        begin
            if RST = '0' then
                by <= to_signed((P2_HOME - SRV_DY) * 16, 16);
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    if serving = '1' then
                        by <= srv_y & "0000";
                    elsif fly = '1' then
                        by <= by + vy;
                    end if;
                elsif s4 = '1' and go = '1' and pt_end = '0' and bounce_ok = '1' then
                    by <= TLQ + TLQ - by;                          -- 鏡射回桌面上方
                end if;
            end if;
        end process;

    recip_t <= to_signed(RECIP(to_integer(tsel)), 11);
    dvx     <= resize(land & "0000", 17) - bx;
    -- 瞄準桌面下 4 像素: 速度取整數會少一點, 瞄剛好的話可能晚一步才穿過桌面, 落點就多走一個 vx
    dvy     <= resize(TLQ, 17) + 64 - by;

    vx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s6 = '1' and launch = '1' then
                    vx <= per_frame(dvx, recip_t);
                end if;
            end if;
        end process;

    vy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s3 = '1' and fly = '1' then
                    vy <= vy + G;
                elsif s4 = '1' and go = '1' and pt_end = '0' and bounce_ok = '1' then
                    vy <= shift_right(vy, 3) - vy;                 -- 反彈只剩 7/8
                elsif s6 = '1' and launch = '1' then
                    vy <= per_frame(dvy, recip_t) - GCOMP(to_integer(tsel));
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- 輸出
    pl_y    <= pl;
    pr_y    <= pr;
    ball_x  <= bx_i;
    ball_y  <= by_i;
    ball_on <= '0' when gph = GP_OVER else '1';
    score_l <= score_l_r;
    score_r <= score_r_r;
    gphase  <= gph;
    paused  <= paused_r;
    blink   <= fcnt(4);
end Behavioral;
