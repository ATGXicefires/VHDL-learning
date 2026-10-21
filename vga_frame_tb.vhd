----------------------------------------------------------------------------------
-- Module Name: vga_frame_tb - Behavioral
-- Description: HW3 畫面擷取 testbench, 把 vga_core 輸出的一整張畫面寫成 frame.ppm (P3, 每色 0..15)
--   tools/sim.py 會用 xelab -generic_top 改 generic, 再把 ppm 轉成 png 檢查
--   開關由 generic 決定; 按鈕流程: 先按 C_PRESSES 次 BTNC, 再按住 BTN 遮罩 (bit 編號見 vga_pkg)
--   HOLD 個 frame 後放開, 再等 SKIP 個 frame 才擷取
--   直接驅動 vga_core 的像素時脈, 跳過 MMCM, CLK 週期不影響畫面內容
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use std.textio.all;
use work.vga_pkg.all;

entity vga_frame_tb is
    Generic ( RES       : integer := 0;
              MODE      : integer := 0;
              VARIANT   : integer := 1;
              DEPTH     : integer := 1;
              C_PRESSES : integer := 0;
              BTN       : integer := 0;
              HOLD      : integer := 0;
              SKIP      : integer := 1 );
end vga_frame_tb;

architecture Behavioral of vga_frame_tb is
    signal CLK    : STD_LOGIC := '0';
    signal RST    : STD_LOGIC := '0';
    signal sw     : STD_LOGIC_VECTOR (6 downto 0);
    signal btn_in : STD_LOGIC_VECTOR (4 downto 0) := (others => '0');
    signal vga_r, vga_g, vga_b : STD_LOGIC_VECTOR (3 downto 0);
    signal vga_hs, vga_vs      : STD_LOGIC;
    signal de     : STD_LOGIC;
    signal status : STD_LOGIC_VECTOR (6 downto 0);
    signal done   : boolean := false;

    constant CLK_PERIOD : time := 10 ns;
    constant T          : timing_type := TIMINGS(RES);
begin
    sw <= conv_std_logic_vector(DEPTH, 1) & conv_std_logic_vector(VARIANT, 1)
          & conv_std_logic_vector(MODE, 3) & conv_std_logic_vector(RES, 2);

    uut: entity work.vga_core
        port map ( CLK    => CLK,
                   RST    => RST,
                   sw     => sw,
                   btn    => btn_in,
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

        procedure wait_frames(n : integer) is
            begin
                for i in 1 to n loop
                    wait until vga_vs'event and vga_vs = T.sync_pol;
                end loop;
            end procedure;
        begin
            wait for CLK_PERIOD * 3;
            RST <= '1';

            -- 按鈕每個 frame 才取樣一次, 按下/放開都要撐過至少一個 frame_tick
            for i in 1 to C_PRESSES loop
                btn_in(BTN_C) <= '1';
                wait_frames(2);
                btn_in(BTN_C) <= '0';
                wait_frames(2);
            end loop;

            btn_in <= conv_std_logic_vector(BTN, 5);
            wait_frames(HOLD);
            btn_in <= (others => '0');
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
                    write(l, conv_integer(unsigned(vga_r)));
                    write(l, ' ');
                    write(l, conv_integer(unsigned(vga_g)));
                    write(l, ' ');
                    write(l, conv_integer(unsigned(vga_b)));
                    write(l, ' ');
                end loop;
                writeline(f, l);
            end loop;
            file_close(f);

            report "frame captured, status = " & integer'image(conv_integer(unsigned(status)))
                severity note;
            done <= true;
            wait;
        end process;
end Behavioral;
