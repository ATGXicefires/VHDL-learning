----------------------------------------------------------------------------------
-- Module Name: vga_timing_tb - Behavioral
-- Description: HW3 vga_timing 的自我檢查 testbench
--   對 TIMINGS 表裡的每個解析度量測: H/V 週期、sync 寬度與極性、每行/每張的可視像素數
--   有錯會以 severity error 報出, 全部通過最後印出 "vga_timing_tb PASS"
--   CLK 週期不影響結果, 量測單位都是 CLK 數
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use work.vga_pkg.all;

entity vga_timing_tb is
end vga_timing_tb;

architecture Behavioral of vga_timing_tb is
    signal CLK        : STD_LOGIC := '0';
    signal RST        : STD_LOGIC := '0';
    signal res_sel    : STD_LOGIC_VECTOR (1 downto 0) := "00";
    signal x, y       : coord_type;
    signal active     : STD_LOGIC;
    signal hs, vs     : STD_LOGIC;
    signal frame_tick : STD_LOGIC;
    signal h_size     : coord_type;
    signal v_size     : coord_type;

    signal cyc  : integer := 0;
    signal done : boolean := false;

    constant CLK_PERIOD : time := 10 ns;
begin
    uut: entity work.vga_timing
        port map ( CLK        => CLK,
                   RST        => RST,
                   res_sel    => res_sel,
                   x          => x,
                   y          => y,
                   active     => active,
                   hs         => hs,
                   vs         => vs,
                   frame_tick => frame_tick,
                   h_size     => h_size,
                   v_size     => v_size );

    -- done 之後停掉時脈, 沒有事件模擬就會自己結束
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

    cyc_counter: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                cyc <= cyc + 1;
            end if;
        end process;

    stim_process: process
        variable t      : timing_type;
        variable c0     : integer;
        variable lines  : integer;
        variable errors : integer := 0;

        procedure check(name : string; got, expect : integer) is
            begin
                if got /= expect then
                    report name & " = " & integer'image(got) & ", expect " & integer'image(expect)
                        severity error;
                    errors := errors + 1;
                end if;
            end procedure;
        begin
            for r in 0 to 3 loop
                t := TIMINGS(r);
                RST     <= '0';
                res_sel <= conv_std_logic_vector(r, 2);
                wait for CLK_PERIOD * 3;
                RST <= '1';

                wait until hs'event and hs = t.sync_pol;
                c0 := cyc;
                wait until hs'event and hs /= t.sync_pol;
                check("res " & integer'image(r) & " h_sync width", cyc - c0, t.h_sync_end - t.h_sync_start);
                wait until hs'event and hs = t.sync_pol;
                check("res " & integer'image(r) & " h_total", cyc - c0, t.h_total);

                wait until active'event and active = '1';
                c0 := cyc;
                wait until active'event and active = '0';
                check("res " & integer'image(r) & " h_active", cyc - c0, t.h_active);

                wait until vs'event and vs = t.sync_pol;
                c0 := cyc;
                wait until vs'event and vs /= t.sync_pol;
                check("res " & integer'image(r) & " v_sync width",
                      cyc - c0, (t.v_sync_end - t.v_sync_start) * t.h_total);

                lines := 0;
                while true loop
                    wait until (active'event and active = '1') or (vs'event and vs = t.sync_pol);
                    exit when vs = t.sync_pol;
                    lines := lines + 1;
                end loop;
                check("res " & integer'image(r) & " v_active", lines, t.v_active);
                check("res " & integer'image(r) & " frame", cyc - c0, t.h_total * t.v_total);

                if r = 0 then
                    wait until frame_tick = '1';
                    check("frame_tick line", conv_integer(unsigned(y)), t.v_active);
                    check("frame_tick col", conv_integer(unsigned(x)), 0);
                end if;

                report "res " & integer'image(r) & " checked" severity note;
            end loop;

            if errors = 0 then
                report "vga_timing_tb PASS" severity note;
            else
                report "vga_timing_tb FAIL: " & integer'image(errors) & " error(s)" severity error;
            end if;
            done <= true;
            wait;
        end process;
end Behavioral;
