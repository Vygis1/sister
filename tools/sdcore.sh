#!/usr/bin/env bash
# Put built console images on the ESP32's SD card, over its Wi-Fi (the card's /cores):
#
#   ./tools/sdcore.sh n64 ps1          cores/n64.bin, cores/ps1.bin -> /cores/
#   ./tools/sdcore.sh /c/fpga_n64/cores/n64.bin    (a path: that file, under its own name)
#
# The running game is left alone: the menu installs an image from the card when a game
# for that console is picked and the card's image is not the one in the flash slot.
# ESP_IP picks the board (default: the one on this desk's network).
set -e
cd "$(dirname "$0")/.."
IP="${ESP_IP:-192.168.178.94}"
for c in "$@"; do
  f="$c"; [ -f "$f" ] || f="cores/$c.bin"
  [ -f "$f" ] || { echo "no $f" >&2; exit 1; }
  n=$(basename "$f")
  # (Windows curl wants C:/ paths, not /c/)
  w=$(cygpath -m "$f" 2>/dev/null || echo "$f")
  printf '%s (%s kB) -> %s:/cores/%s ... ' "$f" "$(( $(stat -c %s "$f") / 1024 ))" "$IP" "$n"
  r=$(curl -s -m 900 -w ' HTTP %{http_code}' -F "file=@$w;filename=$n" "http://$IP/api/library")
  echo "$r"
  case "$r" in *"HTTP 200"*) ;; *) exit 1 ;; esac
done
