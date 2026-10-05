"""The RSP by itself: the model's runs of it, for sim/tb_n64_rsp.v to repeat.

    python tools/n64/n64rspsim.py ROM [--runs N]       writes sim/n64r/
    ./tools/sim.sh tb_n64_rsp
    python tools/n64/n64rspsim.py --check              the RTL's runs against the model's

The model runs the ROM (a krom RSP test, say). Each time the CPU starts the RSP
(clears SP_STATUS's halt), the RSP's starting point is saved: DMEM, IMEM, the PC.
The model then runs on until the RSP halts, and what it did is saved too: the
instructions it ran (address and word) and the DMEM it left. The bench loads
each start through the RSP's CPU port, lets it run to its halt, and writes the
same two things; --check compares them. The RSP's registers carry over from run
to run in both, as on the chip.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import n64model  # noqa: E402

OUT = os.path.join(HERE, '..', '..', 'sim', 'n64r')
NL = chr(10)


def vstate(rsp):
    """the vector unit's state as text: the registers, the accumulator, the flags"""
    lines = ['v%02d %s' % (i, bytes(rsp.vr[i]).hex()) for i in range(32)]
    lines.append('acc ' + ' '.join('%04x%04x%04x' % (rsp.acch[n], rsp.accm[n], rsp.accl[n]) for n in range(8)))
    bits = lambda f: sum(int(f[n]) << n for n in range(8))
    lines.append('flags %02x %02x %02x %02x %02x' % (bits(rsp.vcoh), bits(rsp.vcol), bits(rsp.vcch), bits(rsp.vccl), bits(rsp.vce)))
    return lines


def prepare(rom_path, max_runs, steps=20_000_000, skip=0):
    os.makedirs(OUT, exist_ok=True)
    m = n64model.N64(open(rom_path, 'rb').read())
    m.fast_boot()
    if hasattr(m, 'rdp'):
        m.rdp.draw = False                 # (a game's pictures are not wanted here)
    rsp = m.rsp
    runs = []
    trace = []
    orig_step = rsp.step
    # the RDRAM lines each run's DMAs read, as they were when first read
    reads = {}
    orig_dma = rsp.dma
    # and the DP registers each run read, in order (the bench has no RDP: it answers these)
    dpr = []
    orig_dpr = rsp.dp_read

    def dp_read(i):
        v = orig_dpr(i)
        if not rsp.halted:
            dpr.append(v & 0xFFFFFFFF)
        return v
    rsp.dp_read = dp_read

    def dma(read):
        if read and not rsp.halted:
            p = rsp.pend
            d = p['dram'] & 0xFFFFF8
            for row in range(p['count'] + 1):
                for o in range(0, p['length'] + 8, 8):
                    a = (d + o) & 0xFFFFF0
                    if a not in reads and a + 16 <= len(m.rdram):
                        reads[a] = bytes(m.rdram[a:a + 16])
                d = (d + p['length'] + 8 + p['skip']) & 0xFFFFF8
        orig_dma(read)
    rsp.dma = dma
    started = [0]

    def step():
        if not rsp.halted:
            pc = rsp.pc & 0xFFC
            trace.append('%03x %08x' % (pc, int.from_bytes(m.imem[pc:pc + 4], 'big')))
        orig_step()
    rsp.step = step
    c = m.cpu
    was_halted = True
    last = 0
    for i in range(steps):
        if runs and i - last > 2_000_000:
            break                          # the RSP has not run for a while: the test is done
        if was_halted and not rsp.halted:
            pass
        c.step()
        if was_halted and not rsp.halted:
            # started: what it starts from (the step above ran the CPU's write;
            # the RSP's first instruction is next)
            started[0] += 1
            reads.clear()
            dpr.clear()
            if started[0] > skip:
                runs.append({'dmem': bytes(m.dmem), 'imem': bytes(m.imem), 'pc': rsp.pc & 0xFFC, 't0': len(trace)})
            last = i
        if not was_halted and rsp.halted and runs and 'dmem_end' not in runs[-1]:
            runs[-1]['dmem_end'] = bytes(m.dmem)
            runs[-1]['vstate'] = vstate(rsp)
            runs[-1]['t1'] = len(trace)
            runs[-1]['reads'] = dict(reads)
            runs[-1]['dpr'] = list(dpr)
            last = i
            if len(runs) >= max_runs:
                break
        if started[0] <= skip:
            trace.clear()
        was_halted = rsp.halted
    runs = [r for r in runs if 'dmem_end' in r]
    with open(os.path.join(OUT, 'runs.hex'), 'w') as f:
        # per run: pc, then DMEM and IMEM as 1024 doublewords (big-endian)
        f.write('%x\n' % len(runs))
        for r in runs:
            f.write('%03x\n' % r['pc'])
            for mem in (r['dmem'], r['imem']):
                for i in range(0, 4096, 8):
                    f.write(mem[i:i + 8].hex() + '\n')
    with open(os.path.join(OUT, 'dpreads.hex'), 'w') as f:
        # per run: how many DP register reads, then their values
        for r in runs:
            f.write('%x' % len(r['dpr']) + NL)
            for v in r['dpr']:
                f.write('%08x' % v + NL)
    with open(os.path.join(OUT, 'reads.hex'), 'w') as f:
        # per run: how many lines, then "line data" (data byte 15 first, as the bench's memory)
        for r in runs:
            f.write('%x' % len(r['reads']) + NL)
            for a, d in sorted(r['reads'].items()):
                f.write('%05x %s' % (a >> 4, d[::-1].hex()) + NL)
    with open(os.path.join(OUT, 'model.trace'), 'w') as f:
        for k, r in enumerate(runs):
            f.write('RUN %d\n' % k)
            for line in trace[r['t0']:r['t1']]:
                f.write(line + '\n')
    with open(os.path.join(OUT, 'model_vstate.txt'), 'w') as f:
        for k, r in enumerate(runs):
            f.write('RUN %d' % k + NL + NL.join(r['vstate']) + NL)
    with open(os.path.join(OUT, 'model_dmem.hex'), 'w') as f:
        for r in runs:
            for i in range(0, 4096, 8):
                f.write(r['dmem_end'][i:i + 8].hex() + '\n')
    print('%d runs of the RSP, %d instructions' % (len(runs), sum(r['t1'] - r['t0'] for r in runs)))


POLL_REGS = (4, 5, 6, 7, 11)             # SP_STATUS, DMA_FULL, DMA_BUSY, SEMAPHORE, DPC_STATUS


def poll_pcs(lines):
    """the addresses of polling loops: an MFC0 of a register that DMA timing
    changes, up to the branch back to it and its delay slot. The model's DMAs are
    done at once and the RTL's take time, so these loops go round different
    numbers of times; they are left out of both traces."""
    pcs = set()
    for i, l in enumerate(lines):
        p = l.split()
        if len(p) != 2 or p[0] == 'RUN':
            continue
        w = int(p[1], 16)
        if w >> 26 == 0x10 and (w >> 21) & 31 == 0 and (w >> 11) & 31 in POLL_REGS:
            pc = int(p[0], 16)
            for j in range(i + 1, min(i + 4, len(lines))):
                q = lines[j].split()
                if len(q) != 2 or q[0] == 'RUN':
                    break
                v, qpc = int(q[1], 16), int(q[0], 16)
                if v >> 26 in (4, 5, 6, 7) and ((qpc + 4 + 4 * (((v & 0xFFFF) ^ 0x8000) - 0x8000)) & 0xFFC) == pc:
                    pcs.update(range(pc, qpc + 8, 4))
                    break
    return pcs


def check():
    a = open(os.path.join(OUT, 'model.trace')).read().split('\n')
    b = open(os.path.join(OUT, 'rtl.trace')).read().split('\n')
    skip = poll_pcs(a) | poll_pcs(b)
    keep = lambda l: not (len(l.split()) == 2 and l.split()[0] != 'RUN' and int(l.split()[0], 16) in skip)
    a = [l for l in a if keep(l)]
    b = [l for l in b if keep(l)]
    ok = True
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            print('trace: first difference at line %d: model %s / rtl %s' % (i + 1, a[i], b[i]))
            for j in range(max(0, i - 5), i + 2):
                print('   %-20s %s' % (a[j] if j < len(a) else '', b[j] if j < len(b) else ''))
            ok = False
            break
    else:
        if len(a) != len(b):
            print('trace: model %d lines, rtl %d' % (len(a), len(b)))
            ok = False
        else:
            print('trace: %d lines agree' % len(a))
    va = open(os.path.join(OUT, 'model_vstate.txt')).read().split(NL)
    vb = open(os.path.join(OUT, 'rtl_vstate.txt')).read().split(NL) if os.path.exists(os.path.join(OUT, 'rtl_vstate.txt')) else []
    run = ''
    for i in range(min(len(va), len(vb))):
        if va[i].startswith('RUN'):
            run = va[i]
        if va[i] != vb[i]:
            print('vector state: first difference in %s: model %s / rtl %s' % (run, va[i], vb[i]))
            ok = False
            break
    ma = open(os.path.join(OUT, 'model_dmem.hex')).read().split()
    mb = open(os.path.join(OUT, 'rtl_dmem.hex')).read().split()
    bad = [i for i in range(min(len(ma), len(mb))) if ma[i] != mb[i]]
    if bad or len(ma) != len(mb):
        i = bad[0] if bad else 0
        print('DMEM: %d doublewords differ; first: run %d, offset %03x: model %s rtl %s'
              % (len(bad), i // 512, (i % 512) * 8, ma[i] if bad else '', mb[i] if bad else ''))
        ok = False
    else:
        print('DMEM: the same after every run')
    if '--runs' in sys.argv:
        per_run(a, b)
    return ok


def per_run(a, b):
    """each run on its own: which agree (trace and DMEM), and where each that does
    not first goes its own way, with the run's first instructions (its microcode)"""
    def split(lines):
        runs, cur = [], None
        for l in lines:
            if l.startswith('RUN'):
                cur = []
                runs.append(cur)
            elif cur is not None and l:
                cur.append(l)
        return runs
    ra, rb = split(a), split(b)
    ma = open(os.path.join(OUT, 'model_dmem.hex')).read().split()
    mb = open(os.path.join(OUT, 'rtl_dmem.hex')).read().split()
    good = 0
    for k in range(min(len(ra), len(rb))):
        da = ma[512 * k:512 * k + 512]
        db = mb[512 * k:512 * k + 512]
        if ra[k] == rb[k] and da == db:
            good += 1
            continue
        i = next((j for j in range(min(len(ra[k]), len(rb[k]))) if ra[k][j] != rb[k][j]), min(len(ra[k]), len(rb[k])))
        dd = sum(1 for x, y in zip(da, db) if x != y)
        print('run %3d: %s; trace from %d: model %s / rtl %s; %d DMEM doublewords differ' % (
            k, ' '.join(ra[k][j].split()[0] for j in range(min(3, len(ra[k])))), i,
            ra[k][i] if i < len(ra[k]) else 'end', rb[k][i] if i < len(rb[k]) else 'end', dd))
    print('%d of %d runs agree' % (good, min(len(ra), len(rb))))


if __name__ == '__main__':
    if '--check' in sys.argv:
        sys.exit(0 if check() else 1)
    runs = int(sys.argv[sys.argv.index('--runs') + 1]) if '--runs' in sys.argv else 50
    skip = int(sys.argv[sys.argv.index('--skip') + 1]) if '--skip' in sys.argv else 0
    steps = int(sys.argv[sys.argv.index('--steps') + 1]) if '--steps' in sys.argv else 20_000_000
    prepare(sys.argv[1], runs, steps, skip)
