# jtagaxi.tcl - generate the JTAG-to-AXI master (Xilinx jtag_axi) the debug builds put on the
# register bus: the PC reads and writes the console's registers, frames and memory over the
# JTAG cable (tools/jtag.py), not over the ESP32.
#
#   ./tools/vivado.sh -mode batch -source tools/jtagaxi.tcl    (once; core.sh JTAG=1 uses the .xci)
#
# AXI4 (bursts of up to 256 words), 32-bit address and data, one outstanding transaction each way.

set root [file normalize [file dirname [info script]]/..]
set part xc7a100tfgg676-1
set out  $root/build/jtagaxi_gen

file delete -force $out
file mkdir $out
create_project jtagaxi_gen $out -part $part -force
set_property target_language Verilog [current_project]

create_ip -name jtag_axi -vendor xilinx.com -library ip -module_name jtag_axi_0
set_property -dict [list CONFIG.PROTOCOL {0} CONFIG.M_AXI_DATA_WIDTH {32} CONFIG.M_AXI_ADDR_WIDTH {32} \
                         CONFIG.RD_TXN_QUEUE_LENGTH {1} CONFIG.WR_TXN_QUEUE_LENGTH {1}] [get_ips jtag_axi_0]
set xci [get_property IP_FILE [get_ips jtag_axi_0]]
if {[get_property IS_LOCKED [get_ips jtag_axi_0]]} { puts " *** jtag_axi_0 is LOCKED"; exit 1 }
generate_target all [get_ips jtag_axi_0]
puts " xci  : $xci"
puts " jtag_axi generated"
