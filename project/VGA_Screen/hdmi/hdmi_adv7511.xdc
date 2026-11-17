## HW3 HDMI 版 hdmi_top - 板上 J12 (HDMI OUT) 經 U12 ADV7511
## 其餘腳位 (時脈、開關、按鈕、LED、VGA) 沿用 ../vga_screen.xdc 與 ../vga_lsb.xdc
##
## 廠商沒有電路圖: U12 和 ZedBoard 一樣是 ADV7511, 板子的時脈、LED、開關、按鈕腳位也都和 ZedBoard 相同,
##   所以 HDMI 腳位照 ADI 的 ZedBoard 參考設計 (hdl/projects/common/zed/zed_system_constr.xdc)
## 這些腳全在 bank 33 (3.3 V), Pin_Finder/pin_map.txt 裡也都還沒被用到
## 2026-11-04 上板確認: LD6 亮 (ADV7511 回 ACK), 4 種解析度都有正確畫面, 接法確實和 ZedBoard 相同
## 換到接法不同的板子時 I2C 收不到 ACK: LD6 不亮, 影像腳一直保持高阻抗; 只要改這個檔

set_property -dict {PACKAGE_PIN W18  IOSTANDARD LVCMOS33} [get_ports hdmi_clk]
set_property -dict {PACKAGE_PIN W17  IOSTANDARD LVCMOS33} [get_ports hdmi_vs]
set_property -dict {PACKAGE_PIN V17  IOSTANDARD LVCMOS33} [get_ports hdmi_hs]
set_property -dict {PACKAGE_PIN U16  IOSTANDARD LVCMOS33} [get_ports hdmi_de]

set_property -dict {PACKAGE_PIN Y13  IOSTANDARD LVCMOS33} [get_ports {hdmi_d[0]}]
set_property -dict {PACKAGE_PIN AA13 IOSTANDARD LVCMOS33} [get_ports {hdmi_d[1]}]
set_property -dict {PACKAGE_PIN AA14 IOSTANDARD LVCMOS33} [get_ports {hdmi_d[2]}]
set_property -dict {PACKAGE_PIN Y14  IOSTANDARD LVCMOS33} [get_ports {hdmi_d[3]}]
set_property -dict {PACKAGE_PIN AB15 IOSTANDARD LVCMOS33} [get_ports {hdmi_d[4]}]
set_property -dict {PACKAGE_PIN AB16 IOSTANDARD LVCMOS33} [get_ports {hdmi_d[5]}]
set_property -dict {PACKAGE_PIN AA16 IOSTANDARD LVCMOS33} [get_ports {hdmi_d[6]}]
set_property -dict {PACKAGE_PIN AB17 IOSTANDARD LVCMOS33} [get_ports {hdmi_d[7]}]
set_property -dict {PACKAGE_PIN AA17 IOSTANDARD LVCMOS33} [get_ports {hdmi_d[8]}]
set_property -dict {PACKAGE_PIN Y15  IOSTANDARD LVCMOS33} [get_ports {hdmi_d[9]}]
set_property -dict {PACKAGE_PIN W13  IOSTANDARD LVCMOS33} [get_ports {hdmi_d[10]}]
set_property -dict {PACKAGE_PIN W15  IOSTANDARD LVCMOS33} [get_ports {hdmi_d[11]}]
set_property -dict {PACKAGE_PIN V15  IOSTANDARD LVCMOS33} [get_ports {hdmi_d[12]}]
set_property -dict {PACKAGE_PIN U17  IOSTANDARD LVCMOS33} [get_ports {hdmi_d[13]}]
set_property -dict {PACKAGE_PIN V14  IOSTANDARD LVCMOS33} [get_ports {hdmi_d[14]}]
set_property -dict {PACKAGE_PIN V13  IOSTANDARD LVCMOS33} [get_ports {hdmi_d[15]}]

## ADV7511 的 I2C (位址 0x72); 板上應該已有上拉, 內部上拉只是保險 (和 ADI 相同)
set_property -dict {PACKAGE_PIN AA18 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports hdmi_scl]
set_property -dict {PACKAGE_PIN Y16  IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports hdmi_sda]

## 資料的輸出 FF 放進 IOB, 和 ODDR 轉送的時脈一樣從 IOB 出去, 每支腳的延遲才固定一致
set_property IOB TRUE [get_ports {hdmi_d[*] hdmi_de hdmi_hs hdmi_vs}]

## I2C 最快 100 kHz, SDA 在 adv7511_cfg 裡用 2 級 FF 同步, 不需要做時序分析
set_false_path -to [get_ports {hdmi_scl hdmi_sda}]
set_false_path -from [get_ports hdmi_sda]
