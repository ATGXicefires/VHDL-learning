# 用法 (在專案根目錄): vivado -mode batch -source tools/create_project.tcl
# 會重建 VGA_Screen.xpr, 原始碼留在根目錄不搬動 (和 Breathing_LED 相同的配置)

set root [file normalize [file join [file dirname [info script]] ..]]

create_project VGA_Screen $root -part xc7z020clg484-1 -force
set_property board_part e-elements:ego-xz7:part0:1.1 [current_project]
set_property target_language VHDL [current_project]

set tb_files  [glob -directory $root *_tb.vhd]
set src_files {}
foreach f [glob -directory $root *.vhd] {
    if {[lsearch -exact $tb_files $f] < 0} {
        lappend src_files $f
    }
}

add_files -norecurse $src_files
add_files -fileset constrs_1 -norecurse [glob -directory $root *.xdc]
set_property top vga_top [current_fileset]

add_files -fileset sim_1 -norecurse $tb_files
set_property top vga_frame_tb [get_filesets sim_1]

update_compile_order -fileset sources_1
