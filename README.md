# HW3 VGA 掃描

目標板：E-Elements EGO-XZ7（xc7z020clg484-1，系統時脈 100 MHz，和 Breathing_LED 同一塊）

基本題：在 640x480 的螢幕上顯示 R、G、B 三個色塊，位置和大小可以任意調整，R/G/B 各 1 bit。
Bonus：其他解析度、R/G/B 灰階、色塊圖形（橢圓 / 圓 / 三角形，分空心與實心）、3D 旋轉物體、存在 RAM 裡的複雜圖案。
另外加了兩個好玩的：像 DVD 螢幕保護程式一樣到處彈的 CD，以及單人空氣曲棍球（玩家對電腦）。

---

## 1. 操作方式

### 開關

| 開關 | 名稱 | 功能 |
|---|---|---|
| SW7 | RST | 撥上 = 運作，撥下 = 重置 |
| SW6 | depth | 0 = 每色 1 bit（8 色，灰階用 4x4 Bayer 抖動），1 = 每色 4 bit（4096 色） |
| SW5 | variant | 0 = 空心（3D 時是線框），1 = 實心（3D 時是貼圖加明暗）；模式 001 時 0 = 灰階色條，1 = RAM 圖片；模式 110 時 0 = 單色 CD、1 = 彩虹 CD；模式 111 時是電腦難度（0 簡單、1 困難） |
| SW4..2 | mode | 見下表 |
| SW1..0 | res_sel | 00 = 640x480，01 = 800x600，10 = 1024x768，11 = 1280x1024（都是 60 Hz） |

| mode (SW4..2) | 畫面 |
|---|---|
| 000 | R/G/B 三個色塊（基本題），重疊處會加色混出黃、青、洋紅、白 |
| 001 | 灰階：8 色純色條 + R/G/B/白各 16 階漸層；SW5 = 1 時改成 RAM 圖片 |
| 010 | 橢圓 |
| 011 | 圓 |
| 100 | 三角形 |
| 101 | 3D 旋轉物體：橄欖球 / 球（海灘球）/ 三角錐（正四面體），用 BTNL / BTNR 切換 |
| 110 | CD 彈跳（像 DVD 螢幕保護程式，碰到畫面邊緣就反彈） |
| 111 | 單人空氣曲棍球（玩家對電腦） |

### 按鈕

| 模式 | BTNC | BTNU / BTND / BTNL / BTNR |
|---|---|---|
| 色塊 | 依序切換：R 移動 → R 縮放 → G 移動 → G 縮放 → B 移動 → B 縮放 | 移動或縮放（按住會持續變化，每個 frame 2 像素） |
| 2D 圖形 | 切換 移動 / 縮放 | 移動；縮放時 L/R 調寬、U/D 調高，圓只有半徑 |
| 3D | 暫停 / 繼續 | U / D 加快 / 減慢旋轉；R / L 換下一個 / 上一個物體（橄欖球 → 球 → 三角錐 循環） |
| CD 彈跳 | 暫停 / 繼續 | U / D 加快 / 減慢（7 段） |
| 空氣曲棍球 | 比賽中 = 暫停 / 繼續；比賽結束後 = 開新的一局 | 移動自己的球槌（按住越久越快） |

切換解析度時，2D 圖形會自動回到畫面中央，色塊和 CD 會被推回畫面內，曲棍球重新開球（比分保留）。1024x768 以上的 3D 物體、CD、曲棍球場都會放大 2 倍。

### 空氣曲棍球怎麼玩

- 你是左邊的紅色球槌，電腦是右邊的藍色球槌，只能在自己的半場移動。黃色的是球。
- 把球打進右邊牆上的黑色開口就得 1 分；球進了自己的球門（左邊）就是電腦得分。比分顯示在畫面上方，紅色是你、藍色是電腦。
- 進球後球門會閃一下，約 1 秒後由失分的一方開球（球放在失分方半場的中央）。
- 先得 7 分的人獲勝，勝方的比分會閃爍；按 BTNC 開新的一局。
- 球槌按住方向鍵會從每 frame 2 像素加速到 6 像素：輕點可以微調位置，衝過去撞球可以打得很用力。斜著打、利用上下牆反彈比較容易騙過電腦。
- SW5 = 0 時電腦比較慢（守門 2、出擊 4 像素 / frame），SW5 = 1 時比較快（4 / 6）。
- 切到別的模式時遊戲會凍結，切回來可以接著玩。

### LED

| LED | 意義 |
|---|---|
| LD0 | MMCM 已鎖定（像素時脈穩定） |
| LD1 / LD2 / LD3 | 色塊模式中正在編輯 R / G / B；3D 模式中目前是橄欖球 / 球 / 三角錐 |
| LD4 | 縮放模式（色塊或 2D 圖形） |
| LD5 | 已暫停（3D、CD 彈跳、空氣曲棍球） |

---

## 2. 硬體接線（自製 VGA 轉接板）

### 2.1 原理

EGO-XZ7 只有 HDMI 輸出，沒有 VGA 接頭，所以要自己用電阻做一塊「數位轉類比」的轉接板。

VGA 的 R/G/B 是類比訊號：螢幕端每色有 75 Ω 接地，滿刻度只有 0.7 V。FPGA 的輸出是 3.3 V（或 2.5 V），因此每支腳都要串一顆電阻，跟螢幕的 75 Ω 分壓：

```
V = Vbank * 75 / (R + 75)
3.3 V * 75 / (270 + 75) = 0.72 V
```

**R/G/B 絕對不能不串電阻直接接**：3.3 V 直接接 75 Ω，一支腳要拉約 44 mA，遠超過 FPGA 腳位預設的 12 mA。

4 bit 版的每個顏色要用 4 支腳，各串一顆電阻，電阻值依位元權重加倍（R、2R、4R、8R），最後並接到同一條線上。因為 4 顆電阻永遠都接著（輸出 0 時接地、輸出 1 時接 Vbank），輸出電壓跟 4 bit 數值成正比，形成一個 16 階的 DAC。

### 2.2 先確認的事

1. **先問老師或助教**：實驗室可能已經有 VGA 擴充板，或指定好要接哪個排針。有的話直接跳到第 3 節。
2. **查腳位**：從 EGO-XZ7 的電路圖或手冊（課程平台、瑞宇官網下載區、板子附的光碟），或板子上的絲印，找出：
   - 排針上哪幾支腳接到 **PL**，以及它們的 package pin 名稱（像 `Y11`、`AB10` 這種）
   - 那幾支腳所在 bank 的電壓（VCCO）：3.3 V 或 2.5 V，確認方法見 2.3
3. **決定接 1 bit 還是 4 bit**：
   - **4 bit 轉接板可以同時做 1 bit 和 4 bit**，用 SW6 切換：SW6 = 0 時每色的 4 支腳一起輸出 0000 或 1111，就是 1 bit 的 8 色；SW6 = 1 才用到 16 階。腳位夠的話直接接 4 bit 就好，不用做兩塊。
   - 1 bit 轉接板（每色只接 MSB）只能做 1 bit；SW6 = 1 時灰階會只剩兩階。
   - 4 bit 需要 14 支腳（每色 4 支 + HS、VS），1 bit 只要 5 支（R、G、B、HS、VS）。
   - GPIO 排針只有 7 支 PL 腳，只夠 1 bit；4 bit 要用樹莓派排針（前提是它接到 PL）或 FMC。

### 2.3 確認 bank 電壓

FPGA 的 PL 腳只分布在 4 個 bank。從板上已知的腳位（Vivado 查詢）可以知道各 bank 的電壓：

| Bank | 板上用到的腳 | 電壓 |
|---|---|---|
| 13 | 100 MHz 時脈（Y9） | 3.3 V |
| 33 | LED | 3.3 V |
| 34 | 按鈕、部分開關 | 2.5 V |
| 35 | 其餘開關 | 2.5 V |

電壓是依廠商的板子設定檔（LED 是 LVCMOS33，開關和按鈕是 LVCMOS25），沒有實際量過。bank 500 / 501 / 502 是 PS 端的腳（GPIO 排針上那 7 支 PS 腳），VGA 邏輯接不到。

所以只要知道排針那幾支腳屬於哪個 bank，再對照上表就好：

1. **看電路圖（最準）**：接到排針的 FPGA 訊號名稱，最後的數字就是 bank，例如 `IO_L12P_T1_MRCC_33` 是 bank 33。電源頁會寫 `VCCO_33` 接到 3V3 還是 2V5。
2. **只有 package pin 名稱（像 `AB10`）時**：在 Vivado 開啟 implemented design，在 Tcl Console 輸入

   ```tcl
   get_property BANK [get_package_pins AB10]
   ```

3. **用三用電表實際量**（黑棒接 GND，紅棒碰排針腳，小心別同時碰到兩支腳造成短路）：
   - 還沒燒錄時：SW8 全部 ON、剛上電、還沒燒 bitstream 時，FPGA 的 I/O 通常會被上拉到該 bank 的電壓。量到約 3.3 V 或 2.5 V，那就是那個 bank 的電壓；量到 0 V 只代表板子把上拉關掉了，要改用下一個方法。
   - 燒測試 bitstream 後：讓那支腳固定輸出 1 再量，結果一定準。

這塊板的 LED、開關腳位跟 ZedBoard 一樣。ZedBoard 的 bank 34、35 電壓可以用跳線切換，如果 EGO-XZ7 上看到標著 VADJ 的跳線，代表 34、35 的電壓可能不是固定 2.5 V，要以跳線位置或電路圖為準。

### 2.4 接線圖

電阻單位都是 Ω，數值是 3.3 V bank 用的（2.5 V 見 2.5 的表）。

**1 bit（基本題，5 支腳）**

```
 FPGA pin              resistor          DB15 female         inside the monitor
 vga_r[3] -------------[ 270 ]---------- pin 1   R ---------- 75 -- GND
 vga_g[3] -------------[ 270 ]---------- pin 2   G ---------- 75 -- GND
 vga_b[3] -------------[ 270 ]---------- pin 3   B ---------- 75 -- GND
 vga_hs   -------------[ 100 ]---------- pin 13  HS
 vga_vs   -------------[ 100 ]---------- pin 14  VS
 GND      ------------------------------ pin 5, 6, 7, 8, 10  GND
```

**4 bit（灰階 bonus，14 支腳）**：HS、VS、GND 跟 1 bit 一樣，每個顏色接成下面這樣（圖為 R，G 接 pin 2、B 接 pin 3）

```
 vga_r[3] (MSB) --[  510 ]--+
 vga_r[2]       --[ 1000 ]--+
 vga_r[1]       --[ 2000 ]--+------- DB15 pin 1 (R) ------- 75 -- GND (inside the monitor)
 vga_r[0] (LSB) --[ 3900 ]--+
```

**接到 EGO-XZ7 的 JA2（Pi-CON）排針**：腳位跟樹莓派 40 pin 一樣，是用 [Pin_Finder](../Pin_Finder/README.md) 實測的，全部在 bank 13（3.3 V），所以用 3.3 V 那組電阻。

| 訊號 | JA2 腳號 | package pin | 電阻 | 接到 DB15 |
|---|---|---|---|---|
| vga_r[3] / [2] / [1] / [0] | 11 / 12 / 13 / 15 | AB10 / AA7 / AB9 / AA6 | 510 / 1k / 2k / 3.9k | 1（R） |
| vga_g[3] / [2] / [1] / [0] | 16 / 18 / 19 / 21 | AB2 / AB1 / Y11 / Y10 | 510 / 1k / 2k / 3.9k | 2（G） |
| vga_b[3] / [2] / [1] / [0] | 23 / 24 / 26 / 27 | AB6 / AB4 / AB7 / W7 | 510 / 1k / 2k / 3.9k | 3（B） |
| vga_hs | 28 | W6 | 100 | 13 |
| vga_vs | 29 | Y4 | 100 | 14 |
| GND | 25（或 20、30、34） | — | — | 5、6、7、8、10 |

JA2 的 1、17 腳是 3.3 V，2、4 腳是 5 V，都不要接。

### 2.5 電阻值

| bank 電壓 | 1 bit（每色 1 顆） | 4 bit（bit3 / bit2 / bit1 / bit0） | HS、VS |
|---|---|---|---|
| 3.3 V | 270 Ω | 510 / 1k / 2k / 3.9k Ω | 100 Ω |
| 2.5 V | 180 Ω | 360 / 750 / 1.5k / 3k Ω | 100 Ω |

滿刻度都約 0.7 V。1/4 W 就夠，有 1% 金屬膜的更好。

### 2.6 材料清單

先確認 bank 電壓，電阻只要買其中一組。全部都是 1/4 W。電阻通常 10 顆一包，每種買一包就夠，還有備品。

**電阻：3.3 V bank，接 4 bit（建議，可以同時做 1 bit 和 4 bit）**

| 電阻 | 數量 | 接在哪 |
|---|---|---|
| 510 Ω | 3 | R、G、B 的 bit3 各 1 顆 |
| 1 kΩ | 3 | R、G、B 的 bit2 各 1 顆 |
| 2 kΩ | 3 | R、G、B 的 bit1 各 1 顆 |
| 3.9 kΩ | 3 | R、G、B 的 bit0 各 1 顆 |
| 100 Ω | 2 | HS、VS 各 1 顆 |

**電阻：2.5 V bank，接 4 bit**

| 電阻 | 數量 | 接在哪 |
|---|---|---|
| 360 Ω | 3 | R、G、B 的 bit3 各 1 顆 |
| 750 Ω | 3 | R、G、B 的 bit2 各 1 顆 |
| 1.5 kΩ | 3 | R、G、B 的 bit1 各 1 顆 |
| 3 kΩ | 3 | R、G、B 的 bit0 各 1 顆 |
| 100 Ω | 2 | HS、VS 各 1 顆 |

**電阻：只接 1 bit（PL 腳不夠 14 支時）**

| 電阻 | 數量 | 接在哪 |
|---|---|---|
| 270 Ω（3.3 V bank）或 180 Ω（2.5 V bank） | 3 | R、G、B 各 1 顆 |
| 100 Ω | 2 | HS、VS 各 1 顆 |

**其他材料**

| 項目 | 數量 | 備註 |
|---|---|---|
| VGA 母座轉接板（DB15 母座拉出端子或排針） | 1 | 腳位編號印在板上，最不容易接錯 |
| 麵包板 | 1 | |
| 杜邦線（母對公） | 20 條 | 板子排針是公頭時用母對公 |
| VGA 線（公對公） | 1 | 螢幕只有 HDMI 輸入的話，改買「主動式 VGA 轉 HDMI」轉換器，被動轉接頭不能用 |

### 2.7 注意事項

- 接線時板子要斷電。
- 板子 GND 一定要接到 DB15 的 GND（5、6、7、8、10 腳），少接這條通常就是「無訊號」。
- DB15 的第 9 腳（+5V）和 4、11、12、15 腳（螢幕 ID / DDC）**都不要接**。
- DB15 的腳位編號以轉接板上的標示為準：母座從正面看，第一排是 5 4 3 2 1（由左到右），跟公頭相反。
- 杜邦線盡量短。1280x1024 的像素時脈是 108 MHz，線太長畫面會糊；第一次先用 640x480 測。

---

## 3. 填腳位與產生 bitstream

1. JA2 的腳位已經填在 [vga_screen.xdc](vga_screen.xdc)（MSB 與同步訊號）和 [vga_lsb.xdc](vga_lsb.xdc)（低 3 位元），對照表見 2.4。
2. 改接別的排針時，用 [Pin_Finder](../Pin_Finder/README.md) 查腳位後改這兩個檔的 `PACKAGE_PIN`。
3. `IOSTANDARD` 要配合該 bank 的電壓：3.3 V 用 `LVCMOS33`，2.5 V 用 `LVCMOS25`（JA2 是 3.3 V）。
4. **只接 1 bit 時**：
   - 把 `vga_top` 的 generic `OUT_BITS` 設成 1（Vivado：Settings → General → Generics/Parameters，或 Tcl `set_property generic OUT_BITS=1 [current_fileset]`）
   - 把 `vga_lsb.xdc` disable（Sources 視窗右鍵 → Disable File）
   - 這時 port 只剩 `vga_r[3]`、`vga_g[3]`、`vga_b[3]`、`vga_hs`、`vga_vs`，SW6 會固定用抖動輸出
5. 產生 bitstream（Vivado 不在 PATH 上，路徑是 `D:\Vivado\2026.1\Vivado\bin\vivado.bat`；也可以直接在 GUI 打開 `VGA_Screen.xpr` 按 Generate Bitstream）：

```bash
vivado -mode batch -source tools/build.tcl -tclargs bit
```

6. 燒錄前 SW8 要全部撥 ON 再重新上電，不然 Vivado 會找不到裝置。

腳位還沒填的時候 `write_bitstream` 會因為 UCIO-1（有 port 沒指定腳位）失敗，這是正常的；不加 `-tclargs bit` 時只會跑到 route，可以用來檢查時序。

---

## 4. 上板測試

### 4.1 第一次測試

| 開關 | 設定 |
|---|---|
| SW7 | 1（運作） |
| SW6 | 0（1 bit） |
| SW5 | 1（實心） |
| SW4..2 | 000（色塊） |
| SW1..0 | 00（640x480） |

應該要看到三個斜向交疊的色塊，交疊處是黃色和青色，LD0 和 LD1 會亮。確認後再依序試其他模式和解析度。

### 4.2 常見問題

| 現象 | 可能原因 |
|---|---|
| 螢幕顯示「無訊號」或「超出範圍」 | HS、VS 接錯或沒接，GND 沒接；可以從螢幕 OSD 看它認到的解析度 |
| 顏色對調（例如紅色變藍色） | R/G/B 的腳位接錯 |
| 太暗、太亮或偏色 | 電阻值跟 bank 電壓不符 |
| SW6 = 1（4 bit）時灰階只剩兩階 | 實際上只接了 MSB；把 SW6 撥成 0 改用抖動輸出 |
| 高解析度畫面糊或有雜訊 | 杜邦線太長，先用 640x480 確認 |
| LD0 不亮 | MMCM 沒鎖定，確認 100 MHz 時脈與 bitstream 有正確燒入 |

---

## 5. 設計說明

### 5.1 架構

```
vga_top -- clk_gen   (MMCM: 25 / 40 / 65 / 108.33 MHz, BUFGMUX_CTRL selects one by SW1..0)
        `- vga_core  (everything runs on the pixel clock)
             |- vga_timing   h/v counters, hs/vs, x/y, frame_tick
             |- btn_ctrl     buttons -> block/shape position and size, 3D angle and object
             |- cd_ctrl      CD position, bounce, color, spin
             |- hockey_ctrl  air hockey rules, CPU player, puck physics (2 x puck_hit)
             |- renderers    rgb_blocks / gray_bars / shape2d / image_rom / ball3d / tetra3d / cd_draw / hockey_draw
             `- mode mux -> output stage (4 bit as is, or 1 bit Bayer dithering)
```

- 所有繪圖器都補齊到同樣的管線延遲（`RENDER_LAT`），hs/vs 也延遲同樣的拍數，所以切換模式時不用重新對齊。
- 按鈕只在每個 frame 開頭取樣一次（約 16 ms），本身就能去彈跳，而且物件只在遮沒期間改變，畫面不會撕裂。
- 狀態類模組（`btn_ctrl`、`cd_ctrl`、`hockey_ctrl`）每個 CLK 都從目前狀態把「下一個 frame」算好暫存起來，`frame_tick` 時一次寫回；狀態一整個 frame 都不變，所以中間的運算可以拆成很多級，不必對齊延遲，108 MHz 也跑得動。
- 1 bit 模式每色輸出 0000 或 1111，所以只接 MSB 的轉接板和 4 bit 轉接板都能正確顯示。

### 5.2 解析度與時脈

| res_sel | 解析度 | 像素時脈 | 總長 (H x V) |
|---|---|---|---|
| 00 | 640x480@60 | 25.000 MHz | 800 x 525 |
| 01 | 800x600@60 | 40.000 MHz | 1056 x 628 |
| 10 | 1024x768@60 | 65.000 MHz | 1344 x 806 |
| 11 | 1280x1024@60 | 108.33 MHz（比 VESA 快 0.3%，在 ±0.5% 容許內） | 1688 x 1066 |

一顆 MMCM 的 VCO = 100 MHz / 4 x 39 = 975 MHz，同時除出 4 個頻率。

### 5.3 各模式的做法

- **色塊**（`rgb_blocks.vhd`）：比較座標是否在矩形內，三色用 OR 疊加。
- **灰階**（`gray_bars.vhd`）：用乘倒數取高位元代替除法，算出每個像素在第幾階。
- **2D 圖形**（`shape2d.vhd`）：判斷式全部化成乘法和比較，例如橢圓用 `dx²·b² + dy²·a² < a²·b²`；空心 = 外形減掉內縮 4 像素的內形。半軸上限 360，讓每個乘法剛好用一顆 DSP48。
- **RAM 圖片**（`image_rom.vhd`）：`embed0008_HD.jpg` 縮成 480x480、4 bit 灰階，每個 32 bit word 放 8 個像素，佔 32 個 RAMB36，畫面置中。
- **3D**（`ball3d.vhd`、`tetra3d.vhd`）：
  - 旋轉矩陣、投影係數這些每個 frame 才變一次、而且需要三角函數和除法的參數，用 `tools/gen_rom.py` 預先算好 256 個角度，存成 ROM。
  - 硬體每個像素做光柵化：球和橄欖球用橢球的光線投射（算輪廓、深度、物體座標後貼圖和打光），三角錐用邊函數加背面剔除（凸多面體不需要 z-buffer）。
  - 三個物體共用 mode 101，用 BTNL / BTNR 切換，空出 110 / 111 給 CD 彈跳和空氣曲棍球。
- **CD 彈跳**（`cd_ctrl.vhd`、`cd_draw.vhd`）：
  - 位置用 Q.4（1/16 像素）定點數，x、y 速度比是 11 : 8，軌跡才不會只在幾條 45 度斜線上來回。碰到邊就翻轉方向並換下一個顏色；x、y 在同一個 frame 反彈（剛好撞進角落）時背景會閃約 1 秒。
  - CD 由內到外是中心孔、透明塑膠轂、鏡面環、資料區、外緣，只要比較 `dx² + dy²` 落在哪一圈。
  - 彩虹反光的色相 = 2 × 角度 + spin。角度不算 atan：用 `(|dx| >> 1, |dy| >> 1)` 查 32x32 的 `ATAN_ROM` 得到象限內的角度，再依 dx、dy 正負補成一整圈。用 2 倍角是因為 CD 的繞射紋是兩個相對的扇形；spin 每 frame 加一點，看起來就是整片 CD 在轉。
- **空氣曲棍球**（`hockey_ctrl.vhd`、`puck_hit.vhd`、`hockey_draw.vhd`）：
  - 球的位置、速度用 Q.8 定點數。每個 frame：兩支球槌先移動 → 球位置 += 速度 → 依序和玩家、電腦的球槌做碰撞 → 牆壁反彈（保留 7/8 速度）→ 摩擦（|v| 減 |v|/256 + 1，只按比例減的話慢速時會因為截斷永遠停不下來）。
  - 碰撞（`puck_hit`）：中心距小於 32（球半徑 12 + 球槌半徑 20）才算碰到。法向量 `n = (dx, dy) / d` 不開根號也不做除法：碰到時 |dx|、|dy| 一定小於 32，直接查 32x32 的 `NORM_X` / `NORM_Y` 表。相對速度在法向量上的分量 `dot < 0`（正在靠近）時 `v -= 1.75·dot·n`（球槌當成無限重，揮動的球槌能把球打得比自己快），並把球放回球槌邊緣，避免慢速時黏住。最後每軸限速 12 像素 / frame，保證不會一步穿過球槌。
  - 球門開口 160 像素；球心在 H/2 ± 68 內（整顆球塞得進去）才進得去，進了開口之後上下由門柱擋住，球心出了畫面才算進球。
  - 電腦：球在右半場、在電腦球槌左邊、而且沒有正快速飛向球門時就衝過去打；球跑到球槌和球門之間時從上或下繞過去；其他時候回到球門前，球在右半場時 y 跟著球，在左半場時守中間。
  - 比分用七段顯示器的樣子畫：判斷像素在數字框裡 a ~ g 的哪一段，再和該數字的段表做 AND。

---

## 6. 模擬與工具

需要 Python 3（加上 Pillow）和 Vivado 2026.1。指令都在專案根目錄執行。

| 指令 | 用途 |
|---|---|
| `python tools/sim.py timing` | 跑時序 testbench（自我檢查 4 種解析度） |
| `python tools/sim.py game [GENERIC=value ...]` | 跑 CD 與曲棍球的狀態 testbench（自我檢查），並畫出 `sim_out/cd_motion.gif`、`sim_out/hockey_play.gif` |
| `python tools/sim.py presets [名稱 ...]` | 跑預設的畫面擷取，輸出到 `sim_out/<名稱>.png` |
| `python tools/sim.py frame <名稱> RES=0 MODE=6 ...` | 自訂開關與按鈕擷取一張畫面 |
| `python tools/sim.py sheet <名稱> ...` | 把多張擷取畫面拼成 `sim_out/sheet.png` |
| `python tools/model3d.py 0 40` | 用 Python 模型畫出 3D 物體（跟硬體逐位元相同，用來對照） |
| `python tools/gen_rom.py all` | 重新產生 `image_rom_pkg.vhd`、`rot3d_rom_pkg.vhd` 與 `game_rom_pkg.vhd` |
| `vivado -mode batch -source tools/create_project.tcl` | 重建 `VGA_Screen.xpr` |
| `vivado -mode batch -source tools/build.tcl [-tclargs bit]` | 合成 + 實作（加 `bit` 產生 bitstream），報告輸出到 `sim_out/` |

`vga_frame_tb` 的 generic：`RES`、`MODE`、`VARIANT`、`DEPTH` 對應開關；`C_PRESSES` = 先按幾次 BTNC；`BTN` = 按住的按鈕遮罩（C=1、U=2、D=4、L=8、R=16）；`HOLD` = 按住幾個 frame；`SKIP` = 放開後再等幾個 frame 才擷取。

加入 3D 模組後模擬變慢，一張 640x480 畫面約 1 到 2 分鐘。同時要跑兩組模擬時，可以設環境變數 `SIM_OUT` 指定不同的輸出子資料夾。

CD 和曲棍球要看的是幾千個 frame 的動態，整張畫面模擬太慢，所以另外有 `game_tb`：直接例化 `cd_ctrl` 與 `hockey_ctrl`，每 64 個 CLK 給一次假的 `frame_tick`（大於曲棍球約 30 拍的管線深度），玩家球槌由 testbench 裡的簡單機器人操作。它會檢查 CD 不出畫面、球只會從球門開口離開場地、球槌不越過自己的半場、暫停時不動、有擊球和進球、比賽結束後按 BTNC 比分歸零，並在第 `SWITCH_AT` 個 frame 換成 1024x768 再檢查一次。generic：`FRAMES`（預設 9000）、`SWITCH_AT`（8000）、`HARD`（0；困難模式一局要 2 萬個 frame 左右，例如 `python tools/sim.py game HARD=1 FRAMES=30000 SWITCH_AT=25000`）。

### 驗證結果（2026-10-22）

- 時序 testbench：4 種解析度的 H/V 總長、sync 寬度、極性、可視區域全部通過。
- 每個模式都擷取畫面檢查過；3 個 3D 物體的 HDL 畫面跟 Python 模型逐像素比對，0 個像素不同。
- Vivado 實作：4 個像素時脈都符合時序（最緊的是 108 MHz，WNS +0.63 ns）；用量 LUT 11.5%、Block RAM 36.5 / 140、DSP 58 / 220。

### 驗證結果（2026-10-31，加入 CD 彈跳與空氣曲棍球後）

- `game_tb`（預設，簡單難度 9000 frame）：通過。CD 反彈 125 次；曲棍球擊球 168 次、進球 11 次，打完一局（7 : 1）後按 BTNC 重開，暫停 / 繼續與換解析度都檢查過。
- `game_tb HARD=1 FRAMES=30000`：通過，一局打了約 2 萬個 frame，7 : 3。
- Vivado 實作：4 個像素時脈都符合時序，但 108 MHz 的 WNS 只剩 +0.062 ns（最長路徑在 `hockey_ctrl` 的電腦 AI：邊界 → 出擊判斷 → 速度選擇 → 移動）；用量 LUT 16.8%、Block RAM 36.5 / 140（新的查表都放進 LUT）、DSP 82 / 220；bitstream 產生成功。
