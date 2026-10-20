"""sdput.py - a file onto the console's SD card, through the ESP32 (pc/pad.py running, its tool
port): the card stays in the board.
    python tools/sdput.py LOCALFILE /roms/gg/Game.gg
    python tools/sdput.py cores/gg.bin /cores/gg.bin
pad.py's "X" sends it in 4 kB CRC-checked blocks at 2 Mbaud (it was base64 lines at 115200:
6.5 kB/s). From Git Bash, MSYS_NO_PATHCONV=1, or /cores/... arrives as C:/Program Files/Git/cores.
"""
import socket, sys, time

def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, 'rb').read()
    f = socket.create_connection(('127.0.0.1', 5557), timeout=60).makefile('rwb')
    t0 = time.time()
    f.write(b'X %d %s\n' % (len(data), dst.encode())); f.write(data); f.flush()
    while True:
        r = f.readline().decode().strip()
        if r.startswith('~ '):
            n = int(r[2:])
            print('\r  %d / %d bytes  %.1f kB/s' % (n, len(data), n / 1024.0 / max(0.001, time.time() - t0)), end='', flush=True)
            continue
        break
    print()
    if not r.startswith('ok'):
        sys.exit('%s -> %s: %s' % (src, dst, r or 'no answer'))
    print('%s -> %s: %d bytes in %.1f s (%s)' % (src, dst, len(data), time.time() - t0, r[3:]))

if __name__ == '__main__':
    main()
