"""menunav.py - drive the ESP32's on-screen menu from the PC (pc/pad.py's tool port), reading
where it is from its own log lines in build/pad.log ("menu: buttons .., open|closed, level L,
item I"), so a sequence of presses does not depend on where the menu happened to be.

    python tools/menunav.py play CONSOLE_INDEX [GAME_INDEX]   open the menu, pick the console
                                                             (0 NES, 1 SMS, 2 MD, 3 N64, 4 PS1),
                                                             then the game; wait for the load
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from toolpad import press, START, SELECT, CROSS, CIRCLE, UP, DOWN, LEFT  # noqa: E402

LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'build', 'pad.log')
PAT = re.compile(r'menu: buttons \w+ \(new \w+\), (open|closed), level (\d+), item (\d+)')


def state():
    """the menu's state as the last press found it: (open, level, item)"""
    for line in reversed(open(LOG, errors='replace').read().splitlines()):
        m = PAT.search(line)
        if m:
            return m.group(1) == 'open', int(m.group(2)), int(m.group(3))
    return None


def probe():
    press(LEFT, gap=0.5)                     # (harmless anywhere: a page up)
    return state()


def play(console, game=0, timeout=240):
    s = probe()
    if not s or not s[0]:
        press(START | SELECT, hold=0.3, gap=1.0)
        s = probe()
    if not s or not s[0]:
        raise RuntimeError('the menu did not open (%r)' % (s,))
    if s[1] != 0:
        press(CIRCLE, gap=0.6)               # (back to the consoles)
        s = probe()
    for _ in range(4):                       # LEFT pages up: the first console
        if s[2] == 0:
            break
        s = probe()
    for _ in range(console):
        press(DOWN, gap=0.3)
    s = probe() if False else state()
    mark = os.path.getsize(LOG)
    press(CROSS, gap=1.0)
    for _ in range(game):
        press(DOWN, gap=0.3)
    press(CROSS, gap=1.0)
    t0 = time.time()
    while time.time() - t0 < timeout:
        new = open(LOG, 'rb').read()[mark:].decode(errors='replace')   # (bytes: the log has CRLFs)
        if 'menu: loaded' in new:
            return [l for l in new.splitlines() if 'menu: loaded' in l][-1]
        if 'did not' in new or 'failed' in new:
            raise RuntimeError(new[-300:])
        time.sleep(1)
    raise RuntimeError('no load within %d s' % timeout)


if __name__ == '__main__':
    if sys.argv[1] == 'play':
        print(play(int(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 0))
