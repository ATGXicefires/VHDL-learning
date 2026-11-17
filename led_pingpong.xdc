## LED 來回擊球 led_pingpong - E-Elements EGO-XZ7 (xc7z020clg484-1)
## 腳位取自 EGO-XZ7/1.1/part0_pins.xml, 按鍵方向對照 VGA_Screen/vga_screen.xdc
## 注意: 開關與按鍵所在 bank 為 LVCMOS25, LED 與時脈為 LVCMOS33

## 100 MHz 系統時脈
set_property -dict {PACKAGE_PIN Y9  IOSTANDARD LVCMOS33} [get_ports CLK]
create_clock -period 10.000 -name sys_clk [get_ports CLK]

## SW7 = RST (撥上 = 運作, 撥下 = 重置)
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS25} [get_ports RST]

## 按鈕 (按下 = 1): BTNU 上方玩家, BTND 下方玩家 (各自擊球 / 發球 / 開新局)
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS25} [get_ports btn_u]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS25} [get_ports btn_d]

## LD7 (最上) .. LD0 (最下) = 球 / 比分
set_property -dict {PACKAGE_PIN T22 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN T21 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN U21 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN V22 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN W22 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {led[7]}]

## 開關/按鈕是非同步輸入, 在 led_pingpong 裡用 2 級 FF 同步, 不需要做時序分析
set_false_path -from [get_ports {RST btn_*}]
