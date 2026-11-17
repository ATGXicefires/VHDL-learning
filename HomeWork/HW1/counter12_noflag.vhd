----------------------------------------------------------------------------------
-- Module Name: counter12 - Behavioral
-- Description: 作業一 - 不新增任何訊號, 直接用對方的數值判斷是否輪到自己
--   counter1 只在 counter2 停在 253 (休息中) 時才數
--   counter2 在 counter1 數到 9 時開始數, 之後只要 counter1 停在 0 就繼續數
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

entity counter12 is
    Port ( CLK    : in  STD_LOGIC;
           RST    : in  STD_LOGIC;
           count1 : out STD_LOGIC_VECTOR (3 downto 0);
           count2 : out STD_LOGIC_VECTOR (7 downto 0));
end counter12;

architecture Behavioral of counter12 is
    signal count1_t : STD_LOGIC_VECTOR (3 downto 0);
    signal count2_t : STD_LOGIC_VECTOR (7 downto 0);
begin
    counter1: process(CLK, RST)
        begin
            if RST = '0' then
                count1_t <= "0000";
            elsif CLK'event and CLK = '1' then
                if count2_t = "11111101" then          -- [改] counter2 在 253 休息時才動
                    if count1_t < "1001" then
                        count1_t <= count1_t + '1';
                    else
                        count1_t <= "0000";
                    end if;
                end if;
            end if;
        end process;

    counter2: process(CLK, RST)
        begin
            if RST = '0' then
                count2_t <= "11111101";
            elsif CLK'event and CLK = '1' then
                -- [改] 兩種情況才動:
                --   1. counter1 剛數到 9 (這拍 counter1 會歸 0, counter2 跟著踏出第一步 253->252)
                --   2. counter1 停在 0 且自己已經離開 253 (表示正在自己的回合)
                if count1_t = "1001" or
                   (count1_t = "0000" and count2_t /= "11111101") then
                    if count2_t > "00010001" then      -- 253 倒數到 17
                        count2_t <= count2_t - '1';
                    else
                        count2_t <= "11111101";
                    end if;
                end if;
            end if;
        end process;

    -- 內部訊號接到輸出
    count1 <= count1_t;
    count2 <= count2_t;
end Behavioral;
