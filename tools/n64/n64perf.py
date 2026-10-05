"""How fast the N64 core runs a game on the board, from its debug counters (n64_top.v).

    python tools/n64/n64perf.py [SECONDS] [--stalls]

What full speed means for Super Mario 64: VI interrupts at 60 a second, the audio
interface playing the DAC rate the game set (about 32,000 samples a second; fewer
means the game did not produce them in time), the game's frames at 30 a second
(DP interrupts: SM64 ends each frame's display list with a full sync). Then where
the time goes: the CPU outside SM64's idle loop, the RSP running graphics or audio
tasks, and, with --stalls, the CPU's clocks lost to each kind of wait.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from n64dbg import reg, CTRL   # noqa: E402

CLK = 50_000_000
SEL, DATA = CTRL + 0x170, CTRL + 0x174
STALLS = ['load-use', 'mul/div', 'FP reg in flight', 'FPU busy', 'data TLB', 'data cache (W)', 'fetch (D)', 'fetch TLB']
TASKS = ['graphics', 'audio', 'other']


def rd(sel):
    reg(SEL, sel)
    return reg(DATA)


def snap():
    s = {'t': time.time()}
    s['ins'] = rd(60); s['idle'] = rd(61)
    s['rsp_run'] = rd(55); s['rsp_ins'] = rd(54)
    for k in range(3):
        s['run%d' % k] = rd((k << 8) | 59); s['tins%d' % k] = rd((k << 8) | 58); s['go%d' % k] = rd((k << 8) | 57)
    s['dp'] = rd(20); s['vi'] = rd(22)
    s['t2'] = time.time()
    return s


def ai_rate(seconds):
    """samples the AI played a second (its counter is 16 bits: read it often)"""
    a = rd(52)
    total, prev, t0 = 0, rd(53) & 0xFFFF, time.time()
    while time.time() - t0 < seconds:
        time.sleep(0.5)
        v = rd(53) & 0xFFFF
        total += (v - prev) & 0xFFFF
        prev = v
    return total / (time.time() - t0), a & 0x3FFF


def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else 5.0
    a = snap(); time.sleep(secs); b = snap()
    dt = (b['t'] + b['t2']) / 2 - (a['t'] + a['t2']) / 2
    d = {k: (b[k] - a[k]) & 0xFFFFFFFF for k in a if k not in ('t', 't2')}
    clocks = dt * CLK
    print('over %.1f s:' % dt)
    print('  VI interrupts   %5.1f /s   (60 is full rate)' % (d['vi'] / dt))
    print('  DP full syncs   %5.1f /s   (SM64 draws 30 frames a second at full speed)' % (d['dp'] / dt))
    print('  CPU             %5.1f MIPS, %4.1f%% of its instructions outside the idle loop'
          % (d['ins'] / dt / 1e6, 100.0 * (d['ins'] - d['idle']) / max(1, d['ins'])))
    print('  RSP             %4.1f%% of clocks running, %.2f clocks an instruction'
          % (100.0 * d['rsp_run'] / clocks, d['rsp_run'] / max(1, d['rsp_ins'])))
    for k in range(3):
        if d['go%d' % k]:
            print('    %-9s %4.1f%% of clocks, %5.1f tasks/s, %7.0f instructions and %7.0f clocks a task'
                  % (TASKS[k], 100.0 * d['run%d' % k] / clocks, d['go%d' % k] / dt,
                     d['tins%d' % k] / d['go%d' % k], d['run%d' % k] / d['go%d' % k]))
    rate, dac = ai_rate(3.0)
    want = 48_681_812 / (dac + 1) if dac else 0
    print('  AI              %6.0f samples/s played, the game set %6.0f  (%.0f%%)' % (rate, want, 100.0 * rate / want if want else 0))
    if '--stalls' in sys.argv:
        print('  CPU stalls (share of all clocks):')
        for r in range(8):
            reg(SEL, (r << 8) | 46)
            n0, t0 = reg(DATA), time.time()
            time.sleep(1.0)
            n1, t1 = reg(DATA), time.time()
            print('    %-18s %5.1f%%' % (STALLS[r], 100.0 * ((n1 - n0) & 0xFFFFFFFF) / ((t1 - t0) * CLK)))


if __name__ == '__main__':
    main()
