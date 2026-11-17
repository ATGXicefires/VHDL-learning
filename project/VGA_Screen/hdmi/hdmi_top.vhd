----------------------------------------------------------------------------------
-- Module Name: hdmi_top - Behavioral
-- Description: HW3 VGA 掃描的 HDMI 版 - 同一個 bitstream 同時輸出 VGA (JA2 自製 DAC) 與 HDMI (板上 J12)
--   開關、按鈕、畫面都和 vga_top 一樣 (說明見 vga_top.vhd), 展示時哪個接口能用就接哪個
--   板上的 HDMI 由 U12 (ADV7511) 產生: FPGA 送 16 bit YCbCr 4:2:2 + 像素時脈 (hdmi_422),
--     再用 I2C 設定晶片 (adv7511_cfg); 腳位見 hdmi_adv7511.xdc
--   LED: LD0..LD5 和 vga_top 相同, LD6 = ADV7511 設定完成 (I2C 都有 ACK), LD7 = 偵測到 HDMI 螢幕 (HPD)
--
--   CLK_INVERT: 把轉送給 ADV7511 的像素時脈反相; 預設和 ADI 在 ZedBoard 上用的相位相同,
--     畫面有雜點或閃爍時才改成 true
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

library UNISIM;
use UNISIM.vcomponents.all;

entity hdmi_top is
    Generic ( CLK_INVERT : boolean := false );
    Port ( CLK      : in    STD_LOGIC;
           RST      : in    STD_LOGIC;
           res_sel  : in    STD_LOGIC_VECTOR (1 downto 0);
           mode     : in    STD_LOGIC_VECTOR (2 downto 0);
           variant  : in    STD_LOGIC;
           depth    : in    STD_LOGIC;
           btn_c    : in    STD_LOGIC;
           btn_u    : in    STD_LOGIC;
           btn_d    : in    STD_LOGIC;
           btn_l    : in    STD_LOGIC;
           btn_r    : in    STD_LOGIC;
           led      : out   STD_LOGIC_VECTOR (7 downto 0);
           vga_r    : out   STD_LOGIC_VECTOR (3 downto 0);
           vga_g    : out   STD_LOGIC_VECTOR (3 downto 0);
           vga_b    : out   STD_LOGIC_VECTOR (3 downto 0);
           vga_hs   : out   STD_LOGIC;
           vga_vs   : out   STD_LOGIC;
           hdmi_clk : out   STD_LOGIC;
           hdmi_d   : out   STD_LOGIC_VECTOR (15 downto 0);
           hdmi_de  : out   STD_LOGIC;
           hdmi_hs  : out   STD_LOGIC;
           hdmi_vs  : out   STD_LOGIC;
           hdmi_scl : out   STD_LOGIC;
           hdmi_sda : inout STD_LOGIC);
end hdmi_top;

architecture Behavioral of hdmi_top is
    signal pix_clk    : STD_LOGIC;
    signal locked     : STD_LOGIC;
    signal core_rst   : STD_LOGIC;
    signal sw         : STD_LOGIC_VECTOR (6 downto 0);
    signal btn        : STD_LOGIC_VECTOR (4 downto 0);
    signal r4, g4, b4 : STD_LOGIC_VECTOR (3 downto 0);
    signal hs, vs, de : STD_LOGIC;
    signal status     : STD_LOGIC_VECTOR (6 downto 0);
    signal hd         : STD_LOGIC_VECTOR (15 downto 0);
    signal hde        : STD_LOGIC;
    signal hhs, hvs   : STD_LOGIC;
    signal clk_d1     : STD_LOGIC;
    signal clk_d2     : STD_LOGIC;
    signal clk_fwd    : STD_LOGIC;
    signal cfg_ok     : STD_LOGIC;
    signal hpd        : STD_LOGIC;
    signal vid_en     : STD_LOGIC;
begin
    -- 例化名稱要叫 clocks, vga_screen.xdc 的 clock group 才找得到 MMCM
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
                   vga_hs => hs,
                   vga_vs => vs,
                   de     => de,
                   status => status );

    vga_r  <= r4;
    vga_g  <= g4;
    vga_b  <= b4;
    vga_hs <= hs;
    vga_vs <= vs;

    conv: entity work.hdmi_422
        port map ( CLK  => pix_clk,
                   r    => r4,
                   g    => g4,
                   b    => b4,
                   de   => de,
                   hs   => hs,
                   vs   => vs,
                   d    => hd,
                   de_o => hde,
                   hs_o => hhs,
                   vs_o => hvs );

    cfg: entity work.adv7511_cfg
        port map ( CLK    => pix_clk,
                   RST    => core_rst,
                   scl    => hdmi_scl,
                   sda    => hdmi_sda,
                   cfg_ok => cfg_ok,
                   hpd    => hpd,
                   vid_en => vid_en );

    -- 用 ODDR 轉送時脈: 和資料一樣從 IOB 出去, 兩者的延遲才會一致, 也不會把時脈網路拉進一般繞線
    clk_d1 <= '0' when CLK_INVERT else '1';
    clk_d2 <= not clk_d1;

    fwd: ODDR
        generic map ( DDR_CLK_EDGE => "OPPOSITE_EDGE",
                      INIT         => '0',
                      SRTYPE       => "SYNC" )
        port map ( Q  => clk_fwd,
                   C  => pix_clk,
                   CE => '1',
                   D1 => clk_d1,
                   D2 => clk_d2,
                   R  => '0',
                   S  => '0' );

    -- ADV7511 回應之前影像腳都是高阻抗 (見 adv7511_cfg 的說明)
    hdmi_clk <= clk_fwd when vid_en = '1' else 'Z';
    hdmi_d   <= hd      when vid_en = '1' else (others => 'Z');
    hdmi_de  <= hde     when vid_en = '1' else 'Z';
    hdmi_hs  <= hhs     when vid_en = '1' else 'Z';
    hdmi_vs  <= hvs     when vid_en = '1' else 'Z';

    led <= hpd & cfg_ok & status(4 downto 0) & locked;
end Behavioral;
