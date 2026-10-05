"""The instruction mix of a game on the N64 model: what the CPU spends its
instructions on, the floating-point operations by function and format especially,
to tell which ones the RTL's FPU has to make fast.

    python tools/n64/n64opmix.py ROM [--steps N] [--skip N]

(SM64's idle loop, 0x80246DD0-DF, is left out: it is what the CPU does with
nothing to do.)
"""
import argparse
import collections
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import n64model  # noqa: E402

FPFN = {0x00: 'add', 0x01: 'sub', 0x02: 'mul', 0x03: 'div', 0x04: 'sqrt', 0x05: 'abs', 0x06: 'mov', 0x07: 'neg',
        0x08: 'round.l', 0x09: 'trunc.l', 0x0C: 'round.w', 0x0D: 'trunc.w', 0x0E: 'ceil.w', 0x0F: 'floor.w',
        0x20: 'cvt.s', 0x21: 'cvt.d', 0x24: 'cvt.w', 0x25: 'cvt.l'}
FMT = {16: 's', 17: 'd', 20: 'w', 21: 'l'}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rom')
    ap.add_argument('--steps', type=int, default=20_000_000)
    ap.add_argument('--skip', type=int, default=0, help='instructions to run first, uncounted')
    a = ap.parse_args()
    rom = open(a.rom, 'rb').read()
    if rom[:4] == b'\x37\x80\x40\x12':
        rom = bytes(b for i in range(0, len(rom), 2) for b in (rom[i + 1], rom[i]))
    m = n64model.N64(rom); m.fast_boot(); c = m.cpu
    for _ in range(a.skip):
        c.step()
    ops = collections.Counter(); fp = collections.Counter(); n = idle = 0
    t0 = time.time()
    for _ in range(a.steps):
        pc = c.pc & 0xFFFFFFFF
        if 0x80246DD0 <= pc <= 0x80246DDF:
            idle += 1
        else:
            try:
                w = m.read(c.translate(c.pc, False, 4), 4)
            except Exception:
                w = None
            if w is not None:
                op = w >> 26
                n += 1
                if op == 0x11:
                    rs, fn = (w >> 21) & 31, w & 63
                    if rs >= 16:
                        name = 'c.cond' if fn >= 0x30 else FPFN.get(fn, 'fn%02x' % fn)
                        fp['%s.%s' % (name, FMT.get(rs, rs))] += 1
                    else:
                        fp[{0: 'mfc1', 1: 'dmfc1', 2: 'cfc1', 4: 'mtc1', 5: 'dmtc1', 6: 'ctc1', 8: 'bc1'}.get(rs, 'cop1.%d' % rs)] += 1
                    ops['cop1'] += 1
                elif op in (0x31, 0x35, 0x39, 0x3D):
                    ops['fp load/store'] += 1
                elif op in (0x20, 0x21, 0x23, 0x24, 0x25, 0x27, 0x37, 0x1A, 0x1B, 0x22, 0x26):
                    ops['load'] += 1
                elif op in (0x28, 0x29, 0x2B, 0x3F, 0x2A, 0x2E, 0x2C, 0x2D):
                    ops['store'] += 1
                elif op in (0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x14, 0x15, 0x16, 0x17, 0x01) or (op == 0 and (w & 63) in (8, 9)):
                    ops['branch/jump'] += 1
                elif op == 0 and (w & 63) in (0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F):
                    ops['mul/div'] += 1
                else:
                    ops['alu/other'] += 1
        c.step()
    dt = time.time() - t0
    print('%d instructions (%d of them the idle loop) in %.0f s' % (a.steps, idle, dt))
    print('of the %d outside it:' % n)
    for k, v in ops.most_common():
        print('  %-14s %5.1f%%' % (k, 100.0 * v / n))
    print('the COP1 instructions:')
    for k, v in fp.most_common(24):
        print('  %-14s %5.2f%%' % (k, 100.0 * v / n))


if __name__ == '__main__':
    main()
