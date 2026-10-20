"""coreshots.py - each console's new image onto the card, a game started on it as the menu starts it,
and the picture it sends to the TV grabbed (tools/vgrab.py) into build/grab/<console>.png.

    python tools/coreshots.py nes gg gb          (the games: tools/coretest.py's TESTS)
    python tools/coreshots.py --keep nes         (the image already on the card: no upload)
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from bcmd import command, regs   # noqa: E402
from coretest import TESTS       # noqa: E402
from vgrab import grab           # noqa: E402


def upload(name):
    src = os.path.join(ROOT, 'cores', name + '.bin')
    for _ in range(3):
        r = subprocess.run([sys.executable, os.path.join(HERE, 'sdput.py'), src, '/cores/%s.bin' % name],
                           capture_output=True, text=True, env=dict(os.environ, MSYS_NO_PATHCONV='1'))
        if 'read back crc32' in r.stdout:
            return True
        time.sleep(3)
    return False


def main():
    a = sys.argv[1:]
    keep = '--keep' in a
    want = [x for x in a if not x.startswith('--')]
    games = dict(TESTS)
    for name in want:
        if not keep and not upload(name):
            print('%-5s upload failed' % name, flush=True)
            continue
        lines = command('play ' + games[name], 150.0)
        play = [l.strip() for l in lines if 'play:' in l]
        time.sleep(6)
        a1 = regs([0x80010])
        out = os.path.join(ROOT, 'build', 'grab', name + '.png')
        try:
            n = grab(out, 2)
            shot = '%s (%d lines)' % (out, n)
        except RuntimeError as e:
            shot = 'no picture: %s' % e
        a2 = regs([0x80010])
        fr = (a2[0] - a1[0]) & 0xFFFFFFFF if None not in (a1 + a2) else None
        print('%-5s %s | frames +%s during the grab | %s' % (name, play[0] if play else 'no answer', fr, shot), flush=True)


if __name__ == '__main__':
    main()
