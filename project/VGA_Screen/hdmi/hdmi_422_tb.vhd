----------------------------------------------------------------------------------
-- Module Name: hdmi_422_tb - Behavioral
-- Description: hdmi_422 的自我檢查 testbench
--   4096 色各送一行 (8 個像素 + 4 拍遮沒), 照 ADV7511 的 CSC (adv7511_pkg.CSC_COEF, 四捨五入) 把輸出轉回 RGB,
--   和原本的顏色 (x17) 比, 每個分量誤差要 <= 2; 每行 8 個像素都算, 行首要是邊緣複製, 不能混到上一行的顏色
--   Cb / Cr 順序錯了 (每行第一個像素不是 Cb) 時, 轉回來的顏色會整片不對
--   另外檢查: de_o / hs_o / vs_o = 輸入延遲 LAT 拍、遮沒期間資料為 0、顯示期間 Y >= 16 (資料和 de_o 對齊)
--   有錯會以 severity error 報出, 全部通過最後印出 "hdmi_422_tb PASS"
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use work.adv7511_pkg.all;

entity hdmi_422_tb is
end hdmi_422_tb;

architecture Behavioral of hdmi_422_tb is
    constant CLK_PERIOD : time := 10 ns;
    constant LAT        : integer := 4;
    constant LINE_LEN   : integer := 8;
    constant BLANK_LEN  : integer := 4;

    signal CLK        : STD_LOGIC := '0';
    signal r, g, b    : STD_LOGIC_VECTOR (3 downto 0) := (others => '0');
    signal de, hs, vs : STD_LOGIC := '0';
    signal d          : STD_LOGIC_VECTOR (15 downto 0);
    signal de_o       : STD_LOGIC;
    signal hs_o, vs_o : STD_LOGIC;
    signal stim_done  : boolean := false;
    signal done       : boolean := false;

    -- ADV7511 的 CSC 第 row 列 (0 = R, 1 = G, 2 = B), 結果限制在 0..255
    function csc(row, y, cb, cr : integer) return integer is
        variable num : integer;
        begin
            num := CSC_COEF(4 * row) * cr + CSC_COEF(4 * row + 1) * y + CSC_COEF(4 * row + 2) * cb
                   + 256 * CSC_COEF(4 * row + 3) + 512;
            if num < 0 then
                return 0;
            elsif num / 1024 > 255 then
                return 255;
            else
                return num / 1024;
            end if;
        end function;
begin
    uut: entity work.hdmi_422
        port map ( CLK  => CLK,
                   r    => r,
                   g    => g,
                   b    => b,
                   de   => de,
                   hs   => hs,
                   vs   => vs,
                   d    => d,
                   de_o => de_o,
                   hs_o => hs_o,
                   vs_o => vs_o );

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

    -- 第 c 行的顏色 = c (R = bit 11..8); hs / vs 的花樣故意和 de 錯開, 延遲不一致才看得出來
    stim_process: process
        begin
            wait until CLK'event and CLK = '1';
            for i in 1 to 20 loop
                wait until CLK'event and CLK = '1';
            end loop;
            for c in 0 to 4095 loop
                r  <= conv_std_logic_vector(c / 256, 4);
                g  <= conv_std_logic_vector((c / 16) mod 16, 4);
                b  <= conv_std_logic_vector(c mod 16, 4);
                de <= '1';
                for i in 1 to LINE_LEN loop
                    if i = 3 and c mod 2 = 1 then
                        vs <= '1';
                    elsif i = 3 then
                        vs <= '0';
                    end if;
                    wait until CLK'event and CLK = '1';
                end loop;
                r  <= (others => '0');
                g  <= (others => '0');
                b  <= (others => '0');
                de <= '0';
                for i in 1 to BLANK_LEN loop
                    if i = 2 then
                        hs <= '1';
                    elsif i = 4 then
                        hs <= '0';
                    end if;
                    wait until CLK'event and CLK = '1';
                end loop;
            end loop;
            for i in 1 to 20 loop
                wait until CLK'event and CLK = '1';
            end loop;
            stim_done <= true;
            wait;
        end process;

    check_process: process
        type hist_type is array (0 to LAT - 1) of STD_LOGIC_VECTOR (2 downto 0);
        type word_array is array (0 to LINE_LEN - 1) of integer;
        variable hist     : hist_type := (others => "000");
        variable ys, cs   : word_array;
        variable k        : integer := 0;
        variable line_no  : integer := 0;
        variable cycles   : integer := 0;
        variable errors   : integer := 0;
        variable worst    : integer := 0;
        variable want, got, e : integer;
        variable y, cb, cr    : integer;

        procedure check(name : string; ok : boolean) is
            begin
                if not ok then
                    report name severity error;
                    errors := errors + 1;
                end if;
            end procedure;
        begin
            while not stim_done loop
                wait until CLK'event and CLK = '1';
                -- hist(i) = i 個上升緣之前 DUT 吃進去的輸入; 經過 LAT 級暫存器, 這個上升緣之後的輸出對應 hist(LAT - 1)
                for i in LAT - 1 downto 1 loop
                    hist(i) := hist(i - 1);
                end loop;
                hist(0) := de & hs & vs;
                cycles := cycles + 1;
                wait for 1 ns;

                if cycles > LAT + 2 then
                    check("de/hs/vs delay differs from LAT at cycle " & integer'image(cycles),
                          (de_o & hs_o & vs_o) = hist(LAT - 1));
                    if de_o = '0' then
                        check("data not 0 during blanking at cycle " & integer'image(cycles),
                              conv_integer(unsigned(d)) = 0);
                    else
                        check("Y < 16 while de_o = 1 at cycle " & integer'image(cycles),
                              conv_integer(unsigned(d(7 downto 0))) >= 16);
                    end if;
                end if;

                if de_o = '1' and k < LINE_LEN then
                    ys(k) := conv_integer(unsigned(d(7 downto 0)));
                    cs(k) := conv_integer(unsigned(d(15 downto 8)));
                    k := k + 1;
                elsif de_o = '0' and k > 0 then
                    -- 一行結束: 兩兩一組 (偶數 = Cb, 奇數 = Cr) 轉回 RGB
                    check("line " & integer'image(line_no) & " has " & integer'image(k) & " pixels",
                          k = LINE_LEN);
                    for p in 0 to LINE_LEN - 1 loop
                        y  := ys(p);
                        cb := cs(p - p mod 2);
                        cr := cs(p - p mod 2 + 1);
                        for row in 0 to 2 loop
                            want := ((line_no / 16 ** (2 - row)) mod 16) * 17;
                            got  := csc(row, y, cb, cr);
                            e    := abs (got - want);
                            if e > worst then
                                worst := e;
                            end if;
                            check("color " & integer'image(line_no) & " pixel " & integer'image(p)
                                      & " channel " & integer'image(row) & ": got " & integer'image(got)
                                      & ", expect " & integer'image(want),
                                  e <= 2);
                        end loop;
                    end loop;
                    line_no := line_no + 1;
                    k := 0;
                end if;
            end loop;

            check("lines seen = " & integer'image(line_no), line_no = 4096);
            report "worst channel error = " & integer'image(worst) severity note;
            if errors = 0 then
                report "hdmi_422_tb PASS" severity note;
            else
                report "hdmi_422_tb FAIL: " & integer'image(errors) & " error(s)" severity error;
            end if;
            done <= true;
            wait;
        end process;
end Behavioral;
