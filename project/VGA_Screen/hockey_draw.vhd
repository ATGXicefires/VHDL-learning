----------------------------------------------------------------------------------
-- Module Name: hockey_draw - Behavioral
-- Description: 空氣曲棍球繪圖 (延遲 LAT_HOCKEY 拍), 物件位置是 hockey_ctrl 給的邏輯座標
--   obj_x / obj_y: 0 = 球, 1 = 玩家球槌, 2 = 電腦球槌
--   場地: 深藍桌面、白色邊牆, 左右牆中間的開口是球門 (進球時閃白); 紅色中線與中圈, 藍色球門區半圓
--   中圈和兩個球門區的圓心 y 都是 H / 2, 共用同一個 dy^2; 球門區圓心在畫面左右邊上, 自然只畫出半圓
--   比分用七段顯示器的樣子畫在上方中央 (玩家紅、電腦藍), 比賽結束時勝方的數字閃爍
--   優先序: 球 > 球槌 > 比分 > 球門 / 牆 > 線 > 桌面
--   big = '1' (1024x768 以上) 時座標減半, 整個場地放大 2 倍
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;                                          -- 到各圓心的 dx, dy 是有號數
use work.vga_pkg.all;

entity hockey_draw is
    Port ( CLK       : in  STD_LOGIC;
           RST       : in  STD_LOGIC;
           x         : in  coord_type;
           y         : in  coord_type;
           h_size    : in  coord_type;
           v_size    : in  coord_type;
           big       : in  STD_LOGIC;
           obj_x     : in  coord3_type;
           obj_y     : in  coord3_type;
           score_p   : in  STD_LOGIC_VECTOR (2 downto 0);
           score_c   : in  STD_LOGIC_VECTOR (2 downto 0);
           puck_show : in  STD_LOGIC;
           goal_l    : in  STD_LOGIC;
           goal_r    : in  STD_LOGIC;
           win_p     : in  STD_LOGIC;
           win_c     : in  STD_LOGIC;
           blink     : in  STD_LOGIC;
           rgb       : out rgb_type);
end hockey_draw;

architecture Behavioral of hockey_draw is
    -- 尺寸要和 hockey_ctrl 一致
    constant WALL      : integer := 8;
    constant RP        : integer := 12;
    constant RM        : integer := 20;
    constant GOAL_HALF : integer := 80;

    constant PUCK_IN   : integer := 9;                             -- 球的深色外圈從這裡開始
    constant KNOB_R    : integer := 8;                             -- 球槌握把
    constant RING_IN   : integer := 12;
    constant RING_OUT  : integer := 15;
    constant CIRCLE_R  : integer := 48;                            -- 中圈
    constant CREASE_R  : integer := 96;                            -- 球門區
    constant LINE_W    : integer := 3;
    constant DIG_W     : integer := 32;
    constant DIG_H     : integer := 48;
    constant DIG_Y     : integer := 24;
    constant DIG_GAP   : integer := 24;                            -- 數字和中線的距離
    constant SEG_T     : integer := 6;

    constant C_TABLE    : rgb_type := x"124";
    constant C_WALL     : rgb_type := x"BBB";
    constant C_LINE     : rgb_type := x"C33";
    constant C_CREASE   : rgb_type := x"38C";
    constant C_PUCK     : rgb_type := x"FD2";
    constant C_PUCK_RIM : rgb_type := x"A70";
    constant C_DIG_P    : rgb_type := x"F55";
    constant C_DIG_C    : rgb_type := x"6AF";

    -- 索引 = 球槌的部位: 1 本體, 2 外圈, 3 握把
    type mallet_colors is array (1 to 3) of rgb_type;
    constant P_COLOR : mallet_colors := (x"E33", x"811", x"F99");
    constant C_COLOR : mallet_colors := (x"36E", x"125", x"9BF");

    -- 段的順序 a b c d e f g (a = 上, 順時針繞一圈, g = 中間)
    type seg_table is array (0 to 7) of STD_LOGIC_VECTOR (6 downto 0);
    constant SEG7 : seg_table := ("1111110", "0110000", "1101101", "1111001",
                                  "0110011", "1011011", "1011111", "1110000");

    type d3_type  is array (0 to 2) of signed (11 downto 0);
    type sq3_type is array (0 to 2) of unsigned (23 downto 0);
    type r3_type  is array (0 to 2) of unsigned (24 downto 0);

    -- (sx, sy) 是數字框內的座標; 框左邊或上面的像素減出來是負的, 繞回成大數, 一樣落在框外
    function segments(sx, sy : unsigned) return STD_LOGIC_VECTOR is
        variable s : STD_LOGIC_VECTOR (6 downto 0) := (others => '0');
    begin
        if sx < DIG_W and sy < DIG_H then
            if sy < SEG_T then
                s(6) := '1';
            end if;
            if sx >= DIG_W - SEG_T and sy < DIG_H / 2 then
                s(5) := '1';
            end if;
            if sx >= DIG_W - SEG_T and sy >= DIG_H / 2 then
                s(4) := '1';
            end if;
            if sy >= DIG_H - SEG_T then
                s(3) := '1';
            end if;
            if sx < SEG_T and sy >= DIG_H / 2 then
                s(2) := '1';
            end if;
            if sx < SEG_T and sy < DIG_H / 2 then
                s(1) := '1';
            end if;
            if sy >= (DIG_H - SEG_T) / 2 and sy < (DIG_H + SEG_T) / 2 then
                s(0) := '1';
            end if;
        end if;
        return s;
    end function;

    signal px, py             : unsigned (10 downto 0);
    signal w_log, h_log       : unsigned (10 downto 0);
    signal mid_x, mid_y       : unsigned (10 downto 0);
    signal right_w, bottom_w  : unsigned (10 downto 0);
    signal mouth_lo, mouth_hi : unsigned (10 downto 0);
    signal line_lo, line_hi   : unsigned (10 downto 0);
    signal dig_px, dig_cx     : unsigned (10 downto 0);

    signal odx, ody           : d3_type;
    signal cdx, cdy           : signed (11 downto 0);
    signal ldx, rdx           : signed (11 downto 0);
    signal fld1, fld4         : STD_LOGIC_VECTOR (3 downto 0);     -- 邊牆, 左球門, 右球門, 中線
    signal sx_p, sx_c, sy     : unsigned (10 downto 0);

    signal odx2, ody2         : sq3_type;
    signal cdx2, cdy2         : unsigned (23 downto 0);
    signal ldx2, rdx2         : unsigned (23 downto 0);
    signal seg_p, seg_c       : STD_LOGIC_VECTOR (6 downto 0);
    signal show_p, show_c     : STD_LOGIC;
    signal dig2, dig4         : STD_LOGIC_VECTOR (1 downto 0);     -- 玩家比分, 電腦比分

    signal or2                : r3_type;
    signal cr2, lr2, rr2      : unsigned (24 downto 0);

    signal puck_c             : STD_LOGIC_VECTOR (1 downto 0);     -- 1 本體, 2 外圈
    signal pm_c, cm_c         : STD_LOGIC_VECTOR (1 downto 0);     -- 見 mallet_colors
    signal ring_c             : STD_LOGIC_VECTOR (1 downto 0);     -- 1 中圈, 2 球門區
    signal flash_l, flash_r   : STD_LOGIC;
    signal rgb_r              : rgb_type;
begin
    px    <= unsigned('0' & x(10 downto 1)) when big = '1' else unsigned(x);
    py    <= unsigned('0' & y(10 downto 1)) when big = '1' else unsigned(y);
    w_log <= unsigned('0' & h_size(10 downto 1)) when big = '1' else unsigned(h_size);
    h_log <= unsigned('0' & v_size(10 downto 1)) when big = '1' else unsigned(v_size);
    mid_x <= shift_right(w_log, 1);
    mid_y <= shift_right(h_log, 1);

    -- 場地邊界只在換解析度時改變, 先存起來, 像素比較才不會串上 解析度表 -> 加減法 這段路徑
    right_w_reg: process(CLK, RST)
        begin
            if RST = '0' then
                right_w <= (others => '0');
            elsif CLK'event and CLK = '1' then
                right_w <= w_log - WALL;
            end if;
        end process;

    bottom_w_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bottom_w <= (others => '0');
            elsif CLK'event and CLK = '1' then
                bottom_w <= h_log - WALL;
            end if;
        end process;

    mouth_lo_reg: process(CLK, RST)
        begin
            if RST = '0' then
                mouth_lo <= (others => '0');
            elsif CLK'event and CLK = '1' then
                mouth_lo <= mid_y - GOAL_HALF;
            end if;
        end process;

    mouth_hi_reg: process(CLK, RST)
        begin
            if RST = '0' then
                mouth_hi <= (others => '0');
            elsif CLK'event and CLK = '1' then
                mouth_hi <= mid_y + GOAL_HALF;
            end if;
        end process;

    line_lo_reg: process(CLK, RST)
        begin
            if RST = '0' then
                line_lo <= (others => '0');
            elsif CLK'event and CLK = '1' then
                line_lo <= mid_x - 2;
            end if;
        end process;

    line_hi_reg: process(CLK, RST)
        begin
            if RST = '0' then
                line_hi <= (others => '0');
            elsif CLK'event and CLK = '1' then
                line_hi <= mid_x + 2;
            end if;
        end process;

    dig_px_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dig_px <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dig_px <= mid_x - (DIG_GAP + DIG_W);
            end if;
        end process;

    dig_cx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dig_cx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dig_cx <= mid_x + DIG_GAP;
            end if;
        end process;

    odx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                odx <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    odx(i) <= signed('0' & px) - signed('0' & obj_x(i));
                end loop;
            end if;
        end process;

    ody_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ody <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    ody(i) <= signed('0' & py) - signed('0' & obj_y(i));
                end loop;
            end if;
        end process;

    cdx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cdx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cdx <= signed('0' & px) - signed('0' & mid_x);
            end if;
        end process;

    cdy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cdy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cdy <= signed('0' & py) - signed('0' & mid_y);
            end if;
        end process;

    ldx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ldx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ldx <= signed('0' & px);
            end if;
        end process;

    rdx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rdx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                rdx <= signed('0' & px) - signed('0' & w_log);
            end if;
        end process;

    fld1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                fld1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if px < WALL or px >= right_w or py < WALL or py >= bottom_w then
                    fld1(3) <= '1';
                else
                    fld1(3) <= '0';
                end if;
                if px < WALL and py > mouth_lo and py < mouth_hi then
                    fld1(2) <= '1';
                else
                    fld1(2) <= '0';
                end if;
                if px >= right_w and py > mouth_lo and py < mouth_hi then
                    fld1(1) <= '1';
                else
                    fld1(1) <= '0';
                end if;
                if px >= line_lo and px < line_hi then
                    fld1(0) <= '1';
                else
                    fld1(0) <= '0';
                end if;
            end if;
        end process;

    sx_p_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sx_p <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sx_p <= px - dig_px;
            end if;
        end process;

    sx_c_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sx_c <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sx_c <= px - dig_cx;
            end if;
        end process;

    sy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sy <= py - DIG_Y;
            end if;
        end process;

    odx2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                odx2 <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    odx2(i) <= unsigned(odx(i) * odx(i));
                end loop;
            end if;
        end process;

    ody2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ody2 <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    ody2(i) <= unsigned(ody(i) * ody(i));
                end loop;
            end if;
        end process;

    cdx2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cdx2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cdx2 <= unsigned(cdx * cdx);
            end if;
        end process;

    cdy2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cdy2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cdy2 <= unsigned(cdy * cdy);
            end if;
        end process;

    ldx2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ldx2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ldx2 <= unsigned(ldx * ldx);
            end if;
        end process;

    rdx2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rdx2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                rdx2 <= unsigned(rdx * rdx);
            end if;
        end process;

    seg_p  <= segments(sx_p, sy);
    seg_c  <= segments(sx_c, sy);
    show_p <= '0' when win_p = '1' and blink = '0' else '1';
    show_c <= '0' when win_c = '1' and blink = '0' else '1';

    dig2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dig2 <= "00";
            elsif CLK'event and CLK = '1' then
                if (seg_p and SEG7(to_integer(unsigned(score_p)))) /= "0000000" and show_p = '1' then
                    dig2(1) <= '1';
                else
                    dig2(1) <= '0';
                end if;
                if (seg_c and SEG7(to_integer(unsigned(score_c)))) /= "0000000" and show_c = '1' then
                    dig2(0) <= '1';
                else
                    dig2(0) <= '0';
                end if;
            end if;
        end process;

    or2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                or2 <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    or2(i) <= resize(odx2(i), 25) + ody2(i);
                end loop;
            end if;
        end process;

    cr2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cr2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cr2 <= resize(cdx2, 25) + cdy2;
            end if;
        end process;

    lr2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                lr2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                lr2 <= resize(ldx2, 25) + cdy2;
            end if;
        end process;

    rr2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rr2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                rr2 <= resize(rdx2, 25) + cdy2;
            end if;
        end process;

    puck_c_reg: process(CLK, RST)
        begin
            if RST = '0' then
                puck_c <= "00";
            elsif CLK'event and CLK = '1' then
                if puck_show = '0' or or2(0) >= RP * RP then
                    puck_c <= "00";
                elsif or2(0) >= PUCK_IN * PUCK_IN then
                    puck_c <= "10";
                else
                    puck_c <= "01";
                end if;
            end if;
        end process;

    pm_c_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pm_c <= "00";
            elsif CLK'event and CLK = '1' then
                if or2(1) < KNOB_R * KNOB_R then
                    pm_c <= "11";
                elsif or2(1) >= RING_IN * RING_IN and or2(1) < RING_OUT * RING_OUT then
                    pm_c <= "10";
                elsif or2(1) < RM * RM then
                    pm_c <= "01";
                else
                    pm_c <= "00";
                end if;
            end if;
        end process;

    cm_c_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cm_c <= "00";
            elsif CLK'event and CLK = '1' then
                if or2(2) < KNOB_R * KNOB_R then
                    cm_c <= "11";
                elsif or2(2) >= RING_IN * RING_IN and or2(2) < RING_OUT * RING_OUT then
                    cm_c <= "10";
                elsif or2(2) < RM * RM then
                    cm_c <= "01";
                else
                    cm_c <= "00";
                end if;
            end if;
        end process;

    ring_c_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ring_c <= "00";
            elsif CLK'event and CLK = '1' then
                if cr2 >= CIRCLE_R * CIRCLE_R and cr2 < (CIRCLE_R + LINE_W) * (CIRCLE_R + LINE_W) then
                    ring_c <= "01";
                elsif (lr2 >= CREASE_R * CREASE_R and lr2 < (CREASE_R + LINE_W) * (CREASE_R + LINE_W))
                      or (rr2 >= CREASE_R * CREASE_R and rr2 < (CREASE_R + LINE_W) * (CREASE_R + LINE_W)) then
                    ring_c <= "10";
                else
                    ring_c <= "00";
                end if;
            end if;
        end process;

    -- 邊牆、球門、中線在 S1 就算好, 比分在 S2, 補到和圓形判斷 (S4) 同一級
    fld_pad: entity work.delay_line
        generic map ( WIDTH => 4, DEPTH => 3 )
        port map ( CLK => CLK, din => fld1, dout => fld4 );

    dig_pad: entity work.delay_line
        generic map ( WIDTH => 2, DEPTH => 2 )
        port map ( CLK => CLK, din => dig2, dout => dig4 );

    flash_l <= goal_l and blink;
    flash_r <= goal_r and blink;

    rgb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if puck_c = "01" then
                    rgb_r <= C_PUCK;
                elsif puck_c = "10" then
                    rgb_r <= C_PUCK_RIM;
                elsif pm_c /= "00" then
                    rgb_r <= P_COLOR(to_integer(unsigned(pm_c)));
                elsif cm_c /= "00" then
                    rgb_r <= C_COLOR(to_integer(unsigned(cm_c)));
                elsif dig4(1) = '1' then
                    rgb_r <= C_DIG_P;
                elsif dig4(0) = '1' then
                    rgb_r <= C_DIG_C;
                elsif fld4(2) = '1' then
                    if flash_l = '1' then
                        rgb_r <= x"FFF";
                    else
                        rgb_r <= x"000";
                    end if;
                elsif fld4(1) = '1' then
                    if flash_r = '1' then
                        rgb_r <= x"FFF";
                    else
                        rgb_r <= x"000";
                    end if;
                elsif fld4(3) = '1' then
                    rgb_r <= C_WALL;
                elsif fld4(0) = '1' or ring_c = "01" then
                    rgb_r <= C_LINE;
                elsif ring_c = "10" then
                    rgb_r <= C_CREASE;
                else
                    rgb_r <= C_TABLE;
                end if;
            end if;
        end process;

    rgb <= rgb_r;
end Behavioral;
