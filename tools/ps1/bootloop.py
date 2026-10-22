"""bootloop.py - how often a PlayStation game boots: it is started from the menu N times and
watched for 30 s each; an address/bus/reserved-instruction exception seen on 3 or more of the
samples, or the processor outside RAM and BIOS, is a crash.

    python tools/ps1/bootloop.py [N] [GAME]      (default 4, crash2; through tools/pad.py's port)
"""
import socket, subprocess, sys, time

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    game = sys.argv[2] if len(sys.argv) > 2 else 'crash2'
    ok = 0
    for k in range(n):
        r = subprocess.run([sys.executable, 'tools/menunav.py', 'play', 'PlayStation', game], capture_output=True, text=True, timeout=400)
        f = socket.create_connection(('127.0.0.1', 5557), timeout=5).makefile('rwb')
        def R(a):
            f.write(b'R %x\n' % a); f.flush(); return int(f.readline().decode().strip(), 16)
        bad = 0; first = None
        for t in range(15):
            time.sleep(2)
            pc, c, epc = R(0x80014), R(0x80054), R(0x80058)
            seg = pc & 0x1FFFFFFF
            inside = seg < 0x200000 or 0x1FC00000 <= seg < 0x1FC80000 or 0x1F800000 <= seg < 0x1F800400
            if ((c >> 2) & 31) in (4, 5, 6, 7, 10, 12) or not inside:
                bad += 1
                if first is None: first = 't=%ds pc %08x cause %08x epc %08x' % (2 * t + 2, pc, c, epc)
        res = 'crashed (%s)' % first if bad >= 3 else 'running'
        ok += bad < 3
        print('run %d: %s  [%s]' % (k + 1, res, (r.stdout.strip().splitlines() or ['?'])[-1]), flush=True)
    print('%d of %d ran' % (ok, n))

if __name__ == '__main__':
    main()
