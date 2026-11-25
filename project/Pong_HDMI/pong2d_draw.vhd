----------------------------------------------------------------------------------
-- Module Name: pong2d_draw - Behavioral
-- Description: 2D 乒乓的畫面: 上方比分列、上下牆、中線虛線、左右球拍、圓球, 延遲 LAT_2D 拍
--   x, y 是 vga_timing 已暫存的掃描座標; 狀態由 pong2d_ctrl 在遮沒期間更新, 掃描時都不變
--   P1 (左, 橘) / 右邊 (青) 的球拍和比分同色, 一眼看得出誰是誰
--   S1 比較座標 (各區塊旗標), S2 圓球與 7 段數字, S3 依優先順序選顏色
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
           pl_y    : in  signed (11 downto 0);
           pr_y    : in  signed (11 downto 0);
           ball_x  : in  signed (11 downto 0);
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

    constant C_BAR   : rgb_type := x"001";
    constant C_FIELD : rgb_type := x"013";
    constant C_WALL  : rgb_type := x"9AB";
    constant C_MID   : rgb_type := x"357";
    constant C_P1    : rgb_type := x"F73";
    constant C_P2    : rgb_type := x"3CF";
    constant C_BALL  : rgb_type := x"FFF";

    -- 旗標位置
    constant F_BAR  : integer := 0;
    constant F_WALL : integer := 1;
    constant F_MID  : integer := 2;
    constant F_PADL : integer := 3;
    constant F_PADR : integer := 4;

    signal px, py      : signed (11 downto 0);
    signal fy          : unsigned (11 downto 0);                   -- 球場內的 y, 給中線虛線用
    signal flag1       : STD_LOGIC_VECTOR (4 downto 0);
    signal flag2       : STD_LOGIC_VECTOR (4 downto 0);
    signal bdx, bdy    : signed (12 downto 0);                     -- 相對球心, 2 倍座標要多 1 bit
    signal near_b      : STD_LOGIC;                                -- 在球的外框內, 才值得算平方
    signal sxl, sxr    : unsigned (10 downto 0);
    signal sy          : unsigned (10 downto 0);
    signal win_l, win_r : STD_LOGIC;
    signal show_l      : STD_LOGIC;
    signal show_r      : STD_LOGIC;
    signal show_b      : STD_LOGIC;

    signal ball2       : STD_LOGIC;
    signal dig2        : STD_LOGIC_VECTOR (1 downto 0);            -- 左, 右比分
    signal rgb_r       : rgb_type;
begin
    px <= signed('0' & x);
    py <= signed('0' & y);
    fy <= unsigned(py - FY0);

    ---------------------------------------------------------------- S1
    flag1_reg: process(CLK, RST)
        begin
            if RST = '0' then
                flag1 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                flag1 <= (others => '0');
                if py < FY0 - WALL_T then
                    flag1(F_BAR) <= '1';
                end if;
                if (py >= FY0 - WALL_T and py < FY0) or (py >= FY1 and py < FY1 + WALL_T) then
                    flag1(F_WALL) <= '1';
                end if;
                -- 虛線: 每 32 行畫 16 行
                if px >= SCR_W / 2 - 4 and px < SCR_W / 2 + 4 and py >= FY0 and py < FY1 and fy(4) = '0' then
                    flag1(F_MID) <= '1';
                end if;
                if px >= PL_X and px < PL_X + PAD_W and py >= pl_y and py < pl_y + PAD_H then
                    flag1(F_PADL) <= '1';
                end if;
                if px >= PR_X and px < PR_X + PAD_W and py >= pr_y and py < pr_y + PAD_H then
                    flag1(F_PADR) <= '1';
                end if;
            end if;
        end process;

    -- 球心在外框左上角 + (7.5, 7.5); 用 2 倍座標算才不會有半像素
    bdx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bdx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                bdx <= shift_left(resize(px - ball_x, 13), 1) - (BALL_S - 1);
            end if;
        end process;

    bdy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bdy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                bdy <= shift_left(resize(py - ball_y, 13), 1) - (BALL_S - 1);
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
    near_b <= '1' when bdx > -BALL_S and bdx < BALL_S and bdy > -BALL_S and bdy < BALL_S else '0';

    -- 2 倍座標下半徑 16: bdx^2 + bdy^2 < 256 就是直徑 16 的圓
    ball2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ball2 <= '0';
            elsif CLK'event and CLK = '1' then
                if near_b = '1' and bdx(5 downto 0) * bdx(5 downto 0) + bdy(5 downto 0) * bdy(5 downto 0) < 256 then
                    ball2 <= '1';
                else
                    ball2 <= '0';
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

    rgb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if dig2(1) = '1' then
                    rgb_r <= C_P1;
                elsif dig2(0) = '1' then
                    rgb_r <= C_P2;
                elsif ball2 = '1' and show_b = '1' then
                    rgb_r <= C_BALL;
                elsif flag2(F_PADL) = '1' then
                    rgb_r <= C_P1;
                elsif flag2(F_PADR) = '1' then
                    rgb_r <= C_P2;
                elsif flag2(F_WALL) = '1' then
                    rgb_r <= C_WALL;
                elsif flag2(F_MID) = '1' then
                    rgb_r <= C_MID;
                elsif flag2(F_BAR) = '1' then
                    rgb_r <= C_BAR;
                else
                    rgb_r <= C_FIELD;
                end if;
            end if;
        end process;

    rgb <= rgb_r;
end Behavioral;
