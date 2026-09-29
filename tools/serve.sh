#!/usr/bin/env bash
# Start the web server, and make sure it is the ONLY one.
#
#   ./tools/serve.sh [target-ip]        default $FPGA_HOST, else 192.168.178.50
#
# This exists because `pkill -f` does not match Windows processes from Git Bash:
# it reports success, kills nothing, and the old server keeps port 8080. The
# result is a page served by code from before your last edit, which looks
# exactly like your edit not working. Twice was enough.
set -e
cd "$(dirname "$0")/.."
TARGET="${1:-${FPGA_HOST:-192.168.178.50}}"

powershell.exe -NoProfile -Command "
  Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" |
    Where-Object { \$_.CommandLine -like '*server.py*' } |
    ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }
" >/dev/null 2>&1 || true

sleep 2
mkdir -p build
nohup python pc/server.py --target "$TARGET" > build/server.log 2>&1 &
sleep 4

left=$(powershell.exe -NoProfile -Command "
  (Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" |
    Where-Object { \$_.CommandLine -like '*server.py*' }).Count" | tr -d '\r ')
echo "server.py processes running: $left (expect 1)"
tail -2 build/server.log
