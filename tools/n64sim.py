"""An N64 ROM, ready for the CPU bench, and the model's trace to check it against.

    python tools/n64sim.py ROM.N64 [--steps N]      writes sim/n64/: rdram.hex, pifrom.hex, model.trace
    python tools/n64sim.py --compare                 compares sim/n64/model.trace with the bench's rtl.trace

The bench (sim/tb_vr4300.v) boots the RTL from the same stub the model uses
(tools/n64model.py stub_boot), with RDRAM preloaded from rdram.hex, and writes
every retired instruction: its address, the register it wrote and the value.
The model writes the same for the same ROM. The comparison stops at the first
line that differs and shows the lines around it.

Count and Random are left out of the comparison: they count clocks, and the
model counts instructions.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import n64model  # noqa: E402

OUT = os.path.join(HERE, '..', 'sim', 'n64')


def prepare(rom_path, steps):
    os.makedirs(OUT, exist_ok=True)
    m = n64model.N64(open(rom_path, 'rb').read())
    stub = m.stub_boot()
    # RDRAM: only the doublewords that are not zero, with addresses
    with open(os.path.join(OUT, 'rdram.hex'), 'w') as f:
        mem = m.rdram
        last = -2
        for i in range(0, len(mem), 8):
            dw = mem[i:i + 8]
            if any(dw):
                if i // 8 != last + 1:
                    f.write('@%x\n' % (i // 8))
                f.write(dw.hex() + '\n')
                last = i // 8
    with open(os.path.join(OUT, 'pifrom.hex'), 'w') as f:
        for w in stub:
            f.write('%08x\n' % w)
    # the model's trace
    c = m.cpu
    with open(os.path.join(OUT, 'model.trace'), 'w') as f:
        for _ in range(steps):
            pc = c.pc
            before = list(c.r)
            c.step()
            if c.last_exc is not None:
                f.write('X %02x' % c.last_exc + '\n')
                continue
            # a write is recorded when the value changes (the bench does the same)
            wrote = [i for i in range(1, 32) if c.r[i] != before[i]]
            if wrote:
                for i in wrote:
                    f.write('%08x %02d %016x' % (pc & 0xFFFFFFFF, i, c.r[i]) + '\n')
            else:
                f.write('%08x' % (pc & 0xFFFFFFFF) + '\n')
    open(os.path.join(OUT, 'rom.path'), 'w').write(os.path.abspath(rom_path))
    print('wrote %s (stub %d words, %d steps traced)' % (OUT, len(stub), steps))


def compare_ram(steps, png=None):
    """the bench's RDRAM after `steps` against the model's after the same"""
    rom = open(os.path.join(OUT, 'rom.path')).read().strip()
    m = n64model.N64(open(rom, 'rb').read())
    m.stub_boot()
    for _ in range(steps):
        m.cpu.step()
    lines = open(os.path.join(OUT, 'rtl_rdram.hex')).read().split()
    rtl = bytearray(b''.join(bytes.fromhex(l) for l in lines))
    bad = [i for i in range(0, min(len(rtl), len(m.rdram)), 8) if rtl[i:i + 8] != m.rdram[i:i + 8]]
    if bad:
        print('RDRAM: %d doublewords differ; first at %06x: rtl %s model %s'
              % (len(bad), bad[0], rtl[bad[0]:bad[0] + 8].hex(), m.rdram[bad[0]:bad[0] + 8].hex()))
    else:
        print('RDRAM: all 8 MB agree')
    if png:
        m.rdram = rtl                      # the picture the RTL drew, through the model's VI
        w, h, rgb = m.framebuffer()
        if w:
            n64model.write_png(png, w, h, rgb)
            print("the RTL's framebuffer: %dx%d -> %s" % (w, h, png))
    return not bad


def compare():
    a = open(os.path.join(OUT, 'model.trace')).read().split('\n')
    b = open(os.path.join(OUT, 'rtl.trace')).read().split('\n')
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            print('first difference at line %d:' % (i + 1))
            for j in range(max(0, i - 6), min(n, i + 3)):
                mark = '>>' if j == i else '  '
                print('%s model %-40s rtl %s' % (mark, a[j], b[j]))
            return False
    print('%d lines agree (model %d, rtl %d)' % (n, len(a), len(b)))
    return True


if __name__ == '__main__':
    if '--compare' in sys.argv:
        ok = compare()
        if '--ram' in sys.argv:
            steps = int(sys.argv[sys.argv.index('--ram') + 1])
            png = sys.argv[sys.argv.index('--png') + 1] if '--png' in sys.argv else None
            ok = compare_ram(steps, png) and ok
        sys.exit(0 if ok else 1)
    steps = int(sys.argv[sys.argv.index('--steps') + 1]) if '--steps' in sys.argv else 200000
    prepare(sys.argv[1], steps)
