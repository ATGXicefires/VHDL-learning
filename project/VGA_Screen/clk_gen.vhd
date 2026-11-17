----------------------------------------------------------------------------------
-- Module Name: clk_gen - Behavioral
-- Description: HW3 像素時脈產生, 100 MHz -> MMCM -> 依 res_sel 選 1 個像素時脈
--   res_sel: 00 = 25.000 MHz (640x480), 01 = 40.000 MHz (800x600),
--            10 = 65.000 MHz (1024x768), 11 = 108.33 MHz (1280x1024, 比 VESA 快 0.3%, 在 ±0.5% 容許內)
--   直接例化 MMCME2_BASE primitive 而不用 Clocking Wizard IP, git 只需要追蹤這個 .vhd
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

library UNISIM;
use UNISIM.vcomponents.all;

entity clk_gen is
    Port ( CLK     : in  STD_LOGIC;
           res_sel : in  STD_LOGIC_VECTOR (1 downto 0);
           pix_clk : out STD_LOGIC;
           locked  : out STD_LOGIC);
end clk_gen;

architecture Behavioral of clk_gen is
    signal clkfb                        : STD_LOGIC;
    signal clk25, clk40, clk65, clk108 : STD_LOGIC;
    signal mux_lo, mux_hi              : STD_LOGIC;
begin
    -- VCO = 100 MHz / 4 * 39 = 975 MHz (xc7z020-1 的 VCO 範圍 600 ~ 1200 MHz), 4 個頻率都能整除或用小數除;
    -- 只有 CLKOUT0 支援小數除頻, 所以 975 / 24.375 = 40 MHz 放在 CLKOUT0
    mmcm: MMCME2_BASE
        generic map ( CLKIN1_PERIOD    => 10.0,
                      DIVCLK_DIVIDE    => 4,
                      CLKFBOUT_MULT_F  => 39.0,
                      CLKOUT0_DIVIDE_F => 24.375,
                      CLKOUT1_DIVIDE   => 39,
                      CLKOUT2_DIVIDE   => 15,
                      CLKOUT3_DIVIDE   => 9 )
        port map ( CLKIN1   => CLK,
                   CLKFBIN  => clkfb,
                   CLKFBOUT => clkfb,
                   CLKOUT0  => clk40,
                   CLKOUT1  => clk25,
                   CLKOUT2  => clk65,
                   CLKOUT3  => clk108,
                   LOCKED   => locked,
                   PWRDWN   => '0',
                   RST      => '0' );

    -- BUFGMUX_CTRL 的 S 可以直接接非同步的開關: 它會等新舊時脈都在低電位才切換, 不會產生毛刺
    mux_lo_buf: BUFGMUX_CTRL
        port map ( I0 => clk25, I1 => clk40, S => res_sel(0), O => mux_lo );

    mux_hi_buf: BUFGMUX_CTRL
        port map ( I0 => clk65, I1 => clk108, S => res_sel(0), O => mux_hi );

    mux_out_buf: BUFGMUX_CTRL
        port map ( I0 => mux_lo, I1 => mux_hi, S => res_sel(1), O => pix_clk );
end Behavioral;
