#!/bin/sh
# Run a command in its own window instead of in a terminal nobody is watching.
#
#   ./tools/win.sh "flash the board" python tools/ps1flash.py
#   ./tools/win.sh --also build/core_ps1.log "build" ./tools/core.sh ps1
#
# The command goes into a temp script and bash is handed the script. Passing it
# as a quoted -c string did not survive `start`: bash got the pieces as separate
# arguments, complained "cd: too many arguments", and ran something else.
#
# --also FILE additionally tails FILE into the same window, which is what makes
# it useful for core.sh and sim.sh -- they say almost nothing on stdout and put
# the part you want to watch in a log.
ALSO=""
if [ "$1" = "--also" ]; then ALSO="$2"; shift 2; fi
[ $# -ge 2 ] || { echo "usage: win.sh [--also FILE] <title> <command...>" >&2; exit 2; }
TITLE="$1"; shift
SLUG=$(printf '%s' "$TITLE" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//' | cut -c1-40)

# The repo is wherever this script is; WROOT is the same place spelled for
# Windows programs (C:/...), which is what pythonw and start want.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WROOT=$(cygpath -m "$ROOT" 2>/dev/null || echo "$ROOT")
mkdir -p "$ROOT/build/console"
SCRIPT="build/console/$SLUG.cmd.sh"
# PYTHONUNBUFFERED, or a python command writing to a pipe buffers its output
# and the window sits empty until the command ends -- which is exactly the
# stretch you wanted to watch.
{ echo '#!/bin/sh'; echo "cd '$ROOT' || exit 1"; echo 'export PYTHONUNBUFFERED=1'
  echo "exec $*"; } > "$ROOT/$SCRIPT"
chmod +x "$ROOT/$SCRIPT"

BASH_EXE=$(cygpath -w "$(command -v bash)" 2>/dev/null || command -v bash)
if [ -n "$ALSO" ]; then
	start //B pythonw "$WROOT/tools/console.py" "$TITLE" --also "$ALSO" -- "$BASH_EXE" "$WROOT/$SCRIPT"
else
	start //B pythonw "$WROOT/tools/console.py" "$TITLE" -- "$BASH_EXE" "$WROOT/$SCRIPT"
fi
echo "$WROOT/build/console/$SLUG.log"
