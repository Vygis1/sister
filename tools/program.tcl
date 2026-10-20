#==============================================================================
# program.tcl - load a bitstream over JTAG, or burn it into the QSPI flash.
#
#   vivado -mode batch -source tools/program.tcl -tclargs -bit build/blink/blink.bit
#   vivado -mode batch -source tools/program.tcl -tclargs -bit <file> -flash 1 -mem <part>
#
# Volatile by default: the bitstream lives in the FPGA until power is removed.
# -flash 1 writes it to the board's QSPI so it configures itself at power-on.
#
# Options:
#   -bit   <file>   bitstream to load                 (required)
#   -url   <host>   hw_server URL         (default: localhost:3121)
#   -flash 1        write to QSPI instead of loading volatile
#   -mem   <part>   cfgmem part, required with -flash
#   -iface <mode>   SPIx1 (default) or SPIx4; must match the bitstream
#
# The QSPI part number is NOT guessed here. Read the marking on the flash chip,
# then find the matching cfgmem part with:
#     vivado -mode tcl
#     join [lsort [get_cfgmem_parts]] \n
# Typical candidates on these boards: n25q128-3.3v-spi-x1_x2_x4,
# w25q128fv-spi-x1_x2_x4, s25fl128sxxxxxx0-spi-x1_x2_x4. Writing the wrong one
# either fails outright or programs a device geometry that does not match.
#
# Vivado only sees cables it has drivers for - Xilinx Platform Cable and
# Digilent. A bare FT2232 breakout will not appear here; use openFPGALoader for
# those (see README).
#==============================================================================

set bitfile ""
set url     localhost:3121
set do_flash 0
set mem     ""
set iface   SPIx1

for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        -bit   { incr i; set bitfile [file normalize [lindex $argv $i]] }
        -url   { incr i; set url     [lindex $argv $i] }
        -flash { incr i; set do_flash [lindex $argv $i] }
        -mem   { incr i; set mem     [lindex $argv $i] }
        -iface { incr i; set iface   [lindex $argv $i] }
    }
}
if {$bitfile eq "" || ![file exists $bitfile]} {
    puts " *** -bit <file> is required and must exist"; exit 1
}

open_hw_manager
connect_hw_server -url $url
set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} {
    puts ""
    puts " *** No JTAG target found."
    puts "     - is the cable plugged in, and its driver installed?"
    puts "     - is VREF (J1 pin 1, 3V3) connected? Without it a level-shifting"
    puts "       cable drives nothing and reports no error."
    puts "     - is the board powered?"
    exit 1
}
puts " targets: $targets"
open_hw_target [lindex $targets 0]

set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
puts " device : $dev  (IDCODE [get_property REGISTER.IDCODE $dev -quiet])"

if {$do_flash} {
    if {$mem eq ""} { puts " *** -mem <cfgmem part> is required with -flash"; exit 1 }
    set mcs [file rootname $bitfile].mcs
    # Size the image from the part rather than hardcoding it. MEM_DENSITY is
    # in megabits, write_cfgmem wants megabytes, and an image built for a
    # device larger than the one fitted will not program.
    set cfgpart [lindex [get_cfgmem_parts $mem] 0]
    if {$cfgpart eq ""} { puts " *** no such cfgmem part: $mem"; exit 1 }
    set size_mb [expr {[get_property MEM_DENSITY $cfgpart] / 8}]
    puts " cfgmem : $mem  (${size_mb} MB)"

    # The interface here must MATCH the bitstream's own SPI_BUSWIDTH, and Vivado
    # refuses outright when they differ -- which is the good outcome, because the
    # bad one would be an image the board cannot read.
    write_cfgmem -force -format MCS -interface $iface -size $size_mb \
                 -loadbit "up 0x0 $bitfile" -file $mcs
    create_hw_cfgmem -hw_device $dev $cfgpart
    set cm [get_property PROGRAM.HW_CFGMEM $dev]
    set_property PROGRAM.FILES        [list $mcs] $cm
    set_property PROGRAM.BLANK_CHECK  0          $cm
    set_property PROGRAM.ERASE        1          $cm
    # only the sectors the image covers: the shell is the first 1.4 MB, and the core slot
    # from 2 MB up stays (the default erases the whole flash, and the ESP32 then believes a
    # core is installed that is not there any more)
    set_property PROGRAM.ADDRESS_RANGE {use_file} $cm
    set_property PROGRAM.CFG_PROGRAM  1          $cm
    set_property PROGRAM.VERIFY       1          $cm
    create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
    program_hw_devices $dev
    program_hw_cfgmem -hw_cfgmem $cm

    # Programming the flash leaves the FPGA running the flash-programmer
    # bitstream, not the design. Without this the board looks dead until
    # someone power-cycles it, which is indistinguishable from a bad flash.
    puts ""
    puts " booting from flash..."
    boot_hw_device $dev
    after 1500
    refresh_hw_device -update_hw_probes false $dev

    puts ""
    puts " flashed and booted. It will configure itself at power-on from now on."
} else {
    set_property PROGRAM.FILE $bitfile $dev
    program_hw_devices $dev
    refresh_hw_device $dev
    puts ""
    puts " loaded [file tail $bitfile] - volatile, gone at power-off."
}

close_hw_manager
