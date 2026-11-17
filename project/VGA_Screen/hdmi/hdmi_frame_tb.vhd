----------------------------------------------------------------------------------
-- Module Name: hdmi_frame_tb - Behavioral
-- Description: HDMI 版的畫面擷取 testbench: vga_core -> hdmi_422, 把一整張畫面送給 ADV7511 的 16 bit 匯流排
--   寫成 hdmi_frame.txt; tools/sim.py 再照 ADV7511 的做法 (4:2:2 -> CSC) 解回 RGB 存成 png
--   開關、按鈕流程與 generic 都和 vga_frame_tb 相同, 同一組 generic 擷取的是同一個 frame
--   檔案格式: 第一行 = 寬 高, 之後每行一條掃描線, 每個像素一個 0..65535 的整數 (高 8 bit = Cb/Cr, 低 8 bit = Y)
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use std.textio.all;
use work.vga_pkg.all;

entity hdmi_frame_tb is
    Generic ( RES       : integer := 0;
              MODE      : integer := 0;
              VARIANT   : integer := 1;
              DEPTH     : integer := 1;
              C_PRESSES : integer := 0;
              BTN       : integer := 0;
              HOLD      : integer := 0;
              SKIP      : integer := 1 );
end hdmi_frame_tb;

architecture Behavioral of hdmi_frame_tb is
    signal CLK    : STD_LOGIC := '0';
    signal RST    : STD_LOGIC := '0';
    signal sw     : STD_LOGIC_VECTOR (6 downto 0);
    signal btn_in : STD_LOGIC_VECTOR (4 downto 0) := (others => '0');
    signal r4, g4, b4 : STD_LOGIC_VECTOR (3 downto 0);
    signal hs, vs, de : STD_LOGIC;
    signal status : STD_LOGIC_VECTOR (6 downto 0);
    signal hd     : STD_LOGIC_VECTOR (15 downto 0);
    signal hde    : STD_LOGIC;
    signal hhs, hvs : STD_LOGIC;
    signal done   : boolean := false;

    constant CLK_PERIOD : time := 10 ns;
    constant T          : timing_type := TIMINGS(RES);
begin
    sw <= conv_std_logic_vector(DEPTH, 1) & conv_std_logic_vector(VARIANT, 1)
          & conv_std_logic_vector(MODE, 3) & conv_std_logic_vector(RES, 2);

    core: entity work.vga_core
        port map ( CLK    => CLK,
                   RST    => RST,
                   sw     => sw,
                   btn    => btn_in,
                   vga_r  => r4,
                   vga_g  => g4,
                   vga_b  => b4,
                   vga_hs => hs,
                   vga_vs => vs,
                   de     => de,
                   status => status );

    uut: entity work.hdmi_422
        port map ( CLK  => CLK,
                   r    => r4,
                   g    => g4,
                   b    => b4,
                   de   => de,
                   hs   => hs,
                   vs   => vs,
                   d    => hd,
                   de_o => hde,
                   hs_o => hhs,
                   vs_o => hvs );

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

        -- 和 vga_frame_tb 一樣只認 非作用 -> 作用 的跳變 (開頭的 'U' -> '0' 不算)
        procedure wait_frames(n : integer) is
            begin
                for i in 1 to n loop
                    wait until hvs'event and hvs = T.sync_pol and hvs'last_value = not T.sync_pol;
                end loop;
            end procedure;
        begin
            wait for CLK_PERIOD * 3;
            RST <= '1';

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

            file_open(f, "hdmi_frame.txt", write_mode);
            write(l, T.h_active);
            write(l, ' ');
            write(l, T.v_active);
            writeline(f, l);

            for row in 0 to T.v_active - 1 loop
                for col in 0 to T.h_active - 1 loop
                    wait until CLK'event and CLK = '1' and hde = '1';
                    write(l, conv_integer(unsigned(hd)));
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
