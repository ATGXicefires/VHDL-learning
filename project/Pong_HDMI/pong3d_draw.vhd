----------------------------------------------------------------------------------
-- Module Name: pong3d_draw - Behavioral
-- Description: 3D 隧道乒乓的畫面 (第一人稱透視), 延遲 LAT_3D 拍
--   透視: 世界座標 (X, Y, Z) -> 螢幕 (512 + X s, 384 + Y s), s = SCALE(Z / 4) (見 pong_pkg)
--   每個 frame 只有球、兩支球拍的位置會變, 它們的投影在「每幀值」那一段算好 (狀態只在遮沒期間改,
--     那幾級暫存器早就穩定了); 掃描像素時只做比較, 不用除法
--   隧道四面牆: 像素 (dx, dy) = (x - 512, y - 384); 3|dx| > 4|dy| 是左右牆, 否則是天花板 / 地板
--     (隧道截面 1024 x 768 = 4 : 3, 對角線就是牆角); 越深 max(3|dx|, 4|dy|) 越小, 拿來做霧化明暗
--   牆上的線都不用除法:
--     沿著隧道的縱線: 地板上 X 固定的線過消失點, 3|dx| = k |dy| (k = 0..3 對應 X = 0, 128, 256, 384)
--                    側牆上 Y 固定的線, 4|dy| = n |dx| (n = 0..2 對應 Y = 0, 128, 256)
--     橫圈: 固定深度的矩形, 半寬 / 半高是常數 RING_HW / RING_HH
--     球所在深度的綠色圈 (深度框) 和地板上的影子, 讓人判斷球有多遠
--   畫的順序 (前面的蓋後面的): 比分 > 玩家球拍框 > 玩家球拍半透明面 > 球 > 影子 > 電腦球拍 > 隧道底 >
--     深度框 > 格線 > 牆; 得分時隧道口外圈閃紅 (電腦得分) 或綠 (玩家得分)
--   管線: P1 相對座標與矩形比較, P2 絕對值、平方、數字, P3 區域 / 線 / 球的判斷, P4 選顏色, P5 疊上玩家球拍
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.vga_pkg.all;
use work.pong_pkg.all;

entity pong3d_draw is
    Port ( CLK      : in  STD_LOGIC;
           RST      : in  STD_LOGIC;
           x        : in  coord_type;
           y        : in  coord_type;
           ball_x   : in  signed (11 downto 0);
           ball_y   : in  signed (11 downto 0);
           ball_z   : in  unsigned (9 downto 0);
           pad_x    : in  signed (11 downto 0);
           pad_y    : in  signed (11 downto 0);
           cpu_x    : in  signed (11 downto 0);
           cpu_y    : in  signed (11 downto 0);
           ball_on  : in  STD_LOGIC;
           score_p  : in  unsigned (2 downto 0);
           score_c  : in  unsigned (2 downto 0);
           p_scored : in  STD_LOGIC;
           gphase   : in  gphase_type;
           paused   : in  STD_LOGIC;
           blink    : in  STD_LOGIC;
           rgb      : out rgb_type);
end pong3d_draw;

architecture Behavioral of pong3d_draw is
    constant CX0   : integer := SCR_W / 2;
    constant CY0   : integer := SCR_H / 2;
    constant DIG_W : integer := 32;
    constant DIG_H : integer := 56;
    constant SEG_T : integer := 8;
    constant DIG_Y : integer := 20;
    constant DL_X  : integer := 24;
    constant DR_X  : integer := SCR_W - 24 - DIG_W;
    constant PAD_B : integer := 4;                                 -- 玩家球拍外框粗細
    constant CPU_B : integer := 2;
    constant EDGE_W : integer := 16;                               -- 得分時閃爍的外圈寬度

    constant C_FLOOR : rgb_type := x"246";
    constant C_CEIL  : rgb_type := x"134";
    constant C_SIDE  : rgb_type := x"135";
    constant C_GRID  : rgb_type := x"0DF";
    constant C_BACK  : rgb_type := x"001";
    constant C_DEPTH : rgb_type := x"5F5";
    constant C_SHAD  : rgb_type := x"000";
    constant C_CPU_E : rgb_type := x"F55";
    constant C_CPU_F : rgb_type := x"A22";
    constant C_PAD   : rgb_type := x"8DF";
    constant C_LOST  : rgb_type := x"F22";
    constant C_WON   : rgb_type := x"2F4";
    type ball_colors is array (0 to 3) of rgb_type;
    constant C_BALL  : ball_colors := (x"FFF", x"FEA", x"EB5", x"A72");    -- 高光 -> 邊緣

    -- 區域編碼
    constant R_CEIL  : STD_LOGIC_VECTOR (1 downto 0) := "00";
    constant R_FLOOR : STD_LOGIC_VECTOR (1 downto 0) := "01";
    constant R_LEFT  : STD_LOGIC_VECTOR (1 downto 0) := "10";
    constant R_RIGHT : STD_LOGIC_VECTOR (1 downto 0) := "11";

    -- 依深度調暗: 最近 (lvl = 12) 原色, 最遠 (lvl = 3) 約 0.44 倍
    function shade(c : rgb_type; lvl : unsigned (3 downto 0)) return rgb_type is
        variable o : rgb_type;
        variable v : unsigned (8 downto 0);
    begin
        for i in 0 to 2 loop
            v := unsigned(c(4 * i + 3 downto 4 * i)) * ('0' & lvl + 4);
            if v(8) = '1' then
                o(4 * i + 3 downto 4 * i) := "1111";
            else
                o(4 * i + 3 downto 4 * i) := STD_LOGIC_VECTOR(v(7 downto 4));
            end if;
        end loop;
        return o;
    end function;

    -- 各色 (a + b) / 2: 半透明
    function blend(a, b : rgb_type) return rgb_type is
        variable o : rgb_type;
        variable v : unsigned (4 downto 0);
    begin
        for i in 0 to 2 loop
            v := ('0' & unsigned(a(4 * i + 3 downto 4 * i))) + unsigned(b(4 * i + 3 downto 4 * i));
            o(4 * i + 3 downto 4 * i) := STD_LOGIC_VECTOR(v(4 downto 1));
        end loop;
        return o;
    end function;

    function proj(w : signed (11 downto 0); s : integer) return signed is
    begin
        return resize(shift_right(w * to_signed(s, 12), 10), 12);
    end function;

    ---------------------------------------------------------------- 每幀值
    signal sb          : unsigned (10 downto 0);                   -- 球所在深度的縮放 (Q.10)
    signal mbx, mby    : signed (23 downto 0);
    signal rb_m        : unsigned (16 downto 0);
    signal bsx, bsy    : signed (11 downto 0);                     -- 球心 (螢幕)
    signal br          : unsigned (6 downto 0);                    -- 球半徑 (螢幕)
    signal wb, hb      : unsigned (10 downto 0);                   -- 球所在深度的隧道半寬 / 半高
    signal shy         : signed (11 downto 0);                     -- 影子中心 y
    signal hl          : signed (11 downto 0);                     -- 高光點離球心的距離
    signal br2         : unsigned (13 downto 0);
    signal t_hi        : unsigned (13 downto 0);                   -- 明暗分界 (距高光點的平方)
    signal t_mid       : unsigned (13 downto 0);
    signal t_lo        : unsigned (14 downto 0);
    signal ppl, ppr    : signed (11 downto 0);                     -- 玩家球拍 (螢幕)
    signal ppt, ppb    : signed (11 downto 0);
    signal cpl, cpr    : signed (11 downto 0);                     -- 電腦球拍 (螢幕)
    signal cpt, cpb    : signed (11 downto 0);

    ---------------------------------------------------------------- 像素管線
    signal px, py      : signed (11 downto 0);
    signal pp_in       : STD_LOGIC;
    signal pp_core     : STD_LOGIC;

    -- P1
    signal dx1, dy1    : signed (11 downto 0);
    signal bdx1, bdy1  : signed (11 downto 0);
    signal hdx1, hdy1  : signed (11 downto 0);
    signal sdy1        : signed (11 downto 0);
    signal sxl1, sxr1  : unsigned (10 downto 0);
    signal sy1         : unsigned (10 downto 0);
    signal ovl1        : STD_LOGIC_VECTOR (3 downto 0);            -- 玩家框, 玩家面, 電腦框, 電腦面

    -- P2
    signal adx2, ady2  : unsigned (10 downto 0);
    signal sgn2        : STD_LOGIC_VECTOR (1 downto 0);            -- dx < 0, dy < 0
    signal bd2         : unsigned (23 downto 0);
    signal hd2         : unsigned (23 downto 0);
    signal sd2         : unsigned (27 downto 0);
    signal dig2        : STD_LOGIC_VECTOR (1 downto 0);
    signal ovl2        : STD_LOGIC_VECTOR (3 downto 0);

    -- P3
    signal a3, a4      : unsigned (12 downto 0);
    signal side        : STD_LOGIC;
    signal grid_f      : STD_LOGIC;
    signal grid_s      : STD_LOGIC;
    signal ring_f      : STD_LOGIC;
    signal ring_s      : STD_LOGIC;
    signal region3     : STD_LOGIC_VECTOR (1 downto 0);
    signal lvl3        : unsigned (3 downto 0);
    signal f3          : STD_LOGIC_VECTOR (6 downto 0);            -- 見下面 F3_*
    signal bl3         : unsigned (1 downto 0);                    -- 球的明暗級
    signal dig3        : STD_LOGIC_VECTOR (1 downto 0);
    signal ovl3        : STD_LOGIC_VECTOR (3 downto 0);
    constant F3_BACK   : integer := 0;
    constant F3_GRID   : integer := 1;
    constant F3_DEPTH  : integer := 2;
    constant F3_BALL   : integer := 3;
    constant F3_SHAD   : integer := 4;
    constant F3_EDGE   : integer := 5;                             -- 隧道口外圈 (得分閃爍)
    constant F3_CPU    : integer := 6;                             -- 在電腦球拍的面裡 (框另外看 ovl)

    -- P4
    signal show_b      : STD_LOGIC;
    signal flash       : STD_LOGIC;
    signal base4       : rgb_type;
    signal dig4        : STD_LOGIC_VECTOR (1 downto 0);
    signal ovl4        : STD_LOGIC_VECTOR (1 downto 0);
    signal win_p, win_c : STD_LOGIC;

    -- P5
    signal rgb_r       : rgb_type;
begin
    ---------------------------------------------------------------- 每幀值 (狀態只在遮沒期間變)
    sb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sb <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sb <= to_unsigned(SCALE(to_integer(ball_z(9 downto 2))), 11);
            end if;
        end process;

    mbx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                mbx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                mbx <= ball_x * signed('0' & sb);
            end if;
        end process;

    mby_reg: process(CLK, RST)
        begin
            if RST = '0' then
                mby <= (others => '0');
            elsif CLK'event and CLK = '1' then
                mby <= ball_y * signed('0' & sb);
            end if;
        end process;

    rb_m_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rb_m <= (others => '0');
            elsif CLK'event and CLK = '1' then
                rb_m <= resize(sb * to_unsigned(RB, 6), 17);
            end if;
        end process;

    bsx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bsx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                bsx <= CX0 + resize(shift_right(mbx, 10), 12);
            end if;
        end process;

    bsy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bsy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                bsy <= CY0 + resize(shift_right(mby, 10), 12);
            end if;
        end process;

    br_reg: process(CLK, RST)
        begin
            if RST = '0' then
                br <= (others => '0');
            elsif CLK'event and CLK = '1' then
                br <= rb_m(16 downto 10);
            end if;
        end process;

    -- 隧道半寬 512 s = s / 2, 半高 384 s = 3 s / 8
    wb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                wb <= (others => '0');
            elsif CLK'event and CLK = '1' then
                wb <= shift_right(sb, 1);
            end if;
        end process;

    hb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hb <= (others => '0');
            elsif CLK'event and CLK = '1' then
                hb <= resize(shift_right(sb * to_unsigned(3, 2), 3), 11);
            end if;
        end process;

    shy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                shy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                shy <= CY0 + signed('0' & hb);
            end if;
        end process;

    -- 高光點在球心左上方約 0.375 r, 光像是從左上照下來
    hl_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hl <= (others => '0');
            elsif CLK'event and CLK = '1' then
                hl <= resize(signed('0' & shift_right(br, 2)) + signed('0' & shift_right(br, 3)), 12);
            end if;
        end process;

    br2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                br2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                br2 <= br * br;
            end if;
        end process;

    -- 離高光點 < r/2: 最亮; < 0.87 r; < 1.22 r; 其餘是邊緣 (高光點偏左上, 右下邊緣最遠約 1.375 r)
    t_hi_reg: process(CLK, RST)
        begin
            if RST = '0' then
                t_hi <= (others => '0');
            elsif CLK'event and CLK = '1' then
                t_hi <= shift_right(br2, 2);
            end if;
        end process;

    t_mid_reg: process(CLK, RST)
        begin
            if RST = '0' then
                t_mid <= (others => '0');
            elsif CLK'event and CLK = '1' then
                t_mid <= br2 - shift_right(br2, 2);
            end if;
        end process;

    t_lo_reg: process(CLK, RST)
        begin
            if RST = '0' then
                t_lo <= (others => '0');
            elsif CLK'event and CLK = '1' then
                t_lo <= ('0' & br2) + shift_right(br2, 1);
            end if;
        end process;

    -- 玩家球拍在 Z = 0, s = 1
    ppl_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ppl <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ppl <= CX0 + pad_x - P3_HW;
            end if;
        end process;

    ppr_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ppr <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ppr <= CX0 + pad_x + P3_HW;
            end if;
        end process;

    ppt_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ppt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ppt <= CY0 + pad_y - P3_HH;
            end if;
        end process;

    ppb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ppb <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ppb <= CY0 + pad_y + P3_HH;
            end if;
        end process;

    -- 電腦球拍在隧道底, s = S_FAR
    cpl_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cpl <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cpl <= CX0 + proj(cpu_x - P3_HW, S_FAR);
            end if;
        end process;

    cpr_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cpr <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cpr <= CX0 + proj(cpu_x + P3_HW, S_FAR);
            end if;
        end process;

    cpt_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cpt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cpt <= CY0 + proj(cpu_y - P3_HH, S_FAR);
            end if;
        end process;

    cpb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cpb <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cpb <= CY0 + proj(cpu_y + P3_HH, S_FAR);
            end if;
        end process;

    ---------------------------------------------------------------- P1
    px <= signed('0' & x);
    py <= signed('0' & y);

    dx1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dx1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dx1 <= px - CX0;
            end if;
        end process;

    dy1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dy1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dy1 <= py - CY0;
            end if;
        end process;

    bdx1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bdx1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                bdx1 <= px - bsx;
            end if;
        end process;

    bdy1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bdy1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                bdy1 <= py - bsy;
            end if;
        end process;

    hdx1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hdx1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                hdx1 <= px - bsx + hl;
            end if;
        end process;

    hdy1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hdy1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                hdy1 <= py - bsy + hl;
            end if;
        end process;

    sdy1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sdy1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sdy1 <= py - shy;
            end if;
        end process;

    sxl1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sxl1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sxl1 <= unsigned(x) - DL_X;
            end if;
        end process;

    sxr1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sxr1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sxr1 <= unsigned(x) - DR_X;
            end if;
        end process;

    sy1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sy1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sy1 <= unsigned(y) - DIG_Y;
            end if;
        end process;

    pp_in   <= '1' when px >= ppl and px < ppr and py >= ppt and py < ppb else '0';
    pp_core <= '1' when px >= ppl + PAD_B and px < ppr - PAD_B and py >= ppt + PAD_B and py < ppb - PAD_B else '0';

    ovl1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ovl1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ovl1 <= (others => '0');
                if pp_in = '1' and pp_core = '0' then
                    ovl1(3) <= '1';
                end if;
                if pp_core = '1' then
                    ovl1(2) <= '1';
                end if;
                if px >= cpl and px < cpr and py >= cpt and py < cpb then
                    if px < cpl + CPU_B or px >= cpr - CPU_B or py < cpt + CPU_B or py >= cpb - CPU_B then
                        ovl1(1) <= '1';
                    else
                        ovl1(0) <= '1';
                    end if;
                end if;
            end if;
        end process;

    ---------------------------------------------------------------- P2
    adx2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                adx2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                adx2 <= unsigned(resize(abs(dx1), 11));          -- |dx| < 1024, 截掉的只有符號位
            end if;
        end process;

    ady2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ady2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ady2 <= unsigned(resize(abs(dy1), 11));
            end if;
        end process;

    sgn2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sgn2 <= "00";
            elsif CLK'event and CLK = '1' then
                sgn2 <= dx1(11) & dy1(11);
            end if;
        end process;

    bd2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bd2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                bd2 <= unsigned(bdx1 * bdx1) + unsigned(bdy1 * bdy1);
            end if;
        end process;

    hd2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hd2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                hd2 <= unsigned(hdx1 * hdx1) + unsigned(hdy1 * hdy1);
            end if;
        end process;

    -- 影子是扁的橢圓 (高 = 寬 / 4): dx^2 + 16 dy^2 < r^2
    sd2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sd2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sd2 <= resize(unsigned(bdx1 * bdx1), 28) + shift_left(resize(unsigned(sdy1 * sdy1), 28), 4);
            end if;
        end process;

    win_p <= '1' when score_p = WIN else '0';
    win_c <= '1' when score_c = WIN else '0';

    dig2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dig2 <= "00";
            elsif CLK'event and CLK = '1' then
                dig2 <= (seg_lit(sxl1, sy1, DIG_W, DIG_H, SEG_T, score_p) and not (win_p and blink))
                        & (seg_lit(sxr1, sy1, DIG_W, DIG_H, SEG_T, score_c) and not (win_c and blink));
            end if;
        end process;

    ovl2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ovl2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ovl2 <= ovl1;
            end if;
        end process;

    ---------------------------------------------------------------- P3
    a3   <= resize(adx2 * to_unsigned(3, 2), 13);
    a4   <= shift_left(resize(ady2, 13), 2);
    side <= '1' when a3 > a4 else '0';

    -- 地板 / 天花板的縱線: |3|dx| - k|dy|| < 3, 約 2 像素寬; k = 0 是中線
    grid_f_comb: process(a3, ady2)
        variable d : signed (13 downto 0);
        begin
            grid_f <= '0';
            for k in 0 to 3 loop
                d := signed('0' & a3) - signed(resize(ady2 * to_unsigned(k, 2), 14));
                if d > -3 and d < 3 then
                    grid_f <= '1';
                end if;
            end loop;
        end process;

    -- 側牆的縱線: |4|dy| - n|dx|| < 4; 牆角 (3|dx| = 4|dy|) 也畫, 隧道的稜線才清楚
    grid_s_comb: process(a3, a4, adx2)
        variable d : signed (13 downto 0);
        begin
            grid_s <= '0';
            for n in 0 to 2 loop
                d := signed('0' & a4) - signed(resize(adx2 * to_unsigned(n, 2), 14));
                if d > -4 and d < 4 then
                    grid_s <= '1';
                end if;
            end loop;
            d := signed('0' & a3) - signed('0' & a4);
            if d > -4 and d < 4 then
                grid_s <= '1';
            end if;
        end process;

    ring_f_comb: process(ady2)
        begin
            ring_f <= '0';
            for k in 1 to 7 loop
                if ady2 >= RING_HH(k) and ady2 < RING_HH(k) + 2 then
                    ring_f <= '1';
                end if;
            end loop;
        end process;

    ring_s_comb: process(adx2)
        begin
            ring_s <= '0';
            for k in 1 to 7 loop
                if adx2 >= RING_HW(k) and adx2 < RING_HW(k) + 2 then
                    ring_s <= '1';
                end if;
            end loop;
        end process;

    region3_reg: process(CLK, RST)
        begin
            if RST = '0' then
                region3 <= R_CEIL;
            elsif CLK'event and CLK = '1' then
                if side = '1' then
                    if sgn2(1) = '1' then
                        region3 <= R_LEFT;
                    else
                        region3 <= R_RIGHT;
                    end if;
                elsif sgn2(0) = '1' then
                    region3 <= R_CEIL;
                else
                    region3 <= R_FLOOR;
                end if;
            end if;
        end process;

    -- max(3|dx|, 4|dy|) = 1536 s: 隧道口 12, 隧道底 3
    lvl3_reg: process(CLK, RST)
        begin
            if RST = '0' then
                lvl3 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if side = '1' then
                    lvl3 <= a3(10 downto 7);
                else
                    lvl3 <= a4(10 downto 7);
                end if;
            end if;
        end process;

    f3_reg: process(CLK, RST)
        begin
            if RST = '0' then
                f3 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                f3 <= (others => '0');
                if adx2 < FAR_HW and ady2 < FAR_HH then
                    f3(F3_BACK) <= '1';
                end if;
                if (side = '0' and (grid_f = '1' or ring_f = '1')) or (side = '1' and (grid_s = '1' or ring_s = '1')) then
                    f3(F3_GRID) <= '1';
                end if;
                if (side = '0' and ady2 >= hb and ady2 < hb + 3) or (side = '1' and adx2 >= wb and adx2 < wb + 3) then
                    f3(F3_DEPTH) <= '1';
                end if;
                if bd2 < br2 then
                    f3(F3_BALL) <= '1';
                end if;
                if sd2 < br2 and side = '0' and sgn2(0) = '0' then
                    f3(F3_SHAD) <= '1';
                end if;
                if adx2 >= CX0 - EDGE_W or ady2 >= CY0 - EDGE_W then
                    f3(F3_EDGE) <= '1';
                end if;
                if ovl2(0) = '1' then
                    f3(F3_CPU) <= '1';
                end if;
            end if;
        end process;

    bl3_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bl3 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if hd2 < t_hi then
                    bl3 <= "00";
                elsif hd2 < t_mid then
                    bl3 <= "01";
                elsif hd2 < t_lo then
                    bl3 <= "10";
                else
                    bl3 <= "11";
                end if;
            end if;
        end process;

    dig3_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dig3 <= "00";
            elsif CLK'event and CLK = '1' then
                dig3 <= dig2;
            end if;
        end process;

    ovl3_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ovl3 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ovl3 <= ovl2;
            end if;
        end process;

    ---------------------------------------------------------------- P4
    -- 暫停時球閃爍; 得分停頓期間外圈閃爍
    show_b <= ball_on and not (paused and blink);
    flash  <= '1' when gphase = GP_POINT and blink = '1' else '0';

    base4_reg: process(CLK, RST)
        begin
            if RST = '0' then
                base4 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if f3(F3_BALL) = '1' and show_b = '1' then
                    base4 <= C_BALL(to_integer(bl3));
                elsif f3(F3_SHAD) = '1' and show_b = '1' then
                    base4 <= C_SHAD;
                elsif ovl3(1) = '1' then
                    base4 <= C_CPU_E;
                elsif f3(F3_CPU) = '1' then
                    base4 <= C_CPU_F;
                elsif f3(F3_BACK) = '1' then
                    base4 <= C_BACK;
                elsif f3(F3_EDGE) = '1' and flash = '1' then
                    if p_scored = '1' then
                        base4 <= C_WON;
                    else
                        base4 <= C_LOST;
                    end if;
                elsif f3(F3_DEPTH) = '1' and show_b = '1' then
                    base4 <= C_DEPTH;
                elsif f3(F3_GRID) = '1' then
                    base4 <= shade(C_GRID, lvl3);
                else
                    case region3 is
                        when R_FLOOR => base4 <= shade(C_FLOOR, lvl3);
                        when R_CEIL  => base4 <= shade(C_CEIL, lvl3);
                        when others  => base4 <= shade(C_SIDE, lvl3);
                    end case;
                end if;
            end if;
        end process;

    dig4_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dig4 <= "00";
            elsif CLK'event and CLK = '1' then
                dig4 <= dig3;
            end if;
        end process;

    ovl4_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ovl4 <= "00";
            elsif CLK'event and CLK = '1' then
                ovl4 <= ovl3(3 downto 2);
            end if;
        end process;

    ---------------------------------------------------------------- P5
    -- 玩家球拍在最前面: 框不透明, 面半透明, 才看得到後面的球
    rgb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if dig4(1) = '1' then
                    rgb_r <= C_PAD;
                elsif dig4(0) = '1' then
                    rgb_r <= C_CPU_E;
                elsif ovl4(1) = '1' then
                    rgb_r <= C_PAD;
                elsif ovl4(0) = '1' then
                    rgb_r <= blend(base4, C_PAD);
                else
                    rgb_r <= base4;
                end if;
            end if;
        end process;

    rgb <= rgb_r;
end Behavioral;
