"""Compare the game's executable in RAM against the bytes on the disc.

    python tools/ps1exeverify.py [lines-to-sample] [disc.bin]   (0 = every line)

The disc image is the argument, or PS1_DISC. HDR_LBA below is where
Crash Bandicoot (USA) keeps its PS-X EXE.

The BIOS reads the PS-X EXE off the disc and DMAs it into RAM. If any of it
does not arrive, the game runs off a corrupted copy of itself: a jump table
full of zeros, a directory extent that decodes to a LBA past the end of the
disc, a jump into .bss. All three were seen on the board, and all three are
the same fault seen from different angles -- so check the load itself.

Reads through the DDR3 line window (ctrl 0x7C/0x80), after flushing the
processor's write-back cache, and prints WHERE the differences are, because
the shape of them names the cause: whole 2048-byte sectors missing is the
drive, 16-byte lines is the cache, scattered words is a race.
"""
import os, sys, time, struct, random
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pc"))
import fpgalink as fl

N = 0x0008_0000
RAM_LINE = 0x10000
IMG = os.environ.get("PS1_DISC", "")      # your own image of the disc, raw 2352-byte sectors
HDR_LBA = 112018


def disc_text(img):
    f = open(img, "rb")
    def user(lba):
        f.seek(lba * 2352); return f.read(2352)[24:24 + 2048]
    h = user(HDR_LBA)
    assert h[:8] == b"PS-X EXE", "no PS-X EXE at LBA %d" % HDR_LBA
    pc0, gp0, taddr, tsize = struct.unpack("<4I", h[0x10:0x20])
    data = b"".join(user(HDR_LBA + 1 + i) for i in range((tsize + 2047) // 2048))
    f.close()
    return taddr, tsize, data[:tsize]


def main():
    nums = [a for a in sys.argv[1:] if a.isdigit()]
    img = next((a for a in sys.argv[1:] if not a.isdigit()), IMG)
    if not img:
        sys.exit("give the disc image as an argument or set PS1_DISC to your own dump")
    nsample = int(nums[0]) if nums else 3000
    taddr, tsize, text = disc_text(img)
    print("disc: %s loads at %08x, %d bytes (%d lines of 16)"
          % ("PS-X EXE", taddr, tsize, tsize // 16))

    l = fl.Link(fl.DEFAULT_HOST, 5005, timeout=1.0, retries=4)
    l.write(N + 0x118, 1)
    for _ in range(400):
        if not (l.read(N + 0x118) & 1):
            break
        time.sleep(0.01)

    nlines = tsize // 16
    idx = range(nlines) if nsample == 0 else sorted(random.sample(range(nlines), min(nsample, nlines)))

    bad = []
    zero_lines = 0
    t0 = time.time()
    for k, li in enumerate(idx):
        a = ((taddr & 0x1FFFFF) + li * 16)
        l.write(N + 0x7C, RAM_LINE + (a >> 4))
        for _ in range(60):
            if l.read(N + 0x7C) >> 31:
                break
        got = l.read_block(N + 0x80, 4)
        want = struct.unpack_from("<4I", text, li * 16)
        if tuple(got) != want:
            bad.append((taddr + li * 16, tuple(got), want))
            if got == [0, 0, 0, 0]:
                zero_lines += 1
    dt = time.time() - t0

    print("checked %d lines in %.0f s: %d differ (%.2f%%), %d of those read as all zeros"
          % (len(idx), dt, len(bad), 100.0 * len(bad) / len(idx), zero_lines))
    if not bad:
        print("the executable in RAM matches the disc")
        return 0
    print("first differences:")
    for a, g, w in bad[:12]:
        print("  %08x  got %s" % (a, " ".join("%08x" % x for x in g)))
        print("            want %s" % " ".join("%08x" % x for x in w))
    addrs = [a for a, _, _ in bad]
    print("range %08x .. %08x" % (min(addrs), max(addrs)))
    # does a bad line fall in one 2048-byte sector, or spread over many?
    secs = sorted(set((a - taddr) // 2048 for a in addrs))
    print("bad lines fall in %d distinct 2048-byte sectors (of %d); sector numbers %s%s"
          % (len(secs), (tsize + 2047) // 2048, secs[:16], " ..." if len(secs) > 16 else ""))
    return 1


if __name__ == "__main__":
    sys.exit(main())
