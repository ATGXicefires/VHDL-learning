----------------------------------------------------------------------------------
-- Module Name: led_pingpong_tb - Behavioral
-- Description: led_pingpong 的自我檢查 testbench
--   CLK_FREQ 設 2400 讓模擬加速: 取樣 24 CLK, 初速一格 600 CLK, 最快 200 CLK,
--   比分顯示 2400 CLK
--   只看 led 輸出判斷遊戲狀態, 和玩家在板子上看到的一樣
--   打一整局: 擊中加速 -> 漏接 -> 得分方 (上方) 發球被打回後太早按 -> 下方連發連得 -> 4 分結束 -> 開新局
--   發球和開新局都用發球方 (贏家) 自己的擊球鍵, 另一方按了不能有反應
--   有錯以 severity error 報出, 全部通過最後印出 "led_pingpong_tb PASS"
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

entity led_pingpong_tb is
end led_pingpong_tb;

architecture Behavioral of led_pingpong_tb is
    component led_pingpong
        Generic ( CLK_FREQ : integer := 100_000_000 );
        Port ( CLK   : in  STD_LOGIC;
               RST   : in  STD_LOGIC;
               btn_u : in  STD_LOGIC;
               btn_d : in  STD_LOGIC;
               led   : out STD_LOGIC_VECTOR (7 downto 0));
    end component;

    constant FREQ       : integer := 2400;
    constant CLK_PERIOD : time := 10 ns;
    constant SAMP       : time := CLK_PERIOD * (FREQ / 100);
    constant STEP0      : time := CLK_PERIOD * (FREQ / 4);
    constant SHOW       : time := CLK_PERIOD * FREQ;

    signal CLK   : STD_LOGIC := '0';
    signal RST   : STD_LOGIC := '0';
    signal btn_u : STD_LOGIC := '0';
    signal btn_d : STD_LOGIC := '0';
    signal led   : STD_LOGIC_VECTOR (7 downto 0);
    signal done  : boolean := false;
begin
    uut: led_pingpong
        generic map ( CLK_FREQ => FREQ )
        port map ( CLK => CLK, RST => RST, btn_u => btn_u, btn_d => btn_d, led => led );

    -- done 後停掉時脈, 事件佇列清空模擬才會自己結束
    clk_process: process
        begin
            if done then
                wait;
            end if;
            CLK <= '0';
            wait for CLK_PERIOD / 2;
            CLK <= '1';
            wait for CLK_PERIOD / 2;
        end process;

    stim_process: process
        variable errors : integer := 0;
        variable t0, t1 : time;
        variable up_gap, down_gap : time;

        -- 放開也要撐過 2 次取樣, 不然下一次按下會被當成沒放開
        procedure press(signal b : out STD_LOGIC) is
        begin
            b <= '1';
            wait for SAMP * 3;
            b <= '0';
            wait for SAMP * 3;
        end procedure;

        procedure expect(v : STD_LOGIC_VECTOR (7 downto 0); timeout : time; msg : string) is
        begin
            if led /= v then
                wait until led = v for timeout;
            end if;
            if led /= v then
                report msg severity error;
                errors := errors + 1;
            end if;
        end procedure;

        procedure check(ok : boolean; msg : string) is
        begin
            if not ok then
                report msg severity error;
                errors := errors + 1;
            end if;
        end procedure;
    begin
        RST <= '0';
        wait for CLK_PERIOD * 5;
        RST <= '1';

        -- 開機: 下方發球, 球在 LD0 閃
        expect("00000001", SHOW, "reset: ball not at LD0");

        -- 第 1 球: 下方按 BTND 發球, 上方在 LD7 擊中, 回程應比去程快; 下方漏接 -> 上方 1 分
        press(btn_d);
        expect("00000100", STEP0 * 3, "rally 1: ball did not move up");
        expect("00001000", STEP0 * 2, "rally 1: ball did not reach LD3");
        t0 := now;
        expect("00010000", STEP0 * 2, "rally 1: ball did not reach LD4");
        up_gap := now - t0;
        expect("10000000", STEP0 * 5, "rally 1: ball did not reach LD7");
        wait for STEP0 / 4;
        press(btn_u);
        expect("01000000", STEP0 * 2, "rally 1: hit at LD7 did not send the ball back");
        expect("00010000", STEP0 * 3, "rally 1: ball did not come down to LD4");
        t0 := now;
        expect("00001000", STEP0 * 2, "rally 1: ball did not come down to LD3");
        down_gap := now - t0;
        check(down_gap < up_gap, "rally 1: ball did not speed up after the hit");
        report "step up = " & time'image(up_gap) & ", down = " & time'image(down_gap) severity note;
        expect("00000001", STEP0 * 4, "rally 1: ball did not reach LD0");
        expect("10000000", STEP0 * 2, "rally 1: miss at LD0 did not show score 1:0");
        t0 := now;
        wait until led /= "10000000" for SHOW * 2;
        t1 := now - t0;
        check(t1 > SHOW * 9 / 10 and t1 < SHOW * 11 / 10, "rally 1: score shown for " & time'image(t1));

        -- 第 2 球: 得分的上方發球, 下方在 LD0 打回, 上方太早按 -> 1:1, 改下方發球
        expect("10000000", SHOW, "rally 2: top player (scorer) is not serving");
        press(btn_d);
        wait for STEP0 * 2;
        check(led = "10000000" or led = "00000000", "rally 2: BTND served for the top player");
        press(btn_u);
        expect("00000001", STEP0 * 9, "rally 2: ball from top did not reach LD0");
        press(btn_d);
        expect("00000100", STEP0 * 3, "rally 2: hit at LD0 did not send the ball back");
        press(btn_u);
        expect("10000001", STEP0, "rally 2: early press did not give the bottom player a point");

        -- 第 3 ~ 5 球: 得分的下方連續發球, 上方太早按 -> 下方得分, 到 4 分結束
        for i in 2 to 4 loop
            expect("00000001", SHOW * 2, "bottom player (scorer) is not serving");
            press(btn_d);
            expect("00001000", STEP0 * 5, "ball did not reach LD3");
            if i = 2 then
                -- 球飛向上方時下方亂按不算犯規
                press(btn_d);
                check(led /= "10000011", "pressing BTND while the ball moves away scored a point");
            end if;
            press(btn_u);
            case i is
                when 2 => expect("10000011", STEP0, "score is not 1:2");
                when 3 => expect("10000111", STEP0, "score is not 1:3");
                when others => expect("10001111", STEP0, "score is not 1:4");
            end case;
        end loop;

        -- 結束: 贏家 (下方) 的 4 顆在閃, 上方的 1 分常亮
        wait for SHOW + STEP0;
        expect("10000000", SHOW, "game over: bottom half (winner) never blinks off");
        expect("10001111", SHOW, "game over: bottom half (winner) never blinks on");

        -- 輸家 (上方) 按不能開新局
        press(btn_u);
        check(led = "10000000" or led = "10001111", "game over: loser's BTNU left the game-over state");

        -- 贏家 (下方) 按 BTND 開新局: 清分, 贏家先發
        press(btn_d);
        wait for SAMP;
        check(led = "00000001" or led = "00000000", "new game: scores were not cleared");
        expect("00000001", SHOW, "new game: winner (bottom) is not serving");
        wait for SHOW;
        check(led = "00000001" or led = "00000000", "new game: serve state left without a press");

        if errors = 0 then
            report "led_pingpong_tb PASS" severity note;
        else
            report "led_pingpong_tb FAIL: " & integer'image(errors) & " error(s)" severity error;
        end if;
        done <= true;
        wait;
    end process;
end Behavioral;
