"""A small XA-ADPCM encoder, for making test discs.

    python tools/ps1/xaenc.py --selftest     encode tones, decode them with tools/ps1/cdaudio.py, measure

Encodes 37.8 kHz (or 18.9 kHz) stereo/mono 4-bit XA sectors: per 28-sample
block it tries every filter and shift and keeps the one that decodes closest,
tracking the decoder's own history so errors do not accumulate. It is slow and
exact rather than fast and clever -- it exists to produce known audio for the
drive model and the decoder, not to master anything.
"""
import math
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdaudio import XaDecoder, _POS, _NEG   # noqa: E402

SECTOR = 2352


def _enc_block(samples, prev):
    """28 samples -> (header byte, 28 nibbles), choosing the best filter and shift."""
    best = None
    for flt in range(4):
        for shift in range(13):
            p0, p1 = prev
            nibs = []
            err = 0
            for x in samples:
                pred = ((p0 * _POS[flt]) >> 6) + ((p1 * _NEG[flt]) >> 6)
                # the nibble whose decode lands nearest x
                want = (x - pred) << shift
                n = int(round(want / 4096.0))
                n = -8 if n < -8 else 7 if n > 7 else n
                s = ((n & 0xF) << 12) & 0xFFFF
                if s & 0x8000:
                    s -= 0x10000
                v = (s >> shift) + pred
                v = -32768 if v < -32768 else 32767 if v > 32767 else v
                err += (v - x) * (v - x)
                p1, p0 = p0, v
                nibs.append(n & 0xF)
                if best is not None and err >= best[0]:
                    break
            else:
                if best is None or err < best[0]:
                    best = (err, (flt << 4) | shift, nibs, (p0, p1))
    return best[1], best[2], best[3]


def encode_sector(frames, lba, file=1, chan=1, stereo=True, eof=False):
    """frames: 2016 stereo (or 4032 mono) int samples -> one 2352-byte XA sector"""
    sec = bytearray(SECTOR)
    sec[1:11] = b"\xff" * 10
    a = lba + 150
    bcd = lambda v: ((v // 10) << 4) | (v % 10)
    sec[12], sec[13], sec[14], sec[15] = bcd(a // 4500), bcd((a // 75) % 60), bcd(a % 75), 2
    sub = bytes([file, chan, 0x64 | (0x80 if eof else 0), 0x01 if stereo else 0x00])
    sec[16:20] = sub
    sec[20:24] = sub
    prev = [[0, 0], [0, 0]]
    for ci in range(18):
        ch = bytearray(128)
        words = [0] * 28
        for blk in range(8):
            if stereo:
                c = blk & 1
                start = ci * 112 + (blk // 2) * 28
                samples = [int(frames[start + i][c]) for i in range(28)]
                pv = prev[c]
            else:
                start = ci * 224 + blk * 28
                samples = [int(frames[start + i]) for i in range(28)]
                pv = prev[0]
            hdr, nibs, newprev = _enc_block(samples, tuple(pv))
            pv[0], pv[1] = newprev
            ch[4 + blk] = hdr
            for w in range(28):
                words[w] |= nibs[w] << (blk * 4)
        ch[0:4] = ch[4:8]
        ch[12:16] = ch[8:12]
        ch[16:128] = struct.pack("<28I", *words)
        sec[24 + ci * 128: 24 + ci * 128 + 128] = ch
    return bytes(sec)


def tones(n, f_l, f_r, rate=37800, amp=12000, start=0):
    t = np.arange(start, start + n) / rate
    return np.stack([amp * np.sin(2 * math.pi * f_l * t), amp * np.sin(2 * math.pi * f_r * t)], axis=1).astype(np.int64)


def selftest():
    dec = XaDecoder()
    out = []
    for k in range(6):
        fr = tones(2016, 1000, 500, start=k * 2016)
        out.append(dec.decode(encode_sector(fr, 500 + k)))
    o = np.concatenate(out).astype(np.float64)
    print("decoded %d samples at 44.1 kHz from %d XA sectors (%d at 37.8 kHz)" % (len(o), 6, 6 * 2016))
    want = 6 * 2016 * 44100 // 37800
    ok = abs(len(o) - want) <= 7
    for c, f in ((0, 1000), (1, 500)):
        x = o[2000:, c]
        spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
        peak = np.argmax(spec) * 44100 / len(x)
        rms = math.sqrt(np.mean(x * x))
        print("  channel %d: peak at %.1f Hz (want %d), rms %.0f (a sine of 12000 is %.0f)" % (c, peak, f, rms, 12000 / math.sqrt(2)))
        ok &= abs(peak - f) < 5 and 0.85 < rms / (12000 / math.sqrt(2)) < 1.15
    print("xaenc selftest:", "PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(0 if selftest() else 1)
    print(__doc__)
