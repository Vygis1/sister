"""rspstores.py - where the RTL RSP first computes something different from the model, for
runs captured from a game (tools/n64/n64rspsim.py; the RTL side is sim/tb_n64_rsp.v, which
logs its stores to sim/n64r/rtl_stores.txt).

    python tools/n64/rspstores.py DIR RUN        (DIR: the capture -- runs.hex, reads.hex, dpreads.hex)
    python tools/n64/rspstores.py DIR RUN --subset OUTDIR
                                                 (writes that one run alone, as the bench reads them)

The model's RSP is run on the run's state alone -- RDRAM zeros but the lines it read, the DP
reads answered as they were -- and every byte the RSP itself stores into DMEM is logged with
the store's PC. The two logs are held side by side, byte write against byte write, in order:
the DMA's waits make the instruction traces differ in length, but the stores do not.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import n64rsp     # noqa: E402


def read_run(d, k):
    with open(os.path.join(d, 'runs.hex')) as f:
        n = int(f.readline(), 16)
        for r in range(n):
            pc = int(f.readline(), 16)
            mem = [bytes.fromhex(f.readline().strip()) for _ in range(1024)]
            if r == k:
                run = dict(pc=pc, dmem=b''.join(mem[:512]), imem=b''.join(mem[512:]))
    with open(os.path.join(d, 'reads.hex')) as f:
        for r in range(k + 1):
            n = int(f.readline(), 16)
            lines = [f.readline().split() for _ in range(n)]
        run['reads'] = [(int(a, 16), bytes.fromhex(h)[::-1]) for a, h in lines]
        run['reads_raw'] = lines
    with open(os.path.join(d, 'dpreads.hex')) as f:
        for r in range(k + 1):
            n = int(f.readline(), 16)
            vals = [f.readline().strip() for _ in range(n)]
        run['dpr'] = [int(v, 16) for v in vals]
    return run


def write_subset(run, out):
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'runs.hex'), 'w') as f:
        f.write('1\n%03x\n' % run['pc'])
        for mem in (run['dmem'], run['imem']):
            for i in range(0, 4096, 8):
                f.write(mem[i:i + 8].hex() + '\n')
    with open(os.path.join(out, 'reads.hex'), 'w') as f:
        f.write('%x\n' % len(run['reads_raw']))
        for a, h in run['reads_raw']:
            f.write('%s %s\n' % (a, h))
    with open(os.path.join(out, 'dpreads.hex'), 'w') as f:
        f.write('%x\n' % len(run['dpr']))
        for v in run['dpr']:
            f.write('%08x\n' % v)


class Bus:
    def __init__(self, run):
        self.dmem = bytearray(run['dmem'])
        self.imem = bytearray(run['imem'])
        self.rdram = bytearray(16 << 20)       # (DMA addresses reach 16 MB: a short slice would shrink DMEM)
        for line, d in run['reads']:
            self.rdram[line << 4:(line << 4) + 16] = d
        self.mi_intr = 0
        self.rdram_writes = 0


def model_stores(run, limit=50_000_000):
    bus = Bus(run)
    rsp = n64rsp.RSP(bus)
    log = []
    cur = [0]
    dpr = list(run['dpr'])
    rsp.dp_read = lambda i: dpr.pop(0) if dpr else 0
    ow, odw = rsp.dwrite, rsp.dwb

    def dwrite(a, n, v):
        for i in range(n):
            log.append((cur[0], (a + i) & 0xFFF, (v >> (8 * (n - 1 - i))) & 0xFF))
        ow(a, n, v)

    def dwb(a, v):
        log.append((cur[0], a & 0xFFF, v & 0xFF))
        odw(a, v)
    rsp.dwrite, rsp.dwb = dwrite, dwb
    rsp.pc, rsp.npc, rsp.halted = run['pc'], (run['pc'] + 4) & 0xFFC, 0
    for _ in range(limit):
        if rsp.halted:
            break
        cur[0] = rsp.pc & 0xFFC
        rsp.step()
    return log


def rtl_stores(path):
    """the bench's log: "pc addr_dw we data we2 data2" per clock a store is made"""
    log = []
    for line in open(path):
        p = line.split()
        if len(p) != 6:
            continue
        if 'x' in p[0] + p[1] + p[2] + p[4]:
            continue
        pc, dw, we, we2 = int(p[0], 16), int(p[1], 16), int(p[2], 16), int(p[4], 16)
        for (base, m, h) in ((dw, we, p[3]), ((dw + 1) & 0x1FF, we2, p[5])):
            for k in range(8):                 # bit k = the byte at offset k; data big-endian
                if m >> k & 1:
                    b = h[2 * k:2 * k + 2]
                    log.append((pc, ((base << 3) + k) & 0xFFF, -1 if 'x' in b else int(b, 16)))   # (-1: X stored)
    return log


def model_vregs(run, limit=50_000_000):
    """every byte of a vector register that an instruction changed: (pc, reg, byte, value)"""
    bus = Bus(run)
    rsp = n64rsp.RSP(bus)
    dpr = list(run['dpr'])
    rsp.dp_read = lambda i: dpr.pop(0) if dpr else 0
    rsp.pc, rsp.npc, rsp.halted = run['pc'], (run['pc'] + 4) & 0xFFC, 0
    prev = [bytes(v) for v in rsp.vr]
    log = []
    for _ in range(limit):
        if rsp.halted:
            break
        pc = rsp.pc & 0xFFC
        ir_now = int.from_bytes(bus.imem[pc:pc + 4], 'big')
        rsp.step()
        for r in range(32):
            now = bytes(rsp.vr[r])
            if now != prev[r]:
                for g in range(16):
                    if now[g] != prev[r][g]:
                        log.append((pc, r, g, now[g], ir_now))
                prev[r] = now
    return log


def rtl_vregs(path):
    shadow = [bytearray(16) for _ in range(32)]
    log = []
    for line in open(path):
        p = line.split()
        if len(p) != 4 or 'x' in p[1] + p[2]:
            continue
        pc, r, lanes, h = int(p[0], 16), int(p[1], 16), int(p[2], 16), p[3]
        for g in range(16):
            if lanes >> g & 1:
                b = h[2 * g:2 * g + 2]
                v = -1 if 'x' in b else int(b, 16)
                if v != shadow[r][g]:
                    log.append((pc, r, g, v))
                    shadow[r][g] = v & 0xFF
    return log


def main():
    d, k = sys.argv[1], int(sys.argv[2])
    run = read_run(d, k)
    if '--vregs' in sys.argv:
        m = model_vregs(run)
        r = rtl_vregs(os.path.join('sim', 'n64r', 'rtl_vw.txt'))
        print('model: %d byte changes, rtl: %d' % (len(m), len(r)))
        for i in range(min(len(m), len(r))):
            if m[i][1:4] != r[i][1:]:
                print("first difference at change %d (the model's instruction then: %08x at %03x):" % (i, m[i][4], m[i][0]))
                for j in range(max(0, i - 6), min(i + 6, len(m), len(r))):
                    print('   %6d  model pc %03x v%02d[%2d] = %02x    rtl pc %03x v%02d[%2d] = %s %s'
                          % (j, m[j][0], m[j][1], m[j][2], m[j][3], r[j][0], r[j][1], r[j][2],
                             'X' if r[j][3] < 0 else '%02x' % r[j][3], '<--' if j == i else ''))
                for pc in sorted({m[i][0], r[i][0]}):
                    print('   instruction at %03x: %08x' % (pc, int.from_bytes(run['imem'][pc:pc + 4], 'big')))
                return
        print('the vector registers agree as far as both go')
        return
    if '--subset' in sys.argv:
        write_subset(run, sys.argv[sys.argv.index('--subset') + 1])
        print('run %d written alone' % k)
        return
    m = model_stores(run)
    r = rtl_stores(os.path.join('sim', 'n64r', 'rtl_stores.txt'))
    print('model: %d byte stores, rtl: %d' % (len(m), len(r)))
    for i in range(min(len(m), len(r))):
        if m[i][1:] != r[i][1:]:
            print('first difference at store %d:' % i)
            for j in range(max(0, i - 4), min(i + 6, len(m), len(r))):
                print('   %6d  model pc %03x [%03x] = %02x    rtl pc %03x [%03x] = %02x %s'
                      % (j, m[j][0], m[j][1], m[j][2], r[j][0], r[j][1], r[j][2], '<--' if j == i else ''))
            ir = int.from_bytes(run['imem'][m[i][0]:m[i][0] + 4], 'big')
            print('   the model\'s instruction at %03x: %08x' % (m[i][0], ir))
            return
    print('the stores agree as far as both go')


if __name__ == '__main__':
    main()
