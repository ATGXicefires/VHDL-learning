----------------------------------------------------------------------------------
-- Module Name: btn_ctrl - Behavioral
-- Description: HW3 按鈕控制, 調整 R/G/B 色塊的位置與大小
--   只在 frame_tick 取樣按鈕: 取樣間隔約 16 ms, 本身就濾掉了按鈕彈跳,
--   而且物件只在垂直遮沒期間改變, 畫面不會撕裂
--
--   色塊模式 (mode = "000"):
--     BTNC 依序切換 edit_sel: 0 R移動, 1 R縮放, 2 G移動, 3 G縮放, 4 B移動, 5 B縮放
--     移動: U/D/L/R 往該方向移 STEP 像素; 縮放: R/L 加寬/減寬, D/U 加高/減高
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
           edit_sel   : out STD_LOGIC_VECTOR (2 downto 0));
end btn_ctrl;

architecture Behavioral of btn_ctrl is
    constant STEP     : integer := 2;
    constant MIN_SIZE : integer := 16;

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

    -- 座標和都多補 1 個位元: 切到較小解析度的那一刻 x + w 可能超過 11 bit
    blk_x_ctr: process(CLK, RST)
        begin
            if RST = '0' then
                blk_x_r <= BLK_X_INIT;
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    for i in 0 to 2 loop
                        if ('0' & blk_x_r(i)) + blk_w_r(i) > h_size then
                            if blk_w_r(i) >= h_size then
                                blk_x_r(i) <= (others => '0');
                            else
                                blk_x_r(i) <= h_size - blk_w_r(i);
                            end if;
                        elsif sel_move(i) = '1' and btn(BTN_L) = '1' and blk_x_r(i) >= STEP then
                            blk_x_r(i) <= blk_x_r(i) - STEP;
                        elsif sel_move(i) = '1' and btn(BTN_R) = '1'
                              and ('0' & blk_x_r(i)) + blk_w_r(i) + STEP <= h_size then
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
                        if ('0' & blk_y_r(i)) + blk_h_r(i) > v_size then
                            if blk_h_r(i) >= v_size then
                                blk_y_r(i) <= (others => '0');
                            else
                                blk_y_r(i) <= v_size - blk_h_r(i);
                            end if;
                        elsif sel_move(i) = '1' and btn(BTN_U) = '1' and blk_y_r(i) >= STEP then
                            blk_y_r(i) <= blk_y_r(i) - STEP;
                        elsif sel_move(i) = '1' and btn(BTN_D) = '1'
                              and ('0' & blk_y_r(i)) + blk_h_r(i) + STEP <= v_size then
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
                        elsif sel_size(i) = '1' and btn(BTN_R) = '1'
                              and ('0' & blk_x_r(i)) + blk_w_r(i) + STEP <= h_size then
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
                        elsif sel_size(i) = '1' and btn(BTN_D) = '1'
                              and ('0' & blk_y_r(i)) + blk_h_r(i) + STEP <= v_size then
                            blk_h_r(i) <= blk_h_r(i) + STEP;
                        elsif sel_size(i) = '1' and btn(BTN_U) = '1' and blk_h_r(i) >= MIN_SIZE + STEP then
                            blk_h_r(i) <= blk_h_r(i) - STEP;
                        end if;
                    end loop;
                end if;
            end if;
        end process;

    blk_x    <= blk_x_r;
    blk_y    <= blk_y_r;
    blk_w    <= blk_w_r;
    blk_h    <= blk_h_r;
    edit_sel <= edit_sel_r;
end Behavioral;
