"""Test vectors for rtl/n64_pif.v, from tools/n64/n64pif.py.

    python tools/n64/n64pifvec.py [N] [SEED] > sim/n64/pif_vectors.hex

Each case is a PIF RAM image with the parse bit set, the devices plugged in,
and the RAM the model leaves after parsing and running it. The EEPROM carries
over from case to case, and its final contents are the last line.
"""
import random
import sys

import n64pif

PACKETS = [(1, 3, 0x00), (1, 3, 0xFF), (1, 4, 0x01), (1, 6, 0x01), (3, 33, 0x02), (35, 1, 0x03),
           (5, 1, 0x03), (2, 8, 0x04), (10, 1, 0x05), (4, 1, 0x05), (1, 2, 0x09), (0, 2, None)]


def image(rng):
    ram = bytearray(rng.getrandbits(8) for _ in range(64))
    off = 0
    for ch in range(5):
        if off >= 60:
            break
        if rng.random() < 0.2:
            ram[off] = 0xFF; off += 1                      # padding
        k = rng.random()
        if k < 0.1:
            ram[off] = 0x00; off += 1; continue            # skip the channel
        if k < 0.15:
            ram[off] = 0xFD; off += 1; continue            # reset it
        send, recv, cmd = rng.choice(PACKETS)
        if rng.random() < 0.1:
            send |= rng.choice([0x40, 0x80])               # the run's own skip / reset flags
        if off + 2 + (send & 0x3F) + recv > 63:
            break
        ram[off] = send; ram[off + 1] = recv
        if cmd is not None and (send & 0x3F):
            ram[off + 2] = cmd
        off += 2 + (send & 0x3F) + recv
    if off < 63 and rng.random() < 0.7:
        ram[off] = 0xFE
    ram[63] = 0x01 | (0x02 if rng.random() < 0.05 else 0)
    return ram


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 500
    rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
    ram = bytearray(64)
    j = n64pif.Joybus(ram)
    eep = bytearray(2048)
    for _ in range(n):
        pads = [rng.getrandbits(32) for _ in range(4)]
        present = rng.getrandbits(4)
        size = rng.choice([0, 1, 2])
        j.pads = [pads[i] if present >> i & 1 else None for i in range(4)]
        j.eeprom = None if size == 0 else (memoryview(eep)[:512] if size == 1 else memoryview(eep))
        img = image(rng)
        ram[:] = img
        j.wrote()
        j.before_read()
        print('%08x %08x %08x %08x %x %x %s %s' % (pads[0], pads[1], pads[2], pads[3], present, size, img.hex(), ram.hex()))
    print('EEPROM ' + eep.hex())


if __name__ == '__main__':
    main()
