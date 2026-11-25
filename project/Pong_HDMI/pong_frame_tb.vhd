----------------------------------------------------------------------------------
-- Module Name: pong_frame_tb - Behavioral
-- Description: 畫面擷取 testbench, 把 pong_core 輸出的一整張 1024x768 畫面寫成 frame.ppm (P3, 每色 0..15)
--   tools/sim.py 用 xelab -generic_top 改 generic, 再把 ppm 轉成 png 檢查
--   SW = 開關 (1 = 3D, 2 = 雙人, 4 = 困難); 按鍵流程: 先按 C_PRESSES 次 BTNC,
--   再按住 BTN (控制向量遮罩, 位元見 pong_pkg) HOLD 個 frame 後放開, 再等 SKIP 個 frame 才擷取
--   TICKS = pong_core 的 GAME_TICKS: 每個 frame 遊戲走幾步, 少跑幾個 frame 就能看到球飛到半路
--   直接驅動像素時脈, 跳過 MMCM, CLK 週期不影響畫面內容
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;
use work.vga_pkg.all;
use work.pong_pkg.all;

entity pong_frame_tb is
    Generic ( SW        : integer := 0;
              C_PRESSES : integer := 0;
              BTN       : integer := 0;
              HOLD      : integer := 0;
              TICKS     : integer := 1;
              SKIP      : integer := 1 );
end pong_frame_tb;

architecture Behavioral of pong_frame_tb is
    signal CLK    : STD_LOGIC := '0';
    signal RST    : STD_LOGIC := '0';
    signal sw_v   : STD_LOGIC_VECTOR (2 downto 0);
    signal ctrl   : ctrl_type := (others => '0');
    signal vga_r, vga_g, vga_b : STD_LOGIC_VECTOR (3 downto 0);
    signal vga_hs, vga_vs      : STD_LOGIC;
    signal de     : STD_LOGIC;
    signal status : STD_LOGIC_VECTOR (4 downto 0);
    signal done   : boolean := false;

    constant CLK_PERIOD : time := 10 ns;
    constant T          : timing_type := TIMINGS(2);
begin
    sw_v <= STD_LOGIC_VECTOR(to_unsigned(SW, 3));

    uut: entity work.pong_core
        generic map ( GAME_TICKS => TICKS )
        port map ( CLK    => CLK,
                   RST    => RST,
                   sw     => sw_v,
                   ctrl   => ctrl,
                   vga_r  => vga_r,
                   vga_g  => vga_g,
                   vga_b  => vga_b,
                   vga_hs => vga_hs,
                   vga_vs => vga_vs,
                   de     => de,
                   status => status );

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

    stim_process: process
        file f    : text;
        variable l : line;

        -- 只認 非作用 -> 作用 的跳變: delay_line 沒有重置, 剛開始 vga_vs 會從 'U' 跳到別的值
        procedure wait_frames(n : integer) is
            begin
                for i in 1 to n loop
                    wait until vga_vs'event and vga_vs = T.sync_pol and vga_vs'last_value = not T.sync_pol;
                end loop;
            end procedure;
        begin
            wait for CLK_PERIOD * 3;
            RST <= '1';

            -- 按鍵每個 tick 才取樣一次, 按下/放開都要撐過至少一個 frame_tick
            for i in 1 to C_PRESSES loop
                ctrl(K_C) <= '1';
                wait_frames(2);
                ctrl(K_C) <= '0';
                wait_frames(1);
            end loop;

            ctrl <= STD_LOGIC_VECTOR(to_unsigned(BTN, 7));
            wait_frames(HOLD);
            ctrl <= (others => '0');
            wait_frames(SKIP);

            file_open(f, "frame.ppm", write_mode);
            write(l, string'("P3"));
            writeline(f, l);
            write(l, T.h_active);
            write(l, ' ');
            write(l, T.v_active);
            writeline(f, l);
            write(l, 15);
            writeline(f, l);

            for row in 0 to T.v_active - 1 loop
                for col in 0 to T.h_active - 1 loop
                    wait until CLK'event and CLK = '1' and de = '1';
                    write(l, to_integer(unsigned(vga_r)));
                    write(l, ' ');
                    write(l, to_integer(unsigned(vga_g)));
                    write(l, ' ');
                    write(l, to_integer(unsigned(vga_b)));
                    write(l, ' ');
                end loop;
                writeline(f, l);
            end loop;
            file_close(f);

            report "frame captured, status = " & integer'image(to_integer(unsigned(status)))
                severity note;
            done <= true;
            wait;
        end process;
end Behavioral;
