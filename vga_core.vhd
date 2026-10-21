----------------------------------------------------------------------------------
-- Module Name: vga_core - Behavioral
-- Description: HW3 VGA 掃描核心, 全部跑在像素時脈 CLK 上
--   和 vga_top 分開, 是為了讓 testbench 能直接給像素時脈, 不用模擬 MMCM
--   sw / btn 是非同步輸入, 先經 2 級 FF 同步
--     sw(1..0) = res_sel, sw(4..2) = mode, sw(5) = variant, sw(6) = depth
--     btn 編號見 vga_pkg (BTN_C/U/D/L/R)
--   status(2..0) = 編輯中的色塊 (one-hot R/G/B), status(3) = 縮放模式
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
    signal btn_s            : STD_LOGIC_VECTOR (4 downto 0);

    signal x, y           : coord_type;
    signal active         : STD_LOGIC;
    signal hs, vs         : STD_LOGIC;
    signal frame_tick     : STD_LOGIC;
    signal h_size, v_size : coord_type;

    signal blk_x, blk_y, blk_w, blk_h : coord3_type;
    signal edit_sel                   : STD_LOGIC_VECTOR (2 downto 0);
    signal target_led                 : STD_LOGIC_VECTOR (2 downto 0);

    signal rgb_blk, rgb_blk_d : rgb_type;
    signal rgb_mux            : rgb_type;

    -- hs, vs, active, x(1..0), y(1..0) 延遲到和 rgb_mux 同一級
    signal sync_in, sync_d : STD_LOGIC_VECTOR (6 downto 0);

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
                   edit_sel   => edit_sel );

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

    mode_mux: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_mux <= (others => '0');
            elsif CLK'event and CLK = '1' then
                case mode is
                    when "000"  => rgb_mux <= rgb_blk_d;
                    when others => rgb_mux <= (others => '0');
                end case;
            end if;
        end process;

    sync_in <= hs & vs & active & x(1 downto 0) & y(1 downto 0);

    sync_pad: entity work.delay_line
        generic map ( WIDTH => 7, DEPTH => RENDER_LAT + 1 )
        port map ( CLK => CLK, din => sync_in, dout => sync_d );

    -- 遮沒期間 RGB 必須是 0, 螢幕會拿這段當黑色基準
    color_out: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_out <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if sync_d(4) = '1' then
                    rgb_out <= rgb_mux;
                else
                    rgb_out <= (others => '0');
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
    status(3)          <= edit_sel(0) when mode = "000" else '0';
    status(6 downto 4) <= "000";

    vga_r  <= rgb_out(11 downto 8);
    vga_g  <= rgb_out(7 downto 4);
    vga_b  <= rgb_out(3 downto 0);
    vga_hs <= hs_o;
    vga_vs <= vs_o;
    de     <= de_o;
end Behavioral;
