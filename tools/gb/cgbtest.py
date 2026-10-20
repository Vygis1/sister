"""cgbtest.py - a Game Boy Color test cartridge for tb_gb, assembled here (no RGBDS needed).

    python tools/gb/cgbtest.py sim/roms/gb/cgbtest.hex
    ./tools/sim.sh tb_gb ROM../../sim/roms/gb/cgbtest.hex
    ./tools/sim.sh tb_gb_50 ROM../../sim/roms/gb/cgbtest.hex MAXCLK200000000

What it checks, printing "Passed" or "Failed <n>" through the serial port like blargg's ROMs
(the bench takes the verdict from there):
  1  the CPU starts with A = $11 (a Color game's sign of a Color)
  2  KEY1 + STOP switches to double speed: KEY1 bit 7 reads 1 afterwards, and the CPU wakes
  3  GDMA copies 256 bytes of ROM into VRAM, FF55 reads $FF after, the bytes are right
  4  HDMA copies 128 bytes over eight horizontal blanks with the LCD on, then reads $FF
  5  an HDMA stopped by writing bit 7 = 0 reads bit 7 = 1 with blocks left
  6  work RAM banks: SVBK 2 and 3 are different memory at $D000
  7  the VRAM banks: VBK 1 is different memory at $8000
cgb-acid2 covers the picture itself; this is the rest of the Color.
"""
import sys


class Asm:
    def __init__(self):
        self.rom = bytearray([0xFF]) * 0x8000
        self.pc = 0
        self.labels = {}
        self.fix = []          # (addr, label, kind)

    def org(self, a): self.pc = a
    def label(self, n): self.labels[n] = self.pc
    def db(self, *bs):
        for b in bs: self.rom[self.pc] = b & 0xFF; self.pc += 1
    def dw(self, w): self.db(w & 0xFF, w >> 8)
    def ref16(self, n): self.fix.append((self.pc, n, 'w')); self.dw(0)
    def rel(self, n): self.fix.append((self.pc, n, 'r')); self.db(0)
    def done(self):
        for a, n, k in self.fix:
            t = self.labels[n]
            if k == 'w': self.rom[a] = t & 0xFF; self.rom[a + 1] = t >> 8
            else:
                d = t - (a + 1)
                assert -128 <= d <= 127, (n, d)
                self.rom[a] = d & 0xFF
        return bytes(self.rom)

    # the handful of instructions used
    def ld_a_n(self, n):   self.db(0x3E, n)
    def ld_b_n(self, n):   self.db(0x06, n)
    def ld_c_n(self, n):   self.db(0x0E, n)
    def ld_hl(self, w):    self.db(0x21); (self.ref16(w) if isinstance(w, str) else self.dw(w))
    def ld_de(self, w):    self.db(0x11); self.dw(w)
    def ld_bc(self, w):    self.db(0x01); self.dw(w)
    def ld_sp(self, w):    self.db(0x31); self.dw(w)
    def ldh_n_a(self, n):  self.db(0xE0, n)
    def ldh_a_n(self, n):  self.db(0xF0, n)
    def ld_a_hli(self):    self.db(0x2A)
    def ld_a_de(self):     self.db(0x1A)
    def ld_hl_a(self):     self.db(0x77)
    def ld_a_hl(self):     self.db(0x7E)
    def ld_nn_a(self, w):  self.db(0xEA); self.dw(w)
    def ld_a_nn(self, w):  self.db(0xFA); self.dw(w)
    def inc_de(self):      self.db(0x13)
    def dec_b(self):       self.db(0x05)
    def dec_c(self):       self.db(0x0D)
    def cp_n(self, n):     self.db(0xFE, n)
    def cp_b(self):        self.db(0xB8)
    def and_n(self, n):    self.db(0xE6, n)
    def or_a(self):        self.db(0xB7)
    def ld_b_a(self):      self.db(0x47)
    def ld_a_b(self):      self.db(0x78)
    def xor_a(self):       self.db(0xAF)
    # (the fail labels sit past the end of the test: a jump, where a relative one cannot reach)
    SHORT = ('hwait', 'hdone', 'swait', 'compare', 'print')
    def jr(self, n):
        if n in self.SHORT: self.db(0x18); self.rel(n)
        else: self.db(0xC3); self.ref16(n)
    def jr_nz(self, n):
        if n in self.SHORT: self.db(0x20); self.rel(n)
        else: self.db(0xC2); self.ref16(n)
    def jr_z(self, n):
        if n in self.SHORT: self.db(0x28); self.rel(n)
        else: self.db(0xCA); self.ref16(n)
    def jp(self, n):       self.db(0xC3); self.ref16(n)
    def call(self, n):     self.db(0xCD); self.ref16(n)
    def ret(self):         self.db(0xC9)
    def nop(self):         self.db(0x00)
    def stop(self):        self.db(0x10, 0x00)
    def halt(self):        self.db(0x76)
    def di(self):          self.db(0xF3)
    def push_hl(self):     self.db(0xE5)
    def pop_hl(self):      self.db(0xE1)
    def push_de(self):     self.db(0xD5)
    def pop_de(self):      self.db(0xD1)


def build():
    a = Asm()
    # the header: entry, the Color flag, no mapper, 32 kB, no RAM
    a.org(0x100); a.nop(); a.jp('start')
    a.org(0x143); a.db(0xC0)
    a.org(0x147); a.db(0x00, 0x00, 0x00)
    # the data GDMA and HDMA copy: 512 bytes of a pattern
    a.org(0x4000)
    for i in range(512): a.db((i * 7 + 3) & 0xFF)

    a.org(0x150); a.label('start')
    a.cp_n(0x11); a.jr_nz('fail1')
    a.ld_sp(0xFFFE)
    a.di()
    a.xor_a(); a.ldh_n_a(0xFF); a.ldh_n_a(0x0F)          # IE = 0, IF = 0
    # 2. the speed switch
    a.ld_a_n(0x01); a.ldh_n_a(0x4D); a.stop()
    a.ldh_a_n(0x4D); a.and_n(0x80); a.jr_z('fail2')
    # 3. GDMA with the LCD off: 16 blocks from $4000 to $8000
    a.xor_a(); a.ldh_n_a(0x40)
    a.ld_a_n(0x40); a.ldh_n_a(0x51); a.xor_a(); a.ldh_n_a(0x52)
    a.ld_a_n(0x00); a.ldh_n_a(0x53); a.xor_a(); a.ldh_n_a(0x54)
    a.ld_a_n(0x0F); a.ldh_n_a(0x55)
    a.ldh_a_n(0x55); a.cp_n(0xFF); a.jr_nz('fail3')
    a.ld_hl(0x8000); a.ld_de(0x4000); a.ld_bc(0x0100); a.call('compare'); a.jr_nz('fail3')
    # 4. HDMA with the LCD on: 8 blocks from $4100 to $8100, a block a line; then wait
    a.ld_a_n(0x91); a.ldh_n_a(0x40)
    a.ld_a_n(0x41); a.ldh_n_a(0x51); a.xor_a(); a.ldh_n_a(0x52)
    a.ld_a_n(0x01); a.ldh_n_a(0x53); a.xor_a(); a.ldh_n_a(0x54)
    a.ld_a_n(0x87); a.ldh_n_a(0x55)
    a.ld_b_n(0x00); a.ld_c_n(0x10)                      # 4096 polls at most
    a.label('hwait')
    a.ldh_a_n(0x55); a.cp_n(0xFF); a.jr_z('hdone')
    a.dec_b(); a.jr_nz('hwait'); a.dec_c(); a.jr_nz('hwait'); a.jr('fail4')
    a.label('hdone')
    a.xor_a(); a.ldh_n_a(0x40)
    a.ld_hl(0x8100); a.ld_de(0x4100); a.ld_bc(0x0080); a.call('compare'); a.jr_nz('fail4')
    # 5. an HDMA stopped early: 16 blocks asked for, cut after a few lines
    a.ld_a_n(0x91); a.ldh_n_a(0x40)
    a.ld_a_n(0x40); a.ldh_n_a(0x51); a.xor_a(); a.ldh_n_a(0x52)
    a.ld_a_n(0x02); a.ldh_n_a(0x53); a.xor_a(); a.ldh_n_a(0x54)
    a.ld_a_n(0x8F); a.ldh_n_a(0x55)
    a.ld_b_n(0x00)
    a.label('swait'); a.dec_b(); a.jr_nz('swait')          # a few hundred T-cycles: a line or two
    a.xor_a(); a.ldh_n_a(0x55)                              # stop it
    a.ldh_a_n(0x55); a.and_n(0x80); a.jr_z('fail5')
    a.ldh_a_n(0x55); a.and_n(0x7F); a.cp_n(0x0F); a.jr_z('fail5')   # (something was copied)
    a.xor_a(); a.ldh_n_a(0x40)
    # 6. work RAM banks
    a.ld_a_n(0x02); a.ldh_n_a(0x70); a.ld_a_n(0x22); a.ld_nn_a(0xD000)
    a.ld_a_n(0x03); a.ldh_n_a(0x70); a.ld_a_n(0x33); a.ld_nn_a(0xD000)
    a.ld_a_n(0x01); a.ldh_n_a(0x70); a.ld_a_n(0x11); a.ld_nn_a(0xD000)
    a.ld_a_n(0x02); a.ldh_n_a(0x70); a.ld_a_nn(0xD000); a.cp_n(0x22); a.jr_nz('fail6')
    a.ld_a_n(0x03); a.ldh_n_a(0x70); a.ld_a_nn(0xD000); a.cp_n(0x33); a.jr_nz('fail6')
    a.xor_a(); a.ldh_n_a(0x70); a.ld_a_nn(0xD000); a.cp_n(0x11); a.jr_nz('fail6')   # (bank 0 means 1)
    # 7. VRAM banks (LCD off)
    a.xor_a(); a.ldh_n_a(0x4F); a.ld_a_n(0x55); a.ld_nn_a(0x8000)
    a.ld_a_n(0x01); a.ldh_n_a(0x4F); a.ld_a_n(0xAA); a.ld_nn_a(0x8000)
    a.ld_a_nn(0x8000); a.cp_n(0xAA); a.jr_nz('fail7')
    a.xor_a(); a.ldh_n_a(0x4F); a.ld_a_nn(0x8000); a.cp_n(0x55); a.jr_nz('fail7')
    a.ldh_a_n(0x4F); a.cp_n(0xFE); a.jr_nz('fail7')
    a.ld_hl('passed'); a.call('print'); a.jr('stopped')
    for n in range(1, 8):
        # (the number first: the bench stops at the word)
        a.label('fail%d' % n); a.ld_a_n(0x30 + n); a.call('putc'); a.ld_hl('failed'); a.call('print'); a.jr('stopped')
    a.label('stopped'); a.di(); a.halt(); a.jr('stopped')

    # compare BC bytes at HL with DE: Z set if equal
    a.label('compare')
    a.ld_a_hli(); a.ld_b_a(); a.ld_a_de(); a.inc_de(); a.cp_b()
    a.db(0xC0)                                               # ret nz
    a.dec_c(); a.jr_nz('compare')
    # (BC counts 256 or 128 bytes: C alone is enough -- B is the byte holder)
    a.xor_a(); a.ret()
    # print the 0-ended string at HL
    a.label('print')
    a.ld_a_hli(); a.or_a(); a.db(0xC8)                       # ret z
    a.call('putc'); a.jr('print')
    a.label('putc')
    a.ldh_n_a(0x01); a.ld_a_n(0x81); a.ldh_n_a(0x02); a.ret()
    a.label('passed'); a.db(*b'Passed\n', 0)
    a.label('failed'); a.db(*b' Failed', 0)
    return a.done()


def main():
    rom = build()
    dst = sys.argv[1]
    with open(dst, 'w') as f:
        for b in rom: f.write('%02x\n' % b)
    print('%s: %d bytes' % (dst, len(rom)))


if __name__ == '__main__':
    main()
