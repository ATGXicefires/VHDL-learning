# 用法 (在專案根目錄): vivado -mode batch -source tools/build.tcl [-tclargs [hdmi] [bit]]
# 預設只跑到 route_design: VGA 腳位還沒填時, write_bitstream 會因 UCIO-1 (未指定腳位) 失敗
# hdmi: 改建 HDMI 版 (hdmi/HDMI_Screen.xpr, 先用 tools/create_hdmi_project.tcl 建立)
# 報告輸出到 sim_out/ (HDMI 版是 sim_out/hdmi/)

set root [file normalize [file join [file dirname [info script]] ..]]
set to_step route_design
if {[lsearch -exact $argv bit] >= 0} {
    set to_step write_bitstream
}
set xpr $root/VGA_Screen.xpr
set rpt $root/sim_out
if {[lsearch -exact $argv hdmi] >= 0} {
    set xpr $root/hdmi/HDMI_Screen.xpr
    set rpt $root/sim_out/hdmi
}

open_project $xpr
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "synth_1 failed"
}

launch_runs impl_1 -to_step $to_step -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "impl_1 failed"
}

file mkdir $rpt
open_run impl_1
report_timing_summary -max_paths 5 -file $rpt/timing.rpt
report_utilization -file $rpt/utilization.rpt
report_clocks -file $rpt/clocks.rpt
