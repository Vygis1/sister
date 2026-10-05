"""pad.py - a game controller on this PC (PS5 DualSense, PS4, Xbox... anything SDL knows)
as player 1, through the ESP32: its state goes down the ESP32's USB serial port as a line
"P <buttons> <lx> <ly> <rx> <ry>" whenever it changes and ten times a second regardless,
and the ESP32 (esp32/console/pads.h) lays it out for whichever console is running -- or
for the shell's menu -- and writes it to the board. No network, no server.

    python pc/pad.py [--port COM6]

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
import sys
import time

import serial

os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame
from pygame._sdl2 import controller

PORT = sys.argv[sys.argv.index('--port') + 1] if '--port' in sys.argv else 'COM6'
TRIG = 12000                # a trigger past this is pressed (0..32767)


def open_port():
    s = serial.Serial()
    s.port = PORT; s.baudrate = 115200; s.timeout = 0
    s.dtr = False; s.rts = False             # (set before opening: toggling them resets the ESP32)
    s.open()
    return s


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
    pygame.init()
    controller.init()
    ser = None
    pad = None
    last, last_t = None, 0.0
    print('pad: waiting for a controller (plug it into this PC)')
    while True:
        for ev in pygame.event.get():
            if ev.type == pygame.CONTROLLERDEVICEADDED and pad is None:
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
        cur = (bits, tuple(ax))
        if cur != last or now - last_t > 0.1:
            try:
                ser.write(('P %x %d %d %d %d\n' % (bits, *ax)).encode())
                if ser.in_waiting:                    # what the ESP32 prints, passed on
                    sys.stdout.write(ser.read(ser.in_waiting).decode(errors='replace'))
            except Exception as e:
                print('pad: %s: %s' % (PORT, e)); ser = None; continue
            last, last_t = cur, now
        time.sleep(1 / 250)


if __name__ == '__main__':
    main()
