## HW3 VGA 掃描 vga_top - E-Elements EGO-XZ7 (xc7z020clg484-1)
## 開關/按鈕/LED 腳位取自 EGO-XZ7/1.1/part0_pins.xml
## 注意: 開關與按鈕所在 bank 為 LVCMOS25, LED 與時脈為 LVCMOS33

## 100 MHz 系統時脈
set_property -dict {PACKAGE_PIN Y9  IOSTANDARD LVCMOS33} [get_ports CLK]
create_clock -period 10.000 -name sys_clk [get_ports CLK]

## SW7 = RST (撥上 = 運作, 撥下 = 重置)
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS25} [get_ports RST]

## SW6 = depth, SW5 = variant
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS25} [get_ports depth]
set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS25} [get_ports variant]

## SW4..SW2 = mode
set_property -dict {PACKAGE_PIN H22 IOSTANDARD LVCMOS25} [get_ports {mode[0]}]
set_property -dict {PACKAGE_PIN F21 IOSTANDARD LVCMOS25} [get_ports {mode[1]}]
set_property -dict {PACKAGE_PIN H19 IOSTANDARD LVCMOS25} [get_ports {mode[2]}]

## SW1..SW0 = res_sel
set_property -dict {PACKAGE_PIN F22 IOSTANDARD LVCMOS25} [get_ports {res_sel[0]}]
set_property -dict {PACKAGE_PIN G22 IOSTANDARD LVCMOS25} [get_ports {res_sel[1]}]

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

## 開關/按鈕是非同步輸入, 在 vga_core 裡用 2 級 FF 同步, 不需要做時序分析
set_false_path -from [get_ports {RST depth variant mode[*] res_sel[*] btn_*}]

## MMCM 的 4 個像素時脈經 BUFGMUX 只會有 1 個在用, 彼此之間的路徑不用分析
set_clock_groups -logically_exclusive \
    -group [get_clocks -of_objects [get_pins clocks/mmcm/CLKOUT0]] \
    -group [get_clocks -of_objects [get_pins clocks/mmcm/CLKOUT1]] \
    -group [get_clocks -of_objects [get_pins clocks/mmcm/CLKOUT2]] \
    -group [get_clocks -of_objects [get_pins clocks/mmcm/CLKOUT3]]

## ---------------------------------------------------------------------------
## VGA 輸出 (MSB 與 sync, 1 bit 和 4 bit 都要接)
## EGO-XZ7 沒有 VGA 接頭, 要自製轉接: DB15 母座 1 = R, 2 = G, 3 = B, 13 = HS, 14 = VS,
##   5/6/7/8/10 = GND (要和板子 GND 接在一起)
## 螢幕端 R/G/B 各有 75 Ω 終端, 滿刻度 0.7 V, 所以 FPGA 腳要串電阻分壓:
##   1 bit: 每色 MSB 腳串 1 顆, 3.3 V bank 用 270 Ω (約 0.72 V), 2.5 V bank 用 180 Ω
##   4 bit: 見 vga_lsb.xdc
##   HS/VS 是 TTL 準位, 串 100 Ω 限流後直接接
## EGO-XZ7 的 GPIO 排針只有 7 支 PL 腳, 只夠 1 bit (5 支); 4 bit 共要 14 支, 需用樹莓派排針或 FMC
## TODO: 依 EGO-XZ7 電路圖填入 PACKAGE_PIN, IOSTANDARD 要改成該 bank 的電壓
##       (腳位未填前 write_bitstream 會因 UCIO-1 失敗, synth/impl 仍可跑)
## ---------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS33 [get_ports {vga_r[3] vga_g[3] vga_b[3] vga_hs vga_vs}]
#set_property PACKAGE_PIN TODO [get_ports {vga_r[3]}]
#set_property PACKAGE_PIN TODO [get_ports {vga_g[3]}]
#set_property PACKAGE_PIN TODO [get_ports {vga_b[3]}]
#set_property PACKAGE_PIN TODO [get_ports vga_hs]
#set_property PACKAGE_PIN TODO [get_ports vga_vs]
