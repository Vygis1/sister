#!/bin/bash
# mkdisk.sh - the PC core's hard disk: a 64 MB image with an MBR, one active FAT16 partition,
# FreeDOS (kernel 2043 + FreeCOM, both GPL) and Doom. Runs in WSL (nasm, sfdisk, mkfs.fat, mtools).
#
#   wsl bash tools/pc/mkdisk.sh build/pc/doom.img build/dl/doom/DOOM [autostart]
#   GAME=rayman CYL=260 CD=1 wsl bash tools/pc/mkdisk.sh build/pc/rayman.img build/dl/rayman/Rayman/RAYMAN auto
#
# GAME: doom (the default) or rayman -- the second argument is the game's folder. CD=1 adds the CD-ROM
# drive's DOS side: UDVD2.SYS (the ATAPI driver) and SHSUCDX (FreeDOS's MSCDEX), the drive as D: --
# the drive itself is the ESP32's (esp32/console/cdrom.h), the disc /roms/pc/<image name>.cue.
#
# The geometry is 130 cylinders x 16 heads x 63 sectors -- what the BIOS's translation and the
# IDE identify data both say (tools/pc/pccfg.py reads it back out of the partition table).
# FreeDOS's own FAT16 boot sector (boot/boot.asm, assembled here) goes over mkfs.fat's, keeping
# the BPB mkfs.fat wrote: what FreeDOS's SYS does.
set -e
OUT=$(realpath -m "$1"); DOOM=$(realpath "$2"); AUTO=${3:-}
GAME=${GAME:-doom}; CD=${CD:-0}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FD=$ROOT/build/dl/fdos
CYL=${CYL:-32}; HEADS=16; SPT=63   # (ATA: 16 heads at most -- the IDE holds 5 bits of it; 32 x 16 x 63 is the whole image)
SECT=$((CYL * HEADS * SPT)); START=$SPT; PSECT=$((SECT - START))
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

nasm -dISFAT16 -o "$W/fat16.bin" "$FD/ks/SOURCE/ke2043/boot/boot.asm"
[ "$(stat -c %s "$W/fat16.bin")" = 512 ] || { echo "boot sector is not 512 bytes"; exit 1; }

mkdir -p "$(dirname "$OUT")"
dd if=/dev/zero of="$OUT" bs=512 count=$SECT status=none
printf 'label: dos\nunit: sectors\nstart=%d, size=%d, type=6, bootable\n' $START $PSECT | sfdisk -q --no-reread --no-tell-kernel "$OUT"
dd if=/usr/lib/syslinux/mbr/mbr.bin of="$OUT" bs=440 count=1 conv=notrunc status=none
# The partition's CHS fields in THIS geometry (HEADS/SPT). sfdisk, given a file, writes them for
# 255 heads; the BIOS takes its geometry from them (tools/pc/pccfg.py) and then says 2 x 255 x 63 --
# 126 sectors short of the image, and DOS, reading this partition by CHS, cannot reach them: Doom's
# WAD, copied last, ended there ("Sector not found error reading drive C", on the board).
python3 - "$OUT" $START $((SECT - 1)) $HEADS $SPT <<'PYEOF'
import sys
path, first, last, heads, spt = sys.argv[1], *map(int, sys.argv[2:])
def chs(lba):
    c, r = divmod(lba, heads * spt)
    h, s = divmod(r, spt)
    return bytes([h, (s + 1) | ((c >> 2) & 0xC0), c & 0xFF])
with open(path, 'r+b') as f:
    f.seek(0x1BE + 1); f.write(chs(first))
    f.seek(0x1BE + 5); f.write(chs(last))
PYEOF

dd if=/dev/zero of="$W/part.img" bs=512 count=$PSECT status=none
# (2 kB clusters; past 128 MB of partition FAT16 needs 4 kB: 65524 clusters at most)
CLUS=4; [ $PSECT -gt 260000 ] && CLUS=8; [ $PSECT -gt 520000 ] && CLUS=16; [ $PSECT -gt 1040000 ] && CLUS=32
mkfs.fat -F 16 -s $CLUS -S 512 -g $HEADS/$SPT -h $START -D 0x80 -n PCDISK "$W/part.img" >/dev/null
# FreeDOS's boot code: the jump (0-2) and everything after the BPB (0x3E-0x1FF); the BPB stays
dd if="$W/fat16.bin" of="$W/part.img" bs=1 count=3 conv=notrunc status=none
dd if="$W/fat16.bin" of="$W/part.img" bs=1 skip=62 seek=62 count=450 conv=notrunc status=none

export MTOOLS_SKIP_CHECK=1
P="$W/part.img"
mcopy -i "$P" "$FD/k16/bin/KERNEL.SYS" ::KERNEL.SYS          # (first: the boot sector finds it in the root)
mcopy -i "$P" "$FD/com/plainedt/command.com" ::COMMAND.COM
# HIMEMX (FreeDOS's XMS driver, GPL): DOS/4GW (Doom's extender) hangs on ao486's Bochs BIOS without
# an XMS manager -- 486Tang's own simulation stops at its banner the same way; with XMS it takes its
# memory and the A20 line through it instead of switching modes "raw"
mcopy -i "$P" "$FD/himemx/BIN/HIMEMX.EXE" ::HIMEMX.EXE
# CuteMouse (FreeDOS's mouse driver, GPL): the PS/2 mouse -- the controller's stick (pc.h, pc_top's MOUSE)
mcopy -i "$P" "$FD/cd/CTMOUSE.EXE" ::CTMOUSE.EXE
# LBACACHE (FreeDOS's disk cache, GPL; build/dl/fdos/lbacache from the FreeDOS 1.3 repository): every
# sector the PC reads crosses the ESP32 from the SD card, and a game with overlays (Transport Tycoon)
# reads the same ones over and over -- 8 MB of them in XMS
mcopy -i "$P" "$FD/lbacache/BIN/LBACACHE.COM" ::LBACACHE.COM
printf 'DEVICE=C:\\HIMEMX.EXE\r\nDOS=HIGH\r\nFILES=40\r\nBUFFERS=20\r\nLASTDRIVE=Z\r\nSHELL=C:\\COMMAND.COM C:\\ /E:1024 /P=C:\\AUTOEXEC.BAT\r\n' > "$W/fdconfig.sys"
if [ "$CD" = 1 ]; then
  # the CD-ROM drive: UDVD2 (Jack Ellis, free with sources; FreeDOS 1.3's) in PIO mode -- the drive does no
  # UltraDMA -- and SHSUCDX (Jason Hood, FreeDOS's MSCDEX) giving it the next letter, D:
  mcopy -i "$P" "$FD/cd/udvd2/BIN/UDVD2.SYS" ::UDVD2.SYS
  mcopy -i "$P" "$FD/cd/shsucdx/BIN/SHSUCDX.COM" ::SHSUCDX.COM
  printf 'DEVICE=C:\\UDVD2.SYS /D:FPGACD1 /UX\r\n' >> "$W/fdconfig.sys"
fi
mcopy -i "$P" "$W/fdconfig.sys" ::FDCONFIG.SYS
{
  printf '@ECHO OFF\r\nPROMPT $P$G\r\nPATH C:\\\r\nECHO FPGA PC - FreeDOS\r\n'
  # the Sound Blaster as DOSBox has it (the core's: 220h, IRQ 7, DMA 1, 16-bit DMA 5, an SB16)
  printf 'SET BLASTER=A220 I7 D1 H5 T6\r\n'
  printf 'C:\\CTMOUSE.EXE\r\n'
  printf 'C:\\LBACACHE.COM 8192\r\n'
  [ "$CD" = 1 ] && printf 'C:\\SHSUCDX.COM /D:FPGACD1\r\n'
  # RUN (tools/pc/addgame.py): the game's start, lines split at '|'
  if [ -n "$RUN" ]; then printf '%s' "$RUN" | tr '|' '\n' | sed 's/$/\r/'; fi
  [ -n "$CDTEST" ] && printf 'DIR D:\r\n'          # (the simulation's test: the disc's root listed)
  if [ -n "$AUTO" ] && [ "$GAME" = doom ]; then printf 'CD \\DOOM\r\nDOOM\r\nCD \\\r\n'; fi
  if [ -n "$AUTO" ] && [ "$GAME" = rayman ]; then printf 'CD \\RAYMAN\r\nRAYMAN.EXE save=C:\\RAYMAN\r\nCD \\\r\n'; fi
} > "$W/autoexec.bat"
mcopy -i "$P" "$W/autoexec.bat" ::AUTOEXEC.BAT

if [ "$GAME" = any ]; then
  # tools/pc/addgame.py: the second argument's contents are C:\, as the game's pack has them
  ( cd "$DOOM" && for f in * .[!.]*; do if [ -e "$f" ]; then mcopy -s -i "$P" "$f" ::/; fi; done )
  dd if="$P" of="$OUT" bs=512 seek=$START conv=notrunc status=none
  echo "$OUT: $SECT sectors ($CYL/$HEADS/$SPT)"
  mdir -i "$P" :: | tail -n +4
  exit 0
fi
if [ "$GAME" = rayman ]; then
  # Rayman (the game on C:, the CD for its music); its RAYMAN.CFG says Sound Blaster
  # 220h IRQ 7 DMA 1 -- byte 5 is the IRQ (220 00 00 | 07 00 00 00 | 01 ...); the core's Sound Blaster
  # is on IRQ 5 (sound.v's default)
  cp "$DOOM/RAYMAN.CFG" "$W/rayman.cfg"
  printf '\005' | dd of="$W/rayman.cfg" bs=1 seek=5 conv=notrunc status=none
  mcopy -s -i "$P" "$DOOM" ::RAYMAN
  mcopy -o -i "$P" "$W/rayman.cfg" ::RAYMAN/RAYMAN.CFG
  dd if="$P" of="$OUT" bs=512 seek=$START conv=notrunc status=none
  echo "$OUT: $SECT sectors ($CYL/$HEADS/$SPT), FreeDOS + Rayman"
  mdir -i "$P" :: | tail -n +4
  exit 0
fi
mmd -i "$P" ::DOOM
for f in DOOM.EXE DOOM.WAD SETUP.EXE; do mcopy -i "$P" "$DOOM/$f" ::DOOM/$f; done
# the config: the core's Sound Blaster (sound.v: port 220h, IRQ 5 -- its default --, DMA 1) for the
# effects and the music (its OPL3); no mouse (a pack's config says IRQ 7)
SB=${SB:-1}
if [ "$SB" = 1 ]; then SND='s/^(snd_musicdevice|snd_sfxdevice)([[:space:]]+).*/\1\23/; s/^(snd_sbport)([[:space:]]+).*/\1\2544/; s/^(snd_sbirq)([[:space:]]+).*/\1\25/; s/^(snd_sbdma)([[:space:]]+).*/\1\21/'
else SND='s/^(snd_musicdevice|snd_sfxdevice)([[:space:]]+).*/\1\20/'; fi
tr -d '\r' < "$DOOM/DEFAULT.CFG" | sed -E "$SND; s/^(use_mouse)([[:space:]]+).*/\1\20/" \
  | sed 's/$/\r/' > "$W/default.cfg"
mcopy -i "$P" "$W/default.cfg" ::DOOM/DEFAULT.CFG

dd if="$P" of="$OUT" bs=512 seek=$START conv=notrunc status=none
echo "$OUT: $SECT sectors ($CYL/$HEADS/$SPT), FreeDOS + Doom"
mdir -i "$P" :: | tail -n +4
