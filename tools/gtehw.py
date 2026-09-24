"""Turn JaCzekanski's GTE fuzz log (results from a real PlayStation) into the
vector file sim/tb_gte.v reads.

    python tools/gtehw.py <gte_valid_*.log> > sim/roms/gte_vectors.hex

Our own sweep (tools/gtetest.py) compares the RTL against a model written from
the same documentation the RTL was written from, so the two can agree and both
be wrong. This compares against the chip. Each case in the log is the whole
register file before the command, the command with its fields named, and the
whole register file after it, read off hardware.
"""
import re
import sys

OPS = {}   # name -> opcode, taken from the header line itself


def cases(path):
    st = {}
    cur = None
    with open(path) as f:
        for line in f:
            line = line.strip()
            m = re.match(r"^> r\[(\d+)\] = 0x([0-9a-fA-F]+)$", line)
            if m:
                if cur is not None:      # a new input block starts a new case
                    yield cur
                    cur = None
                st[int(m.group(1))] = int(m.group(2), 16)
                continue
            m = re.match(r"^GTE 0x([0-9a-fA-F]+) (\w+) \(sf=(\d+), lm=(\d+), tx=(\d+), vx=(\d+), mx=(\d+)\)$", line)
            if m:
                op, name, sf, lm, tx, vx, mx = m.group(1), m.group(2), *(int(g) for g in m.groups()[2:])
                word = (int(op, 16) & 0x3F) | (lm << 10) | (tx << 13) | (vx << 15) | (mx << 17) | (sf << 19)
                cur = {"before": dict(st), "word": word, "after": {}, "name": name}
                continue
            m = re.match(r"^< r\[(\d+)\] = 0x([0-9a-fA-F]+)$", line)
            if m and cur is not None:
                cur["after"][int(m.group(1))] = int(m.group(2), 16)
    if cur is not None:
        yield cur


def main():
    n = 0
    out = []
    for c in cases(sys.argv[1]):
        if len(c["before"]) < 64 or len(c["after"]) < 64:
            continue
        w = [c["before"].get(i, 0) for i in range(64)]
        w.append(c["word"])
        w += [c["after"].get(i, 0) for i in range(64)]
        out.append(w)
        n += 1
    for w in out:
        for x in w:
            print("%08x" % (x & 0xFFFFFFFF))
    print("%d cases, %d words" % (n, n * 129), file=sys.stderr)


if __name__ == "__main__":
    main()
