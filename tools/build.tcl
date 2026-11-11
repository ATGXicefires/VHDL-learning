# 用法 (在專案根目錄): vivado -mode batch -source tools/build.tcl
# 跑 synth -> impl -> bitstream, 報告輸出到 sim_out/
# bitstream 在 LED_PingPong.runs/impl_1/led_pingpong.bit

set root [file normalize [file join [file dirname [info script]] ..]]
set rpt $root/sim_out

open_project $root/LED_PingPong.xpr
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

file mkdir $rpt
open_run impl_1
report_timing_summary -max_paths 5 -file $rpt/timing.rpt
report_utilization -file $rpt/utilization.rpt
