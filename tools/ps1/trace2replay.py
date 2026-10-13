"""trace2replay.py - the board's GPU input trace (gp0trace.py windows, saved as "tag word" lines
with SEG markers) as GP0 words for sim/tb_ps1_replay.v: what a real game actually sent, where
DuckStation's RAM is not at hand.

    python tools/ps1/trace2replay.py build/medievil_trace.txt

Each window starts mid-command, so a window is taken from its first E1 (draw mode) word on;
the drawing area / offset (E3, E4, E5) first seen anywhere are put in front, so the clipping
is the game's. GP1 writes and the DMA's node headers are not GP0 words and are left out.
"""
import os, sys
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
segs, cur = [], []
for line in open(sys.argv[1]):
    if line.startswith('SEG'):
        if cur: segs.append(cur)
        cur = []; continue
    tag, w = line.split(); tag = int(tag); w = int(w, 16)
    if tag in (0, 1): cur.append(w)
if cur: segs.append(cur)
env = {}
for s in segs:
    for w in s:
        op = w >> 24
        if op in (0xE3, 0xE4, 0xE5) and op not in env: env[op] = w
words = [env[k] for k in sorted(env)]

def length(s, i):
    """how many words the GP0 command at s[i] takes, or 0 for one the bench cannot replay"""
    w = s[i]; op = w >> 24
    if 0x20 <= op <= 0x3F:
        nv = 4 if op & 8 else 3; per = 1 + (1 if op & 4 else 0) + (1 if op & 0x10 else 0)
        return 1 + nv * per - (1 if op & 0x10 else 0)
    if 0x60 <= op <= 0x7F:
        return 2 + (1 if op & 4 else 0) + (1 if ((op >> 3) & 3) == 0 else 0)
    if 0x40 <= op <= 0x5F:
        if op & 8:
            k = i + (3 if op & 0x10 else 2)
            while k < len(s) and (s[k] & 0xF000F000) != 0x50005000: k += 1
            return k + 1 - i
        return 4 if op & 0x10 else 3
    if op == 0xA0:
        if i + 3 > len(s): return 3
        w_ = s[i + 2] & 0xFFFF; h = s[i + 2] >> 16
        return 3 + (w_ * h + 1) // 2
    if op == 0x02: return 3
    if op == 0x80: return 4
    if op == 0xC0: return 0                      # a VRAM read: its words would never be collected
    if op == 0x00 or op == 0x01 or op == 0x03 or 0xE1 <= op <= 0xE6 or 0x04 <= op <= 0x1E: return 1
    return 0

def clean(s, start):
    """the window from `start`, parsed command by command; True if every command is a known one"""
    i = start
    while i < len(s):
        n = length(s, i)
        if n == 0: return False
        i += n
    return True

used = 0; dropped = 0
for s in segs:
    # the first start, up to 24 words in, from which the whole window parses as known commands
    # (a window begins mid-command, and a data word can look like E1)
    start = next((k for k in range(min(24, len(s))) if clean(s, k)), None)
    if start is None: dropped += 1; continue
    # a VRAM read (C0) the bench cannot answer, and a window that ends mid-command, are cut
    i = start; keep = []
    while i < len(s):
        n = length(s, i)
        if n == 0 or i + n > len(s): break
        if (s[i] >> 24) != 0xC0: keep += s[i:i + n]
        i += n
    words += keep; used += 1
print('%d windows dropped (no clean start)' % dropped)
out = os.path.join(ROOT, 'sim', 'roms', 'ps1', 'replay.hex')
open(out, 'w').write('%08x\n' % len(words) + ''.join('%08x\n' % w for w in words))
print('%d words from %d of %d windows (E3/E4/E5: %s) -> %s' % (len(words), used, len(segs), ' '.join('%08x' % v for v in words[:len(env)]), out))
