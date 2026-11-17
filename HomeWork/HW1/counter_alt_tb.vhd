----------------------------------------------------------------------------------
-- Module Name: counter_alt_tb - Behavioral
-- Description: 作業一 counter_alt 的 testbench
--   產生 10ns 週期的 CLK, 一開始 RST 拉低重置, 之後觀察兩個計數器交替計數
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

entity counter_alt_tb is
-- testbench 沒有 port
end counter_alt_tb;

architecture Behavioral of counter_alt_tb is
    -- 受測元件宣告
    component counter_alt
        Port ( CLK    : in  STD_LOGIC;
               RST    : in  STD_LOGIC;
               count1 : out STD_LOGIC_VECTOR (3 downto 0);
               count2 : out STD_LOGIC_VECTOR (7 downto 0));
    end component;

    -- 輸入訊號
    signal CLK    : STD_LOGIC := '0';
    signal RST    : STD_LOGIC := '0';

    -- 輸出訊號
    signal count1 : STD_LOGIC_VECTOR (3 downto 0);
    signal count2 : STD_LOGIC_VECTOR (7 downto 0);

    constant CLK_PERIOD : time := 10 ns;
begin
    -- 接上受測元件
    uut: counter_alt
        port map ( CLK    => CLK,
                   RST    => RST,
                   count1 => count1,
                   count2 => count2 );

    -- 時脈產生
    clk_process: process
        begin
            CLK <= '0';
            wait for CLK_PERIOD / 2;
            CLK <= '1';
            wait for CLK_PERIOD / 2;
        end process;

    -- 刺激訊號
    stim_process: process
        begin
            RST <= '0';                      -- 先重置
            wait for CLK_PERIOD * 2;
            RST <= '1';                      -- 解除重置, 開始計數

            -- 一輪 = counter1 走 10 拍 + counter2 走 237 拍 (253 -> 17)
            -- 跑 3 輪以上確認有交替
            wait for CLK_PERIOD * 800;

            wait;                            -- 模擬結束, 停在這裡
        end process;
end Behavioral;
