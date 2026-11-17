----------------------------------------------------------------------------------
-- Module Name: ball3d - Behavioral
-- Description: HW3 bonus 3D 旋轉球 / 橄欖球 (正交投影的橢球光線投射), 延遲 LAT_BALL 拍
--   kind = '1' 球 (海灘球配色), '0' 橄欖球 (棕色本體 + 兩端白條紋 + 縫線)
--   球就是三軸相等的橢球, 兩者共用同一條管線, 只有參數 ROM 和貼圖不同
--
--   每個 frame 從 rot3d_rom_pkg 依 angle 載入參數 (旋轉矩陣的三角函數和除法都由 tools/gen_rom.py 先算好):
--     輪廓  Q = QA X^2 + QB XY + QC Y^2 < 1         (橢球沿視線方向的投影)
--     深度  Z = ZX X + ZY Y + H sqrt(1 - Q)          (面向觀察者那一面)
--     物體座標 (u, v, w) = N (X, Y, Z), 落在單位球面上, 拿來貼圖
--     明暗  dot = (u, v, w) . L                      (L 是轉到物體座標的光源方向)
--   各數值的定點格式見 tools/gen_rom.py; tools/model3d.py 是這條管線逐位元相同的 Python 模型
--   solid = '0' 時改畫經緯線與輪廓線 (空心)
--   管線級數 (下面註解裡的 Sn): S1 座標, S2 平方項, S3 乘係數, S4 Q, S5 輪廓判斷, S6 sqrt,
--     S7 H * sqrt, S8 Z, S9 ~ S10 物體座標, S11 ~ S12 明暗與經線, S13 貼圖, S14 輸出
--   座標: X 向右, Y 向上, 原點在畫面中央; big = '1' (1024x768 以上) 座標減半, 物體放大 2 倍
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;                                          -- 座標與係數是有號數
use work.vga_pkg.all;
use work.rot3d_rom_pkg.all;

entity ball3d is
    Port ( CLK        : in  STD_LOGIC;
           RST        : in  STD_LOGIC;
           x          : in  coord_type;
           y          : in  coord_type;
           h_size     : in  coord_type;
           v_size     : in  coord_type;
           big        : in  STD_LOGIC;
           frame_tick : in  STD_LOGIC;
           angle      : in  STD_LOGIC_VECTOR (7 downto 0);
           kind       : in  STD_LOGIC;
           solid      : in  STD_LOGIC;
           rgb        : out rgb_type);
end ball3d;

architecture Behavioral of ball3d is
    -- 以下門檻都是 Q.10 (1024 = 1.0), 和 tools/model3d.py 一致
    constant LINE_T    : integer := 28;                            -- 經線半寬
    constant LAT_T     : integer := 20;                            -- 緯線半寬
    constant RIM_Q     : integer := 1024 - 40;                     -- 輪廓線: Q 接近 1 的外圈
    constant CAP_V     : integer := 940;                           -- 球的白色極冠
    constant STRIPE_LO : integer := 600;                           -- 橄欖球兩端白條紋
    constant STRIPE_HI : integer := 700;
    constant LACE_U    : integer := 380;                           -- 縫線長度
    constant LACE_W    : integer := 30;
    constant STITCH_W  : integer := 90;
    constant COS30     : integer := 887;                           -- cos(30 度) * 1024, 算 60/120 度經線

    type n9_type    is array (0 to 8) of signed (17 downto 0);
    type l3_type    is array (0 to 2) of signed (11 downto 0);
    type prod9_type is array (0 to 8) of signed (29 downto 0);
    type uvw_type   is array (0 to 2) of signed (13 downto 0);
    type dl3_type   is array (0 to 2) of signed (25 downto 0);
    type xy7_type   is array (1 to 7) of signed (11 downto 0);

    signal ai               : integer range 0 to 255;
    signal loaded           : STD_LOGIC;
    signal qa, qb, qc       : signed (17 downto 0);
    signal zx, zy           : signed (17 downto 0);
    signal hh               : unsigned (7 downto 0);
    signal nm               : n9_type;
    signal lv               : l3_type;

    signal dxr, dyr         : signed (11 downto 0);
    signal vx, vy           : signed (11 downto 0);
    signal vx_d, vy_d       : xy7_type;                            -- X, Y 一路延遲到 S8 給 N 矩陣用
    signal xx, xy, yy       : signed (20 downto 0);
    signal pzx, pzy         : signed (29 downto 0);
    signal ta, tb, tc       : signed (38 downto 0);
    signal zlin             : signed (15 downto 0);
    signal zlin_v, zlin_dv  : STD_LOGIC_VECTOR (15 downto 0);
    signal zlin_d           : signed (15 downto 0);
    signal qsum             : signed (40 downto 0);
    signal inside           : STD_LOGIC;
    signal rim              : STD_LOGIC;
    signal sq_idx           : unsigned (9 downto 0);
    signal sq               : unsigned (9 downto 0);
    signal hs               : unsigned (17 downto 0);
    signal vz               : signed (11 downto 0);
    signal prod             : prod9_type;
    signal uvw              : uvw_type;
    signal uvw_d            : uvw_type;
    signal dl               : dl3_type;
    signal pk               : signed (24 downto 0);
    signal dot              : signed (13 downto 0);
    signal d0, d60, d120    : signed (13 downto 0);
    signal flag_d           : STD_LOGIC_VECTOR (15 downto 0);      -- inside & rim 由 S5 往後延遲
    signal ins_13, rim_12   : STD_LOGIC;
    signal ap               : signed (13 downto 0);
    signal ax_12, au_12     : signed (13 downto 0);
    signal uvw_12           : uvw_type;
    signal on_line          : STD_LOGIC;
    signal gore             : STD_LOGIC_VECTOR (2 downto 0);
    signal gore_color       : rgb_type;
    signal lace, stripe     : STD_LOGIC;
    signal base             : rgb_type;
    signal shade            : unsigned (3 downto 0);
    signal rgb_r            : rgb_type;
begin
    ai <= to_integer(unsigned(angle));

    load_qa: process(CLK, RST)
        begin
            if RST = '0' then
                qa <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    if kind = '1' then
                        qa <= to_signed(SPH_QA(ai), 18);
                    else
                        qa <= to_signed(RUG_QA(ai), 18);
                    end if;
                end if;
            end if;
        end process;

    load_qb: process(CLK, RST)
        begin
            if RST = '0' then
                qb <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    if kind = '1' then
                        qb <= to_signed(SPH_QB(ai), 18);
                    else
                        qb <= to_signed(RUG_QB(ai), 18);
                    end if;
                end if;
            end if;
        end process;

    load_qc: process(CLK, RST)
        begin
            if RST = '0' then
                qc <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    if kind = '1' then
                        qc <= to_signed(SPH_QC(ai), 18);
                    else
                        qc <= to_signed(RUG_QC(ai), 18);
                    end if;
                end if;
            end if;
        end process;

    load_zx: process(CLK, RST)
        begin
            if RST = '0' then
                zx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    if kind = '1' then
                        zx <= to_signed(SPH_ZX(ai), 18);
                    else
                        zx <= to_signed(RUG_ZX(ai), 18);
                    end if;
                end if;
            end if;
        end process;

    load_zy: process(CLK, RST)
        begin
            if RST = '0' then
                zy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    if kind = '1' then
                        zy <= to_signed(SPH_ZY(ai), 18);
                    else
                        zy <= to_signed(RUG_ZY(ai), 18);
                    end if;
                end if;
            end if;
        end process;

    load_h: process(CLK, RST)
        begin
            if RST = '0' then
                hh <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    if kind = '1' then
                        hh <= to_unsigned(SPH_H(ai), 8);
                    else
                        hh <= to_unsigned(RUG_H(ai), 8);
                    end if;
                end if;
            end if;
        end process;

    load_n: process(CLK, RST)
        begin
            if RST = '0' then
                nm <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    for i in 0 to 8 loop
                        if kind = '1' then
                            nm(i) <= to_signed(SPH_N(ai, i), 18);
                        else
                            nm(i) <= to_signed(RUG_N(ai, i), 18);
                        end if;
                    end loop;
                end if;
            end if;
        end process;

    load_l: process(CLK, RST)
        begin
            if RST = '0' then
                lv <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    for i in 0 to 2 loop
                        if kind = '1' then
                            lv(i) <= to_signed(SPH_L(ai, i), 12);
                        else
                            lv(i) <= to_signed(RUG_L(ai, i), 12);
                        end if;
                    end loop;
                end if;
            end if;
        end process;

    -- 用 resize 而不是 '0' & ...: coord3_type 也有 & 運算子, 字串常數接在前面時型別會有歧義
    -- 第一個 frame_tick 前參數全是 0, Q = 0 會讓整個畫面都被當成在輪廓內
    loaded_reg: process(CLK, RST)
        begin
            if RST = '0' then
                loaded <= '0';
            elsif CLK'event and CLK = '1' then
                if frame_tick = '1' then
                    loaded <= '1';
                end if;
            end if;
        end process;

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

    vx_pipe: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                vx_d(1) <= vx;
                for i in 2 to 7 loop
                    vx_d(i) <= vx_d(i - 1);
                end loop;
            end if;
        end process;

    vy_pipe: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                vy_d(1) <= vy;
                for i in 2 to 7 loop
                    vy_d(i) <= vy_d(i - 1);
                end loop;
            end if;
        end process;

    xx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                xx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                xx <= resize(vx * vx, 21);
            end if;
        end process;

    xy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                xy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                xy <= resize(vx * vy, 21);
            end if;
        end process;

    yy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                yy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                yy <= resize(vy * vy, 21);
            end if;
        end process;

    pzx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pzx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                pzx <= zx * vx;
            end if;
        end process;

    pzy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pzy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                pzy <= zy * vy;
            end if;
        end process;

    ta_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ta <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ta <= qa * xx;
            end if;
        end process;

    tb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tb <= (others => '0');
            elsif CLK'event and CLK = '1' then
                tb <= qb * xy;
            end if;
        end process;

    tc_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tc <= (others => '0');
            elsif CLK'event and CLK = '1' then
                tc <= qc * yy;
            end if;
        end process;

    zlin_reg: process(CLK, RST)
        begin
            if RST = '0' then
                zlin <= (others => '0');
            elsif CLK'event and CLK = '1' then
                zlin <= resize(shift_right(resize(pzx, 31) + pzy, 14), 16);
            end if;
        end process;

    qsum_reg: process(CLK, RST)
        begin
            if RST = '0' then
                qsum <= (others => '0');
            elsif CLK'event and CLK = '1' then
                qsum <= resize(ta, 41) + tb + tc;
            end if;
        end process;

    -- zlin 從 S3 延遲到 S7, 和 hs 一起在 S8 相加
    zlin_v <= std_logic_vector(zlin);

    zlin_pipe: entity work.delay_line
        generic map ( WIDTH => 16, DEPTH => 4 )
        port map ( CLK => CLK, din => zlin_v, dout => zlin_dv );

    zlin_d <= signed(zlin_dv);

    -- Q < 1 對應 qsum < 2^29, Q 的 Q.10 值就是 qsum(28..19)
    inside_reg: process(CLK, RST)
        begin
            if RST = '0' then
                inside <= '0';
            elsif CLK'event and CLK = '1' then
                if loaded = '1' and qsum >= 0 and qsum < 2 ** 29 then
                    inside <= '1';
                else
                    inside <= '0';
                end if;
            end if;
        end process;

    rim_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rim <= '0';
            elsif CLK'event and CLK = '1' then
                if unsigned(qsum(28 downto 19)) >= RIM_Q then
                    rim <= '1';
                else
                    rim <= '0';
                end if;
            end if;
        end process;

    sq_idx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sq_idx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sq_idx <= 1023 - unsigned(qsum(28 downto 19));
            end if;
        end process;

    sq_reg: process(CLK, RST)
        begin
            if RST = '0' then
                sq <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sq <= to_unsigned(SQRT_ROM(to_integer(sq_idx)), 10);
            end if;
        end process;

    hs_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hs <= (others => '0');
            elsif CLK'event and CLK = '1' then
                hs <= hh * sq;
            end if;
        end process;

    vz_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vz <= (others => '0');
            elsif CLK'event and CLK = '1' then
                vz <= resize(zlin_d + signed(resize(shift_right(hs, 10), 16)), 12);
            end if;
        end process;

    -- vx_d(7) / vy_d(7) 和 vz 都在 S8, 是同一個像素
    prod_reg: process(CLK, RST)
        begin
            if RST = '0' then
                prod <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    prod(3 * i)     <= nm(3 * i) * vx_d(7);
                    prod(3 * i + 1) <= nm(3 * i + 1) * vy_d(7);
                    prod(3 * i + 2) <= nm(3 * i + 2) * vz;
                end loop;
            end if;
        end process;

    uvw_reg: process(CLK, RST)
        begin
            if RST = '0' then
                uvw <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    uvw(i) <= resize(shift_right(resize(prod(3 * i), 32) + prod(3 * i + 1) + prod(3 * i + 2), 10), 14);
                end loop;
            end if;
        end process;

    -- 球繞 v 自轉, 橄欖球長軸是 u; 經線畫在和軸垂直的 (p, w) 平面上, p = 另一個座標
    ap <= uvw(0) when kind = '1' else uvw(1);

    dl_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dl <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                for i in 0 to 2 loop
                    dl(i) <= uvw(i) * lv(i);
                end loop;
            end if;
        end process;

    pk_reg: process(CLK, RST)
        begin
            if RST = '0' then
                pk <= (others => '0');
            elsif CLK'event and CLK = '1' then
                pk <= ap * to_signed(COS30, 11);
            end if;
        end process;

    uvw_d_reg: process(CLK, RST)
        begin
            if RST = '0' then
                uvw_d <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                uvw_d <= uvw;
            end if;
        end process;

    dot_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dot <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dot <= resize(shift_right(resize(dl(0), 28) + dl(1) + dl(2), 10), 14);
            end if;
        end process;

    d0_reg: process(CLK, RST)
        begin
            if RST = '0' then
                d0 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                d0 <= uvw_d(2);
            end if;
        end process;

    -- 60 / 120 度經線: d = +-q / 2 - p * cos30; 和 0 度經線 d0 = q 一起把 (p, q) 平面切成 6 瓣
    d60_reg: process(CLK, RST)
        begin
            if RST = '0' then
                d60 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                d60 <= shift_right(uvw_d(2), 1) - resize(shift_right(pk, 10), 14);
            end if;
        end process;

    d120_reg: process(CLK, RST)
        begin
            if RST = '0' then
                d120 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                d120 <= -shift_right(uvw_d(2), 1) - resize(shift_right(pk, 10), 14);
            end if;
        end process;

    ax_12_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ax_12 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if kind = '1' then
                    ax_12 <= uvw_d(1);
                else
                    ax_12 <= uvw_d(0);
                end if;
            end if;
        end process;

    uvw_12_reg: process(CLK, RST)
        begin
            if RST = '0' then
                uvw_12 <= (others => (others => '0'));
            elsif CLK'event and CLK = '1' then
                uvw_12 <= uvw_d;
            end if;
        end process;

    flag_pipe: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                flag_d <= flag_d(13 downto 0) & inside & rim;
            end if;
        end process;

    -- flag_d 每拍左移 2 位, 第 k 組 (bit 2k-1..2k-2) 是 S5 的旗標延遲到 S(5+k)
    ins_13 <= flag_d(15);
    rim_12 <= flag_d(12);

    au_12 <= abs(uvw_12(0));

    on_line <= '1' when abs(d0) < LINE_T or abs(d60) < LINE_T or abs(d120) < LINE_T
                        or abs(ax_12) < LAT_T or abs(abs(ax_12) - 512) < LAT_T or rim_12 = '1' else '0';

    gore <= std_logic_vector'(d0(13) & d60(13) & d120(13));

    with gore select
        gore_color <= x"F00" when "011",
                      x"FF0" when "001",
                      x"0F0" when "000",
                      x"0FF" when "100",
                      x"00F" when "110",
                      x"F0F" when "111",
                      x"FFF" when others;

    stripe <= '1' when au_12 >= STRIPE_LO and au_12 < STRIPE_HI else '0';
    lace   <= '1' when uvw_12(1) > 0 and au_12 < LACE_U
                       and (abs(uvw_12(2)) < LACE_W
                            or (abs(uvw_12(2)) < STITCH_W and uvw_12(0)(6 downto 5) = "00")) else '0';

    base_reg: process(CLK, RST)
        begin
            if RST = '0' then
                base <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if solid = '0' then
                    if on_line = '1' then
                        base <= x"FFF";
                    else
                        base <= (others => '0');
                    end if;
                elsif kind = '1' then
                    if abs(ax_12) > CAP_V then
                        base <= x"FFF";
                    else
                        base <= gore_color;
                    end if;
                elsif stripe = '1' or lace = '1' then
                    base <= x"FFF";
                else
                    base <= x"A52";
                end if;
            end if;
        end process;

    -- shade = 4 + 11 * max(dot, 0), 4 是環境光
    shade_reg: process(CLK, RST)
        variable lit : unsigned (17 downto 0);
        begin
            if RST = '0' then
                shade <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if solid = '0' then
                    shade <= "1111";
                elsif dot <= 0 then
                    shade <= to_unsigned(4, 4);
                else
                    lit := resize(shift_right(resize(unsigned(dot), 18) * 11, 10), 18);
                    if lit >= 11 then
                        shade <= "1111";
                    else
                        shade <= resize(lit + 4, 4);
                    end if;
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
                if ins_13 = '0' then
                    rgb_r <= (others => '0');
                else
                    rgb_r(11 downto 8) <= std_logic_vector(resize(shift_right(unsigned(base(11 downto 8)) * k, 4), 4));
                    rgb_r(7 downto 4)  <= std_logic_vector(resize(shift_right(unsigned(base(7 downto 4)) * k, 4), 4));
                    rgb_r(3 downto 0)  <= std_logic_vector(resize(shift_right(unsigned(base(3 downto 0)) * k, 4), 4));
                end if;
            end if;
        end process;

    rgb <= rgb_r;
end Behavioral;
