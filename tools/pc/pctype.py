"""pctype.py - type a line on the PC core's keyboard (through pad.py's tool port and the ESP32's "kb"):
    python tools/pc/pctype.py "cd \\doom" [--enter]
Letters, digits, space and the usual punctuation, as PS/2 set 2 make / break codes."""
import socket
import sys
import time

S2 = {'a': '1c', 'b': '32', 'c': '21', 'd': '23', 'e': '24', 'f': '2b', 'g': '34', 'h': '33', 'i': '43', 'j': '3b',
      'k': '42', 'l': '4b', 'm': '3a', 'n': '31', 'o': '44', 'p': '4d', 'q': '15', 'r': '2d', 's': '1b', 't': '2c',
      'u': '3c', 'v': '2a', 'w': '1d', 'x': '22', 'y': '35', 'z': '1a', '1': '16', '2': '1e', '3': '26', '4': '25',
      '5': '2e', '6': '36', '7': '3d', '8': '3e', '9': '46', '0': '45', ' ': '29', '-': '4e', '=': '55', '[': '54',
      ']': '5b', '\\': '5d', ';': '4c', "'": '52', ',': '41', '.': '49', '/': '4a', '\n': '5a'}
SHIFTED = {':': ';', '_': '-', '+': '=', '?': '/', '*': '8', '!': '1', '"': "'"}


def main():
    text = sys.argv[1]
    if '--enter' in sys.argv:
        text += '\n'
    s = socket.create_connection(('127.0.0.1', 5557), timeout=5)
    for ch in text:
        shift = ch.isupper() or ch in SHIFTED
        k = S2.get(SHIFTED.get(ch, ch.lower()))
        if k is None:
            continue
        if shift:
            s.sendall(b'S kb 12\n')
        s.sendall(('S kb %s\n' % k).encode()); time.sleep(0.03)
        s.sendall(('S kb f0 %s\n' % k).encode()); time.sleep(0.03)
        if shift:
            s.sendall(b'S kb f0 12\n')
    time.sleep(0.2)
    s.close()


if __name__ == '__main__':
    main()
