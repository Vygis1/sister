#!/usr/bin/env bash
# Run Vivado on this tree.
#
#   ./tools/vivado.sh check                    - is the install usable for this part?
#   ./tools/vivado.sh build                    - blink -> bitstream
#   ./tools/vivado.sh build -top mydesign      - something else -> bitstream
#   ./tools/vivado.sh build -synth 1           - synthesis only
#   ./tools/vivado.sh prog build/blink/blink.bit
#   ./tools/vivado.sh flash build/blink/blink.bit -mem <cfgmem-part>
#   ./tools/vivado.sh proj -top eth_top -run 1 - make build/proj/console.xpr
#   ./tools/vivado.sh gui build/proj/console.xpr
#   ./tools/vivado.sh gui                      - interactive Vivado
#
# Run this from Git Bash, not from msys2's sh: msys2's sh cannot launch
# vivado.bat - it returns success having run nothing, silently.
set -e
cd "$(dirname "$0")/.."

PART="${PART:-xc7a100tfgg676-1}"

if [ -z "$VIVADO" ]; then
  for c in /c/AMDDesignTools/*/Vivado/bin/vivado.bat \
           /c/Xilinx/Vivado/*/bin/vivado.bat \
           /d/AMDDesignTools/*/Vivado/bin/vivado.bat; do
    [ -f "$c" ] && VIVADO="$c" && break
  done
fi
if [ -z "$VIVADO" ] || [ ! -f "$VIVADO" ]; then
  echo "Vivado not found. Set VIVADO=/path/to/vivado.bat" >&2
  exit 1
fi

mkdir -p build
echo "vivado: $VIVADO"
echo "part:   $PART"
echo

cmd="${1:-build}"; shift || true
case "$cmd" in
  check) exec "$VIVADO" -mode batch -source tools/check.tcl -nojournal -nolog \
                 -tclargs -part "$PART" "$@" ;;
  build) exec "$VIVADO" -mode batch -source tools/build.tcl -nojournal -nolog \
                 -tclargs -part "$PART" "$@" ;;
  prog)  bit="$1"; shift || true
         exec "$VIVADO" -mode batch -source tools/program.tcl -nojournal -nolog \
                 -tclargs -bit "$bit" "$@" ;;
  flash) bit="$1"; shift || true
         exec "$VIVADO" -mode batch -source tools/program.tcl -nojournal -nolog \
                 -tclargs -bit "$bit" -flash 1 "$@" ;;
  proj)  exec "$VIVADO" -mode batch -source tools/project.tcl -nojournal -nolog                  -tclargs -part "$PART" "$@" ;;
  mig)   python tools/migpins.py || exit 1
         exec "$VIVADO" -mode batch -source tools/mig.tcl -nojournal -nolog "$@" ;;
  gui)   exec "$VIVADO" -mode gui "$@" ;;
  *) echo "usage: $0 [check|build|prog|flash|proj|mig|gui] [args]" >&2; exit 2 ;;
esac
