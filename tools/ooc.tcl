#==============================================================================
# ooc.tcl - one module synthesised out of context: its size, by sub-module, and
# its timing at 50 MHz. Minutes, where a board build is most of an hour.
#
#   vivado -mode batch -source tools/ooc.tcl -nojournal -nolog -tclargs -top n64_rdp2 [-depth 3]
#          [-period NS] [-impl]   (-impl: placed and routed; paths longer than the period
#                                  to build/ooc/<top>_long.txt, for tools/longpaths.py)
#
# Reads every rtl/*.v (the top pulls in what it uses). Writes build/ooc/<top>_util.rpt
# (hierarchical utilisation) and build/ooc/<top>_timing.rpt, and prints the totals.
# Check "Infeasible ram_style" and memories that came out as flip-flops in the log
# before trusting a board build with a new memory in it.
#==============================================================================

set top n64_top
set depth 3
set part xc7a100tfgg676-1
set period 20.0
set impl 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    if {$a eq "-top"}   { incr i; set top   [lindex $argv $i] }
    if {$a eq "-depth"} { incr i; set depth [lindex $argv $i] }
    if {$a eq "-part"}  { incr i; set part  [lindex $argv $i] }
    if {$a eq "-period"} { incr i; set period [lindex $argv $i] }
    if {$a eq "-impl"}   { set impl 1 }
}
set out build/ooc
file mkdir $out

read_verilog [glob rtl/*.v]
synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name clk -period $period [get_ports clk]
if {$impl} {
    # (placed and routed by itself: the module's own paths, without the rest of
    # the chip's congestion -- an optimistic bound, but a real one)
    # (opt_design fails on vr4300 with an empty Synth 20-411: placed without it then)
    if {[catch {opt_design} e]} { puts " opt_design failed: $e -- placing without it" }
    place_design
    phys_opt_design
    route_design
}
write_checkpoint -force $out/${top}.dcp
# every endpoint whose path is longer than the period, as tools/longpaths.tcl writes them
set f [open $out/${top}_long.txt w]
foreach p [get_timing_paths -max_paths 100000 -nworst 1 -slack_lesser_than 0 -unique_pins] {
    puts $f [format "%.3f %d %s %s" [get_property DATAPATH_DELAY $p] [get_property LOGIC_LEVELS $p]         [get_property PARENT_CELL [get_property STARTPOINT_PIN $p]] [get_property PARENT_CELL [get_property ENDPOINT_PIN $p]]]
}
close $f
report_utilization -hierarchical -hierarchical_depth $depth -file $out/${top}_util.rpt
report_timing_summary -max_paths 5 -file $out/${top}_timing.rpt
report_timing -max_paths 40 -nworst 1 -unique_pins -file $out/${top}_paths.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts ""
puts [format " %s: worst setup slack %.3f ns at a %.3f ns period (out of context, %s)" $top $wns $period [expr {$impl ? "routed" : "before placement"}]]
puts " reports: $out/${top}_util.rpt, $out/${top}_timing.rpt"
