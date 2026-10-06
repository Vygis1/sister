#!/usr/bin/env bash
# A bench for a module still in rtl/wip/ (kept out of rtl/ so the builds and every other
# bench, which take all of rtl/*.v, never see it half-written):
#
#   ./tools/simwip.sh tb_w65816 [PLUSARG=value ...]
#
# compiles rtl/wip/*.v and sim/TB.v only, and runs it in build/sim-TB.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TB="$1"; shift || true
if [ -z "$VIVADO_BIN" ]; then
  for c in /c/AMDDesignTools/*/Vivado/bin /c/Xilinx/Vivado/*/bin; do
    [ -d "$c" ] && VIVADO_BIN="$c" && break
  done
fi
XVLOG="$VIVADO_BIN/xvlog.bat"; XELAB="$VIVADO_BIN/xelab.bat"; XSIM="$VIVADO_BIN/xsim.bat"
OUT="$ROOT/build/sim-$TB"
mkdir -p "$OUT"; cd "$OUT"
"$XVLOG" --nolog "$ROOT"/rtl/wip/w65816.v "$ROOT"/rtl/wip/spc700.v "$ROOT"/rtl/wip/snes_*.v "$ROOT/sim/$TB.v" > xvlog.log 2>&1 || { cat xvlog.log; exit 1; }
"$XELAB" --nolog -debug off -s "$TB"_snap "$TB" > xelab.log 2>&1 || { cat xelab.log; exit 1; }
PLUS=""; for a in "$@"; do PLUS="$PLUS --testplusarg $a"; done
"$XSIM" --nolog "$TB"_snap -R $PLUS > run.log 2>&1 || { cat run.log; exit 1; }
grep -vE '^(#|\s*$)' run.log | grep -viE 'xsim|vivado simulator|copyright|^Time resolution' || true
grep -q "all checks passed" run.log
