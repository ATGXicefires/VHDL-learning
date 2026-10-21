----------------------------------------------------------------------------------
-- Module Name: vga_top - Behavioral
-- Description: HW3 VGA 掃描 - 螢幕顯示 R/G/B 三個色塊, 位置和大小可用按鈕任意調整
--   目標板: E-Elements EGO-XZ7 (xc7z020clg484-1, sys_clk = 100 MHz)
--   板上沒有 VGA 接頭, 要自製電阻 DAC 轉接 (接法見 vga_screen.xdc)
--
--   開關 (腳位見 vga_screen.xdc):
--     SW7     = RST (撥上 = 運作, 撥下 = 重置)
--     SW6     = depth   (保留)
--     SW5     = variant 0 = 空心, 1 = 實心
--     SW4..2  = mode    000 = RGB 色塊
--     SW1..0  = res_sel 00 = 640x480@60, 01 = 800x600@60, 10 = 1024x768@60, 11 = 1280x1024@60
--   按鈕:
--     BTNC 依序切換編輯對象: R移動 -> R縮放 -> G移動 -> G縮放 -> B移動 -> B縮放
--     BTNU/D/L/R 移動或縮放 (按住持續變化)
--   LED:
--     LD0 = MMCM locked, LD1..3 = 編輯中的色塊 R/G/B, LD4 = 縮放模式
--
--   OUT_BITS: 每色實際接出的位元數 (4 或 1)
--     port 宣告成 (3 downto 4 - OUT_BITS), 1 bit 版只剩 MSB, 才能在 PL 腳不夠時只接 5 支腳
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

entity vga_top is
    Generic ( OUT_BITS : integer := 4 );
    Port ( CLK     : in  STD_LOGIC;
           RST     : in  STD_LOGIC;
           res_sel : in  STD_LOGIC_VECTOR (1 downto 0);
           mode    : in  STD_LOGIC_VECTOR (2 downto 0);
           variant : in  STD_LOGIC;
           depth   : in  STD_LOGIC;
           btn_c   : in  STD_LOGIC;
           btn_u   : in  STD_LOGIC;
           btn_d   : in  STD_LOGIC;
           btn_l   : in  STD_LOGIC;
           btn_r   : in  STD_LOGIC;
           led     : out STD_LOGIC_VECTOR (7 downto 0);
           vga_r   : out STD_LOGIC_VECTOR (3 downto 4 - OUT_BITS);
           vga_g   : out STD_LOGIC_VECTOR (3 downto 4 - OUT_BITS);
           vga_b   : out STD_LOGIC_VECTOR (3 downto 4 - OUT_BITS);
           vga_hs  : out STD_LOGIC;
           vga_vs  : out STD_LOGIC);
end vga_top;

architecture Behavioral of vga_top is
    signal pix_clk  : STD_LOGIC;
    signal locked   : STD_LOGIC;
    signal core_rst : STD_LOGIC;
    signal sw       : STD_LOGIC_VECTOR (6 downto 0);
    signal btn      : STD_LOGIC_VECTOR (4 downto 0);
    signal r4, g4, b4 : STD_LOGIC_VECTOR (3 downto 0);
    signal status   : STD_LOGIC_VECTOR (6 downto 0);
begin
    clocks: entity work.clk_gen
        port map ( CLK     => CLK,
                   res_sel => res_sel,
                   pix_clk => pix_clk,
                   locked  => locked );

    -- MMCM 鎖定前像素時脈不穩, 讓核心保持重置
    core_rst <= RST and locked;

    sw  <= depth & variant & mode & res_sel;
    btn <= btn_r & btn_l & btn_d & btn_u & btn_c;

    core: entity work.vga_core
        port map ( CLK    => pix_clk,
                   RST    => core_rst,
                   sw     => sw,
                   btn    => btn,
                   vga_r  => r4,
                   vga_g  => g4,
                   vga_b  => b4,
                   vga_hs => vga_hs,
                   vga_vs => vga_vs,
                   de     => open,
                   status => status );

    vga_r <= r4(3 downto 4 - OUT_BITS);
    vga_g <= g4(3 downto 4 - OUT_BITS);
    vga_b <= b4(3 downto 4 - OUT_BITS);

    led <= status & locked;
end Behavioral;
