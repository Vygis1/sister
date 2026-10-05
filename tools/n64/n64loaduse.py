"""How a game's loads are used, on the N64 model: for each load, does the next
instruction (or the one after) read what it loaded, and how -- as an ALU operand,
as store data, as an address, in a branch, or otherwise. Tells what forwarding a
load's data to the ALU alone (rtl/vr4300.v) would save.

    python tools/n64/n64loaduse.py ROM [--skip N] [--steps N]
"""
import argparse
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import n64model  # noqa: E402

LOADS = {0x20, 0x21, 0x23, 0x24, 0x25, 0x27, 0x37, 0x1A, 0x1B, 0x22, 0x26}
STORES = {0x28, 0x29, 0x2B, 0x3F, 0x2A, 0x2E, 0x2C, 0x2D}
ALU_I = {0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x19}          # ADDIU SLTI SLTIU ANDI ORI XORI LUI DADDIU
ALU_R = {0x00, 0x02, 0x03, 0x04, 0x06, 0x07, 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2F,
         0x14, 0x16, 0x17, 0x38, 0x3A, 0x3B, 0x3C, 0x3E, 0x3F}      # shifts, ADDU SUBU logic SLT(U) DADDU DSUBU D-shifts
BRANCH = {0x01, 0x04, 0x05, 0x06, 0x07, 0x14, 0x15, 0x16, 0x17}


def use_of(w, reg):
    """how instruction w reads reg: None, or a kind"""
    op, rs, rt = w >> 26, (w >> 21) & 31, (w >> 16) & 31
    if op == 0:
        fn = w & 63
        reads = []
        if fn in (0x00, 0x02, 0x03, 0x38, 0x3A, 0x3B, 0x3C, 0x3E, 0x3F):
            reads = [rt]
        elif fn in (0x08, 0x09):
            reads = [rs]
        elif fn in (0x10, 0x12):
            reads = []
        else:
            reads = [rs, rt]
        if reg not in reads or reg == 0:
            return None
        if fn in ALU_R:
            return 'alu'
        if fn in (0x08, 0x09):
            return 'jump'
        if fn in (0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F):
            return 'mul/div'
        return 'other'
    if op in LOADS or op in (0x31, 0x35):
        return 'address' if rs == reg and reg else None
    if op in STORES or op in (0x39, 0x3D):
        if rs == reg and reg:
            return 'address'
        if rt == reg and reg and op not in (0x39, 0x3D):
            return 'store data'
        return None
    if op in ALU_I:
        return 'alu' if rs == reg and reg and op != 0x0F else None
    if op in BRANCH:
        if reg and (rs == reg or (op in (0x04, 0x05, 0x14, 0x15) and rt == reg)):
            return 'branch'
        return None
    if op == 0x11 and ((w >> 21) & 31) in (4, 5):
        return 'other' if rt == reg and reg else None   # MTC1/DMTC1
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rom'); ap.add_argument('--skip', type=int, default=150_000_000); ap.add_argument('--steps', type=int, default=5_000_000)
    a = ap.parse_args()
    rom = open(a.rom, 'rb').read()
    if rom[:4] == b'\x37\x80\x40\x12':
        rom = bytes(b for i in range(0, len(rom), 2) for b in (rom[i + 1], rom[i]))
    m = n64model.N64(rom); m.fast_boot(); c = m.cpu
    for _ in range(a.skip):
        c.step()
    def word(pc):
        try:
            return m.read(c.translate(pc, False, 4), 4)
        except Exception:
            return None
    n = loads = 0
    next1 = collections.Counter(); next2 = collections.Counter()
    for _ in range(a.steps):
        pc = c.pc
        if 0x80246DD0 <= (pc & 0xFFFFFFFF) <= 0x80246DDF:
            c.step(); continue
        w = word(pc)
        if w is not None:
            n += 1
            if (w >> 26) in LOADS:
                loads += 1
                rt = (w >> 16) & 31
                w1, w2 = word(pc + 4), word(pc + 8)
                k1 = use_of(w1, rt) if w1 is not None else None
                if k1:
                    next1[k1] += 1
                else:
                    k2 = use_of(w2, rt) if w2 is not None else None
                    if k2:
                        next2[k2] += 1
        c.step()
    print('%d instructions outside the idle loop, %d loads (%.1f%%)' % (n, loads, 100.0 * loads / max(1, n)))
    print('used by the very next instruction (now 2 stalls):')
    for k, v in next1.most_common():
        print('  %-11s %5.1f%% of loads' % (k, 100.0 * v / loads))
    print('used by the one after (now 1 stall):')
    for k, v in next2.most_common():
        print('  %-11s %5.1f%% of loads' % (k, 100.0 * v / loads))
    s_now = 2 * sum(next1.values()) + sum(next2.values())
    fwd = ('alu', 'store data')
    s_new = sum(v * (1 if k in fwd else 2) for k, v in next1.items()) + sum(v * (0 if k in fwd else 1) for k, v in next2.items())
    print('stall clocks per 1000 instructions: now %.0f, with ALU/store-data forwarding from W %.0f' % (1000.0 * s_now / n, 1000.0 * s_new / n))


if __name__ == '__main__':
    main()
