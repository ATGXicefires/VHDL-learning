----------------------------------------------------------------------------------
-- Module Name: cd_ctrl - Behavioral
-- Description: CD 彈跳 (mode = "110") 的運動狀態, 像 DVD 螢幕保護程式一樣在畫面裡斜向移動, 碰邊反彈
--   位置是 Q.4 (1/16 像素); 速度等級 lv = 1..7, |vx| = 11 lv, |vy| = 8 lv:
--     x, y 速度不同, 軌跡才不會只在幾條 45 度斜線上來回
--   座標是邏輯座標: big = '1' (1024x768 以上) 時畫面當成一半大, cd_draw 會把 CD 放大 2 倍
--   每次反彈 tint 換下一個顏色; x, y 在同一個 frame 反彈 = 剛好撞進角落, flash 閃約 1 秒
--   BTNC 暫停 / 繼續, BTNU / BTND 加快 / 減慢; enable = '0' (不在這個模式) 時凍結
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;
use work.vga_pkg.all;

entity cd_ctrl is
    Port ( CLK        : in  STD_LOGIC;
           RST        : in  STD_LOGIC;
           frame_tick : in  STD_LOGIC;
           enable     : in  STD_LOGIC;
           btn        : in  STD_LOGIC_VECTOR (4 downto 0);
           h_size     : in  coord_type;
           v_size     : in  coord_type;
           big        : in  STD_LOGIC;
           cd_x       : out coord_type;
           cd_y       : out coord_type;
           spin       : out STD_LOGIC_VECTOR (7 downto 0);
           tint       : out STD_LOGIC_VECTOR (2 downto 0);
           flash      : out STD_LOGIC;
           paused     : out STD_LOGIC);
end cd_ctrl;

architecture Behavioral of cd_ctrl is
    constant R      : integer := 64;                               -- 和 cd_draw 的外緣半徑一致
    constant R_Q4   : STD_LOGIC_VECTOR (14 downto 0) := conv_std_logic_vector(R * 16, 15);
    constant X_INIT : integer := 200;                              -- 4 種解析度的邏輯畫面都 >= 512x384, 起點都在範圍內
    constant Y_INIT : integer := 120;

    signal btn_q                     : STD_LOGIC_VECTOR (4 downto 0);
    signal press_c, press_u, press_d : STD_LOGIC;
    signal paused_r                  : STD_LOGIC;
    signal run                       : STD_LOGIC;
    signal lv                        : STD_LOGIC_VECTOR (2 downto 0);
    signal vx, vy                    : STD_LOGIC_VECTOR (6 downto 0);

    signal w_log, h_log              : coord_type;
    signal x_max, y_max              : STD_LOGIC_VECTOR (14 downto 0);
    signal pos_x, pos_y              : STD_LOGIC_VECTOR (14 downto 0);
    signal dir_x, dir_y              : STD_LOGIC;                  -- '1' = 往右 / 往下
    signal edge_r, edge_l            : STD_LOGIC;
    signal edge_d, edge_u            : STD_LOGIC;
    signal over_x, over_y            : STD_LOGIC;
    signal bounce_x, bounce_y        : STD_LOGIC;

    signal tint_r                    : STD_LOGIC_VECTOR (2 downto 0);
    signal flash_cnt                 : STD_LOGIC_VECTOR (5 downto 0);
    signal spin_r                    : STD_LOGIC_VECTOR (7 downto 0);
begin
    btn_prev: process(CLK, RST)
        begin
            if RST = '0' then
                btn_q <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    btn_q <= btn;
                end if;
            end if;
        end process;

    press_c <= btn(BTN_C) and not btn_q(BTN_C);
    press_u <= btn(BTN_U) and not btn_q(BTN_U);
    press_d <= btn(BTN_D) and not btn_q(BTN_D);

    paused_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                paused_r <= '0';
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and enable = '1' and press_c = '1' then
                    paused_r <= not paused_r;
                end if;
            end if;
        end process;

    run <= enable and not paused_r;

    lv_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                lv <= "011";
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and enable = '1' then
                    if press_u = '1' and lv /= "111" then
                        lv <= lv + '1';
                    elsif press_d = '1' and lv /= "001" then
                        lv <= lv - '1';
                    end if;
                end if;
            end if;
        end process;

    vx <= ('0' & lv & "000") + ("000" & lv & '0') + ("0000" & lv);
    vy <= '0' & lv & "000";

    w_log <= '0' & h_size(10 downto 1) when big = '1' else h_size;
    h_log <= '0' & v_size(10 downto 1) when big = '1' else v_size;

    -- 邊界只在換解析度時改變, 先存起來, 下面的比較才不會串上 解析度表 -> 減法 這段路徑
    x_max_reg: process(CLK, RST)
        begin
            if RST = '0' then
                x_max <= (others => '0');
            elsif CLK'event and CLK = '1' then
                x_max <= (w_log - R) & "0000";
            end if;
        end process;

    y_max_reg: process(CLK, RST)
        begin
            if RST = '0' then
                y_max <= (others => '0');
            elsif CLK'event and CLK = '1' then
                y_max <= (h_log - R) & "0000";
            end if;
        end process;

    -- 和 btn_ctrl 一樣: 每個 CLK 先判斷「下一步會不會出界」, frame_tick 時直接用
    edge_r_reg: process(CLK, RST)
        begin
            if RST = '0' then
                edge_r <= '0';
            elsif CLK'event and CLK = '1' then
                if pos_x + vx >= x_max then
                    edge_r <= '1';
                else
                    edge_r <= '0';
                end if;
            end if;
        end process;

    edge_l_reg: process(CLK, RST)
        begin
            if RST = '0' then
                edge_l <= '0';
            elsif CLK'event and CLK = '1' then
                if pos_x <= R_Q4 + vx then
                    edge_l <= '1';
                else
                    edge_l <= '0';
                end if;
            end if;
        end process;

    edge_d_reg: process(CLK, RST)
        begin
            if RST = '0' then
                edge_d <= '0';
            elsif CLK'event and CLK = '1' then
                if pos_y + vy >= y_max then
                    edge_d <= '1';
                else
                    edge_d <= '0';
                end if;
            end if;
        end process;

    edge_u_reg: process(CLK, RST)
        begin
            if RST = '0' then
                edge_u <= '0';
            elsif CLK'event and CLK = '1' then
                if pos_y <= R_Q4 + vy then
                    edge_u <= '1';
                else
                    edge_u <= '0';
                end if;
            end if;
        end process;

    -- 切到較小的解析度時 CD 可能整個落在新畫面外, 要直接拉回來, 不能等它慢慢移進來
    over_x_reg: process(CLK, RST)
        begin
            if RST = '0' then
                over_x <= '0';
            elsif CLK'event and CLK = '1' then
                if pos_x > x_max then
                    over_x <= '1';
                else
                    over_x <= '0';
                end if;
            end if;
        end process;

    over_y_reg: process(CLK, RST)
        begin
            if RST = '0' then
                over_y <= '0';
            elsif CLK'event and CLK = '1' then
                if pos_y > y_max then
                    over_y <= '1';
                else
                    over_y <= '0';
                end if;
            end if;
        end process;

    bounce_x <= edge_r when dir_x = '1' else edge_l;
    bounce_y <= edge_d when dir_y = '1' else edge_u;

    pos_x_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                pos_x <= conv_std_logic_vector(X_INIT * 16, 15);
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    if over_x = '1' then
                        pos_x <= x_max;
                    elsif run = '1' then
                        if dir_x = '1' then
                            if edge_r = '1' then
                                pos_x <= x_max;
                            else
                                pos_x <= pos_x + vx;
                            end if;
                        elsif edge_l = '1' then
                            pos_x <= R_Q4;
                        else
                            pos_x <= pos_x - vx;
                        end if;
                    end if;
                end if;
            end if;
        end process;

    pos_y_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                pos_y <= conv_std_logic_vector(Y_INIT * 16, 15);
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    if over_y = '1' then
                        pos_y <= y_max;
                    elsif run = '1' then
                        if dir_y = '1' then
                            if edge_d = '1' then
                                pos_y <= y_max;
                            else
                                pos_y <= pos_y + vy;
                            end if;
                        elsif edge_u = '1' then
                            pos_y <= R_Q4;
                        else
                            pos_y <= pos_y - vy;
                        end if;
                    end if;
                end if;
            end if;
        end process;

    dir_x_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                dir_x <= '1';
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and run = '1' and bounce_x = '1' then
                    dir_x <= not dir_x;
                end if;
            end if;
        end process;

    dir_y_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                dir_y <= '1';
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and run = '1' and bounce_y = '1' then
                    dir_y <= not dir_y;
                end if;
            end if;
        end process;

    tint_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                tint_r <= "000";
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and run = '1' and (bounce_x = '1' or bounce_y = '1') then
                    if tint_r >= 6 then
                        tint_r <= "000";
                    else
                        tint_r <= tint_r + '1';
                    end if;
                end if;
            end if;
        end process;

    flash_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                flash_cnt <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and run = '1' then
                    if bounce_x = '1' and bounce_y = '1' then
                        flash_cnt <= (others => '1');
                    elsif flash_cnt /= 0 then
                        flash_cnt <= flash_cnt - '1';
                    end if;
                end if;
            end if;
        end process;

    -- spin 每 frame 加 2: 彩虹紋是 2 倍角, 等於 CD 每 frame 轉 1/256 圈 (約 4 秒一圈)
    spin_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                spin_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and run = '1' then
                    spin_r <= spin_r + 2;
                end if;
            end if;
        end process;

    cd_x   <= pos_x(14 downto 4);
    cd_y   <= pos_y(14 downto 4);
    spin   <= spin_r;
    tint   <= tint_r;
    -- 每 8 frame 亮暗切換一次 (約 4 Hz), 閃太快看了不舒服
    flash  <= '1' when flash_cnt /= 0 and flash_cnt(3) = '1' else '0';
    paused <= paused_r;
end Behavioral;
