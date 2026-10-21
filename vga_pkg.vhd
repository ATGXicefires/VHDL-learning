----------------------------------------------------------------------------------
-- Package Name: vga_pkg
-- Description: HW3 VGA 掃描共用定義 (時序表、管線延遲、色彩格式、按鈕編號)
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

package vga_pkg is
    -- sync 區間為 [sync_start, sync_end), 都是從 0 起算的計數值
    type timing_type is record
        h_active, h_sync_start, h_sync_end, h_total : integer;
        v_active, v_sync_start, v_sync_end, v_total : integer;
        sync_pol : STD_LOGIC;                                      -- sync 脈衝期間的電位
    end record;

    type timing_table is array (0 to 3) of timing_type;

    -- 索引 = res_sel, 數值取自 VESA DMT; 這 4 個模式的 H/V 極性剛好相同
    constant TIMINGS : timing_table := (
        (640,  656,  752,  800,  480,  490,  492,  525,  '0'),     -- 25.000 MHz
        (800,  840,  968,  1056, 600,  601,  605,  628,  '1'),     -- 40.000 MHz
        (1024, 1048, 1184, 1344, 768,  771,  777,  806,  '0'),     -- 65.000 MHz
        (1280, 1328, 1440, 1688, 1024, 1025, 1028, 1066, '1'));    -- 108.33 MHz

    subtype coord_type is STD_LOGIC_VECTOR (10 downto 0);
    type coord3_type is array (0 to 2) of coord_type;

    subtype rgb_type is STD_LOGIC_VECTOR (11 downto 0);           -- R(11..8) G(7..4) B(3..0)

    -- 所有繪圖器都補齊到這個延遲, 切換模式時 hs/vs 不用跟著改延遲
    constant RENDER_LAT : integer := 16;
    constant LAT_BLOCKS : integer := 2;
    constant LAT_BARS   : integer := 2;

    constant BTN_C : integer := 0;
    constant BTN_U : integer := 1;
    constant BTN_D : integer := 2;
    constant BTN_L : integer := 3;
    constant BTN_R : integer := 4;
end vga_pkg;
