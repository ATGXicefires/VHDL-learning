----------------------------------------------------------------------------------
-- Module Name: pong_top - Behavioral
-- Description: 螢幕乒乓 (2D / 3D 球桌), 經板上 HDMI (J12, U12 = ADV7511) 輸出 1024x768 @ 60 Hz
--   HDMI 的部分 (hdmi_422 轉 YCbCr 4:2:2、adv7511_cfg 走 I2C 設定晶片、ODDR 轉送像素時脈、
--     設定成功前影像腳高阻抗) 照抄 ../VGA_Screen/hdmi/hdmi_top, 那一版已經上板驗證過
--   開關: SW7 = RST (上 = 運作), SW0 = 3D, SW1 = 雙人 (2D), SW2 = 電腦困難
--   按鈕先轉成控制向量 ctrl (見 pong_pkg); 將來接鍵盤時, 把鍵盤解出來的 ctrl 和這裡的 OR 起來就好
--     雙人時右拍用 BTNR = 上、BTNL = 下 (2D 用不到左右, 和 3D 的左右共用按鈕)
--   LED: LD0 MMCM 鎖定, LD1 3D, LD2 雙人, LD3 暫停, LD4 等待發球, LD5 比賽結束,
--        LD6 ADV7511 設定完成 (I2C 都有 ACK), LD7 偵測到 HDMI 螢幕 (HPD)
--
--   CLK_INVERT: 把轉送給 ADV7511 的像素時脈反相; 畫面有雜點或閃爍時才改成 true
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use work.pong_pkg.all;

library UNISIM;
use UNISIM.vcomponents.all;

entity pong_top is
    Generic ( CLK_INVERT : boolean := false );
    Port ( CLK      : in    STD_LOGIC;
           RST      : in    STD_LOGIC;
           sw_3d    : in    STD_LOGIC;
           sw_2p    : in    STD_LOGIC;
           sw_hard  : in    STD_LOGIC;
           btn_c    : in    STD_LOGIC;
           btn_u    : in    STD_LOGIC;
           btn_d    : in    STD_LOGIC;
           btn_l    : in    STD_LOGIC;
           btn_r    : in    STD_LOGIC;
           led      : out   STD_LOGIC_VECTOR (7 downto 0);
           hdmi_clk : out   STD_LOGIC;
           hdmi_d   : out   STD_LOGIC_VECTOR (15 downto 0);
           hdmi_de  : out   STD_LOGIC;
           hdmi_hs  : out   STD_LOGIC;
           hdmi_vs  : out   STD_LOGIC;
           hdmi_scl : out   STD_LOGIC;
           hdmi_sda : inout STD_LOGIC);
end pong_top;

architecture Behavioral of pong_top is
    signal pix_clk    : STD_LOGIC;
    signal locked     : STD_LOGIC;
    signal core_rst   : STD_LOGIC;
    signal sw         : STD_LOGIC_VECTOR (2 downto 0);
    signal ctrl       : ctrl_type;
    signal r4, g4, b4 : STD_LOGIC_VECTOR (3 downto 0);
    signal hs, vs, de : STD_LOGIC;
    signal status     : STD_LOGIC_VECTOR (4 downto 0);
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
    clocks: entity work.clk65
        port map ( CLK     => CLK,
                   pix_clk => pix_clk,
                   locked  => locked );

    -- MMCM 鎖定前像素時脈不穩, 讓核心保持重置
    core_rst <= RST and locked;

    sw <= sw_hard & sw_2p & sw_3d;

    ctrl(K_C)    <= btn_c;
    ctrl(K_UP)   <= btn_u;
    ctrl(K_DN)   <= btn_d;
    ctrl(K_LT)   <= btn_l;
    ctrl(K_RT)   <= btn_r;
    ctrl(K_P2UP) <= btn_r;
    ctrl(K_P2DN) <= btn_l;

    core: entity work.pong_core
        port map ( CLK    => pix_clk,
                   RST    => core_rst,
                   sw     => sw,
                   ctrl   => ctrl,
                   vga_r  => r4,
                   vga_g  => g4,
                   vga_b  => b4,
                   vga_hs => hs,
                   vga_vs => vs,
                   de     => de,
                   status => status );

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

    -- 用 ODDR 轉送時脈: 和資料一樣從 IOB 出去, 兩者的延遲才會一致
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

    led <= hpd & cfg_ok & status(4 downto 1) & status(0) & locked;
end Behavioral;
