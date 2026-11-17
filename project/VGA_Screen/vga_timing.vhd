----------------------------------------------------------------------------------
-- Module Name: vga_timing - Behavioral
-- Description: HW3 VGA 掃描時序產生器, 時序參數依 res_sel 從 vga_pkg.TIMINGS 選取
--   所有輸出都已暫存 (同一級), x/y 只在 active = '1' 時有意義
--   frame_tick 在最後一條可視掃描線結束後的第一個 CLK 拉高, 讓物件在遮沒期間更新, 畫面不撕裂
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;
use work.vga_pkg.all;

entity vga_timing is
    Port ( CLK        : in  STD_LOGIC;
           RST        : in  STD_LOGIC;
           res_sel    : in  STD_LOGIC_VECTOR (1 downto 0);
           x          : out coord_type;
           y          : out coord_type;
           active     : out STD_LOGIC;
           hs         : out STD_LOGIC;
           vs         : out STD_LOGIC;
           frame_tick : out STD_LOGIC;
           h_size     : out coord_type;
           v_size     : out coord_type);
end vga_timing;

architecture Behavioral of vga_timing is
    signal h_active, h_sync_start, h_sync_end, h_total : coord_type;
    signal v_active, v_sync_start, v_sync_end, v_total : coord_type;
    signal sync_pol : STD_LOGIC;

    signal hcnt, vcnt : coord_type;
    signal line_end   : STD_LOGIC;

    signal x_r, y_r   : coord_type;
    signal active_r   : STD_LOGIC;
    signal hs_r, vs_r : STD_LOGIC;
    signal tick_r     : STD_LOGIC;
begin
    h_active     <= conv_std_logic_vector(TIMINGS(conv_integer(res_sel)).h_active, 11);
    h_sync_start <= conv_std_logic_vector(TIMINGS(conv_integer(res_sel)).h_sync_start, 11);
    h_sync_end   <= conv_std_logic_vector(TIMINGS(conv_integer(res_sel)).h_sync_end, 11);
    h_total      <= conv_std_logic_vector(TIMINGS(conv_integer(res_sel)).h_total, 11);
    v_active     <= conv_std_logic_vector(TIMINGS(conv_integer(res_sel)).v_active, 11);
    v_sync_start <= conv_std_logic_vector(TIMINGS(conv_integer(res_sel)).v_sync_start, 11);
    v_sync_end   <= conv_std_logic_vector(TIMINGS(conv_integer(res_sel)).v_sync_end, 11);
    v_total      <= conv_std_logic_vector(TIMINGS(conv_integer(res_sel)).v_total, 11);
    sync_pol     <= TIMINGS(conv_integer(res_sel)).sync_pol;

    -- 用 >= 是為了 res_sel 由大切小時, 計數值已超過新上限也能歸 0
    line_end <= '1' when hcnt >= h_total - 1 else '0';

    h_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                hcnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if line_end = '1' then
                    hcnt <= (others => '0');
                else
                    hcnt <= hcnt + '1';
                end if;
            end if;
        end process;

    v_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                vcnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if line_end = '1' then
                    if vcnt >= v_total - 1 then
                        vcnt <= (others => '0');
                    else
                        vcnt <= vcnt + '1';
                    end if;
                end if;
            end if;
        end process;

    x_reg: process(CLK, RST)
        begin
            if RST = '0' then
                x_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                x_r <= hcnt;
            end if;
        end process;

    y_reg: process(CLK, RST)
        begin
            if RST = '0' then
                y_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                y_r <= vcnt;
            end if;
        end process;

    active_reg: process(CLK, RST)
        begin
            if RST = '0' then
                active_r <= '0';
            elsif CLK'event and CLK = '1' then
                if hcnt < h_active and vcnt < v_active then
                    active_r <= '1';
                else
                    active_r <= '0';
                end if;
            end if;
        end process;

    hs_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hs_r <= '0';
            elsif CLK'event and CLK = '1' then
                if hcnt >= h_sync_start and hcnt < h_sync_end then
                    hs_r <= sync_pol;
                else
                    hs_r <= not sync_pol;
                end if;
            end if;
        end process;

    vs_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vs_r <= '0';
            elsif CLK'event and CLK = '1' then
                if vcnt >= v_sync_start and vcnt < v_sync_end then
                    vs_r <= sync_pol;
                else
                    vs_r <= not sync_pol;
                end if;
            end if;
        end process;

    tick_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tick_r <= '0';
            elsif CLK'event and CLK = '1' then
                if hcnt = 0 and vcnt = v_active then
                    tick_r <= '1';
                else
                    tick_r <= '0';
                end if;
            end if;
        end process;

    x          <= x_r;
    y          <= y_r;
    active     <= active_r;
    hs         <= hs_r;
    vs         <= vs_r;
    frame_tick <= tick_r;
    h_size     <= h_active;
    v_size     <= v_active;
end Behavioral;
