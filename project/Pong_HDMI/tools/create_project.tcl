# 用法 (在專案根目錄): vivado -mode batch -source tools/create_project.tcl
# 建立 Pong_HDMI.xpr (top = pong_top)
# 時序、HDMI、延遲線直接引用 ../VGA_Screen 已上板驗證的檔案, 不複製一份, 修正才不會分岔

set root [file normalize [file join [file dirname [info script]] ..]]
set vga  [file normalize $root/../VGA_Screen]

create_project Pong_HDMI $root -part xc7z020clg484-1 -force
set_property board_part e-elements:ego-xz7:part0:1.1 [current_project]
set_property target_language VHDL [current_project]

add_files -norecurse [list \
    $vga/vga_pkg.vhd \
    $vga/delay_line.vhd \
    $vga/vga_timing.vhd \
    $vga/hdmi/adv7511_pkg.vhd \
    $vga/hdmi/adv7511_cfg.vhd \
    $vga/hdmi/hdmi_422.vhd \
    $root/pong_pkg.vhd \
    $root/clk65.vhd \
    $root/pong2d_ctrl.vhd \
    $root/pong2d_draw.vhd \
    $root/pong3d_ctrl.vhd \
    $root/pong3d_draw.vhd \
    $root/pong_core.vhd \
    $root/pong_top.vhd]
add_files -fileset constrs_1 -norecurse [list $root/pong.xdc $vga/hdmi/hdmi_adv7511.xdc]
set_property top pong_top [current_fileset]

add_files -fileset sim_1 -norecurse [list $root/pong_frame_tb.vhd $root/pong_game_tb.vhd]
set_property top pong_game_tb [get_filesets sim_1]

update_compile_order -fileset sources_1
