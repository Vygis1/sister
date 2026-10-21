#!/usr/bin/env bash
# Build one console as a raw image, ready for a flash slot.
#
#   ./tools/core.sh nes          just the NES
#   ./tools/core.sh sms          just the Master System
#   ./tools/core.sh md           just the Mega Drive
#   ./tools/core.sh ps1          just the PlayStation
#   ./tools/core.sh n64          just the Nintendo 64
#   ./tools/core.sh gb           just the Game Boy
#   ./tools/core.sh a26          just the Atari 2600
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
  gg|gamegear)
         # the Master System core with GG set (sms.v): 12-bit colour, START, stereo, the LCD's
         # 160 x 144 window tripled; its cartridge in block RAM like the Master System's (256 kB)
         NAME=gg;    GEN="-gen CORE_NES:0 -gen CORE_SMS:0 -gen CORE_GG:1 -gen CORE_MD:0"; EXTRA="$NOMIG" ;;
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
         NAME=ps1;   GEN="-gen CORE_NES:0 -gen CORE_SMS:0 -gen CORE_MD:0 -gen CORE_PS1:1 -gen CLK_DIV:${PS1_DIV:-20} -gen PS1_DBG:${PS1_DBG:-1} -gen JTAG_DBG:${JTAG:-0} -gen PS1_DCIDX:${PS1_DCIDX:-8}"
         # The PlayStation keeps 1 MB of VRAM in DDR3, so like the Mega Drive it
         # needs the memory controller. Its boot program is baked into the core.
         EXTRA="-ip $MIG_XCI" ;;
  n64|nintendo64)
         # (at 62.5 MHz: the console's MMCM, 1000 MHz / 16 -- the RCP's own clock)
         NAME=n64;   GEN="-gen CORE_NES:0 -gen CORE_SMS:0 -gen CORE_MD:0 -gen CORE_PS1:0 -gen CORE_N64:1 -gen CLK_DIV:${N64_DIV:-16} -gen N64_DBG:${N64_DBG:-1} -gen N64_ISV:${N64_ISV:-0} -gen JTAG_DBG:${JTAG:-0}"
         # RDRAM and the cartridge live in DDR3: the memory controller again.
         EXTRA="-ip $MIG_XCI" ;;
  snes|superfamicom)
         # The cartridge lives in DDR3 (cart_ddr3, as the Mega Drive's); work RAM, VRAM and
         # sound RAM are block RAM. 50 MHz by default (SNES_DIV): ~3170 clocks a line, the PPU
         # draws one in ~1550.
         NAME=snes;  GEN="-gen CORE_NES:0 -gen CORE_SMS:0 -gen CORE_MD:0 -gen CORE_PS1:0 -gen CORE_N64:0 -gen CORE_SNES:1 -gen CLK_DIV:${SNES_DIV:-20} -gen JTAG_DBG:${JTAG:-0}"
         EXTRA="-ip $MIG_XCI" ;;
  gb|gameboy)
         # The Game Boy (gb_top.v): its cartridge in DDR3 (cart_ddr3 + cart_cache, as the SNES's),
         # so the memory controller again; 160 x 144 tripled on HDMI, stereo sound.
         NAME=gb;    GEN="-gen CORE_NES:0 -gen CORE_SMS:0 -gen CORE_MD:0 -gen CORE_GB:1 -gen JTAG_DBG:${JTAG:-0}"
         EXTRA="-ip $MIG_XCI" ;;
  pce|pcengine|tg16)
         # The PC Engine (pce_top.v): its HuCard in DDR3 (cart_ddr3 + cart_cache, as the Game Boy's),
         # so the memory controller again; 256-512 x 240 in 9-bit colour, the PSG's stereo.
         NAME=pce;   GEN="-gen CORE_NES:0 -gen CORE_SMS:0 -gen CORE_MD:0 -gen CORE_PCE:1 -gen JTAG_DBG:${JTAG:-0}"
         EXTRA="-ip $MIG_XCI" ;;
  gba|gameboyadvance)
         # The Game Boy Advance (gba_top.v): the cartridge and the work RAM in DDR3 (mem_arb, cart_ddr3,
         # cart_cache, gba_ewram), the BIOS built in; 240 x 160 in 15-bit colour.
         NAME=gba;   GEN="-gen CORE_NES:0 -gen CORE_SMS:0 -gen CORE_MD:0 -gen CORE_GBA:1 -gen JTAG_DBG:${JTAG:-0}"
         EXTRA="-ip $MIG_XCI" ;;
  a26|atari|atari2600)
         # The Atari 2600 (a26_top.v): its cartridge (up to 32 kB) in the core's own block RAM,
         # filled through the program window like the Master System's; no memory controller.
         NAME=a26;   GEN="-gen CORE_NES:0 -gen CORE_SMS:0 -gen CORE_MD:0 -gen CORE_A26:1"; EXTRA="$NOMIG" ;;
  pc|dos|486)
         # The PC (pc_top.v): a 486 (ao486 from 486Tang, rtl/pc), its memory and its picture in
         # DDR3, its hard disk served by the ESP32 from an image on the card; VGA to 640x480.
         # 66.7 MHz (PC_DIV 15): ao486's decode/write/read stall chains restructured (2026-10-21, every change
         # checked cycle-exact by sim/pc's per-clock trace hash) -- closes with the Explore directives and the
         # ExtraTimingOpt placer (+0.060 ns); Doom's demo3 16.6 fps against 15.6 at the old 62.5 MHz
         NAME=pc;    GEN="-gen CORE_NES:0 -gen CORE_SMS:0 -gen CORE_MD:0 -gen CORE_PC:1 -gen CLK_DIV:${PC_DIV:-15} -gen JTAG_DBG:${JTAG:-0}"
         [ "${PC_DIV:-15}" -lt 20 ] && { EFFORT=${EFFORT:-1}; export PLACE_DIR=${PLACE_DIR:-ExtraTimingOpt}; }
         EXTRA="-ip $MIG_XCI" ;;
  dev)   NAME=dev;   GEN="-gen CORE_NES:1 -gen CORE_SMS:1"; EXTRA="$NOMIG" ;;
  shell) NAME=shell; TOP=shell_top; XDC=boards/qmtech_a100t/shell_top.xdc ;;
  *) echo "usage: tools/core.sh [nes|sms|gg|md|ps1|n64|snes|gb|a26|pce|gba|pc|dev|shell]" >&2; exit 1 ;;
esac
# RELEASE=1: the shipping image. Everything a developer or a PC on the network read is left
# out -- the logic analyser, the PC sound ring, the frame reader, the bare-CPU test slot, the
# PlayStation's and the N64's debug hardware (eth_top RELEASE, PS1_DBG=0, N64_DBG=0; JTAG=0
# unless asked for). Its reports go to build/rel_<name>/ so the debug build's stay for
# comparison; the image still lands in cores/<name>.bin, which is what goes on the card.
if [ "${RELEASE:-0}" = 1 ]; then
  GEN="$GEN -gen RELEASE:1"
  GEN="$(echo "$GEN" | sed -E "s/-gen PS1_DBG:[0-9]+/-gen PS1_DBG:0/; s/-gen N64_DBG:[0-9]+/-gen N64_DBG:0/")"
  # (JTAG stays as asked: RELEASE=1 JTAG=1 is the release image with the register bus kept, for
  # measuring a shipping-shaped core -- the frame counter and the memory counters are in every image)
fi
# JTAG=1: the register bus over the JTAG cable (eth_top JTAG_DBG, tools/jtag.py) -- the
# jtag_axi core generated once by tools/jtagaxi.tcl
if [ "${JTAG:-0}" = 1 ]; then
  JTAG_XCI=build/jtagaxi_gen/jtagaxi_gen.srcs/sources_1/ip/jtag_axi_0/jtag_axi_0.xci
  [ -f "$JTAG_XCI" ] || { echo "no $JTAG_XCI: run tools/jtagaxi.tcl first" >&2; exit 1; }
  EXTRA="$EXTRA -ip $JTAG_XCI"
fi

LOG="build/core_$NAME.log"
# each core in a folder of its own, so two can build at once
OUT="build/core_$NAME"
if [ "${RELEASE:-0}" = 1 ]; then LOG="build/rel_$NAME.log"; OUT="build/rel_$NAME"; fi
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
tools/vivado.sh build -top "$TOP" -xdc "$XDC" $GEN $EXTRA ${EFFORT:+-effort} ${INCR:+-incr} -out "$OUT" 2>&1 | tee "$LOG" | \
  grep -E "^ *(ERROR|CRITICAL)|TIMING:|raw image:|generics:" || true

bad=0
grep -qE "^ERROR" "$LOG"            && { echo " *** errors"; bad=1; }
# (the router's "did not meet timing" is not one when the recovery passes after it -- build.tcl
# -- brought the slack back: the TIMING line below is the verdict on that)
grep -E "^CRITICAL WARNING:" "$LOG" | grep -vq "\[Route 35-39\]" && { echo " *** critical warnings"; bad=1; }
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
grep -E "Slice LUTs|Block RAM Tile" "$OUT/post_route_util.rpt" | head -2
echo " cores/$NAME.bin  $((SIZE/1024)) kB"
