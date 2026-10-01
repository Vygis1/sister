"""CD audio on the board, end to end: XA-ADPCM and CD-DA, by frequency.

    python tools/ps1cdtest.py [build/testdiscs/xadisc/xadisc.cue]

Makes a tiny program, loads it IN PLACE OF THE BIOS (so it owns the hardware
from reset), serves the XA test disc from this PC (tools/mktestdisc.py xa), and
listens to what the console plays through the server's audio ring:

    1. Init, Demute; SPU on with CD audio in (SPUCNT C001h, CD volume 7FFFh)
    2. Setmode 2x | XA | filter, Setfilter file 1 channel 3, Setloc LBA 1000, ReadS
       -> channel 3 of eight interleaved XA channels: a 700 Hz tone
    3. after a few seconds, Pause, then Play track 2 (an MP3)
       -> 880 Hz

Each phase's recording must peak at its tone and nowhere near the others (the
other XA channels are 400..1100 Hz, so a broken filter shows up as the wrong
frequency, not as silence). Put the real BIOS back afterwards with
tools/ps1flash.py boot (or by loading it on the page).

The program's first instruction is the real BIOS's (lui t0, 0x13): the server's
keepalive compares that word to decide whether the BIOS has gone.
"""
import io
import math
import os
import struct
import sys
import time
import json
import urllib.request
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mipsasm import Asm, ZERO, T0, T1, T2, T3, T4, T5  # noqa: E402

SERVER = "http://127.0.0.1:8080"


def program(xa_channel=3, cdda_only=False):
    a = Asm(org=0xBFC00000)
    a.lui(T0, 0x0013)                 # the real BIOS's first word (see the docstring)
    a.lui(T0, 0xBF80)                 # T0 = I/O
    # the SPU: volumes, then on, unmuted, CD audio in
    a.li(T1, 0x3FFF); a.sh(T1, 0x1D80, T0); a.sh(T1, 0x1D82, T0)
    a.li(T1, 0x7FFF); a.sh(T1, 0x1DB0, T0); a.sh(T1, 0x1DB2, T0)
    a.li(T1, 0xC001); a.sh(T1, 0x1DAA, T0)

    n = [0]

    def wait_int(want):
        """poll HINTSTS until interrupt `want` arrives; acknowledge everything seen"""
        n[0] += 1
        top, got = "w%d" % n[0], "g%d" % n[0]
        a.label(top)
        a.li(T1, 1); a.sb(T1, 0x1800, T0)                 # index 1
        a.lbu(T2, 0x1803, T0); a.nop()                   # the load delay slot
        a.andi(T2, T2, 7)
        a.beq(T2, ZERO, top); a.nop()
        a.li(T1, 0x07); a.sb(T1, 0x1803, T0)              # acknowledge (and drop the response)
        a.li(T3, want)
        a.bne(T2, T3, top); a.nop()

    def command(c, params=(), ints=(3,)):
        a.sb(ZERO, 0x1800, T0)                            # index 0
        for p in params:
            a.li(T1, p); a.sb(T1, 0x1802, T0)
        a.li(T1, c); a.sb(T1, 0x1801, T0)
        for i in ints:
            wait_int(i)

    def delay(count):
        n[0] += 1
        lab = "d%d" % n[0]
        a.li(T4, count)
        a.label(lab)
        a.addiu(T4, T4, -1)
        a.bne(T4, ZERO, lab); a.nop()

    # every interrupt enabled, anything pending acknowledged
    a.li(T1, 1); a.sb(T1, 0x1800, T0)
    a.li(T1, 0x1F); a.sb(T1, 0x1802, T0); a.sb(T1, 0x1803, T0)
    command(0x0A, ints=(3, 2))                            # Init
    command(0x0C)                                         # Demute
    if cdda_only:                                         # an audio CD: Play(1) and leave it
        command(0x0E, [0x00])
        command(0x03, [0x01])
        a.label("cd_forever")
        a.j("cd_forever"); a.nop()
    command(0x0E, [0xC8])                                 # Setmode: 2x, XA, filter
    command(0x0D, [0x01, xa_channel])                     # Setfilter: file 1, channel
    command(0x02, [0x00, 0x15, 0x25])                     # Setloc 00:15:25 = LBA 1000
    command(0x1B)                                         # ReadS: XA plays
    a.label("phase1")
    delay(60_000_000)                                     # past the end of the XA (5.3 s)
    a.li(T1, 1); a.sb(T1, 0x1800, T0); a.li(T1, 0x07); a.sb(T1, 0x1803, T0)
    command(0x09, ints=(3, 2))                            # Pause
    command(0x0E, [0x00])                                 # Setmode: plain
    command(0x03, [0x02])                                 # Play track 2
    a.label("forever")
    a.j("forever"); a.nop()
    words = a.words()
    blob = b"".join(struct.pack("<I", w) for w in words)
    return blob.ljust(512 * 1024, b"\0")


def post(path, body=None, raw=None, t=120):
    data = raw if raw is not None else json.dumps(body or {}).encode()
    kind = "application/octet-stream" if raw is not None else "application/json"
    return json.loads(urllib.request.urlopen(urllib.request.Request(
        SERVER + path, data=data, method="POST", headers={"Content-Type": kind}), timeout=t).read())


def record(seconds):
    w = urllib.request.urlopen(SERVER + "/api/syn/record?seconds=%g" % seconds, timeout=60).read()
    wf = wave.open(io.BytesIO(w))
    x = np.frombuffer(wf.readframes(wf.getnframes()), dtype=np.int16).reshape(-1, wf.getnchannels()).astype(float)
    return x, wf.getframerate()


def peak(x, rate):
    m = x.mean(axis=1)
    if np.sqrt((m * m).mean()) < 50:
        return None, 0
    spec = np.abs(np.fft.rfft(m * np.hanning(len(m))))
    return np.argmax(spec[20:]) * rate / len(m) + 20 * rate / len(m), np.sqrt((m * m).mean())


def main():
    disc = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "build", "testdiscs", "xadisc", "xadisc.cue")
    print("disc:", post("/api/disc/select", {"path": os.path.abspath(disc)}).get("tracks"))
    post("/api/disc/host", {"on": True})
    time.sleep(1.5)
    print("program loaded:", post("/api/nes/load", raw=program()).get("ok"))
    # short recordings back to back, each one's strongest tone: the XA's 700 Hz
    # first, then the MP3's 880 Hz; a recording that falls behind is just retried
    t0 = time.time()
    seen = []
    while time.time() - t0 < 22:
        try:
            x, rate = record(0.5)
        except Exception:
            continue
        f, rms = peak(x, rate)
        seen.append(f)
        print("  %5.1f s  %s" % (time.time() - t0, "silence" if f is None else "%.0f Hz, level %.0f" % (f, rms)))
    near = lambda want: [i for i, f in enumerate(seen) if f is not None and abs(f - want) < 15]
    xa, cd = near(700), near(880)
    wrong = [f for f in seen if f is not None and abs(f - 700) >= 15 and abs(f - 880) >= 15]
    print("XA channel 3 (700 Hz): %d recordings; MP3 track (880 Hz): %d; anything else: %s"
          % (len(xa), len(cd), ["%.0f" % f for f in wrong] or "none"))
    ok = bool(xa) and bool(cd) and xa[-1] < cd[0] and not wrong
    print("ps1cdtest:", "PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
