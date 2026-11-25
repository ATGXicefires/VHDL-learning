----------------------------------------------------------------------------------
-- Module Name: pong_game_tb - Behavioral
-- Description: 遊戲規則的自我檢查 testbench: 不經過畫面, 直接用很快的 tick 驅動遊戲邏輯, 幾秒就能打完好幾局
--   同時跑 3 局, 玩家都由 testbench 裡的「機器人」按鍵:
--     g2: 2D 單人對電腦 (HARD2D), g2p: 2D 雙人 (兩邊都是機器人), g3: 3D 對電腦 (HARD3D)
--   機器人只看得到 REACT 步之前的球 (約 0.2 秒, 和真人的反應時間差不多), 球朝自己來才追, 有死區,
--     所以也會漏接; 用來確認電腦難度合理 (簡單模式人該贏, 困難模式要拚)
--   機器人會看弧線推算球到自己擊球面的位置, 並且每球挑拍子上偏一點的地方打, 回球才有變化
--   每局檢查: 比賽中球和球拍都在範圍內、球不可以穿進桌子、比分只會加 1、2D 由上一分的贏家發球、
--     有人到 7 分就進入結束階段,
--     結束後按 BTNC 比分歸 0 並回到發球; 3 局都通過才印 pong_game_tb PASS
--   pong2d_log.txt / pong3d_log.txt 記錄每一步的狀態, tools/sim.py 拿來畫 GIF
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;
use work.pong_pkg.all;

entity pong_game_tb is
    Generic ( HARD2D    : integer := 0;
              HARD3D    : integer := 0;
              REACT     : integer := 12;
              AIM2      : integer := 8;                            -- 2D 單人機器人瞄點的間距 (越大越常打到拍緣)
              MAX_STEPS : integer := 60000 );
end pong_game_tb;

architecture Behavioral of pong_game_tb is
    constant CLK_PERIOD : time := 10 ns;

    type hist_type is array (0 to 63) of integer;                  -- 環狀緩衝, 機器人看到的是延遲過的球

    signal CLK     : STD_LOGIC := '0';
    signal RST     : STD_LOGIC := '0';
    signal tick    : STD_LOGIC := '0';
    signal tcnt    : integer range 0 to STEP_CLKS - 1 := 0;
    signal hard2   : STD_LOGIC;
    signal hard3   : STD_LOGIC;
    signal done    : boolean := false;
    signal ok2, ok2p, ok3 : boolean := false;
    signal err2, err2p, err3 : integer := 0;                       -- 每個 process 各自計數 (signal 只能有一個 driver)

    -- 2D 單人
    signal c2      : ctrl_type := (others => '0');
    signal pl2, pr2, bx2, by2 : signed (11 downto 0);
    signal on2     : STD_LOGIC;
    signal sl2, sr2 : unsigned (2 downto 0);
    signal gp2     : gphase_type;
    signal pa2, bl2 : STD_LOGIC;

    -- 2D 雙人
    signal c2p     : ctrl_type := (others => '0');
    signal pl2p, pr2p, bx2p, by2p : signed (11 downto 0);
    signal on2p    : STD_LOGIC;
    signal sl2p, sr2p : unsigned (2 downto 0);
    signal gp2p    : gphase_type;
    signal pa2p, bl2p : STD_LOGIC;

    -- 3D
    signal c3      : ctrl_type := (others => '0');
    signal bx3, by3 : signed (11 downto 0);
    signal bz3     : unsigned (9 downto 0);
    signal px3, py3, cx3, cy3 : signed (11 downto 0);
    signal on3     : STD_LOGIC;
    signal sp3, sc3 : unsigned (2 downto 0);
    signal ps3     : STD_LOGIC;
    signal gp3     : gphase_type;
    signal pa3, bl3 : STD_LOGIC;

    function img(v : integer) return string is
    begin
        return integer'image(v);
    end function;

    function img(v : signed) return string is
    begin
        return ' ' & integer'image(to_integer(v));
    end function;

    -- 2D 機器人看到的弧線: 用 4 步前後的兩個位置估速度, 照 pong2d_ctrl 的物理 (重力、桌面反彈) 往前推,
    --   得到球到自己擊球面 (left = 左拍) 時的高度 gy; ev 是估計的 vx
    procedure predict2(x1, y1, ym, y3, x0, y0 : integer; left : boolean; gy, ev : out real) is
        constant g : real := real(GRAV) / 16.0;
        variable x, y, vx, vy : real;
    begin
        x  := real(x1);
        y  := real(y1);
        vx := real(x1 - x0) / 4.0;
        -- 估的是 2 步前的速度, 補 2 步的重力; 4 步裡夾著一次彈跳 (先往下後往上) 的話, 上下速度會互相抵消,
        --   改用最後一步 (ym = 1 步前, y3 = 3 步前)
        if y1 < ym and y3 > y0 then
            vy := real(y1 - ym) + g;
        else
            vy := real(y1 - y0) / 4.0 + 2.0 * g;
        end if;
        ev := vx;
        for i in 1 to 200 loop
            exit when (left and (x <= real(PL2_X) or vx >= 0.0)) or
                      (not left and (x >= real(PR2_X) or vx <= 0.0));
            x  := x + vx;
            y  := y + vy;
            vy := vy + g;
            if y >= real(TBL2_Y - RB2) and x >= real(TX0) and x <= real(TX1) then
                y  := 2.0 * real(TBL2_Y - RB2) - y;
                vy := -vy * 0.875;
            end if;
        end loop;
        gy := y;
    end procedure;

    -- 一支 2D 球拍的按鍵: 「上」就是發球鍵, 所以發球前只用「下」退回待命高度, 再輕按一下「上」發球
    --   (不是發球方的那一邊按了只會往上一點); 球朝自己來就追預測的高度 (死區 6),
    --   每顆來球挑拍子上偏一點的地方打 (偏 0 / spread / 2 spread), 回球才有長有短; 其餘時間回待命高度
    procedure keys2(gp : gphase_type; step : integer; incoming : boolean; gy : real; pad : signed; spread : real;
                    coming : inout boolean; aim : inout real; seed : inout integer;
                    up, dn : out STD_LOGIC) is
        variable tgt : real := real(P2_HOME);
    begin
        up := '0';
        dn := '0';
        if gp = GP_SERVE then
            if to_integer(pad) < P2_HOME - 6 then
                dn := '1';
            elsif step mod 8 = 0 then
                up := '1';
            end if;
            return;
        elsif gp = GP_PLAY and incoming then
            if not coming then
                seed   := (seed * 1103 + 12345) mod 65536;
                -- 瞄點 (決定回球長短) 加上看錯的量 (-24 .. 24): 真人不會每球都判斷得剛好
                aim    := real((seed / 256) mod 5 - 2) * spread + real((seed / 32) mod 7 - 3) * 8.0;
                coming := true;
            end if;
            tgt := gy - aim;
        else
            coming := false;
        end if;
        if tgt < real(to_integer(pad)) - 6.0 then
            up := '1';
        elsif tgt > real(to_integer(pad)) + 6.0 then
            dn := '1';
        end if;
    end procedure;

    -- 比賽中球在螢幕內、沒有陷進桌子; 球拍在可移動範圍內
    procedure check2(gp : gphase_type; bx, by, pl, pr : signed; name : string; signal err : inout integer) is
    begin
        if gp = GP_PLAY then
            if bx < 0 or bx >= SCR_W or by < 0 or by > FLOOR2_Y + 32 then
                report name & ": ball left the screen" severity error;
                err <= err + 1;
            end if;
            if bx >= TX0 and bx <= TX1 and by > TBL2_Y - RB2 then
                report name & ": ball inside the table" severity error;
                err <= err + 1;
            end if;
        end if;
        if pl < P2_YMIN or pl > P2_YMAX or pr < P2_YMIN or pr > P2_YMAX then
            report name & ": paddle out of range" severity error;
            err <= err + 1;
        end if;
    end procedure;
begin
    hard2 <= '1' when HARD2D = 1 else '0';
    hard3 <= '1' when HARD3D = 1 else '0';

    clk_process: process
        begin
            while not done loop
                CLK <= '0';
                wait for CLK_PERIOD / 2;
                CLK <= '1';
                wait for CLK_PERIOD / 2;
            end loop;
            wait;
        end process;

    rst_process: process
        begin
            wait for CLK_PERIOD * 5;
            RST <= '1';
            wait;
        end process;

    -- 每 STEP_CLKS 個 CLK 一次 tick, 剛好夠遊戲邏輯算完一步
    tick_process: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                if tcnt = STEP_CLKS - 1 then
                    tcnt <= 0;
                    tick <= RST;
                else
                    tcnt <= tcnt + 1;
                    tick <= '0';
                end if;
            end if;
        end process;

    g2: entity work.pong2d_ctrl
        port map ( CLK => CLK, RST => RST, tick => tick, enable => '1', two_p => '0', hard => hard2, ctrl => c2,
                   pl_y => pl2, pr_y => pr2, ball_x => bx2, ball_y => by2, ball_on => on2,
                   score_l => sl2, score_r => sr2, gphase => gp2, paused => pa2, blink => bl2 );

    g2p: entity work.pong2d_ctrl
        port map ( CLK => CLK, RST => RST, tick => tick, enable => '1', two_p => '1', hard => '0', ctrl => c2p,
                   pl_y => pl2p, pr_y => pr2p, ball_x => bx2p, ball_y => by2p, ball_on => on2p,
                   score_l => sl2p, score_r => sr2p, gphase => gp2p, paused => pa2p, blink => bl2p );

    g3: entity work.pong3d_ctrl
        port map ( CLK => CLK, RST => RST, tick => tick, enable => '1', hard => hard3, ctrl => c3,
                   ball_x => bx3, ball_y => by3, ball_z => bz3, pad_x => px3, pad_y => py3,
                   cpu_x => cx3, cpu_y => cy3, ball_on => on3, score_p => sp3, score_c => sc3,
                   p_scored => ps3, gphase => gp3, paused => pa3, blink => bl3 );

    ---------------------------------------------------------------- 2D 單人
    -- 和 bot3 一樣看弧線: 用 REACT 步前的兩個位置估速度, 照 pong2d_ctrl 的物理往前推到自己的擊球面
    bot2: process
        file f          : text;
        variable l      : line;
        variable hx, hy : hist_type := (others => 0);
        variable gy     : real;                                    -- 預測球到擊球面的高度
        variable ev     : real;                                    -- 估計的 vx
        variable coming : boolean := false;
        variable aim    : real := 0.0;
        variable seed   : integer := 11;
        variable ku, kd : STD_LOGIC;
        variable s_l    : integer := 0;
        variable s_r    : integer := 0;
        variable last_l : boolean := true;                         -- 上一分是左邊得的 (開局左邊先發)
        variable srv_n  : integer := 0;                            -- 在發球狀態幾步了
        variable over   : boolean := false;
        variable step   : integer := 0;
        begin
            file_open(f, "pong2d_log.txt", write_mode);
            write(l, string'("frame pl pr bx by on sl sr gph"));
            writeline(f, l);
            loop
                wait until CLK'event and CLK = '1' and tick = '1';
                step := step + 1;
                assert step < MAX_STEPS report "2D 1P: game did not end" severity failure;

                check2(gp2, bx2, by2, pl2, pr2, "2D 1P", err2);
                if not over and (to_integer(sl2) - s_l > 1 or to_integer(sl2) < s_l or
                                 to_integer(sr2) - s_r > 1 or to_integer(sr2) < s_r) then
                    report "2D 1P: score jumped" severity error;
                    err2 <= err2 + 1;
                end if;
                if to_integer(sl2) > s_l then
                    last_l := true;
                elsif to_integer(sr2) > s_r then
                    last_l := false;
                end if;
                s_l := to_integer(sl2);
                s_r := to_integer(sr2);
                -- 贏家發球: 發球前球停在發球方的拍子旁, 看球在網的哪一邊就知道是誰發
                --   (進入發球狀態的第一步, 球的位置還是上一步算的死球位置, 所以從第二步才看)
                if gp2 = GP_SERVE then
                    srv_n := srv_n + 1;
                else
                    srv_n := 0;
                end if;
                if srv_n >= 2 and (bx2 < NET2_X) /= last_l then
                    report "2D 1P: the server is not the last point winner" severity error;
                    err2 <= err2 + 1;
                end if;

                write(l, img(step) & img(pl2) & img(pr2) & img(bx2) & img(by2));
                write(l, ' ' & img(to_integer(unsigned'('0' & on2))) & ' ' & img(s_l) & ' ' & img(s_r));
                write(l, ' ' & img(to_integer(unsigned(gp2))));
                writeline(f, l);

                hx(step mod 64) := to_integer(bx2);
                hy(step mod 64) := to_integer(by2);
                predict2(hx((step - REACT) mod 64), hy((step - REACT) mod 64), hy((step - REACT - 1) mod 64),
                         hy((step - REACT - 3) mod 64), hx((step - REACT - 4) mod 64), hy((step - REACT - 4) mod 64),
                         true, gy, ev);

                if gp2 = GP_OVER then
                    if not over then
                        if s_l /= WIN and s_r /= WIN then
                            report "2D 1P: game over without a winner" severity error;
                            err2 <= err2 + 1;
                        end if;
                        report "2D 1P game over " & img(s_l) & " : " & img(s_r) & " after " & img(step) & " steps";
                        over := true;
                    end if;
                    c2 <= (K_C => not c2(K_C), others => '0');
                elsif over then
                    if s_l /= 0 or s_r /= 0 or gp2 /= GP_SERVE then
                        report "2D 1P: BTNC after game over did not start a new game" severity error;
                        err2 <= err2 + 1;
                    end if;
                    exit;
                else
                    keys2(gp2, step, ev < 0.0, gy, pl2, real(AIM2), coming, aim, seed, ku, kd);
                    c2 <= (K_UP => ku, K_DN => kd, others => '0');
                end if;
            end loop;
            file_close(f);
            ok2 <= true;
            wait;
        end process;

    ---------------------------------------------------------------- 2D 雙人 (兩邊都是機器人)
    bot2p: process
        variable hx, hy : hist_type := (others => 0);
        variable gyl, gyr : real;
        variable evl, evr : real;
        variable com_l, com_r : boolean := false;
        variable aim_l, aim_r : real := 0.0;
        variable seed   : integer := 23;
        variable ul, dl : STD_LOGIC;
        variable ur, dr : STD_LOGIC;
        variable over   : boolean := false;
        variable step   : integer := 0;
        begin
            loop
                wait until CLK'event and CLK = '1' and tick = '1';
                step := step + 1;
                assert step < MAX_STEPS report "2D 2P: game did not end" severity failure;
                check2(gp2p, bx2p, by2p, pl2p, pr2p, "2D 2P", err2p);

                hx(step mod 64) := to_integer(bx2p);
                hy(step mod 64) := to_integer(by2p);
                predict2(hx((step - REACT) mod 64), hy((step - REACT) mod 64), hy((step - REACT - 1) mod 64),
                         hy((step - REACT - 3) mod 64), hx((step - REACT - 4) mod 64), hy((step - REACT - 4) mod 64),
                         true, gyl, evl);
                predict2(hx((step - REACT) mod 64), hy((step - REACT) mod 64), hy((step - REACT - 1) mod 64),
                         hy((step - REACT - 3) mod 64), hx((step - REACT - 4) mod 64), hy((step - REACT - 4) mod 64),
                         false, gyr, evr);

                if gp2p = GP_OVER then
                    if not over then
                        report "2D 2P game over " & img(to_integer(sl2p)) & " : " & img(to_integer(sr2p))
                               & " after " & img(step) & " steps";
                        over := true;
                    end if;
                    c2p <= (K_C => not c2p(K_C), others => '0');
                elsif over then
                    if sl2p /= 0 or sr2p /= 0 or gp2p /= GP_SERVE then
                        report "2D 2P: BTNC after game over did not start a new game" severity error;
                        err2p <= err2p + 1;
                    end if;
                    exit;
                else
                    keys2(gp2p, step, evl < 0.0, gyl, pl2p, 20.0, com_l, aim_l, seed, ul, dl);
                    keys2(gp2p, step, evr > 0.0, gyr, pr2p, 20.0, com_r, aim_r, seed, ur, dr);
                    c2p <= (K_UP => ul, K_DN => dl, K_P2UP => ur, K_P2DN => dr, others => '0');
                end if;
            end loop;
            ok2p <= true;
            wait;
        end process;

    ---------------------------------------------------------------- 3D
    -- 機器人像真人一樣看弧線判斷落點: 用看得到的 (REACT 步前) 兩個位置估速度,
    --   照 pong3d_ctrl 的物理 (重力、桌面反彈) 往前推到 Z = 0, 得到球到玩家擊球面時的位置
    bot3: process
        procedure predict(x1, y1, z1, x0, y0, z0 : integer; gx, gy, ez : out real) is
            constant g : real := real(GRAV) / 16.0;
            variable x, y, z, vx, vy, vz : real;
        begin
            x  := real(x1);
            y  := real(y1);
            z  := real(z1);
            vx := real(x1 - x0) / 4.0;
            vy := real(y1 - y0) / 4.0 + 2.0 * g;                   -- 估的是 2 步前的速度, 補 2 步的重力
            vz := real(z1 - z0) / 4.0;
            ez := vz;
            for i in 1 to 200 loop
                exit when z <= 0.0 or vz >= 0.0;
                x := x + vx;
                y := y + vy;
                vy := vy + g;
                z := z + vz;
                if y >= real(TBL_Y - RB) and abs(x) <= real(TW) and z >= real(Z_T0) and z <= real(Z_T1) then
                    y  := 2.0 * real(TBL_Y - RB) - y;
                    vy := -vy * 0.875;
                end if;
            end loop;
            gx := x;
            gy := y;
        end procedure;

        file f          : text;
        variable l      : line;
        variable hx, hy : hist_type := (others => 0);
        variable hz     : hist_type := (others => 0);
        variable sx, sy : integer;
        variable sz     : integer;
        variable gx, gy : real;                                    -- 預測球到 Z = 0 時的位置
        variable ez     : real;                                    -- 估計的 vz (< 0 = 朝玩家來)
        variable coming : boolean := false;
        variable aim    : real := 0.0;                             -- 這一球想打在拍心偏多少
        variable seed   : integer := 7;
        variable s_p    : integer := 0;
        variable s_c    : integer := 0;
        variable over   : boolean := false;
        variable step   : integer := 0;
        begin
            file_open(f, "pong3d_log.txt", write_mode);
            write(l, string'("frame px py cx cy bx by bz on sp sc gph"));
            writeline(f, l);
            loop
                wait until CLK'event and CLK = '1' and tick = '1';
                step := step + 1;
                assert step < MAX_STEPS report "3D: game did not end" severity failure;

                if to_integer(by3) > FLOOR_Y or to_integer(by3) < 0 or bz3 > Z_FAR then
                    report "3D: ball outside the room" severity error;
                    err3 <= err3 + 1;
                end if;
                -- 比賽中球不可以在桌子裡面 (球心低於碰桌面的高度, 又在桌面範圍內)
                if gp3 = GP_PLAY and abs(to_integer(bx3)) <= TW and bz3 >= Z_T0 and bz3 <= Z_T1 and
                   to_integer(by3) > TBL_Y - RB then
                    report "3D: ball inside the table" severity error;
                    err3 <= err3 + 1;
                end if;
                if abs(to_integer(px3)) > PXMAX or to_integer(py3) < PYMIN or to_integer(py3) > PYMAX or
                   abs(to_integer(cx3)) > PXMAX or to_integer(cy3) < PYMIN or to_integer(cy3) > PYMAX then
                    report "3D: paddle out of range" severity error;
                    err3 <= err3 + 1;
                end if;
                if not over and (to_integer(sp3) - s_p > 1 or to_integer(sp3) < s_p or
                                 to_integer(sc3) - s_c > 1 or to_integer(sc3) < s_c) then
                    report "3D: score jumped" severity error;
                    err3 <= err3 + 1;
                end if;
                s_p := to_integer(sp3);
                s_c := to_integer(sc3);

                write(l, img(step) & img(px3) & img(py3) & img(cx3) & img(cy3) & img(bx3) & img(by3));
                write(l, ' ' & img(to_integer(bz3)) & ' ' & img(to_integer(unsigned'('0' & on3))));
                write(l, ' ' & img(s_p) & ' ' & img(s_c) & ' ' & img(to_integer(unsigned(gp3))));
                writeline(f, l);

                hx(step mod 64) := to_integer(bx3);
                hy(step mod 64) := to_integer(by3);
                hz(step mod 64) := to_integer(bz3);
                sx := hx((step - REACT) mod 64);
                sy := hy((step - REACT) mod 64);
                sz := hz((step - REACT) mod 64);
                predict(sx, sy, sz, hx((step - REACT - 4) mod 64), hy((step - REACT - 4) mod 64),
                        hz((step - REACT - 4) mod 64), gx, gy, ez);

                if gp3 = GP_OVER then
                    if not over then
                        if s_p /= WIN and s_c /= WIN then
                            report "3D: game over without a winner" severity error;
                            err3 <= err3 + 1;
                        end if;
                        report "3D game over " & img(s_p) & " : " & img(s_c) & " after " & img(step) & " steps";
                        over := true;
                    end if;
                    c3 <= (K_C => not c3(K_C), others => '0');
                elsif over then
                    if s_p /= 0 or s_c /= 0 or gp3 /= GP_SERVE then
                        report "3D: BTNC after game over did not start a new game" severity error;
                        err3 <= err3 + 1;
                    end if;
                    exit;
                else
                    -- 球朝自己飛來、進到 600 以內才追, 死區 40; 發球前先把球拍移回慣用的高度
                    c3 <= (others => '0');
                    if gp3 = GP_SERVE then
                        if to_integer(py3) < PY_HOME - 20 then
                            c3(K_DN) <= '1';
                        elsif to_integer(py3) > PY_HOME + 20 then
                            c3(K_UP) <= '1';
                        elsif step mod 4 = 0 then
                            c3(K_C) <= '1';
                        end if;
                    elsif ez < 0.0 and sz < 800 then
                        -- 每顆來球挑一個擊球點, 打在拍子偏一點的地方回出角度 (像真人會瞄邊線)
                        if not coming then
                            seed := (seed * 1103 + 12345) mod 65536;
                            aim  := real((seed / 256) mod 5 - 2) * 25.0;
                            coming := true;
                        end if;
                        gx := gx - aim;
                        if gx < real(to_integer(px3)) - 24.0 then
                            c3(K_LT) <= '1';
                        elsif gx > real(to_integer(px3)) + 24.0 then
                            c3(K_RT) <= '1';
                        end if;
                        if gy < real(to_integer(py3)) - 24.0 then
                            c3(K_UP) <= '1';
                        elsif gy > real(to_integer(py3)) + 24.0 then
                            c3(K_DN) <= '1';
                        end if;
                    elsif ez >= 0.0 then
                        coming := false;
                    end if;
                end if;
            end loop;
            file_close(f);
            ok3 <= true;
            wait;
        end process;

    finish: process
        begin
            wait until ok2 and ok2p and ok3;
            wait for CLK_PERIOD;
            if err2 + err2p + err3 = 0 then
                report "pong_game_tb PASS";
            else
                report "pong_game_tb FAIL: " & img(err2 + err2p + err3) & " errors" severity error;
            end if;
            done <= true;
            wait;
        end process;
end Behavioral;
