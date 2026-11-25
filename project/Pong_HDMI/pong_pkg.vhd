----------------------------------------------------------------------------------
-- Package Name: pong_pkg
-- Description: 螢幕乒乓 (Pong_HDMI) 共用定義: 控制向量、2D 側視球桌與 3D 球桌的尺寸、透視縮放表、7 段數字
--   畫面固定 1024x768 (65 MHz); 遊戲邏輯 (*_ctrl) 和繪圖 (*_draw) 都從這裡取尺寸, 碰撞和畫面才會一致
--   座標型別 coord_type、色彩 rgb_type 沿用 ../VGA_Screen/vga_pkg
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package pong_pkg is
    -- 控制向量: 按鈕和將來的鍵盤都先轉成這個格式, 遊戲邏輯不用管按鍵從哪來
    subtype ctrl_type is STD_LOGIC_VECTOR (6 downto 0);
    constant K_C    : integer := 0;                                -- 暫停 / 開新局; 3D 也用來發球
    constant K_UP   : integer := 1;                                -- P1 (2D 左拍, 3D 球拍) 上; 2D 也是 P1 的發球鍵
    constant K_DN   : integer := 2;                                -- P1 下
    constant K_LT   : integer := 3;                                -- 3D 球拍左
    constant K_RT   : integer := 4;                                -- 3D 球拍右
    constant K_P2UP : integer := 5;                                -- 2D 雙人時右拍上; 也是 P2 的發球鍵
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

    ---------------------------------------------------------------- 2D 側視球桌
    -- 直接用螢幕座標 (Y 向下), 從側面看: 桌子橫在下方, 網子在中間, 兩支球拍在桌子兩端外面
    -- 桌長對網高接近真的 2.74 m 對 15 cm, 網子畫高一點才看得清楚
    constant TBL2_Y   : integer := 560;                            -- 桌面
    constant TBL2_T   : integer := 12;                             -- 桌板厚度
    constant TX0      : integer := 192;                            -- 桌子左端
    constant TX1      : integer := 832;                            -- 桌子右端
    constant NET2_X   : integer := 512;
    constant NET2_H   : integer := 40;
    constant FLOOR2_Y : integer := 744;                            -- 地板 (球掉到這裡就算死球)
    constant RB2      : integer := 8;                              -- 球半徑
    constant PAD2_R   : integer := 28;                             -- 圓形拍面半徑 (比例上比真的球拍大一點)
    constant PL2_X    : integer := 96;                             -- 左拍中心 (只能上下移)
    constant PR2_X    : integer := SCR_W - PL2_X;                  -- 右拍中心
    constant P2_YMIN  : integer := 200;                            -- 拍心的上下範圍
    constant P2_YMAX  : integer := 720;
    constant P2_HOME  : integer := TBL2_Y - 100;                   -- 待命高度

    ---------------------------------------------------------------- 3D 球桌
    -- 世界座標: X 向右, Y 向下 (眼睛在 Y = 0), Z 往對面; 投影 螢幕 = (512 + X s, HZ_Y + Y s)
    -- 眼睛比桌面高 TBL_Y, 視平線 HZ_Y 在螢幕上方外面, 所以看起來是從斜上方往下看
    -- 玩家擊球面在 Z = 0 (桌子前緣後方), 電腦擊球面在 Z = Z_FAR; 桌子比例接近真的 2.74 x 1.525 m
    constant HZ_Y    : integer := -64;
    constant TBL_Y   : integer := 768;                             -- 桌面
    constant FLOOR_Y : integer := TBL_Y + 240;                     -- 地板 (球掉到這裡就算死球)
    constant TW      : integer := 240;                             -- 桌子半寬
    constant Z_T0    : integer := 96;                              -- 桌子近端
    constant Z_T1    : integer := 924;                             -- 桌子遠端
    constant Z_NET   : integer := 510;
    constant NET_H   : integer := 48;
    constant NET_HW  : integer := TW + 16;                         -- 網子比桌子寬一點
    constant Z_FAR   : integer := 1020;
    constant RB      : integer := 20;                              -- 球半徑
    constant PAD_R   : integer := 72;                              -- 圓形球拍半徑
    constant GRAV    : integer := 10;                              -- 重力 0.625 像素 / frame^2 (Q.4)
    -- 球拍可以移到桌子外面一點, 才接得到斜飛出去的球
    constant PXMAX   : integer := TW + 160;
    constant PYMIN   : integer := TBL_Y - 360;
    constant PYMAX   : integer := TBL_Y + 40;
    -- 待命高度: 球彈起來飛到擊球面時大多在桌面上方 160 ~ 190, 站在這裡多半只要左右移
    constant PY_HOME : integer := TBL_Y - 180;

    -- 透視: s(z) = D / (D + z), Q.10 (1024 = 1.0); D = 768 時最遠處約 0.43 倍
    constant PERSP_D : integer := 768;
    type scale_table is array (0 to 255) of integer range 0 to 1024;
    constant SCALE   : scale_table;                                -- 索引 = z / 4, 在 package body 算好
    constant S_FAR   : integer;                                    -- SCALE(255), 電腦擊球面
    -- 桌面上的固定深度投影到螢幕的列 (桌面那一列 y 只跟深度有關)
    constant Y_NEAR  : integer;                                    -- 桌子近端
    constant Y_FAR   : integer;                                    -- 桌子遠端
    constant Y_NET   : integer;                                    -- 網子底
    constant Y_NETT  : integer;                                    -- 網子頂
    constant NEAR_HW : integer;                                    -- 近端桌緣的半寬 (螢幕像素)
    constant NET_SHW : integer;                                    -- 網子的半寬 (螢幕像素)

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

    constant SCALE   : scale_table := make_scale;
    constant S_FAR   : integer := SCALE(255);
    constant Y_NEAR  : integer := HZ_Y + TBL_Y * SCALE(Z_T0 / 4) / 1024;
    constant Y_FAR   : integer := HZ_Y + TBL_Y * SCALE(Z_T1 / 4) / 1024;
    constant Y_NET   : integer := HZ_Y + TBL_Y * SCALE(Z_NET / 4) / 1024;
    constant Y_NETT  : integer := HZ_Y + (TBL_Y - NET_H) * SCALE(Z_NET / 4) / 1024;
    constant NEAR_HW : integer := TW * SCALE(Z_T0 / 4) / 1024;
    constant NET_SHW : integer := NET_HW * SCALE(Z_NET / 4) / 1024;

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
