----------------------------------------------------------------------------------
-- Module Name: game_tb - Behavioral
-- Description: CD 彈跳與空氣曲棍球的狀態 testbench: 直接例化 cd_ctrl 和 hockey_ctrl,
--   每 TICK 個 CLK 給一次假的 frame_tick, 不用掃完整張畫面, 幾千個 frame 幾秒就跑完
--   TICK 要大於 hockey_ctrl 的管線深度 (約 30 拍), frame_tick 寫回時下一個 frame 才已經算好
--   玩家球槌由這裡的簡單機器人操作: 球在左半場就從球的左邊撞過去 (球在球槌左邊時先繞), 否則回球門前守
--   每個 frame 把狀態寫進 game_log.txt (tools/sim.py game 會畫成 GIF), 並檢查:
--     CD 永遠在畫面內; 球除了從球門開口出去以外不會離開場地; 兩支球槌不越過自己的半場;
--     暫停時什麼都不動; 有反彈、有擊球、有進球; OVER 之後按 BTNC 比分歸零
--   第 SWITCH_AT 個 frame 起改成 1024x768 (邏輯畫面 512x384), 檢查換解析度後的邊界
--   預設 HARD = 0: 機器人約 7000 frame 就能贏一局, 才測得到 OVER -> BTNC 重開;
--   HARD = 1 時一局要 2 萬個 frame 左右 (python tools/sim.py game HARD=1 FRAMES=30000 SWITCH_AT=25000)
--   有錯會以 severity error 報出, 全部通過最後印出 "game_tb PASS"
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;
use work.vga_pkg.all;

entity game_tb is
    Generic ( FRAMES    : integer := 9000;
              SWITCH_AT : integer := 8000;
              HARD      : integer := 0 );
end game_tb;

architecture Behavioral of game_tb is
    constant CLK_PERIOD : time := 10 ns;
    constant TICK       : integer := 64;

    signal CLK        : STD_LOGIC := '0';
    signal RST        : STD_LOGIC := '0';
    signal frame_tick : STD_LOGIC := '0';
    signal done       : boolean := false;
    signal h_size     : coord_type := std_logic_vector(to_unsigned(640, 11));
    signal v_size     : coord_type := std_logic_vector(to_unsigned(480, 11));
    signal big        : STD_LOGIC := '0';
    signal hard_in    : STD_LOGIC;
    signal btn_cd     : STD_LOGIC_VECTOR (4 downto 0) := (others => '0');
    signal btn_hk     : STD_LOGIC_VECTOR (4 downto 0) := (others => '0');

    signal cd_x, cd_y         : coord_type;
    signal cd_spin            : STD_LOGIC_VECTOR (7 downto 0);
    signal cd_tint            : STD_LOGIC_VECTOR (2 downto 0);
    signal cd_flash           : STD_LOGIC;
    signal cd_paused          : STD_LOGIC;

    signal hk_x, hk_y         : coord3_type;
    signal score_p, score_c   : STD_LOGIC_VECTOR (2 downto 0);
    signal puck_show          : STD_LOGIC;
    signal goal_l, goal_r     : STD_LOGIC;
    signal win_p, win_c       : STD_LOGIC;
    signal blink, hit         : STD_LOGIC;
    signal hk_paused          : STD_LOGIC;
begin
    hard_in <= '1' when HARD = 1 else '0';

    cd_uut: entity work.cd_ctrl
        port map ( CLK        => CLK,
                   RST        => RST,
                   frame_tick => frame_tick,
                   enable     => '1',
                   btn        => btn_cd,
                   h_size     => h_size,
                   v_size     => v_size,
                   big        => big,
                   cd_x       => cd_x,
                   cd_y       => cd_y,
                   spin       => cd_spin,
                   tint       => cd_tint,
                   flash      => cd_flash,
                   paused     => cd_paused );

    hk_uut: entity work.hockey_ctrl
        port map ( CLK        => CLK,
                   RST        => RST,
                   frame_tick => frame_tick,
                   enable     => '1',
                   btn        => btn_hk,
                   h_size     => h_size,
                   v_size     => v_size,
                   big        => big,
                   hard       => hard_in,
                   obj_x      => hk_x,
                   obj_y      => hk_y,
                   score_p    => score_p,
                   score_c    => score_c,
                   puck_show  => puck_show,
                   goal_l     => goal_l,
                   goal_r     => goal_r,
                   win_p      => win_p,
                   win_c      => win_c,
                   blink      => blink,
                   hit        => hit,
                   paused     => hk_paused );

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

    tick_process: process
        begin
            wait until RST = '1';
            while not done loop
                for i in 1 to TICK - 1 loop
                    wait until CLK'event and CLK = '1';
                end loop;
                frame_tick <= '1';
                wait until CLK'event and CLK = '1';
                frame_tick <= '0';
            end loop;
            wait;
        end process;

    stim_process: process
        file f          : text;
        variable l      : line;
        variable errors : integer := 0;
        variable w, h   : integer := 0;
        variable cx, cy, tint : integer;
        variable px, py, pmx, pmy, cmx, cmy : integer;
        variable sp, sc : integer;
        variable prev_cx, prev_cy, prev_tint : integer := 0;
        variable prev_px, prev_py, prev_pmx, prev_pmy, prev_cmx, prev_cmy : integer := 0;
        variable prev_sp, prev_sc : integer := 0;
        variable cd_was_paused, hk_was_paused : boolean := false;
        variable hit_now : STD_LOGIC;
        variable skip    : integer := 2;
        variable over_at : integer := -1;
        variable pause_at : integer := -1;
        variable pauses  : integer := 0;
        variable bounces, hits, goals, overs, restarts : integer := 0;
        variable aim, tx, ty : integer;
        variable b       : STD_LOGIC_VECTOR (4 downto 0);

        procedure check(ok : boolean; frame : integer; msg : string) is
            begin
                if not ok then
                    errors := errors + 1;
                    report "frame " & integer'image(frame) & ": " & msg severity error;
                end if;
            end procedure;

        procedure put(v : integer) is
            begin
                write(l, v);
                write(l, ' ');
            end procedure;

        procedure put(v : STD_LOGIC) is
            begin
                if v = '1' then
                    put(1);
                else
                    put(0);
                end if;
            end procedure;
        begin
            wait for CLK_PERIOD * 3;
            RST <= '1';
            file_open(f, "game_log.txt", write_mode);
            write(l, string'("# frame w h cd_x cd_y cd_tint cd_flash cd_paused puck_x puck_y pm_x pm_y cm_x cm_y "
                           & "score_p score_c puck_show goal_l goal_r win_p win_c hit hk_paused"));
            writeline(f, l);

            for fr in 0 to FRAMES - 1 loop
                -- 這個邊緣 DUT 寫回; 此刻讀到的 hit 還是寫回前那一步算出來的
                wait until CLK'event and CLK = '1' and frame_tick = '1';
                hit_now := hit;
                wait until CLK'event and CLK = '1';

                w := to_integer(unsigned(h_size));
                h := to_integer(unsigned(v_size));
                if big = '1' then
                    w := w / 2;
                    h := h / 2;
                end if;
                cx   := to_integer(unsigned(cd_x));
                cy   := to_integer(unsigned(cd_y));
                tint := to_integer(unsigned(cd_tint));
                px   := to_integer(unsigned(hk_x(0)));
                py   := to_integer(unsigned(hk_y(0)));
                pmx  := to_integer(unsigned(hk_x(1)));
                pmy  := to_integer(unsigned(hk_y(1)));
                cmx  := to_integer(unsigned(hk_x(2)));
                cmy  := to_integer(unsigned(hk_y(2)));
                sp   := to_integer(unsigned(score_p));
                sc   := to_integer(unsigned(score_c));

                put(fr); put(w); put(h);
                put(cx); put(cy); put(tint); put(cd_flash); put(cd_paused);
                put(px); put(py); put(pmx); put(pmy); put(cmx); put(cmy);
                put(sp); put(sc); put(puck_show); put(goal_l); put(goal_r); put(win_p); put(win_c);
                put(hit_now); put(hk_paused);
                writeline(f, l);

                -- 剛開機和剛換解析度的那一步, 物件才正要被拉回新畫面內
                if skip > 0 then
                    skip := skip - 1;
                else
                    check(cx >= 64 and cx <= w - 64 and cy >= 64 and cy <= h - 64, fr, "CD out of screen");
                    if puck_show = '1' then
                        check(py >= 20 and py <= h - 20, fr, "puck y out of table");
                        if abs(py - h / 2) > 68 then
                            check(px >= 20 and px <= w - 20, fr, "puck x out of table");
                        else
                            check(px < w, fr, "puck x out of screen");
                        end if;
                    end if;
                    check(pmx >= 28 and pmx <= w / 2 - 20 and pmy >= 28 and pmy <= h - 28, fr,
                          "player mallet left its half");
                    check(cmx >= w / 2 + 20 and cmx <= w - 28 and cmy >= 28 and cmy <= h - 28, fr,
                          "cpu mallet left its half");
                    check(sp <= 7 and sc <= 7, fr, "score above 7");
                    if cd_was_paused and cd_paused = '1' then
                        check(cx = prev_cx and cy = prev_cy, fr, "CD moved while paused");
                    end if;
                    if hk_was_paused and hk_paused = '1' then
                        check(px = prev_px and py = prev_py and pmx = prev_pmx and pmy = prev_pmy
                              and cmx = prev_cmx and cmy = prev_cmy, fr, "hockey moved while paused");
                    end if;

                    if tint /= prev_tint then
                        bounces := bounces + 1;
                    end if;
                    if hit_now = '1' and (px /= prev_px or py /= prev_py) then
                        hits := hits + 1;
                    end if;
                    if sp > prev_sp or sc > prev_sc then
                        goals := goals + 1;
                    end if;
                end if;

                if (win_p = '1' or win_c = '1') and over_at < 0 then
                    over_at := fr;
                    overs := overs + 1;
                    report "game over at frame " & integer'image(fr) & ", " & integer'image(sp)
                           & " : " & integer'image(sc) severity note;
                end if;
                if over_at >= 0 and fr = over_at + 122 then
                    check(sp = 0 and sc = 0 and win_p = '0' and win_c = '0', fr, "BTNC did not start a new game");
                    restarts := restarts + 1;
                    over_at := -1;
                end if;

                prev_cx := cx;  prev_cy := cy;  prev_tint := tint;
                prev_px := px;  prev_py := py;
                prev_pmx := pmx;  prev_pmy := pmy;  prev_cmx := cmx;  prev_cmy := cmy;
                prev_sp := sp;  prev_sc := sc;
                cd_was_paused := cd_paused = '1';
                hk_was_paused := hk_paused = '1';

                -- 下面設的按鈕會在下一個 frame_tick 被取樣
                if fr = 300 or fr = 310 then
                    btn_cd <= "00010";                             -- BTNU 加速兩級
                elsif fr = 1500 or fr = 1600 then
                    btn_cd <= "00001";                             -- BTNC 暫停, 100 frame 後繼續
                else
                    btn_cd <= "00000";
                end if;

                -- 機器人: 球在球槌右邊才撞得出去, 否則先從上或下繞到球的左邊; y 加一點偏移讓擊球角度有變化
                aim := ((fr / 40) mod 5 - 2) * 10;
                if px < w / 2 and puck_show = '1' then
                    if pmx < px - 8 then
                        tx := px;
                        ty := py + aim;
                    else
                        tx := px - 44;
                        if pmy < py then
                            ty := py - 44;
                        else
                            ty := py + 44;
                        end if;
                    end if;
                else
                    tx := 48;
                    ty := py;
                    if ty < h / 2 - 64 then
                        ty := h / 2 - 64;
                    elsif ty > h / 2 + 64 then
                        ty := h / 2 + 64;
                    end if;
                end if;
                b := "00000";
                if tx > pmx + 3 then
                    b(BTN_R) := '1';
                elsif tx < pmx - 3 then
                    b(BTN_L) := '1';
                end if;
                if ty > pmy + 3 then
                    b(BTN_D) := '1';
                elsif ty < pmy - 3 then
                    b(BTN_U) := '1';
                end if;
                -- 暫停只在比賽中有效: 第 600 frame 之後第一個 PLAY 的 frame 按 BTNC, 60 frame 後再按一次繼續
                if pause_at < 0 and fr >= 600 and hk_paused = '0' and puck_show = '1'
                   and win_p = '0' and win_c = '0' then
                    b(BTN_C) := '1';
                    pause_at := fr;
                elsif pause_at >= 0 and fr = pause_at + 60 then
                    if hk_paused = '1' then
                        b(BTN_C) := '1';
                        pauses := pauses + 1;
                    end if;
                elsif over_at >= 0 and fr = over_at + 120 then
                    b(BTN_C) := '1';
                end if;
                btn_hk <= b;

                if fr = SWITCH_AT then
                    h_size <= std_logic_vector(to_unsigned(1024, 11));
                    v_size <= std_logic_vector(to_unsigned(768, 11));
                    big    <= '1';
                    skip   := 2;
                end if;
            end loop;
            file_close(f);

            report "cd bounces = " & integer'image(bounces) & ", hockey hits = " & integer'image(hits)
                   & ", goals = " & integer'image(goals) & ", games over = " & integer'image(overs)
                   & ", restarts = " & integer'image(restarts) & ", pauses = " & integer'image(pauses)
                   severity note;
            check(bounces >= 4, FRAMES, "CD bounced fewer than 4 times");
            check(pauses = 1, FRAMES, "hockey pause / resume not exercised");
            check(hits >= 10, FRAMES, "fewer than 10 hits");
            check(goals >= 1, FRAMES, "no goal scored");
            if errors = 0 then
                report "game_tb PASS" severity note;
            else
                report "game_tb FAIL: " & integer'image(errors) & " error(s)" severity error;
            end if;
            done <= true;
            wait;
        end process;
end Behavioral;
