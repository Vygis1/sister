"""menunav.py - drive the ESP32's on-screen menu from the PC (tools/pad.py's tool port), reading
where it is from its own log lines in build/pad.log ("menu: buttons .., open|closed, level L,
item I [the highlighted item]", written once a press has done its work), so a sequence of
presses does not depend on where the menu happened to be.

    python tools/menunav.py play CONSOLE [GAME]   open the menu, pick the console (its name as
                                                  the menu shows it -- "Super NES" -- or 0 NES,
                                                  1 SMS, 2 MD, 3 N64, 4 PS1, 5 SNES), then the
                                                  game (its index, or the start of its name);
                                                  wait for the load
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from toolpad import press, START, SELECT, CROSS, CIRCLE, UP, DOWN  # noqa: E402

LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'build', 'pad.log')
PAT = re.compile(r'menu: buttons \w+ \(new \w+\), (open|closed), level (\d+), item (\d+)(?: \[(.*)\])?')
NAMES = ['NES', 'Master System', 'Mega Drive', 'Nintendo 64', 'PlayStation', 'Super NES']


def state():
    """the menu's state after the last press: (open, level, item, text)"""
    for line in reversed(open(LOG, errors='replace').read().splitlines()):
        if 'menu: loaded' in line:          # (a load closes the menu)
            return False, 0, 0, ''
        m = PAT.search(line)
        if m:
            return m.group(1) == 'open', int(m.group(2)), int(m.group(3)), m.group(4) or ''
    return None


def step(bits, gap=0.35):
    """a press, then the state it left (its log line, once written)"""
    n = len(open(LOG, 'rb').read())
    press(bits, gap=gap)
    t0 = time.time()
    while time.time() - t0 < 3:
        if len(open(LOG, 'rb').read()) > n and PAT.search(open(LOG, 'rb').read()[n:].decode(errors='replace')):
            break
        time.sleep(0.05)
    return state()


def find(want, limit=400):
    """move down the list until the highlighted item starts with want"""
    s = step(DOWN)
    for _ in range(limit):
        if s and s[3].lower().startswith(want.lower()):
            return s
        s = step(DOWN)
    raise RuntimeError('no item "%s" in the menu' % want)


def play(console, game=0, timeout=240):
    if isinstance(console, int) or str(console).isdigit():
        console = NAMES[int(console)]
    s = state()
    if not s or not s[0]:
        s = step(START | SELECT, gap=1.0)
    if not s or not s[0]:
        raise RuntimeError('the menu did not open (%r)' % (s,))
    for _ in range(4):                       # back to the consoles
        if s[1] == 0:
            break
        s = step(CIRCLE, gap=0.6)
    find(console)
    s = step(CROSS, gap=1.0)
    if s[1] != 1:
        raise RuntimeError('not in the games list (%r)' % (s,))
    mark = os.path.getsize(LOG)
    if isinstance(game, str) and not game.isdigit():
        if not s[3].lower().startswith(game.lower()):
            find(game)
    else:
        for _ in range(int(game)):
            step(DOWN, gap=0.25)
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
        print(play(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else 0))
