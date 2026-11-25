----------------------------------------------------------------------------------
-- Package Name: pong_pkg
-- Description: 螢幕乒乓 (Pong_HDMI) 共用定義: 控制向量、2D 球場與 3D 隧道的尺寸、透視縮放表、7 段數字
--   畫面固定 1024x768 (65 MHz); 遊戲邏輯 (*_ctrl) 和繪圖 (*_draw) 都從這裡取尺寸, 碰撞和畫面才會一致
--   座標型別 coord_type、色彩 rgb_type 沿用 ../VGA_Screen/vga_pkg
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package pong_pkg is
    -- 控制向量: 按鈕和將來的鍵盤都先轉成這個格式, 遊戲邏輯不用管按鍵從哪來
    subtype ctrl_type is STD_LOGIC_VECTOR (6 downto 0);
    constant K_C    : integer := 0;                                -- 發球 / 暫停 / 開新局
    constant K_UP   : integer := 1;                                -- P1 (2D 左拍, 3D 球拍) 上
    constant K_DN   : integer := 2;                                -- P1 下
    constant K_LT   : integer := 3;                                -- 3D 球拍左
    constant K_RT   : integer := 4;                                -- 3D 球拍右
    constant K_P2UP : integer := 5;                                -- 2D 雙人時右拍上
    constant K_P2DN : integer := 6;                                -- 2D 雙人時右拍下

    constant SCR_W : integer := 1024;
    constant SCR_H : integer := 768;
    constant WIN   : integer := 7;                                 -- 先得 7 分獲勝

    -- 遊戲階段 (2D、3D 共用編碼, LED 和繪圖才能用同一套判斷)
    subtype gphase_type is STD_LOGIC_VECTOR (1 downto 0);
    constant GP_SERVE : gphase_type := "00";
    constant GP_PLAY  : gphase_type := "01";
    constant GP_POINT : gphase_type := "10";
    constant GP_OVER  : gphase_type := "11";

    -- 每個 frame_tick 之後, 遊戲邏輯用幾個 CLK 依序算完一步 (見 *_ctrl 的 ph);
    -- pong_core 的 GAME_TICKS 加速模擬時, 兩次 tick 至少要隔這麼久
    constant STEP_CLKS : integer := 16;

    ---------------------------------------------------------------- 2D
    constant FY0     : integer := 104;                             -- 球場內緣上 (上方留給比分)
    constant FY1     : integer := 744;                             -- 球場內緣下 (不含)
    constant WALL_T  : integer := 8;
    constant PAD_W   : integer := 16;
    constant PAD_H   : integer := 96;
    constant PL_X    : integer := 48;                              -- 左拍左緣
    constant PR_X    : integer := SCR_W - 48 - PAD_W;              -- 右拍左緣
    constant BALL_S  : integer := 16;                              -- 球的外框邊長 (畫成直徑 16 的圓)

    ---------------------------------------------------------------- 3D
    -- 世界座標: X 向右 +-T_HW, Y 向下 +-T_HH, Z 從螢幕 (0) 往裡到 Z_FAR; 隧道口剛好填滿螢幕
    constant T_HW    : integer := 512;
    constant T_HH    : integer := 384;
    constant Z_FAR   : integer := 1020;
    constant RB      : integer := 48;                              -- 球半徑
    constant P3_HW   : integer := 128;                             -- 球拍半寬 / 半高 (兩邊相同)
    constant P3_HH   : integer := 96;

    -- 透視: s(z) = D / (D + z), Q.10 (1024 = 1.0); D = 384 時最深處縮成約 0.27 倍, 有明顯的縱深
    constant PERSP_D : integer := 384;
    type scale_table is array (0 to 255) of integer range 0 to 1024;
    constant SCALE   : scale_table;                                -- 索引 = z / 4, 在 package body 算好
    constant S_FAR   : integer;                                    -- SCALE(255), 最深處 (電腦球拍那一面)
    constant FAR_HW  : integer;                                    -- 隧道底的半寬 / 半高 (螢幕像素)
    constant FAR_HH  : integer;

    -- 隧道上 7 圈固定深度的格線 (z = 128, 256, ..., 896), 讓人看得出遠近
    type ring_table is array (1 to 7) of integer;
    constant RING_HW : ring_table;
    constant RING_HH : ring_table;

    ---------------------------------------------------------------- 7 段數字
    -- 段的順序 a b c d e f g (a = 上, 順時針繞一圈, g = 中間), 和 VGA_Screen 的 hockey_draw 相同
    type seg_table is array (0 to 9) of STD_LOGIC_VECTOR (6 downto 0);
    constant SEG7 : seg_table := ("1111110", "0110000", "1101101", "1111001", "0110011",
                                  "1011011", "1011111", "1110000", "1111111", "1111011");

    -- (sx, sy) 是數字框內的座標; 框左邊或上面的像素減出來是負的, 繞回成大數, 一樣落在框外
    function seg_lit(sx, sy : unsigned (10 downto 0); w, h, t : integer;
                     digit : unsigned (2 downto 0)) return STD_LOGIC;
end pong_pkg;

package body pong_pkg is
    function make_scale return scale_table is
        variable s : scale_table;
    begin
        for i in 0 to 255 loop
            s(i) := (PERSP_D * 1024 + (PERSP_D + 4 * i) / 2) / (PERSP_D + 4 * i);
        end loop;
        return s;
    end function;

    constant SCALE  : scale_table := make_scale;
    constant S_FAR  : integer := SCALE(255);
    constant FAR_HW : integer := T_HW * S_FAR / 1024;
    constant FAR_HH : integer := T_HH * S_FAR / 1024;

    function make_rings(half : integer) return ring_table is
        variable r : ring_table;
    begin
        for k in 1 to 7 loop
            r(k) := half * SCALE(32 * k) / 1024;
        end loop;
        return r;
    end function;

    constant RING_HW : ring_table := make_rings(T_HW);
    constant RING_HH : ring_table := make_rings(T_HH);

    function seg_lit(sx, sy : unsigned (10 downto 0); w, h, t : integer;
                     digit : unsigned (2 downto 0)) return STD_LOGIC is
        variable s : STD_LOGIC_VECTOR (6 downto 0) := (others => '0');
    begin
        if sx < w and sy < h then
            if sy < t then
                s(6) := '1';
            end if;
            if sx >= w - t and sy < h / 2 then
                s(5) := '1';
            end if;
            if sx >= w - t and sy >= h / 2 then
                s(4) := '1';
            end if;
            if sy >= h - t then
                s(3) := '1';
            end if;
            if sx < t and sy >= h / 2 then
                s(2) := '1';
            end if;
            if sx < t and sy < h / 2 then
                s(1) := '1';
            end if;
            if sy >= (h - t) / 2 and sy < (h + t) / 2 then
                s(0) := '1';
            end if;
        end if;
        if (s and SEG7(to_integer(digit))) /= "0000000" then
            return '1';
        end if;
        return '0';
    end function;
end pong_pkg;
