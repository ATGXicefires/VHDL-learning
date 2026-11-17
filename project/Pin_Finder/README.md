# 排針腳位探測（Pin Finder）

EGO-XZ7 廠商沒有公開手冊和電路圖（官網和 Web Archive 都只有 Vivado 板子設定檔），所以不知道排針上哪支腳接到哪個 PL package pin。這個 bitstream 用實測的方式查出來，查到之後就能填 HW3 的 [vga_screen.xdc](../VGA_Screen/vga_screen.xdc) 和 [vga_lsb.xdc](../VGA_Screen/vga_lsb.xdc)。

## 原理

- 板上還沒用到的 178 支 PL 腳全部設成「輸入 + 內部上拉」，**沒有任何一支設成輸出**，不管排針外面接了什麼都不會燒壞。
- 用電阻把排針上的一支腳拉到 GND，FPGA 看到哪支 probe 從 1 變 0，就把它的編號用二進位顯示在 LD7..LD0。
- 編號對應的 package pin 寫在 [pin_map.txt](pin_map.txt)。

## 要準備的東西

- 1 顆 1 kΩ 電阻（做 DAC 剩的就可以；2 kΩ、3.9 kΩ 也行）
- 1 條杜邦線
- 三用電表

1 kΩ 的用途是保護：就算碰到 5 V 腳或 PS 的輸出腳，電流也只有幾 mA。**不要用沒串電阻的線直接碰排針。**

## 步驟

1. SW8 全部撥 ON，重新上電，在 Vivado Hardware Manager 燒 `pin_finder.bit`。
2. SW7 撥上。燒完後前 10 ms 會自動校正，LD7..LD0 應該全暗。
3. 杜邦線一端接板子 GND（左下角的 TP7 GND 測試點，或用三用電表的導通檔找出排針上的 GND 腳），另一端接電阻。
4. 用電阻的另一腳**一次碰一支**排針腳，看 LED：
   - 有亮：板子右邊那排 LED 由上往下就是 LD7..LD0（最上面 LD7 是最高位元），亮 = 1，到 `pin_map.txt` 查 package pin。放開後 LED 會保持，碰下一支腳才更新。
   - 全暗或沒變：這支腳不是 PL 腳（PS 腳、電源、GND 或沒接）。
5. 同一支腳用三用電表量對 GND 的電壓（不要碰電阻）：PL 腳被內部上拉到 bank 電壓，量到約 3.3 V 或 2.5 V，這就是要選哪組 DAC 電阻的依據。
6. 每支腳記成一行：`排針名稱 腳號 → LED 值 → package pin → 電壓`。

如果 LED 一直亂跳，把 SW7 撥下約 1 秒再撥上重新校正（校正時不要碰排針）。校正時會自己跳動的腳會被永久遮掉；不小心在校正時碰到某支腳，要重新燒錄才會解除。

## 建議的探測順序

| 排針 | 位置 | 說明 |
|---|---|---|
| JA2「Pi-CON」 | 板子左邊，2x20 共 40 支 | 樹莓派相容排針，最有可能有 14 支以上 PL 腳 → 4 bit VGA 首選 |
| J11「GPIO」 | 右下，2x10 牛角座 | 官網規格是 7 PS + 7 PL，只夠 1 bit（5 支） |
| J6「XADC」 | 下方中間 | 主要是類比輸入，最後再看 |

## 重新產生

```bash
vivado -mode batch -source build.tcl
```

`build.tcl` 會重新產生 `pin_finder.xdc`、`pin_map.txt` 和 `pin_finder.bit`，報告在 `out/`。腳位清單由 Vivado 直接查出（bank 13/33/34/35 的 200 支一般 I/O 扣掉時脈、開關、按鈕、LED）。
