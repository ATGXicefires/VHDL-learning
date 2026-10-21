----------------------------------------------------------------------------------
-- Module Name: vga_core - Behavioral
-- Description: HW3 VGA 掃描核心, 全部跑在像素時脈 CLK 上
--   和 vga_top 分開, 是為了讓 testbench 能直接給像素時脈, 不用模擬 MMCM
--   sw / btn 是非同步輸入, 先經 2 級 FF 同步
--     sw(1..0) = res_sel, sw(4..2) = mode, sw(5) = variant, sw(6) = depth
--     btn 編號見 vga_pkg (BTN_C/U/D/L/R)
--   status(2..0) = 編輯中的色塊 (one-hot R/G/B), status(3) = 縮放模式 (色塊或 2D 圖形)
--   de 只給 testbench 擷取畫面用, 上板不接
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;
use work.vga_pkg.all;

entity vga_core is
    Port ( CLK    : in  STD_LOGIC;
           RST    : in  STD_LOGIC;
           sw     : in  STD_LOGIC_VECTOR (6 downto 0);
           btn    : in  STD_LOGIC_VECTOR (4 downto 0);
           vga_r  : out STD_LOGIC_VECTOR (3 downto 0);
           vga_g  : out STD_LOGIC_VECTOR (3 downto 0);
           vga_b  : out STD_LOGIC_VECTOR (3 downto 0);
           vga_hs : out STD_LOGIC;
           vga_vs : out STD_LOGIC;
           de     : out STD_LOGIC;
           status : out STD_LOGIC_VECTOR (6 downto 0));
end vga_core;

architecture Behavioral of vga_core is
    signal in_meta, in_sync : STD_LOGIC_VECTOR (11 downto 0);
    signal res_sel          : STD_LOGIC_VECTOR (1 downto 0);
    signal mode             : STD_LOGIC_VECTOR (2 downto 0);
    signal variant          : STD_LOGIC;
    signal depth            : STD_LOGIC;
    signal btn_s            : STD_LOGIC_VECTOR (4 downto 0);

    signal x, y           : coord_type;
    signal active         : STD_LOGIC;
    signal hs, vs         : STD_LOGIC;
    signal frame_tick     : STD_LOGIC;
    signal h_size, v_size : coord_type;

    signal blk_x, blk_y, blk_w, blk_h : coord3_type;
    signal edit_sel                   : STD_LOGIC_VECTOR (2 downto 0);
    signal target_led                 : STD_LOGIC_VECTOR (2 downto 0);
    signal shp_cx, shp_cy             : coord_type;
    signal shp_a, shp_b               : STD_LOGIC_VECTOR (8 downto 0);
    signal shp_resize                 : STD_LOGIC;
    signal shp_kind                   : STD_LOGIC_VECTOR (1 downto 0);

    signal rgb_blk, rgb_blk_d   : rgb_type;
    signal rgb_bars, rgb_bars_d : rgb_type;
    signal rgb_shp, rgb_shp_d   : rgb_type;
    signal rgb_mux              : rgb_type;

    -- hs, vs, active, x(1..0), y(1..0) 延遲到和 rgb_mux 同一級
    signal sync_in, sync_d : STD_LOGIC_VECTOR (6 downto 0);

    signal bayer_idx        : STD_LOGIC_VECTOR (3 downto 0);
    signal bayer_t          : STD_LOGIC_VECTOR (3 downto 0);
    signal r_dit, g_dit, b_dit : STD_LOGIC;
    signal rgb_out          : rgb_type;
    signal hs_o, vs_o, de_o : STD_LOGIC;
begin
    sync_meta: process(CLK, RST)
        begin
            if RST = '0' then
                in_meta <= (others => '0');
            elsif CLK'event and CLK = '1' then
                in_meta <= btn & sw;
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

    res_sel <= in_sync(1 downto 0);
    mode    <= in_sync(4 downto 2);
    variant <= in_sync(5);
    depth   <= in_sync(6);
    btn_s   <= in_sync(11 downto 7);

    timing: entity work.vga_timing
        port map ( CLK        => CLK,
                   RST        => RST,
                   res_sel    => res_sel,
                   x          => x,
                   y          => y,
                   active     => active,
                   hs         => hs,
                   vs         => vs,
                   frame_tick => frame_tick,
                   h_size     => h_size,
                   v_size     => v_size );

    ctrl: entity work.btn_ctrl
        port map ( CLK        => CLK,
                   RST        => RST,
                   frame_tick => frame_tick,
                   mode       => mode,
                   btn        => btn_s,
                   h_size     => h_size,
                   v_size     => v_size,
                   blk_x      => blk_x,
                   blk_y      => blk_y,
                   blk_w      => blk_w,
                   blk_h      => blk_h,
                   edit_sel   => edit_sel,
                   res_sel    => res_sel,
                   shp_cx     => shp_cx,
                   shp_cy     => shp_cy,
                   shp_a      => shp_a,
                   shp_b      => shp_b,
                   shp_resize => shp_resize );

    blocks: entity work.rgb_blocks
        port map ( CLK   => CLK,
                   RST   => RST,
                   x     => x,
                   y     => y,
                   blk_x => blk_x,
                   blk_y => blk_y,
                   blk_w => blk_w,
                   blk_h => blk_h,
                   solid => variant,
                   rgb   => rgb_blk );

    blocks_pad: entity work.delay_line
        generic map ( WIDTH => 12, DEPTH => RENDER_LAT - LAT_BLOCKS )
        port map ( CLK => CLK, din => rgb_blk, dout => rgb_blk_d );

    bars: entity work.gray_bars
        port map ( CLK     => CLK,
                   RST     => RST,
                   res_sel => res_sel,
                   x       => x,
                   y       => y,
                   rgb     => rgb_bars );

    bars_pad: entity work.delay_line
        generic map ( WIDTH => 12, DEPTH => RENDER_LAT - LAT_BARS )
        port map ( CLK => CLK, din => rgb_bars, dout => rgb_bars_d );

    with mode select
        shp_kind <= "00" when "010",
                    "01" when "011",
                    "10" when others;

    shape: entity work.shape2d
        port map ( CLK   => CLK,
                   RST   => RST,
                   x     => x,
                   y     => y,
                   kind  => shp_kind,
                   solid => variant,
                   cx    => shp_cx,
                   cy    => shp_cy,
                   a     => shp_a,
                   b     => shp_b,
                   rgb   => rgb_shp );

    shape_pad: entity work.delay_line
        generic map ( WIDTH => 12, DEPTH => RENDER_LAT - LAT_SHAPE )
        port map ( CLK => CLK, din => rgb_shp, dout => rgb_shp_d );

    mode_mux: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_mux <= (others => '0');
            elsif CLK'event and CLK = '1' then
                case mode is
                    when "000"  => rgb_mux <= rgb_blk_d;
                    when "001"  =>
                        if variant = '0' then
                            rgb_mux <= rgb_bars_d;
                        else
                            rgb_mux <= (others => '0');
                        end if;
                    when "010" | "011" | "100" => rgb_mux <= rgb_shp_d;
                    when others => rgb_mux <= (others => '0');
                end case;
            end if;
        end process;

    sync_in <= hs & vs & active & x(1 downto 0) & y(1 downto 0);

    sync_pad: entity work.delay_line
        generic map ( WIDTH => 7, DEPTH => RENDER_LAT + 1 )
        port map ( CLK => CLK, din => sync_in, dout => sync_d );

    -- 4x4 Bayer 有序抖動門檻, 索引 = y(1..0) & x(1..0)
    bayer_idx <= sync_d(1 downto 0) & sync_d(3 downto 2);

    with bayer_idx select
        bayer_t <= x"0" when "0000", x"8" when "0001", x"2" when "0010", x"A" when "0011",
                   x"C" when "0100", x"4" when "0101", x"E" when "0110", x"6" when "0111",
                   x"3" when "1000", x"B" when "1001", x"1" when "1010", x"9" when "1011",
                   x"F" when "1100", x"7" when "1101", x"D" when "1110", x"5" when others;

    -- 4 bit 值先映射到 0..16 (加上自身 MSB), 才能讓 15 = 全亮, 0 = 全暗, 中間 16 階都用得到
    r_dit <= '1' when ('0' & rgb_mux(11 downto 8)) + rgb_mux(11) > bayer_t else '0';
    g_dit <= '1' when ('0' & rgb_mux(7 downto 4)) + rgb_mux(7) > bayer_t else '0';
    b_dit <= '1' when ('0' & rgb_mux(3 downto 0)) + rgb_mux(3) > bayer_t else '0';

    -- 遮沒期間 RGB 必須是 0, 螢幕會拿這段當黑色基準
    -- 1 bit 模式每色輸出 0000 或 1111, 只接 MSB 的轉接板和 4 bit 轉接板都能正確顯示
    color_out: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_out <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if sync_d(4) = '0' then
                    rgb_out <= (others => '0');
                elsif depth = '1' then
                    rgb_out <= rgb_mux;
                else
                    rgb_out(11 downto 8) <= (others => r_dit);
                    rgb_out(7 downto 4)  <= (others => g_dit);
                    rgb_out(3 downto 0)  <= (others => b_dit);
                end if;
            end if;
        end process;

    hs_out: process(CLK, RST)
        begin
            if RST = '0' then
                hs_o <= '0';
            elsif CLK'event and CLK = '1' then
                hs_o <= sync_d(6);
            end if;
        end process;

    vs_out: process(CLK, RST)
        begin
            if RST = '0' then
                vs_o <= '0';
            elsif CLK'event and CLK = '1' then
                vs_o <= sync_d(5);
            end if;
        end process;

    de_out: process(CLK, RST)
        begin
            if RST = '0' then
                de_o <= '0';
            elsif CLK'event and CLK = '1' then
                de_o <= sync_d(4);
            end if;
        end process;

    with edit_sel(2 downto 1) select
        target_led <= "001" when "00",
                      "010" when "01",
                      "100" when others;

    status(2 downto 0) <= target_led when mode = "000" else "000";
    status(3)          <= edit_sel(0) when mode = "000" else
                          shp_resize  when mode = "010" or mode = "011" or mode = "100" else '0';
    status(6 downto 4) <= "000";

    vga_r  <= rgb_out(11 downto 8);
    vga_g  <= rgb_out(7 downto 4);
    vga_b  <= rgb_out(3 downto 0);
    vga_hs <= hs_o;
    vga_vs <= vs_o;
    de     <= de_o;
end Behavioral;
