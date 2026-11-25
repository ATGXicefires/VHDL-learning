# 用法 (在專案根目錄): vivado -mode batch -source tools/build.tcl
# 合成、實作、產生 bitstream (Pong_HDMI.runs/impl_1/pong_top.bit); 先用 tools/create_project.tcl 建立專案
# 報告輸出到 sim_out/

set root [file normalize [file join [file dirname [info script]] ..]]

open_project $root/Pong_HDMI.xpr
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "synth_1 failed"
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "impl_1 failed"
}

file mkdir $root/sim_out
open_run impl_1
report_timing_summary -max_paths 5 -file $root/sim_out/timing.rpt
report_utilization -file $root/sim_out/utilization.rpt
