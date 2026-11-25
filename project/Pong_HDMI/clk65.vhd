----------------------------------------------------------------------------------
-- Module Name: clk65 - Behavioral
-- Description: 100 MHz -> MMCM -> 65 MHz 像素時脈 (1024x768 @ 60 Hz)
--   VGA_Screen 的 clk_gen 要在 4 種解析度間切換, 用了 3 個 BUFGMUX 和 4 個時脈輸出;
--   這裡解析度固定, 只留一個輸出, 也就不用 clock group 約束
--   VCO = 100 MHz / 4 * 39 = 975 MHz (和 clk_gen 相同, 已上板驗證), 975 / 15 = 65 MHz
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

library UNISIM;
use UNISIM.vcomponents.all;

entity clk65 is
    Port ( CLK     : in  STD_LOGIC;
           pix_clk : out STD_LOGIC;
           locked  : out STD_LOGIC);
end clk65;

architecture Behavioral of clk65 is
    signal clkfb  : STD_LOGIC;
    signal clk_u  : STD_LOGIC;
begin
    mmcm: MMCME2_BASE
        generic map ( CLKIN1_PERIOD    => 10.0,
                      DIVCLK_DIVIDE    => 4,
                      CLKFBOUT_MULT_F  => 39.0,
                      CLKOUT0_DIVIDE_F => 15.0 )
        port map ( CLKIN1   => CLK,
                   CLKFBIN  => clkfb,
                   CLKFBOUT => clkfb,
                   CLKOUT0  => clk_u,
                   LOCKED   => locked,
                   PWRDWN   => '0',
                   RST      => '0' );

    buf: BUFG
        port map ( I => clk_u, O => pix_clk );
end Behavioral;
