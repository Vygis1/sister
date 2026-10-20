"""A reference picture of a PC Engine game from Mednafen (build/dl/mednafen), for the bench's
frame to be judged against.

    python tools/pce/mednafen_shot.py ROM OUT.png [SECONDS] [KEY@SEC ...]
    python tools/pce/mednafen_shot.py build/dl/pce_blox/20220408/GAME.pce build/blox_ref.png 4 RETURN@2

Starts Mednafen on the ROM, waits, taps the keys named (SDL key names: RETURN, TAB, LALT,
LCTRL, UP, ...) at the seconds given, takes a snapshot (F9), closes the window, and copies
the newest snapshot from ~/.mednafen/snaps to OUT.png. The window has to be on top for the
keys to land: nothing else should be clicked meanwhile.
"""
import ctypes
import glob
import os
import shutil
import subprocess
import sys
import time

MEDNAFEN = os.path.join('build', 'dl', 'mednafen', 'mednafen.exe')
SNAPS = os.path.join(os.path.expanduser('~'), '.mednafen', 'snaps')
VK = {'RETURN': 0x0D, 'TAB': 0x09, 'LALT': 0xA4, 'LCTRL': 0xA2, 'LSHIFT': 0xA0, 'SPACE': 0x20, 'ESCAPE': 0x1B,
      'UP': 0x26, 'DOWN': 0x28, 'LEFT': 0x25, 'RIGHT': 0x27, 'F9': 0x78, 'F12': 0x7B}
user32 = ctypes.windll.user32


HWND = [0]


def find_window(pid):
    """Mednafen's visible window (by its process), polled for up to ten seconds."""
    found = []
    @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    def cb(h, _):
        wp = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(h, ctypes.byref(wp))
        if wp.value == pid and user32.IsWindowVisible(h):
            n = user32.GetWindowTextLengthW(h)
            buf = ctypes.create_unicode_buffer(n + 1)
            user32.GetWindowTextW(h, buf, n + 1)
            found.append((h, buf.value))
        return True
    for _ in range(40):
        time.sleep(0.25)
        found.clear()
        user32.EnumWindows(cb, 0)
        if found:
            print('window: %s' % found[0][1].encode('ascii', 'replace').decode())
            return found[0][0]
    return 0


def tap(name, hold=0.12):
    """A key, as a message to the window (so the window need not be in front)."""
    vk = VK[name] if name in VK else ord(name.upper())
    scan = user32.MapVirtualKeyW(vk, 0)
    user32.PostMessageW(HWND[0], 0x0100, vk, (scan << 16) | 1)
    time.sleep(hold)
    user32.PostMessageW(HWND[0], 0x0101, vk, (scan << 16) | 0xC0000001)


def main():
    rom, out = sys.argv[1], sys.argv[2]
    secs = float(sys.argv[3]) if len(sys.argv) > 3 else 4.0
    keys = []
    for a in sys.argv[4:]:
        k, t = a.split('@')
        keys.append((float(t), k))
    keys.sort()
    before = set(glob.glob(os.path.join(SNAPS, '*.png')))
    p = subprocess.Popen([MEDNAFEN, '-video.fs', '0', '-sound', '0', rom], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t0 = time.time()
    # bring it to the front once its window is up
    hwnd = find_window(p.pid)
    HWND[0] = hwnd
    if not hwnd:
        print('no Mednafen window found')
    else:
        user32.SetForegroundWindow(hwnd)
    for t, k in keys:
        while time.time() - t0 < t:
            time.sleep(0.05)
        tap(k)
    while time.time() - t0 < secs:
        time.sleep(0.05)
    tap('F9')
    time.sleep(0.8)
    if hwnd:
        user32.PostMessageW(hwnd, 0x0010, 0, 0)          # WM_CLOSE: a clean exit writes the settings file
    try:
        p.wait(timeout=8)
    except subprocess.TimeoutExpired:
        p.kill()
    after = set(glob.glob(os.path.join(SNAPS, '*.png'))) - before
    if not after:
        sys.exit('no snapshot appeared in %s' % SNAPS)
    newest = max(after, key=os.path.getmtime)
    shutil.copy(newest, out)
    print('%s <- %s' % (out, newest))


if __name__ == '__main__':
    main()
