----------------------------------------------------------------------------------
-- Module Name: delay_line - Behavioral
-- Description: 固定拍數的移位暫存器, 用來對齊各繪圖器的管線延遲; DEPTH = 0 時直接連通
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

entity delay_line is
    Generic ( WIDTH : integer := 1;
              DEPTH : integer := 1 );
    Port ( CLK  : in  STD_LOGIC;
           din  : in  STD_LOGIC_VECTOR (WIDTH - 1 downto 0);
           dout : out STD_LOGIC_VECTOR (WIDTH - 1 downto 0));
end delay_line;

architecture Behavioral of delay_line is
    type pipe_type is array (1 to DEPTH) of STD_LOGIC_VECTOR (WIDTH - 1 downto 0);
    signal pipe : pipe_type;
begin
    gen_pass: if DEPTH = 0 generate
        dout <= din;
    end generate;

    gen_delay: if DEPTH > 0 generate
        -- 不接 RST: 有重置的移位暫存器無法推論成 SRL, 會多吃很多 FF
        shift: process(CLK)
            begin
                if CLK'event and CLK = '1' then
                    pipe(1) <= din;
                    for i in 2 to DEPTH loop
                        pipe(i) <= pipe(i - 1);
                    end loop;
                end if;
            end process;

        dout <= pipe(DEPTH);
    end generate;
end Behavioral;
