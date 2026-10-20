#!/usr/bin/env python3
"""pccfg.py - the PC core's configuration for a hard-disk image: what the ESP32 writes into the
core before the CPU runs (pc_top.v MGMT_ADDR / MGMT_DATA): the CMOS (memory, equipment, date)
and IDE 0's geometry and identify data, as {addr32, data32} little-endian pairs ending with an
address of 0. Written beside the image as <image>.cfg; the menu reads it when the PC starts.

    python tools/pc/pccfg.py build/pc/doom.img [--mem 32]

From nand2mario's 486Tang tools/mksdcard.py (BSD-3-Clause): the geometry and identify code
as it is; the disk's start sector (0xF006) is 0 here -- the ESP32 serves the image file itself.
"""
import argparse, os, struct, time

SECTOR_SIZE = 512

def decode_chs(head, sec_cyl, cyl_lo):
    """Decode packed CHS. Returns (valid, cyl, hd, sec)."""
    if head == 0xFF and sec_cyl == 0xFF and cyl_lo == 0xFF:
        return False, 0, 0, 0
    sec = sec_cyl & 0x3F
    cyl = ((sec_cyl & 0xC0) << 2) | cyl_lo
    if sec == 0:
        return False, 0, 0, 0
    return True, cyl, head, sec


def chs_to_lba(cyl, head, sec, heads, spt):
    return ((cyl * heads) + head) * spt + (sec - 1)


def calc_geometry_from_mbr(mbr_data: bytes, total_bytes: int):
    """Replicates verilator/ide.cpp calc_geometry in Python.
    Returns (cylinders, heads, spt)."""
    # Partition table entries start at 0x1BE
    entries = [mbr_data[0x1BE + i * 16: 0x1BE + (i + 1) * 16] for i in range(4)]
    candidates = [
        (255, 63),
        (240, 63), (224, 56),
        (128, 63), (64, 63), (32, 63), (16, 63),
        (15, 63), (15, 32),
        (8, 32), (4, 32),
    ]

    plausible = []
    for heads, spt in candidates:
        ok = True
        for e in entries:
            (boot, begHead, begSecCyl, begCylLo, ptype, endHead, endSecCyl, endCylLo,
             lbaStart, lbaSectors) = struct.unpack('<BBBBBBBBII', e)
            if ptype == 0:
                continue
            valid_beg, cs, hs, ss = decode_chs(begHead, begSecCyl, begCylLo)
            if valid_beg:
                lba_calc = chs_to_lba(cs, hs, ss, heads, spt)
                if lba_calc != lbaStart:
                    ok = False
            valid_end, ce, he, se = decode_chs(endHead, endSecCyl, endCylLo)
            if valid_end:
                lba_end = lbaStart + lbaSectors - 1
                lba_calc = chs_to_lba(ce, he, se, heads, spt)
                if lba_calc != lba_end:
                    ok = False
            if not ok:
                break
        if ok:
            plausible.append((heads, spt))

    if not plausible:
        # Fallback: typical translation
        heads, spt = 255, 63
    else:
        # Prefer spt=63, then larger head count
        plausible.sort(key=lambda x: (x[1], x[0]), reverse=True)
        heads, spt = plausible[0]

    cylinders = total_bytes // SECTOR_SIZE // heads // spt
    return cylinders, heads, spt


def build_identify_words(cyl: int, heads: int, spt: int):
    total = cyl * heads * spt
    ident = [0] * 256
    ident[0] = 0x0040
    ident[1] = min(16383, cyl)
    ident[3] = heads
    ident[4] = (512 * spt) & 0xFFFF
    ident[5] = 512
    ident[6] = spt
    # words 7..9 zero
    # words 10..19 serial "AOHD000      "
    ident[10] = (ord('A') << 8) | ord('O')
    ident[11] = (ord('H') << 8) | ord('D')
    ident[12] = (ord('0') << 8) | ord('0')
    ident[13] = (ord('0') << 8) | ord('0')
    ident[14] = (ord('0') << 8) | ord(' ')
    ident[15] = (ord(' ') << 8) | ord(' ')
    ident[16] = (ord(' ') << 8) | ord(' ')
    ident[17] = (ord(' ') << 8) | ord(' ')
    ident[18] = (ord(' ') << 8) | ord(' ')
    ident[19] = (ord(' ') << 8) | ord(' ')
    ident[20] = 3
    ident[21] = 512
    ident[22] = 4
    # 23..26 zero (firmware rev)
    # 27..46 model number "AO Harddrive            "
    model = "AO Harddrive".ljust(40)  # 20 words
    for i in range(20):
        ident[27 + i] = (ord(model[2 * i]) << 8) | ord(model[2 * i + 1])
    ident[47] = 16
    ident[48] = 1
    ident[49] = 1 << 9
    ident[50] = 0
    ident[51] = 0x0200
    ident[52] = 0x0200
    ident[53] = 0x0007
    ident[54] = min(16383, cyl)
    ident[55] = heads
    ident[56] = spt
    ident[57] = total & 0xFFFF
    ident[58] = (total >> 16) & 0xFFFF
    ident[59] = 0
    ident[60] = total & 0xFFFF
    ident[61] = (total >> 16) & 0xFFFF
    ident[62] = 0
    ident[63] = 0
    ident[64] = 0
    ident[65] = 120
    ident[66] = 120
    ident[67] = 120
    ident[68] = 120
    # 69..79 zero
    ident[80] = 0x007E
    ident[81] = 0
    ident[82] = 1 << 14
    ident[83] = (1 << 14) | (1 << 13) | (1 << 12) | (1 << 10)
    ident[84] = 1 << 14
    ident[85] = 1 << 14
    ident[86] = (1 << 14) | (1 << 13) | (1 << 12) | (1 << 10)
    ident[87] = 1 << 14
    ident[88] = 0
    # 89..92 zero
    ident[93] = 1 | (1 << 14) | 0x2000
    # 94..99 zero
    ident[100] = total & 0xFFFF
    ident[101] = (total >> 16) & 0xFFFF
    # rest zero
    return ident



def config_pairs(mem_mb, hdd_path):
    mem_kb = (mem_mb - 1) * 1024              # extended memory: above the first megabyte
    t = time.localtime()
    bcd = lambda v: ((v // 10) << 4) | (v % 10)
    pairs = [
        (0xF430, mem_kb & 0xFF), (0xF431, (mem_kb >> 8) & 0xFF),
        (0xF414, 1 | (1 << 2) | (2 << 4)),    # equipment: a diskette controller, a PS/2 mouse, 80x25 colour
        (0xF410, 0x00),                        # no floppy drives
        (0xF40D, 0x80),                        # the battery is good
        # shutdown status 0: a cold start. The CMOS outlives a restart (pc_top's soft reset keeps its
        # RAM), and DOS/4GW and HIMEM leave a shutdown code there (a 286-style return to real mode);
        # the BIOS then took the restart for one of those and halted -- every second start over a
        # running Doom (2026-10-18, board)
        (0xF40F, 0x00),
        (0xF409, bcd(t.tm_year % 100)), (0xF408, bcd(t.tm_mon)), (0xF407, bcd(t.tm_mday)),
        (0xF432, bcd(t.tm_year // 100)),
    ]
    with open(hdd_path, 'rb') as f:
        mbr = f.read(SECTOR_SIZE)
        f.seek(0, os.SEEK_END)
        total_bytes = f.tell()
    cyl, heads, spt = calc_geometry_from_mbr(mbr, total_bytes)
    # the size the IDE controller allows (0xF005) and identify reports for LBA: the whole image,
    # not cylinders x heads x sectors -- the cylinders round down, the partition runs to the image's
    # end, and a read past that size is "Sector not found" (DOS/4GW reading DOOM.WAD, on the board)
    total = total_bytes // SECTOR_SIZE
    pairs += [(0xF001, cyl), (0xF002, heads), (0xF003, spt), (0xF004, spt * heads),
              (0xF005, total), (0xF006, 0)]
    ident = build_identify_words(cyl, heads, spt)
    ident[60], ident[61] = total & 0xFFFF, (total >> 16) & 0xFFFF
    ident[100], ident[101] = total & 0xFFFF, (total >> 16) & 0xFFFF
    for i in range(128):
        pairs.append((0xF000, (ident[2 * i + 1] << 16) | ident[2 * i]))
    return pairs, (cyl, heads, spt)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('image')
    ap.add_argument('--mem', type=int, default=32, help='memory in MB (default 32)')
    a = ap.parse_args()
    pairs, geo = config_pairs(a.mem, a.image)
    data = b''.join(struct.pack('<II', ad, v & 0xFFFFFFFF) for ad, v in pairs) + struct.pack('<I', 0)
    out = os.path.splitext(a.image)[0] + '.cfg'
    open(out, 'wb').write(data)
    print('%s: %d writes, %d MB, geometry %d/%d/%d' % (out, len(pairs), a.mem, *geo))


if __name__ == '__main__':
    main()
