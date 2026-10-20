"""Converts the SingleStepTests wdc65c02 suite into one flat hex stream for sim/tb_huc6280.v.
    git clone --depth 1 --filter=blob:none --sparse https://github.com/SingleStepTests/65x02 build/65x02tests
    (cd build/65x02tests && git sparse-checkout set wdc65c02/v1)
    python tools/pce/c02tests.py                      -> build/65x02tests/all.hex
    python tools/pce/c02tests.py a9 7c                 -> only those opcodes

The HuC6280 is a 65C02 with more: everything the WDC part does, it does the same, so its
tests check this core's registers, flags and memory -- but not its cycle counts, which are
Hudson's own (every memory instruction a cycle longer, no page-crossing penalties). The count
each test should take comes from the table below (MAME's h6280, which the documentation
agrees with), plus the extras: a branch taken, a decimal ADC/SBC.

Left out: the opcodes Hudson gave a meaning the WDC part does not have (SXY SAX SAY CLA CLX
CLY ST0-2 TMA TAM the block transfers TST BSR CSL CSH SET), WAI/STP ($CB/$DB, NOPs here), and
BRK (its vector is $FFF6 on a HuC6280, $FFFE on a 65C02). And any test touching $2000-$3FFF:
the bench maps bank 1 onto bank 0 so zero page and the stack sit at $0000 as the suite wants.

One record, all words in hex:
    opcode  pc s a x y p  n (addr data)*n        the initial state
            pc s a x y p  n (addr data)*n        the final state
            cycles                               what the HuC6280 takes
"""
import json
import os
import sys

SRC = os.path.join('build', '65x02tests', 'wdc65c02', 'v1')
OUT = os.path.join('build', '65x02tests', 'all.hex')

# the HuC6280's cycle counts by opcode (branches: not taken; BBR/BBS: not taken)
CYC = {}
for row in """
00 8 01 7 02 3 03 5 04 6 05 4 06 6 07 7 08 3 09 2 0a 2 0b 2 0c 7 0d 5 0e 7 0f 6
10 2 11 7 12 7 13 5 14 6 15 4 16 6 17 7 18 2 19 5 1a 2 1b 2 1c 7 1d 5 1e 7 1f 6
20 7 21 7 22 3 23 5 24 4 25 4 26 6 27 7 28 4 29 2 2a 2 2b 2 2c 5 2d 5 2e 7 2f 6
30 2 31 7 32 7 33 2 34 4 35 4 36 6 37 7 38 2 39 5 3a 2 3b 2 3c 5 3d 5 3e 7 3f 6
40 7 41 7 42 3 43 4 44 8 45 4 46 6 47 7 48 3 49 2 4a 2 4b 2 4c 4 4d 5 4e 7 4f 6
50 2 51 7 52 7 53 5 54 3 55 4 56 6 57 7 58 2 59 5 5a 3 5b 2 5c 2 5d 5 5e 7 5f 6
60 7 61 7 62 2 63 4 64 4 65 4 66 6 67 7 68 4 69 2 6a 2 6b 2 6c 7 6d 5 6e 7 6f 6
70 2 71 7 72 7 73 17 74 4 75 4 76 6 77 7 78 2 79 5 7a 4 7b 2 7c 7 7d 5 7e 7 7f 6
80 4 81 7 82 2 83 7 84 4 85 4 86 4 87 7 88 2 89 2 8a 2 8b 2 8c 5 8d 5 8e 5 8f 6
90 2 91 7 92 7 93 8 94 4 95 4 96 4 97 7 98 2 99 5 9a 2 9b 2 9c 5 9d 5 9e 5 9f 6
a0 2 a1 7 a2 2 a3 7 a4 4 a5 4 a6 4 a7 7 a8 2 a9 2 aa 2 ab 2 ac 5 ad 5 ae 5 af 6
b0 2 b1 7 b2 7 b3 8 b4 4 b5 4 b6 4 b7 7 b8 2 b9 5 ba 2 bb 2 bc 5 bd 5 be 5 bf 6
c0 2 c1 7 c2 2 c3 17 c4 4 c5 4 c6 6 c7 7 c8 2 c9 2 ca 2 cb 2 cc 5 cd 5 ce 7 cf 6
d0 2 d1 7 d2 7 d3 17 d4 3 d5 4 d6 6 d7 7 d8 2 d9 5 da 3 db 2 dc 2 dd 5 de 7 df 6
e0 2 e1 7 e2 2 e3 17 e4 4 e5 4 e6 6 e7 7 e8 2 e9 2 ea 2 eb 2 ec 5 ed 5 ee 7 ef 6
f0 2 f1 7 f2 7 f3 17 f4 2 f5 4 f6 6 f7 7 f8 2 f9 5 fa 4 fb 2 fc 2 fd 5 fe 7 ff 6
""".split('\n'):
    w = row.split()
    for i in range(0, len(w), 2):
        CYC[int(w[i], 16)] = int(w[i + 1])

SKIP = {0x5C, 0xDC, 0xFC, 0xE2,   # (NOPs of 3, 3, 3 and 2 bytes on the WDC part; 1 byte here, as on the HuC6280)
        0x00, 0x02, 0x22, 0x42, 0x62, 0x82, 0xC2, 0x03, 0x13, 0x23, 0x43, 0x53, 0x73, 0x83, 0x93, 0xA3, 0xB3,
        0xC3, 0xD3, 0xE3, 0xF3, 0x44, 0x54, 0xD4, 0xF4, 0xCB, 0xDB}
BRANCH = {0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0}
BBR = {0x0F, 0x1F, 0x2F, 0x3F, 0x4F, 0x5F, 0x6F, 0x7F, 0x8F, 0x9F, 0xAF, 0xBF, 0xCF, 0xDF, 0xEF, 0xFF}


def taken(opc, i):
    """Does this branch go? (From the flags, or the zero page bit: a displacement of 0 makes
    the final pc say nothing.)"""
    ram = dict(i['ram'])
    p = i['p']
    if opc in BRANCH:
        flag = {0: p >> 7 & 1, 1: p >> 6 & 1, 2: p & 1, 3: p >> 1 & 1}[opc >> 6]
        return flag == (opc >> 5 & 1)
    zp = ram[(i['pc'] + 1) & 0xFFFF]
    bit = ram.get(zp, 0) >> ((opc >> 4) & 7) & 1
    return bit == (opc >> 7)


def cycles(opc, t):
    n = CYC[opc]
    i, f = t['initial'], t['final']
    if (opc in BRANCH or opc in BBR) and taken(opc, i):
        n += 2
    if opc in (0x69, 0x65, 0x75, 0x6D, 0x7D, 0x79, 0x61, 0x71, 0x72,
               0xE9, 0xE5, 0xF5, 0xED, 0xFD, 0xF9, 0xE1, 0xF1, 0xF2) and (i['p'] & 8):
        n += 1
    return n


def conv(name):
    opc = int(name, 16)
    tests = json.load(open(os.path.join(SRC, name + '.json')))
    words = []
    kept = 0
    for t in tests:
        i, f = t['initial'], t['final']
        if any(0x2000 <= a < 0x4000 for a, _ in i['ram'] + f['ram']):
            continue
        kept += 1
        words.append(opc)
        for s in (i, f):
            words += [s['pc'], s['s'], s['a'], s['x'], s['y'], s['p'], len(s['ram'])]
            for a, d in s['ram']:
                # (PHP: the WDC part pushes bit 5 as 1; this chip pushes T, 0 here)
                if opc == 0x08 and s is f and a == 0x100 + i['s']:
                    d &= 0xDF
                words += [a, d]
        words.append(cycles(opc, t))
    return words, kept


def main():
    names = sorted(f[:-5] for f in os.listdir(SRC) if f.endswith('.json'))
    if len(sys.argv) > 1:
        want = [a.lower() for a in sys.argv[1:]]
        names = [n for n in names if n in want]
    names = [n for n in names if int(n, 16) not in SKIP]
    n = 0
    with open(OUT, 'w') as out:
        for name in names:
            w, cnt = conv(name)
            n += cnt
            out.write(' '.join('%x' % x for x in w))
            out.write('\n')
    print('%d tests from %d opcodes -> %s' % (n, len(names), OUT))


if __name__ == '__main__':
    main()
