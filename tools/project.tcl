#==============================================================================
# project.tcl - build a real Vivado project you can open and look at.
#
# The batch flow in build.tcl is what produces bitstreams: reproducible from
# this tree, nothing hidden in a .xpr. That is the right thing for building and
# the wrong thing for LOOKING, because there is no schematic to open, no device
# view, no hierarchy you can click into.
#
# So this makes a project alongside it, from the same sources. It is disposable:
# delete build/proj and run this again. Nothing depends on it, and the bitstream
# that goes on the board still comes from build.tcl.
#
#   vivado -mode batch -source tools/project.tcl -tclargs -top eth_top -run 1
#
#   -top   <name>   top module        (default: eth_top)
#   -xdc   <file>   constraints       (default: boards/qmtech_a100t/eth_top.xdc)
#   -out   <dir>    project directory (default: build/proj)
#   -run   1        synthesise and implement before exiting
#==============================================================================

set root [file normalize [file dirname [info script]]/..]

set top  eth_top
set xdc  $root/boards/qmtech_a100t/eth_top.xdc
set out  $root/build/proj
set part xc7a100tfgg676-1
set do_run 0

for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        -top  { incr i; set top  [lindex $argv $i] }
        -xdc  { incr i; set xdc  [file normalize [lindex $argv $i]] }
        -out  { incr i; set out  [file normalize [lindex $argv $i]] }
        -part { incr i; set part [lindex $argv $i] }
        -run  { incr i; set do_run [lindex $argv $i] }
        default { puts " ignoring unknown arg: [lindex $argv $i]" }
    }
}

# Start clean. A half-migrated project is worse than no project.
if {[file exists $out]} { file delete -force $out }
file mkdir $out

create_project console $out -part $part -force
set_property target_language Verilog [current_project]

# --- sources ------------------------------------------------------------------
# Added by reference, not copied, so editing rtl/*.v outside Vivado is picked up
# the next time the project is opened. A project that keeps its own copies would
# quietly diverge from the tree that builds the board.
set rtl [lsort [glob -nocomplain $root/rtl/*.v $root/rtl/*.sv]]
add_files -norecurse -fileset sources_1 $rtl
add_files -norecurse -fileset constrs_1 $xdc
set_property top $top [get_filesets sources_1]

# The .vh files are `include`d rather than compiled, so synthesis finds them
# next to the file that includes them whether or not they are in the project.
# They go in anyway: 649 lines of Z80 instruction decode that is invisible in
# the source tree otherwise, which makes the GUI lie about what the design is.
set hdrs [lsort [glob -nocomplain $root/rtl/*.vh]]
if {[llength $hdrs] > 0} {
    add_files -norecurse -fileset sources_1 $hdrs
    set_property file_type {Verilog Header} [get_files $hdrs]
}

# Testbenches, so the module list in the GUI is the whole project and not half
# of it. Note the caveat printed at the end about running them from here.
set tbs [lsort [glob -nocomplain $root/sim/*.v]]
if {[llength $tbs] > 0} {
    add_files -norecurse -fileset sim_1 $tbs
    set_property top tb_console [get_filesets sim_1]
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Leave the run strategies at whatever this Vivado calls its defaults -- naming
# them explicitly breaks whenever the version changes, and the defaults are what
# build.tcl uses anyway, so the numbers in the GUI match the board.
set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]

puts ""
puts "=============================================================="
puts " project : $out/console.xpr"
puts " top     : $top"
puts " sources : [llength $rtl] RTL + [llength $hdrs] headers, [llength $tbs] testbenches"
puts "=============================================================="

if {$do_run} {
    puts " running synthesis and implementation..."
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        puts " *** synthesis failed"
        exit 1
    }
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
        puts " *** implementation failed"
        exit 1
    }
    open_run impl_1
    puts ""
    report_utilization -hierarchical -hierarchical_depth 2
    puts ""
    puts " WNS: [get_property SLACK [get_timing_paths -delay_type max]]"
}

puts ""
puts " open it with:  tools/vivado.sh gui build/proj/console.xpr"
puts ""
puts " NOTE: testbenches run from here will not find sim/roms/*.hex -- their"
puts "       \$readmemh paths are relative to build/sim, where tools/sim.sh puts"
puts "       them. Use tools/sim.sh for running simulations; the sim sources are"
puts "       in the project so you can read and edit them, not so you can launch"
puts "       them from a different directory."
puts ""
