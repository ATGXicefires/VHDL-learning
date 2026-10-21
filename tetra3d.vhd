----------------------------------------------------------------------------------
-- Module Name: tetra3d - Behavioral
-- Description: HW3 bonus 3D 旋轉三角錐 (正四面體), 延遲 LAT_TETRA 拍
--   每個 frame 從 rot3d_rom_pkg 依 angle 載入 4 個面 x 3 條邊的邊函數
--     E = A * X + B * Y + C  (A, B 已除以邊長, E 的單位直接是「到邊的像素距離」 * 2^14)
--   三條邊都 E >= 0 就在該面內; 背面的 C = -1, 永遠不會命中
--   凸多面體只要做背面剔除, 正面的面在螢幕上不會重疊, 所以不需要 z-buffer
--   solid = '1': 每面固定顏色乘上該面的 Lambert 明暗; '0': 只畫可見面的邊 (自動消去隱藏線)
--   座標: X 向右, Y 向上, 原點在畫面中央; big = '1' (1024x768 以上) 座標減半, 物體放大 2 倍
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;                                          -- 座標與邊函數是有號數
use work.vga_pkg.all;
use work.rot3d_rom_pkg.all;

entity tetra3d is
    Port ( CLK        : in  STD_LOGIC;
           RST        : in  STD_LOGIC;
           x          : in  coord_type;
           y          : in  coord_type;
           h_size     : in  coord_type;
           v_size     : in  coord_type;
           big        : in  STD_LOGIC;
           frame_tick : in  STD_LOGIC;
           angle      : in  STD_LOGIC_VECTOR (7 downto 0);
           solid      : in  STD_LOGIC;
           rgb        : out rgb_type);
end tetra3d;

architecture Behavioral of tetra3d is
    constant EDGE_T : integer := 3 * 2 ** 14;                      -- 空心時線寬 3 像素

    type ab12_type   is array (0 to 11) of signed (15 downto 0);
    type c12_type    is array (0 to 11) of signed (23 downto 0);
    type prod12_type is array (0 to 11) of signed (27 downto 0);
    type shade4_type is array (0 to 3) of unsigned (3 downto 0);
    type color4_type is array (0 to 3) of rgb_type;

    constant FACE_COLOR : color4_type := (x"F00", x"0F0", x"00F", x"FF0");

    signal ai             : integer range 0 to 255;
    signal ea, eb         : ab12_type;
    signal ec             : c12_type;
    signal face_shade     : shade4_type;

    signal dxr, dyr       : signed (11 downto 0);
    signal vx, vy         : signed (11 downto 0);
    signal pa, pb         : prod12_type;
    signal ev             : prod12_type;
    signal inside, near   : STD_LOGIC_VECTOR (3 downto 0);
    signal base           : rgb_type;
    signal shade          : unsigned (3 downto 0);
    signal rgb_r          : rgb_type;
begin
    ai <= to_integer(unsigned(angle));

    load_a: process(CLK, RST)
        begin
            if RST = '0' then
                ea <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    for e in 0 to 11 loop
                        ea(e) <= to_signed(TET_A(ai, e), 16);
                    end loop;
                end if;
            end if;
        end process;

    load_b: process(CLK, RST)
        begin
            if RST = '0' then
                eb <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    for e in 0 to 11 loop
                        eb(e) <= to_signed(TET_B(ai, e), 16);
                    end loop;
                end if;
            end if;
        end process;

    -- 重置值 -1: 第一個 frame_tick 前所有面都不命中, 不會閃出亂碼
    load_c: process(CLK, RST)
        begin
            if RST = '0' then
                ec <= (others => to_signed(-1, 24));
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    for e in 0 to 11 loop
                        ec(e) <= to_signed(TET_C(ai, e), 24);
                    end loop;
                end if;
            end if;
        end process;

    load_shade: process(CLK, RST)
        begin
            if RST = '0' then
                face_shade <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    for f in 0 to 3 loop
                        face_shade(f) <= to_unsigned(TET_SHADE(ai, f), 4);
                    end loop;
                end if;
            end if;
        end process;

    -- 用 resize 而不是 '0' & ...: coord3_type 也有 & 運算子, 字串常數接在前面時型別會有歧義
    dxr <= signed(resize(unsigned(x), 12)) - signed(resize(unsigned(h_size(10 downto 1)), 12));
    dyr <= signed(resize(unsigned(v_size(10 downto 1)), 12)) - signed(resize(unsigned(y), 12));

    vx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if big = '1' then
                    vx <= shift_right(dxr, 1);
                else
                    vx <= dxr;
                end if;
            end if;
        end process;

    vy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if big = '1' then
                    vy <= shift_right(dyr, 1);
                else
                    vy <= dyr;
                end if;
            end if;
        end process;

    pa_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pa <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                for e in 0 to 11 loop
                    pa(e) <= ea(e) * vx;
                end loop;
            end if;
        end process;

    pb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pb <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                for e in 0 to 11 loop
                    pb(e) <= eb(e) * vy;
                end loop;
            end if;
        end process;

    ev_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ev <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                for e in 0 to 11 loop
                    ev(e) <= pa(e) + pb(e) + resize(ec(e), 28);
                end loop;
            end if;
        end process;

    inside_reg: process(CLK, RST)
        begin
            if RST = '0' then
                inside <= "0000";
            elsif CLK'event and CLK = '1' then
                for f in 0 to 3 loop
                    if ev(3 * f) >= 0 and ev(3 * f + 1) >= 0 and ev(3 * f + 2) >= 0 then
                        inside(f) <= '1';
                    else
                        inside(f) <= '0';
                    end if;
                end loop;
            end if;
        end process;

    near_reg: process(CLK, RST)
        begin
            if RST = '0' then
                near <= "0000";
            elsif CLK'event and CLK = '1' then
                for f in 0 to 3 loop
                    if ev(3 * f) >= 0 and ev(3 * f + 1) >= 0 and ev(3 * f + 2) >= 0
                       and (ev(3 * f) < EDGE_T or ev(3 * f + 1) < EDGE_T or ev(3 * f + 2) < EDGE_T) then
                        near(f) <= '1';
                    else
                        near(f) <= '0';
                    end if;
                end loop;
            end if;
        end process;

    -- 兩個面共用的邊上兩面都算命中, 取編號小的那面
    base_reg: process(CLK, RST)
        begin
            if RST = '0' then
                base <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if solid = '0' then
                    if near /= "0000" then
                        base <= x"FFF";
                    else
                        base <= (others => '0');
                    end if;
                elsif inside(0) = '1' then
                    base <= FACE_COLOR(0);
                elsif inside(1) = '1' then
                    base <= FACE_COLOR(1);
                elsif inside(2) = '1' then
                    base <= FACE_COLOR(2);
                elsif inside(3) = '1' then
                    base <= FACE_COLOR(3);
                else
                    base <= (others => '0');
                end if;
            end if;
        end process;

    shade_reg: process(CLK, RST)
        begin
            if RST = '0' then
                shade <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if solid = '0' then
                    shade <= "1111";
                elsif inside(0) = '1' then
                    shade <= face_shade(0);
                elsif inside(1) = '1' then
                    shade <= face_shade(1);
                elsif inside(2) = '1' then
                    shade <= face_shade(2);
                else
                    shade <= face_shade(3);
                end if;
            end if;
        end process;

    -- 每色 c * (shade + 1) / 16: shade = 15 時剛好保持原色
    rgb_reg: process(CLK, RST)
        variable k : unsigned (4 downto 0);
        begin
            if RST = '0' then
                rgb_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                k := resize(shade, 5) + 1;
                rgb_r(11 downto 8) <= std_logic_vector(resize(shift_right(unsigned(base(11 downto 8)) * k, 4), 4));
                rgb_r(7 downto 4)  <= std_logic_vector(resize(shift_right(unsigned(base(7 downto 4)) * k, 4), 4));
                rgb_r(3 downto 0)  <= std_logic_vector(resize(shift_right(unsigned(base(3 downto 0)) * k, 4), 4));
            end if;
        end process;

    rgb <= rgb_r;
end Behavioral;
