#==============================================================================
# longpaths.tcl - from a routed checkpoint, every endpoint whose worst path in
# one clock is longer than a given delay: what has to be cut to run that clock
# faster. One line per endpoint (data path delay, logic levels, start, end) to
# build/longpaths.txt; tools/longpaths.py groups them by module.
#
#   vivado -mode batch -source tools/longpaths.tcl -nojournal -nolog -tclargs \
#       build/core_n64/post_route.dcp 12.0 cclk
#==============================================================================
set dcp   [lindex $argv 0]
set limit [lindex $argv 1]
set clk   [lindex $argv 2]
open_checkpoint $dcp
set per [get_property PERIOD [get_clocks $clk]]
set slack [expr {$per - $limit}]
puts "clock $clk, period $per: paths longer than $limit ns (slack under $slack)"
set paths [get_timing_paths -group $clk -max_paths 200000 -nworst 1 -slack_lesser_than $slack -unique_pins]
set f [open build/longpaths.txt w]
foreach p $paths {
    puts $f [format "%.3f %d %s %s" [get_property DATAPATH_DELAY $p] [get_property LOGIC_LEVELS $p] \
        [get_property PARENT_CELL [get_property STARTPOINT_PIN $p]] [get_property PARENT_CELL [get_property ENDPOINT_PIN $p]]]
}
close $f
puts "[llength $paths] endpoints"
