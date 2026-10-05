"""pad.py - a game controller on this PC (PS5 DualSense, PS4, Xbox... anything SDL
knows) as player 1 of whichever console the board is running. Its state goes to the
board through the server (/api/nes/input) whenever it changes, and twice a second
regardless; the server lays the buttons out for the machine (pad_for_console).

    python pc/pad.py [--server http://127.0.0.1:8080]

Mapping (SDL's standard layout, so it is the same on every pad; PlayStation names):

    NES, Master System   Cross or Square -> A, Circle or Triangle -> B,
                         Create -> Select, Options -> Start; D-pad or left stick
    Mega Drive           Square -> A, Cross -> B, Circle -> C, Options -> Start
    PlayStation          every button as it is; the left stick also moves the D-pad
    Nintendo 64          left stick -> the stick, Cross -> A, Square -> B, L2 -> Z,
                         L1 / R1 -> L / R, Options -> Start, D-pad -> D-pad,
                         right stick (or Triangle / Circle) -> C buttons

The console is asked of the server every two seconds, so the mapping follows the
menu switching machines.
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

# the server's pad word (NES order, then the rest of a modern pad): server.py _NES_BITS
A, B, SELECT, START, UP, DOWN, LEFT, RIGHT, X, Y, L1, R1, L2, R2 = range(14)
NES, SMS, MD, PS1, N64 = 0, 1, 2, 3, 4
NAMES = {NES: 'NES', SMS: 'Master System', MD: 'Mega Drive', PS1: 'PlayStation', N64: 'Nintendo 64'}
DIG = 16000                 # an axis past this is a direction pressed
TRIG = 12000                # a trigger past this is pressed (0..32767)
DEAD = 0.12                 # the N64 stick's dead zone, of full scale
N64_MAX = 80                # a real N64 stick reads about +-80 at its rim


def post(body):
    req = urllib.request.Request(SERVER + '/api/nes/input', data=json.dumps(body).encode(),
                                 headers={'Content-Type': 'application/json'})
    try:
        urllib.request.urlopen(req, timeout=1).read()
        return True
    except Exception as e:
        print('server:', e)
        return False


def console():
    """the console the board is running, or None (the shell, or no answer)"""
    try:
        r = json.load(urllib.request.urlopen(SERVER + '/api/nes/console', timeout=1))
        return r.get('console')
    except Exception:
        return None


def stick(v):
    """an SDL axis (-32768..32767) as an N64 stick reading, with a dead zone"""
    f = max(-1.0, min(1.0, v / 32767.0))
    if abs(f) < DEAD:
        return 0
    f = (abs(f) - DEAD) / (1.0 - DEAD) * (1 if f > 0 else -1)
    return int(round(f * N64_MAX))


def read(pad, which):
    """{'joy1': the pad word, 'stick1': [x, y]} for the console running"""
    b = pad.get_button
    ax, ay = pad.get_axis(pygame.CONTROLLER_AXIS_LEFTX), pad.get_axis(pygame.CONTROLLER_AXIS_LEFTY)
    rx, ry = pad.get_axis(pygame.CONTROLLER_AXIS_RIGHTX), pad.get_axis(pygame.CONTROLLER_AXIS_RIGHTY)
    cross, circle = b(pygame.CONTROLLER_BUTTON_A), b(pygame.CONTROLLER_BUTTON_B)
    square, triangle = b(pygame.CONTROLLER_BUTTON_X), b(pygame.CONTROLLER_BUTTON_Y)
    create, options = b(pygame.CONTROLLER_BUTTON_BACK), b(pygame.CONTROLLER_BUTTON_START)
    l1, r1 = b(pygame.CONTROLLER_BUTTON_LEFTSHOULDER), b(pygame.CONTROLLER_BUTTON_RIGHTSHOULDER)
    l2 = pad.get_axis(pygame.CONTROLLER_AXIS_TRIGGERLEFT) > TRIG
    r2 = pad.get_axis(pygame.CONTROLLER_AXIS_TRIGGERRIGHT) > TRIG
    du, dd = b(pygame.CONTROLLER_BUTTON_DPAD_UP), b(pygame.CONTROLLER_BUTTON_DPAD_DOWN)
    dl, dr = b(pygame.CONTROLLER_BUTTON_DPAD_LEFT), b(pygame.CONTROLLER_BUTTON_DPAD_RIGHT)
    on = set()
    if which == N64:
        # the D-pad is its own; the stick is analog
        if du: on.add(UP)
        if dd: on.add(DOWN)
        if dl: on.add(LEFT)
        if dr: on.add(RIGHT)
        if cross: on.add(A)
        if square: on.add(X)                          # -> B
        if l2: on.add(L2)                             # -> Z
        if l1: on.add(L1)
        if r1: on.add(R1)
        if options: on.add(START)
        # the C buttons: the right stick, or Triangle / Circle for up and down
        if triangle or ry < -DIG: on.add(Y)           # C up
        if circle or ry > DIG: on.add(B)              # C down
        if rx < -DIG: on.add(SELECT)                  # C left
        if rx > DIG or r2: on.add(R2)                 # C right
        st = [stick(ax), -stick(ay)]                  # (up is positive)
    else:
        if du or ay < -DIG: on.add(UP)
        if dd or ay > DIG: on.add(DOWN)
        if dl or ax < -DIG: on.add(LEFT)
        if dr or ax > DIG: on.add(RIGHT)
        if options: on.add(START)
        if which == PS1:
            for btn, bit in ((cross, A), (circle, B), (square, X), (triangle, Y), (create, SELECT),
                             (l1, L1), (r1, R1), (l2, L2), (r2, R2)):
                if btn: on.add(bit)
        elif which == MD:
            if square: on.add(A)
            if cross: on.add(B)
            if circle: on.add(SELECT)                 # -> C
        else:                                         # NES, Master System
            if cross or square: on.add(A)
            if circle or triangle: on.add(B)
            if create: on.add(SELECT)
        st = [0, 0]
    return sum(1 << k for k in on), st


def main():
    pygame.init()
    controller.init()
    pad = None
    which, which_t = None, 0.0
    last, last_st, last_t = -1, [0, 0], 0.0
    print('pad: waiting for a controller (plug it into this PC)')
    while True:
        for ev in pygame.event.get():
            if ev.type == pygame.CONTROLLERDEVICEADDED and pad is None:
                pad = controller.Controller(ev.device_index)
                print('pad: %s connected' % pad.name)
            elif ev.type == pygame.CONTROLLERDEVICEREMOVED and pad is not None:
                print('pad: disconnected'); pad = None
                post({'joy1': 0, 'stick1': [0, 0]}); last = 0
        now = time.time()
        if now - which_t > 2.0:
            w = console()
            if w != which:
                print('pad: the board is running %s' % (NAMES.get(w, 'no console (the shell?)')))
                which, last = w, -1
            which_t = now
        if pad is None or which is None:
            time.sleep(0.05)
            continue
        bits, st = read(pad, which)
        moved = abs(st[0] - last_st[0]) >= 2 or abs(st[1] - last_st[1]) >= 2 or (st != last_st and st == [0, 0])
        if bits != last or moved or now - last_t > 0.5:
            body = {'joy1': bits}
            if which == N64:
                body['stick1'] = st
            post(body)
            if bits != last:
                print('pad: %04X' % bits)
            last, last_st, last_t = bits, st, now
        time.sleep(1 / 120)


if __name__ == '__main__':
    main()
