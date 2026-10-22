# HW3 VGA 掃描

目標板：E-Elements EGO-XZ7（xc7z020clg484-1，系統時脈 100 MHz，和 Breathing_LED 同一塊）

基本題：在 640x480 的螢幕上顯示 R、G、B 三個色塊，位置和大小可以任意調整，R/G/B 各 1 bit。
Bonus：其他解析度、R/G/B 灰階、色塊圖形（橢圓 / 圓 / 三角形，分空心與實心）、3D 旋轉物體、存在 RAM 裡的複雜圖案。

---

## 1. 操作方式

### 開關

| 開關 | 名稱 | 功能 |
|---|---|---|
| SW7 | RST | 撥上 = 運作，撥下 = 重置 |
| SW6 | depth | 0 = 每色 1 bit（8 色，灰階用 4x4 Bayer 抖動），1 = 每色 4 bit（4096 色） |
| SW5 | variant | 0 = 空心（3D 時是線框），1 = 實心（3D 時是貼圖加明暗）；模式 001 時 0 = 灰階色條，1 = RAM 圖片 |
| SW4..2 | mode | 見下表 |
| SW1..0 | res_sel | 00 = 640x480，01 = 800x600，10 = 1024x768，11 = 1280x1024（都是 60 Hz） |

| mode (SW4..2) | 畫面 |
|---|---|
| 000 | R/G/B 三個色塊（基本題），重疊處會加色混出黃、青、洋紅、白 |
| 001 | 灰階：8 色純色條 + R/G/B/白各 16 階漸層；SW5 = 1 時改成 RAM 圖片 |
| 010 | 橢圓 |
| 011 | 圓 |
| 100 | 三角形 |
| 101 | 3D 旋轉橄欖球 |
| 110 | 3D 旋轉球（海灘球） |
| 111 | 3D 旋轉三角錐（正四面體） |

### 按鈕

| 模式 | BTNC | BTNU / BTND / BTNL / BTNR |
|---|---|---|
| 色塊 | 依序切換：R 移動 → R 縮放 → G 移動 → G 縮放 → B 移動 → B 縮放 | 移動或縮放（按住會持續變化，每個 frame 2 像素） |
| 2D 圖形 | 切換 移動 / 縮放 | 移動；縮放時 L/R 調寬、U/D 調高，圓只有半徑 |
| 3D | 暫停 / 繼續 | U / D 加快 / 減慢旋轉 |

切換解析度時，2D 圖形會自動回到畫面中央，色塊會被推回畫面內。1024x768 以上的 3D 物體會放大 2 倍。

### LED

| LED | 意義 |
|---|---|
| LD0 | MMCM 已鎖定（像素時脈穩定） |
| LD1 / LD2 / LD3 | 色塊模式中正在編輯 R / G / B |
| LD4 | 縮放模式（色塊或 2D 圖形） |
| LD5 | 3D 旋轉已暫停 |

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
   - 那個 bank 的電壓（VCCO）：3.3 V 或 2.5 V
   - 不確定電壓的話，可以先填一支腳讓它輸出 1，再用三用電表量它對 GND 的電壓
3. **決定接 1 bit 還是 4 bit**：
   - **4 bit 轉接板可以同時做 1 bit 和 4 bit**，用 SW6 切換：SW6 = 0 時每色的 4 支腳一起輸出 0000 或 1111，就是 1 bit 的 8 色；SW6 = 1 才用到 16 階。腳位夠的話直接接 4 bit 就好，不用做兩塊。
   - 1 bit 轉接板（每色只接 MSB）只能做 1 bit；SW6 = 1 時灰階會只剩兩階。
   - 4 bit 需要 14 支腳（每色 4 支 + HS、VS），1 bit 只要 5 支（R、G、B、HS、VS）。
   - GPIO 排針只有 7 支 PL 腳，只夠 1 bit；4 bit 要用樹莓派排針（前提是它接到 PL）或 FMC。

### 2.3 接線圖

電阻單位都是 Ω，數值是 3.3 V bank 用的（2.5 V 見 2.4 的表）。

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

### 2.4 電阻值

| bank 電壓 | 1 bit（每色 1 顆） | 4 bit（bit3 / bit2 / bit1 / bit0） | HS、VS |
|---|---|---|---|
| 3.3 V | 270 Ω | 510 / 1k / 2k / 3.9k Ω | 100 Ω |
| 2.5 V | 180 Ω | 360 / 750 / 1.5k / 3k Ω | 100 Ω |

滿刻度都約 0.7 V。1/4 W 就夠，有 1% 金屬膜的更好。

### 2.5 材料清單

| 項目 | 數量 | 備註 |
|---|---|---|
| VGA 母座轉接板（DB15 母座拉出端子或排針） | 1 | 腳位編號印在板上，最不容易接錯；也可以剪舊 VGA 線來焊 |
| 電阻 | 1 bit：3 + 2 顆；4 bit：12 + 2 顆 | 值見 2.4 的表，「+ 2」是 HS、VS 的 100 Ω |
| 麵包板 | 1 | |
| 杜邦線 | 約 20 條 | 板子排針是公頭的話買母對公 |
| 有 VGA 輸入的螢幕 + VGA 線 | 1 | 只有 HDMI 的螢幕要買「主動式 VGA 轉 HDMI」轉換器，被動轉接頭不能用 |

### 2.6 注意事項

- 接線時板子要斷電。
- 板子 GND 一定要接到 DB15 的 GND（5、6、7、8、10 腳），少接這條通常就是「無訊號」。
- DB15 的第 9 腳（+5V）和 4、11、12、15 腳（螢幕 ID / DDC）**都不要接**。
- DB15 的腳位編號以轉接板上的標示為準：母座從正面看，第一排是 5 4 3 2 1（由左到右），跟公頭相反。
- 杜邦線盡量短。1280x1024 的像素時脈是 108 MHz，線太長畫面會糊；第一次先用 640x480 測。

---

## 3. 填腳位與產生 bitstream

1. 在 [vga_screen.xdc](vga_screen.xdc) 填 MSB 與同步訊號（`vga_r[3]`、`vga_g[3]`、`vga_b[3]`、`vga_hs`、`vga_vs`）的 `PACKAGE_PIN`，把 `TODO` 那幾行的 `#` 拿掉。
2. 4 bit 版另外在 [vga_lsb.xdc](vga_lsb.xdc) 填 `vga_r/g/b[2..0]`。
3. `IOSTANDARD` 要改成該 bank 的電壓：3.3 V 用 `LVCMOS33`，2.5 V 用 `LVCMOS25`。
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
             |- btn_ctrl     buttons -> block/shape position and size, 3D angle
             |- renderers    rgb_blocks / gray_bars / shape2d / image_rom / ball3d / tetra3d
             `- mode mux -> output stage (4 bit as is, or 1 bit Bayer dithering)
```

- 所有繪圖器都補齊到同樣的管線延遲（`RENDER_LAT`），hs/vs 也延遲同樣的拍數，所以切換模式時不用重新對齊。
- 按鈕只在每個 frame 開頭取樣一次（約 16 ms），本身就能去彈跳，而且物件只在遮沒期間改變，畫面不會撕裂。
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

---

## 6. 模擬與工具

需要 Python 3（加上 Pillow）和 Vivado 2026.1。指令都在專案根目錄執行。

| 指令 | 用途 |
|---|---|
| `python tools/sim.py timing` | 跑時序 testbench（自我檢查 4 種解析度） |
| `python tools/sim.py presets [名稱 ...]` | 跑預設的畫面擷取，輸出到 `sim_out/<名稱>.png` |
| `python tools/sim.py frame <名稱> RES=0 MODE=6 ...` | 自訂開關與按鈕擷取一張畫面 |
| `python tools/sim.py sheet <名稱> ...` | 把多張擷取畫面拼成 `sim_out/sheet.png` |
| `python tools/model3d.py 0 40` | 用 Python 模型畫出 3D 物體（跟硬體逐位元相同，用來對照） |
| `python tools/gen_rom.py all` | 重新產生 `image_rom_pkg.vhd` 與 `rot3d_rom_pkg.vhd` |
| `vivado -mode batch -source tools/create_project.tcl` | 重建 `VGA_Screen.xpr` |
| `vivado -mode batch -source tools/build.tcl [-tclargs bit]` | 合成 + 實作（加 `bit` 產生 bitstream），報告輸出到 `sim_out/` |

`vga_frame_tb` 的 generic：`RES`、`MODE`、`VARIANT`、`DEPTH` 對應開關；`C_PRESSES` = 先按幾次 BTNC；`BTN` = 按住的按鈕遮罩（C=1、U=2、D=4、L=8、R=16）；`HOLD` = 按住幾個 frame；`SKIP` = 放開後再等幾個 frame 才擷取。

加入 3D 模組後模擬變慢，一張 640x480 畫面約 1 到 2 分鐘。同時要跑兩組模擬時，可以設環境變數 `SIM_OUT` 指定不同的輸出子資料夾。

### 驗證結果（2026-10-22）

- 時序 testbench：4 種解析度的 H/V 總長、sync 寬度、極性、可視區域全部通過。
- 每個模式都擷取畫面檢查過；3 個 3D 物體的 HDL 畫面跟 Python 模型逐像素比對，0 個像素不同。
- Vivado 實作：4 個像素時脈都符合時序（最緊的是 108 MHz，WNS +0.63 ns）；用量 LUT 11.5%、Block RAM 36.5 / 140、DSP 58 / 220。
