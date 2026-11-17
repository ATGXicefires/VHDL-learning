----------------------------------------------------------------------------------
-- Module Name: hw1 - Behavioral
-- Description: 作業一 (FSM 版) - 兩個計數器交替計數
--   架構: FSM 輸出 state 給 counter1 / counter2, 兩個計數值再回授給 FSM
--
--          +--------------------------+
--          |          +-----+         |
--          +--------->| FSM |<--------+
--          |          +--+--+         |
--          |             | state      |
--          |      +------+------+     |
--          |      v             v     |
--          | +----------+ +----------+|
--          | | counter1 | | counter2 ||
--          | +----+-----+ +----+-----+|
--          +------+ cnt1       +------+ cnt2
--
--   S0 : counter1 計數 0 -> 9 (上數), counter2 停在 253
--   S1 : counter2 計數 253 -> 17 (下數), counter1 停在 0
--
--   RST = '0' 時重置: state = S0, cnt1 = 0, cnt2 = 253
--
--   規定: 1 個 process 只更動 1 個訊號
--     fsm      -> 只改 state
--     counter1 -> 只改 cnt1
--     counter2 -> 只改 cnt2
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

entity hw1 is
    Port ( CLK    : in  STD_LOGIC;
           RST    : in  STD_LOGIC;
           cnt1_o : out STD_LOGIC_VECTOR (3 downto 0);
           cnt2_o : out STD_LOGIC_VECTOR (7 downto 0));
end hw1;

architecture Behavioral of hw1 is
    type state_type is (S0, S1);                         -- S0: 輪到 counter1, S1: 輪到 counter2
    signal state : state_type;

    signal cnt1  : STD_LOGIC_VECTOR (3 downto 0);
    signal cnt2  : STD_LOGIC_VECTOR (7 downto 0);
begin
    -- FSM: 看 cnt1 / cnt2 決定換手, 只改 state
    fsm: process(CLK, RST)
        begin
            if RST = '0' then
                state <= S0;                             -- 先由 counter1 開始
            elsif CLK'event and CLK = '1' then
                case state is
                    when S0 =>
                        if cnt1 = "1001" then            -- counter1 數到 9 -> 換 counter2
                            state <= S1;
                        end if;
                    when S1 =>
                        if cnt2 = "00010001" then        -- counter2 數到 17 -> 換 counter1
                            state <= S0;
                        end if;
                end case;
            end if;
        end process;

    -- counter1: S0 時 0 -> 9 上數, 數完歸 0; 其他狀態停住
    counter1: process(CLK, RST)
        begin
            if RST = '0' then
                cnt1 <= "0000";
            elsif CLK'event and CLK = '1' then
                if state = S0 then
                    if cnt1 < "1001" then
                        cnt1 <= cnt1 + '1';
                    else
                        cnt1 <= "0000";
                    end if;
                end if;
            end if;
        end process;

    -- counter2: S1 時 253 -> 17 下數, 數完回 253; 其他狀態停住
    counter2: process(CLK, RST)
        begin
            if RST = '0' then
                cnt2 <= "11111101";                     -- 253
            elsif CLK'event and CLK = '1' then
                if state = S1 then
                    if cnt2 > "00010001" then
                        cnt2 <= cnt2 - '1';
                    else
                        cnt2 <= "11111101";
                    end if;
                end if;
            end if;
        end process;

    -- 內部訊號接到輸出
    cnt1_o <= cnt1;
    cnt2_o <= cnt2;
end Behavioral;
