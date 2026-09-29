"""Talk to the shell: install a core into the flash slot and boot it.

    python pc/shell.py status
    python pc/shell.py install cores/nes.bin
    python pc/shell.py verify  cores/nes.bin
    python pc/shell.py boot            # start the installed core
    python pc/shell.py boot --shell    # back to the shell

The shell is the golden image at address 0 of the configuration flash. It has
two front doors and this is the one that goes over Ethernet; the other is four
wires to an ESP32. Both reach the same flash engine, so anything this can do a
phone will be able to do later.

There is ONE core slot and it is everything the shell is not using. One core at
a time, with the whole chip to itself: that is the point of the arrangement, and
it is why the NES image contains a NES and nothing else.

What goes in the slot is a RAW bitstream -- a .bin, not a .bit. A .bit carries a
text header naming the design and the build date, and the FPGA's configuration
engine does not skip it: it would try to read that header as commands and the
whole image would fail to load.
"""

import argparse
import struct
import sys
import time
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fpgalink as fl

SHELL_ID      = 0x0000_0000
SHELL_VERSION = 0x0000_0004
SHELL_STATUS  = 0x0000_0008
SHELL_SCRATCH = 0x0000_000C
SHELL_CTRL    = 0x0000_0010
SHELL_BOOT    = 0x0000_0018
SHELL_BUF     = 0x0001_0000

OP_ID, OP_ERASE, OP_PROGRAM, OP_READ = 0, 1, 2, 3

PAGE = 256
SECTOR = 64 * 1024
SLOT_BASE = 2 * 1024 * 1024      # the shell keeps everything below this
SLOT_SIZE = 6 * 1024 * 1024      # and the core gets all the rest
BOOT_MAGIC = 0xB007_0000

SYNC_WORD = bytes([0xAA, 0x99, 0x55, 0x66])


def ctrl(op, offset=0):
    """Everything a flash operation needs, in one word."""
    assert 0 <= offset < SLOT_SIZE, f"offset {offset:#x} is outside the slot"
    return (op & 3) | ((offset & 0x7FFFFF) << 4)


class Shell:
    def __init__(self, target=fl.DEFAULT_HOST):
        self.link = fl.Link(target, timeout=1.0, retries=6)

    def present(self):
        """Is the thing answering actually the shell, and not a console?"""
        return self.link.read(SHELL_ID) == 0x5348454C      # "SHEL"

    def version(self):
        return self.link.read(SHELL_VERSION)

    def busy(self):
        return bool(self.link.read(SHELL_STATUS) & 1)

    def probe(self):
        """What the pins actually did, as opposed to what they were told to do."""
        v = self.link.read(SHELL_STATUS)
        return {
            "busy": bool(v & 1),
            "miso": bool(v & 2),
            "miso_ever_low": bool(v & 4),
            "sck_edges": (v >> 8) & 0xFF,
            "cs_falls": (v >> 16) & 0xFF,
            "state": (v >> 24) & 0x1F,
        }

    def miso(self):
        """The raw state of the pin the flash answers on.

        Stuck high is what an unconnected input looks like; stuck low is what a
        chip held in reset looks like. Either way it tells dead apart from idle,
        which the data bytes alone cannot.
        """
        return bool(self.link.read(SHELL_STATUS) & 2)

    def wait(self, timeout=90.0, what="the flash"):
        t0 = time.time()
        while self.busy():
            if time.time() - t0 > timeout:
                raise TimeoutError(f"{what} did not finish in {timeout:.0f}s")
            time.sleep(0.001)

    # --- one page at a time -------------------------------------------------
    def write_page(self, offset, data):
        assert len(data) == PAGE
        words = list(struct.unpack("<64I", data))
        self.link.write_block(SHELL_BUF, words)
        self.link.write(SHELL_CTRL, ctrl(OP_PROGRAM, offset))
        self.wait(5.0, "a page program")

    def read_raw(self, addr):
        """Read a page from an absolute flash address.

        Reads are not slot-relative: the whole point of one is to check what is
        actually in the chip, including the shell's own image at zero, which is
        the one place whose contents are known independently.
        """
        return self.read_page(addr)

    def read_page(self, offset):
        self.link.write(SHELL_CTRL, ctrl(OP_READ, offset))
        self.wait(5.0, "a page read")
        words = self.link.read_block(SHELL_BUF, 64)
        return b"".join(struct.pack("<I", w) for w in words)

    def erase(self, nbytes, progress=None):
        """Clear just the sectors an image of this size will occupy.

        Erasing the whole 6 MB slot would be tidier and takes three minutes, most
        of it spent clearing space nothing is about to be written into. A sector
        erase on this part is up to three seconds and cannot be hurried, so the
        only lever is how many of them to do.
        """
        sectors = (nbytes + SECTOR - 1) // SECTOR
        for i in range(sectors):
            self.link.write(SHELL_CTRL, ctrl(OP_ERASE, i * SECTOR))
            self.wait(10.0, f"erasing sector {i}")
            if progress:
                progress(i + 1, sectors)
        return sectors

    # --- whole cores ---------------------------------------------------------
    def install(self, path, progress=None):
        data = open(path, "rb").read()
        check_bitstream(data, path)
        if len(data) > SLOT_SIZE:
            raise ValueError(f"{path} is {len(data)//1024} kB; "
                             f"the slot is {SLOT_SIZE//1024} kB")

        self.erase(len(data),
                   progress=lambda a, b: progress and progress("erasing", a, b))

        pages = (len(data) + PAGE - 1) // PAGE
        for i in range(pages):
            chunk = data[i * PAGE:(i + 1) * PAGE].ljust(PAGE, b"\xFF")
            self.write_page(i * PAGE, chunk)
            if progress and (i % 64 == 0 or i == pages - 1):
                progress("writing", i + 1, pages)
        return pages

    def verify(self, path, progress=None):
        data = open(path, "rb").read()
        pages = (len(data) + PAGE - 1) // PAGE
        bad = []
        for i in range(pages):
            want = data[i * PAGE:(i + 1) * PAGE].ljust(PAGE, b"\xFF")
            got = self.read_page(i * PAGE)
            if got != want:
                bad.append(i)
            if progress and (i % 64 == 0 or i == pages - 1):
                progress("verifying", i + 1, pages)
        return bad

    def chip_id(self):
        """Ask the flash who it is: $20 $BA $17 is a Micron N25Q64.

        The one question whose answer cannot be faked by a chip that is not
        there. Every other operation reads $FF from an absent flash and $FF from
        an erased one, so "it read all ones" proves nothing at all.
        """
        self.link.write(SHELL_CTRL, ctrl(OP_ID))
        self.wait(5.0, "reading the chip id")
        w = self.link.read(SHELL_BUF)
        return (w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF)

    def installed(self):
        """Is there a core in the slot?

        A configuration image opens with a run of padding and then the sync word
        $AA995566. Looking for it is how the board answers the question itself,
        rather than trusting a record kept somewhere else that could disagree.
        """
        try:
            return SYNC_WORD in self.read_page(0)
        except Exception:
            return None

    def boot(self, core=True):
        """No reply is possible: the chip stops being what was listening."""
        self.link.write(SHELL_BOOT, BOOT_MAGIC | (1 if core else 0))


def check_bitstream(data, path):
    """Refuse the two files that look right and are not.

    A .bit has a text header before the sync word; the configuration engine does
    not skip it, so the image never loads and the board falls back to the shell
    with nothing explaining why. Better to say so here.
    """
    if data[:4] == b"\x00\x09\x0f\xf0" or b"Vivado" in data[:200]:
        raise ValueError(
            f"{path} looks like a .bit with its header still on.\n"
            "        The slot needs a raw .bin -- build with tools/core.sh, or\n"
            "        add -bin_file to write_bitstream."
        )
    if SYNC_WORD not in data[:1024]:
        raise ValueError(
            f"{path} has no bitstream sync word in its first kilobyte,\n"
            "        so it is probably not a configuration image at all."
        )


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target", default=fl.DEFAULT_HOST)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status")
    sub.add_parser("id")
    p = sub.add_parser("install"); p.add_argument("file")
    p = sub.add_parser("verify");  p.add_argument("file")
    sub.add_parser("erase")
    p = sub.add_parser("boot")
    p.add_argument("--shell", action="store_true",
                   help="reconfigure back to the shell instead of the core")

    args = ap.parse_args()
    sh = Shell(args.target)

    def show(stage, a, b):
        unit = "sectors" if stage == "erasing" else "pages"
        print(f"\r  {stage} {a}/{b} {unit}   ", end="", flush=True)

    if args.cmd == "status":
        if not sh.present():
            print("that is not the shell -- the board is running a console core.")
            print("power-cycle it, or load the shell over JTAG.")
            return 1
        print(f"shell version {sh.version():#010x}, busy={sh.busy()}")
        mfr, kind, cap = sh.chip_id()
        p = sh.probe()
        names = {0: "idle", 16: "warm-up", 17: "warm-up", 18: "reset-enable",
                 19: "reset-enable", 20: "reset", 21: "reset", 22: "settling"}
        st = p["state"]
        print(f"  controller state: {st} ({names.get(st, 'mid-transaction')})")
        print(f"  pins: {p['cs_falls']} transactions, {p['sck_edges']} clock edges"
              f" (both saturate at 255)")
        print(f"        MISO reads {'high' if p['miso'] else 'low'}, "
              f"and has {'' if p['miso_ever_low'] else 'NEVER '}been low while selected")
        known = " (Micron N25Q64)" if (mfr, kind, cap) == (0x20, 0xBA, 0x17) else ""
        print(f"  flash id: {mfr:02X} {kind:02X} {cap:02X}{known}")
        if mfr in (0x00, 0xFF):
            print("  *** the flash is not answering -- nothing else here will work")
        what = "holds a core" if sh.installed() else "empty"
        print(f"  core slot {SLOT_BASE:#08x}..{SLOT_BASE + SLOT_SIZE - 1:#08x}: {what}")

    elif args.cmd == "id":
        print("flash id: %02X %02X %02X" % sh.chip_id())

    elif args.cmd == "install":
        t0 = time.time()
        pages = sh.install(args.file, progress=show)
        print(f"\r  wrote {pages} pages in {time.time() - t0:.1f}s          ")
        bad = sh.verify(args.file, progress=show)
        if bad:
            print(f"\r  *** {len(bad)} pages differ, first at {bad[0]}     ")
            return 1
        print(f"\r  verified, all {pages} pages match                      ")

    elif args.cmd == "verify":
        bad = sh.verify(args.file, progress=show)
        print(f"\r  {'OK' if not bad else str(len(bad)) + ' pages differ'}          ")
        return 1 if bad else 0

    elif args.cmd == "erase":
        n = sh.erase(SLOT_SIZE, progress=lambda a, b: show("erasing", a, b))
        print(f"\r  erased {n} sectors                    ")

    elif args.cmd == "boot":
        where = "the shell" if args.shell else "the core"
        print(f"booting {where} -- the board stops answering as whatever it was")
        sh.boot(core=not args.shell)

    return 0


if __name__ == "__main__":
    sys.exit(main())
