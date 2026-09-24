#!/usr/bin/env bash
# Build and program the console. The one command that is always the right one.
#
#   ./tools/board.sh build     synthesise, place, route, bitstream
#   ./tools/board.sh prog      program the board over JTAG
#   ./tools/board.sh all       both
#
# It exists because the build needs a top module AND a constraints file, and
# forgetting the second one does not fail early: synthesis, placement and
# routing all succeed, and only the bitstream writer notices that nine pins
# were never assigned. That is four minutes to find out something that should
# have taken none.
set -e
cd "$(dirname "$0")/.."

TOP=eth_top
XDC=boards/qmtech_a100t/eth_top.xdc
BIT=build/$TOP/$TOP.bit

build() {
  tools/vivado.sh build -top "$TOP" -xdc "$XDC" 2>&1 | tee build/board.log | \
    grep -E "^ *(ERROR|CRITICAL)|TIMING:|Slice LUTs|Block RAM Tile|write_bitstream" || true

  # The three things that are errors even when Vivado says otherwise.
  local bad=0
  grep -qE "^ERROR" build/board.log && { echo " *** errors"; bad=1; }
  grep -qE "^CRITICAL WARNING:" build/board.log && { echo " *** critical warnings"; bad=1; }
  grep -qi "multi-driven" build/board.log && { echo " *** multi-driven nets"; bad=1; }
  [ -f "$BIT" ] || { echo " *** no bitstream"; bad=1; }
  [ $bad -eq 0 ] || exit 1

  grep -E "Slice LUTs|Block RAM Tile|Slice Registers" build/$TOP/post_route_util.rpt \
    2>/dev/null | head -4 || true
  echo "ok: $BIT"
}

case "${1:-all}" in
  build) build ;;
  prog)  tools/vivado.sh prog "$BIT" ;;
  all)   build; tools/vivado.sh prog "$BIT" ;;
  *)     echo "usage: tools/board.sh [build|prog|all]" >&2; exit 1 ;;
esac
