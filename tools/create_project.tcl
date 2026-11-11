# 用法 (在專案根目錄): vivado -mode batch -source tools/create_project.tcl
# 會重建 LED_PingPong.xpr, 原始碼留在根目錄不搬動 (和 Breathing_LED 相同的配置)

set root [file normalize [file join [file dirname [info script]] ..]]

create_project LED_PingPong $root -part xc7z020clg484-1 -force
set_property board_part e-elements:ego-xz7:part0:1.1 [current_project]
set_property target_language VHDL [current_project]

add_files -norecurse [list $root/led_pingpong.vhd]
add_files -fileset constrs_1 -norecurse [list $root/led_pingpong.xdc]
set_property top led_pingpong [current_fileset]

add_files -fileset sim_1 -norecurse [list $root/led_pingpong_tb.vhd]
set_property top led_pingpong_tb [get_filesets sim_1]

update_compile_order -fileset sources_1
