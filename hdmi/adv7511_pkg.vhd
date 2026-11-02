----------------------------------------------------------------------------------
-- Package Name: adv7511_pkg
-- Description: HDMI 版 - 板上 U12 (ADV7511) 的 I2C 位址、初始化表與 CSC 係數
--   adv7511_cfg 依序寫入 INIT_TABLE; testbench 的 ADV7511 模型與 tools/sim.py 也讀這裡的 CSC_COEF
--   數值取自 ADI Linux 驅動 (adv7511_drv.c) 與 ZedBoard 的 device tree (zynq-zed-adv7511.dtsi),
--   ADI 用同一組設定在 ZedBoard 的 ADV7511 上驗證過
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

package adv7511_pkg is
    constant ADV_ADDR_W : STD_LOGIC_VECTOR (7 downto 0) := x"72";
    constant ADV_ADDR_R : STD_LOGIC_VECTOR (7 downto 0) := x"73";
    constant REG_STATUS : STD_LOGIC_VECTOR (7 downto 0) := x"42";
    constant HPD_BIT    : integer := 6;                            -- REG_STATUS 裡的 HPD

    type reg_write_type is record
        reg, val : STD_LOGIC_VECTOR (7 downto 0);
    end record;

    type reg_list_type is array (natural range <>) of reg_write_type;

    constant INIT_TABLE : reg_list_type := (
        -- HPD 一律當成 high: 沒插螢幕也能設定, 拔插螢幕時晶片也不會自己把設定清掉
        (x"D6", x"C0"),
        (x"41", x"10"),                                            -- 解除 power down
        -- ADI 規定的固定值 (驅動裡的 adv7511_fixed_registers)
        (x"98", x"03"), (x"9A", x"E0"), (x"9C", x"30"), (x"9D", x"61"), (x"A2", x"A4"),
        (x"A3", x"A4"), (x"E0", x"D0"), (x"F9", x"00"), (x"55", x"02"),
        -- 輸入 16 bit YCbCr 4:2:2 + 分離式 sync、每色 8 bit、style 1、right justified、SDR 時脈不延遲;
        -- 輸出 RGB 4:4:4 (ZedBoard 只接了 16 支資料線, 所以和 ADI 一樣送 4:2:2)
        (x"15", x"01"), (x"16", x"38"), (x"48", x"08"), (x"D0", x"0C"), (x"BA", x"60"),
        -- DVI 模式: 不送 infoframe, 電腦螢幕和電視都收
        (x"AF", x"14"),
        -- CSC 係數 (= CSC_COEF), 0x18 bit 7 = 啟用, bit 6..5 = x4;
        -- 先開 update mode (0x1A bit 5) 再寫, 最後關掉時 24 個暫存器才一起生效
        (x"1A", x"24"),
        (x"18", x"C7"), (x"19", x"34"), (x"1B", x"AD"), (x"1C", x"00"), (x"1D", x"00"),
        (x"1E", x"1C"), (x"1F", x"1B"), (x"20", x"1D"), (x"21", x"DC"), (x"22", x"04"),
        (x"23", x"AD"), (x"24", x"1F"), (x"25", x"24"), (x"26", x"01"), (x"27", x"35"),
        (x"28", x"00"), (x"29", x"00"), (x"2A", x"04"), (x"2B", x"AD"), (x"2C", x"08"),
        (x"2D", x"7C"), (x"2E", x"1B"), (x"2F", x"77"),
        (x"1A", x"04"));

    -- BT.709 limited YCbCr -> full RGB (驅動裡的 adv7511_csc_ycbcr_to_rgb), 13 bit 二補數
    -- 每列 4 個 = Cr、Y、Cb 的係數與常數項, 依序是 R、G、B 三列; 以 8 bit 來看:
    --   輸出 = (Cr x A1 + Y x A2 + Cb x A3) / 1024 + A4 / 4
    type csc_type is array (0 to 11) of integer;
    constant CSC_COEF : csc_type := (
        1844, 1197,     0,  -997,
        -548, 1197,  -220,   309,
           0, 1197,  2172, -1161);
end adv7511_pkg;
