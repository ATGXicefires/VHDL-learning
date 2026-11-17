# 用法 (在專案根目錄): vivado -mode batch -source tools/program.tcl
# 透過 JTAG 燒錄 led_pingpong.bit; 偵測不到 FPGA 時先確認 SW8 全 ON 並重新上電

set root [file normalize [file join [file dirname [info script]] ..]]
set bit $root/LED_PingPong.runs/impl_1/led_pingpong.bit

open_hw_manager
connect_hw_server -allow_non_jtag

# 板上的 USB-JTAG 會開出 A/B 兩個通道, 只有其中一個接到 FPGA, 所以逐一找有 xc7z020 的
set dev ""
foreach tgt [get_hw_targets] {
    current_hw_target $tgt
    open_hw_target
    set found [get_hw_devices -quiet xc7z020*]
    if {$found ne ""} {
        set dev [lindex $found 0]
        break
    }
    close_hw_target
}
if {$dev eq ""} {
    # 訊息用英文: vivado batch 的主控台會把中文印成亂碼
    error "xc7z020 not found: check the USB cable, set SW8 all ON and power-cycle"
}

current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "DONE = [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
