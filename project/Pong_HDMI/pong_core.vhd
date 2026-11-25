----------------------------------------------------------------------------------
-- Module Name: pong_core - Behavioral
-- Description: 螢幕乒乓的核心, 全部跑在 65 MHz 像素時脈 CLK 上 (1024x768 @ 60 Hz)
--   和 pong_top 分開, testbench 才能直接給像素時脈, 不用模擬 MMCM
--   sw / ctrl 是非同步輸入, 先經 2 級 FF 同步: sw(0) = 3D, sw(1) = 雙人 (2D), sw(2) = 電腦困難
--   2D / 3D 的遊戲邏輯各自保留狀態, 沒選到的那個凍結; 畫面依 sw(0) 選一個輸出
--   兩個繪圖器延遲不同 (LAT_2D / LAT_3D), 都補到 RENDER_LAT, hs / vs / de 也延遲同樣拍數
--   GAME_TICKS: 每個 frame 讓遊戲走幾步, 上板是 1; 模擬擷取畫面時調大, 少跑幾個 frame 就能看到球飛到半路
--   status: 0 = 3D, 1 = 雙人, 2 = 暫停, 3 = 等待發球, 4 = 比賽結束
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.vga_pkg.all;
use work.pong_pkg.all;

entity pong_core is
    Generic ( GAME_TICKS : integer := 1 );
    Port ( CLK    : in  STD_LOGIC;
           RST    : in  STD_LOGIC;
           sw     : in  STD_LOGIC_VECTOR (2 downto 0);
           ctrl   : in  ctrl_type;
           vga_r  : out STD_LOGIC_VECTOR (3 downto 0);
           vga_g  : out STD_LOGIC_VECTOR (3 downto 0);
           vga_b  : out STD_LOGIC_VECTOR (3 downto 0);
           vga_hs : out STD_LOGIC;
           vga_vs : out STD_LOGIC;
           de     : out STD_LOGIC;
           status : out STD_LOGIC_VECTOR (4 downto 0));
end pong_core;

architecture Behavioral of pong_core is
    constant LAT_2D     : integer := 3;
    constant LAT_3D     : integer := 5;
    constant RENDER_LAT : integer := 5;
    constant RES_1024   : STD_LOGIC_VECTOR (1 downto 0) := "10";   -- vga_pkg.TIMINGS 的 1024x768

    signal in_meta, in_sync : STD_LOGIC_VECTOR (9 downto 0);
    signal mode3d, two_p    : STD_LOGIC;
    signal hard             : STD_LOGIC;
    signal ctrl_s           : ctrl_type;
    signal en2d             : STD_LOGIC;

    signal x, y             : coord_type;
    signal active           : STD_LOGIC;
    signal hs, vs           : STD_LOGIC;
    signal frame_tick       : STD_LOGIC;
    signal h_size, v_size   : coord_type;

    signal tk_cnt           : unsigned (4 downto 0);
    signal tk_left          : integer range 0 to GAME_TICKS;
    signal game_tick        : STD_LOGIC;

    -- 2D
    signal pl_y, pr_y       : signed (11 downto 0);
    signal b2x, b2y         : signed (11 downto 0);
    signal b2_on            : STD_LOGIC;
    signal sc_l, sc_r       : unsigned (2 downto 0);
    signal gph2             : gphase_type;
    signal paused2, blink2  : STD_LOGIC;

    -- 3D
    signal b3x, b3y         : signed (11 downto 0);
    signal b3z              : unsigned (9 downto 0);
    signal pad_x, pad_y     : signed (11 downto 0);
    signal cpu_x, cpu_y     : signed (11 downto 0);
    signal b3_on            : STD_LOGIC;
    signal sc_p, sc_c       : unsigned (2 downto 0);
    signal p_scored         : STD_LOGIC;
    signal gph3             : gphase_type;
    signal paused3, blink3  : STD_LOGIC;

    signal rgb2d, rgb2d_d   : rgb_type;
    signal rgb3d            : rgb_type;
    signal rgb_mux          : rgb_type;
    signal sync_in, sync_d  : STD_LOGIC_VECTOR (2 downto 0);       -- hs, vs, active
    signal rgb_out          : rgb_type;
    signal hs_o, vs_o, de_o : STD_LOGIC;
    signal gph_sel          : gphase_type;
    signal paused_sel       : STD_LOGIC;
begin
    sync_meta: process(CLK, RST)
        begin
            if RST = '0' then
                in_meta <= (others => '0');
            elsif CLK'event and CLK = '1' then
                in_meta <= ctrl & sw;
            end if;
        end process;

    sync_reg: process(CLK, RST)
        begin
            if RST = '0' then
                in_sync <= (others => '0');
            elsif CLK'event and CLK = '1' then
                in_sync <= in_meta;
            end if;
        end process;

    mode3d <= in_sync(0);
    two_p  <= in_sync(1);
    hard   <= in_sync(2);
    ctrl_s <= in_sync(9 downto 3);
    en2d   <= not mode3d;

    timing: entity work.vga_timing
        port map ( CLK        => CLK,
                   RST        => RST,
                   res_sel    => RES_1024,
                   x          => x,
                   y          => y,
                   active     => active,
                   hs         => hs,
                   vs         => vs,
                   frame_tick => frame_tick,
                   h_size     => h_size,
                   v_size     => v_size );

    ---------------------------------------------------------------- 遊戲步進
    -- frame_tick 本身算第 1 步; 其餘 GAME_TICKS - 1 步每隔 STEP_CLKS 個 CLK 補一次, 全都落在垂直遮沒內
    tk_cnt_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tk_cnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    tk_cnt <= (others => '0');
                else
                    tk_cnt <= tk_cnt + 1;
                end if;
            end if;
        end process;

    tk_left_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tk_left <= 0;
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    tk_left <= GAME_TICKS - 1;
                elsif tk_cnt = STEP_CLKS - 1 and tk_left /= 0 then
                    tk_left <= tk_left - 1;
                end if;
            end if;
        end process;

    game_tick <= '1' when frame_tick = '1' or (tk_cnt = STEP_CLKS - 1 and tk_left /= 0) else '0';

    ---------------------------------------------------------------- 2D
    ctrl2d: entity work.pong2d_ctrl
        port map ( CLK     => CLK,
                   RST     => RST,
                   tick    => game_tick,
                   enable  => en2d,
                   two_p   => two_p,
                   hard    => hard,
                   ctrl    => ctrl_s,
                   pl_y    => pl_y,
                   pr_y    => pr_y,
                   ball_x  => b2x,
                   ball_y  => b2y,
                   ball_on => b2_on,
                   score_l => sc_l,
                   score_r => sc_r,
                   gphase  => gph2,
                   paused  => paused2,
                   blink   => blink2 );

    draw2d: entity work.pong2d_draw
        port map ( CLK     => CLK,
                   RST     => RST,
                   x       => x,
                   y       => y,
                   pl_y    => pl_y,
                   pr_y    => pr_y,
                   ball_x  => b2x,
                   ball_y  => b2y,
                   ball_on => b2_on,
                   score_l => sc_l,
                   score_r => sc_r,
                   paused  => paused2,
                   blink   => blink2,
                   rgb     => rgb2d );

    ---------------------------------------------------------------- 3D
    ctrl3d: entity work.pong3d_ctrl
        port map ( CLK      => CLK,
                   RST      => RST,
                   tick     => game_tick,
                   enable   => mode3d,
                   hard     => hard,
                   ctrl     => ctrl_s,
                   ball_x   => b3x,
                   ball_y   => b3y,
                   ball_z   => b3z,
                   pad_x    => pad_x,
                   pad_y    => pad_y,
                   cpu_x    => cpu_x,
                   cpu_y    => cpu_y,
                   ball_on  => b3_on,
                   score_p  => sc_p,
                   score_c  => sc_c,
                   p_scored => p_scored,
                   gphase   => gph3,
                   paused   => paused3,
                   blink    => blink3 );

    draw3d: entity work.pong3d_draw
        port map ( CLK      => CLK,
                   RST      => RST,
                   x        => x,
                   y        => y,
                   ball_x   => b3x,
                   ball_y   => b3y,
                   ball_z   => b3z,
                   pad_x    => pad_x,
                   pad_y    => pad_y,
                   cpu_x    => cpu_x,
                   cpu_y    => cpu_y,
                   ball_on  => b3_on,
                   score_p  => sc_p,
                   score_c  => sc_c,
                   p_scored => p_scored,
                   gphase   => gph3,
                   paused   => paused3,
                   blink    => blink3,
                   rgb      => rgb3d );

    ---------------------------------------------------------------- 對齊與輸出
    dly2d: entity work.delay_line
        generic map ( WIDTH => 12, DEPTH => RENDER_LAT - LAT_2D )
        port map ( CLK => CLK, din => rgb2d, dout => rgb2d_d );

    -- 3D 已經是 RENDER_LAT, 不用補
    mux_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_mux <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if mode3d = '1' then
                    rgb_mux <= rgb3d;
                else
                    rgb_mux <= rgb2d_d;
                end if;
            end if;
        end process;

    -- + 1 是 mux_reg
    sync_in <= hs & vs & active;
    dly_sync: entity work.delay_line
        generic map ( WIDTH => 3, DEPTH => RENDER_LAT + 1 )
        port map ( CLK => CLK, din => sync_in, dout => sync_d );

    -- 遮沒期間一定要輸出黑色, 螢幕靠它量黑色準位
    rgb_out_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_out <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if sync_d(0) = '1' then
                    rgb_out <= rgb_mux;
                else
                    rgb_out <= (others => '0');
                end if;
            end if;
        end process;

    hs_o_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hs_o <= '0';
            elsif CLK'event and CLK = '1' then
                hs_o <= sync_d(2);
            end if;
        end process;

    vs_o_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vs_o <= '0';
            elsif CLK'event and CLK = '1' then
                vs_o <= sync_d(1);
            end if;
        end process;

    de_o_reg: process(CLK, RST)
        begin
            if RST = '0' then
                de_o <= '0';
            elsif CLK'event and CLK = '1' then
                de_o <= sync_d(0);
            end if;
        end process;

    vga_r  <= rgb_out(11 downto 8);
    vga_g  <= rgb_out(7 downto 4);
    vga_b  <= rgb_out(3 downto 0);
    vga_hs <= hs_o;
    vga_vs <= vs_o;
    de     <= de_o;

    gph_sel    <= gph3 when mode3d = '1' else gph2;
    paused_sel <= paused3 when mode3d = '1' else paused2;

    status(0) <= mode3d;
    status(1) <= two_p and not mode3d;
    status(2) <= paused_sel;
    status(3) <= '1' when gph_sel = GP_SERVE else '0';
    status(4) <= '1' when gph_sel = GP_OVER else '0';
end Behavioral;
