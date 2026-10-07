"""mdecvec.py - vectors for sim/tb_ps1_mdec.v from the model (tools/ps1/mdec.py): the standard
tables uploaded, then decode commands in every output depth (15-bit, 24-bit, 8- and 4-bit mono,
signed and unsigned, bit 15) over random run-length data, padded with FE00h to whole 32-word
blocks as games send it; and the words the model says come out.

    python tools/ps1/mdecvec.py [MACROBLOCKS] [SEED]    -> sim/ps1mdec/in.txt, sim/ps1mdec/out.txt
    ./tools/sim.sh tb_ps1_mdec

in.txt: "C value" (a write to 1824h) or "D value" (a word into 1820h, as DMA0 sends it).
out.txt: the words DMA1 reads, in order.
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mdec  # noqa: E402

OUT = os.path.join(HERE, '..', '..', 'sim', 'ps1mdec')


def block(rng):
    """a block's halfwords: the DC, some ACs, the end"""
    h = [(rng.randrange(1, 64) << 10) | (rng.randrange(-512, 512) & 0x3FF)]
    k = 0
    while True:
        run = min(63, int(rng.expovariate(0.35)))
        if k + run + 1 > 63 or rng.random() < 0.06:
            if k + run + 1 == 63 and rng.random() < 0.3:
                h.append((run << 10) | (rng.randrange(-200, 200) & 0x3FF))   # (the 63rd ends it, no FE00)
                return h
            h.append(0xFE00)
            return h
        k += run + 1
        lv = int(rng.gauss(0, 40))
        lv = max(-512, min(511, lv))
        h.append((run << 10) | (lv & 0x3FF))


def command(rng, nmb, depth, signed, bit15):
    blocks = nmb * (1 if depth < 2 else 6)
    hw = []
    for _ in range(blocks):
        if rng.random() < 0.2:
            hw.append(0xFE00)                     # padding between blocks
        hw += block(rng)
    if len(hw) & 1:
        hw.append(0xFE00)
    words = [hw[i] | hw[i + 1] << 16 for i in range(0, len(hw), 2)]
    while len(words) % 32:
        words.append(0xFE00FE00)
    cmd = (1 << 29) | (depth << 27) | (signed << 26) | (bit15 << 25) | len(words)
    return [cmd] + words


def main():
    nmb = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    rng = random.Random(seed)
    m = mdec.Mdec()
    ins = [('C', 0x80000000), ('C', 0x60000000)]
    m.write1(0x80000000); m.write1(0x60000000)
    def send(ws):
        for w in ws:
            ins.append(('D', w)); m.write0(w)
    q = mdec.STD_QUANT
    send([0x40000001] + [q[i] | q[i + 1] << 8 | q[i + 2] << 16 | q[i + 3] << 24 for i in range(0, 64, 4)] * 2)
    sc = [v for row in mdec.STD_SCALE for v in row]
    send([0x60000000] + [sc[i] | sc[i + 1] << 16 for i in range(0, 64, 2)])
    for depth, signed, bit15 in ((3, 0, 0), (2, 0, 0), (3, 1, 1), (2, 1, 0), (1, 0, 0), (0, 0, 0), (1, 1, 0), (0, 1, 0)):
        send(command(rng, nmb if depth >= 2 else nmb * 4, depth, signed, bit15))
    out = []
    while m.out:
        out.append(m.read0())
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, 'in.txt'), 'w').write(''.join('%s %08x\n' % (k, v) for k, v in ins))
    open(os.path.join(OUT, 'out.txt'), 'w').write(''.join('%08x\n' % v for v in out))
    print('%d words in, %d out' % (len(ins), len(out)))


if __name__ == '__main__':
    main()
