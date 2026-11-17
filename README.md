# VHDL-learning

FPGA / VHDL 課程的作業與專案。

目標板：E-Elements EGO-XZ7（Zynq-7000 `xc7z020clg484-1`，PL 系統時脈 100 MHz），開發工具 Vivado。

## HomeWork

| 資料夾 | 內容 |
|---|---|
| [HW1](HomeWork/HW1) | 作業一：兩個計數器交替計數（counter1 0→9 上數，counter2 253→17 下數），含 testbench 與模組化版本（`modular/`） |
| [HW1_FSM](HomeWork/HW1_FSM) | 作業一 FSM 版：由 FSM 控制兩個計數器輪流計數 |

## project

| 資料夾 | 內容 |
|---|---|
| [Breathing_LED](project/Breathing_LED) | HW2 呼吸燈（PWM），可用開關調呼吸頻率與明暗解析度 |
| [VGA_Screen](project/VGA_Screen) | HW3 VGA 掃描：色塊、灰階、2D/3D 圖形、圖片 ROM、彈跳 CD、空氣曲棍球，另有 HDMI（ADV7511）版本 |
| [LED_PingPong](project/LED_PingPong) | 用板上 8 顆 LED 做的雙人來回擊球小遊戲 |
| [Pin_Finder](project/Pin_Finder) | 實測排針腳位對應 PL package pin 的工具 bitstream（板子沒有公開電路圖） |

每個專案資料夾內都有 Vivado 專案檔（`.xpr`）、VHDL 原始碼、約束檔（`.xdc`）與 testbench；Vivado 產生的 build 目錄不放進庫裡，開專案後重新 synth / impl 即可。
