## HW3 VGA 掃描 - 4 bit 版才需要的 R/G/B 低 3 位元
## OUT_BITS = 1 時這些 port 不存在, 要在 Vivado 把這個檔案 disable (右鍵 Disable File)
##
## 4 bit 電阻 DAC: 同色 4 支腳各串 1 顆電阻後並接到 DB15 同一支腳, 電阻值依權重加倍
##   3.3 V bank: bit3 = 510 Ω, bit2 = 1 kΩ, bit1 = 2 kΩ, bit0 = 3.9 kΩ (滿刻度約 0.72 V)
##   2.5 V bank: bit3 = 360 Ω, bit2 = 750 Ω, bit1 = 1.5 kΩ, bit0 = 3 kΩ (滿刻度約 0.69 V)
## TODO: 依 EGO-XZ7 電路圖填入 PACKAGE_PIN, IOSTANDARD 要改成該 bank 的電壓

set_property IOSTANDARD LVCMOS33 [get_ports {vga_r[0] vga_r[1] vga_r[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_g[0] vga_g[1] vga_g[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_b[0] vga_b[1] vga_b[2]}]
#set_property PACKAGE_PIN TODO [get_ports {vga_r[2]}]
#set_property PACKAGE_PIN TODO [get_ports {vga_r[1]}]
#set_property PACKAGE_PIN TODO [get_ports {vga_r[0]}]
#set_property PACKAGE_PIN TODO [get_ports {vga_g[2]}]
#set_property PACKAGE_PIN TODO [get_ports {vga_g[1]}]
#set_property PACKAGE_PIN TODO [get_ports {vga_g[0]}]
#set_property PACKAGE_PIN TODO [get_ports {vga_b[2]}]
#set_property PACKAGE_PIN TODO [get_ports {vga_b[1]}]
#set_property PACKAGE_PIN TODO [get_ports {vga_b[0]}]
