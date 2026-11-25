----------------------------------------------------------------------------------
-- Module Name: pong2d_draw - Behavioral
-- Description: 2D 側視球桌的畫面: 牆、地板、桌子 (桌面、桌腳)、網子、兩支圓形球拍 (含握把)、球、比分, 延遲 LAT_2D 拍
--   x, y 是 vga_timing 已暫存的掃描座標; 狀態由 pong2d_ctrl 在遮沒期間更新, 掃描時都不變
--   左拍 (P1) 紅、右拍藍, 比分數字同色, 一眼看得出誰是誰
--   S1 比較座標 (固定物件的旗標) 並算出相對球心、拍心的座標, S2 圓形 (平方) 與握把、7 段數字, S3 依優先順序選顏色
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.vga_pkg.all;
use work.pong_pkg.all;

entity pong2d_draw is
    Port ( CLK     : in  STD_LOGIC;
           RST     : in  STD_LOGIC;
           x       : in  coord_type;
           y       : in  coord_type;
           pl_y    : in  signed (11 downto 0);                     -- 拍心
           pr_y    : in  signed (11 downto 0);
           ball_x  : in  signed (11 downto 0);                     -- 球心
           ball_y  : in  signed (11 downto 0);
           ball_on : in  STD_LOGIC;
           score_l : in  unsigned (2 downto 0);
           score_r : in  unsigned (2 downto 0);
           paused  : in  STD_LOGIC;
           blink   : in  STD_LOGIC;
           rgb     : out rgb_type);
end pong2d_draw;

architecture Behavioral of pong2d_draw is
    constant DIG_W : integer := 40;
    constant DIG_H : integer := 72;
    constant SEG_T : integer := 10;
    constant DIG_Y : integer := 16;
    constant DL_X  : integer := SCR_W / 2 - 48 - DIG_W;
    constant DR_X  : integer := SCR_W / 2 + 48;

    constant LEG_W  : integer := 12;
    constant LEG_IN : integer := 40;                               -- 桌腳離桌端多遠
    constant NET_W  : integer := 3;                                -- 網子半寬 (側面看只是一條)
    constant HDL_Y0 : integer := PAD2_R - 6;                       -- 握把從拍面下緣開始
    constant HDL_L  : integer := 48;
    constant HDL_HW : integer := 5;
    constant RIM_R2 : integer := (PAD2_R - 4) * (PAD2_R - 4);
    constant PAD_R2 : integer := PAD2_R * PAD2_R + PAD2_R;         -- 多加 R: 整數圓心時邊緣比較圓
    constant BALL_R2 : integer := RB2 * RB2 + RB2;

    constant C_WALL   : rgb_type := x"123";
    constant C_FLOOR  : rgb_type := x"532";
    constant C_TBL    : rgb_type := x"14A";
    constant C_EDGE   : rgb_type := x"EEF";
    constant C_LEG    : rgb_type := x"333";
    constant C_NET    : rgb_type := x"BBC";
    constant C_NETTOP : rgb_type := x"FFF";
    constant C_P1     : rgb_type := x"E22";
    constant C_P1RIM  : rgb_type := x"811";
    constant C_P2     : rgb_type := x"26E";
    constant C_P2RIM  : rgb_type := x"138";
    constant C_DIG1   : rgb_type := x"F55";
    constant C_DIG2   : rgb_type := x"5AF";
    constant C_HDL    : rgb_type := x"A63";
    constant C_BALL   : rgb_type := x"FE9";

    -- 旗標位置
    constant F_FLOOR  : integer := 0;
    constant F_EDGE   : integer := 1;                              -- 桌面上緣白線
    constant F_TBL    : integer := 2;
    constant F_LEG    : integer := 3;
    constant F_NET    : integer := 4;
    constant F_NETTOP : integer := 5;

    signal px, py      : signed (11 downto 0);
    signal flag1       : STD_LOGIC_VECTOR (5 downto 0);
    signal flag2       : STD_LOGIC_VECTOR (5 downto 0);
    signal bdx, bdy    : signed (11 downto 0);                     -- 相對球心
    signal ldx, ldy    : signed (11 downto 0);                     -- 相對左拍心
    signal rdx, rdy    : signed (11 downto 0);
    signal sxl, sxr    : unsigned (10 downto 0);
    signal sy          : unsigned (10 downto 0);

    signal near_b      : STD_LOGIC;                                -- 在外框內, 才值得算平方
    signal near_l      : STD_LOGIC;
    signal near_r      : STD_LOGIC;
    signal ld2, rd2    : unsigned (13 downto 0);                   -- 到拍心距離的平方
    signal lhy, rhy    : signed (11 downto 0);                     -- 握把上的位置
    signal lhx, rhx    : signed (11 downto 0);                     -- 離握把中線多遠
    signal win_l, win_r : STD_LOGIC;
    signal show_l      : STD_LOGIC;
    signal show_r      : STD_LOGIC;
    signal show_b      : STD_LOGIC;

    signal ball2       : STD_LOGIC;
    signal padl2       : STD_LOGIC_VECTOR (1 downto 0);            -- (拍面, 拍緣)
    signal padr2       : STD_LOGIC_VECTOR (1 downto 0);
    signal hdl2        : STD_LOGIC;
    signal dig2        : STD_LOGIC_VECTOR (1 downto 0);            -- 左, 右比分
    signal rgb_r       : rgb_type;

    function sq7(v : signed (11 downto 0)) return unsigned is
    begin
        return unsigned(v(6 downto 0) * v(6 downto 0));
    end function;
begin
    px <= signed('0' & x);
    py <= signed('0' & y);

    ---------------------------------------------------------------- S1
    flag1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                flag1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                flag1 <= (others => '0');
                if py >= FLOOR2_Y then
                    flag1(F_FLOOR) <= '1';
                end if;
                if px >= TX0 and px < TX1 then
                    if py >= TBL2_Y and py < TBL2_Y + 3 then
                        flag1(F_EDGE) <= '1';
                    end if;
                    if py >= TBL2_Y + 3 and py < TBL2_Y + TBL2_T then
                        flag1(F_TBL) <= '1';
                    end if;
                end if;
                if py >= TBL2_Y + TBL2_T and py < FLOOR2_Y and
                   ((px >= TX0 + LEG_IN and px < TX0 + LEG_IN + LEG_W) or
                    (px >= TX1 - LEG_IN - LEG_W and px < TX1 - LEG_IN)) then
                    flag1(F_LEG) <= '1';
                end if;
                if px >= NET2_X - NET_W and px < NET2_X + NET_W then
                    -- 網子每 4 列空 1 列, 看得出是網而不是一塊板子
                    if py >= TBL2_Y - NET2_H and py < TBL2_Y and y(1 downto 0) /= "11" then
                        flag1(F_NET) <= '1';
                    end if;
                    if py >= TBL2_Y - NET2_H - 4 and py < TBL2_Y - NET2_H then
                        flag1(F_NETTOP) <= '1';
                    end if;
                end if;
            end if;
        end process;

    bdx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bdx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                bdx <= px - ball_x;
            end if;
        end process;

    bdy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bdy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                bdy <= py - ball_y;
            end if;
        end process;

    ldx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ldx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ldx <= px - PL2_X;
            end if;
        end process;

    ldy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ldy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ldy <= py - pl_y;
            end if;
        end process;

    rdx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rdx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                rdx <= px - PR2_X;
            end if;
        end process;

    rdy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rdy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                rdy <= py - pr_y;
            end if;
        end process;

    sxl_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sxl <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sxl <= unsigned(x) - DL_X;
            end if;
        end process;

    sxr_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sxr <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sxr <= unsigned(x) - DR_X;
            end if;
        end process;

    sy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sy <= unsigned(y) - DIG_Y;
            end if;
        end process;

    ---------------------------------------------------------------- S2
    near_b <= '1' when abs(bdx) <= RB2 and abs(bdy) <= RB2 else '0';
    near_l <= '1' when abs(ldx) <= PAD2_R and abs(ldy) <= PAD2_R else '0';
    near_r <= '1' when abs(rdx) <= PAD2_R and abs(rdy) <= PAD2_R else '0';
    ld2    <= sq7(ldx) + sq7(ldy);
    rd2    <= sq7(rdx) + sq7(rdy);

    -- 握把往拍子外側斜下去 (左拍往左下, 右拍往右下): 每往下 2 列, 中線往外移 1
    lhy <= ldy - HDL_Y0;
    rhy <= rdy - HDL_Y0;
    lhx <= ldx + shift_right(lhy, 1);
    rhx <= rdx - shift_right(rhy, 1);

    ball2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ball2 <= '0';
            elsif CLK'event and CLK = '1' then
                if near_b = '1' and sq7(bdx) + sq7(bdy) <= BALL_R2 then
                    ball2 <= '1';
                else
                    ball2 <= '0';
                end if;
            end if;
        end process;

    padl2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                padl2 <= "00";
            elsif CLK'event and CLK = '1' then
                padl2 <= "00";
                if near_l = '1' and ld2 <= PAD_R2 then
                    if ld2 > RIM_R2 then
                        padl2 <= "01";
                    else
                        padl2 <= "10";
                    end if;
                end if;
            end if;
        end process;

    padr2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                padr2 <= "00";
            elsif CLK'event and CLK = '1' then
                padr2 <= "00";
                if near_r = '1' and rd2 <= PAD_R2 then
                    if rd2 > RIM_R2 then
                        padr2 <= "01";
                    else
                        padr2 <= "10";
                    end if;
                end if;
            end if;
        end process;

    hdl2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hdl2 <= '0';
            elsif CLK'event and CLK = '1' then
                if (lhy >= 0 and lhy < HDL_L and abs(lhx) <= HDL_HW) or
                   (rhy >= 0 and rhy < HDL_L and abs(rhx) <= HDL_HW) then
                    hdl2 <= '1';
                else
                    hdl2 <= '0';
                end if;
            end if;
        end process;

    win_l  <= '1' when score_l = WIN else '0';
    win_r  <= '1' when score_r = WIN else '0';
    -- 勝方比分閃爍
    show_l <= not (win_l and blink);
    show_r <= not (win_r and blink);

    dig2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dig2 <= "00";
            elsif CLK'event and CLK = '1' then
                dig2 <= (seg_lit(sxl, sy, DIG_W, DIG_H, SEG_T, score_l) and show_l)
                        & (seg_lit(sxr, sy, DIG_W, DIG_H, SEG_T, score_r) and show_r);
            end if;
        end process;

    flag2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                flag2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                flag2 <= flag1;
            end if;
        end process;

    ---------------------------------------------------------------- S3
    -- 暫停時球閃爍, 不看 LED 也知道停住了
    show_b <= ball_on and not (paused and blink);

    -- 球在最前面 (擊球那一刻球會疊在拍面上), 握把在拍面後面, 網子蓋過桌面
    rgb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if dig2(1) = '1' then
                    rgb_r <= C_DIG1;
                elsif dig2(0) = '1' then
                    rgb_r <= C_DIG2;
                elsif ball2 = '1' and show_b = '1' then
                    rgb_r <= C_BALL;
                elsif padl2(1) = '1' then
                    rgb_r <= C_P1;
                elsif padl2(0) = '1' then
                    rgb_r <= C_P1RIM;
                elsif padr2(1) = '1' then
                    rgb_r <= C_P2;
                elsif padr2(0) = '1' then
                    rgb_r <= C_P2RIM;
                elsif hdl2 = '1' then
                    rgb_r <= C_HDL;
                elsif flag2(F_NETTOP) = '1' then
                    rgb_r <= C_NETTOP;
                elsif flag2(F_NET) = '1' then
                    rgb_r <= C_NET;
                elsif flag2(F_EDGE) = '1' then
                    rgb_r <= C_EDGE;
                elsif flag2(F_TBL) = '1' then
                    rgb_r <= C_TBL;
                elsif flag2(F_LEG) = '1' then
                    rgb_r <= C_LEG;
                elsif flag2(F_FLOOR) = '1' then
                    rgb_r <= C_FLOOR;
                else
                    rgb_r <= C_WALL;
                end if;
            end if;
        end process;

    rgb <= rgb_r;
end Behavioral;
