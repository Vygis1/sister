"""exedisc.py - a PS-X EXE as a bootable CD image, the way the console boots a game: an ISO 9660
data track with SYSTEM.CNF pointing at the program, as raw 2352-byte Mode 2 Form 1 sectors (the
form our drive and the ESP32's disc reader take).

    python tools/ps1/exedisc.py PROGRAM.EXE OUT.bin
    python tools/ps1/exedisc.py --all build/ps1tests OUTDIR     every .exe under a tree, one .bin each
                                                                  (named after its path: gpu_triangle.bin)

EDC/ECC are left zero: our drive checks the sync and header, not the error correction.

PS1_SYSAREA=disc.bin puts that disc's system area (raw sectors 0-15: the licence text and the
PlayStation logo the BIOS draws) on the front. Without it the BIOS draws its logo from empty
sectors -- garbage text ("bad hankaku code"), a garbage model, and the shell's own drawing
then derails (a 57-word "primitive", GPU timeouts) before it ever starts the program. The
reference logs were made from properly mastered discs. (A game's sectors: local use only.)
"""
import io
import os
import struct
import sys

import pycdlib

SYSTEM_CNF = b"BOOT = cdrom:\\PSX.EXE;1\r\nTCB = 4\r\nEVENT = 16\r\nSTACK = 801FFFF0\r\n"


def bcd(v):
    return ((v // 10) << 4) | (v % 10)


def iso_bytes(exe):
    iso = pycdlib.PyCdlib()
    iso.new(interchange_level=1, sys_ident='PLAYSTATION', vol_ident='PS1TEST')
    iso.add_fp(io.BytesIO(SYSTEM_CNF), len(SYSTEM_CNF), '/SYSTEM.CNF;1')
    iso.add_fp(io.BytesIO(exe), len(exe), '/PSX.EXE;1')
    out = io.BytesIO()
    iso.write_fp(out)
    iso.close()
    data = out.getvalue()
    if len(data) % 2048:
        data += bytes(2048 - len(data) % 2048)
    # (some room after the files: a BIOS reading ahead past the end finds sectors, not the edge)
    return data + bytes(2048 * 64)


_EDC_T = []
for _i in range(256):
    _x = _i
    for _ in range(8):
        _x = (_x >> 1) ^ 0xD8018001 if _x & 1 else _x >> 1
    _EDC_T.append(_x)


def edc(b):
    """the CD EDC: CRC-32, reflected 0xD8018001, starting at 0 (ECMA-130)"""
    c = 0
    for v in b:
        c = (c >> 8) ^ _EDC_T[(c ^ v) & 0xFF]
    return c


def raw_sectors(iso):
    out = bytearray()
    for lba in range(len(iso) // 2048):
        a = lba + 150
        mm, ss, ff = a // 4500, (a // 75) % 60, a % 75
        s = bytearray(2352)
        s[1:11] = b'\xff' * 10                                       # sync: 00, ten FF, 00
        s[12:16] = bytes((bcd(mm), bcd(ss), bcd(ff), 2))             # header: MSF, mode 2
        s[16:24] = bytes((0, 0, 8, 0, 0, 0, 8, 0))                   # subheader: data, form 1 (twice)
        s[24:24 + 2048] = iso[2048 * lba:2048 * (lba + 1)]
        # the sector's EDC (subheader + data), as a mastered disc has it: the drive checks it and
        # has a bad sector sent again (rtl/ps1_cdrom.v; an EDC of 0 it takes as "none recorded")
        s[0x818:0x81C] = struct.pack('<I', edc(s[16:0x818]))
        out += s
    return bytes(out)


SYSAREA = None


def make(exe_path, out_path):
    global SYSAREA
    exe = open(exe_path, 'rb').read()
    if exe[:8] != b'PS-X EXE':
        raise SystemExit('%s: not a PS-X EXE' % exe_path)
    img = raw_sectors(iso_bytes(exe))
    src = os.environ.get('PS1_SYSAREA')
    if src:
        if SYSAREA is None:
            SYSAREA = open(src, 'rb').read(16 * 2352)
        img = SYSAREA + img[16 * 2352:]
    open(out_path, 'wb').write(img)


def main():
    if sys.argv[1] == '--all':
        root, out = sys.argv[2], sys.argv[3]
        os.makedirs(out, exist_ok=True)
        for d, _, files in os.walk(root):
            for fn in sorted(files):
                if fn.lower().endswith('.exe') and 'tools' not in d.replace('\\', '/').split('/'):
                    rel = os.path.relpath(os.path.join(d, fn), root).replace('\\', '/')
                    parts = rel.rsplit('.', 1)[0].split('/')
                    if len(parts) >= 2 and parts[-1] == parts[-2]:   # gpu/triangle/triangle -> gpu_triangle
                        parts = parts[:-1]
                    name = '_'.join(parts)
                    make(os.path.join(d, fn), os.path.join(out, name + '.bin'))
                    print(name)
    else:
        make(sys.argv[1], sys.argv[2])


if __name__ == '__main__':
    main()
