"""pad.py - the ESP32's serial port, held for the PC's tools; and, asked for, a game
controller on this PC relayed to the board.
    python tools/pad.py [--port COM8] [--relay]
--relay: a controller on this PC (PS5 DualSense, PS4, Xbox... anything SDL knows) goes down
the ESP32's USB serial port as a line "P <buttons> <lx> <ly> <rx> <ry>" whenever it changes
and ten times a second regardless, and the ESP32 (esp32/console/pads.h) lays it out for
whichever console is running. OFF unless asked: the board's pads are Bluetooth now, and a
DualShock left plugged into this PC was relayed as a second player with its L2 reading held
(2026-10-13: MediEvil's camera spun on its own). The tools' own presses (menunav through
the tool port) still go through.

It also holds the serial port for the PC's tools: on 127.0.0.1:5557 a line "R <addr>" or
"W <addr> <value>" (hex) is passed to the ESP32, and its answer ("= <value>", "= ok") comes
back (tools/n64/n64dbg.py reg()). What else the ESP32 prints is shown here.

Until the ESP32 takes the pad itself. Mapping (the ESP32's, pads.h; PlayStation names):

    NES, Master System, menu   Cross or Square -> A, Circle or Triangle -> B,
                               Create -> Select, Options -> Start; D-pad or left stick
    Mega Drive                 Square -> A, Cross -> B, Circle -> C, Options -> Start
    PlayStation                every button as it is; the left stick also the D-pad
    Nintendo 64                left stick -> the stick, Cross -> A, Square -> B, L2 -> Z,
                               L1 / R1 -> L / R, Options -> Start, D-pad -> D-pad,
                               right stick (or Triangle / Circle) -> C buttons
    PS button                  the menu
"""
import os
import queue
import socket
import sys
import threading
import calendar
import time
import zlib
from collections import deque

import serial

os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame
from pygame._sdl2 import controller

def _find_port():
    """the ESP32's USB serial port: the T8's CH9102 (1A86:55D4), else an S3's own USB or CH343"""
    from serial.tools import list_ports
    ports = list(list_ports.comports())
    for vid, pid in ((0x1A86, 0x55D4), (0x303A, None), (0x1A86, None)):
        for p in ports:
            if p.vid == vid and (pid is None or p.pid == pid):
                return p.device
    return 'COM6'


PORT = sys.argv[sys.argv.index('--port') + 1] if '--port' in sys.argv else _find_port()
TOOLS = ('127.0.0.1', 5557)
BAUD = 2000000              # the firmware's Serial.begin (115200 before 2026-10-15)
TRIG = 12000                # a trigger past this is pressed (0..32767)

ser = None
wlock = threading.Lock()    # one writer at a time on the port
cmd_lock = threading.Lock() # one register command in flight
replies = queue.Queue()
override = [None, 0.0]      # a tool's "P ..." line, and until when it stands in for the pad


def open_port():
    s = serial.Serial()
    s.port = PORT; s.baudrate = BAUD; s.timeout = 0.05
    s.dtr = False; s.rts = False             # (set before opening: toggling them resets the ESP32)
    s.open()
    return s


port_dead = threading.Event()   # the port failed (the board's USB dropped): the main loop opens it again


def write(line):
    with wlock:
        try:
            ser.write(line.encode())
        except Exception:
            port_dead.set()
            raise


def reader():
    """the ESP32's output: register answers to the queue, the rest shown"""
    buf = b''
    while True:
        s = ser
        if s is None:
            time.sleep(0.1); continue
        try:
            buf += s.read(max(1, s.in_waiting))    # (as soon as anything is there)
        except Exception:
            port_dead.set(); time.sleep(0.1); continue
        while b'\n' in buf:
            line, buf = buf.split(b'\n', 1)
            t = line.decode(errors='replace').rstrip('\r')
            if t.startswith('= '):
                replies.put(t[2:])
            elif t:
                print(t)


def put_file(path, data, f):
    """a file onto the card: "U open", then 4 kB "U blk" blocks, two in flight so the card writes
    one while the next comes down the line; an "error at <end>" (a bad block, and everything sent
    after it, dropped) sends again from there. Progress lines "~ <bytes>" to the tool."""
    def ask(line, t=10.0):
        write(line + '\n')
        return replies.get(timeout=t)
    while not replies.empty():
        replies.get_nowait()
    try:
        r = ask('U open %s %d' % (path, len(data)))
        if r != 'ok':
            return 'error open: ' + r
        BLK, pos, inflight, retries, shown = 4096, 0, deque(), 0, 0
        while True:
            while len(inflight) < 2 and pos < len(data):
                b = data[pos:pos + BLK]
                with wlock:                   # header and bytes in one write: no pad line between
                    ser.write(b'U blk %x %x %x\n' % (pos, len(b), zlib.crc32(b)) + b)
                inflight.append(pos + len(b)); pos += len(b)
            if not inflight:
                return 'error no answer at the end'
            r = replies.get(timeout=30.0)   # (a card allocating space on a big FAT32 can stall for seconds)
            if r.startswith('error at '):
                retries += 1
                if retries > 20:
                    return 'error too many retries: ' + r
                inflight.clear(); pos = int(r.split()[2], 16)
                continue
            if r not in ('ok', 'done'):
                return 'error ' + r
            end = inflight.popleft()
            if end - shown >= 256 * 1024 or r == 'done':
                f.write(b'~ %d\n' % end); f.flush(); shown = end
            if r == 'done':
                c = ask('U crc %s' % path, 60.0).split()   # read back off the card
                want = '%08x %x' % (zlib.crc32(data), len(data))
                if ' '.join(c) != want:
                    return 'error the card holds %s, sent %s' % (' '.join(c), want)
                return 'ok %d retries, read back crc32 %s' % (retries, c[0])
    except queue.Empty:
        return 'error timeout'


def tools_server():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(TOOLS); srv.listen(4)

    def serve(c):
        f = c.makefile('rwb')
        for raw in f:
            q = raw.decode(errors='replace').strip()
            if q[:2] == 'P ':                 # a tool pressing buttons: in place of the pad for 0.3 s
                override[0], override[1] = q, time.time() + 0.3
                f.write(b'ok\n'); f.flush(); continue
            if q[:2] == 'S ':                 # a line for the ESP32's serial console ("state"): what it
                with cmd_lock:                # prints comes out here, as everything else does
                    write(q[2:] + '\n')
                f.write(b'ok\n'); f.flush(); continue
            if q[:2] == 'X ':                 # "X <size> <path>" and the file's bytes: onto the card
                size, path = q[2:].split(' ', 1)
                data = f.read(int(size))
                with cmd_lock:
                    ans = put_file(path, data, f)
                f.write((ans + '\n').encode()); f.flush(); continue
            if not q or q[0] not in 'RWDU':
                continue
            with cmd_lock:
                while not replies.empty():
                    replies.get_nowait()
                try:
                    write(q + '\n')
                    ans = replies.get(timeout=30.0 if q[0] in 'DU' else 2.0)
                except Exception:
                    ans = 'timeout'
            f.write((ans + '\n').encode()); f.flush()
        c.close()

    while True:
        c, _ = srv.accept()
        threading.Thread(target=serve, args=(c,), daemon=True).start()


def state(pad):
    b = pad.get_button
    bits = 0
    for k, btn in enumerate((pygame.CONTROLLER_BUTTON_A, pygame.CONTROLLER_BUTTON_B,
                             pygame.CONTROLLER_BUTTON_X, pygame.CONTROLLER_BUTTON_Y,
                             pygame.CONTROLLER_BUTTON_BACK, pygame.CONTROLLER_BUTTON_START,
                             pygame.CONTROLLER_BUTTON_DPAD_UP, pygame.CONTROLLER_BUTTON_DPAD_DOWN,
                             pygame.CONTROLLER_BUTTON_DPAD_LEFT, pygame.CONTROLLER_BUTTON_DPAD_RIGHT,
                             pygame.CONTROLLER_BUTTON_LEFTSHOULDER, pygame.CONTROLLER_BUTTON_RIGHTSHOULDER)):
        if b(btn):
            bits |= 1 << k
    if pad.get_axis(pygame.CONTROLLER_AXIS_TRIGGERLEFT) > TRIG:
        bits |= 1 << 12
    if pad.get_axis(pygame.CONTROLLER_AXIS_TRIGGERRIGHT) > TRIG:
        bits |= 1 << 13
    if b(pygame.CONTROLLER_BUTTON_GUIDE):
        bits |= 1 << 14
    ax = [max(-128, min(127, pad.get_axis(a) // 256)) for a in
          (pygame.CONTROLLER_AXIS_LEFTX, pygame.CONTROLLER_AXIS_LEFTY,
           pygame.CONTROLLER_AXIS_RIGHTX, pygame.CONTROLLER_AXIS_RIGHTY)]
    return bits, ax



# --- the PC core's keyboard: this window's keys, as PS/2 set 2 scan codes ("kb <hex> ..." to the
# ESP32, esp32/console/pc.h). SDL names keys by their USB HID usage; a key is its make code, and
# F0 + it when let go; E0 in front of the extended ones. Only while the window has the focus --
# a keyboard hook would take keys typed into everything else.
HID_PS2 = {
    4: '1c', 5: '32', 6: '21', 7: '23', 8: '24', 9: '2b', 10: '34', 11: '33', 12: '43', 13: '3b', 14: '42',
    15: '4b', 16: '3a', 17: '31', 18: '44', 19: '4d', 20: '15', 21: '2d', 22: '1b', 23: '2c', 24: '3c',
    25: '2a', 26: '1d', 27: '22', 28: '35', 29: '1a',
    30: '16', 31: '1e', 32: '26', 33: '25', 34: '2e', 35: '36', 36: '3d', 37: '3e', 38: '46', 39: '45',
    40: '5a', 41: '76', 42: '66', 43: '0d', 44: '29', 45: '4e', 46: '55', 47: '54', 48: '5b', 49: '5d',
    51: '4c', 52: '52', 53: '0e', 54: '41', 55: '49', 56: '4a', 57: '58',
    58: '05', 59: '06', 60: '04', 61: '0c', 62: '03', 63: '0b', 64: '83', 65: '0a', 66: '01', 67: '09',
    68: '78', 69: '07', 71: '7e',
    73: 'e0 70', 74: 'e0 6c', 75: 'e0 7d', 76: 'e0 71', 77: 'e0 69', 78: 'e0 7a',
    79: 'e0 74', 80: 'e0 6b', 81: 'e0 72', 82: 'e0 75',
    83: '77', 84: 'e0 4a', 85: '7c', 86: '7b', 87: '79', 88: 'e0 5a', 89: '69', 90: '72', 91: '7a',
    92: '6b', 93: '73', 94: '74', 95: '6c', 96: '75', 97: '7d', 98: '70', 99: '71',
    224: '14', 225: '12', 226: '11', 227: 'e0 1f', 228: 'e0 14', 229: '59', 230: 'e0 11', 231: 'e0 27',
}


def ps2(scancode, down):
    c = HID_PS2.get(scancode)
    if c is None:
        return None
    parts = c.split()
    if not down:
        parts.insert(len(parts) - 1, 'f0')
    return 'kb ' + ' '.join(parts) + '\n'


def main():
    global ser
    pygame.init()
    controller.init()
    threading.Thread(target=reader, daemon=True).start()
    threading.Thread(target=tools_server, daemon=True).start()
    pad = None
    last, last_t = None, 0.0
    relay = '--relay' in sys.argv
    kb = '--nokb' not in sys.argv
    if kb:
        win = pygame.display.set_mode((420, 70))
        pygame.display.set_caption('PC keyboard - click here and type (FPGA PC core)')
        win.fill((40, 40, 90)); pygame.display.flip()
    print('pad: tools on %s:%d%s' % (TOOLS[0], TOOLS[1], '; relaying a controller on this PC' if relay else '; no controller relayed (--relay for that)'))
    quiet = True                      # nothing sent since the last press ended
    while True:
        for ev in pygame.event.get():
            if ev.type == pygame.CONTROLLERDEVICEADDED and pad is None and relay:
                pad = controller.Controller(ev.device_index)
                print('pad: %s connected' % pad.name)
            elif ev.type == pygame.CONTROLLERDEVICEREMOVED and pad is not None:
                print('pad: disconnected'); pad = None
            elif kb and ev.type in (pygame.KEYDOWN, pygame.KEYUP) and ser is not None:
                ln = ps2(ev.scancode, ev.type == pygame.KEYDOWN)
                if ln:
                    try: write(ln)
                    except Exception: pass
        if port_dead.is_set() and ser is not None:
            # (a handle on a port that went away cannot be used again, and while it stays open Windows
            # refuses a new one: "Access is denied" until pad.py was restarted -- 2026-10-19)
            print('pad: %s went away: opening it again' % PORT)
            old, ser = ser, None
            try: old.close()
            except Exception: pass
            time.sleep(1)
        if ser is None:
            try:
                ser = open_port()
                port_dead.clear()
                print('pad: talking to the ESP32 on %s' % PORT)
                # the board's clock (its DS1302, the Game Boy Advance cartridges' clock): the PC's
                # local time, as seconds since 1970 with no zone
                write('time %d\n' % calendar.timegm(time.localtime()))
                write('log on\n')                 # (the ESP32's log, into this one: it is off after every reset)
            except Exception as e:
                print('pad: %s: %s (again in a second)' % (PORT, e)); time.sleep(1); continue
        bits, ax = state(pad) if pad is not None else (0, [0, 0, 0, 0])
        now = time.time()
        line = 'P %x %d %d %d %d' % (bits, *ax)
        if override[0] and now < override[1]:
            line = override[0]                # (a tool's press, see tools_server)
        cur = line
        if not relay:
            # only a tool's press reaches the board; one release after it, then silence, so the
            # ESP32 drops the "PC pad" (pads.h: a second without a line) instead of keeping a
            # phantom player
            if override[0] and now < override[1]: quiet = False
            elif quiet: time.sleep(1 / 250); continue
            else: quiet = True; line = 'P 0 0 0 0 0'
        if cur != last or now - last_t > 0.1 or not relay:
            try:
                write(line + '\n')
            except Exception as e:
                print('pad: %s: %s' % (PORT, e)); ser = None; continue
            last, last_t = cur, now
        time.sleep(1 / 250)


if __name__ == '__main__':
    main()
