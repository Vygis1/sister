"""sdput.py - a file onto the console's SD card, through the ESP32 (pc/pad.py running, its tool
port): the card stays in the board.
    python tools/sdput.py LOCALFILE /roms/gg/Game.gg
    python tools/sdput.py cores/gg.bin /cores/gg.bin
"""
import base64, os, socket, sys, time

def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, 'rb').read()
    f = socket.create_connection(('127.0.0.1', 5557), timeout=40).makefile('rwb')
    def ask(line):
        f.write((line + '
').encode()); f.flush()
        return f.readline().decode().strip()
    r = ask('U open %s %d' % (dst, len(data)))
    if r != 'ok': sys.exit('open: ' + r)
    t0 = time.time(); sent = 0
    for i in range(0, len(data), 189):
        chunk = data[i:i + 189]
        r = ask('U ' + base64.b64encode(chunk).decode())
        if r not in ('ok', 'done'): sys.exit('at %d: %s' % (i, r))
        sent += len(chunk)
        if sent % (189 * 200) == 0 or r == 'done':
            print('  %d / %d bytes  %.1f kB/s' % (sent, len(data), sent / 1024.0 / max(0.001, time.time() - t0)), end='', flush=True)
    print()
    if r != 'done': print('close:', ask('U close'))
    print('%s -> %s: %d bytes in %.1f s' % (src, dst, len(data), time.time() - t0))

if __name__ == '__main__':
    main()
