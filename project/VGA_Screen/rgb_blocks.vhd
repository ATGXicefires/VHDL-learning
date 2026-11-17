----------------------------------------------------------------------------------
-- Module Name: rgb_blocks - Behavioral
-- Description: HW3 基本題, 畫出 R/G/B 三個矩形色塊 (延遲 LAT_BLOCKS 拍)
--   三塊的顏色用 OR 疊加, 交疊處會出現黃/青/洋紅/白 (加色混色)
--   solid = '0' 時只畫 BORDER 寬的外框 (空心)
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;
use work.vga_pkg.all;

entity rgb_blocks is
    Port ( CLK   : in  STD_LOGIC;
           RST   : in  STD_LOGIC;
           x     : in  coord_type;
           y     : in  coord_type;
           blk_x : in  coord3_type;
           blk_y : in  coord3_type;
           blk_w : in  coord3_type;
           blk_h : in  coord3_type;
           solid : in  STD_LOGIC;
           rgb   : out rgb_type);
end rgb_blocks;

architecture Behavioral of rgb_blocks is
    constant BORDER : integer := 4;

    signal in_outer, in_inner : STD_LOGIC_VECTOR (2 downto 0);
    signal hit, hit_r         : STD_LOGIC_VECTOR (2 downto 0);
    signal rgb_r              : rgb_type;
begin
    gen_hit: for i in 0 to 2 generate
        in_outer(i) <= '1' when x >= blk_x(i) and ('0' & x) < ('0' & blk_x(i)) + blk_w(i)
                                and y >= blk_y(i) and ('0' & y) < ('0' & blk_y(i)) + blk_h(i) else '0';
        in_inner(i) <= '1' when ('0' & x) >= ('0' & blk_x(i)) + BORDER
                                and ('0' & x) + BORDER < ('0' & blk_x(i)) + blk_w(i)
                                and ('0' & y) >= ('0' & blk_y(i)) + BORDER
                                and ('0' & y) + BORDER < ('0' & blk_y(i)) + blk_h(i) else '0';
        hit(i) <= in_outer(i) and (solid or not in_inner(i));
    end generate;

    hit_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hit_r <= "000";
            elsif CLK'event and CLK = '1' then
                hit_r <= hit;
            end if;
        end process;

    rgb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                rgb_r(11 downto 8) <= (others => hit_r(0));
                rgb_r(7 downto 4)  <= (others => hit_r(1));
                rgb_r(3 downto 0)  <= (others => hit_r(2));
            end if;
        end process;

    rgb <= rgb_r;
end Behavioral;
