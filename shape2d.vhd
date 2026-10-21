----------------------------------------------------------------------------------
-- Module Name: shape2d - Behavioral
-- Description: HW3 bonus 色塊圖形: 橢圓 / 圓 / 三角形, 空心或實心 (延遲 LAT_SHAPE 拍)
--   kind: "00" = 橢圓 (半軸 a, b), "01" = 圓 (半徑 a), "10" = 頂點朝上的等腰三角形 (半底 a, 半高 b)
--   (cx, cy) = 中心; 判斷式全部化成乘法和比較, 不需要除法:
--     橢圓   dx^2 * b^2 + dy^2 * a^2 < a^2 * b^2  (用 < : 用 <= 時 4 個極點會各凸出 1 個像素)
--     圓     dx^2 + dy^2 < a^2
--     三角形 s = a * (dy + b) - 2b * |dx| >= 0 且 dy <= b  (s 正比於點到斜邊的距離)
--   空心 = 在外形內但不在內縮 BORDER 的內形內
--   a, b 上限 360 (btn_ctrl 會夾住): a^2 < 2^17, 每個乘法剛好塞進 1 顆 DSP48 (25 x 18)
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;                                          -- dx, dy 是有號數
use work.vga_pkg.all;

entity shape2d is
    Port ( CLK   : in  STD_LOGIC;
           RST   : in  STD_LOGIC;
           x     : in  coord_type;
           y     : in  coord_type;
           kind  : in  STD_LOGIC_VECTOR (1 downto 0);
           solid : in  STD_LOGIC;
           cx    : in  coord_type;
           cy    : in  coord_type;
           a     : in  STD_LOGIC_VECTOR (8 downto 0);
           b     : in  STD_LOGIC_VECTOR (8 downto 0);
           rgb   : out rgb_type);
end shape2d;

architecture Behavioral of shape2d is
    constant BORDER : integer := 4;

    signal a_u, b_u, ai, bi : unsigned (8 downto 0);
    signal b_x2             : unsigned (9 downto 0);
    signal b_in             : signed (11 downto 0);
    signal a2, b2, ai2, bi2 : unsigned (16 downto 0);
    signal ab2, aibi2       : unsigned (33 downto 0);
    signal tri_tl           : unsigned (12 downto 0);

    signal dx, dy           : signed (11 downto 0);
    signal dx2, dy2         : unsigned (21 downto 0);
    signal adx              : unsigned (11 downto 0);
    signal dyb              : signed (12 downto 0);
    signal dy_2, dy_3       : signed (11 downto 0);

    signal p_ex, p_ey, q_ex, q_ey : unsigned (38 downto 0);
    signal t_ab, t_bx             : signed (22 downto 0);
    signal c_sum                  : unsigned (22 downto 0);

    signal tri_s                  : signed (22 downto 0);
    signal ell_out, ell_in        : STD_LOGIC;
    signal cir_out, cir_in        : STD_LOGIC;
    signal tri_out, tri_in        : STD_LOGIC;
    signal hit_out, hit_in        : STD_LOGIC;
    signal hits                   : STD_LOGIC_VECTOR (1 downto 0);
    signal shape_color            : rgb_type;
    signal rgb_r                  : rgb_type;
begin
    a_u  <= unsigned(a);
    b_u  <= unsigned(b);
    ai   <= a_u - BORDER when a_u > BORDER else (others => '0');
    bi   <= b_u - BORDER when b_u > BORDER else (others => '0');
    b_x2 <= b_u & '0';
    b_in <= signed(resize(b_u, 12)) - BORDER;

    -- a, b 只在 frame_tick 改變, 下面這串參數晚幾拍才更新也不會畫錯
    a2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                a2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                a2 <= resize(a_u * a_u, 17);
            end if;
        end process;

    b2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                b2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                b2 <= resize(b_u * b_u, 17);
            end if;
        end process;

    ai2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ai2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ai2 <= resize(ai * ai, 17);
            end if;
        end process;

    bi2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                bi2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                bi2 <= resize(bi * bi, 17);
            end if;
        end process;

    ab2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ab2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ab2 <= a2 * b2;
            end if;
        end process;

    aibi2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                aibi2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                aibi2 <= ai2 * bi2;
            end if;
        end process;

    -- 內三角形斜邊往內推 BORDER 像素, 對應 s 的門檻是 BORDER * sqrt(a^2 + 4b^2);
    -- sqrt 用 max + 3/8 * min 近似 (誤差 < 7%), 邊框粗細差不到半個像素
    tri_tl_reg: process(CLK, RST)
        variable hi, lo : unsigned (12 downto 0);
        begin
            if RST = '0' then
                tri_tl <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if ('0' & a_u) > b_x2 then
                    hi := resize(a_u, 13);
                    lo := resize(b_x2, 13);
                else
                    hi := resize(b_x2, 13);
                    lo := resize(a_u, 13);
                end if;
                tri_tl <= resize(hi * BORDER + shift_right(lo * (3 * BORDER), 3), 13);
            end if;
        end process;

    dx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dx <= signed('0' & x) - signed('0' & cx);
            end if;
        end process;

    dy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dy <= signed('0' & y) - signed('0' & cy);
            end if;
        end process;

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

    adx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                adx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                adx <= unsigned(abs(dx));
            end if;
        end process;

    dyb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dyb <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dyb <= resize(dy, 13) + signed(resize(b_u, 13));
            end if;
        end process;

    dy_2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dy_2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dy_2 <= dy;
            end if;
        end process;

    p_ex_reg: process(CLK, RST)
        begin
            if RST = '0' then
                p_ex <= (others => '0');
            elsif CLK'event and CLK = '1' then
                p_ex <= dx2 * b2;
            end if;
        end process;

    p_ey_reg: process(CLK, RST)
        begin
            if RST = '0' then
                p_ey <= (others => '0');
            elsif CLK'event and CLK = '1' then
                p_ey <= dy2 * a2;
            end if;
        end process;

    q_ex_reg: process(CLK, RST)
        begin
            if RST = '0' then
                q_ex <= (others => '0');
            elsif CLK'event and CLK = '1' then
                q_ex <= dx2 * bi2;
            end if;
        end process;

    q_ey_reg: process(CLK, RST)
        begin
            if RST = '0' then
                q_ey <= (others => '0');
            elsif CLK'event and CLK = '1' then
                q_ey <= dy2 * ai2;
            end if;
        end process;

    t_ab_reg: process(CLK, RST)
        begin
            if RST = '0' then
                t_ab <= (others => '0');
            elsif CLK'event and CLK = '1' then
                t_ab <= dyb * signed('0' & a_u);
            end if;
        end process;

    t_bx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                t_bx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                t_bx <= signed(resize(adx * b_x2, 23));
            end if;
        end process;

    c_sum_reg: process(CLK, RST)
        begin
            if RST = '0' then
                c_sum <= (others => '0');
            elsif CLK'event and CLK = '1' then
                c_sum <= resize(dx2, 23) + dy2;
            end if;
        end process;

    dy_3_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dy_3 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dy_3 <= dy_2;
            end if;
        end process;

    tri_s <= t_ab - t_bx;

    ell_out <= '1' when resize(p_ex, 40) + p_ey < ab2 else '0';
    ell_in  <= '1' when resize(q_ex, 40) + q_ey < aibi2 else '0';
    cir_out <= '1' when c_sum < a2 else '0';
    cir_in  <= '1' when c_sum < ai2 else '0';
    tri_out <= '1' when tri_s >= 0 and dy_3 <= signed(resize(b_u, 12)) else '0';
    tri_in  <= '1' when tri_s >= signed('0' & tri_tl) and dy_3 <= b_in else '0';

    with kind select
        hit_out <= ell_out when "00",
                   cir_out when "01",
                   tri_out when others;

    with kind select
        hit_in <= ell_in when "00",
                  cir_in when "01",
                  tri_in when others;

    hits_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hits <= "00";
            elsif CLK'event and CLK = '1' then
                hits <= hit_out & hit_in;
            end if;
        end process;

    with kind select
        shape_color <= x"0FF" when "00",
                       x"FF0" when "01",
                       x"F0F" when others;

    rgb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if hits(1) = '1' and (solid = '1' or hits(0) = '0') then
                    rgb_r <= shape_color;
                else
                    rgb_r <= (others => '0');
                end if;
            end if;
        end process;

    rgb <= rgb_r;
end Behavioral;
