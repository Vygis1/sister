"""coretest.py - every console on the board, one game each: started as the menu starts it, then is it
alive? Its frame counter (console register 0x80010 -- page 8: the core's own frames) must climb and its CPU
position (0x14) must move. Not a picture check -- that needs eyes on the screen.

    python tools/coretest.py                  all of them
    python tools/coretest.py nes md           some
"""
import sys
import time

sys.path.insert(0, __file__.rsplit('\\', 1)[0].rsplit('/', 1)[0])
from bcmd import command, regs   # noqa: E402

TESTS = [
    ('nes',  '/roms/nes/Super Mario Bros. (Japan, USA).nes'),
    ('sms',  '/roms/sms/Alex Kidd in Miracle World (USA) (Rev-A).sms'),
    ('gg',   '/roms/gg/Tetris4GG.gg'),
    ('md',   '/roms/md/Combat Cars (USA, Europe).gen'),
    ('snes', '/roms/snes/Super Mario World (USA).sfc'),
    ('pce',  '/roms/pce/Bomberman 94.pce'),
    ('gba',  '/roms/gba/Celeste Classic.gba'),
    ('gb',   '/roms/gb/cgb-acid2.gbc'),
    ('a26',  '/roms/a26/test.a26'),
    ('n64',  '/roms/n64/Super Mario 64.z64'),
    ('ps1',  '/roms/ps1/Tekken 2 (USA).cue'),
    ('pc',   '/roms/pc/DOOM (1993).img'),
]


def run(name, path):
    lines = command('play ' + path, 120.0)
    play = [l for l in lines if 'play:' in l]
    loaded = [l for l in lines if 'menu: loaded' in l]
    if not play:
        return 'NO ANSWER', lines[-3:]
    if 'no ' in play[0] and 'play: no' in play[0]:
        return 'NO GAME', play
    if ' -- ' in play[0]:
        return 'LOAD ERROR', play
    time.sleep(4)
    a = regs([0x80010, 0x80014])
    time.sleep(3)
    b = regs([0x80010, 0x80014])
    if None in a or None in b:
        return 'NO REGISTERS', [str(a), str(b)]
    frames = (b[0] - a[0]) & 0xFFFFFFFF
    moved = a[1] != b[1]
    verdict = 'ALIVE' if frames > 0 and moved else 'FRAMES ONLY' if frames > 0 else 'CPU ONLY' if moved else 'DEAD'
    return verdict, ['frames +%d in 3 s, CPU %08X -> %08X' % (frames, a[1], b[1])] + loaded[:1]


if __name__ == '__main__':
    want = sys.argv[1:]
    for name, path in TESTS:
        if want and name not in want:
            continue
        v, info = run(name, path)
        print('%-5s %-12s %s' % (name, v, ' | '.join(info)), flush=True)
