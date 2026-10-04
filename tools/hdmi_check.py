"""hdmi_check.py - the data islands in sim/hdmi_syms.txt (tb_hdmi_tx's blanking
symbols, one clock a line: channel 0, 1, 2 in hex), checked independently of the RTL:
each island's preamble, guard bands and packets found, TERC4 decoded, every header's
and subpacket's BCH ECC recomputed, InfoFrame checksums, the ACR's N/CTS, and the audio
samples in order (tb_hdmi_tx sends L = 0x1000, 0x1001, ..., R = ~L).

    python tools/hdmi_check.py
"""
import os
import sys

TERC4 = ['1010011100', '1001100011', '1011100100', '1011100010', '0101110001', '0100011110',
         '0110001110', '0100111100', '1011001100', '0100111001', '0110011100', '1011000110',
         '1010001110', '1001110001', '0101100011', '1011000011']
TER = {int(v, 2): i for i, v in enumerate(TERC4)}
CTL = {0b1101010100: 0, 0b0010101011: 1, 0b0101010100: 2, 0b1010101011: 3}
DI_GB = 0b0100110011


def bch(bits):
    e = 0
    for b in bits:
        fb = (e ^ b) & 1
        e = (e >> 1) ^ (0x83 if fb else 0)
    return e


def main():
    path = os.path.join(os.path.dirname(__file__), '..', 'sim', 'hdmi_syms.txt')
    rows = [tuple(int(v, 16) for v in l.split()) for l in open(path) if l.strip() and "x" not in l.lower().replace("0x", "")]
    errs = 0; kinds = {}; samples = []; i = 0; islands = 0
    while i + 8 < len(rows):
        # a data island preamble: channel 1 and 2 both control token 01, 8 clocks
        if all(CTL.get(rows[i + j][1]) == 1 and CTL.get(rows[i + j][2]) == 1 for j in range(8)):
            g = i + 8
            if not (rows[g][1] == DI_GB and rows[g][2] == DI_GB and rows[g + 1][1] == DI_GB):
                errs += 1; print('island at %d: no leading guard band' % i); i += 8; continue
            p0 = g + 2
            for pk in range(2):
                base = p0 + 32 * pk
                hb, sp = [], [[] for _ in range(4)]
                for k in range(32):
                    c0, c1, c2 = rows[base + k]
                    if c0 not in TER or c1 not in TER or c2 not in TER:
                        errs += 1; print('island %d packet %d clock %d: not TERC4' % (islands, pk, k)); break
                    d0, d1, d2 = TER[c0], TER[c1], TER[c2]
                    if not (d0 & 8):
                        errs += 1; print('island %d: channel 0 bit 3 clear' % islands)
                    hb.append((d0 >> 2) & 1)
                    for s in range(4):
                        sp[s].append((d1 >> s) & 1); sp[s].append((d2 >> s) & 1)
                if len(hb) != 32:
                    break
                if bch(hb[:24]) != sum(b << n for n, b in enumerate(hb[24:])):
                    errs += 1; print('island %d packet %d: header ECC wrong' % (islands, pk))
                for s in range(4):
                    if bch(sp[s][:56]) != sum(b << n for n, b in enumerate(sp[s][56:])):
                        errs += 1; print('island %d packet %d subpacket %d: ECC wrong' % (islands, pk, s))
                hdr = [sum(hb[8 * n + b] << b for b in range(8)) for n in range(3)]
                sb = [[sum(sp[s][8 * n + b] << b for b in range(8)) for n in range(7)] for s in range(4)]
                kinds[hdr[0]] = kinds.get(hdr[0], 0) + 1
                if hdr[0] == 0x02:                                  # audio samples
                    for s in range(4):
                        if hdr[1] & (1 << s):
                            l = sb[s][1] | (sb[s][2] << 8); r = sb[s][4] | (sb[s][5] << 8)
                            samples.append((l, r))
                elif hdr[0] == 0x01:                                # clock regeneration
                    cts = (sb[0][1] << 16) | (sb[0][2] << 8) | sb[0][3]; n = (sb[0][4] << 16) | (sb[0][5] << 8) | sb[0][6]
                    if (cts, n) != (25000, 6144):
                        errs += 1; print('ACR: CTS %d N %d' % (cts, n))
                elif hdr[0] in (0x82, 0x84):                        # InfoFrames
                    total = sum(hdr) + sum(sum(row) for row in sb)
                    if total & 0xFF:
                        errs += 1; print('InfoFrame %02X: checksum wrong' % hdr[0])
                    if hdr[0] == 0x82 and sb[0][4] != 1:
                        errs += 1; print('AVI: VIC %d' % sb[0][4])
            t = p0 + 64
            if not (rows[t][1] == DI_GB and rows[t + 1][2] == DI_GB):
                errs += 1; print('island %d: no trailing guard band' % islands)
            islands += 1
            i = t + 2
        else:
            i += 1
    # the samples: consecutive, R the complement of L -- or the same one again now and then
    # (hdmi_tx takes the latest sample at 48 kHz on its own clock; the bench's source runs
    # at 47985 Hz, so one in about 3200 is taken twice)
    bad = 0; again = 0
    for n in range(1, len(samples)):
        if samples[n] == samples[n - 1]:
            again += 1
            if again * 1000 > len(samples): bad += 1
            continue
        if samples[n][0] != (samples[n - 1][0] + 1) & 0xFFFF or samples[n][1] != (~samples[n][0]) & 0xFFFF:
            bad += 1
            if bad < 5: print('sample %d: %04X %04X after %04X' % (n, samples[n][0], samples[n][1], samples[n - 1][0]))
    errs += bad
    print('%d islands; packets by type %s; %d audio samples (%04X..%04X); %d errors' % (
        islands, {('%02X' % k): v for k, v in sorted(kinds.items())}, len(samples),
        samples[0][0] if samples else 0, samples[-1][0] if samples else 0, errs))
    print('hdmi_check: all checks passed' if errs == 0 and islands > 500 and samples else 'hdmi_check: FAIL')
    return errs == 0


if __name__ == '__main__':
    sys.exit(0 if main() else 1)
