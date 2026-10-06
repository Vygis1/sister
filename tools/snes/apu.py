"""apu.py - the SNES sound unit's CPU side, as a model: the SPC700 (tools/snes/spc700.py), its
64 kB of RAM, the four ports to the main CPU, the control register at $F1 and the boot ROM.

IPL is our own boot program, not Nintendo's: written here to the upload handshake Fullsnes
documents ("SNES APU Main CPU Communication Port"), so programs that talk to the boot ROM
(every game does, to send its sound driver) work the same.

    reset: S = $EF, clear $01-$EF, put $AA $BB in ports 0 and 1, wait for $CC in port 0
    block: the address from ports 2/3, echo port 0 (the kick); port 1 = 0 means jump there;
           else wait for index 0 in port 0 -- the main CPU sends the first byte as soon as it
           sees the echo, so the kick must not be taken for anything after it
    data:  the main CPU writes the byte to port 1 and its index (from 0) to port 0; each
           byte is stored, then its index echoed. One signed compare of port 0 with the
           index expected (Y) tells the three cases apart: equal, the next byte; behind,
           the last one still there; ahead, a new block's kick (always index + 2 or more).

X stays 0 throughout (the clear loop leaves it there), so the jump is JMP [!$0000+X] with
A = X = Y = 0 (some games count on that). Entering at $FFC9 (as some games do) skips only
the clearing.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spc700  # noqa: E402
import dsp as dsp_mod  # noqa: E402

IPL = bytes([
    0xCD, 0xEF,             # FFC0  mov x,#$ef
    0xBD,                   # FFC2  mov sp,x
    0xE8, 0x00,             # FFC3  mov a,#0
    0xC6,                   # FFC5  clr: mov (x),a
    0x1D,                   # FFC6  dec x
    0xD0, 0xFC,             # FFC7  bne clr
    0x8F, 0xAA, 0xF4,       # FFC9  mov $f4,#$aa        (games also enter here)
    0x8F, 0xBB, 0xF5,       # FFCC  mov $f5,#$bb
    0x78, 0xCC, 0xF4,       # FFCF  hs: cmp $f4,#$cc
    0xD0, 0xFB,             # FFD2  bne hs
    0xBA, 0xF6,             # FFD4  blk: movw ya,$f6     (the address)
    0xDA, 0x00,             # FFD6  movw $00,ya
    0xFA, 0xF4, 0xF4,       # FFD8  mov $f4,$f4         (echo the kick)
    0xE4, 0xF5,             # FFDB  mov a,$f5           (the command)
    0xF0, 0x19,             # FFDD  beq go
    0x8D, 0x00,             # FFDF  mov y,#0            (Y: the index expected)
    0x7E, 0xF4,             # FFE1  w0: cmp y,$f4       (the first byte's index: 0)
    0xD0, 0xFC,             # FFE3  bne w0
    0xE4, 0xF5,             # FFE5  data: mov a,$f5
    0xD7, 0x00,             # FFE7  mov [$00]+y,a       (stored, then echoed)
    0xCB, 0xF4,             # FFE9  mov $f4,y
    0xFC,                   # FFEB  inc y
    0xD0, 0x02,             # FFEC  bne wait
    0xAB, 0x01,             # FFEE  inc $01
    0x7E, 0xF4,             # FFF0  wait: cmp y,$f4
    0xF0, 0xF1,             # FFF2  beq data            (the next byte)
    0x10, 0xFA,             # FFF4  bpl wait            (still the last one)
    0x2F, 0xDC,             # FFF6  bra blk             (ahead of it: a new block's kick)
    0xFD,                   # FFF8  go: mov y,a         (A = X = Y = 0, as games expect)
    0x1F, 0x00, 0x00,       # FFF9  jmp [!$0000+x]
    0x00, 0x00,             # FFFC
    0xC0, 0xFF,             # FFFE  the reset vector
])
assert len(IPL) == 64


class APU:
    def __init__(self):
        self.ram = bytearray(65536)
        self.to_spc = [0] * 4           # written by the main CPU, read at $F4-$F7
        self.to_cpu = [0] * 4           # written by the SPC700, read at $2140-$2143
        self.ipl_on = True
        self.dsp = dsp_mod.DSP(self.ram)
        self.dsp_addr = 0
        self.t_en = 0                   # $F1 bits 0-2
        self.t_div = [0, 0, 0]          # $FA-$FC (0 = 256)
        self.t_stage = [0, 0, 0]        # the dividers' counts
        self.t_out = [0, 0, 0]          # $FD-$FF, 4 bits
        self.aux = [0, 0]               # $F8 / $F9: plain storage on the SNES
        self.spc = spc700.SPC(self.read, self.write)
        self.spc.pc = IPL[0x3E] | (IPL[0x3F] << 8)
        self.done = 0                   # SPC700 cycles the timers / DSP have caught up to

    def catch_up(self):
        """bring the timers and the DSP up to the SPC700's cycle count: timers 0 / 1 tick at
        8 kHz (every 128 cycles), timer 2 at 64 kHz (16), the DSP makes a sample every 32"""
        while self.done + 16 <= self.spc.cycles:
            self.done += 16
            self._tick(2)
            if self.done % 128 == 0:
                self._tick(0)
                self._tick(1)
            if self.done % 32 == 0:
                self.dsp.sample()

    def _tick(self, n):
        if not self.t_en & (1 << n):
            return
        self.t_stage[n] = (self.t_stage[n] + 1) & 0xFF
        if self.t_stage[n] == self.t_div[n]:
            self.t_stage[n] = 0
            self.t_out[n] = (self.t_out[n] + 1) & 15

    def step(self):
        self.spc.step()
        self.catch_up()

    def read(self, a):
        if 0xF0 <= a <= 0xFF:
            self.catch_up()
            if a in (0xF0, 0xF1) or 0xFA <= a <= 0xFC:
                return 0                # (write-only)
            if a == 0xF2:
                return self.dsp_addr
            if a == 0xF3:
                return self.dsp.read(self.dsp_addr)
            if a <= 0xF7:
                return self.to_spc[a - 0xF4]
            if a <= 0xF9:
                return self.aux[a - 0xF8]
            v = self.t_out[a - 0xFD]
            self.t_out[a - 0xFD] = 0
            return v
        if a >= 0xFFC0 and self.ipl_on:
            return IPL[a - 0xFFC0]
        return self.ram[a]

    def write(self, a, v):
        if 0xF0 <= a <= 0xFF:
            self.catch_up()
            if 0xF4 <= a <= 0xF7:
                self.to_cpu[a - 0xF4] = v
            elif a == 0xF1:
                self.ipl_on = bool(v & 0x80)
                for n in range(3):
                    if v & (1 << n) and not self.t_en & (1 << n):
                        self.t_stage[n] = 0
                        self.t_out[n] = 0
                self.t_en = v & 7
                if v & 0x10:
                    self.to_spc[0] = self.to_spc[1] = 0
                if v & 0x20:
                    self.to_spc[2] = self.to_spc[3] = 0
            elif a == 0xF2:
                self.dsp_addr = v
            elif a == 0xF3:
                self.dsp.write(self.dsp_addr, v)
            elif a in (0xF8, 0xF9):
                self.aux[a - 0xF8] = v
            elif 0xFA <= a <= 0xFC:
                self.t_div[a - 0xFA] = v
        self.ram[a] = v                 # (RAM under the I/O and the boot ROM is written too)
