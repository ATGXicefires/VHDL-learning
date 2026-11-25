----------------------------------------------------------------------------------
-- Module Name: pong3d_draw - Behavioral
-- Description: 3D 球桌的畫面 (從球員身後斜上方看), 延遲 LAT_3D 拍
--   透視: 世界座標 (X, Y, Z) -> 螢幕 (512 + X s, HZ_Y + Y s), s = SCALE(Z / 4) (見 pong_pkg)
--   每個 frame 只有球、兩支球拍的位置會變, 它們的投影在「每幀值」那一段算好 (狀態只在遮沒期間改,
--     那幾級暫存器早就穩定了); 掃描像素時只做比較, 不用除法
--   桌面: 桌面上第 y 列的縮放是 s = (y - HZ_Y) / TBL_Y, 那一列桌面的半寬是 TW s,
--     所以「在桌面上」= |dx| TBL_Y < TW (y - HZ_Y), 兩邊都只是乘常數; 邊線就是兩者差距很小的地方
--   網子、桌子端線、桌子前緣的厚度都在固定深度, 是固定的列 (Y_NET 等, pong_pkg 算好)
--   球的影子畫在桌面高度 (bx, TBL_Y, bz), 看得出球多高、落點在哪; 影子只在桌面上才畫
--   畫的順序 (前面的蓋後面的): 比分 > 玩家球拍 (框不透明、拍面半透明) > 網子前的球 > 網子 >
--     網子後的球 > 電腦球拍 > 得分閃爍外圈 > 影子 > 桌上白線 > 桌面 > 桌子前緣 > 地板 > 牆
--   管線: P1 相對座標與列的判斷, P2 絕對值、平方、乘常數、數字, P3 各物件的判斷, P4 選顏色, P5 疊上玩家球拍
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
    constant CX0    : integer := SCR_W / 2;
    constant DIG_W  : integer := 32;
    constant DIG_H  : integer := 56;
    constant SEG_T  : integer := 8;
    constant DIG_Y  : integer := 20;
    constant DL_X   : integer := 24;
    constant DR_X   : integer := SCR_W - 24 - DIG_W;
    constant EDGE_W : integer := 16;                               -- 得分時閃爍的外圈寬度
    constant FRONT_H : integer := 14;                              -- 桌子前緣的厚度 (螢幕像素)
    constant Y_WALL : integer := 232;                              -- 牆腳線
    constant LINE_W : integer := 3;                                -- 桌上白線寬度 (像素)

    -- 球拍: 圓形拍面 + 握把; 電腦的球拍在 Z_FAR, 尺寸乘上 S_FAR
    constant PAD_RI  : integer := PAD_R - 5;                       -- 拍面框的內緣
    constant PAD_R2  : integer := PAD_R * PAD_R;
    constant PAD_RI2 : integer := PAD_RI * PAD_RI;
    constant HAND_W  : integer := 11;                              -- 握把半寬
    constant HAND_L  : integer := 64;                              -- 握把露在拍面外的長度
    constant CPU_R   : integer := PAD_R * S_FAR / 1024;
    constant CPU_R2  : integer := CPU_R * CPU_R;
    constant CPU_RI2 : integer := (CPU_R - 2) * (CPU_R - 2);
    constant CHAND_W : integer := HAND_W * S_FAR / 1024;
    constant CHAND_L : integer := HAND_L * S_FAR / 1024;

    -- 平塗: 每色只有 4 bit, 依列漸層會變成一條條明顯的色帶
    constant C_WALL  : rgb_type := x"124";
    constant C_FLOOR : rgb_type := x"532";
    constant C_TBL   : rgb_type := x"14A";
    constant C_FRONT : rgb_type := x"036";
    constant C_LINE  : rgb_type := x"EEF";
    constant C_NET   : rgb_type := x"9AB";
    constant C_NETT  : rgb_type := x"FFF";
    constant C_SHAD  : rgb_type := x"024";
    constant C_FACE  : rgb_type := x"D22";
    constant C_RIM   : rgb_type := x"FA5";
    constant C_HAND  : rgb_type := x"A63";
    constant C_DIG_P : rgb_type := x"8DF";
    constant C_DIG_C : rgb_type := x"F66";
    constant C_LOST  : rgb_type := x"F22";
    constant C_WON   : rgb_type := x"2F4";
    type ball_colors is array (0 to 3) of rgb_type;
    constant C_BALL  : ball_colors := (x"FFF", x"FEA", x"EB5", x"A72");    -- 高光 -> 邊緣

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
    signal msh         : unsigned (20 downto 0);
    signal bsx, bsy    : signed (11 downto 0);                     -- 球心 (螢幕)
    signal br          : unsigned (6 downto 0);                    -- 球半徑 (螢幕)
    signal shy         : signed (11 downto 0);                     -- 影子中心 y
    signal sh_on       : STD_LOGIC;                                -- 球在桌面正上方
    signal ball_fr     : STD_LOGIC;                                -- 球在網子前 (玩家這一側)
    signal hl          : signed (11 downto 0);                     -- 高光點離球心的距離
    signal br2         : unsigned (13 downto 0);
    signal t_hi        : unsigned (13 downto 0);                   -- 明暗分界 (距高光點的平方)
    signal t_mid       : unsigned (13 downto 0);
    signal t_lo        : unsigned (14 downto 0);
    signal ppx, ppy    : signed (11 downto 0);                     -- 玩家拍心 (螢幕)
    signal cpx, cpy    : signed (11 downto 0);                     -- 電腦拍心 (螢幕)

    ---------------------------------------------------------------- 像素管線
    signal px, py      : signed (11 downto 0);

    -- P1
    signal dx1, yh1    : signed (11 downto 0);                     -- 相對畫面中線 / 視平線
    signal bdx1, bdy1  : signed (11 downto 0);
    signal hdx1, hdy1  : signed (11 downto 0);
    signal sdy1        : signed (11 downto 0);
    signal pdx1, pdy1  : signed (11 downto 0);
    signal cdx1, cdy1  : signed (11 downto 0);
    signal sxl1, sxr1  : unsigned (10 downto 0);
    signal sy1         : unsigned (10 downto 0);
    signal row1        : STD_LOGIC_VECTOR (7 downto 0);            -- 見下面 R_*
    constant R_TBL     : integer := 0;                             -- 桌面的列
    constant R_END     : integer := 1;                             -- 端線的列
    constant R_FRONT   : integer := 2;                             -- 桌子前緣的列
    constant R_NET     : integer := 3;                             -- 網子的列
    constant R_NETT    : integer := 4;                             -- 網子頂邊的列
    constant R_MESH    : integer := 5;                             -- 網格的線
    constant R_FLOOR   : integer := 6;
    constant R_EDGE    : integer := 7;                             -- 螢幕外圈
    signal hand1       : STD_LOGIC_VECTOR (1 downto 0);            -- 玩家握把, 電腦握把

    -- P2
    signal adx2        : unsigned (10 downto 0);
    signal axt2        : unsigned (20 downto 0);                   -- |dx| TBL_Y
    signal ywt2        : unsigned (20 downto 0);                   -- (y - HZ_Y) TW
    signal bd2         : unsigned (23 downto 0);
    signal hd2         : unsigned (23 downto 0);
    signal sd2         : unsigned (25 downto 0);
    signal pd2         : unsigned (23 downto 0);
    signal cd2         : unsigned (23 downto 0);
    signal dig2        : STD_LOGIC_VECTOR (1 downto 0);
    signal row2        : STD_LOGIC_VECTOR (7 downto 0);
    signal hand2       : STD_LOGIC_VECTOR (1 downto 0);

    -- P3
    signal in_tbl      : STD_LOGIC;
    signal f3          : STD_LOGIC_VECTOR (10 downto 0);           -- 見下面 F3_*
    constant F3_BALL   : integer := 0;
    constant F3_NET    : integer := 1;
    constant F3_NETT   : integer := 2;
    constant F3_CRIM   : integer := 3;
    constant F3_CFACE  : integer := 4;
    constant F3_CHAND  : integer := 5;
    constant F3_EDGE   : integer := 6;
    constant F3_SHAD   : integer := 7;
    constant F3_LINE   : integer := 8;
    constant F3_TBL    : integer := 9;
    constant F3_FRONT  : integer := 10;
    signal floor3      : STD_LOGIC;
    signal bl3         : unsigned (1 downto 0);                    -- 球的明暗級
    signal dig3        : STD_LOGIC_VECTOR (1 downto 0);
    signal ovl3        : STD_LOGIC_VECTOR (2 downto 0);            -- 玩家拍框, 拍面, 握把

    -- P4
    signal show_b      : STD_LOGIC;
    signal flash       : STD_LOGIC;
    signal base4       : rgb_type;
    signal dig4        : STD_LOGIC_VECTOR (1 downto 0);
    signal ovl4        : STD_LOGIC_VECTOR (2 downto 0);
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

    msh_reg: process(CLK, RST)
        begin
            if RST = '0' then
                msh <= (others => '0');
            elsif CLK'event and CLK = '1' then
                msh <= sb * to_unsigned(TBL_Y, 10);
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
                bsy <= HZ_Y + resize(shift_right(mby, 10), 12);
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

    shy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                shy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                shy <= HZ_Y + signed(resize(msh(20 downto 10), 12));
            end if;
        end process;

    sh_on_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sh_on <= '0';
            elsif CLK'event and CLK = '1' then
                if abs(ball_x) <= TW and ball_z >= Z_T0 and ball_z <= Z_T1 then
                    sh_on <= '1';
                else
                    sh_on <= '0';
                end if;
            end if;
        end process;

    ball_fr_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ball_fr <= '0';
            elsif CLK'event and CLK = '1' then
                if ball_z < Z_NET then
                    ball_fr <= '1';
                else
                    ball_fr <= '0';
                end if;
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
    ppx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ppx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ppx <= CX0 + pad_x;
            end if;
        end process;

    ppy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ppy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ppy <= HZ_Y + pad_y;
            end if;
        end process;

    cpx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cpx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cpx <= CX0 + proj(cpu_x, S_FAR);
            end if;
        end process;

    cpy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cpy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cpy <= HZ_Y + proj(cpu_y, S_FAR);
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

    yh1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                yh1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                yh1 <= py - HZ_Y;
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

    pdx1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pdx1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                pdx1 <= px - ppx;
            end if;
        end process;

    pdy1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pdy1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                pdy1 <= py - ppy;
            end if;
        end process;

    cdx1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cdx1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cdx1 <= px - cpx;
            end if;
        end process;

    cdy1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cdy1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cdy1 <= py - cpy;
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

    -- 只跟 x、y 有關的判斷: 固定深度的東西在螢幕上是固定的列
    row1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                row1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                row1 <= (others => '0');
                if py >= Y_FAR and py < Y_NEAR then
                    row1(R_TBL) <= '1';
                end if;
                if (py >= Y_FAR and py < Y_FAR + 2) or (py >= Y_NEAR - LINE_W and py < Y_NEAR) then
                    row1(R_END) <= '1';
                end if;
                if py >= Y_NEAR and py < Y_NEAR + FRONT_H then
                    row1(R_FRONT) <= '1';
                end if;
                if py >= Y_NETT and py <= Y_NET then
                    row1(R_NET) <= '1';
                end if;
                if py >= Y_NETT and py < Y_NETT + 3 then
                    row1(R_NETT) <= '1';
                end if;
                if x(2 downto 0) = "000" or y(1 downto 0) = "00" then
                    row1(R_MESH) <= '1';
                end if;
                if py >= Y_WALL then
                    row1(R_FLOOR) <= '1';
                end if;
                if px < EDGE_W or px >= SCR_W - EDGE_W or py < EDGE_W or py >= SCR_H - EDGE_W then
                    row1(R_EDGE) <= '1';
                end if;
            end if;
        end process;

    -- 握把從拍面底下伸出來
    hand1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hand1 <= "00";
            elsif CLK'event and CLK = '1' then
                hand1 <= "00";
                if px >= ppx - HAND_W and px < ppx + HAND_W and py >= ppy + PAD_R - 8 and py < ppy + PAD_R + HAND_L then
                    hand1(1) <= '1';
                end if;
                if px >= cpx - CHAND_W and px < cpx + CHAND_W and py >= cpy + CPU_R - 3 and py < cpy + CPU_R + CHAND_L then
                    hand1(0) <= '1';
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

    axt2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                axt2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                axt2 <= unsigned(resize(abs(dx1), 11)) * to_unsigned(TBL_Y, 10);
            end if;
        end process;

    -- y - HZ_Y 在可視範圍內一定是正的
    ywt2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ywt2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ywt2 <= resize(unsigned(yh1(10 downto 0)) * to_unsigned(TW, 9), 21);
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

    -- 桌面斜著看會被壓扁, 影子畫成高 = 寬 / 2 的橢圓: dx^2 + 4 dy^2 < r^2
    sd2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sd2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sd2 <= resize(unsigned(bdx1 * bdx1), 26) + shift_left(resize(unsigned(sdy1 * sdy1), 26), 2);
            end if;
        end process;

    pd2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pd2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                pd2 <= unsigned(pdx1 * pdx1) + unsigned(pdy1 * pdy1);
            end if;
        end process;

    cd2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cd2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cd2 <= unsigned(cdx1 * cdx1) + unsigned(cdy1 * cdy1);
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

    row2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                row2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                row2 <= row1;
            end if;
        end process;

    hand2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hand2 <= "00";
            elsif CLK'event and CLK = '1' then
                hand2 <= hand1;
            end if;
        end process;

    ---------------------------------------------------------------- P3
    in_tbl <= '1' when row2(R_TBL) = '1' and axt2 < ywt2 else '0';

    f3_reg: process(CLK, RST)
        begin
            if RST = '0' then
                f3 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                f3 <= (others => '0');
                if bd2 < br2 then
                    f3(F3_BALL) <= '1';
                end if;
                -- 網子只有網線和頂邊不透明, 網眼看得到後面
                if row2(R_NET) = '1' and adx2 < NET_SHW and (row2(R_MESH) = '1' or row2(R_NETT) = '1') then
                    f3(F3_NET) <= '1';
                end if;
                if row2(R_NETT) = '1' then
                    f3(F3_NETT) <= '1';
                end if;
                if cd2 < CPU_R2 then
                    if cd2 >= CPU_RI2 then
                        f3(F3_CRIM) <= '1';
                    else
                        f3(F3_CFACE) <= '1';
                    end if;
                end if;
                if hand2(0) = '1' then
                    f3(F3_CHAND) <= '1';
                end if;
                if row2(R_EDGE) = '1' then
                    f3(F3_EDGE) <= '1';
                end if;
                if sd2 < br2 and sh_on = '1' and in_tbl = '1' then
                    f3(F3_SHAD) <= '1';
                end if;
                -- 邊線: 離桌緣不到 LINE_W 像素 (差距以 TBL_Y 為單位); 中線; 兩條端線
                if in_tbl = '1' and (ywt2 - axt2 < LINE_W * TBL_Y or adx2 < 2 or row2(R_END) = '1') then
                    f3(F3_LINE) <= '1';
                end if;
                if in_tbl = '1' then
                    f3(F3_TBL) <= '1';
                end if;
                if row2(R_FRONT) = '1' and adx2 < NEAR_HW then
                    f3(F3_FRONT) <= '1';
                end if;
            end if;
        end process;

    floor3_reg: process(CLK, RST)
        begin
            if RST = '0' then
                floor3 <= '0';
            elsif CLK'event and CLK = '1' then
                floor3 <= row2(R_FLOOR);
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
                ovl3 <= (others => '0');
                if pd2 < PAD_R2 then
                    if pd2 >= PAD_RI2 then
                        ovl3(2) <= '1';
                    else
                        ovl3(1) <= '1';
                    end if;
                end if;
                if hand2(1) = '1' then
                    ovl3(0) <= '1';
                end if;
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
                if f3(F3_BALL) = '1' and show_b = '1' and ball_fr = '1' then
                    base4 <= C_BALL(to_integer(bl3));
                elsif f3(F3_NET) = '1' then
                    if f3(F3_NETT) = '1' then
                        base4 <= C_NETT;
                    else
                        base4 <= C_NET;
                    end if;
                elsif f3(F3_BALL) = '1' and show_b = '1' then
                    base4 <= C_BALL(to_integer(bl3));
                elsif f3(F3_CRIM) = '1' then
                    base4 <= C_RIM;
                elsif f3(F3_CFACE) = '1' then
                    base4 <= C_FACE;
                elsif f3(F3_CHAND) = '1' then
                    base4 <= C_HAND;
                elsif f3(F3_EDGE) = '1' and flash = '1' then
                    if p_scored = '1' then
                        base4 <= C_WON;
                    else
                        base4 <= C_LOST;
                    end if;
                elsif f3(F3_SHAD) = '1' and show_b = '1' then
                    base4 <= C_SHAD;
                elsif f3(F3_LINE) = '1' then
                    base4 <= C_LINE;
                elsif f3(F3_TBL) = '1' then
                    base4 <= C_TBL;
                elsif f3(F3_FRONT) = '1' then
                    base4 <= C_FRONT;
                elsif floor3 = '1' then
                    base4 <= C_FLOOR;
                else
                    base4 <= C_WALL;
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
                ovl4 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ovl4 <= ovl3;
            end if;
        end process;

    ---------------------------------------------------------------- P5
    -- 玩家球拍在最前面: 框和握把不透明, 拍面半透明, 才看得到後面的球
    rgb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if dig4(1) = '1' then
                    rgb_r <= C_DIG_P;
                elsif dig4(0) = '1' then
                    rgb_r <= C_DIG_C;
                elsif ovl4(2) = '1' then
                    rgb_r <= C_RIM;
                elsif ovl4(1) = '1' then
                    rgb_r <= blend(base4, C_FACE);
                elsif ovl4(0) = '1' then
                    rgb_r <= C_HAND;
                else
                    rgb_r <= base4;
                end if;
            end if;
        end process;

    rgb <= rgb_r;
end Behavioral;
