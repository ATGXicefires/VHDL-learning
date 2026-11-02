# 用法 (在專案根目錄): vivado -mode batch -source tools/create_hdmi_project.tcl
# 建立 HDMI 版專案 hdmi/HDMI_Screen.xpr (top = hdmi_top), VGA 版的 VGA_Screen.xpr 不受影響
# RTL 與 xdc 直接引用根目錄的檔案, 兩個專案共用同一份 vga_core; 只有 vga_top.vhd 不加,
#   它是 VGA 版的 top, 留著 Vivado 會多一個沒用到的 top

set root [file normalize [file join [file dirname [info script]] ..]]
set hdmi $root/hdmi

create_project HDMI_Screen $hdmi -part xc7z020clg484-1 -force
set_property board_part e-elements:ego-xz7:part0:1.1 [current_project]
set_property target_language VHDL [current_project]

set src_files {}
set tb_files {}
foreach f [concat [glob -directory $root *.vhd] [glob -directory $hdmi *.vhd]] {
    if {[string match *_tb.vhd $f]} {
        lappend tb_files $f
    } elseif {[file tail $f] != "vga_top.vhd"} {
        lappend src_files $f
    }
}
add_files -norecurse $src_files
add_files -fileset constrs_1 -norecurse [concat [glob -directory $root *.xdc] [glob -directory $hdmi *.xdc]]
set_property top hdmi_top [current_fileset]

add_files -fileset sim_1 -norecurse $tb_files
set_property top hdmi_frame_tb [get_filesets sim_1]

update_compile_order -fileset sources_1
