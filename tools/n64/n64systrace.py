"""The model booted through the real boot ROM (as n64_top boots), traced, and
compared with tb_n64_top's sys.trace.

    python tools/n64/n64systrace.py [--steps N]

Writes sim/n64/sys_model.trace and reports the first line where the two differ.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import n64model  # noqa: E402
import n64bootrom  # noqa: E402

OUT = os.path.join(HERE, '..', '..', 'sim', 'n64')


def main():
    steps = int(sys.argv[sys.argv.index('--steps') + 1]) if '--steps' in sys.argv else 3_000_000
    rom = open(open(os.path.join(OUT, 'rom.path')).read().strip(), 'rb').read()
    m = n64model.N64(rom)
    if '--junk' in sys.argv:
        # tb_n64_top's JUNK1: line i is {i*9E3779B1, i^A5A51234, ~i*85EBCA6B, i+DEADBEEF}, byte 0 lowest
        M = 0xFFFFFFFF
        for i in range(len(m.rdram) // 16):
            ws = ((i + 0xDEADBEEF) & M, ((~i & M) * 0x85EBCA6B) & M, (i ^ 0xA5A51234) & M, (i * 0x9E3779B1) & M)
            m.rdram[16 * i:16 * i + 16] = b''.join(w.to_bytes(4, 'little') for w in ws)
    for i, w in enumerate(n64bootrom.program()):
        m.pifrom[4 * i:4 * i + 4] = w.to_bytes(4, 'big')
    c = m.cpu
    c.pc = 0xFFFFFFFFBFC00000
    c.npc = c.pc + 4
    rtl = open(os.path.join(OUT, 'sys.trace')).read().split('\n')
    n = min(steps, len(rtl) - 1)
    with open(os.path.join(OUT, 'sys_model.trace'), 'w') as f:
        lines = []
        for _ in range(n + 8):
            pc = c.pc
            before = list(c.r)
            c.step()
            if c.last_exc is not None:
                lines.append('X %02x' % c.last_exc)
                continue
            wrote = [i for i in range(1, 32) if c.r[i] != before[i]]
            if wrote:
                for i in wrote:
                    lines.append('%08x %02d %016x' % (pc & 0xFFFFFFFF, i, c.r[i]))
            else:
                lines.append('%08x' % (pc & 0xFFFFFFFF))
        f.write('\n'.join(lines) + '\n')
    for i in range(min(len(lines), len(rtl))):
        if lines[i] != rtl[i]:
            print('first difference at line %d:' % (i + 1))
            for j in range(max(0, i - 8), min(len(lines), len(rtl), i + 3)):
                print('%s model %-40s rtl %s' % ('>>' if j == i else '  ', lines[j], rtl[j]))
            return
    print('%d lines agree' % min(len(lines), len(rtl)))


if __name__ == '__main__':
    main()
