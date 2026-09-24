"""Play the FPGA's oscillator bank and capture what it makes.

There is no DAC on the board. Samples go into a ring buffer in block RAM and
come back over the same UDP register bus as everything else, which means the
audio arrives bit-exact -- no converter, no cable, nothing analog anywhere.

    python pc/synth.py demo            # play a short piece, write a WAV
    python pc/synth.py tone 440        # hold a note and record two seconds
    python pc/synth.py silence         # all voices off

The ring buffer holds about 167 ms. WCOUNT is a free-running total rather than
an index, so falling behind is detectable rather than silently producing
scrambled audio.
"""

import argparse
import struct
import sys
import time
import wave

import fpgalink as fl

SYN = 0x0003_0000
SYN_ID = SYN + 0x00
SYN_CTRL = SYN + 0x04
SYN_MASTER = SYN + 0x08
SYN_RATE = SYN + 0x0C
SYN_ATTACK = SYN + 0x10
SYN_RELEASE = SYN + 0x14
SYN_WCOUNT = SYN + 0x20
SYN_PHASE = SYN + 0x40          # + voice*4
SYN_VOICE = SYN + 0x60          # + voice*4

ABUF = 0x0004_0000
ABUF_WORDS = 16384

SQUARE, SAW, TRIANGLE, NOISE = 0, 1, 2, 3

VOICES = 8


class Synth:
    def __init__(self, link):
        self.link = link
        ident = link.read(SYN_ID)
        if ident != 0x5359_0001:
            raise RuntimeError(f"no synth at 0x{SYN:08X} (read 0x{ident:08X})")
        self.rate = link.read(SYN_RATE)

    # --- control ---------------------------------------------------------

    def enable(self, on=True):
        self.link.write(SYN_CTRL, 1 if on else 0)

    def master(self, level):
        self.link.write(SYN_MASTER, int(level) & 0xFFFF)

    def envelope(self, attack, release):
        self.link.write(SYN_ATTACK, int(attack) & 0xFFFF)
        self.link.write(SYN_RELEASE, int(release) & 0xFFFF)

    def phase_inc(self, hz):
        """The frequency control word: hz * 2^32 / sample_rate."""
        return int(round(hz * (1 << 32) / self.rate)) & 0xFFFFFFFF

    def note_on(self, voice, hz, wave=TRIANGLE, volume=0xC000):
        self.link.write(SYN_PHASE + voice * 4, self.phase_inc(hz))
        self.link.write(SYN_VOICE + voice * 4,
                        (volume << 16) | ((wave & 7) << 1) | 1)

    def note_off(self, voice):
        cur = self.link.read(SYN_VOICE + voice * 4)
        self.link.write(SYN_VOICE + voice * 4, cur & ~1)

    def all_off(self):
        for v in range(VOICES):
            self.link.write(SYN_VOICE + v * 4, 0)

    # --- capture ---------------------------------------------------------

    def capture(self, seconds, on_tick=None):
        """Follow the ring buffer for `seconds` and return signed 16-bit samples.

        Reads WCOUNT, works out what is new, and pulls exactly that. Raises if
        more than a buffer's worth went by between polls, because the samples in
        between are genuinely gone and silently splicing over the gap would make
        a recording that sounds fine and is wrong.
        """
        out = []
        want = int(seconds * self.rate)
        last = self.link.read(SYN_WCOUNT)
        t0 = time.monotonic()

        while len(out) < want:
            now = self.link.read(SYN_WCOUNT)
            new = (now - last) & 0xFFFFFFFF
            if new == 0:
                time.sleep(0.002)
                continue
            if new > ABUF_WORDS:
                raise RuntimeError(
                    f"fell behind by {new} words (buffer holds {ABUF_WORDS}); "
                    "samples were overwritten")

            start = last % ABUF_WORDS
            # One contiguous run, or two if it wrapped.
            runs = ([(start, new)] if start + new <= ABUF_WORDS
                    else [(start, ABUF_WORDS - start), (0, new - (ABUF_WORDS - start))])
            for base, count in runs:
                for word in self.link.read_block(ABUF + base * 4, count):
                    lo = word & 0xFFFF
                    hi = (word >> 16) & 0xFFFF
                    out.append(lo - 0x8000)
                    out.append(hi - 0x8000)
            last = now
            # Anything the caller wants to do mid-capture happens HERE, on this
            # thread. A second thread sharing the link serialises against it and
            # the capture falls behind the ring buffer.
            if on_tick:
                on_tick(len(out) / self.rate)

            if time.monotonic() - t0 > seconds * 8 + 5:
                raise RuntimeError("capture is not keeping up with the sample rate")

        return out[:want]


def write_wav(path, samples, rate):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack(f"<{len(samples)}h",
                                  *(max(-32768, min(32767, s)) for s in samples)))


def note_hz(midi):
    return 440.0 * (2.0 ** ((midi - 69) / 12.0))


def main():
    ap = argparse.ArgumentParser(description="Drive and record the FPGA synth")
    ap.add_argument("command", choices=["demo", "tone", "silence"], nargs="?", default="demo")
    ap.add_argument("arg", nargs="?", default="440")
    ap.add_argument("--target", default="192.168.178.50")
    ap.add_argument("--out", default="synth.wav")
    args = ap.parse_args()

    link = fl.Link(args.target)
    syn = Synth(link)
    print(f"synth at {args.target}, sample rate {syn.rate} Hz")

    if args.command == "silence":
        syn.all_off()
        syn.enable(False)
        print("all voices off")
        return

    syn.all_off()
    syn.master(0xA000 if args.command == 'tone' else 0x4800)
    syn.envelope(attack=600, release=300)
    syn.enable(True)

    if args.command == "tone":
        hz = float(args.arg)
        syn.note_on(0, hz, TRIANGLE)
        print(f"holding {hz} Hz, recording 2 s...")
        samples = syn.capture(2.0)
        syn.note_off(0)
    else:
        # A chord and a little melody, so the recording shows both polyphony
        # and note transitions rather than one flat tone.
        script = [
            (0.0, [(0, 57, TRIANGLE), (1, 64, TRIANGLE), (2, 69, SQUARE)]),
            (0.6, [(3, 72, SAW)]),
            (1.2, [(0, 55, TRIANGLE), (1, 62, TRIANGLE), (2, 67, SQUARE), (3, 71, SAW)]),
            (1.8, [(0, 53, TRIANGLE), (1, 60, TRIANGLE), (2, 65, SQUARE), (3, 69, SAW)]),
        ]
        print("playing, recording 2.6 s...")

        pending = list(script)

        def on_tick(elapsed):
            while pending and pending[0][0] <= elapsed:
                _, notes = pending.pop(0)
                for voice, midi, wave_ in notes:
                    syn.note_on(voice, note_hz(midi), wave_)

        samples = syn.capture(2.6, on_tick=on_tick)
        for v in range(4):
            syn.note_off(v)

    syn.all_off()

    peak = max(abs(s) for s in samples)
    nonzero = sum(1 for s in samples if s != 0)
    print(f"captured {len(samples)} samples, peak {peak}, {nonzero} non-silent")
    write_wav(args.out, samples, syn.rate)
    print(f"wrote {args.out}  ({len(samples)/syn.rate:.2f} s at {syn.rate} Hz)")


if __name__ == "__main__":
    sys.exit(main())
