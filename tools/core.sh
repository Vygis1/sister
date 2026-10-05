#!/usr/bin/env bash
# Build one console as a raw image, ready for a flash slot.
#
#   ./tools/core.sh nes          just the NES
#   ./tools/core.sh sms          just the Master System
#   ./tools/core.sh md           just the Mega Drive
#   ./tools/core.sh ps1          just the PlayStation
#   ./tools/core.sh n64          just the Nintendo 64
#   ./tools/core.sh shell        the golden image
#   ./tools/core.sh dev          both consoles in one image, for JTAG
#
# ONE MACHINE PER IMAGE. That is the whole point of the shell: a core in a slot
# gets the entire chip instead of sharing it with a console nobody is running.
# The `dev` build exists because during development a JTAG load beats a flash
# install and a reconfiguration, not because sharing is a good idea.
#
# Everything lands in cores/, which is the library the web UI offers. A slot
# wants a .bin and not a .bit -- see tools/build.tcl for why that is not a
# detail but the difference between loading and not.
set -e
cd "$(dirname "$0")/.."

TOP=eth_top
XDC=boards/qmtech_a100t/eth_top.xdc
GEN=""
EXTRA=""
MIG_XCI=build/mig_gen/mig_gen.srcs/sources_1/ip/mig_a100t/mig_a100t.xci

# eth_top carries the DDR3 ports whether or not a core uses them, so a core
# built without the memory controller still has 27 output pins to place. The
# controller's own .xdc does that for the Mega Drive; everything else needs
# this, or write_bitstream stops on DRC UCIO-1 after a full run.
NOMIG="-xdc2 boards/qmtech_a100t/ddr3_unused.xdc"

case "${1:-nes}" in
  nes)   NAME=nes;   GEN="-gen CORE_NES:1 -gen CORE_SMS:0"; EXTRA="$NOMIG" ;;
  sms)   NAME=sms;   GEN="-gen CORE_NES:0 -gen CORE_SMS:1 -gen CORE_MD:0"; EXTRA="$NOMIG" ;;
  md|genesis|megadrive)
         NAME=md;    GEN="-gen CORE_NES:0 -gen CORE_SMS:0 -gen CORE_MD:1 -gen MD_DDR3:1"
         # The Mega Drive keeps its cartridge in DDR3, so it needs the memory
         # pins and the memory controller. Nothing else here does.
         # Only the IP. The DDR3 pins are constrained by the memory controller
         # itself, out of the same .prj that tools/migpins.py writes from
         # ddr3.xdc -- passing that file as well constrains every pin twice, and
         # where the two disagree the PHY's own byte-lane clocking becomes
         # unroutable. It cost a build to find out.
         EXTRA="-ip $MIG_XCI" ;;
  ps1|playstation)
         NAME=ps1;   GEN="-gen CORE_NES:0 -gen CORE_SMS:0 -gen CORE_MD:0 -gen CORE_PS1:1"
         # The PlayStation keeps 1 MB of VRAM in DDR3, so like the Mega Drive it
         # needs the memory controller. Its boot program is baked into the core.
         EXTRA="-ip $MIG_XCI" ;;
  n64|nintendo64)
         NAME=n64;   GEN="-gen CORE_NES:0 -gen CORE_SMS:0 -gen CORE_MD:0 -gen CORE_PS1:0 -gen CORE_N64:1"
         # RDRAM and the cartridge live in DDR3: the memory controller again.
         EXTRA="-ip $MIG_XCI" ;;
  dev)   NAME=dev;   GEN="-gen CORE_NES:1 -gen CORE_SMS:1"; EXTRA="$NOMIG" ;;
  shell) NAME=shell; TOP=shell_top; XDC=boards/qmtech_a100t/shell_top.xdc ;;
  *) echo "usage: tools/core.sh [nes|sms|md|ps1|n64|dev|shell]" >&2; exit 1 ;;
esac

LOG="build/core_$NAME.log"
# each core in a folder of its own, so two can build at once
OUT="build/core_$NAME"
# A marker older than anything this run produces, so the check below can tell
# a fresh image from the one the previous run left behind.
STAMP="build/.core_$NAME.start"
mkdir -p build && : > "$STAMP"
# What every source looked like as the build started: cores/$NAME.src is cut from
# this (tools/srcstamp.py), and tools/release.sh checks an image against it.
python tools/srcstamp.py --snapshot > "build/.core_$NAME.hashes"
# EFFORT=1 asks for the timing-driven place and route directives. They cost
# about twice the runtime and are worth it for a design that is close, which the
# PlayStation now is: at 99.99% of the part's slices its critical path is 75%
# ROUTING, and the default directives left 0.003 ns -- too thin to flash.
tools/vivado.sh build -top "$TOP" -xdc "$XDC" $GEN $EXTRA ${EFFORT:+-effort} -out "$OUT" 2>&1 | tee "$LOG" | \
  grep -E "^ *(ERROR|CRITICAL)|TIMING:|raw image:|generics:" || true

bad=0
grep -qE "^ERROR" "$LOG"            && { echo " *** errors"; bad=1; }
grep -qE "^CRITICAL WARNING:" "$LOG" && { echo " *** critical warnings"; bad=1; }
grep -qi "multi-driven" "$LOG"      && { echo " *** multi-driven nets"; bad=1; }
[ -f "$OUT/$TOP.bin" ]        || { echo " *** no .bin produced"; bad=1; }
# The image has to be newer than the marker above. A build that is interrupted
# -- killed, or out of memory -- leaves the PREVIOUS bitstream sitting in
# build/, and copying that into cores/ publishes a stale image that looks
# exactly like your change not working. It cost an install and a measurement
# to notice.
[ "$OUT/$TOP.bin" -nt "$STAMP" ] || { echo " *** $OUT/$TOP.bin is older than this run: the build did not finish"; bad=1; }
# An image that misses timing is not an image. It will be flashed, it will
# run, and it will do something different every time it warms up -- which
# reads as a logic bug and is chased as one.
grep -qE "^ TIMING: FAILS" "$LOG"    && { echo " *** timing failed: this image would not be trustworthy"; bad=1; }
[ $bad -eq 0 ] || exit 1

# The core slot is everything above $200000: 6 MB of an 8 MB flash. An image
# that does not fit would be written anyway and fail to load later, which is a
# much worse place to find out.
SLOT_KB=6144
SIZE=$(stat -c %s "$OUT/$TOP.bin")
if [ "$NAME" != "shell" ] && [ "$SIZE" -gt $((SLOT_KB*1024)) ]; then
  echo " *** $((SIZE/1024)) kB will not fit the ${SLOT_KB} kB slot"
  exit 1
fi
# The shell has its own 2 MB at the bottom and must not run into the slot.
if [ "$NAME" = "shell" ] && [ "$SIZE" -gt 2097152 ]; then
  echo " *** the shell is $((SIZE/1024)) kB and must stay under 2048"
  exit 1
fi

mkdir -p cores
cp "$OUT/$TOP.bin" "cores/$NAME.bin"
python tools/srcstamp.py "$LOG" "build/.core_$NAME.hashes" > "cores/$NAME.src" || echo " *** no source stamp: tools/release.sh will refuse this image"
# the shell as a bitstream too: the first programming writes it over JTAG
[ "$NAME" = shell ] && cp "$OUT/$TOP.bit" cores/shell.bit
grep -E "Slice LUTs|Block RAM Tile" "build/$TOP/post_route_util.rpt" | head -2
echo " cores/$NAME.bin  $((SIZE/1024)) kB"
