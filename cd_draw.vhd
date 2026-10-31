----------------------------------------------------------------------------------
-- Module Name: cd_draw - Behavioral
-- Description: 畫 CD (延遲 LAT_CD 拍), 圓心 (cd_x, cd_y) 是 cd_ctrl 給的邏輯座標
--   由內到外 (半徑): < 8 中心孔 (透出背景), < 22 透明塑膠轂, < 26 鏡面環, < 62 資料區, < 64 外緣
--   資料區 solid = '1': 彩虹反光, 色相 = 2 * 角度 + spin
--     CD 的繞射紋是兩個相對的扇形 (蝴蝶結狀), 所以用 2 倍角; spin 一直加就像整片在轉
--     不算 atan: (|dx| >> 1, |dy| >> 1) 查 ATAN_ROM 得象限內角度, 再依 dx, dy 正負補成整圈
--   solid = '0': 單色, 顏色由 tint 決定 (每撞一次牆換一色, 致敬 DVD 螢幕保護程式)
--   flash = '1' 時背景變灰 (撞進角落)
--   big = '1' (1024x768 以上) 時座標減半, CD 放大 2 倍
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;                                          -- dx, dy 是有號數
use work.vga_pkg.all;
use work.game_rom_pkg.all;

entity cd_draw is
    Port ( CLK   : in  STD_LOGIC;
           RST   : in  STD_LOGIC;
           x     : in  coord_type;
           y     : in  coord_type;
           big   : in  STD_LOGIC;
           cd_x  : in  coord_type;
           cd_y  : in  coord_type;
           spin  : in  STD_LOGIC_VECTOR (7 downto 0);
           tint  : in  STD_LOGIC_VECTOR (2 downto 0);
           flash : in  STD_LOGIC;
           solid : in  STD_LOGIC;
           rgb   : out rgb_type);
end cd_draw;

architecture Behavioral of cd_draw is
    constant HOLE_R   : integer := 8;
    constant HUB_R    : integer := 22;
    constant MIRROR_R : integer := 26;
    constant DATA_R   : integer := 62;
    constant R        : integer := 64;                             -- 和 cd_ctrl 的反彈半徑一致

    subtype ring_type is STD_LOGIC_VECTOR (2 downto 0);
    constant RING_BG     : ring_type := "000";
    constant RING_HUB    : ring_type := "001";
    constant RING_MIRROR : ring_type := "010";
    constant RING_DATA   : ring_type := "011";
    constant RING_RIM    : ring_type := "100";

    type tint_table is array (0 to 7) of rgb_type;
    constant TINT_COLOR : tint_table := (x"F33", x"F93", x"FF3", x"3F5", x"3FF", x"45F", x"F4F", x"FFF");

    signal px, py           : unsigned (10 downto 0);
    signal dx, dy           : signed (11 downto 0);
    signal adx, ady         : unsigned (11 downto 0);
    signal dx2, dy2         : unsigned (21 downto 0);
    signal addr             : unsigned (9 downto 0);
    signal quad, quad_3     : STD_LOGIC_VECTOR (1 downto 0);       -- (dx < 0, dy < 0)
    signal r2               : unsigned (22 downto 0);
    signal a6               : unsigned (5 downto 0);
    signal ring, ring_5     : ring_type;
    signal theta            : unsigned (7 downto 0);
    signal hue              : unsigned (7 downto 0);
    signal bg               : rgb_type;
    signal rgb_r            : rgb_type;
begin
    px <= unsigned('0' & x(10 downto 1)) when big = '1' else unsigned(x);
    py <= unsigned('0' & y(10 downto 1)) when big = '1' else unsigned(y);

    dx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dx <= signed('0' & px) - signed('0' & cd_x);
            end if;
        end process;

    dy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dy <= signed('0' & py) - signed('0' & cd_y);
            end if;
        end process;

    adx <= unsigned(abs(dx));
    ady <= unsigned(abs(dy));

    dx2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dx2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dx2 <= unsigned(resize(dx * dx, 22));
            end if;
        end process;

    dy2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dy2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dy2 <= unsigned(resize(dy * dy, 22));
            end if;
        end process;

    -- |dx| 或 |dy| >= 64 時位址會繞回來, 但那些像素都在 CD 外面 (r >= 64), 用不到角度
    addr_reg: process(CLK, RST)
        begin
            if RST = '0' then
                addr <= (others => '0');
            elsif CLK'event and CLK = '1' then
                addr <= adx(5 downto 1) & ady(5 downto 1);
            end if;
        end process;

    quad_reg: process(CLK, RST)
        begin
            if RST = '0' then
                quad <= "00";
            elsif CLK'event and CLK = '1' then
                quad <= dx(11) & dy(11);
            end if;
        end process;

    r2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                r2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                r2 <= resize(dx2, 23) + dy2;
            end if;
        end process;

    a6_reg: process(CLK, RST)
        begin
            if RST = '0' then
                a6 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                a6 <= to_unsigned(ATAN_ROM(to_integer(addr)), 6);
            end if;
        end process;

    quad_3_reg: process(CLK, RST)
        begin
            if RST = '0' then
                quad_3 <= "00";
            elsif CLK'event and CLK = '1' then
                quad_3 <= quad;
            end if;
        end process;

    ring_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ring <= RING_BG;
            elsif CLK'event and CLK = '1' then
                if r2 < HOLE_R * HOLE_R then
                    ring <= RING_BG;
                elsif r2 < HUB_R * HUB_R then
                    ring <= RING_HUB;
                elsif r2 < MIRROR_R * MIRROR_R then
                    ring <= RING_MIRROR;
                elsif r2 < DATA_R * DATA_R then
                    ring <= RING_DATA;
                elsif r2 < R * R then
                    ring <= RING_RIM;
                else
                    ring <= RING_BG;
                end if;
            end if;
        end process;

    -- 一圈 256 格; 只要整圈連續就好, 從哪個方向起算不重要
    theta_reg: process(CLK, RST)
        begin
            if RST = '0' then
                theta <= (others => '0');
            elsif CLK'event and CLK = '1' then
                case quad_3 is
                    when "00"   => theta <= resize(a6, 8);
                    when "10"   => theta <= 128 - resize(a6, 8);
                    when "11"   => theta <= 128 + resize(a6, 8);
                    when others => theta <= 0 - resize(a6, 8);
                end case;
            end if;
        end process;

    ring_5_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ring_5 <= RING_BG;
            elsif CLK'event and CLK = '1' then
                ring_5 <= ring;
            end if;
        end process;

    hue_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hue <= (others => '0');
            elsif CLK'event and CLK = '1' then
                hue <= (theta(6 downto 0) & '0') + unsigned(spin);
            end if;
        end process;

    bg <= x"333" when flash = '1' else x"000";

    rgb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                case ring_5 is
                    when RING_HUB    => rgb_r <= x"556";
                    when RING_MIRROR => rgb_r <= x"EEE";
                    when RING_DATA   =>
                        if solid = '1' then
                            rgb_r <= RAINBOW(to_integer(hue(7 downto 3)));
                        else
                            rgb_r <= TINT_COLOR(to_integer(unsigned(tint)));
                        end if;
                    when RING_RIM    => rgb_r <= x"999";
                    when others      => rgb_r <= bg;
                end case;
            end if;
        end process;

    rgb <= rgb_r;
end Behavioral;
