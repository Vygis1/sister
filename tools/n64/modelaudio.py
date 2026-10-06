"""modelaudio.py - a game's sound as the model plays it (tools/n64/n64model.py, its RSP and
AI): the reference to hold the board's against (tools/n64/aring.py).

    python tools/n64/modelaudio.py ROM SECONDS [OUT]      (emulated seconds, by VI frames)

Writes OUT.wav (default build/model_audio) at the game's DAC rate, stereo, every sample the
model's AI played, and a picture of the screen at the end (OUT.png).
"""
import os
import struct
import sys
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import n64model          # noqa: E402
import n64rdptests       # noqa: E402  (ensure_rdp, vi_picture, save_picture)


def main():
    rom_path, secs = sys.argv[1], float(sys.argv[2])
    out = sys.argv[3] if len(sys.argv) > 3 else os.path.join('build', 'model_audio')
    rom = open(rom_path, 'rb').read()
    if rom[:4] == bytes((0x37, 0x80, 0x40, 0x12)):
        rom = bytes(b for i in range(0, len(rom), 2) for b in (rom[i + 1], rom[i]))
    m = n64model.N64(rom)
    n64rdptests.ensure_rdp(m)
    m.fast_boot()
    c = m.cpu
    t0 = time.time()
    got = []
    frame = m.vi_frames
    end = int(secs * 60)
    while m.vi_frames < end:
        for _ in range(1024):
            c.step()
        if m.vi_frames != frame:
            frame = m.vi_frames
            got.extend(m.ai_samples); m.ai_samples.clear()
            if frame % 30 == 0:
                print('frame %d (%.1f s emulated), %.0f s, %d samples so far, dacrate %d'
                      % (frame, frame / 60, time.time() - t0, len(got), m.ai_dacrate), flush=True)
    rate = int(48681812 / (m.ai_dacrate + 1)) if m.ai_dacrate else 32000
    with wave.open(out + '.wav', 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(b''.join(struct.pack('<hh', l, r) for l, r in got))
    n64rdptests.save_picture(n64rdptests.vi_picture(m), out + '.png')
    print('%s.wav: %d samples at %d Hz' % (out, len(got), rate))


if __name__ == '__main__':
    main()
