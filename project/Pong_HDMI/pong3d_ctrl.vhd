----------------------------------------------------------------------------------
-- Module Name: pong3d_ctrl - Behavioral
-- Description: 3D 球桌的規則與物理: 玩家在桌子這一端 (Z = 0) 對電腦 (Z = Z_FAR), 先得 7 分獲勝
--   世界座標 (見 pong_pkg): X 向右, Y 向下, Z 往對面; 球的位置、速度是 Q.4, 有重力
--   和 pong2d_ctrl 一樣, 每次 tick 用 ph = 1..7 依序算完一步, 畫面掃描時狀態都不變:
--     ph1 球拍速度、電腦的目標, 清掉上一步的得分旗標
--     ph2 球拍移動 (順便記下這一步移了多少, 擊球時拿來決定落點)
--     ph3 球前進、受重力 (發球前球黏在發球方的球拍前)
--     ph4 碰網、碰桌面: 落在接球方半場第一次就彈起來, 其餘情況都是死球
--     ph5 球到了接球方的擊球面: 彈過、球拍又碰得到就回擊, 決定落點
--     ph6 擊球 (或發球) 後依落點算出新速度; 得分與階段切換
--   擊球不直接給速度, 而是先決定「落點」, 再反推速度: 飛到落點要 T 個 frame (依速度級查表),
--     v = (落點 - 現在位置) / T, 除法換成乘上常數 RECIP = 4096 / T, 所以不需要除法器
--     這樣回球的落點可以由擊球點控制 (打在拍緣斜得多、太偏就出界), 也保證弧線一定會落到那一點
--   死球判定 (owner = 最後擊球方, bounced = 已經在接球方半場彈過):
--     擊球方失誤 (接球方得分): 撞網、撞到桌緣、第一次落地不在對方半場或出界、沒落地就飛過接球方的擊球面
--     接球方失誤 (擊球方得分): 球拍沒碰到、在自己半場彈第二次、球掉到地板
--   發球簡化成和擊球一樣直接打到對方半場 (真正的規則要先彈自己這邊)
--   BTNC、得分方發球、enable 凍結都和 pong2d_ctrl 相同
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.pong_pkg.all;

entity pong3d_ctrl is
    Port ( CLK      : in  STD_LOGIC;
           RST      : in  STD_LOGIC;
           tick     : in  STD_LOGIC;
           enable   : in  STD_LOGIC;
           hard     : in  STD_LOGIC;
           ctrl     : in  ctrl_type;
           ball_x   : out signed (11 downto 0);                    -- 球心 (世界座標)
           ball_y   : out signed (11 downto 0);
           ball_z   : out unsigned (9 downto 0);
           pad_x    : out signed (11 downto 0);                    -- 玩家球拍中心
           pad_y    : out signed (11 downto 0);
           cpu_x    : out signed (11 downto 0);                    -- 電腦球拍中心
           cpu_y    : out signed (11 downto 0);
           ball_on  : out STD_LOGIC;
           score_p  : out unsigned (2 downto 0);
           score_c  : out unsigned (2 downto 0);
           p_scored : out STD_LOGIC;                               -- 最近一分是玩家得的
           gphase   : out gphase_type;
           paused   : out STD_LOGIC;
           blink    : out STD_LOGIC);
end pong3d_ctrl;

architecture Behavioral of pong3d_ctrl is
    constant SPD0       : integer := 6;
    constant SPD_MAX    : integer := 20;
    constant G          : integer := GRAV;
    constant SERVE_WAIT : integer := 50;
    constant POINT_WAIT : integer := 60;
    -- 發球後這段時間 BTNC 不算暫停: 電腦發球的同時按 BTNC 想發球, 不該一開球就停住
    constant PAUSE_GUARD : integer := 15;
    constant SERVE_GAP  : integer := 32;                           -- 發球前球在球拍前多遠
    constant Z_LAND_P   : integer := 740;                          -- 玩家回球的基本落點深度
    constant HIT_R2     : integer := (PAD_R + RB) * (PAD_R + RB);  -- 球心離拍心這麼近都算接到

    -- 速度級: 擊球到落地要飛幾個 frame; 玩家每回一球升一級, 得分後回到 0
    type lvl_table is array (0 to 7) of integer;
    -- 最快那級也要飛 30 個 frame: 再快弧線太平, 從低處回球幾乎都會掛網
    constant T_FLY : lvl_table := (48, 45, 42, 39, 36, 34, 32, 30);

    function make_recip return lvl_table is
        variable r : lvl_table;
    begin
        for i in 0 to 7 loop
            r(i) := (4096 + T_FLY(i) / 2) / T_FLY(i);
        end loop;
        return r;
    end function;

    -- ph3 是 by += vy 之後才 vy += G, T 步共多落 G T (T - 1) / 2, 起始 vy 要先扣掉平均值 G (T - 1) / 2
    function make_gcomp return lvl_table is
        variable r : lvl_table;
    begin
        for i in 0 to 7 loop
            r(i) := G * (T_FLY(i) - 1) / 2;
        end loop;
        return r;
    end function;

    constant RECIP : lvl_table := make_recip;
    constant GCOMP : lvl_table := make_gcomp;

    -- Q.4 的比較值
    constant TLQ    : signed (15 downto 0) := to_signed((TBL_Y - RB) * 16, 16);     -- 球碰到桌面時的球心高度
    constant NETTQ  : signed (15 downto 0) := to_signed((TBL_Y - NET_H - RB) * 16, 16);
    constant FLOORQ : signed (15 downto 0) := to_signed((FLOOR_Y - RB) * 16, 16);
    constant TWQ    : signed (15 downto 0) := to_signed(TW * 16, 16);
    constant NETXQ  : signed (15 downto 0) := to_signed(NET_HW * 16, 16);
    constant ZT0Q   : signed (15 downto 0) := to_signed(Z_T0 * 16, 16);
    constant ZT1Q   : signed (15 downto 0) := to_signed(Z_T1 * 16, 16);
    constant NETQ   : signed (15 downto 0) := to_signed(Z_NET * 16, 16);
    constant ZF     : signed (15 downto 0) := to_signed(Z_FAR * 16, 16);
    constant XMAX   : signed (11 downto 0) := to_signed(PXMAX, 12);
    constant YMIN   : signed (11 downto 0) := to_signed(PYMIN, 12);
    constant YMAX   : signed (11 downto 0) := to_signed(PYMAX, 12);

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
    signal go          : STD_LOGIC;
    signal serving     : STD_LOGIC;
    signal server_p    : STD_LOGIC;                                -- 下一球由玩家發 (= 最近一分是玩家得的)
    signal score_p_r   : unsigned (2 downto 0);
    signal score_c_r   : unsigned (2 downto 0);

    signal mv_up, mv_dn  : STD_LOGIC;
    signal mv_lt, mv_rt  : STD_LOGIC;
    signal spd         : unsigned (4 downto 0);
    signal px, py      : signed (11 downto 0);
    signal dpx, dpy    : signed (11 downto 0);                     -- 這一步球拍移了多少

    signal track       : STD_LOGIC;                                -- 電腦正在追球
    signal lead_x      : signed (11 downto 0);
    signal lead_y      : signed (11 downto 0);
    signal tgt_x       : signed (11 downto 0);
    signal tgt_y       : signed (11 downto 0);
    signal err_x       : signed (11 downto 0);
    signal err_y       : signed (11 downto 0);
    signal cstep       : signed (11 downto 0);
    signal cx, cy      : signed (11 downto 0);

    signal bx, by, bz  : signed (15 downto 0);
    signal vx, vy, vz  : signed (11 downto 0);
    signal bx_i, by_i  : signed (11 downto 0);
    signal owner       : STD_LOGIC;                                -- 最後擊球的是玩家
    signal bounced     : STD_LOGIC;                                -- 已經在接球方半場彈過
    signal lvl         : unsigned (2 downto 0);
    signal land_x      : signed (11 downto 0);                     -- 這一球的落點
    signal land_z      : signed (11 downto 0);
    signal launch      : STD_LOGIC;                                -- ph6 要依落點重算速度
    signal pt_end      : STD_LOGIC;                                -- 這一步成了死球
    signal pt_p        : STD_LOGIC;                                -- 這一分給玩家

    -- ph4
    signal by_prev     : signed (15 downto 0);
    signal bz_prev     : signed (15 downto 0);
    signal cross_tbl   : STD_LOGIC;                                -- 這一步往下穿過桌面高度
    signal on_tbl      : STD_LOGIC;
    signal rcv_half    : STD_LOGIC;                                -- 球在接球方的半場
    signal net_hit     : STD_LOGIC;
    signal bounce_ok   : STD_LOGIC;
    signal dead4       : STD_LOGIC;
    signal pwin4       : STD_LOGIC;

    -- ph5
    signal offp_x      : signed (11 downto 0);                     -- 球心相對玩家拍心
    signal offp_y      : signed (11 downto 0);
    signal offc_x      : signed (11 downto 0);
    signal offc_y      : signed (11 downto 0);
    signal reach_p     : STD_LOGIC;
    signal reach_c     : STD_LOGIC;
    signal at_near     : STD_LOGIC;                                -- 球飛過了玩家的擊球面
    signal at_far      : STD_LOGIC;
    signal hit_p       : STD_LOGIC;
    signal hit_c       : STD_LOGIC;
    signal dead5       : STD_LOGIC;
    signal pwin5       : STD_LOGIC;
    signal rand_x      : signed (11 downto 0);                     -- 電腦的落點
    signal rand_z      : signed (11 downto 0);
    signal plx_hit     : signed (11 downto 0);                     -- 玩家回球的落點
    signal plz_hit     : signed (11 downto 0);

    -- ph6
    signal recip_l     : signed (8 downto 0);
    signal dvx, dvy, dvz : signed (16 downto 0);                   -- 到落點的距離 (Q.4)

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

    -- d / T: d 乘上 RECIP = 4096 / T 再右移 12 位
    function per_frame(d : signed (16 downto 0); r : signed (8 downto 0)) return signed is
        variable p : signed (25 downto 0);
    begin
        p := d * r;
        return resize(shift_right(p, 12), 12);
    end function;

    function sq(v : signed (11 downto 0)) return unsigned is
    begin
        return unsigned(v * v);
    end function;
begin
    ---------------------------------------------------------------- 步驟計數與輸入 (同 pong2d_ctrl)
    ph_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ph <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if tick = '1' and enable = '1' then
                    ph <= "001";
                elsif ph /= 0 then
                    ph <= ph + 1;
                end if;
            end if;
        end process;

    s1 <= '1' when ph = 1 else '0';
    s2 <= '1' when ph = 2 else '0';
    s3 <= '1' when ph = 3 else '0';
    s4 <= '1' when ph = 4 else '0';
    s5 <= '1' when ph = 5 else '0';
    s6 <= '1' when ph = 6 else '0';

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

    lfsr_reg: process(CLK, RST)
        begin
            if RST = '0' then
                lfsr <= x"5EED";
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
    go      <= '1' when gph = GP_PLAY and paused_r = '0' else '0';
    serving <= '1' when gph = GP_SERVE else '0';

    gph_next_comb: process(gph, server_p, press_c, wcnt, go, pt_end, score_p_r, score_c_r)
        begin
            gph_next <= gph;
            case gph is
                when GP_SERVE =>
                    if (server_p = '1' and press_c = '1') or (server_p = '0' and wcnt >= SERVE_WAIT) then
                        gph_next <= GP_PLAY;
                    end if;
                when GP_PLAY =>
                    if go = '1' and pt_end = '1' then
                        gph_next <= GP_POINT;
                    end if;
                when GP_POINT =>
                    if wcnt >= POINT_WAIT then
                        if score_p_r = WIN or score_c_r = WIN then
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

    server_reg: process(CLK, RST)
        begin
            if RST = '0' then
                server_p <= '1';
            elsif CLK'event and CLK = '1' then
                if s6 = '1' and go = '1' and pt_end = '1' then
                    server_p <= pt_p;
                end if;
            end if;
        end process;

    score_p_reg: process(CLK, RST)
        begin
            if RST = '0' then
                score_p_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s6 = '1' then
                    if go = '1' and pt_end = '1' and pt_p = '1' then
                        score_p_r <= score_p_r + 1;
                    elsif gph = GP_OVER and press_c = '1' then
                        score_p_r <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    score_c_reg: process(CLK, RST)
        begin
            if RST = '0' then
                score_c_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s6 = '1' then
                    if go = '1' and pt_end = '1' and pt_p = '0' then
                        score_c_r <= score_c_r + 1;
                    elsif gph = GP_OVER and press_c = '1' then
                        score_c_r <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- 玩家球拍
    mv_up <= ctrl_q(K_UP) and not ctrl_q(K_DN);
    mv_dn <= ctrl_q(K_DN) and not ctrl_q(K_UP);
    mv_lt <= ctrl_q(K_LT) and not ctrl_q(K_RT);
    mv_rt <= ctrl_q(K_RT) and not ctrl_q(K_LT);

    spd_reg: process(CLK, RST)
        begin
            if RST = '0' then
                spd <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s1 = '1' then
                    if (mv_up or mv_dn or mv_lt or mv_rt) = '0' then
                        spd <= (others => '0');
                    elsif spd < SPD0 then
                        spd <= to_unsigned(SPD0, 5);
                    elsif spd < SPD_MAX then
                        spd <= spd + 1;
                    end if;
                end if;
            end if;
        end process;

    dpx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dpx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s2 = '1' then
                    if paused_r = '1' then
                        dpx <= (others => '0');
                    elsif mv_lt = '1' then
                        dpx <= clamp(px - signed('0' & spd), -XMAX, XMAX) - px;
                    elsif mv_rt = '1' then
                        dpx <= clamp(px + signed('0' & spd), -XMAX, XMAX) - px;
                    else
                        dpx <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    dpy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dpy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s2 = '1' then
                    if paused_r = '1' then
                        dpy <= (others => '0');
                    elsif mv_up = '1' then
                        dpy <= clamp(py - signed('0' & spd), YMIN, YMAX) - py;
                    elsif mv_dn = '1' then
                        dpy <= clamp(py + signed('0' & spd), YMIN, YMAX) - py;
                    else
                        dpy <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    -- dpx / dpy 在 ph2 算好, ph3 才加上去, 兩者一定一致
    px_reg: process(CLK, RST)
        begin
            if RST = '0' then
                px <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    px <= px + dpx;
                end if;
            end if;
        end process;

    py_reg: process(CLK, RST)
        begin
            if RST = '0' then
                py <= to_signed(PY_HOME, 12);
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    py <= py + dpy;
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- 電腦球拍
    -- 球朝它來才追, 其餘時間回到中間待命; 難度差在移動速度 (cstep) 和回球的角度 (rand_x)
    --   高度: 球落地前高高低低, 跟著跑只會白忙, 所以彈起來之後才追; 追的是 8 個 frame 後的位置
    track   <= '1' when gph = GP_PLAY and owner = '1' else '0';
    lead_x  <= bx_i + shift_right(vx, 1);                          -- vx 是 Q.4, 8 frame = vx / 2
    lead_y  <= by_i + shift_right(vy, 1);

    tgt_x_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tgt_x <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s1 = '1' then
                    if track = '1' then
                        tgt_x <= lead_x;
                    else
                        tgt_x <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    tgt_y_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tgt_y <= to_signed(PY_HOME, 12);
            elsif CLK'event and CLK = '1' then
                if s1 = '1' then
                    if track = '1' and bounced = '1' then
                        tgt_y <= lead_y;
                    else
                        tgt_y <= to_signed(PY_HOME, 12);
                    end if;
                end if;
            end if;
        end process;

    err_x <= tgt_x - cx;
    err_y <= tgt_y - cy;
    cstep <= to_signed(9, 12) when hard = '1' else to_signed(6, 12);

    cx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s2 = '1' and paused_r = '0' then
                    cx <= chase(cx, err_x, cstep, to_signed(4, 12), -XMAX, XMAX);
                end if;
            end if;
        end process;

    cy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cy <= to_signed(PY_HOME, 12);
            elsif CLK'event and CLK = '1' then
                if s2 = '1' and paused_r = '0' then
                    cy <= chase(cy, err_y, cstep, to_signed(4, 12), YMIN, YMAX);
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- ph4: 網子與桌面
    bx_i <= bx(15 downto 4);
    by_i <= by(15 downto 4);

    -- ph3 先 by += vy 再 vy += G, 所以上一步的 by = by - (vy - G)
    by_prev   <= by - vy + G;
    bz_prev   <= bz - vz;
    cross_tbl <= '1' when by >= TLQ and by_prev < TLQ else '0';
    on_tbl    <= '1' when abs(bx) <= TWQ and bz >= ZT0Q and bz <= ZT1Q else '0';
    rcv_half  <= '1' when (owner = '1' and bz >= NETQ) or (owner = '0' and bz < NETQ) else '0';
    net_hit   <= '1' when ((bz_prev < NETQ) xor (bz < NETQ)) and by > NETTQ and abs(bx) <= NETXQ else '0';
    bounce_ok <= cross_tbl and on_tbl and rcv_half and not bounced and not net_hit;

    -- 死球與得分方: 擊球方失誤 -> 接球方 (not owner) 得分; 接球方失誤 -> 擊球方 (owner) 得分
    --   球在桌面以下又在桌子範圍內: 落在擊球方自己那邊、兩跳, 或從桌緣底下撞進桌子
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
    offp_x  <= bx_i - px;
    offp_y  <= by_i - py;
    offc_x  <= bx_i - cx;
    offc_y  <= by_i - cy;
    reach_p <= '1' when sq(offp_x) + sq(offp_y) <= HIT_R2 else '0';
    reach_c <= '1' when sq(offc_x) + sq(offc_y) <= HIT_R2 else '0';

    at_far  <= '1' when owner = '1' and bz > ZF else '0';
    at_near <= '1' when owner = '0' and bz < 0 else '0';
    hit_p   <= at_near and bounced and reach_p;
    hit_c   <= at_far and bounced and reach_c;
    -- 沒彈過就到了: 球太長, 擊球方失誤; 彈過但沒碰到拍: 擊球方得分
    dead5   <= (at_near or at_far) and not (hit_p or hit_c);
    pwin5   <= owner when bounced = '1' else not owner;

    -- 電腦: 簡單模式打中間一帶 (+-160), 困難模式打到邊線附近 (+-224, 不會出界)
    rand_x <= resize(signed(lfsr(7 downto 0)), 12) + shift_right(resize(signed(lfsr(7 downto 0)), 12), 1)
              + shift_right(resize(signed(lfsr(7 downto 0)), 12), 2) when hard = '1'    -- 1.75 x (-128 .. 127)
              else resize(signed(lfsr(7 downto 0)), 12) + shift_right(resize(signed(lfsr(7 downto 0)), 12), 2);
    rand_z <= to_signed(180, 12) + signed(resize(unsigned(lfsr(15 downto 8)), 12)) when hard = '1'
              else to_signed(236, 12) + signed(resize(unsigned(lfsr(14 downto 8)), 12));

    -- 玩家: 擊球點每偏 1 像素落點橫移 3; 球拍的速度也帶過去; 打在拍子上半部球比較長
    plx_hit <= offp_x + shift_left(offp_x, 1) + shift_left(dpx, 2);
    plz_hit <= Z_LAND_P - shift_left(offp_y, 1) - shift_right(offp_y, 2);

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

    pt_p_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pt_p <= '0';
            elsif CLK'event and CLK = '1' then
                if go = '1' and pt_end = '0' then
                    if s4 = '1' and dead4 = '1' then
                        pt_p <= pwin4;
                    elsif s5 = '1' and dead5 = '1' then
                        pt_p <= pwin5;
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
                        owner <= server_p;
                    elsif go = '1' and pt_end = '0' and hit_p = '1' then
                        owner <= '1';
                    elsif go = '1' and pt_end = '0' and hit_c = '1' then
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
                if s4 = '1' and go = '1' and pt_end = '0' and bounce_ok = '1' then
                    bounced <= '1';
                elsif s5 = '1' and (serving = '1' or (go = '1' and pt_end = '0' and (hit_p or hit_c) = '1')) then
                    bounced <= '0';
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
                    elsif go = '1' and pt_end = '0' and hit_p = '1' and lvl /= 7 then
                        lvl <= lvl + 1;                            -- 只有玩家回球會加速, 節奏由人決定
                    end if;
                end if;
            end if;
        end process;

    land_x_reg: process(CLK, RST)
        begin
            if RST = '0' then
                land_x <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s5 = '1' then
                    if serving = '1' then
                        if server_p = '1' then
                            land_x <= shift_right(px, 1);          -- 發球往球拍那一側打
                        else
                            land_x <= rand_x;
                        end if;
                    elsif hit_p = '1' then
                        land_x <= plx_hit;
                    elsif hit_c = '1' then
                        land_x <= rand_x;
                    end if;
                end if;
            end if;
        end process;

    land_z_reg: process(CLK, RST)
        begin
            if RST = '0' then
                land_z <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s5 = '1' then
                    if serving = '1' then
                        if server_p = '1' then
                            land_z <= to_signed(Z_LAND_P, 12);
                        else
                            land_z <= rand_z;
                        end if;
                    elsif hit_p = '1' then
                        land_z <= plz_hit;
                    elsif hit_c = '1' then
                        land_z <= rand_z;
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
                    launch <= serving or (go and not pt_end and (hit_p or hit_c));
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- 球
    bx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    if serving = '1' then
                        if server_p = '1' then
                            bx <= (px + dpx) & "0000";             -- px 在這一拍才加上 dpx
                        else
                            bx <= cx & "0000";
                        end if;
                    elsif go = '1' then
                        bx <= bx + vx;
                    end if;
                end if;
            end if;
        end process;

    by_reg: process(CLK, RST)
        begin
            if RST = '0' then
                by <= to_signed(PY_HOME * 16, 16);
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    if serving = '1' then
                        if server_p = '1' then
                            by <= (py + dpy) & "0000";
                        else
                            by <= cy & "0000";
                        end if;
                    elsif go = '1' then
                        by <= by + vy;
                    end if;
                elsif s4 = '1' and go = '1' and pt_end = '0' and bounce_ok = '1' then
                    by <= TLQ + TLQ - by;                          -- 鏡射回桌面上方
                end if;
            end if;
        end process;

    bz_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bz <= to_signed(SERVE_GAP * 16, 16);
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    if serving = '1' then
                        if server_p = '1' then
                            bz <= to_signed(SERVE_GAP * 16, 16);
                        else
                            bz <= ZF - SERVE_GAP * 16;
                        end if;
                    elsif go = '1' then
                        bz <= bz + vz;
                    end if;
                elsif s5 = '1' and go = '1' then
                    -- 回擊從擊球面出發; 死球也停在那一面上, 得分的停頓期間看得到它從哪裡漏掉
                    if bz < 0 then
                        bz <= (others => '0');
                    elsif bz > ZF then
                        bz <= ZF;
                    end if;
                end if;
            end if;
        end process;

    recip_l <= to_signed(RECIP(to_integer(lvl)), 9);
    dvx     <= resize(land_x & "0000", 17) - bx;
    dvy     <= resize(TLQ, 17) - by;
    dvz     <= resize(land_z & "0000", 17) - bz;

    vx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s6 = '1' and launch = '1' then
                    vx <= per_frame(dvx, recip_l);
                end if;
            end if;
        end process;

    vy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s3 = '1' and go = '1' then
                    vy <= vy + G;
                elsif s4 = '1' and go = '1' and pt_end = '0' and bounce_ok = '1' then
                    vy <= shift_right(vy, 3) - vy;                 -- 反彈只剩 7/8
                elsif s6 = '1' and launch = '1' then
                    vy <= per_frame(dvy, recip_l) - GCOMP(to_integer(lvl));
                end if;
            end if;
        end process;

    vz_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vz <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s6 = '1' and launch = '1' then
                    vz <= per_frame(dvz, recip_l);
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- 輸出
    ball_x   <= bx_i;
    ball_y   <= by_i;
    ball_z   <= unsigned(bz(13 downto 4));                         -- ph5 之後一定在 0 .. Z_FAR
    pad_x    <= px;
    pad_y    <= py;
    cpu_x    <= cx;
    cpu_y    <= cy;
    ball_on  <= '0' when gph = GP_OVER else '1';
    score_p  <= score_p_r;
    score_c  <= score_c_r;
    p_scored <= server_p;
    gphase   <= gph;
    paused   <= paused_r;
    blink    <= fcnt(4);
end Behavioral;
