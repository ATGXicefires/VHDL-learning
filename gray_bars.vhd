----------------------------------------------------------------------------------
-- Module Name: gray_bars - Behavioral
-- Description: HW3 bonus R/G/B 灰階, 畫面分成上下 5 條 (延遲 LAT_BARS 拍)
--   第 0 條: 8 色純色條 (白 黃 青 綠 洋紅 紅 藍 黑), 1 bit 也畫得出來
--   第 1~4 條: R / G / B / 灰 由左到右 16 階漸層
--   depth = 1 bit 時由 vga_core 做 Bayer 抖動, 一樣看得出 16 階
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;
use work.vga_pkg.all;

entity gray_bars is
    Port ( CLK     : in  STD_LOGIC;
           RST     : in  STD_LOGIC;
           res_sel : in  STD_LOGIC_VECTOR (1 downto 0);
           x       : in  coord_type;
           y       : in  coord_type;
           rgb     : out rgb_type);
end gray_bars;

architecture Behavioral of gray_bars is
    -- 640 / 16 等寬度不是 2 的冪次, 改乘倒數再取高位元來代替除法:
    --   KX = ceil(16 * 2^20 / h_active), KY = ceil(5 * 2^20 / v_active)
    -- 取 ceil 是為了讓剛好落在邊界上的像素歸到右邊/下面那一階
    type k_table is array (0 to 3) of integer;
    constant KX : k_table := (26215, 20972, 16384, 13108);
    constant KY : k_table := (10923, 8739, 6827, 5120);

    signal kx_sel         : STD_LOGIC_VECTOR (14 downto 0);
    signal ky_sel         : STD_LOGIC_VECTOR (13 downto 0);
    signal prod_x         : STD_LOGIC_VECTOR (25 downto 0);
    signal prod_y         : STD_LOGIC_VECTOR (24 downto 0);
    signal level          : STD_LOGIC_VECTOR (3 downto 0);
    signal band           : STD_LOGIC_VECTOR (2 downto 0);
    signal bar_color      : rgb_type;
    signal rgb_r          : rgb_type;
begin
    kx_sel <= conv_std_logic_vector(KX(conv_integer(res_sel)), 15);
    ky_sel <= conv_std_logic_vector(KY(conv_integer(res_sel)), 14);

    mul_x: process(CLK, RST)
        begin
            if RST = '0' then
                prod_x <= (others => '0');
            elsif CLK'event and CLK = '1' then
                prod_x <= x * kx_sel;
            end if;
        end process;

    mul_y: process(CLK, RST)
        begin
            if RST = '0' then
                prod_y <= (others => '0');
            elsif CLK'event and CLK = '1' then
                prod_y <= y * ky_sel;
            end if;
        end process;

    level <= prod_x(23 downto 20);
    band  <= prod_y(22 downto 20);

    with level(3 downto 1) select
        bar_color <= x"FFF" when "000",
                     x"FF0" when "001",
                     x"0FF" when "010",
                     x"0F0" when "011",
                     x"F0F" when "100",
                     x"F00" when "101",
                     x"00F" when "110",
                     x"000" when others;

    rgb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                case band is
                    when "000"  => rgb_r <= bar_color;
                    when "001"  => rgb_r <= level & "0000" & "0000";
                    when "010"  => rgb_r <= "0000" & level & "0000";
                    when "011"  => rgb_r <= "0000" & "0000" & level;
                    when others => rgb_r <= level & level & level;
                end case;
            end if;
        end process;

    rgb <= rgb_r;
end Behavioral;
