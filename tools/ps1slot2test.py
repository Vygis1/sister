"""Port 2 on the board: the second pad and the second memory card.

    python tools/ps1slot2test.py

Loads a small program IN PLACE OF THE BIOS that talks to controller port 2
exactly as the kernel does (select with JOY_CTRL bit 13, a byte at a time,
waiting for each /ACK), while this script holds a known pattern on pad 2
through the server:

    pad 2    01h 42h 00h 00h 00h  ->  FFh 41h 5Ah, then the buttons held
    card 2   81h 53h 00h 00h ...  ->  the Get ID answer, 5Ah 5Dh 5Ch 5Dh 04h 00h 00h 80h

The program ends in one loop if every byte was right and in a loop of its own
for each byte that was not, so the processor's address (ctrl 0x14) says which
byte failed without reading any memory back. Put the real BIOS back afterwards
by loading it on the page.
"""
import os
import struct
import sys
import time
import json
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mipsasm import Asm, ZERO, T0, T1, T2, T3, T4  # noqa: E402

SERVER = "http://127.0.0.1:8080"
# pad 2 holds cross and start: the page's "a" and "start" bits
JOY2 = 1 | 8
SWLO, SWHI = 0xF7, 0xBF          # start (bit 3) and cross (bit 14), active low


def program():
    a = Asm(org=0xBFC00000)
    a.lui(T0, 0x0013)                         # the real BIOS's first word: the keepalive checks it
    a.lui(T0, 0xBF80)
    a.li(T1, 0x0088); a.sh(T1, 0x104E, T0)    # baud
    a.li(T1, 0x000D); a.sh(T1, 0x1048, T0)    # mode
    fails = []
    n = [0]

    def xfer(byte, want, ack, what):
        n[0] += 1
        a.li(T1, byte); a.sb(T1, 0x1040, T0)
        a.label("rx%d" % n[0])                # wait for the answer
        a.lw(T2, 0x1044, T0); a.nop()
        a.andi(T2, T2, 2)
        a.beq(T2, ZERO, "rx%d" % n[0]); a.nop()
        a.lbu(T2, 0x1040, T0); a.nop()
        a.li(T3, want)
        a.bne(T2, T3, "fail%d" % n[0]); a.nop()
        fails.append(("fail%d" % n[0], what))
        if ack:                               # /ACK: an interrupt, then acknowledge it
            a.li(T4, 100000)
            a.label("ack%d" % n[0])
            a.addiu(T4, T4, -1)
            a.beq(T4, ZERO, "noack%d" % n[0]); a.nop()
            a.lw(T2, 0x1044, T0); a.nop()
            a.andi(T2, T2, 0x200)
            a.beq(T2, ZERO, "ack%d" % n[0]); a.nop()
            a.li(T1, CTRL | 0x10); a.sh(T1, 0x104A, T0)
            fails.append(("noack%d" % n[0], what + ": no /ACK"))

    # pad 2
    CTRL = 0x3003                             # TXEN | select | /ACK irq enable | port 2
    a.li(T1, CTRL); a.sh(T1, 0x104A, T0)
    xfer(0x01, 0xFF, True, "pad 2, byte 0")
    xfer(0x42, 0x41, True, "pad 2, ID low (41h: digital pad)")
    xfer(0x00, 0x5A, True, "pad 2, ID high")
    xfer(0x00, SWLO, True, "pad 2, buttons low (start)")
    xfer(0x00, SWHI, False, "pad 2, buttons high (cross)")
    a.sh(ZERO, 0x104A, T0)
    a.li(T4, 2000)                            # a moment deselected
    a.label("gap"); a.addiu(T4, T4, -1); a.bne(T4, ZERO, "gap"); a.nop()
    # card 2: Get ID
    a.li(T1, CTRL); a.sh(T1, 0x104A, T0)
    xfer(0x81, 0xFF, True, "card 2, address")
    a.li(T1, 0x53); a.sb(T1, 0x1040, T0)      # 53h: the answer is FLAG, which may be 08h or 00h
    a.label("rxf")
    a.lw(T2, 0x1044, T0); a.nop()
    a.andi(T2, T2, 2)
    a.beq(T2, ZERO, "rxf"); a.nop()
    a.lbu(T2, 0x1040, T0); a.nop()
    a.li(T4, 100000)
    a.label("ackf"); a.addiu(T4, T4, -1)
    a.beq(T4, ZERO, "noackf"); a.nop()
    a.lw(T2, 0x1044, T0); a.nop()
    a.andi(T2, T2, 0x200)
    a.beq(T2, ZERO, "ackf"); a.nop()
    a.li(T1, CTRL | 0x10); a.sh(T1, 0x104A, T0)
    fails.append(("noackf", "card 2, Get ID command: no /ACK"))
    for i, (b, ack) in enumerate(((0x5A, True), (0x5D, True), (0x5C, True), (0x5D, True),
                                  (0x04, True), (0x00, True), (0x00, True), (0x80, False))):
        xfer(0x00, b, ack, "card 2, Get ID byte %d (%02Xh)" % (i + 2, b))
    a.sh(ZERO, 0x104A, T0)
    a.label("pass"); a.j("pass"); a.nop()
    for lab, _ in fails:
        a.label(lab); a.j(lab); a.nop()
    words = a.words()
    where = {a.labels[lab]: what for lab, what in fails}
    return b"".join(struct.pack("<I", w) for w in words).ljust(512 * 1024, b"\0"), a.labels["pass"], where


def call(path, body=None, raw=None):
    if body is None and raw is None:
        return json.loads(urllib.request.urlopen(SERVER + path, timeout=30).read())
    data = raw if raw is not None else json.dumps(body).encode()
    kind = "application/octet-stream" if raw is not None else "application/json"
    return json.loads(urllib.request.urlopen(urllib.request.Request(
        SERVER + path, data=data, method="POST", headers={"Content-Type": kind}), timeout=120).read())


def main():
    blob, passed, where = program()
    call("/api/nes/input", {"joy2": JOY2})
    print("program loaded:", call("/api/nes/load", raw=blob).get("ok"))
    time.sleep(1.0)
    call("/api/nes/input", {"joy2": JOY2})    # the load reset the pads
    time.sleep(2.0)
    pc = call("/api/reg/%d" % 0x80014)["value"]
    call("/api/nes/input", {"joy2": 0})
    if pc - passed in (0, 4):                    # a loop is a jump and its delay slot
        pc = passed
    where.update({k + 4: v for k, v in list(where.items())})
    if pc == passed:
        print("ps1slot2test: PASS -- pad 2 answered with its buttons, card 2 answered Get ID")
        return True
    print("ps1slot2test: FAIL at %08x: %s" % (pc, where.get(pc, "still running (stuck waiting for an answer)")))
    return False


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
