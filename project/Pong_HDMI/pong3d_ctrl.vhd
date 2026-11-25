----------------------------------------------------------------------------------
-- Module Name: pong3d_ctrl - Behavioral
-- Description: 3D 隧道乒乓的規則與物理: 玩家在隧道口 (Z = 0) 對電腦 (Z = Z_FAR), 先得 7 分獲勝
--   世界座標 (見 pong_pkg): X 向右 +-T_HW, Y 向下 +-T_HH, Z 往隧道裡; 球的位置、速度是 Q.4
--   和 pong2d_ctrl 一樣, 每次 tick 用 ph = 1..7 依序算完一步, 畫面掃描時狀態都不變:
--     ph1 球拍速度、電腦的目標
--     ph2 球拍移動 (順便記下這一步移了多少, 擊球時把球拍的速度帶給球)
--     ph3 球前進 (發球前球黏在發球方的球拍前)
--     ph4 四面牆反彈 (鏡射)
--     ph5 球到了 Z = 0 或 Z_FAR 那一面: 碰得到球拍就反彈, Z 也鏡射回來
--     ph6 碰不到的話球停在那一面, 對方得分; 階段切換
--   擊球後的橫向速度 = 擊球點離球拍中心多遠 (打在拍緣斜得最多) + 球拍正在移動的速度,
--     所以可以「搓」球, 讓它斜飛撞牆; 玩家每次回球 |vz| 都會加快
--   電腦: 球朝它來才追 (簡單模式等球過半), 每 frame 最多移 STEP 像素, 斜線快球會追不上
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
    constant VZ0        : integer := 10 * 16;                      -- 發球: 約 1.7 秒到底
    constant ACCZ       : integer := 12;
    constant VZMAX      : integer := 25 * 16;                      -- 最快約 0.7 秒到底
    constant VLAT       : integer := 16 * 16;                      -- 橫向速度上限
    constant SERVE_WAIT : integer := 50;
    constant POINT_WAIT : integer := 60;
    -- 發球後這段時間 BTNC 不算暫停: 電腦發球的同時按 BTNC 想發球, 不該一開球就停住
    constant PAUSE_GUARD : integer := 15;
    constant SERVE_GAP  : integer := 32;                           -- 發球前球在球拍前多遠
    constant REACH_X    : integer := P3_HW + RB / 2;               -- 球心離球拍中心這麼近都算接到
    constant REACH_Y    : integer := P3_HH + RB / 2;

    constant BXMAX  : signed (15 downto 0) := to_signed((T_HW - RB) * 16, 16);
    constant BYMAX  : signed (15 downto 0) := to_signed((T_HH - RB) * 16, 16);
    constant ZF     : signed (15 downto 0) := to_signed(Z_FAR * 16, 16);
    constant PXMAX  : signed (11 downto 0) := to_signed(T_HW - P3_HW, 12);
    constant PYMAX  : signed (11 downto 0) := to_signed(T_HH - P3_HH, 12);

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
    signal server_p    : STD_LOGIC;                                -- 下一球由玩家發 (= 最近一分是玩家得的)
    signal score_p_r   : unsigned (2 downto 0);
    signal score_c_r   : unsigned (2 downto 0);

    signal mv_up, mv_dn  : STD_LOGIC;
    signal mv_lt, mv_rt  : STD_LOGIC;
    signal spd         : unsigned (4 downto 0);
    signal px, py      : signed (11 downto 0);
    signal dpx, dpy    : signed (11 downto 0);                     -- 這一步球拍移了多少

    signal aim_x       : signed (11 downto 0);
    signal aim_y       : signed (11 downto 0);
    signal tgt_x       : signed (11 downto 0);
    signal tgt_y       : signed (11 downto 0);
    signal err_x       : signed (11 downto 0);
    signal err_y       : signed (11 downto 0);
    signal cstep       : signed (11 downto 0);
    signal cx, cy      : signed (11 downto 0);

    signal bx, by, bz  : signed (15 downto 0);
    signal vx, vy, vz  : signed (11 downto 0);
    signal bx_i, by_i  : signed (11 downto 0);
    signal offp_x      : signed (11 downto 0);                     -- 球心相對玩家球拍中心
    signal offp_y      : signed (11 downto 0);
    signal offc_x      : signed (11 downto 0);                     -- 球心相對電腦球拍中心
    signal offc_y      : signed (11 downto 0);
    signal at_near     : STD_LOGIC;                                -- 這一步球到了 Z = 0 那一面
    signal at_far      : STD_LOGIC;
    signal hit_p       : STD_LOGIC;
    signal hit_c       : STD_LOGIC;
    signal miss_p      : STD_LOGIC;                                -- 玩家沒接到 = 電腦得分
    signal miss_c      : STD_LOGIC;
    signal vz_fast     : signed (11 downto 0);
    signal spin_px     : signed (11 downto 0);                     -- 玩家擊球後的橫向速度
    signal spin_py     : signed (11 downto 0);
    signal spin_cx     : signed (11 downto 0);
    signal spin_cy     : signed (11 downto 0);

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
    function chase(pos, err, step, dz, lim : signed) return signed is
    begin
        if err > dz then
            if err > step then
                return clamp(pos + step, -lim, lim);
            end if;
            return clamp(pos + err, -lim, lim);
        elsif err < -dz then
            if err < -step then
                return clamp(pos - step, -lim, lim);
            end if;
            return clamp(pos + err, -lim, lim);
        end if;
        return pos;
    end function;

    -- 擊球點偏 1 像素 -> 橫向 1.5/16 像素 / frame, 再加上球拍速度的 1/4, 最後限制在 +-VLAT
    function spin(off, pad_v : signed) return signed is
        variable v : signed (13 downto 0);
    begin
        v := resize(off, 14) + shift_right(resize(off, 14), 1) + shift_left(resize(pad_v, 14), 2);
        if v > VLAT then
            return to_signed(VLAT, 12);
        elsif v < -VLAT then
            return to_signed(-VLAT, 12);
        end if;
        return resize(v, 12);
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
    go <= '1' when gph = GP_PLAY and paused_r = '0' else '0';

    gph_next_comb: process(gph, server_p, press_c, wcnt, go, miss_p, miss_c, score_p_r, score_c_r)
        begin
            gph_next <= gph;
            case gph is
                when GP_SERVE =>
                    if (server_p = '1' and press_c = '1') or (server_p = '0' and wcnt >= SERVE_WAIT) then
                        gph_next <= GP_PLAY;
                    end if;
                when GP_PLAY =>
                    if go = '1' and (miss_p = '1' or miss_c = '1') then
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
                if s6 = '1' and go = '1' then
                    if miss_c = '1' then
                        server_p <= '1';
                    elsif miss_p = '1' then
                        server_p <= '0';
                    end if;
                end if;
            end if;
        end process;

    score_p_reg: process(CLK, RST)
        begin
            if RST = '0' then
                score_p_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s6 = '1' then
                    if go = '1' and miss_c = '1' then
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
                    if go = '1' and miss_p = '1' then
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
                        dpx <= clamp(px - signed('0' & spd), -PXMAX, PXMAX) - px;
                    elsif mv_rt = '1' then
                        dpx <= clamp(px + signed('0' & spd), -PXMAX, PXMAX) - px;
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
                        dpy <= clamp(py - signed('0' & spd), -PYMAX, PYMAX) - py;
                    elsif mv_dn = '1' then
                        dpy <= clamp(py + signed('0' & spd), -PYMAX, PYMAX) - py;
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
                py <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    py <= py + dpy;
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- 電腦球拍
    -- 困難模式每次玩家回球後隨機挑擊球點, 回球才有角度; 簡單模式一律用中心接
    aim_x_reg: process(CLK, RST)
        begin
            if RST = '0' then
                aim_x <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s5 = '1' and hit_p = '1' then
                    if hard = '1' then
                        aim_x <= resize(signed(lfsr(6 downto 0)), 12);    -- -64 .. 63
                    else
                        aim_x <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    aim_y_reg: process(CLK, RST)
        begin
            if RST = '0' then
                aim_y <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s5 = '1' and hit_p = '1' then
                    if hard = '1' then
                        aim_y <= resize(signed(lfsr(13 downto 8)), 12);   -- -32 .. 31
                    else
                        aim_y <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    tgt_x_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tgt_x <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s1 = '1' then
                    if gph = GP_PLAY and vz > 0 and (hard = '1' or bz > ZF / 2) then
                        tgt_x <= bx_i - aim_x;
                    else
                        tgt_x <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    tgt_y_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tgt_y <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s1 = '1' then
                    if gph = GP_PLAY and vz > 0 and (hard = '1' or bz > ZF / 2) then
                        tgt_y <= by_i - aim_y;
                    else
                        tgt_y <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    err_x <= tgt_x - cx;
    err_y <= tgt_y - cy;
    cstep <= to_signed(9, 12) when hard = '1' else to_signed(5, 12);

    cx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s2 = '1' and paused_r = '0' then
                    cx <= chase(cx, err_x, cstep, to_signed(4, 12), PXMAX);
                end if;
            end if;
        end process;

    cy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s2 = '1' and paused_r = '0' then
                    cy <= chase(cy, err_y, cstep, to_signed(4, 12), PYMAX);
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- 球
    bx_i <= bx(15 downto 4);
    by_i <= by(15 downto 4);

    offp_x <= bx_i - px;
    offp_y <= by_i - py;
    offc_x <= bx_i - cx;
    offc_y <= by_i - cy;

    at_near <= '1' when vz < 0 and bz < 0 else '0';
    at_far  <= '1' when vz > 0 and bz > ZF else '0';
    hit_p   <= '1' when at_near = '1' and abs(offp_x) <= REACH_X and abs(offp_y) <= REACH_Y else '0';
    hit_c   <= '1' when at_far = '1' and abs(offc_x) <= REACH_X and abs(offc_y) <= REACH_Y else '0';
    -- ph5 接到的球已經被鏡射回範圍內, 所以 ph6 還在面外的就是沒接到
    miss_p  <= '1' when bz < 0 else '0';
    miss_c  <= '1' when bz > ZF else '0';

    vz_fast <= abs(vz) + ACCZ when abs(vz) + ACCZ < VZMAX else to_signed(VZMAX, 12);
    spin_px <= spin(offp_x, dpx);
    spin_py <= spin(offp_y, dpy);
    spin_cx <= spin(offc_x, to_signed(0, 12));
    spin_cy <= spin(offc_y, to_signed(0, 12));

    bx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    if gph = GP_SERVE then
                        if server_p = '1' then
                            bx <= (px + dpx) & "0000";             -- px 在這一拍才加上 dpx
                        else
                            bx <= cx & "0000";
                        end if;
                    elsif go = '1' then
                        bx <= bx + vx;
                    end if;
                elsif s4 = '1' and go = '1' then
                    if bx > BXMAX then
                        bx <= BXMAX + BXMAX - bx;
                    elsif bx < -BXMAX then
                        bx <= -BXMAX - BXMAX - bx;
                    end if;
                end if;
            end if;
        end process;

    by_reg: process(CLK, RST)
        begin
            if RST = '0' then
                by <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    if gph = GP_SERVE then
                        if server_p = '1' then
                            by <= (py + dpy) & "0000";
                        else
                            by <= cy & "0000";
                        end if;
                    elsif go = '1' then
                        by <= by + vy;
                    end if;
                elsif s4 = '1' and go = '1' then
                    if by > BYMAX then
                        by <= BYMAX + BYMAX - by;
                    elsif by < -BYMAX then
                        by <= -BYMAX - BYMAX - by;
                    end if;
                end if;
            end if;
        end process;

    bz_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bz <= to_signed(SERVE_GAP * 16, 16);
            elsif CLK'event and CLK = '1' then
                if s3 = '1' then
                    if gph = GP_SERVE then
                        if server_p = '1' then
                            bz <= to_signed(SERVE_GAP * 16, 16);
                        else
                            bz <= ZF - SERVE_GAP * 16;
                        end if;
                    elsif go = '1' then
                        bz <= bz + vz;
                    end if;
                elsif s5 = '1' and go = '1' then
                    if hit_p = '1' then
                        bz <= -bz;
                    elsif hit_c = '1' then
                        bz <= ZF + ZF - bz;
                    end if;
                elsif s6 = '1' and go = '1' then
                    -- 沒接到: 球停在那一面上, 得分的停頓期間看得到它從哪裡漏掉
                    if bz < 0 then
                        bz <= (others => '0');
                    elsif bz > ZF then
                        bz <= ZF;
                    end if;
                end if;
            end if;
        end process;

    vx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s4 = '1' and go = '1' and (bx > BXMAX or bx < -BXMAX) then
                    vx <= -vx;
                elsif s5 = '1' and go = '1' then
                    if hit_p = '1' then
                        vx <= spin_px;
                    elsif hit_c = '1' then
                        vx <= spin_cx;
                    end if;
                elsif s6 = '1' and gph = GP_SERVE then
                    vx <= resize(signed(lfsr(5 downto 0)), 12);   -- 發球帶一點隨機角度
                end if;
            end if;
        end process;

    vy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s4 = '1' and go = '1' and (by > BYMAX or by < -BYMAX) then
                    vy <= -vy;
                elsif s5 = '1' and go = '1' then
                    if hit_p = '1' then
                        vy <= spin_py;
                    elsif hit_c = '1' then
                        vy <= spin_cy;
                    end if;
                elsif s6 = '1' and gph = GP_SERVE then
                    vy <= resize(signed(lfsr(11 downto 6)), 12);
                end if;
            end if;
        end process;

    vz_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vz <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if s5 = '1' and go = '1' then
                    if hit_p = '1' then
                        vz <= vz_fast;                             -- 只有玩家回球會加速, 節奏由人決定
                    elsif hit_c = '1' then
                        vz <= -abs(vz);
                    end if;
                elsif s6 = '1' then
                    if gph = GP_SERVE then
                        if server_p = '1' then
                            vz <= to_signed(VZ0, 12);
                        else
                            vz <= to_signed(-VZ0, 12);
                        end if;
                    elsif gph /= GP_PLAY or miss_p = '1' or miss_c = '1' then
                        vz <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- 輸出
    ball_x   <= bx_i;
    ball_y   <= by_i;
    ball_z   <= unsigned(bz(13 downto 4));                         -- ph6 之後一定在 0 .. Z_FAR
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
