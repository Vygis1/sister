"""How much dual issue would save the RSP, from the model's trace of a game's RSP runs
(sim/n64r/model.trace, tools/n64/n64rspsim.py): each instruction followed in program
order by the next, could the two go in one clock?

  full:  one scalar (SU) + one vector (VU) op either way round, no VR dependency, no
         branch or delay slot (the real RSP's rule, roughly -- SGI guide, ares canDualIssue)
  narrow: a scalar ALU op first and a vector computation second, the pair 8-aligned in
         IMEM (one doubleword fetch) -- what rtl/n64_rsp.v could do cheaply

    python tools/n64/n64rsppairs.py [TRACE]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TRACE = os.path.join(HERE, '..', '..', 'sim', 'n64r', 'model.trace')


def kind(w):
    op = w >> 26
    if op == 0x12:                                   # COP2
        return 'vu' if (w >> 25) & 1 else 'su_vr'   # vector op / MFC2 MTC2 CFC2 CTC2
    if op in (0x32, 0x3A):
        return 'su_vr'                               # LWC2 / SWC2 (vector loads/stores)
    if op in (0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x01) or (op == 0 and (w & 63) in (8, 9)):
        return 'branch'
    if op == 0 and (w & 63) == 0x0D:
        return 'other'                               # BREAK
    if op == 0x10:
        return 'su_c0'
    if op in (0x20, 0x21, 0x23, 0x24, 0x25, 0x27, 0x28, 0x29, 0x2B):
        return 'su_mem'
    return 'su_alu'


def vu_regs(w):
    vt, vs, vd = (w >> 16) & 31, (w >> 11) & 31, (w >> 6) & 31
    return {vs, vt}, vd


def main():
    seq = []
    for line in open(sys.argv[1] if len(sys.argv) > 1 else TRACE):
        p = line.split()
        if len(p) == 2 and p[0] != 'RUN':
            seq.append((int(p[0], 16), int(p[1], 16)))
        elif p and p[0] == 'RUN':
            seq.append(None)
    n = sum(1 for x in seq if x)
    full = narrow = 0
    i = 0
    prev_branch = False
    while i < len(seq) - 1:
        a, b = seq[i], seq[i + 1]
        if a is None or b is None:
            i += 1; prev_branch = False; continue
        ka, kb = kind(a[1]), kind(b[1])
        seqok = b[0] == a[0] + 4 and not prev_branch
        paired = False
        if seqok and ka != 'branch' and kb != 'branch' and ka != 'other' and kb != 'other':
            if ka.startswith('su') and kb == 'vu':
                rd_su = None
                if ka == 'su_vr' and a[1] >> 26 == 0x32:
                    rd_su = (a[1] >> 16) & 31                 # LWC2 writes vt
                srcs, _ = vu_regs(b[1])
                if rd_su is None or rd_su not in srcs:
                    full += 1; paired = True
                    if ka == 'su_alu' and a[0] % 8 == 0:
                        narrow += 1
            elif ka == 'vu' and kb.startswith('su'):
                _, vd = vu_regs(a[1])
                rd_ok = not (kb == 'su_vr' and ((b[1] >> 16) & 31) == vd)
                if rd_ok:
                    full += 1; paired = True
        prev_branch = (ka == 'branch')
        i += 2 if paired else 1
    print('%d instructions; pairs, full rule: %d (%.1f%% fewer clocks), narrow: %d (%.1f%%)'
          % (n, full, 100.0 * full / n, narrow, 100.0 * narrow / n))


if __name__ == '__main__':
    main()
