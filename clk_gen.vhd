----------------------------------------------------------------------------------
-- Module Name: clk_gen - Behavioral
-- Description: HW3 像素時脈產生, 100 MHz -> MMCM -> 25 MHz (640x480@60)
--   直接例化 MMCME2_BASE primitive 而不用 Clocking Wizard IP, git 只需要追蹤這個 .vhd
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

library UNISIM;
use UNISIM.vcomponents.all;

entity clk_gen is
    Port ( CLK     : in  STD_LOGIC;
           pix_clk : out STD_LOGIC;
           locked  : out STD_LOGIC);
end clk_gen;

architecture Behavioral of clk_gen is
    signal clkfb : STD_LOGIC;
    signal clk25 : STD_LOGIC;
begin
    -- VCO = 100 MHz / 4 * 39 = 975 MHz (xc7z020-1 的 VCO 範圍 600 ~ 1200 MHz)
    mmcm: MMCME2_BASE
        generic map ( CLKIN1_PERIOD   => 10.0,
                      DIVCLK_DIVIDE   => 4,
                      CLKFBOUT_MULT_F => 39.0,
                      CLKOUT1_DIVIDE  => 39 )
        port map ( CLKIN1   => CLK,
                   CLKFBIN  => clkfb,
                   CLKFBOUT => clkfb,
                   CLKOUT1  => clk25,
                   LOCKED   => locked,
                   PWRDWN   => '0',
                   RST      => '0' );

    pix_buf: BUFG
        port map ( I => clk25, O => pix_clk );
end Behavioral;
