"""xatest.py - esp32/console/xa.h (the ESP32's XA decoder) against pc/cdaudio.py's XaDecoder,
word for word, on a run of real XA sectors from a disc image.

    python tools/ps1/xatest.py DISC.bin [FIRST_LBA] [COUNT]

Builds tools/ps1/xatest.cpp with MSYS gcc, feeds both the same sectors -- filtered and not --
and reports the first differing word.
"""
import os, subprocess, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'pc'))
import cdaudio  # noqa: E402

GCC = r'C:\msys64\mingw64\bin\g++.exe'
TMP = os.path.join(HERE, '..', '..', 'build', 'xatest')


def main():
    img = sys.argv[1]
    first = int(sys.argv[2]) if len(sys.argv) > 2 else None
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 400
    os.makedirs(TMP, exist_ok=True)
    exe = os.path.join(TMP, 'xatest.exe')
    env = dict(os.environ, PATH=r'C:\msys64\mingw64\bin;' + os.environ['PATH'])
    subprocess.check_call([GCC, '-O2', '-o', exe, os.path.join(HERE, 'xatest.cpp')], env=env)
    f = open(img, 'rb')
    nsec = os.path.getsize(img) // 2352
    if first is None:                        # the first XA audio sector on the disc
        for lba in range(0, nsec, 50):
            f.seek(lba * 2352); s = f.read(24)
            if s[15] == 2 and (s[18] & 0x24) == 0x24:
                first = lba; break
    f.seek(first * 2352)
    raw = f.read(count * 2352)
    secs = [raw[i * 2352:(i + 1) * 2352] for i in range(len(raw) // 2352)]
    # the audio ones (the drive queues only those), with a flush marker in the middle
    audio = [s for s in secs if s[15] == 2 and (s[18] & 0x24) == 0x24]
    mark = b'\xee' + bytes(2351)
    stream = audio[:len(audio) // 2] + [mark] + audio[len(audio) // 2:]
    inp = os.path.join(TMP, 'in.bin'); open(inp, 'wb').write(b''.join(stream))
    bad = 0
    for filtered in (1, 0):
        out = os.path.join(TMP, 'out%d.bin' % filtered)
        print(subprocess.check_output([exe, inp, out, str(filtered)], env=env).decode().strip(), '(C, filtered=%d)' % filtered)
        got = np.fromfile(out, dtype=np.uint32)
        dec = cdaudio.XaDecoder(); want = []
        for s in stream:
            if s[0] == 0xEE:
                dec.reset(); continue
            if dec.accept(s, bool(filtered)):
                d = dec.decode(s)
                want.append(((d[:, 1].astype(np.uint32) & 0xFFFF) << 16) | (d[:, 0].astype(np.uint32) & 0xFFFF))
        want = np.concatenate(want) if want else np.zeros(0, np.uint32)
        if len(got) != len(want) or not np.array_equal(got, want):
            n = min(len(got), len(want))
            diff = np.nonzero(got[:n] != want[:n])[0]
            i = int(diff[0]) if len(diff) else n
            print('  DIFFERS: %d words vs the model\'s %d; first at %d: %s vs %s' % (len(got), len(want), i,
                  '%08x' % got[i] if i < len(got) else '-', '%08x' % want[i] if i < len(want) else '-'))
            bad += 1
        else:
            print('  the same: %d words (%d sectors from LBA %d, codings %s)' % (len(got), len(audio), first,
                  sorted(set('%02x' % s[19] for s in audio))))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
