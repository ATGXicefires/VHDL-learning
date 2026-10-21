----------------------------------------------------------------------------------
-- Module Name: btn_ctrl - Behavioral
-- Description: HW3 按鈕控制, 調整 R/G/B 色塊與 2D 圖形的位置與大小
--   只在 frame_tick 取樣按鈕: 取樣間隔約 16 ms, 本身就濾掉了按鈕彈跳,
--   而且物件只在垂直遮沒期間改變, 畫面不會撕裂
--
--   色塊模式 (mode = "000"):
--     BTNC 依序切換 edit_sel: 0 R移動, 1 R縮放, 2 G移動, 3 G縮放, 4 B移動, 5 B縮放
--     移動: U/D/L/R 往該方向移 STEP 像素; 縮放: R/L 加寬/減寬, D/U 加高/減高
--   2D 圖形模式 (mode = "010" 橢圓, "011" 圓, "100" 三角形):
--     BTNC 切換 移動 / 縮放 (shp_resize); 縮放時 R/L 調 a, D/U 調 b, 圓只有 a: R/D 放大, L/U 縮小
--     切換解析度時圖形自動回到畫面中央
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;
use work.vga_pkg.all;

entity btn_ctrl is
    Port ( CLK        : in  STD_LOGIC;
           RST        : in  STD_LOGIC;
           frame_tick : in  STD_LOGIC;
           mode       : in  STD_LOGIC_VECTOR (2 downto 0);
           btn        : in  STD_LOGIC_VECTOR (4 downto 0);
           h_size     : in  coord_type;
           v_size     : in  coord_type;
           blk_x      : out coord3_type;
           blk_y      : out coord3_type;
           blk_w      : out coord3_type;
           blk_h      : out coord3_type;
           edit_sel   : out STD_LOGIC_VECTOR (2 downto 0);
           res_sel    : in  STD_LOGIC_VECTOR (1 downto 0);
           shp_cx     : out coord_type;
           shp_cy     : out coord_type;
           shp_a      : out STD_LOGIC_VECTOR (8 downto 0);
           shp_b      : out STD_LOGIC_VECTOR (8 downto 0);
           shp_resize : out STD_LOGIC);
end btn_ctrl;

architecture Behavioral of btn_ctrl is
    constant STEP     : integer := 2;
    constant MIN_SIZE : integer := 16;
    constant SHP_MIN  : integer := 8;
    constant SHP_MAX  : integer := 360;                           -- shape2d 的 DSP 位寬上限

    -- 三塊斜向交疊, 一開機就能看到加色混色
    constant BLK_X_INIT : coord3_type := (conv_std_logic_vector(64, 11),
                                          conv_std_logic_vector(224, 11),
                                          conv_std_logic_vector(384, 11));
    constant BLK_Y_INIT : coord3_type := (conv_std_logic_vector(64, 11),
                                          conv_std_logic_vector(160, 11),
                                          conv_std_logic_vector(256, 11));
    constant BLK_W_INIT : coord3_type := (others => conv_std_logic_vector(192, 11));
    constant BLK_H_INIT : coord3_type := (others => conv_std_logic_vector(144, 11));

    signal btn_q      : STD_LOGIC_VECTOR (4 downto 0);
    signal press_c    : STD_LOGIC;
    signal edit_sel_r : STD_LOGIC_VECTOR (2 downto 0);
    signal sel_move   : STD_LOGIC_VECTOR (2 downto 0);
    signal sel_size   : STD_LOGIC_VECTOR (2 downto 0);

    signal blk_x_r, blk_y_r, blk_w_r, blk_h_r : coord3_type;

    type end3_type is array (0 to 2) of STD_LOGIC_VECTOR (11 downto 0);
    signal x_end, y_end     : end3_type;
    signal room_r, room_d   : STD_LOGIC_VECTOR (2 downto 0);
    signal over_r, over_d   : STD_LOGIC_VECTOR (2 downto 0);

    signal is_2d, is_circle       : STD_LOGIC;
    signal res_q                  : STD_LOGIC_VECTOR (1 downto 0);
    signal res_changed            : STD_LOGIC;
    signal shp_resize_r           : STD_LOGIC;
    signal shp_cx_r, shp_cy_r     : coord_type;
    signal shp_a_r, shp_b_r       : STD_LOGIC_VECTOR (8 downto 0);
    signal shp_room_r, shp_room_d : STD_LOGIC;
    signal grow_a, shrink_a       : STD_LOGIC;
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

    edit_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                edit_sel_r <= "000";
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and mode = "000" and press_c = '1' then
                    if edit_sel_r >= 5 then
                        edit_sel_r <= "000";
                    else
                        edit_sel_r <= edit_sel_r + '1';
                    end if;
                end if;
            end if;
        end process;

    -- edit_sel 高 2 位元 = 色塊編號, 最低位元 = 縮放
    gen_sel: for i in 0 to 2 generate
        sel_move(i) <= '1' when mode = "000" and conv_integer(edit_sel_r(2 downto 1)) = i
                                and edit_sel_r(0) = '0' else '0';
        sel_size(i) <= '1' when mode = "000" and conv_integer(edit_sel_r(2 downto 1)) = i
                                and edit_sel_r(0) = '1' else '0';
    end generate;

    -- 邊界判斷每個 CLK 先算好存起來, frame_tick 時直接用, 不然 加法 -> 比較 -> 選擇 串在一起在 108 MHz 下太長;
    -- 狀態只在 frame_tick 改變, 晚 2 拍才更新的旗標在下一個 frame_tick 前早就穩定了
    -- x_end / y_end 多補 1 個位元: 切到較小解析度的那一刻 x + w 可能超過 11 bit
    x_end_reg: process(CLK, RST)
        begin
            if RST = '0' then
                x_end <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    x_end(i) <= ('0' & blk_x_r(i)) + blk_w_r(i);
                end loop;
            end if;
        end process;

    y_end_reg: process(CLK, RST)
        begin
            if RST = '0' then
                y_end <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    y_end(i) <= ('0' & blk_y_r(i)) + blk_h_r(i);
                end loop;
            end if;
        end process;

    room_r_reg: process(CLK, RST)
        begin
            if RST = '0' then
                room_r <= "000";
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    if x_end(i) + STEP <= h_size then
                        room_r(i) <= '1';
                    else
                        room_r(i) <= '0';
                    end if;
                end loop;
            end if;
        end process;

    room_d_reg: process(CLK, RST)
        begin
            if RST = '0' then
                room_d <= "000";
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    if y_end(i) + STEP <= v_size then
                        room_d(i) <= '1';
                    else
                        room_d(i) <= '0';
                    end if;
                end loop;
            end if;
        end process;

    over_r_reg: process(CLK, RST)
        begin
            if RST = '0' then
                over_r <= "000";
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    if x_end(i) > h_size then
                        over_r(i) <= '1';
                    else
                        over_r(i) <= '0';
                    end if;
                end loop;
            end if;
        end process;

    over_d_reg: process(CLK, RST)
        begin
            if RST = '0' then
                over_d <= "000";
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    if y_end(i) > v_size then
                        over_d(i) <= '1';
                    else
                        over_d(i) <= '0';
                    end if;
                end loop;
            end if;
        end process;

    blk_x_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                blk_x_r <= BLK_X_INIT;
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    for i in 0 to 2 loop
                        if over_r(i) = '1' then
                            if blk_w_r(i) >= h_size then
                                blk_x_r(i) <= (others => '0');
                            else
                                blk_x_r(i) <= h_size - blk_w_r(i);
                            end if;
                        elsif sel_move(i) = '1' and btn(BTN_L) = '1' and blk_x_r(i) >= STEP then
                            blk_x_r(i) <= blk_x_r(i) - STEP;
                        elsif sel_move(i) = '1' and btn(BTN_R) = '1' and room_r(i) = '1' then
                            blk_x_r(i) <= blk_x_r(i) + STEP;
                        end if;
                    end loop;
                end if;
            end if;
        end process;

    blk_y_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                blk_y_r <= BLK_Y_INIT;
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    for i in 0 to 2 loop
                        if over_d(i) = '1' then
                            if blk_h_r(i) >= v_size then
                                blk_y_r(i) <= (others => '0');
                            else
                                blk_y_r(i) <= v_size - blk_h_r(i);
                            end if;
                        elsif sel_move(i) = '1' and btn(BTN_U) = '1' and blk_y_r(i) >= STEP then
                            blk_y_r(i) <= blk_y_r(i) - STEP;
                        elsif sel_move(i) = '1' and btn(BTN_D) = '1' and room_d(i) = '1' then
                            blk_y_r(i) <= blk_y_r(i) + STEP;
                        end if;
                    end loop;
                end if;
            end if;
        end process;

    blk_w_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                blk_w_r <= BLK_W_INIT;
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    for i in 0 to 2 loop
                        if blk_w_r(i) > h_size then
                            blk_w_r(i) <= h_size;
                        elsif sel_size(i) = '1' and btn(BTN_R) = '1' and room_r(i) = '1' then
                            blk_w_r(i) <= blk_w_r(i) + STEP;
                        elsif sel_size(i) = '1' and btn(BTN_L) = '1' and blk_w_r(i) >= MIN_SIZE + STEP then
                            blk_w_r(i) <= blk_w_r(i) - STEP;
                        end if;
                    end loop;
                end if;
            end if;
        end process;

    blk_h_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                blk_h_r <= BLK_H_INIT;
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    for i in 0 to 2 loop
                        if blk_h_r(i) > v_size then
                            blk_h_r(i) <= v_size;
                        elsif sel_size(i) = '1' and btn(BTN_D) = '1' and room_d(i) = '1' then
                            blk_h_r(i) <= blk_h_r(i) + STEP;
                        elsif sel_size(i) = '1' and btn(BTN_U) = '1' and blk_h_r(i) >= MIN_SIZE + STEP then
                            blk_h_r(i) <= blk_h_r(i) - STEP;
                        end if;
                    end loop;
                end if;
            end if;
        end process;

    is_2d     <= '1' when mode = "010" or mode = "011" or mode = "100" else '0';
    is_circle <= '1' when mode = "011" else '0';

    res_prev: process(CLK, RST)
        begin
            if RST = '0' then
                res_q <= "00";
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    res_q <= res_sel;
                end if;
            end if;
        end process;

    res_changed <= '1' when res_sel /= res_q else '0';

    shp_resize_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                shp_resize_r <= '0';
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and is_2d = '1' and press_c = '1' then
                    shp_resize_r <= not shp_resize_r;
                end if;
            end if;
        end process;

    shp_room_r_reg: process(CLK, RST)
        begin
            if RST = '0' then
                shp_room_r <= '0';
            elsif CLK'event and CLK = '1' then
                if shp_cx_r + STEP < h_size then
                    shp_room_r <= '1';
                else
                    shp_room_r <= '0';
                end if;
            end if;
        end process;

    shp_room_d_reg: process(CLK, RST)
        begin
            if RST = '0' then
                shp_room_d <= '0';
            elsif CLK'event and CLK = '1' then
                if shp_cy_r + STEP < v_size then
                    shp_room_d <= '1';
                else
                    shp_room_d <= '0';
                end if;
            end if;
        end process;

    shp_cx_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                shp_cx_r <= conv_std_logic_vector(320, 11);
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    if res_changed = '1' then
                        shp_cx_r <= '0' & h_size(10 downto 1);
                    elsif is_2d = '1' and shp_resize_r = '0' then
                        if btn(BTN_L) = '1' and shp_cx_r >= STEP then
                            shp_cx_r <= shp_cx_r - STEP;
                        elsif btn(BTN_R) = '1' and shp_room_r = '1' then
                            shp_cx_r <= shp_cx_r + STEP;
                        end if;
                    end if;
                end if;
            end if;
        end process;

    shp_cy_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                shp_cy_r <= conv_std_logic_vector(240, 11);
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    if res_changed = '1' then
                        shp_cy_r <= '0' & v_size(10 downto 1);
                    elsif is_2d = '1' and shp_resize_r = '0' then
                        if btn(BTN_U) = '1' and shp_cy_r >= STEP then
                            shp_cy_r <= shp_cy_r - STEP;
                        elsif btn(BTN_D) = '1' and shp_room_d = '1' then
                            shp_cy_r <= shp_cy_r + STEP;
                        end if;
                    end if;
                end if;
            end if;
        end process;

    grow_a   <= btn(BTN_R) or (is_circle and btn(BTN_D));
    shrink_a <= btn(BTN_L) or (is_circle and btn(BTN_U));

    shp_a_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                shp_a_r <= conv_std_logic_vector(160, 9);
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and is_2d = '1' and shp_resize_r = '1' then
                    if grow_a = '1' and shp_a_r <= SHP_MAX - STEP then
                        shp_a_r <= shp_a_r + STEP;
                    elsif shrink_a = '1' and shp_a_r >= SHP_MIN + STEP then
                        shp_a_r <= shp_a_r - STEP;
                    end if;
                end if;
            end if;
        end process;

    shp_b_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                shp_b_r <= conv_std_logic_vector(100, 9);
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' and is_2d = '1' and shp_resize_r = '1' and is_circle = '0' then
                    if btn(BTN_D) = '1' and shp_b_r <= SHP_MAX - STEP then
                        shp_b_r <= shp_b_r + STEP;
                    elsif btn(BTN_U) = '1' and shp_b_r >= SHP_MIN + STEP then
                        shp_b_r <= shp_b_r - STEP;
                    end if;
                end if;
            end if;
        end process;

    blk_x    <= blk_x_r;
    blk_y    <= blk_y_r;
    blk_w    <= blk_w_r;
    blk_h    <= blk_h_r;
    edit_sel <= edit_sel_r;

    shp_cx     <= shp_cx_r;
    shp_cy     <= shp_cy_r;
    shp_a      <= shp_a_r;
    shp_b      <= shp_b_r;
    shp_resize <= shp_resize_r;
end Behavioral;
