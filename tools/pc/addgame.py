"""addgame.py - a DOS game onto the console's SD card, for the PC core: one command, and it is in the
menu (PC -> its name) like a console's ROM.

    python tools/pc/addgame.py "C:/Users/me/Downloads/Rayman (1995).zip"        (to E:/ if the card is there)
    python tools/pc/addgame.py <game.zip | game folder> [--name NAME] [--run "CD X|GAME.EXE"] [--out DIR]
    python tools/pc/addgame.py --dos                                            (FreeDOS alone: a DOS prompt)

What goes on the card, in /roms/pc/:
    NAME.img   a bootable hard disk: FreeDOS (HIMEMX, the CD-ROM driver and SHSUCDX when there is a CD) and
               the game, started from AUTOEXEC.BAT
    NAME.cfg   the core's configuration for it (tools/pc/pccfg.py)
    NAME.cue   the game's CD, if it has one, with its .bin file(s) as NAME.bin (NAME-2.bin ...) -- the
               firmware puts it in the CD-ROM drive (D:) when NAME.img starts

The game: a zip of one game folder, or the folder itself. The folder is C:\\ when it
holds the game's own folder(s) and a start .BAT (Rayman: RAYMAN\\, RAYMAN.BAT, cd\\); otherwise it is the
game's folder and becomes C:\\<it> (Doom: DOOM\\DOOM.EXE). The start is the .BAT, else the .EXE named
like the folder, else --run. The Sound Blaster is DOSBox's (220h, IRQ 7, DMA 1): the packs' own setup
files are right as they come.

Runs mkdisk.sh in WSL (nasm, mtools, sfdisk, mkfs.fat -- see tools/pc/mkdisk.sh).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CYL_BYTES = 16 * 63 * 512                  # a cylinder: 16 heads x 63 sectors
NOT_STARTS = {'INSTALL', 'SETUP', 'NETWORK', 'CONFIG', 'UNINSTAL', 'IPXSETUP', 'SERSETUP', 'MODEM'}


def wsl_path(p):
    p = os.path.abspath(p).replace('\\', '/')
    return '/mnt/' + p[0].lower() + p[2:] if re.match(r'^[A-Za-z]:', p) else p


def card_root():
    for d in 'EFGHIJKLMNOPQRSTUVWXYZ':
        if os.path.isdir(d + ':/roms') and os.path.isdir(d + ':/cores'):
            return d + ':/'
    return None


def tree_size(d):
    return sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(d) for f in fs)


def unpack(src, work):
    """the pack's folder, unpacked (a zip) or as it is (a folder)"""
    if os.path.isdir(src):
        return src
    with zipfile.ZipFile(src) as z:
        z.extractall(work)
    tops = [e for e in os.listdir(work) if not e.startswith('__MACOSX')]
    return os.path.join(work, tops[0]) if len(tops) == 1 and os.path.isdir(os.path.join(work, tops[0])) else work


def layout(top, run):
    """(the folder whose contents are C:\\ , the AUTOEXEC lines that start the game, the cue sheet or None)"""
    entries = os.listdir(top)
    cue = None
    for sub in entries:
        if sub.lower() in ('cd', 'cdrom', 'cds') and os.path.isdir(os.path.join(top, sub)):
            files = sorted(os.listdir(os.path.join(top, sub)))
            cues = [f for f in files if f.lower().endswith('.cue')]
            isos = [f for f in files if f.lower().endswith('.iso')]
            if cues:
                cue = os.path.join(top, sub, cues[0])
            elif isos:
                # an ISO: a cue sheet for it, one data track of 2048-byte sectors
                cue = os.path.join(top, sub, os.path.splitext(isos[0])[0] + '.cue')
                with open(cue, 'w', newline='\r\n') as f:
                    f.write('FILE "%s" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n' % isos[0])
    execs = [e for e in entries if e.upper().endswith(('.EXE', '.COM'))]
    # (a folder holding the game's own folder -- a subfolder with programs in it -- is C:\ even with a
    # utility or two beside it: a pack's ASKECHO.COM next to TTD's TTDLX\)
    def has_progs(d):
        try: return any(f.upper().endswith(('.EXE', '.COM')) for f in os.listdir(d))
        except OSError: return False
    if any(os.path.isdir(os.path.join(top, e)) and e.lower() not in ('cd', 'cdrom', 'cds') and has_progs(os.path.join(top, e))
           for e in entries):
        execs = []
    bats = [e for e in entries if e.upper().endswith('.BAT') and os.path.splitext(e)[0].upper() not in NOT_STARTS]
    stage = tempfile.mkdtemp(prefix='pcgame_')
    if execs:
        # the game's own folder: C:\<NAME>
        name = re.sub(r'[^A-Z0-9_]', '', os.path.basename(top).upper())[:8] or 'GAME'
        shutil.copytree(top, os.path.join(stage, name), ignore=shutil.ignore_patterns('*.exo'))
        if not run:
            base = os.path.basename(top).upper()
            # (the pack's own start, a START.BAT or a .BAT named like the folder, before a guessed .EXE)
            own = [e for e in bats if os.path.splitext(e)[0].upper() in ('START', base[:8])]
            if own:
                run = 'CD \\%s|CALL %s' % (name, own[0].upper())
        if not run:
            base = os.path.basename(top).upper()
            pick = [e for e in execs if os.path.splitext(e)[0].upper() == base[:8]] or \
                   [e for e in execs if e.upper().endswith('.EXE') and os.path.splitext(e)[0].upper() not in NOT_STARTS]
            if not pick:
                sys.exit('no start found in %s: give --run' % top)
            run = 'CD \\%s|%s' % (name, os.path.splitext(pick[0])[0].upper())
    else:
        # C:\ itself: the pack's folder(s) and its start .BAT; not the CD (it goes in the drive)
        for e in entries:
            s = os.path.join(top, e)
            if e.lower().endswith('.exo') or (cue and os.path.abspath(s) == os.path.dirname(os.path.abspath(cue))):
                continue
            (shutil.copytree if os.path.isdir(s) else shutil.copy2)(s, os.path.join(stage, e))
        if not run:
            if not bats:
                sys.exit('no start .BAT in %s: give --run' % top)
            run = 'CALL C:\\%s' % bats[0].upper()
    drop_temp_copies(stage)
    return stage, run, cue


def drop_temp_copies(stage):
    """MicroProse's CD games (Transport Tycoon Deluxe) keep a FILES.TMP: the files they copied from the CD
    on their last start. At every start the game deletes those and copies them again -- 6.7 MB for TTD,
    five minutes through the SD card. A pack holds the copies already, so the list goes: with no
    FILES.TMP the game uses the files it finds (TTD then starts in 24 s instead of ~5 min)."""
    for d, _, files in os.walk(stage):
        for f in files:
            if f.upper() != 'FILES.TMP':
                continue
            p = os.path.join(d, f)
            names = [n.decode('ascii', 'replace') for n in open(p, 'rb').read().split(b'\0') if n]
            have = {x.upper() for x in files}
            if names and all(n.upper() in have for n in names):
                os.remove(p)
                print('dropped %s (its %d files are all there already)' % (os.path.relpath(p, stage), len(names)))


def copy_cue(cue, out_dir, name):
    """the cue sheet as NAME.cue, its bin files as NAME.bin (NAME-2.bin ...), the FILE lines to match"""
    src_dir = os.path.dirname(cue)
    text = open(cue, encoding='latin-1').read()
    files = re.findall(r'(?im)^\s*FILE\s+"?([^"\r\n]+?)"?\s+(BINARY|MOTOROLA|WAVE|MP3)\s*$', text)
    renamed = {}
    for i, (f, _) in enumerate(files):
        if f in renamed:
            continue
        new = '%s%s%s' % (name, '' if not renamed else '-%d' % (len(renamed) + 1), os.path.splitext(f)[1].lower())
        renamed[f] = new
        src = os.path.join(src_dir, f)
        if not os.path.exists(src):           # (case differences)
            m = [g for g in os.listdir(src_dir) if g.lower() == f.lower()]
            src = os.path.join(src_dir, m[0]) if m else src
        print('  %s -> %s (%d MB)' % (os.path.basename(src), new, os.path.getsize(src) >> 20))
        shutil.copyfile(src, os.path.join(out_dir, new))
    for f, new in renamed.items():
        text = re.sub(r'(?im)^(\s*FILE\s+)"?%s"?' % re.escape(f), lambda m: '%s"%s"' % (m.group(1), new), text)
    with open(os.path.join(out_dir, name + '.cue'), 'w', encoding='latin-1', newline='\r\n') as o:
        o.write(text.replace('\r\n', '\n'))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('game', nargs='?', help='a game zip or a game folder')
    ap.add_argument('--name', help='its name in the menu (default: the zip\'s name)')
    ap.add_argument('--run', help="the AUTOEXEC lines that start it, split at '|'")
    ap.add_argument('--out', help='the folder for it (default: <card>/roms/pc, else build/pc/games)')
    ap.add_argument('--dos', action='store_true', help='FreeDOS alone (the menu entry "FreeDOS")')
    ap.add_argument('--free', type=int, default=8, help='MB of free space on its disk for saves (default 8)')
    a = ap.parse_args()
    if not a.game and not a.dos:
        ap.error('a game, or --dos')

    card = card_root()
    out = a.out or (card + 'roms/pc' if card else os.path.join(ROOT, 'build', 'pc', 'games'))
    os.makedirs(out, exist_ok=True)
    work = tempfile.mkdtemp(prefix='pcpack_')
    try:
        if a.dos:
            name, stage, run, cue = a.name or 'FreeDOS', tempfile.mkdtemp(prefix='pcgame_'), '', None
        else:
            name = a.name or os.path.splitext(os.path.basename(a.game.rstrip('/\\')))[0]
            top = unpack(a.game, work)
            stage, run, cue = layout(top, a.run)
        size = tree_size(stage)
        cyl = max(16, -(-(size * 11 // 10 + (a.free + 2) * 1024 * 1024) // CYL_BYTES))
        if cyl > 1024:
            sys.exit('%s: %d MB is past what DOS reaches by cylinders (504 MB)' % (name, size >> 20))
        img = os.path.join(ROOT, 'build', 'pc', 'games', name + '.img')
        os.makedirs(os.path.dirname(img), exist_ok=True)
        print('%s: %d MB of game, a %d MB disk (%d cylinders)%s; start: %s' %
              (name, size >> 20, cyl * CYL_BYTES >> 20, cyl, ', a CD' if cue else '', run or '(a DOS prompt)'))
        # (the command in a file: wsl.exe's own quoting of an argument mangles the quotes and backslashes)
        sh = os.path.join(work, 'mk.sh')
        with open(sh, 'w', newline='\n') as f:
            f.write('export GAME=any CYL=%d CD=%d RUN=%s\n' % (cyl, 1 if cue else 0, shlex_quote(run)))
            f.write('bash %s %s %s\n' % (shlex_quote(wsl_path(os.path.join(ROOT, 'tools', 'pc', 'mkdisk.sh'))),
                                         shlex_quote(wsl_path(img)), shlex_quote(wsl_path(stage))))
        r = subprocess.run(['wsl', '-d', 'Ubuntu', '--', 'bash', wsl_path(sh)], capture_output=True, text=True)
        if r.returncode:
            sys.exit('mkdisk.sh failed:\n' + r.stdout + r.stderr)
        subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'pc', 'pccfg.py'), img], check=True)
        cfg = os.path.splitext(img)[0] + '.cfg'
        for f in (img, cfg):
            dst = os.path.join(out, os.path.basename(f))
            if os.path.abspath(dst) != os.path.abspath(f):
                shutil.copyfile(f, dst)
        if cue:
            copy_cue(cue, out, name)
        print('%s -> %s' % (name, out))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def shlex_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


if __name__ == '__main__':
    main()
