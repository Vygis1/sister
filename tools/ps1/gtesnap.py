"""gtesnap.py - the PlayStation's GTE checked on the board, against tools/ps1/gte.py, on the
commands the running game actually gives it: the GTE stopped (ps1_gte.v's debug snapshot,
console 0x190 / 0x194) just before a command and every register read as MFC2/CFC2 sees it,
the command run and every register read again; the model, loaded with the first set, runs the
same command and must read back the second.

    python tools/ps1/gtesnap.py [N] [SKIP]     N snapshots (default 20), each SKIP commands apart
                                               (default random 0-2000); through pc/pad.py's port

Each snapshot holds the GTE (and so the game) for the moment it takes to read: ~260 link calls.
"""
import os
import random
import socket
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gte  # noqa: E402

NES = 0x80000
SNAP, IDX = NES + 0x190, NES + 0x194
OPS = {0x01: 'RTPS', 0x06: 'NCLIP', 0x0C: 'OP', 0x10: 'DPCS', 0x11: 'INTPL', 0x12: 'MVMVA', 0x13: 'NCDS',
       0x14: 'CDP', 0x16: 'NCDT', 0x1B: 'NCCS', 0x1C: 'CC', 0x1E: 'NCS', 0x20: 'NCT', 0x28: 'SQR', 0x29: 'DCPL',
       0x2A: 'DPCT', 0x2D: 'AVSZ3', 0x2E: 'AVSZ4', 0x30: 'RTPT', 0x3D: 'GPF', 0x3E: 'GPL', 0x3F: 'NCCT'}


class Port:
    def __init__(self):
        self.f = socket.create_connection(('127.0.0.1', 5557), timeout=10).makefile('rwb')

    def r(self, a):
        self.f.write(b'R %x\n' % a); self.f.flush()
        return int(self.f.readline().decode().strip(), 16)

    def w(self, a, v):
        self.f.write(b'W %x %x\n' % (a, v)); self.f.flush(); self.f.readline()


def wait(p, bit):
    for _ in range(400):
        st = p.r(SNAP)
        if (st >> bit) & 1:
            return st
    return None


def regs(p):
    out = []
    for i in range(64):
        p.w(IDX, i)
        out.append(p.r(IDX))
    return out[0:32], out[32:64]


def snapshot(p, skip):
    p.w(SNAP, 0)
    p.w(SNAP, 0x80000000 | skip)
    st = wait(p, 25)                  # stopped before it
    if st is None:
        p.w(SNAP, 0)
        return None
    word = st & 0x1FFFFFF
    bd, bc = regs(p)
    p.w(SNAP, 0xC0000000 | skip)      # go
    if wait(p, 26) is None:           # stopped after it
        p.w(SNAP, 0)
        return None
    ad, ac = regs(p)
    p.w(SNAP, 0)                      # (released: the game goes on)
    return word, bd, bc, ad, ac


def load(bd, bc):
    """the model, with the registers as they read: the FIFO and the read-only ones raw"""
    g = gte.GTE()
    for i in range(32):
        if i == 15 or i == 29 or i == 31:
            continue                  # (SXYP reads SXY2; ORGB and LZCR follow from the others)
        if i == 28:
            continue                  # (IRGB's write would overwrite IR1-3 with 5-bit values)
        g.write_data(i, bd[i])
    for i in range(31):
        g.write_ctrl(i, bc[i])
    g.c[31] = bc[31] & 0x7FFFF000
    return g


def check(word, bd, bc, ad, ac):
    g = load(bd, bc)
    g.op(word)
    bad = []
    for i in range(32):
        if g.read_data(i) & 0xFFFFFFFF != ad[i]:
            bad.append('d%d model %08x board %08x' % (i, g.read_data(i) & 0xFFFFFFFF, ad[i]))
        if g.read_ctrl(i) & 0xFFFFFFFF != ac[i]:
            bad.append('c%d model %08x board %08x' % (i, g.read_ctrl(i) & 0xFFFFFFFF, ac[i]))
    return bad


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    fixed = int(sys.argv[2]) if len(sys.argv) > 2 else None
    p = Port()
    stats = {}
    for k in range(n):
        s = snapshot(p, fixed if fixed is not None else random.randrange(0, 2000))
        if not s:
            print('no command came (is a game running?)'); continue
        word, bd, bc, ad, ac = s
        name = OPS.get(word & 0x3F, '%02x' % (word & 0x3F))
        bad = check(word, bd, bc, ad, ac)
        stats.setdefault(name, [0, 0])[0] += 1
        if bad:
            stats[name][1] += 1
            print('%-6s %07x DIFFERS: %s' % (name, word, '; '.join(bad[:6])))
            print('   before data %s' % ' '.join('%08x' % v for v in bd))
            print('   before ctrl %s' % ' '.join('%08x' % v for v in bc))
    print('commands checked:', ', '.join('%s %d (%d differ)' % (k, v[0], v[1]) for k, v in sorted(stats.items())))


if __name__ == '__main__':
    main()
