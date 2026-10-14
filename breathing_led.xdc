## HW2 呼吸燈 breathing_led - E-Elements EGO-XZ7 (xc7z020clg484-1)
## 腳位取自 EGO-XZ7/1.1/part0_pins.xml
## 注意: 開關所在 bank 為 LVCMOS25, LED 與時脈為 LVCMOS33

## 100 MHz 系統時脈
set_property -dict {PACKAGE_PIN Y9  IOSTANDARD LVCMOS33} [get_ports CLK]
create_clock -period 10.000 -name sys_clk [get_ports CLK]

## SW7 = RST (撥上 = 運作, 撥下 = 重置)
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS25} [get_ports RST]

## SW1..SW0 = freq_sel (呼吸週期: 00 = 1 s, 01 = 2 s, 10 = 3 s, 11 = 4 s)
set_property -dict {PACKAGE_PIN F22 IOSTANDARD LVCMOS25} [get_ports {freq_sel[0]}]
set_property -dict {PACKAGE_PIN G22 IOSTANDARD LVCMOS25} [get_ports {freq_sel[1]}]

## SW4..SW2 = res_sel (明暗解析度: 000 = 256 階 ... 111 = 2 階)
set_property -dict {PACKAGE_PIN H22 IOSTANDARD LVCMOS25} [get_ports {res_sel[0]}]
set_property -dict {PACKAGE_PIN F21 IOSTANDARD LVCMOS25} [get_ports {res_sel[1]}]
set_property -dict {PACKAGE_PIN H19 IOSTANDARD LVCMOS25} [get_ports {res_sel[2]}]

## LD0 = 呼吸燈
set_property -dict {PACKAGE_PIN T22 IOSTANDARD LVCMOS33} [get_ports led]
