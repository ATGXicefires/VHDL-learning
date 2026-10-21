----------------------------------------------------------------------------------
-- Module Name: image_rom - Behavioral
-- Description: HW3 bonus 複雜圖案, 把 embed0008_HD.jpg 存在 Block RAM 裡顯示 (延遲 LAT_IMAGE 拍)
--   圖片 480x480, 4 bit 灰階, 放在畫面正中央; 內容由 tools/gen_rom.py 產生在 image_rom_pkg
--   每個 32 bit word 放 8 個像素, 30720 words 約佔 30 個 RAMB36 (晶片共 140 個)
--   depth = 1 bit 時由 vga_core 做 Bayer 抖動
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;
use work.vga_pkg.all;
use work.image_rom_pkg.all;

entity image_rom is
    Port ( CLK    : in  STD_LOGIC;
           RST    : in  STD_LOGIC;
           x      : in  coord_type;
           y      : in  coord_type;
           h_size : in  coord_type;
           v_size : in  coord_type;
           rgb    : out rgb_type);
end image_rom;

architecture Behavioral of image_rom is
    constant IMG : integer := 480;

    signal rom : image_rom_type := IMAGE_DATA;
    attribute rom_style : string;
    attribute rom_style of rom : signal is "block";

    signal h_rest, v_rest : coord_type;
    signal x0, y0         : coord_type;
    signal ix, iy         : STD_LOGIC_VECTOR (11 downto 0);
    signal inside         : STD_LOGIC;
    signal addr           : STD_LOGIC_VECTOR (14 downto 0);

    signal word, word_q   : STD_LOGIC_VECTOR (31 downto 0);
    signal inside_p       : STD_LOGIC_VECTOR (1 downto 0);
    signal sel_p          : STD_LOGIC_VECTOR (5 downto 0);    -- ix(2..0) 延遲 2 拍, 選 word 裡的第幾個像素
    signal gray           : STD_LOGIC_VECTOR (3 downto 0);
    signal rgb_r          : rgb_type;
begin
    h_rest <= h_size - IMG;
    v_rest <= v_size - IMG;
    x0     <= '0' & h_rest(10 downto 1);
    y0     <= '0' & v_rest(10 downto 1);

    ix_reg: process(CLK, RST)
        begin
            if RST = '0' then
                ix <= (others => '0');
            elsif CLK'event and CLK = '1' then
                ix <= ('0' & x) - ('0' & x0);
            end if;
        end process;

    iy_reg: process(CLK, RST)
        begin
            if RST = '0' then
                iy <= (others => '0');
            elsif CLK'event and CLK = '1' then
                iy <= ('0' & y) - ('0' & y0);
            end if;
        end process;

    -- ix/iy 為負時最高位元是 1, 會被當成很大的數, 一起被 < IMG 擋掉
    inside <= '1' when ix < IMG and iy < IMG else '0';
    addr   <= iy(8 downto 0) & ix(8 downto 3);

    -- BRAM 的資料暫存器只支援同步重置, 不接 RST 才能吸進 RAMB36;
    -- 圖片外不讀, 避免 iy >= 480 時位址超出 ROM 範圍
    rom_read: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                if inside = '1' then
                    word <= rom(conv_integer(addr));
                end if;
            end if;
        end process;

    -- 再多一級讓 Vivado 用上 BRAM 內建的輸出暫存器, 108 MHz 下 clock-to-out 才夠快
    word_reg: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                word_q <= word;
            end if;
        end process;

    inside_pipe: process(CLK, RST)
        begin
            if RST = '0' then
                inside_p <= "00";
            elsif CLK'event and CLK = '1' then
                inside_p <= inside_p(0) & inside;
            end if;
        end process;

    sel_pipe: process(CLK, RST)
        begin
            if RST = '0' then
                sel_p <= (others => '0');
            elsif CLK'event and CLK = '1' then
                sel_p <= sel_p(2 downto 0) & ix(2 downto 0);
            end if;
        end process;

    with sel_p(5 downto 3) select
        gray <= word_q(3 downto 0)   when "000",
                word_q(7 downto 4)   when "001",
                word_q(11 downto 8)  when "010",
                word_q(15 downto 12) when "011",
                word_q(19 downto 16) when "100",
                word_q(23 downto 20) when "101",
                word_q(27 downto 24) when "110",
                word_q(31 downto 28) when others;

    rgb_reg: process(CLK, RST)
        begin
            if RST = '0' then
                rgb_r <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if inside_p(1) = '1' then
                    rgb_r <= gray & gray & gray;
                else
                    rgb_r <= (others => '0');
                end if;
            end if;
        end process;

    rgb <= rgb_r;
end Behavioral;
