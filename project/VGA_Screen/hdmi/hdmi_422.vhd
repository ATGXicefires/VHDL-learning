----------------------------------------------------------------------------------
-- Module Name: hdmi_422 - Behavioral
-- Description: HDMI 版的像素格式轉換: vga_core 的 RGB (每色 4 bit) -> ADV7511 的 16 bit YCbCr 4:2:2
--   d(15..8) = Cb / Cr 交替 (每行第一個像素放 Cb), d(7..0) = Y; 做法照 ADI 的 ZedBoard 參考設計 (ad_ss_444to422.v),
--   只多了行首的邊緣複製
--   ADV7511 再用晶片內的 CSC (adv7511_pkg) 轉回 RGB
--   延遲 4 拍, de_o / hs_o / vs_o 也延遲 4 拍; 輸出全部直接來自暫存器, 才能放進 IOB
--
--   規定: 1 個 process 只更動 1 個訊號
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;

entity hdmi_422 is
    Port ( CLK  : in  STD_LOGIC;
           r    : in  STD_LOGIC_VECTOR (3 downto 0);
           g    : in  STD_LOGIC_VECTOR (3 downto 0);
           b    : in  STD_LOGIC_VECTOR (3 downto 0);
           de   : in  STD_LOGIC;
           hs   : in  STD_LOGIC;
           vs   : in  STD_LOGIC;
           d    : out STD_LOGIC_VECTOR (15 downto 0);
           de_o : out STD_LOGIC;
           hs_o : out STD_LOGIC;
           vs_o : out STD_LOGIC);
end hdmi_422;

architecture Behavioral of hdmi_422 is
    -- BT.709 limited range (Y 16..235, Cb/Cr 16..240), 係數已乘上 17 (4 bit -> 8 bit) 再放大 256 倍;
    -- 從 CSC_COEF 的反矩陣出發再微調, 4096 色經 ADV7511 轉回 RGB 後每個分量誤差都 <= 2,
    -- 晶片內部不論四捨五入或截斷都成立, 黑、白也剛好回到 0 和 255
    -- Cb、Cr 的正負係數加起來相等, 灰階的 Cb = Cr = 128, 不會偏色; 中間值都在 0..65535, 用 16 bit 無號數即可
    constant Y_OFS : STD_LOGIC_VECTOR (15 downto 0) := conv_std_logic_vector(4207, 16);
    constant C_OFS : STD_LOGIC_VECTOR (15 downto 0) := conv_std_logic_vector(32896, 16);
    constant K_YR  : STD_LOGIC_VECTOR (11 downto 0) := conv_std_logic_vector(796, 12);
    constant K_YG  : STD_LOGIC_VECTOR (11 downto 0) := conv_std_logic_vector(2666, 12);
    constant K_YB  : STD_LOGIC_VECTOR (11 downto 0) := conv_std_logic_vector(271, 12);
    constant K_CBR : STD_LOGIC_VECTOR (11 downto 0) := conv_std_logic_vector(439, 12);
    constant K_CBG : STD_LOGIC_VECTOR (11 downto 0) := conv_std_logic_vector(1467, 12);
    constant K_CBB : STD_LOGIC_VECTOR (11 downto 0) := conv_std_logic_vector(1906, 12);
    constant K_CRR : STD_LOGIC_VECTOR (11 downto 0) := conv_std_logic_vector(1905, 12);
    constant K_CRG : STD_LOGIC_VECTOR (11 downto 0) := conv_std_logic_vector(1730, 12);
    constant K_CRB : STD_LOGIC_VECTOR (11 downto 0) := conv_std_logic_vector(175, 12);

    signal y_sum, cb_sum, cr_sum : STD_LOGIC_VECTOR (15 downto 0);
    signal ycc1, ycc2, ycc3      : STD_LOGIC_VECTOR (23 downto 0);  -- Cr & Y & Cb
    signal ycc3e                 : STD_LOGIC_VECTOR (23 downto 0);
    signal sync1, sync2, sync3   : STD_LOGIC_VECTOR (2 downto 0);   -- de & hs & vs
    signal sync4                 : STD_LOGIC_VECTOR (2 downto 0);
    signal cb_f, cr_f            : STD_LOGIC_VECTOR (9 downto 0);
    signal chroma                : STD_LOGIC_VECTOR (15 downto 0);  -- 濾波後的 Cr & Cb
    signal cr_sel                : STD_LOGIC;
    signal d_r                   : STD_LOGIC_VECTOR (15 downto 0);
begin
    y_sum  <= Y_OFS + r * K_YR + g * K_YG + b * K_YB;
    cb_sum <= C_OFS + b * K_CBB - r * K_CBR - g * K_CBG;
    cr_sum <= C_OFS + r * K_CRR - g * K_CRG - b * K_CRB;

    -- 資料只在各級的 de = '1' 時前進: 遮沒期間保留最後一個像素, 行尾的色度濾波才不會混進遮沒的黑色
    -- 不接 RST: 每行前面的遮沒就會把 cr_sel 歸零, 其他都是資料
    s1_ycc: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                if de = '1' then
                    ycc1 <= cr_sum(15 downto 8) & y_sum(15 downto 8) & cb_sum(15 downto 8);
                end if;
            end if;
        end process;

    s2_ycc: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                if sync1(2) = '1' then
                    ycc2 <= ycc1;
                end if;
            end if;
        end process;

    s3_ycc: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                if sync2(2) = '1' then
                    ycc3 <= ycc2;
                end if;
            end if;
        end process;

    s1_sync: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                sync1 <= de & hs & vs;
            end if;
        end process;

    s2_sync: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                sync2 <= sync1;
            end if;
        end process;

    s3_sync: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                sync3 <= sync2;
            end if;
        end process;

    s4_sync: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                sync4 <= sync3;
            end if;
        end process;

    -- 行首時 ycc3 還是上一行的最後一個像素, 改用目前的像素 (邊緣複製), 每行最左邊才不會混到上一行右邊的顏色
    -- (ADI 原本的寫法沒處理, 例如右邊是亮藍、左邊是黑的畫面, 最左一行會偏藍)
    ycc3e <= ycc3 when sync3(2) = '1' else ycc2;

    -- 4:2:2 每 2 個像素只送 1 組色度, 先用 [1 2 1] / 4 低通, 細線和字的邊緣才不會出現色紋
    cb_f <= ("00" & ycc1(7 downto 0)) + (ycc2(7 downto 0) & '0') + ("00" & ycc3e(7 downto 0));
    cr_f <= ("00" & ycc1(23 downto 16)) + (ycc2(23 downto 16) & '0') + ("00" & ycc3e(23 downto 16));

    -- 濾波中心是 ycc2, 和下一拍的 ycc3 對齊
    filt: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                chroma <= cr_f(9 downto 2) & cb_f(9 downto 2);
            end if;
        end process;

    -- ADV7511 靠「每行第一個像素是 Cb」分辨 Cb / Cr
    sel: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                if sync3(2) = '1' then
                    cr_sel <= not cr_sel;
                else
                    cr_sel <= '0';
                end if;
            end if;
        end process;

    -- 遮沒期間送 0 (和 ADI 相同), 匯流排安靜一點
    dout: process(CLK)
        begin
            if CLK'event and CLK = '1' then
                if sync3(2) = '0' then
                    d_r <= (others => '0');
                elsif cr_sel = '1' then
                    d_r <= chroma(15 downto 8) & ycc3(15 downto 8);
                else
                    d_r <= chroma(7 downto 0) & ycc3(15 downto 8);
                end if;
            end if;
        end process;

    d    <= d_r;
    de_o <= sync4(2);
    hs_o <= sync4(1);
    vs_o <= sync4(0);
end Behavioral;
