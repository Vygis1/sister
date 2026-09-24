# Generate the DDR3 controller from boards/qmtech_a100t/mig_a100t.prj.
#
# This exists because the alternative is the MIG wizard, and the wizard is a
# list of 48 near-identical ball names typed in by hand. One inserted row put
# ddr3_addr[2] on F16 -- a VCCO_16 power pad -- and shifted eleven address
# lines down behind it. Nothing complains until route_design cannot place the
# PHY, by which point the cause is twenty minutes upstream.
#
# Run tools/migpins.py first: it writes the .prj's pinout from ddr3.xdc, which
# is the schematic record and the only place the numbers belong.
#
#   tools/vivado.sh mig     (or: vivado -mode batch -source tools/mig.tcl)

set root [file normalize [file dirname [info script]]/..]
set part xc7a100tfgg676-1
set out  $root/build/mig_gen
set prj  $root/boards/qmtech_a100t/mig_a100t.prj

if {![file exists $prj]} { puts " *** no $prj"; exit 1 }

# The project part must be the board's. An IP customized for one part inside a
# project set to another is LOCKED: its output products will not regenerate,
# implementation silently uses whatever netlist was there before, and the
# mismatch surfaces as unroutable PHY pins. That is how this went wrong the
# first time -- the project had been left on Vivado's default xc7a12ti.
puts " part : $part"
puts " prj  : [file tail $prj]"

file delete -force $out
file mkdir $out
create_project mig_gen $out -part $part -force
set_property target_language Verilog [current_project]

create_ip -name mig_7series -vendor xilinx.com -library ip -module_name mig_a100t
set_property -dict [list CONFIG.XML_INPUT_FILE $prj] [get_ips mig_a100t]

set xci [get_property IP_FILE [get_ips mig_a100t]]
if {[get_property IS_LOCKED [get_ips mig_a100t]]} {
    puts " *** mig_a100t is LOCKED -- part mismatch, output products are stale"
    exit 1
}

# generate_target produces the RTL and the constraints. The out-of-context
# synthesis that normally follows is build.tcl's job -- this is a project-mode
# session and synth_ip refuses to run in one.
generate_target all [get_ips mig_a100t]

# Prove the pins survived the round trip, against the file the build reads.
set gen $out/mig_gen.gen/sources_1/ip/mig_a100t/mig_a100t/user_design/constraints/mig_a100t.xdc
if {![file exists $gen]} { puts " *** the controller emitted no constraints"; exit 1 }
puts " xci  : $xci"
puts " xdc  : $gen"
puts " mig generated"
