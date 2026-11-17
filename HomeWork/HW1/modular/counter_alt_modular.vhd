----------------------------------------------------------------------------------
-- Module Name: counter_alt_modular
-- Description: 作業一 - 兩個計數器交替計數 (模組化版本, 單一檔案)
--
--   一個檔案內拆成四個區塊 (entity):
--     [1] up_counter    : 通用上數計數器 (0 -> MAX), 數完發出 done
--     [2] down_counter  : 通用下數計數器 (START -> MIN), 數完發出 done
--     [3] alt_ctrl      : 控制器, 決定現在輪到誰 (turn)
--     [4] counter_alt   : 頂層, 把上面三塊接起來
--
--   要改計數範圍只需改頂層的 generic map, 不用動計數器內部。
--   要改換手規則只需改 alt_ctrl。
----------------------------------------------------------------------------------


--================================================================================
-- [1] up_counter : 通用上數計數器
--     en = '1' 時每拍 +1, 數到 MAX 那拍 done = '1', 下一拍歸 0
--     en = '0' 時停住 (保持 0)
--================================================================================
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

entity up_counter is
    Generic ( WIDTH : integer := 4;
              MAX   : integer := 9 );
    Port ( CLK   : in  STD_LOGIC;
           RST   : in  STD_LOGIC;
           en    : in  STD_LOGIC;
           done  : out STD_LOGIC;
           count : out STD_LOGIC_VECTOR (WIDTH-1 downto 0));
end up_counter;

architecture Behavioral of up_counter is
    signal count_t : STD_LOGIC_VECTOR (WIDTH-1 downto 0);
begin
    process(CLK, RST)
        begin
            if RST = '0' then
                count_t <= (others => '0');
            elsif CLK'event and CLK = '1' then
                if en = '1' then
                    if count_t < MAX then
                        count_t <= count_t + '1';
                    else
                        count_t <= (others => '0');
                    end if;
                end if;
            end if;
        end process;

    -- 數到 MAX 時通知控制器可以換手
    done  <= '1' when (en = '1' and count_t = MAX) else '0';
    count <= count_t;
end Behavioral;


--================================================================================
-- [2] down_counter : 通用下數計數器
--     en = '1' 時每拍 -1, 數到 MIN 那拍 done = '1', 下一拍回 START
--     en = '0' 時停住 (保持 START)
--================================================================================
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

entity down_counter is
    Generic ( WIDTH : integer := 8;
              START : integer := 253;
              MIN   : integer := 17 );
    Port ( CLK   : in  STD_LOGIC;
           RST   : in  STD_LOGIC;
           en    : in  STD_LOGIC;
           done  : out STD_LOGIC;
           count : out STD_LOGIC_VECTOR (WIDTH-1 downto 0));
end down_counter;

architecture Behavioral of down_counter is
    signal count_t : STD_LOGIC_VECTOR (WIDTH-1 downto 0);
begin
    process(CLK, RST)
        begin
            if RST = '0' then
                count_t <= conv_std_logic_vector(START, WIDTH);
            elsif CLK'event and CLK = '1' then
                if en = '1' then
                    if count_t > MIN then
                        count_t <= count_t - '1';
                    else
                        count_t <= conv_std_logic_vector(START, WIDTH);
                    end if;
                end if;
            end if;
        end process;

    done  <= '1' when (en = '1' and count_t = MIN) else '0';
    count <= count_t;
end Behavioral;


--================================================================================
-- [3] alt_ctrl : 交替控制器
--     turn = '0' 輪到 counter1, turn = '1' 輪到 counter2
--     收到目前計數器的 done 就換手
--================================================================================
library IEEE;
use IEEE.std_logic_1164.all;

entity alt_ctrl is
    Port ( CLK   : in  STD_LOGIC;
           RST   : in  STD_LOGIC;
           done1 : in  STD_LOGIC;
           done2 : in  STD_LOGIC;
           en1   : out STD_LOGIC;
           en2   : out STD_LOGIC);
end alt_ctrl;

architecture Behavioral of alt_ctrl is
    signal turn : STD_LOGIC;
begin
    process(CLK, RST)
        begin
            if RST = '0' then
                turn <= '0';                       -- 先由 counter1 開始
            elsif CLK'event and CLK = '1' then
                if turn = '0' and done1 = '1' then
                    turn <= '1';                   -- counter1 數完 -> 換 counter2
                elsif turn = '1' and done2 = '1' then
                    turn <= '0';                   -- counter2 數完 -> 換 counter1
                end if;
            end if;
        end process;

    en1 <= not turn;
    en2 <= turn;
end Behavioral;


--================================================================================
-- [4] counter_alt : 頂層, 接線
--================================================================================
library IEEE;
use IEEE.std_logic_1164.all;

entity counter_alt is
    Port ( CLK    : in  STD_LOGIC;
           RST    : in  STD_LOGIC;
           count1 : out STD_LOGIC_VECTOR (3 downto 0);
           count2 : out STD_LOGIC_VECTOR (7 downto 0));
end counter_alt;

architecture Structural of counter_alt is
    signal en1, en2     : STD_LOGIC;
    signal done1, done2 : STD_LOGIC;
begin
    u_ctrl: entity work.alt_ctrl
        port map ( CLK   => CLK,
                   RST   => RST,
                   done1 => done1,
                   done2 => done2,
                   en1   => en1,
                   en2   => en2 );

    u_cnt1: entity work.up_counter
        generic map ( WIDTH => 4, MAX => 9 )
        port map ( CLK   => CLK,
                   RST   => RST,
                   en    => en1,
                   done  => done1,
                   count => count1 );

    u_cnt2: entity work.down_counter
        generic map ( WIDTH => 8, START => 253, MIN => 17 )
        port map ( CLK   => CLK,
                   RST   => RST,
                   en    => en2,
                   done  => done2,
                   count => count2 );
end Structural;
