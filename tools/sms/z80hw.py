"""Run a CP/M .COM Z80 test program on the board and print what it says.

    python tools/sms/z80hw.py sim/roms/z80/zexdoc.com

ZEXDOC needs tens of billions of cycles. Measured in xsim that is over a day --
1.4 billion cycles did not finish the first of its sixty-seven tests. The board
runs the same core at 50 MHz and turns that into minutes, which is the entire
reason this script exists.

The board has no operating system, so the handful of things a CP/M program
actually needs are assembled as Z80 code in tools/sms/z80shim.py and dropped into
low memory. Console output leaves through an I/O port into a buffer that the
register bus reads back.
"""

import os, sys, struct, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "pc"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fpgalink import Link, DEFAULT_HOST
from z80shim import apply_to, HALT_AT

NES_CTRL, NES_CONSOLE = 0x0008_0004, 0x0008_0020
NES_CONCNT, NES_Z80PC = 0x0008_0024, 0x0008_0028
NES_PRG, CON_PAGE = 0x0009_0000, 0x000F_0000
CON_MAX = 4096


def main():
    rom = open(sys.argv[1], "rb").read()
    link = Link(DEFAULT_HOST, timeout=1.0, retries=6)

    mem = bytearray(64 * 1024)
    mem[0x0100:0x0100 + len(rom)] = rom
    apply_to(mem)
    print(f"{sys.argv[1]}: {len(rom)} bytes at $0100")

    link.write(NES_CTRL, 0)                       # hold the console in reset
    words = list(struct.unpack("<16384I", bytes(mem)))
    for i in range(0, len(words), 16384):
        link.write_block(NES_PRG + (i // 16384) * 0x0001_0000, words[i:i + 16384])

    link.write(NES_CONSOLE, 1)                    # select the Z80 slot
    got = link.read(NES_CONSOLE)
    if (got & 0xF) != 1:
        print(f"  this bitstream has no Z80 slot (CONSOLE reads {got:#010x})")
        return 1

    link.write(NES_CTRL, 1)
    print("  running...")

    seen, last_report, start = 0, time.time(), time.time()
    buf = bytearray()

    def catch_up(n):
        """Read only the words that are new, keeping them at their real offset.

        Re-reading starts at the word containing `seen`, not at the end of the
        buffer. The word straddling the end was fetched when it was only
        partly written, so the bytes past the count in it are stale -- keeping
        it cost one character at every poll boundary, which turned OK into K.
        """
        nonlocal seen
        first = seen // 4
        del buf[first * 4:]
        for w in range(first, (n + 3) // 4):
            buf.extend(struct.pack("<I", link.read(CON_PAGE + w * 4)))
        if n > seen:
            sys.stdout.write(bytes(buf[seen:n]).decode("latin-1"))
            sys.stdout.flush()
            seen = n

    while True:
        n = link.read(NES_CONCNT)
        if n > seen:
            catch_up(n)

        if n >= CON_MAX:
            print(f"{chr(10)}  output buffer full at {CON_MAX} bytes")
            break
        if time.time() - start > 3600:
            print(f"{chr(10)}  gave up after an hour")
            break

        # A finished program returns to $0000. The bootstrap finds its flag
        # already set and stops on the HALT, leaving PC one past it.
        if link.read(NES_Z80PC) == HALT_AT + 1:
            time.sleep(0.5)
            catch_up(link.read(NES_CONCNT))
            break

        if time.time() - last_report > 60:
            last_report = time.time()
            print(f"{chr(10)}  [{time.time() - start:.0f}s, "
                  f"PC={link.read(NES_Z80PC):#06x}, {n} chars]", flush=True)
        time.sleep(0.2)

    body = bytes(buf[:seen]).decode("latin-1")
    print(f"{chr(10)}  {seen} characters in {time.time() - start:.0f}s")

    # These suites say "OK" per test and "ERROR" with the expected and actual
    # CRC when a test fails, so the transcript is the verdict.
    oks = body.count("OK")
    errs = body.count("ERROR")
    print(f"  {oks} passed, {errs} failed")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
