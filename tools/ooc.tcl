#==============================================================================
# ooc.tcl - one module synthesised out of context: its size, by sub-module, and
# its timing at 50 MHz. Minutes, where a board build is most of an hour.
#
#   vivado -mode batch -source tools/ooc.tcl -nojournal -nolog -tclargs -top n64_rdp2 [-depth 3]
#
# Reads every rtl/*.v (the top pulls in what it uses). Writes build/ooc/<top>_util.rpt
# (hierarchical utilisation) and build/ooc/<top>_timing.rpt, and prints the totals.
# Check "Infeasible ram_style" and memories that came out as flip-flops in the log
# before trusting a board build with a new memory in it.
#==============================================================================

set top n64_top
set depth 3
set part xc7a100tfgg676-1
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    if {$a eq "-top"}   { incr i; set top   [lindex $argv $i] }
    if {$a eq "-depth"} { incr i; set depth [lindex $argv $i] }
    if {$a eq "-part"}  { incr i; set part  [lindex $argv $i] }
}
set out build/ooc
file mkdir $out

read_verilog [glob rtl/*.v]
synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name clk -period 20.0 [get_ports clk]
report_utilization -hierarchical -hierarchical_depth $depth -file $out/${top}_util.rpt
report_timing_summary -max_paths 5 -file $out/${top}_timing.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts ""
puts [format " %s: worst setup slack %.3f ns at 50 MHz (out of context, before placement)" $top $wns]
puts " reports: $out/${top}_util.rpt, $out/${top}_timing.rpt"
