#==============================================================================
# check.tcl - is this Vivado install actually usable for this board?
#
#   ./tools/vivado.sh check
#
# Runs in under a minute. Answers two questions: is the part installed, and will
# it synthesise without demanding a licence.
#
# XC7A100T is a free-tier device. Vivado ML Standard targets it with no licence
# file. The 30-day activation flow in the installer is for Enterprise - if that
# dialog loops with nothing actionable on it, ignore it.
#==============================================================================

set part xc7a100tfgg676-1
for {set i 0} {$i < [llength $argv]} {incr i} {
    if {[lindex $argv $i] eq "-part"} { incr i; set part [lindex $argv $i] }
}
set family [string range $part 0 7]

puts ""
puts "=============================================================="
puts " Vivado install check"
puts "=============================================================="
puts " version : [version -short]"
puts " want    : $part"

set parts [get_parts -quiet ${family}*]
puts ""
if {[llength $parts] == 0} {
    puts " *** NO $family PARTS INSTALLED ***"
    puts ""
    puts " This is device selection, not licensing. The installer had '7 Series'"
    puts " unticked, so no Artix-7 support was installed. Re-run the installer,"
    puts " tick 7 Series, and add it to the existing install."
    puts ""
    puts "=============================================================="
    puts " NOT READY"
    puts "=============================================================="
    exit 1
}
puts " found [llength $parts] $family package/speed variants:"
foreach p [lsort $parts] { puts "   $p" }

if {[lsearch -exact $parts $part] < 0} {
    puts ""
    puts " *** $part is not among them - check the part string."
    exit 1
}

puts ""
puts "=============================================================="
puts " Licence check - a two-gate design that must synthesise"
puts "=============================================================="

set tmp [file join [pwd] build check]
file mkdir $tmp
set f [open $tmp/tiny.v w]
puts $f "module tiny(input c, input d, output reg q);"
puts $f "always @(posedge c) q <= ~d;"
puts $f "endmodule"
close $f

set ok 0
if {[catch {
    read_verilog $tmp/tiny.v
    synth_design -top tiny -part $part -mode out_of_context
    set ok 1
} err]} {
    puts ""
    puts " synthesis FAILED on a two-gate design:"
    puts "   $err"
    puts ""
    puts " If that mentions a licence, you have landed in Enterprise mode."
    puts " $part does not need one."
} else {
    puts ""
    puts " Synthesis succeeded on $part. No licence required."
}

puts ""
puts "=============================================================="
if {$ok} {
    puts " READY. Next: ./tools/vivado.sh build"
} else {
    puts " NOT READY - see above."
}
puts "=============================================================="
puts ""
