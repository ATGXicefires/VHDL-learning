----------------------------------------------------------------------------------
-- Module Name: puck_hit - Behavioral
-- Description: 空氣曲棍球: 一支球槌對球的碰撞 (hockey_ctrl 例化 2 次串接, 先玩家後電腦)
--   輸入在整個 frame 內都不變, 所以這裡只是一串逐級暫存的運算, 不用對齊延遲:
--   約 10 拍後輸出就穩定, hockey_ctrl 到下一個 frame_tick 才取用
--   球的位置、速度是 Q.8 (1/256 像素; 速度單位是 1/256 像素 / frame); 球槌位置是整數像素,
--   mvx / mvy 是球槌這個 frame 的位移 (Q.8)
--   中心距 d < 32 (= 球半徑 12 + 球槌半徑 20) 才算碰到:
--     n = (dx, dy) / d 查 NORM_X / NORM_Y: 碰到時 |dx|, |dy| 必 < 32, 32x32 的表就夠, 不用開根號和除法
--     v_rel = v - v_m, dot = v_rel . n; dot < 0 (正在靠近) 才反彈: v = v - 1.75 dot n
--       (恢復係數 0.75, 球槌當成無限重, 所以揮動的球槌能把球打得比自己快)
--     有重疊就把球放回球槌邊緣 (球槌 + 32 n), 不然球慢的時候會黏在球槌上
--   最後每軸限速 VMAX: 速度只有碰撞會變大, 限在這裡就夠, 也保證每 frame 移動量小於碰撞範圍, 不會穿過球槌
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;                                          -- 位置、速度都是有號數
use work.game_rom_pkg.all;

entity puck_hit is
    Generic ( PUSH_LEFT : boolean := false );                      -- 兩個圓心重合時沒有方向, 往對方球門推
    Port ( CLK  : in  STD_LOGIC;
           RST  : in  STD_LOGIC;
           px   : in  signed (19 downto 0);
           py   : in  signed (19 downto 0);
           vx   : in  signed (15 downto 0);
           vy   : in  signed (15 downto 0);
           mx   : in  signed (11 downto 0);
           my   : in  signed (11 downto 0);
           mvx  : in  signed (15 downto 0);
           mvy  : in  signed (15 downto 0);
           px_o : out signed (19 downto 0);
           py_o : out signed (19 downto 0);
           vx_o : out signed (15 downto 0);
           vy_o : out signed (15 downto 0);
           hit  : out STD_LOGIC);
end puck_hit;

architecture Behavioral of puck_hit is
    constant TOUCH2 : integer := 32 * 32;
    constant VMAX   : integer := 12 * 256;                         -- 12 像素 / frame

    signal dxi, dyi       : signed (11 downto 0);
    signal adx, ady       : unsigned (11 downto 0);
    signal dx2, dy2       : unsigned (23 downto 0);
    signal adr            : unsigned (9 downto 0);
    signal neg_x, neg_y   : STD_LOGIC;
    signal d2             : unsigned (24 downto 0);
    signal nxm, nym       : unsigned (7 downto 0);
    signal near           : STD_LOGIC;
    signal nx, ny         : signed (8 downto 0);                   -- Q1.7
    signal vrx, vry       : signed (16 downto 0);
    signal tx, ty         : signed (25 downto 0);
    signal cxp, cyp       : signed (19 downto 0);
    signal dot            : signed (19 downto 0);
    signal approach       : STD_LOGIC;
    signal kx, ky         : signed (28 downto 0);
    signal dvx, dvy       : signed (19 downto 0);
    signal vxn, vyn       : signed (19 downto 0);
    signal px_r, py_r     : signed (19 downto 0);
    signal vx_r, vy_r     : signed (15 downto 0);
    signal hit_r          : STD_LOGIC;
begin
    dxi_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dxi <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dxi <= px(19 downto 8) - mx;
            end if;
        end process;

    dyi_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dyi <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dyi <= py(19 downto 8) - my;
            end if;
        end process;

    adx <= unsigned(abs(dxi));
    ady <= unsigned(abs(dyi));

    dx2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dx2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dx2 <= unsigned(dxi * dxi);
            end if;
        end process;

    dy2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dy2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dy2 <= unsigned(dyi * dyi);
            end if;
        end process;

    -- 沒碰到時 |dx| 或 |dy| 可能 >= 32, 位址會繞回來, 但那時查到的值不會被用到
    adr_reg: process(CLK, RST)
        begin
            if RST = '0' then
                adr <= (others => '0');
            elsif CLK'event and CLK = '1' then
                adr <= adx(4 downto 0) & ady(4 downto 0);
            end if;
        end process;

    neg_x_reg: process(CLK, RST)
        begin
            if RST = '0' then
                neg_x <= '0';
            elsif CLK'event and CLK = '1' then
                if dxi < 0 or (dxi = 0 and PUSH_LEFT) then
                    neg_x <= '1';
                else
                    neg_x <= '0';
                end if;
            end if;
        end process;

    neg_y_reg: process(CLK, RST)
        begin
            if RST = '0' then
                neg_y <= '0';
            elsif CLK'event and CLK = '1' then
                neg_y <= dyi(11);
            end if;
        end process;

    d2_reg: process(CLK, RST)
        begin
            if RST = '0' then
                d2 <= (others => '0');
            elsif CLK'event and CLK = '1' then
                d2 <= resize(dx2, 25) + dy2;
            end if;
        end process;

    nxm_reg: process(CLK, RST)
        begin
            if RST = '0' then
                nxm <= (others => '0');
            elsif CLK'event and CLK = '1' then
                nxm <= to_unsigned(NORM_X(to_integer(adr)), 8);
            end if;
        end process;

    nym_reg: process(CLK, RST)
        begin
            if RST = '0' then
                nym <= (others => '0');
            elsif CLK'event and CLK = '1' then
                nym <= to_unsigned(NORM_Y(to_integer(adr)), 8);
            end if;
        end process;

    near_reg: process(CLK, RST)
        begin
            if RST = '0' then
                near <= '0';
            elsif CLK'event and CLK = '1' then
                if d2 < TOUCH2 then
                    near <= '1';
                else
                    near <= '0';
                end if;
            end if;
        end process;

    nx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                nx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if neg_x = '1' then
                    nx <= -signed('0' & nxm);
                else
                    nx <= signed('0' & nxm);
                end if;
            end if;
        end process;

    ny_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ny <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if neg_y = '1' then
                    ny <= -signed('0' & nym);
                else
                    ny <= signed('0' & nym);
                end if;
            end if;
        end process;

    vrx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vrx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                vrx <= resize(vx, 17) - mvx;
            end if;
        end process;

    vry_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vry <= (others => '0');
            elsif CLK'event and CLK = '1' then
                vry <= resize(vy, 17) - mvy;
            end if;
        end process;

    tx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                tx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                tx <= vrx * nx;
            end if;
        end process;

    ty_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ty <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ty <= vry * ny;
            end if;
        end process;

    -- 32 像素 * n (Q1.7) 換成 Q.8 剛好是 64 * n
    cxp_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cxp <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cxp <= shift_left(resize(mx, 20), 8) + shift_left(resize(nx, 20), 6);
            end if;
        end process;

    cyp_reg: process(CLK, RST)
        begin
            if RST = '0' then
                cyp <= (others => '0');
            elsif CLK'event and CLK = '1' then
                cyp <= shift_left(resize(my, 20), 8) + shift_left(resize(ny, 20), 6);
            end if;
        end process;

    dot_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dot <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dot <= resize(shift_right(resize(tx, 27) + ty, 7), 20);
            end if;
        end process;

    approach <= dot(19);

    kx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                kx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                kx <= dot * nx;
            end if;
        end process;

    ky_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ky <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ky <= dot * ny;
            end if;
        end process;

    -- 1.75 dot n = 7 (dot n) / 4, n 再去掉 Q1.7 的 7 個小數位元: 合起來 7 k >> 9
    dvx_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dvx <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dvx <= resize(shift_right(shift_left(resize(kx, 32), 3) - kx, 9), 20);
            end if;
        end process;

    dvy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                dvy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                dvy <= resize(shift_right(shift_left(resize(ky, 32), 3) - ky, 9), 20);
            end if;
        end process;

    vxn_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vxn <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if near = '1' and approach = '1' then
                    vxn <= resize(vx, 20) - dvx;
                else
                    vxn <= resize(vx, 20);
                end if;
            end if;
        end process;

    vyn_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vyn <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if near = '1' and approach = '1' then
                    vyn <= resize(vy, 20) - dvy;
                else
                    vyn <= resize(vy, 20);
                end if;
            end if;
        end process;

    px_o_reg: process(CLK, RST)
        begin
            if RST = '0' then
                px_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if near = '1' then
                    px_r <= cxp;
                else
                    px_r <= px;
                end if;
            end if;
        end process;

    py_o_reg: process(CLK, RST)
        begin
            if RST = '0' then
                py_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if near = '1' then
                    py_r <= cyp;
                else
                    py_r <= py;
                end if;
            end if;
        end process;

    vx_o_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vx_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if vxn > VMAX then
                    vx_r <= to_signed(VMAX, 16);
                elsif vxn < -VMAX then
                    vx_r <= to_signed(-VMAX, 16);
                else
                    vx_r <= resize(vxn, 16);
                end if;
            end if;
        end process;

    vy_o_reg: process(CLK, RST)
        begin
            if RST = '0' then
                vy_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if vyn > VMAX then
                    vy_r <= to_signed(VMAX, 16);
                elsif vyn < -VMAX then
                    vy_r <= to_signed(-VMAX, 16);
                else
                    vy_r <= resize(vyn, 16);
                end if;
            end if;
        end process;

    hit_reg: process(CLK, RST)
        begin
            if RST = '0' then
                hit_r <= '0';
            elsif CLK'event and CLK = '1' then
                hit_r <= near and approach;
            end if;
        end process;

    px_o <= px_r;
    py_o <= py_r;
    vx_o <= vx_r;
    vy_o <= vy_r;
    hit  <= hit_r;
end Behavioral;
