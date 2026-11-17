## HW3 VGA 掃描 - 4 bit 版才需要的 R/G/B 低 3 位元
## OUT_BITS = 1 時這些 port 不存在, 要在 Vivado 把這個檔案 disable (右鍵 Disable File)
##
## 4 bit 電阻 DAC: 同色 4 支腳各串 1 顆電阻後並接到 DB15 同一支腳, 電阻值依權重加倍
##   3.3 V bank: bit3 = 510 Ω, bit2 = 1 kΩ, bit1 = 2 kΩ, bit0 = 3.9 kΩ (滿刻度約 0.72 V)
##   2.5 V bank: bit3 = 360 Ω, bit2 = 750 Ω, bit1 = 1.5 kΩ, bit0 = 3 kΩ (滿刻度約 0.69 V)
## JA2 的 PL 腳全在 bank 13 (3.3 V), 用 3.3 V 那組電阻; 腳位是用 ../Pin_Finder 實測的
##   JA2 腳號: vga_r[2..0] = 12 / 13 / 15, vga_g[2..0] = 18 / 19 / 21, vga_b[2..0] = 24 / 26 / 27

set_property IOSTANDARD LVCMOS33 [get_ports {vga_r[0] vga_r[1] vga_r[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_g[0] vga_g[1] vga_g[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_b[0] vga_b[1] vga_b[2]}]
set_property PACKAGE_PIN AA7  [get_ports {vga_r[2]}]
set_property PACKAGE_PIN AB9  [get_ports {vga_r[1]}]
set_property PACKAGE_PIN AA6  [get_ports {vga_r[0]}]
set_property PACKAGE_PIN AB1  [get_ports {vga_g[2]}]
set_property PACKAGE_PIN Y11  [get_ports {vga_g[1]}]
set_property PACKAGE_PIN Y10  [get_ports {vga_g[0]}]
set_property PACKAGE_PIN AB4  [get_ports {vga_b[2]}]
set_property PACKAGE_PIN AB7  [get_ports {vga_b[1]}]
set_property PACKAGE_PIN W7   [get_ports {vga_b[0]}]
