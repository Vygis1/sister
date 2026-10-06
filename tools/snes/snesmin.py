"""snesmin.py - just enough of a SNES around tools/snes/w65816.py to run a CPU test ROM:
LoROM, work RAM (with its low-page mirror), RDNMI ($4210) raised once a frame, the VRAM data
port captured as text (what a test ROM writes on its screen), and the sound unit
(tools/snes/apu.py: the SPC700 with our boot ROM) behind ports $2140-$2143, run in step by
clock: 21.477 MHz master, the 65816 at ~7 a cycle, the SPC700 at 21.

    python tools/snes/snesmin.py ROM.sfc [MAX_INSTRUCTIONS]

Stops when the program jumps to itself (a test ROM's end); prints the text it wrote and
test_num (gilyon's cputest keeps it at $0010).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import w65816  # noqa: E402
import apu  # noqa: E402

FRAME = 44_700          # CPU cycles a frame (262 lines of 1364 master clocks, ~8 a cycle)


class Snes:
    def __init__(self, rom):
        self.rom = rom
        self.wram = bytearray(128 * 1024)
        self.vram_text = []
        self.vblank = False
        self.next_frame = FRAME
        self.cpu = w65816.CPU(self.read, self.write)
        self.apu = apu.APU()

    def map(self, a):
        bank, off = a >> 16, a & 0xFFFF
        if bank in (0x7E, 0x7F):
            return 'w', ((bank - 0x7E) << 16) | off
        b = bank & 0x7F
        if b < 0x40 and off < 0x2000:
            return 'w', off
        if off >= 0x8000:
            return 'r', ((b << 15) | (off - 0x8000)) % len(self.rom)
        if b < 0x40:
            return 'io', off
        return None, 0

    def read(self, a):
        kind, o = self.map(a)
        if kind == 'w':
            return self.wram[o]
        if kind == 'r':
            return self.rom[o]
        if kind == 'io' and 0x2140 <= o < 0x2180:
            return self.apu.to_cpu[o & 3]
        if kind == 'io' and o == 0x4210:
            v = 0x80 if self.vblank else 0
            self.vblank = False
            return v | 0x02
        return 0

    def write(self, a, v):
        kind, o = self.map(a)
        if kind == 'w':
            self.wram[o] = v
        elif kind == 'io' and o == 0x2118:
            self.vram_text.append(v)
        elif kind == 'io' and 0x2140 <= o < 0x2180:
            self.apu.to_spc[o & 3] = v

    def run(self, limit):
        c = self.cpu
        lo = self.rom[0x7FFC] | (self.rom[0x7FFD] << 8)      # the reset vector (emulation mode)
        c.pc = lo
        for n in range(limit):
            if c.cycles >= self.next_frame:
                self.vblank = True
                self.next_frame += FRAME
            pc = (c.pbr << 16) | c.pc
            c.step()
            sp = self.apu.spc
            while sp.cycles * 21 < c.cycles * 7:
                sp.step()
            if (c.pbr << 16) | c.pc == pc and self.rom_at(pc) in (0x4C, 0x80):
                return 'stopped at %06x after %d instructions' % (pc, n)
            if n % 4096 == 0 and (b'Success' in bytes(self.vram_text[-16:]) or b'Failed' in bytes(self.vram_text[-16:])):
                return 'wrote its result after %d instructions' % n
        return 'still running after %d instructions' % limit

    def rom_at(self, a):
        kind, o = self.map(a)
        return self.rom[o] if kind == 'r' else None

    def text(self):
        return ''.join(chr(b) if 32 <= b < 127 else '.' for b in self.vram_text)


def main():
    rom = open(sys.argv[1], 'rb').read()
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 50_000_000
    s = Snes(rom)
    print(s.run(limit))
    print('test_num %04x' % (s.wram[0x10] | (s.wram[0x11] << 8)))
    print('screen text (the last 200 bytes written to VRAM):', s.text()[-200:])


if __name__ == '__main__':
    main()
