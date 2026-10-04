"""pad.py - a game controller on this PC (PS5 DualSense, PS4, Xbox... anything SDL
knows), as the NES's joypad 1: its buttons go to the board through the server
(/api/nes/input) whenever they change, and twice a second regardless.

    python pc/pad.py [--server http://127.0.0.1:8080]

Mapping (SDL's standard layout, so it is the same on every pad):
    D-pad or left stick -> D-pad      Cross (or Square)    -> A
    Circle (or Triangle) -> B         Create / Back        -> Select
    Options / Start      -> Start
"""
import json
import os
import sys
import time
import urllib.request

os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame
from pygame._sdl2 import controller

SERVER = sys.argv[sys.argv.index('--server') + 1] if '--server' in sys.argv else 'http://127.0.0.1:8080'


def send(bits):
    req = urllib.request.Request(SERVER + '/api/nes/input', data=json.dumps({'joy1': bits}).encode(),
                                 headers={'Content-Type': 'application/json'})
    try:
        urllib.request.urlopen(req, timeout=1).read()
    except Exception as e:
        print('server:', e)


def main():
    pygame.init()
    controller.init()
    pad = None
    last, last_t = -1, 0.0
    print('pad: waiting for a controller (plug it into this PC)')
    while True:
        for ev in pygame.event.get():
            if ev.type == pygame.CONTROLLERDEVICEADDED and pad is None:
                pad = controller.Controller(ev.device_index)
                print('pad: %s connected' % pad.name)
            elif ev.type == pygame.CONTROLLERDEVICEREMOVED and pad is not None:
                print('pad: disconnected'); pad = None; send(0); last = 0
        if pad is None:
            time.sleep(0.05)
            continue
        b = pad.get_button
        ax = pad.get_axis(pygame.CONTROLLER_AXIS_LEFTX); ay = pad.get_axis(pygame.CONTROLLER_AXIS_LEFTY)
        up = b(pygame.CONTROLLER_BUTTON_DPAD_UP) or ay < -16000
        down = b(pygame.CONTROLLER_BUTTON_DPAD_DOWN) or ay > 16000
        left = b(pygame.CONTROLLER_BUTTON_DPAD_LEFT) or ax < -16000
        right = b(pygame.CONTROLLER_BUTTON_DPAD_RIGHT) or ax > 16000
        a = b(pygame.CONTROLLER_BUTTON_A) or b(pygame.CONTROLLER_BUTTON_X)
        bb = b(pygame.CONTROLLER_BUTTON_B) or b(pygame.CONTROLLER_BUTTON_Y)
        sel = b(pygame.CONTROLLER_BUTTON_BACK)
        start = b(pygame.CONTROLLER_BUTTON_START)
        # the NES's order: A, B, Select, Start, Up, Down, Left, Right
        bits = (a << 0) | (bb << 1) | (sel << 2) | (start << 3) | (up << 4) | (down << 5) | (left << 6) | (right << 7)
        now = time.time()
        if bits != last or now - last_t > 0.5:
            send(bits)
            if bits != last:
                print('pad: %02X' % bits)
            last, last_t = bits, now
        time.sleep(1 / 120)


if __name__ == '__main__':
    main()
