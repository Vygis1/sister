"""cachemodel.py - the processor's cache hierarchy, replayed against a real game's trace.

    python tools/ps1/cachemodel.py build/syphon_trace.bin [ENTRIES]

The trace comes from tools/ps1/memtrace.py. The hierarchy is the core's (ps1_top.v):

  L1I  ps1_icache u_icache: 4 KB direct-mapped, 16-byte lines, answers in the cycle asked
  L1D  ps1_icache u_dcache: 4 KB direct-mapped, filled by data reads only, a word store patches
       a line it holds (WR_PATCH)
  L2   ps1_cache ccache: 128 KB direct-mapped, write-back, a store that misses fetches the line
       first; the DMA's reads go round it, its writes (the ordering-table clear) allocate lines

Each configuration is charged in clocks the processor waits: an L2 hit HIT clocks, a trip to DDR3
MISS, a dirty line written back on the way WB more. Absolute numbers are a model; the
DIFFERENCES between configurations are what this is for.
"""
import sys, array

HIT, MISS, WB = 3, 22, 4


class DM:
    """a direct-mapped (ways=1) or LRU set-associative cache of 16-byte lines"""
    def __init__(self, kb, ways=1, linebytes=16):
        self.lb = linebytes.bit_length() - 1
        self.sets = (kb * 1024) // linebytes // ways
        self.ways = ways
        self.tag = [[-1] * self.sets for _ in range(ways)]
        self.dirty = [[False] * self.sets for _ in range(ways)]
        self.wv = [[15] * self.sets for _ in range(ways)]     # word-valid mask (no-fetch stores)
        self.age = [[0] * self.sets for _ in range(ways)]
        self.t = 0

    def find(self, line):
        s = line % self.sets
        for w in range(self.ways):
            if self.tag[w][s] == line: return s, w
        return s, -1

    def touch(self, s, w):
        self.t += 1; self.age[w][s] = self.t

    def victim(self, s):
        if self.ways == 1: return 0
        best = 0
        for w in range(1, self.ways):
            if self.tag[w][s] < 0: return w
            if self.age[w][s] < self.age[best][s]: best = w
        return best if self.tag[best][s] >= 0 or True else 0

    def drop(self, line):
        s, w = self.find(line)
        if w >= 0: self.tag[w][s] = -1


def run(trace, l1i_kb=4, l1d_kb=4, l2_kb=128, l2_ways=1, l2_line=16, nofetch=False, prefetch=0, ipref=0, sbuf=0, nsb=1, sbhit=HIT + 2):
    l1i = DM(l1i_kb); l1d = DM(l1d_kb)
    l2 = DM(l2_kb, l2_ways, l2_line)
    sh2 = l2.lb
    st = dict(stall=0, l2_hit=0, l2_miss=0, wb=0, fetch=0, load=0, store=0, l1i_miss=0, l1d_miss=0, st_miss=0, vbl=0, pf=0, pf_used=0)
    pf_pending = set()
    sbs = [[] for _ in range(nsb)]; sbr = [0]; st['sb_hit'] = 0

    def l2_read(a, cpu=True, allow_pf=True):
        line = a >> sh2
        s, w = l2.find(line)
        if w >= 0:
            word = (a >> 2) & 3
            if nofetch and not (l2.wv[w][s] >> word) & 1:
                l2.wv[w][s] = 15; l2.touch(s, w)
                st['l2_miss'] += 1; return MISS                # the rest of the line fetched now
            l2.touch(s, w)
            if line in pf_pending: pf_pending.discard(line); st['pf_used'] += 1
            st['l2_hit'] += 1; return HIT
        cost = MISS
        if sbuf:
            for b_ in sbs:
                if line in b_:
                    cost = sbhit; st['sb_hit'] += 1
                    k = b_.index(line); top = b_[-1]
                    del b_[:k + 1]
                    b_.extend(range(top + 1, top + 2 + k))      # it runs on ahead by what was used
                    break
            else:
                sbs[sbr[0]][:] = list(range(line + 1, line + 1 + sbuf)); sbr[0] = (sbr[0] + 1) % nsb
        w = l2.victim(s)
        if l2.tag[w][s] >= 0 and l2.dirty[w][s]: cost += WB; st['wb'] += 1
        l2.tag[w][s] = line; l2.dirty[w][s] = False; l2.wv[w][s] = 15; l2.touch(s, w)
        if cost != sbhit or not sbuf: st['l2_miss'] += 1
        npf = prefetch if allow_pf else 0
        for k in range(1, npf + 1):                    # the next lines, in the same trip (bandwidth, not wait)
            nl = line + k; s2, w2 = l2.find(nl)
            if w2 < 0:
                w2 = l2.victim(s2)
                if l2.tag[w2][s2] >= 0 and l2.dirty[w2][s2]: st['wb'] += 1
                l2.tag[w2][s2] = nl; l2.dirty[w2][s2] = False; l2.wv[w2][s2] = 15; l2.touch(s2, w2)
                pf_pending.add(nl); st['pf'] += 1
        return cost

    for e in trace:
        kind = e >> 29; a = e & 0x1FFFFFFF
        if kind == 0:
            st['fetch'] += 1
            line = a >> 4; s = line % l1i.sets
            if l1i.tag[0][s] != line:
                st['l1i_miss'] += 1
                c = l2_read(a, allow_pf=True)
                if ipref and c > HIT: c = c                 # (a fetch miss's next line: see prefetch)
                st['stall'] += c
                l1i.tag[0][s] = line
        elif kind == 1:
            st['load'] += 1
            line = a >> 4; s = line % l1d.sets
            if l1d.tag[0][s] != line:
                st['l1d_miss'] += 1
                st['stall'] += l2_read(a)
                l1d.tag[0][s] = line
        elif kind == 2:
            st['store'] += 1
            line2 = a >> sh2
            s, w = l2.find(line2)
            if w >= 0:
                l2.dirty[w][s] = True; l2.touch(s, w)
                if nofetch: l2.wv[w][s] |= 1 << ((a >> 2) & 3)
                st['stall'] += 1
            else:
                st['st_miss'] += 1
                w = l2.victim(s)
                c = 1 if nofetch else MISS
                if l2.tag[w][s] >= 0 and l2.dirty[w][s]: c += WB; st['wb'] += 1
                l2.tag[w][s] = line2; l2.dirty[w][s] = True; l2.touch(s, w)
                l2.wv[w][s] = (1 << ((a >> 2) & 3)) if nofetch else 15
                st['stall'] += c
                if not nofetch: st['l2_miss'] += 1
        elif kind == 4:                                 # a DMA write: allocates in L2, drops L1 copies
            line2 = a >> sh2
            s, w = l2.find(line2)
            if w < 0:
                w = l2.victim(s)
                if l2.tag[w][s] >= 0 and l2.dirty[w][s]: st['wb'] += 1
                l2.tag[w][s] = line2; l2.wv[w][s] = 15
            l2.dirty[w][s] = True
            l1d.drop(a >> 4); l1i.drop(a >> 4)
        elif kind == 7:
            st['vbl'] += 1
    return st


def main():
    t = array.array('I'); t.frombytes(open(sys.argv[1], 'rb').read())
    if len(sys.argv) > 2: t = t[:int(sys.argv[2])]
    configs = [
        ('as built', {}),
        ('stream buffer 2 lines', dict(sbuf=2)),
        ('stream buffer 4 lines', dict(sbuf=4)),
        ('2 stream buffers x 4 lines', dict(sbuf=4, nsb=2)),
        ('no-fetch stores + 2 stream buffers x 4', dict(sbuf=4, nsb=2, nofetch=True)),
        ('no-fetch + 2 sb x 4 + L2 2-way', dict(sbuf=4, nsb=2, nofetch=True, l2_ways=2)),
        ('no-fetch + next 3 lines into L2', dict(prefetch=3, nofetch=True)),
    ]
    configs_all = [
        ('as built: L1I 4K, L1D 4K, L2 128K direct', {}),
        ('L2 2-way', dict(l2_ways=2)),
        ('L2 4-way', dict(l2_ways=4)),
        ('L2 256K direct', dict(l2_kb=256)),
        ('stores allocate without a fetch', dict(nofetch=True)),
        ('L2 miss also brings the next line', dict(prefetch=1)),
        ('L2 miss brings the next 3 lines', dict(prefetch=3)),
        ('L1I 8K', dict(l1i_kb=8)),
        ('L1I 16K', dict(l1i_kb=16)),
        ('L1D 8K', dict(l1d_kb=8)),
        ('L1D 16K', dict(l1d_kb=16)),
        ('2-way + no-fetch stores + next line', dict(l2_ways=2, nofetch=True, prefetch=1)),
        ('2-way + no-fetch + next line + L1I 16K + L1D 16K', dict(l2_ways=2, nofetch=True, prefetch=1, l1i_kb=16, l1d_kb=16)),
    ]
    base = None
    print('%d trace entries' % len(t))
    for name, kw in configs:
        st = run(t, **kw)
        if base is None:
            base = st['stall']
            print('  %d fetches, %d loads, %d stores, %d VBlanks' % (st['fetch'], st['load'], st['store'], st['vbl']))
        print('%-50s stall %9d (%5.1f%%)  L1I miss %7d  L1D miss %7d  L2 miss %7d  store-miss %6d  wb %6d  pf used %d/%d  sb hits %d'
              % (name, st['stall'], 100.0 * st['stall'] / base, st['l1i_miss'], st['l1d_miss'], st['l2_miss'], st['st_miss'], st['wb'], st['pf_used'], st['pf'], st['sb_hit']))
        sys.stdout.flush()

if __name__ == '__main__':
    main()
