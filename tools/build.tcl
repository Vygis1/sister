#==============================================================================
# build.tcl - non-project Vivado build, RTL -> bitstream.
#
# Nothing is stored in a .xpr; the build is reproducible from this tree alone.
# Driven by tools/vivado.sh, but usable directly:
#
#   vivado -mode batch -source tools/build.tcl -tclargs -top blink
#
# Options (all optional):
#   -top   <name>   top module                 (default: blink)
#   -part  <part>   target part                (default: xc7a100tfgg676-1)
#   -rtl   <dir>    source dir, *.v *.sv       (default: rtl)
#   -xdc   <file>   constraints                (default: boards/qmtech_a100t/qmtech_a100t.xdc)
#   -out   <dir>    output dir                 (default: build/<top>)
#   -synth 1        stop after synthesis, no bitstream
#   -gen   N:V      set Verilog parameter N to V on the top module
#
# The generic separator is a COLON and not an equals sign, because vivado.bat is
# a Windows batch file and cmd.exe splits arguments on "=" exactly as it splits
# them on spaces. `-gen CORE_NES=0` arrives as two tokens, the value is lost, and
# the parameter quietly takes some other value -- which is worse than an error,
# because the build succeeds and produces the wrong thing.
#==============================================================================

set root [file normalize [file dirname [info script]]/..]

set top    blink
set part   xc7a100tfgg676-1
set rtldir $root/rtl
set xdc    $root/boards/qmtech_a100t/qmtech_a100t.xdc
# Extra constraints and IP, both repeatable. A core that uses DDR3 needs a
# second constraints file for the memory pins and the memory controller itself,
# and neither belongs in a build that does not use them: the pins would be
# constrained on a design with no such ports, and the controller would cost
# eight minutes of synthesis to produce something nothing instantiates.
set xdcs   {}
set ips    {}
set outdir ""
set synth_only 0
set generics {}

for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        -top   { incr i; set top    [lindex $argv $i] }
        -part  { incr i; set part   [lindex $argv $i] }
        -rtl   { incr i; set rtldir [file normalize [lindex $argv $i]] }
        -xdc   { incr i; set xdc    [file normalize [lindex $argv $i]] }
        -xdc2  { incr i; lappend xdcs [file normalize [lindex $argv $i]] }
        -ip    { incr i; lappend ips  [file normalize [lindex $argv $i]] }
        -out   { incr i; set outdir [file normalize [lindex $argv $i]] }
        -synth { incr i; set synth_only [lindex $argv $i] }
        -gen   { incr i; lappend generics [string map {: =} [lindex $argv $i]] }
        -effort { set effort 1 }
        -fresh  { set fresh 1 }
        -incr   { set incr 1 }
        default { puts " ignoring unknown arg: [lindex $argv $i]" }
    }
}
if {![info exists effort]} { set effort 0 }
if {![info exists fresh]}  { set fresh 0 }
if {![info exists incr]}   { set incr 0 }
if {$outdir eq ""} { set outdir $root/build/$top }
# CONSOLE_CLK_HZ, a Verilog define, for the code that cannot take a parameter -- a SystemVerilog
# package (the PC's OPL3, opl3_pkg.sv): eth_top's console clock is 1000 MHz / CLK_DIV
set defines {}
foreach g $generics {
    if {[regexp {^CLK_DIV=([0-9]+)$} $g -> cdiv]} { lappend defines "CONSOLE_CLK_HZ=[expr {1000000000 / $cdiv}]" }
}

file mkdir $outdir

puts ""
puts "=============================================================="
puts " $top -> $part"
puts " rtl : $rtldir"
puts " xdc : $xdc"
puts " out : $outdir"
puts "=============================================================="
puts ""

# Establish the part BEFORE anything is read.
#
# synth_design takes -part, so it is easy to believe that is enough. It is not:
# read_ip loads the IP into the session's implicit project, and that project is
# on Vivado's default part until told otherwise -- xc7a12ticsg325-1L, a chip
# this design has never heard of. An IP customized for one part inside a project
# set to another is LOCKED, and a locked IP will not regenerate its output
# products. Implementation then runs against whatever netlist happened to be on
# disk, which is how a corrected pinout can be generated, sit in the .xci, and
# still not reach the bitstream.
#
# It fails as "16 unroutable pins" inside the memory controller's PHY, twenty
# minutes downstream of the one line that caused it.
create_project -in_memory -part $part

set srcs [concat [glob -nocomplain $rtldir/*.v] [glob -nocomplain $rtldir/*.sv]]
if {[llength $srcs] == 0} { puts " *** no sources in $rtldir"; exit 1 }
foreach f [lsort $srcs] {
    puts " read: [file tail $f]"
    if {[file extension $f] eq ".sv"} { read_verilog -sv $f } else { read_verilog $f }
}
# the PC (CORE_PC=1): ao486 and its chipset from rtl/pc, by its file list (rtl/pc/files.f -- the
# folder holds 486Tang's alternatives too, under the same module names)
set incdirs {}
if {[lsearch -exact $generics "CORE_PC=1"] >= 0} {
    set fl [open $rtldir/pc/files.f]
    foreach f [split [read $fl] "
"] {
        set f [string trim $f]
        if {$f eq ""} continue
        puts " read: pc/$f"
        read_verilog -sv $rtldir/pc/$f      ;# (all of it as SystemVerilog: some of ao486's .v files are)
    }
    close $fl
    lappend incdirs $rtldir/pc/ao486
}
if {![file exists $xdc]} { puts " *** no such xdc: $xdc"; exit 1 }
read_xdc $xdc
foreach f $xdcs {
    if {![file exists $f]} { puts " *** no such xdc: $f"; exit 1 }
    puts " xdc : $f"
    read_xdc $f
}

# IP is read before synthesis and synthesised with the design. Out-of-context
# would be faster to rebuild but hides the memory controller's own constraints
# from the top-level timing run, and a memory interface whose timing was never
# checked against the design around it is the kind of thing that calibrates on
# the bench and fails in a warm room.
foreach f $ips {
    if {![file exists $f]} { puts " *** no such ip: $f"; exit 1 }
    puts " ip  : [file tail $f]"
    read_ip $f
    generate_target synthesis [get_files $f]
    synth_ip [get_files $f]
    # read_ip, then synthesise the IP out of context.
    #
    # The out-of-context netlist is not optional here -- without it synth_design
    # stops with "DCP does not exist". What IS worth avoiding is
    # `generate_target all`, which additionally produces the IP's own example
    # design; nothing instantiates it and it only adds files to trip over.
    #
    # synth_ip builds an out-of-context netlist for the IP, and synth_design
    # then synthesises the same IP again in context. Both copies end up in the
    # design and Vivado reports the result as multiple drivers on nets deep
    # inside the memory controller -- which reads as a broken controller rather
    # than as the same controller twice.
    #
    # The synthesis targets were already produced when the IP was generated, so
    # letting synth_design pull it in is all that is needed.
}

# Parameters set from the command line, so one source tree builds the NES core
# and the Master System core without either being a different file.
if {[llength $generics] > 0} {
    puts " generics: $generics"
}
# Let placement and routing use the machine. Vivado's default here is
# conservative, and those two steps are about half of a build's wall clock.
# Synthesis is single-threaded whatever this says, so the gain is on the back
# half only. 8 is the most Vivado accepts.
set_param general.maxThreads 8

set defopt {}
if {[llength $defines]} { set defopt [list -verilog_define $defines]; puts " defines: $defines" }
# RETIME=1 (the environment): synthesis moves registers across long combinational chains to balance
# them -- the same behaviour every clock
if {[info exists ::env(RETIME)] && $::env(RETIME) eq "1"} { lappend defopt -retiming; puts " retiming on" }

# AREA=1 (the environment) asks synthesis and opt_design for their area-first directives:
# for a design that would not otherwise fit (the N64 with its RDP pipeline: 97% of the LUTs).
if {[info exists ::env(AREA)] && $::env(AREA) ne ""} {
    synth_design -top $top -part $part -generic $generics -include_dirs $incdirs {*}$defopt -directive AreaOptimized_high
} else {
    synth_design -top $top -part $part -generic $generics -include_dirs $incdirs {*}$defopt
}

# Critical warnings are errors wearing a friendlier label. A multi-driven net
# lets synthesis silently drop a driver, and the hardware then does not match
# simulation. Surface the count rather than let it scroll past in a long log.
set crit [get_msg_config -severity {CRITICAL WARNING} -count]
if {$crit > 0} {
    puts ""
    puts " *** $crit CRITICAL WARNING(s) - search the log, treat as errors ***"
    puts ""
}

write_checkpoint -force $outdir/post_synth.dcp
report_utilization -file $outdir/post_synth_util.rpt
report_utilization -hierarchical -hierarchical_depth 5 -file $outdir/post_synth_hier.rpt

set luts [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT} -quiet]]
set ffs  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH} -quiet]]
set b18  [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*} -quiet]]
set b36  [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*} -quiet]]
set dsp  [llength [get_cells -hier -filter {REF_NAME =~ DSP48*} -quiet]]
puts ""
puts " post-synthesis utilisation (XC7A100T totals):"
puts [format "   LUTs         %6d  of  63400  (%.1f%%)" $luts [expr {100.0*$luts/63400}]]
puts [format "   FFs          %6d  of 126800  (%.1f%%)" $ffs  [expr {100.0*$ffs/126800}]]
puts [format "   BRAM36 equiv %6.1f  of    135  (%.1f%%)" \
      [expr {$b36 + $b18/2.0}] [expr {100.0*($b36+$b18/2.0)/135}]]
puts [format "   DSP48        %6d  of    240  (%.1f%%)" $dsp [expr {100.0*$dsp/240}]]

# A combinational loop is caught by the bitstream's DRC -- after an hour of place and route.
# It is already there in the synthesised netlist: look for it now and stop.
set lpr [report_drc -checks {LUTLP-1} -return_string]
if {[string match "*Combinatorial Loop Alert*" $lpr]} {
    set fh [open $outdir/loops.rpt w]; puts $fh $lpr; close $fh
    puts ""
    puts "ERROR: a combinational loop in the synthesised design -- see $outdir/loops.rpt"
    exit 1
}
if {$synth_only} {
    puts ""
    puts " synthesis only - stopping here."
    exit 0
}

puts ""
puts " implementing..."
if {[info exists ::env(AREA)] && $::env(AREA) ne ""} {
    opt_design -directive ExploreArea
} else {
    opt_design
}

# Start from where the last build finished. Vivado keeps the placement and
# routing of everything that has not changed and only works on what has, which
# on the small edits this project actually makes is most of the design. Place
# and route are half the wall clock and neither uses more than about one and a
# half cores however many you have, so this is the only lever that moves.
#
# Opt in with -incr, because the downside is far worse than the upside. On a
# small edit it halves place and route. On a large one -- adding the memory
# queues, say -- the router spends its time trying to fit new logic into a
# placement that was not made for it: measured once at 37 minutes still
# oscillating and not converging, against 10 for a clean build. Two minutes
# saved is not worth that risk by default.
set incr_dcp $outdir/post_route.dcp
if {$incr && [file exists $incr_dcp]} {
    puts " reusing [file tail $incr_dcp] as a starting point"
    read_checkpoint -incremental $incr_dcp
}

# -effort asks for the Explore directives rather than the defaults, for a design
# that is actually close. (It was ExtraTimingOpt placement and AggressiveExplore:
# on 2026-10-05 that left the PlayStation at -0.907 ns after two hours, where
# Explore, from the same netlist, passed at +0.248 in twenty minutes.)
if {$effort} {
    # PLACE_DIR (the environment) picks another placer directive for a re-roll of a design
    # that missed by a few hundred picoseconds: the big images are a placement lottery
    # (the PlayStation's release image missed by 0.385 ns where its debug image passed).
    set pdir [expr {[info exists ::env(PLACE_DIR)] && $::env(PLACE_DIR) ne "" ? $::env(PLACE_DIR) : "Explore"}]
    puts " (Explore directives; placer $pdir)"
    place_design     -directive $pdir
    phys_opt_design  -directive Explore
    route_design     -directive Explore
} else {
    place_design
    phys_opt_design
    route_design
}

# A post-route phys_opt only helps when something is still failing, and it can
# only improve on what routing produced -- it re-places and re-routes individual
# failing paths rather than starting over.
set wns_try [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]]
if {$wns_try ne "" && $wns_try < 0} {
    puts [format " post-route slack %.3f ns - trying physical optimisation" $wns_try]
    phys_opt_design -directive AggressiveExplore
}
# ...and if that was not enough, a timing clean-up of the routing and one more go: these
# two passes are what stands between a near miss and a flashable image, and cost ten minutes.
set wns_try2 [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]]
if {$wns_try2 ne "" && $wns_try2 < 0} {
    puts [format " still %.3f ns - routing clean-up and physical optimisation once more" $wns_try2]
    route_design -tns_cleanup
    phys_opt_design -directive AggressiveExplore
    route_design -tns_cleanup
}

write_checkpoint -force $outdir/post_route.dcp
report_timing_summary -file $outdir/post_route_timing.rpt
report_utilization    -file $outdir/post_route_util.rpt
report_drc            -file $outdir/drc.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]]
puts ""
puts "=============================================================="
if {$wns eq ""} {
    puts " TIMING: no paths reported - were the constraints read?"
} elseif {$wns < 0} {
    puts [format " TIMING: FAILS by %.3f ns - see post_route_timing.rpt" [expr {-$wns}]]
} else {
    puts [format " TIMING: passes, worst slack %.3f ns" $wns]
}
puts "=============================================================="

# Two files, and the difference matters. A .bit carries a text header naming the
# design and the build date; JTAG skips it, and the FPGA's own configuration
# engine does NOT -- so a .bit written into a MultiBoot slot never loads, and the
# board falls back to the shell with nothing saying why. The .bin is the raw
# image, and that is what goes in a slot.
#
# Compressed because a slot is 2 MB and an uncompressed image for this part is
# 3.65 MB. Compression is handled by the configuration engine itself, so it costs
# nothing at load time and is the difference between fitting and not.
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force -bin_file $outdir/$top.bit

puts ""
puts " bitstream: $outdir/$top.bit"
if {[file exists $outdir/$top.bin]} {
    set kb [expr {[file size $outdir/$top.bin] / 1024}]
    puts " raw image: $outdir/$top.bin  (${kb} kB, for a flash slot)"
}
puts " reports:   $outdir"
puts ""
