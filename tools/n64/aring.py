"""aring.py - what the board sends to HDMI as sound: the audio ring (rtl/ps1_aring.v, fed by
the PlayStation's SPU or the N64's AI, 44.1 kHz stereo) read in one piece through the
ESP32 (pc/pad.py's tool port, "D addr n"), saved as a WAV and drawn as a picture.

    python tools/n64/aring.py [OUT_PREFIX] [--count N]

The ring is 16384 samples (371 ms). It is read in one block (~60 ms), during which a few
thousand new samples overwrite its oldest: what is kept is the run that was not touched,
oldest first -- about 320 ms of contiguous sound.
"""
import os
import socket
import struct
import sys
import wave

RING, WCOUNT, SIZE = 0x00040000, 0x00030020, 0x00030018
OUT = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('--') else os.path.join('build', 'aring')
COUNT = int(sys.argv[sys.argv.index('--count') + 1]) if '--count' in sys.argv else 1


class Tool:
    def __init__(self):
        self.f = socket.create_connection(('127.0.0.1', 5557), timeout=30).makefile('rwb')

    def cmd(self, s):
        self.f.write(s.encode() + b'\n'); self.f.flush()
        return self.f.readline().decode().strip()

    def reg(self, a):
        return int(self.cmd('R %x' % a), 16)

    def block(self, a, n):
        h = self.cmd('D %x %x' % (a, n))
        return [int(h[8 * i:8 * i + 8], 16) for i in range(n)]


def s16(v):
    return v - 65536 if v & 0x8000 else v


def capture(t):
    """the ring's untouched run: the ESP32 reads it in ~60 ms (its printing takes seconds, so
    the count after is no measure); everything from 4096 samples past the cursor before on was
    written before the read began and not overwritten during it, oldest first"""
    n = t.reg(SIZE)
    w0 = t.reg(WCOUNT)
    ring = t.block(RING, n)
    start = (w0 + 4096) % n
    words = [ring[(start + i) % n] for i in range(n - 4096)]
    return [(s16(w & 0xFFFF), s16(w >> 16)) for w in words], 4096


def save(path, smp):
    with wave.open(path + '.wav', 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
        w.writeframes(b''.join(struct.pack('<hh', l, r) for l, r in smp))


def draw(path, smp, width=1600, height=400):
    """the left channel's waveform, min/max per column, and a 25 ms close-up below"""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import n64model
    img = [[(255, 255, 255)] * width for _ in range(height)]
    half = height // 2
    def plot(seg, y0, h, col):
        if not seg: return
        per = max(1, len(seg) / width)
        for x in range(width):
            a = seg[int(x * per):int((x + 1) * per) + 1] or [0]
            lo, hi = min(a), max(a)
            for v in range(lo, hi + 1, max(1, (hi - lo) // h + 1)):
                y = y0 + h // 2 - int(v * (h // 2 - 2) / 32768)
                if y0 <= y < y0 + h: img[y][x] = col
    plot([l for l, r in smp], 0, half, (0, 0, 160))
    plot([l for l, r in smp][:1102], half, half, (160, 0, 0))     # the first 25 ms
    n64model.write_png(path + '.png', width, height, bytes(c for row in img for px in row for c in px))


def main():
    t = Tool()
    for k in range(COUNT):
        smp, moved = capture(t)
        p = '%s_%d' % (OUT, k) if COUNT > 1 else OUT
        save(p, smp)
        peak = max((max(abs(l), abs(r)) for l, r in smp), default=0)
        jumps = sum(1 for i in range(1, len(smp)) if abs(smp[i][0] - smp[i - 1][0]) > 8000)
        silent = sum(1 for l, r in smp if l == 0 and r == 0)
        print('%s: %d samples (%.0f ms; %d left as a margin), peak %d, %d jumps over 8000, %d zero'
              % (p, len(smp), len(smp) / 44.1, moved, peak, jumps, silent))
        draw(p, smp)


if __name__ == '__main__':
    main()
