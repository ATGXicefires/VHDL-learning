## 螢幕乒乓 pong_top - E-Elements EGO-XZ7 (xc7z020clg484-1)
## 開關/按鈕/LED 腳位和 ../VGA_Screen/vga_screen.xdc 相同 (取自 EGO-XZ7/1.1/part0_pins.xml)
## HDMI 腳位直接引用 ../VGA_Screen/hdmi/hdmi_adv7511.xdc (已上板驗證)
## 注意: 開關與按鈕所在 bank 為 LVCMOS25, LED 與時脈為 LVCMOS33

## 100 MHz 系統時脈
set_property -dict {PACKAGE_PIN Y9  IOSTANDARD LVCMOS33} [get_ports CLK]
create_clock -period 10.000 -name sys_clk [get_ports CLK]

## SW7 = RST (撥上 = 運作, 撥下 = 重置)
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS25} [get_ports RST]

## SW0 = 3D, SW1 = 雙人, SW2 = 電腦困難
set_property -dict {PACKAGE_PIN F22 IOSTANDARD LVCMOS25} [get_ports sw_3d]
set_property -dict {PACKAGE_PIN G22 IOSTANDARD LVCMOS25} [get_ports sw_2p]
set_property -dict {PACKAGE_PIN H22 IOSTANDARD LVCMOS25} [get_ports sw_hard]

## 按鈕 (按下 = 1)
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS25} [get_ports btn_c]
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS25} [get_ports btn_u]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS25} [get_ports btn_d]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS25} [get_ports btn_l]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS25} [get_ports btn_r]

## LD7..LD0 = 狀態
set_property -dict {PACKAGE_PIN T22 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN T21 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN U21 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN V22 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN W22 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {led[7]}]

## 開關/按鈕是非同步輸入, 在 pong_core 裡用 2 級 FF 同步; LED 只是給人看的
set_false_path -from [get_ports {RST sw_* btn_*}]
set_false_path -to [get_ports {led[*]}]
