"""pcetest.py - a PC Engine test card for tb_pce, assembled here: Hudson's part of the processor
and the machine around it, which the 65C02 suite does not reach.

    python tools/pce/pcetest.py sim/roms/pce/pcetest.hex
    ./tools/sim.sh tb_pce ROM../../sim/roms/pce/pcetest.hex SELFTEST1 MAXCLK20000000

Each step writes its number to $2101 before it runs, so a failing step leaves its number
there and stops; the end writes $A5 to $2100 and 0 to $2101. The bench reads those.
   1 TAM/TMA, one and several registers      8 CLA CLX CLY
   2 a page seen through two banks, zero page  9 CSL/CSH: the timer sees the speed
   3 TII TDD TIN TIA TAI                      10 ST0/ST1/ST2 and the VDC's read buffer
   4 TST                                      11 the timer's interrupt and its acknowledge
   5 BSR                                      12 the VDC's vertical blank interrupt
   6 SET: ADC / AND on zero page X            13 BRK through $FFF6, and the byte it skips
   7 SXY SAX SAY                              14 the pad port, nothing pressed
"""
import sys


class Asm:
    def __init__(self):
        self.rom = bytearray([0xFF]) * 0x2000
        self.pc = 0
        self.labels = {}
        self.fix = []

    def org(self, a): self.pc = a - 0xE000
    def here(self): return self.pc + 0xE000
    def label(self, n): self.labels[n] = self.here()
    def db(self, *bs):
        for b in bs: self.rom[self.pc] = b & 0xFF; self.pc += 1
    def dw(self, w): self.db(w & 0xFF, w >> 8)
    def w16(self, w):
        if isinstance(w, str): self.fix.append((self.pc, w, 'w')); self.dw(0)
        else: self.dw(w)
    def rel(self, n): self.fix.append((self.pc, n, 'r')); self.db(0)
    def done(self):
        for a, n, k in self.fix:
            t = self.labels[n]
            if k == 'w': self.rom[a] = t & 0xFF; self.rom[a + 1] = t >> 8
            else:
                d = t - (a + 0xE000 + 1)
                assert -128 <= d <= 127, (n, d)
                self.rom[a] = d & 0xFF
        return bytes(self.rom)

    # instructions
    def lda_imm(self, n): self.db(0xA9, n)
    def lda_zp(self, z): self.db(0xA5, z)
    def lda_abs(self, w): self.db(0xAD); self.w16(w)
    def lda_absx(self, w): self.db(0xBD); self.w16(w)
    def ldx_imm(self, n): self.db(0xA2, n)
    def ldy_imm(self, n): self.db(0xA0, n)
    def ldx_abs(self, w): self.db(0xAE); self.w16(w)
    def sta_zp(self, z): self.db(0x85, z)
    def sta_abs(self, w): self.db(0x8D); self.w16(w)
    def sta_absx(self, w): self.db(0x9D); self.w16(w)
    def stx_abs(self, w): self.db(0x8E); self.w16(w)
    def sty_abs(self, w): self.db(0x8C); self.w16(w)
    def stz_abs(self, w): self.db(0x9C); self.w16(w)
    def cmp_imm(self, n): self.db(0xC9, n)
    def cmp_abs(self, w): self.db(0xCD); self.w16(w)
    def cpx_imm(self, n): self.db(0xE0, n)
    def cpy_imm(self, n): self.db(0xC0, n)
    def inc_abs(self, w): self.db(0xEE); self.w16(w)
    def dex(self): self.db(0xCA)
    def dey(self): self.db(0x88)
    def inx(self): self.db(0xE8)
    # (a branch to `fail`, far away, is the opposite branch over a jump)
    INV = {0xD0: 0xF0, 0xF0: 0xD0, 0x10: 0x30, 0x30: 0x10, 0x50: 0x70, 0x70: 0x50, 0x90: 0xB0, 0xB0: 0x90}
    def br(self, op, n):
        if n == 'fail': self.db(self.INV[op], 3); self.jmp('fail')
        else: self.db(op); self.rel(n)
    def bne(self, n): self.br(0xD0, n)
    def beq(self, n): self.br(0xF0, n)
    def bpl(self, n): self.br(0x10, n)
    def bmi(self, n): self.br(0x30, n)
    def bvc(self, n): self.br(0x50, n)
    def bcc(self, n): self.br(0x90, n)
    def bcs(self, n): self.br(0xB0, n)
    def bra(self, n):
        if n == 'fail': self.jmp('fail')
        else: self.db(0x80); self.rel(n)
    def bsr(self, n): self.db(0x44); self.rel(n)
    def jmp(self, n): self.db(0x4C); self.w16(n)
    def jsr(self, n): self.db(0x20); self.w16(n)
    def rts(self): self.db(0x60)
    def rti(self): self.db(0x40)
    def brk(self): self.db(0x00, 0x00)
    def tam(self, m): self.db(0x53, m)
    def tma(self, m): self.db(0x43, m)
    def tii(self, s, d, n): self.db(0x73); self.dw(s); self.dw(d); self.dw(n)
    def tdd(self, s, d, n): self.db(0xC3); self.dw(s); self.dw(d); self.dw(n)
    def tin(self, s, d, n): self.db(0xD3); self.dw(s); self.dw(d); self.dw(n)
    def tia(self, s, d, n): self.db(0xE3); self.dw(s); self.dw(d); self.dw(n)
    def tai(self, s, d, n): self.db(0xF3); self.dw(s); self.dw(d); self.dw(n)
    def tst_abs(self, n, w): self.db(0x93, n); self.w16(w)
    def tst_zp(self, n, z): self.db(0x83, n, z)
    def set(self): self.db(0xF4)
    def adc_imm(self, n): self.db(0x69, n)
    def and_imm(self, n): self.db(0x29, n)
    def ora_imm(self, n): self.db(0x09, n)
    def sxy(self): self.db(0x02)
    def sax(self): self.db(0x22)
    def say(self): self.db(0x42)
    def cla(self): self.db(0x62)
    def clx(self): self.db(0x82)
    def cly(self): self.db(0xC2)
    def csl(self): self.db(0x54)
    def csh(self): self.db(0xD4)
    def st0(self, n): self.db(0x03, n)
    def st1(self, n): self.db(0x13, n)
    def st2(self, n): self.db(0x23, n)
    def sei(self): self.db(0x78)
    def cli(self): self.db(0x58)
    def clc(self): self.db(0x18)
    def sec(self): self.db(0x38)
    def cld(self): self.db(0xD8)
    def txs(self): self.db(0x9A)
    def nop(self): self.db(0xEA)
    def tax(self): self.db(0xAA)
    def txa(self): self.db(0x8A)
    def tya(self): self.db(0x98)
    def pha(self): self.db(0x48)
    def pla(self): self.db(0x68)
    def sec_sbc_imm(self, n): self.db(0x38); self.db(0xE9, n)


DONE, FAILCODE, DETAIL, TIMERCNT, VBLCNT, BRKCNT = 0x2100, 0x2101, 0x2102, 0x2110, 0x2111, 0x2112


def build():
    a = Asm()
    a.org(0xE000); a.label('reset')
    a.sei(); a.csh(); a.cld(); a.ldx_imm(0xFF); a.txs()
    a.lda_imm(0xFF); a.tam(0x01)             # MPR0 = $FF: the hardware at $0000
    a.lda_imm(0xF8); a.tam(0x02)             # MPR1 = $F8: work RAM at $2000, zero page and the stack in it
    a.stz_abs(DONE); a.stz_abs(FAILCODE); a.stz_abs(TIMERCNT); a.stz_abs(VBLCNT); a.stz_abs(BRKCNT)
    a.stz_abs(0x0C01)                        # the timer off
    a.lda_imm(0x07); a.sta_abs(0x1402)       # every interrupt masked
    a.sta_abs(0x1403)

    def step(n):
        a.lda_imm(n); a.sta_abs(FAILCODE)

    # 1. TAM / TMA
    step(1)
    a.lda_imm(0x12); a.tam(0x08); a.lda_imm(0x00); a.tma(0x08); a.cmp_imm(0x12); a.bne('fail')
    a.lda_imm(0x34); a.tam(0x30); a.cla(); a.tma(0x10); a.cmp_imm(0x34); a.bne('fail'); a.cla(); a.tma(0x20); a.cmp_imm(0x34); a.bne('fail')
    # 2. the same page through two banks; zero page is bank 1's first page
    step(2)
    a.lda_imm(0xF8); a.tam(0x04); a.tam(0x08)                        # MPR2 = MPR3 = $F8 (work RAM again)
    a.lda_imm(0x5A); a.sta_abs(0x4123); a.lda_abs(0x6123); a.cmp_imm(0x5A); a.bne('fail')
    a.lda_imm(0x77); a.sta_zp(0x10); a.lda_abs(0x4010); a.cmp_imm(0x77); a.bne('fail')
    a.lda_imm(0x66); a.sta_abs(0x2011); a.lda_zp(0x11); a.cmp_imm(0x66); a.bne('fail')
    # 3. block transfers: a pattern at $2200 (i * 3 + 1), then each kind
    step(3)
    a.ldx_imm(0); a.lda_imm(1)
    a.label('pat'); a.sta_absx(0x2200); a.clc(); a.adc_imm(3); a.inx(); a.cpx_imm(16); a.bne('pat')
    a.tii(0x2200, 0x2300, 16)
    a.ldx_imm(0)
    a.label('ck3a'); a.lda_absx(0x2200); a.cmp_abs(0x2300) if False else None
    # (compare byte by byte: lda $2200,x ; cmp $2300,x -- no cmp abs,x helper: use a loop through A and zero page)
    a.lda_absx(0x2300); a.sta_zp(0x20); a.lda_absx(0x2200); a.db(0xC5, 0x20); a.bne('fail'); a.inx(); a.cpx_imm(16); a.bne('ck3a')
    a.tdd(0x220F, 0x230F, 16)                                        # backwards: the same copy
    a.ldx_imm(0)
    a.label('ck3b'); a.lda_absx(0x2300); a.sta_zp(0x20); a.lda_absx(0x2200); a.db(0xC5, 0x20); a.bne('fail'); a.inx(); a.cpx_imm(16); a.bne('ck3b')
    a.tin(0x2200, 0x2400, 4)                                         # four bytes into one place: the last stays
    a.lda_abs(0x2400); a.cmp_imm(1 + 3 * 3); a.bne('fail')
    a.tia(0x2200, 0x2500, 8)                                         # eight bytes to $2500 / $2501 in turn
    a.lda_abs(0x2500); a.cmp_imm(1 + 6 * 3); a.bne('fail'); a.lda_abs(0x2501); a.cmp_imm(1 + 7 * 3); a.bne('fail')
    a.tai(0x2200, 0x2600, 4)                                         # $2200 / $2201 in turn, four bytes up
    a.lda_abs(0x2600); a.cmp_imm(1); a.bne('fail'); a.lda_abs(0x2601); a.cmp_imm(4); a.bne('fail')
    a.lda_abs(0x2602); a.cmp_imm(1); a.bne('fail'); a.lda_abs(0x2603); a.cmp_imm(4); a.bne('fail')
    # 4. TST: Z from the AND, N and V from the byte
    step(4)
    a.lda_imm(0xC3); a.sta_abs(0x2200)
    a.tst_abs(0x3C, 0x2200); a.bne('fail'); a.bpl('fail'); a.bvc('fail')
    a.tst_abs(0x01, 0x2200); a.beq('fail')
    a.lda_imm(0x40); a.sta_zp(0x21); a.tst_zp(0x80, 0x21); a.bne('fail'); a.bmi('fail'); a.bvc('fail')
    # 5. BSR
    step(5)
    a.ldx_imm(0); a.bsr('sub5'); a.cpx_imm(7); a.bne('fail'); a.bra('after5')
    a.label('sub5'); a.ldx_imm(7); a.rts()
    a.label('after5')
    # 6. SET: the operation on zero page X, A untouched
    step(6)
    a.lda_imm(0xF0); a.sta_zp(0x30); a.ldx_imm(0x30); a.clc(); a.lda_imm(0x11)
    a.set(); a.adc_imm(0x0F)
    a.cmp_imm(0x11); a.bne('fail'); a.lda_zp(0x30); a.cmp_imm(0xFF); a.bne('fail')
    a.lda_imm(0x55); a.set(); a.and_imm(0x0F); a.cmp_imm(0x55); a.bne('fail'); a.lda_zp(0x30); a.cmp_imm(0x0F); a.bne('fail')
    a.lda_imm(0x22); a.set(); a.ora_imm(0xF0); a.lda_zp(0x30); a.cmp_imm(0xFF); a.bne('fail')
    # 7. SXY SAX SAY
    step(7)
    a.ldx_imm(1); a.ldy_imm(2); a.sxy(); a.cpx_imm(2); a.bne('fail'); a.cpy_imm(1); a.bne('fail')
    a.lda_imm(3); a.sax(); a.cmp_imm(2); a.bne('fail'); a.cpx_imm(3); a.bne('fail')
    a.say(); a.cmp_imm(1); a.bne('fail'); a.cpy_imm(2); a.bne('fail')
    # 8. CLA CLX CLY
    step(8)
    a.lda_imm(9); a.ldx_imm(9); a.ldy_imm(9); a.cla(); a.clx(); a.cly()
    a.cmp_imm(0); a.bne('fail'); a.cpx_imm(0); a.bne('fail'); a.cpy_imm(0); a.bne('fail')
    # 9. the speed: the same loop in both, timed by the timer (1024 clocks a step, counting down from
    #    127): 16 x 256 x 6 cycles = 24.6 k cycles, 24 steps at high speed, 96 at low
    step(9)
    a.lda_imm(0x7F); a.sta_abs(0x0C00)
    a.stz_abs(0x0C01); a.lda_imm(1); a.sta_abs(0x0C01)                      # (0 then 1: reloaded)
    a.lda_abs(0x0C00); a.sta_zp(0x40)
    a.ldy_imm(16); a.ldx_imm(0)
    a.label('l9h'); a.dex(); a.bne('l9h'); a.dey(); a.bne('l9h')
    a.lda_abs(0x0C00); a.sta_zp(0x41)
    a.stz_abs(0x0C01); a.lda_imm(1); a.sta_abs(0x0C01)
    a.csl()
    a.lda_abs(0x0C00); a.sta_zp(0x42)
    a.ldy_imm(16); a.ldx_imm(0)
    a.label('l9l'); a.dex(); a.bne('l9l'); a.dey(); a.bne('l9l')
    a.lda_abs(0x0C00); a.sta_zp(0x43)
    a.csh(); a.stz_abs(0x0C01)
    a.lda_zp(0x40); a.sec(); a.db(0xE5, 0x41); a.sta_zp(0x44)              # high-speed steps = $40 - $41
    a.lda_zp(0x42); a.sec(); a.db(0xE5, 0x43); a.sta_zp(0x45)              # low-speed steps = $42 - $43
    a.lda_zp(0x44); a.sta_abs(DETAIL)
    a.cmp_imm(20); a.bcc('fail'); a.cmp_imm(29); a.bcs('fail')
    a.lda_zp(0x45); a.sta_abs(DETAIL)
    a.cmp_imm(85); a.bcc('fail'); a.cmp_imm(110); a.bcs('fail')
    # 10. ST0 / ST1 / ST2 and the read buffer
    step(10)
    a.st0(0x00); a.st1(0x34); a.st2(0x12)                                   # MAWR = $1234
    a.st0(0x02); a.st1(0xCD); a.st2(0xAB)                                   # VRAM[$1234] = $ABCD
    a.st1(0x21); a.st2(0x43)                                                # VRAM[$1235] = $4321
    a.st0(0x01); a.st1(0x34); a.st2(0x12)                                   # MARR = $1234
    a.st0(0x02); a.nop(); a.nop()
    a.lda_abs(0x0002); a.cmp_imm(0xCD); a.bne('fail'); a.lda_abs(0x0003); a.cmp_imm(0xAB); a.bne('fail')
    a.nop(); a.nop(); a.lda_abs(0x0002); a.cmp_imm(0x21); a.bne('fail'); a.lda_abs(0x0003); a.cmp_imm(0x43); a.bne('fail')
    # 11. the timer's interrupt
    step(11)
    a.lda_imm(0x03); a.sta_abs(0x1402)                                      # only the timer through
    a.lda_imm(1); a.sta_abs(0x0C00); a.sta_abs(0x0C01); a.cli()
    a.ldy_imm(0)
    a.label('w11'); a.lda_abs(TIMERCNT); a.cmp_imm(3); a.bcs('ok11'); a.dey(); a.bne('w11'); a.ldx_imm(0)
    a.label('w11b'); a.lda_abs(TIMERCNT); a.cmp_imm(3); a.bcs('ok11'); a.dex(); a.bne('w11b'); a.bra('fail')
    a.label('ok11'); a.sei(); a.stz_abs(0x0C01)
    # 12. the VDC's vertical blank
    step(12)
    a.lda_imm(0x05); a.sta_abs(0x1402)                                      # IRQ1 through
    a.st0(0x05); a.st1(0x08); a.st2(0x00)                                   # CR: the blank interrupt
    a.cli(); a.ldy_imm(0)
    a.label('w12'); a.lda_abs(VBLCNT); a.cmp_imm(2); a.bcs('ok12'); a.ldx_imm(0)
    a.label('w12b'); a.dex(); a.bne('w12b'); a.dey(); a.bne('w12'); a.bra('fail')
    a.label('ok12'); a.sei(); a.st0(0x05); a.st1(0x00); a.st2(0x00)
    # 13. BRK: the vector, the byte skipped
    step(13)
    a.lda_imm(0x07); a.sta_abs(0x1402); a.cli()
    a.ldx_imm(1); a.brk(); a.dex()                                          # (the padding byte is the BRK's own)
    a.cpx_imm(0); a.bne('fail'); a.lda_abs(BRKCNT); a.cmp_imm(1); a.bne('fail')
    # 14. the pad port: nothing pressed
    step(14)
    a.lda_imm(0x03); a.sta_abs(0x1000); a.lda_imm(0x01); a.sta_abs(0x1000)
    a.lda_abs(0x1000); a.and_imm(0x0F); a.cmp_imm(0x0F); a.bne('fail')
    a.lda_imm(0x00); a.sta_abs(0x1000); a.lda_abs(0x1000); a.cmp_imm(0xBF); a.bne('fail')
    # done
    a.stz_abs(FAILCODE); a.lda_imm(0xA5); a.sta_abs(DONE)
    a.label('fail'); a.bra('fail')

    # the handlers
    a.label('irq_timer'); a.pha(); a.inc_abs(TIMERCNT); a.sta_abs(0x1403); a.pla(); a.rti()
    a.label('irq1'); a.pha(); a.lda_abs(0x0000); a.inc_abs(VBLCNT); a.pla(); a.rti()
    a.label('irq2'); a.pha(); a.inc_abs(BRKCNT); a.pla(); a.rti()
    a.org(0xFFF6); a.w16('irq2'); a.w16('irq1'); a.w16('irq_timer'); a.w16('reset'); a.w16('reset')
    return a.done()


def main():
    rom = build()
    with open(sys.argv[1], 'w') as f:
        for b in rom: f.write('%02x\n' % b)
    print('%s: %d bytes' % (sys.argv[1], len(rom)))


if __name__ == '__main__':
    main()
