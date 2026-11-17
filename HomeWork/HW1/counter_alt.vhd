----------------------------------------------------------------------------------
-- Module Name: counter_alt - Behavioral
-- Description: 作業一 - 兩個計數器交替計數
--   counter1 : 0 -> 9 (上數), 數完停在 0 等待
--   counter2 : 253 -> 17 (下數), 數完停在 253 等待
--   turn = '0' 時 counter1 計數、counter2 停住
--   turn = '1' 時 counter2 計數、counter1 停住
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

entity counter_alt is
    Port ( CLK    : in  STD_LOGIC;
           RST    : in  STD_LOGIC;
           count1 : out STD_LOGIC_VECTOR (3 downto 0);
           count2 : out STD_LOGIC_VECTOR (7 downto 0));
end counter_alt;

architecture Behavioral of counter_alt is
    signal count1_t : STD_LOGIC_VECTOR (3 downto 0);
    signal count2_t : STD_LOGIC_VECTOR (7 downto 0);
    signal turn     : STD_LOGIC;   -- '0': 輪到 counter1, '1': 輪到 counter2
begin
    -- 一個 process 同時處理兩個計數器與換手, 避免多重驅動
    counters: process(CLK, RST)
        begin
            if RST = '0' then
                count1_t <= "0000";
                count2_t <= "11111101";          -- 253
                turn     <= '0';                 -- 先由 counter1 開始
            elsif CLK'event and CLK = '1' then
                if turn = '0' then
                    -- counter1 計數, counter2 停在 253
                    if count1_t < "1001" then    -- 0 ~ 8 繼續加
                        count1_t <= count1_t + '1';
                    else                         -- 數到 9, 歸 0 並換 counter2
                        count1_t <= "0000";
                        turn     <= '1';
                    end if;
                else
                    -- counter2 計數, counter1 停在 0
                    if count2_t > "00010001" then -- 253 ~ 18 繼續減 (下限 17)
                        count2_t <= count2_t - '1';
                    else                         -- 數到 17, 回 253 並換 counter1
                        count2_t <= "11111101";
                        turn     <= '0';
                    end if;
                end if;
            end if;
        end process;

    -- 內部訊號接到輸出
    count1 <= count1_t;
    count2 <= count2_t;
end Behavioral;
