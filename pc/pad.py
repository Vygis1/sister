"""pad.py - the ESP32's serial port, held for the PC's tools; and, asked for, a game
controller on this PC relayed to the board.
    python pc/pad.py [--port COM8] [--relay]
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
import time

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
TRIG = 12000                # a trigger past this is pressed (0..32767)

ser = None
wlock = threading.Lock()    # one writer at a time on the port
cmd_lock = threading.Lock() # one register command in flight
replies = queue.Queue()
override = [None, 0.0]      # a tool's "P ..." line, and until when it stands in for the pad


def open_port():
    s = serial.Serial()
    s.port = PORT; s.baudrate = 115200; s.timeout = 0.05
    s.dtr = False; s.rts = False             # (set before opening: toggling them resets the ESP32)
    s.open()
    return s


def write(line):
    with wlock:
        ser.write(line.encode())


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
            time.sleep(0.1); continue
        while b'\n' in buf:
            line, buf = buf.split(b'\n', 1)
            t = line.decode(errors='replace').rstrip('\r')
            if t.startswith('= '):
                replies.put(t[2:])
            elif t:
                print(t)


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
            if not q or q[0] not in 'RWD':
                continue
            with cmd_lock:
                while not replies.empty():
                    replies.get_nowait()
                try:
                    write(q + '\n')
                    ans = replies.get(timeout=30.0 if q[0] == 'D' else 2.0)
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


def main():
    global ser
    pygame.init()
    controller.init()
    threading.Thread(target=reader, daemon=True).start()
    threading.Thread(target=tools_server, daemon=True).start()
    pad = None
    last, last_t = None, 0.0
    relay = '--relay' in sys.argv
    print('pad: tools on %s:%d%s' % (TOOLS[0], TOOLS[1], '; relaying a controller on this PC' if relay else '; no controller relayed (--relay for that)'))
    quiet = True                      # nothing sent since the last press ended
    while True:
        for ev in pygame.event.get():
            if ev.type == pygame.CONTROLLERDEVICEADDED and pad is None and relay:
                pad = controller.Controller(ev.device_index)
                print('pad: %s connected' % pad.name)
            elif ev.type == pygame.CONTROLLERDEVICEREMOVED and pad is not None:
                print('pad: disconnected'); pad = None
        if ser is None:
            try:
                ser = open_port()
                print('pad: talking to the ESP32 on %s' % PORT)
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
