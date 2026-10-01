"""Test discs for the PlayStation's CD audio.

    python tools/mktestdisc.py audio  OUTDIR   an audio CD: an MP3 track and a WAV track, as a .cue
    python tools/mktestdisc.py xa     OUTDIR   a data track of XA-ADPCM (eight interleaved channels,
                                               each its own tone) plus an MP3 audio track, as a .cue

The audio CD is for the BIOS's own CD player: it reads the table of contents,
plays the tracks and shows the time from report mode. The XA disc is for
tools/ps1cdtest.py, a program run in place of the BIOS that plays one XA
channel and then the audio track.

Tones, so what comes out of the console can be checked by frequency:
    audio CD    track 1: 440 Hz left, 660 Hz right (MP3); track 2: 330 Hz both (WAV)
    XA disc     channel k: 400 + 100*k Hz; track 2: 880 Hz (MP3)
"""
import math
import os
import struct
import sys
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def tone(seconds, fl, fr, rate=44100, amp=9000):
    t = np.arange(int(seconds * rate)) / rate
    l = amp * np.sin(2 * math.pi * fl * t)
    r = amp * np.sin(2 * math.pi * fr * t)
    return np.stack([l, r], axis=1).astype(np.int16)


def write_mp3(path, pcm, rate=44100):
    import lameenc
    enc = lameenc.Encoder()
    enc.set_bit_rate(192); enc.set_in_sample_rate(rate); enc.set_channels(2); enc.set_quality(2)
    data = enc.encode(pcm.tobytes()) + enc.flush()
    open(path, "wb").write(data)


def write_wav(path, pcm, rate=44100):
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(pcm.tobytes())


def audio_cd(out):
    os.makedirs(out, exist_ok=True)
    write_mp3(os.path.join(out, "track01.mp3"), tone(20, 440, 660))
    write_wav(os.path.join(out, "track02.wav"), tone(20, 330, 330))
    with open(os.path.join(out, "audiocd.cue"), "w") as f:
        f.write('FILE "track01.mp3" MP3\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n'
                'FILE "track02.wav" WAVE\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n')
    print("audio CD in", out)


XA_START = 1000          # LBA of the first XA sector in the data track
XA_SECTORS = 8 * 100     # eight channels, interleaved: a hundred sectors each (5.3 s at double speed)


def xa_disc(out):
    import xaenc
    os.makedirs(out, exist_ok=True)
    n = XA_START + XA_SECTORS + 64
    data = bytearray(n * 2352)
    bcd = lambda v: ((v // 10) << 4) | (v % 10)
    # plain Mode 2 data sectors everywhere, with real headers
    for lba in range(n):
        o = lba * 2352
        a = lba + 150
        data[o + 1:o + 11] = b"\xff" * 10
        data[o + 12:o + 16] = bytes([bcd(a // 4500), bcd((a // 75) % 60), bcd(a % 75), 2])
        data[o + 16:o + 24] = bytes([0, 0, 0x08, 0, 0, 0, 0x08, 0])
    # eight channels of XA, interleaved a sector each: channel k is LBA % 8 == k
    pos = [0] * 8
    for i in range(XA_SECTORS):
        lba = XA_START + i
        ch = i % 8
        f = 400 + 100 * ch
        fr = xaenc.tones(2016, f, f, start=pos[ch])
        pos[ch] += 2016
        data[lba * 2352:(lba + 1) * 2352] = xaenc.encode_sector(fr, lba, file=1, chan=ch)
    open(os.path.join(out, "xadisc.bin"), "wb").write(data)
    write_mp3(os.path.join(out, "track02.mp3"), tone(10, 880, 880))
    with open(os.path.join(out, "xadisc.cue"), "w") as f:
        f.write('FILE "xadisc.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n'
                'FILE "track02.mp3" MP3\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n')
    print("XA disc in", out, "-- XA from LBA", XA_START, "for", XA_SECTORS, "sectors; data track", n, "sectors")


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("audio", "xa"):
        sys.exit(__doc__)
    (audio_cd if sys.argv[1] == "audio" else xa_disc)(sys.argv[2])
