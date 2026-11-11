# LED 來回擊球 (LED_PingPong)

在 EGO-XZ7 (xc7z020clg484-1) 上用板載 8 顆 LED 做的雙人對打小遊戲。LED 是直排，LD7 在最上面，上方玩家守 LD7，下方玩家守 LD0。

## 操作

| 板上元件 | 功能 |
|---|---|
| SW7 | 撥上 = 運作，撥下 = 重置 |
| BTNC | 發球；遊戲結束後按一下開新局 |
| BTNU | 上方玩家擊球（守 LD7） |
| BTND | 下方玩家擊球（守 LD0） |

## 玩法

1. **發球**：球停在發球方那一端閃爍，按 BTNC 發球。開機由下方先發，之後由得分方發球，開新局時由上一局的贏家先發。
2. **擊球**：球走到自己那一端（LD7 或 LD0）時，按自己的鍵把球打回去。每打回一次，球速加快 1/8。初速是一格 0.25 秒，最快一格 1/12 秒。
3. **失分**：以下兩種情況會失分，對方得 1 分：
   - **太早按**：球朝自己飛來、但還沒到端點就按下。
   - **漏接**：球已經到端點，但在下一格時間到之前沒按。

   球飛離自己時按鍵沒有作用，亂按不會失分。
4. **比分**：每得一分會顯示比分約 1 秒。上半 4 顆是上方玩家的分數，從 LD7 往下亮；下半 4 顆是下方玩家的分數，從 LD0 往上亮。顯示完由得分方發下一球，球速回到初速。
5. **結束**：先得 4 分的人獲勝，贏家那半邊會閃爍。按 BTNC 清除比分並開新局。

## 檔案

| 檔案 | 內容 |
|---|---|
| `led_pingpong.vhd` | 遊戲本體，單一 entity；generic `CLK_FREQ` 預設 100 MHz |
| `led_pingpong.xdc` | 腳位約束 |
| `led_pingpong_tb.vhd` | 自我檢查 testbench，打完一整局 |
| `tools/sim.py` | 批次執行 xsim，通過時印出 `led_pingpong_tb PASS` |
| `tools/create_project.tcl` | 重建 `LED_PingPong.xpr` |
| `tools/build.tcl` | 合成、實作、產生 bitstream，報告輸出到 `sim_out/` |

## 模擬、建置與燒錄

以下指令都在專案根目錄執行。

```
python tools/sim.py
vivado -mode batch -source tools/create_project.tcl
vivado -mode batch -source tools/build.tcl
```

產生的 bitstream 位於 `LED_PingPong.runs/impl_1/led_pingpong.bit`。燒錄步驟：

1. 把 SW8 全部撥到 ON 並重新上電，否則 JTAG 偵測不到 FPGA。
2. 執行 `vivado -mode batch -source tools/program.tcl`，或在 Vivado Hardware Manager 手動燒錄上述 `.bit`。
3. 把 SW7 撥上，開始遊戲。

注意：按下 S12 會清掉 PL 的設定，重新燒錄即可恢復。

## 調整手感

球速相關的常數都在 `led_pingpong.vhd` 開頭：

| 常數 | 意義 |
|---|---|
| `STEP_INIT` | 初速，一格的時間 |
| `STEP_MIN` | 最快速度，一格的時間 |
| `SHOW_MAX` | 比分顯示時間 |
| `WIN_SCORE` | 獲勝分數，最大為 4，因為半邊只有 4 顆 LED |
