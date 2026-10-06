"""apu.py - the SNES sound unit's CPU side, as a model: the SPC700 (tools/snes/spc700.py), its
64 kB of RAM, the four ports to the main CPU, the control register at $F1 and the boot ROM.

IPL is our own boot program, not Nintendo's: written here to the upload handshake Fullsnes
documents ("SNES APU Main CPU Communication Port"), so programs that talk to the boot ROM
(every game does, to send its sound driver) work the same.

    reset: S = $EF, clear $01-$EF, put $AA $BB in ports 0 and 1, wait for $CC in port 0
    block: the address from ports 2/3, echo port 0; port 1 = 0 means jump to the address
    data:  the main CPU writes the byte to port 1 and its index (from 0) to port 0; each
           byte is stored and the index echoed. Port 0 still one behind is a byte not yet
           sent; any other value starts a new block.

X stays 0 throughout (the clear loop leaves it there): the pointer is [$00+X], the index's
copy in $02, and the jump JMP [!$0000+X].
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spc700  # noqa: E402

IPL = bytes([
    0xCD, 0xEF,             # FFC0  mov x,#$ef
    0xBD,                   # FFC2  mov sp,x
    0xE8, 0x00,             # FFC3  mov a,#0
    0xC6,                   # FFC5  clr: mov (x),a
    0x1D,                   # FFC6  dec x
    0xD0, 0xFC,             # FFC7  bne clr
    0x8F, 0xAA, 0xF4,       # FFC9  mov $f4,#$aa
    0x8F, 0xBB, 0xF5,       # FFCC  mov $f5,#$bb
    0x78, 0xCC, 0xF4,       # FFCF  hs: cmp $f4,#$cc
    0xD0, 0xFB,             # FFD2  bne hs
    0xFA, 0xF6, 0x00,       # FFD4  blk: mov $00,$f6
    0xFA, 0xF7, 0x01,       # FFD7  mov $01,$f7
    0xFA, 0xF4, 0xF4,       # FFDA  mov $f4,$f4         (echo)
    0xEB, 0xF5,             # FFDD  mov y,$f5
    0xF0, 0x1A,             # FFDF  beq go
    0xD8, 0x02,             # FFE1  mov $02,x           (index 0)
    0xE4, 0xF4,             # FFE3  wait: mov a,$f4
    0x2E, 0x02, 0x0D,       # FFE5  cbne $02,nd
    0xE4, 0xF5,             # FFE8  mov a,$f5
    0xC7, 0x00,             # FFEA  mov [$00+x],a
    0xFA, 0x02, 0xF4,       # FFEC  mov $f4,$02         (echo the index)
    0x3A, 0x00,             # FFEF  incw $00
    0xAB, 0x02,             # FFF1  inc $02
    0x2F, 0xEE,             # FFF3  bra wait
    0xBC,                   # FFF5  nd: inc a
    0x2E, 0x02, 0xDB,       # FFF6  cbne $02,blk        (not one behind: a new block)
    0x2F, 0xE8,             # FFF9  bra wait
    0x1F, 0x00, 0x00,       # FFFB  go: jmp [!$0000+x]
    0xC0, 0xFF,             # FFFE  the reset vector
])
assert len(IPL) == 64


class APU:
    def __init__(self):
        self.ram = bytearray(65536)
        self.to_spc = [0] * 4           # written by the main CPU, read at $F4-$F7
        self.to_cpu = [0] * 4           # written by the SPC700, read at $2140-$2143
        self.ipl_on = True
        self.spc = spc700.SPC(self.read, self.write)
        self.spc.pc = IPL[0x3E] | (IPL[0x3F] << 8)

    def read(self, a):
        if 0xF4 <= a <= 0xF7:
            return self.to_spc[a - 0xF4]
        if a >= 0xFFC0 and self.ipl_on:
            return IPL[a - 0xFFC0]
        return self.ram[a]

    def write(self, a, v):
        if 0xF4 <= a <= 0xF7:
            self.to_cpu[a - 0xF4] = v
            return
        if a == 0xF1:
            self.ipl_on = bool(v & 0x80)
            if v & 0x10:
                self.to_spc[0] = self.to_spc[1] = 0
            if v & 0x20:
                self.to_spc[2] = self.to_spc[3] = 0
        self.ram[a] = v                 # (RAM under the I/O and the boot ROM is written too)
