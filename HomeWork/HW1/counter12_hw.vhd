----------------------------------------------------------------------------------
-- Module Name: counter12 - Behavioral
-- Description: 作業一 - 在課堂 counter12 的基礎上改成交替計數
--   改動處都以  -- [改] / -- [新增]  標示
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
    signal turn     : STD_LOGIC;   -- [新增] '0': 輪到 counter1, '1': 輪到 counter2
begin
    counter1: process(CLK, RST)
        begin
            if RST = '0' then
                count1_t <= "0000";
            elsif CLK'event and CLK = '1' then
                if turn = '0' then                 -- [改] 只有輪到自己才動
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
                if turn = '1' then                 -- [改] 只有輪到自己才動
                    if count2_t > "00010001" then  -- 253 倒數到 17
                        count2_t <= count2_t - '1';
                    else
                        count2_t <= "11111101";
                    end if;
                end if;
            end if;
        end process;

    -- [新增] 換手控制: 誰數完就換給另一個
    switch: process(CLK, RST)
        begin
            if RST = '0' then
                turn <= '0';                       -- 先由 counter1 開始
            elsif CLK'event and CLK = '1' then
                if turn = '0' and count1_t = "1001" then      -- counter1 數到 9
                    turn <= '1';
                elsif turn = '1' and count2_t = "00010001" then -- counter2 數到 17
                    turn <= '0';
                end if;
            end if;
        end process;

    -- 內部訊號接到輸出
    count1 <= count1_t;
    count2 <= count2_t;
end Behavioral;
