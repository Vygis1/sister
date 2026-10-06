"""snes.py - the whole SNES as a model: tools/snes/w65816.py on the bus, the PPU (ppu.py), the
sound unit's CPU side (apu.py), DMA and HDMA, the CPU's I/O ($4200-$421F), the timing of a
frame and the interrupts.

    python tools/snes/snes.py ROM.sfc [--frames N] [--joy HEX] [--png OUT.png] [--ref REF.png]

Runs N frames (default 60) and writes the last as a 256x224 PNG (hi-res halves are averaged);
with --ref, counts the pixels that differ from a reference screenshot (krom's tests ship one).
--joy holds pad 1's buttons throughout ($4218/$4219 bits: $0010 R, $0020 L, $0080 A, ...).

Timing (Fullsnes "SNES Timings"): a 21.477 MHz master clock, 1364 a line, 262 lines.
CPU accesses take 6, 8 or 12 master clocks by address (FastROM: 6 above bank $80 when $420D
bit 0 is set), internal cycles 6. DMA: 8 a byte, the CPU held. HDMA: each line 0..224 at
H = 1104. NMI at the start of line 225 (240 with overscan); IRQ by HTIME / VTIME.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import w65816  # noqa: E402
import ppu as ppu_mod  # noqa: E402
import apu as apu_mod  # noqa: E402

LINE = 1364
LINES = 262
HDMA_H = 1104
_PATTERN = {0: (0,), 1: (0, 1), 2: (0, 0), 3: (0, 0, 1, 1), 4: (0, 1, 2, 3), 5: (0, 1, 0, 1),
            6: (0, 0), 7: (0, 0, 1, 1)}


class Channel:
    def __init__(self):
        self.dmap = 0xFF
        self.bbad = 0xFF
        self.a1t = 0xFFFF
        self.a1b = 0xFF
        self.das = 0xFFFF
        self.dasb = 0xFF
        self.a2a = 0xFFFF
        self.ntrl = 0xFF
        self.unused = 0xFF
        self.hdma_done = False
        self.do_transfer = False


class Snes:
    def __init__(self, rom):
        self.rom = rom
        self.hirom = self._detect_hirom()
        self.wram = bytearray(128 * 1024)
        self.wmadd = 0
        self.ppu = ppu_mod.PPU()
        self.apu = apu_mod.APU()
        self.ch = [Channel() for _ in range(8)]
        self.nmitimen = 0
        self.htime = 0x1FF
        self.vtime = 0x1FF
        self.wrmpya = 0xFF
        self.wrdiv = 0xFFFF
        self.rddiv = 0
        self.rdmpy = 0
        self.memsel = 0
        self.hdmaen = 0
        self.rdnmi = False
        self.timeup = False
        self.mdr = 0
        self.joy1 = 0                        # pad 1's buttons, as $4218/$4219 read them
        self.mc = 0                          # master clocks since power on
        self.frame_no = 0
        self.v = 0
        self.line_start = 0
        self.hdma_pending = True
        self.irq_done_line = -1
        self.cpu = w65816.CPU(self.read, self.write)
        self.cpu.r8 = self._r8
        self.cpu.w8 = self._w8
        self.cpu.io = self._io
        self.render = False
        lo = self.read(0xFFFC) | (self.read(0xFFFD) << 8)
        self.cpu.pc = lo

    def _detect_hirom(self):
        def score(off):
            if off + 0x30 > len(self.rom):
                return -1
            mode = self.rom[off + 0x15]
            ck = self.rom[off + 0x1C] | (self.rom[off + 0x1D] << 8)
            cs = self.rom[off + 0x1E] | (self.rom[off + 0x1F] << 8)
            s = 0
            if (ck ^ cs) == 0xFFFF:
                s += 2
            if (mode & 0xEF) in (0x20, 0x30) and off == 0x7FC0:
                s += 1
            if (mode & 0xEF) in (0x21, 0x31) and off == 0xFFC0:
                s += 1
            return s
        return score(0xFFC0) > score(0x7FC0)

    # --- the bus with its timing -------------------------------------------------------------
    def speed(self, a):
        bank, off = a >> 16, a & 0xFFFF
        if bank & 0x40 == 0:                         # $00-$3F, $80-$BF
            if off < 0x2000:
                return 8
            if off < 0x4000:
                return 6
            if off < 0x4200:
                return 12
            if off < 0x6000:
                return 6
            if off < 0x8000:
                return 8
        if bank >= 0x80 and self.memsel & 1:
            return 6
        return 8

    def _r8(self, a):
        a &= 0xFFFFFF
        self.mc += self.speed(a)
        self.cpu.cycles += 1
        self.mdr = self.read(a)
        return self.mdr

    def _w8(self, a, v):
        a &= 0xFFFFFF
        self.mc += self.speed(a)
        self.cpu.cycles += 1
        self.mdr = v & 0xFF
        self.write(a, v & 0xFF)

    def _io(self):
        self.mc += 6
        self.cpu.cycles += 1

    def rom_addr(self, bank, off):
        if self.hirom:
            if bank & 0x40 or off >= 0x8000:
                return ((bank & 0x3F) << 16 | off) % len(self.rom)
            return None
        if off >= 0x8000:
            return (((bank & 0x7F) << 15) | (off - 0x8000)) % len(self.rom)
        if bank & 0x7F >= 0x40 and bank < 0xFE and bank & 0x7F < 0x70:
            return (((bank & 0x7F) << 15) | off & 0x7FFF) % len(self.rom)
        return None

    def read(self, a):
        bank, off = a >> 16, a & 0xFFFF
        if bank in (0x7E, 0x7F):
            return self.wram[((bank & 1) << 16) | off]
        if bank & 0x40 == 0:
            if off < 0x2000:
                return self.wram[off]
            if 0x2100 <= off < 0x2140:
                h = (self.mc - self.line_start) >> 2
                return self.ppu.read(off, h, self.v)
            if 0x2140 <= off < 0x2180:
                self._catch_up_apu()
                return self.apu.to_cpu[off & 3]
            if off == 0x2180:
                v = self.wram[self.wmadd]
                self.wmadd = (self.wmadd + 1) & 0x1FFFF
                return v
            if off in (0x4016, 0x4017):
                return self.mdr & 0xFC
            if 0x4200 <= off < 0x4220:
                return self.io_read(off)
            if 0x4300 <= off < 0x4380:
                return self.dma_read(off)
            if off < 0x8000:
                return self.mdr
        r = self.rom_addr(bank, off)
        return self.rom[r] if r is not None else self.mdr

    def write(self, a, v):
        bank, off = a >> 16, a & 0xFFFF
        if bank in (0x7E, 0x7F):
            self.wram[((bank & 1) << 16) | off] = v
            return
        if bank & 0x40 == 0:
            if off < 0x2000:
                self.wram[off] = v
            elif 0x2100 <= off < 0x2140:
                self.ppu.write(off, v)
            elif 0x2140 <= off < 0x2180:
                self._catch_up_apu()
                self.apu.to_spc[off & 3] = v
            elif off == 0x2180:
                self.wram[self.wmadd] = v
                self.wmadd = (self.wmadd + 1) & 0x1FFFF
            elif off == 0x2181:
                self.wmadd = (self.wmadd & 0x1FF00) | v
            elif off == 0x2182:
                self.wmadd = (self.wmadd & 0x100FF) | (v << 8)
            elif off == 0x2183:
                self.wmadd = (self.wmadd & 0xFFFF) | ((v & 1) << 16)
            elif 0x4200 <= off < 0x4220:
                self.io_write(off, v)
            elif 0x4300 <= off < 0x4380:
                self.dma_write(off, v)

    def _catch_up_apu(self):
        sp = self.apu.spc
        while sp.cycles * 21 < self.mc:
            self.apu.step()

    # --- $4200-$421F ---------------------------------------------------------------------------
    def io_write(self, r, v):
        if r == 0x4200:
            self.nmitimen = v
            if not v & 0x30:
                self.timeup = False
        elif r == 0x4202:
            self.wrmpya = v
        elif r == 0x4203:
            self.rdmpy = self.wrmpya * v
            self.rddiv = v
        elif r == 0x4204:
            self.wrdiv = (self.wrdiv & 0xFF00) | v
        elif r == 0x4205:
            self.wrdiv = (self.wrdiv & 0xFF) | (v << 8)
        elif r == 0x4206:
            if v:
                self.rddiv, self.rdmpy = self.wrdiv // v, self.wrdiv % v
            else:
                self.rddiv, self.rdmpy = 0xFFFF, self.wrdiv
        elif r == 0x4207:
            self.htime = (self.htime & 0x100) | v
        elif r == 0x4208:
            self.htime = (self.htime & 0xFF) | ((v & 1) << 8)
        elif r == 0x4209:
            self.vtime = (self.vtime & 0x100) | v
        elif r == 0x420A:
            self.vtime = (self.vtime & 0xFF) | ((v & 1) << 8)
        elif r == 0x420B:
            self.run_dma(v)
        elif r == 0x420C:
            self.hdmaen = v
        elif r == 0x420D:
            self.memsel = v

    def io_read(self, r):
        if r == 0x4210:
            v = (0x80 if self.rdnmi else 0) | 0x02 | (self.mdr & 0x70)
            self.rdnmi = False
            return v
        if r == 0x4211:
            v = (0x80 if self.timeup else 0) | (self.mdr & 0x7F)
            self.timeup = False
            return v
        if r == 0x4212:
            h = self.mc - self.line_start
            vb = self.v >= self.ppu.lines() + 1
            hb = h < 4 or h >= 1096
            joy = vb and self.v < self.ppu.lines() + 4
            return (0x80 if vb else 0) | (0x40 if hb else 0) | (1 if joy else 0) | (self.mdr & 0x3E)
        if r == 0x4213:
            return 0
        if r == 0x4214:
            return self.rddiv & 0xFF
        if r == 0x4215:
            return self.rddiv >> 8
        if r == 0x4216:
            return self.rdmpy & 0xFF
        if r == 0x4217:
            return self.rdmpy >> 8
        if r == 0x4218:
            return self.joy1 & 0xFF
        if r == 0x4219:
            return self.joy1 >> 8
        if 0x421A <= r < 0x4220:
            return 0
        return self.mdr

    # --- DMA -------------------------------------------------------------------------------
    def dma_write(self, r, v):
        c = self.ch[(r >> 4) & 7]
        k = r & 0xF
        if k == 0:
            c.dmap = v
        elif k == 1:
            c.bbad = v
        elif k == 2:
            c.a1t = (c.a1t & 0xFF00) | v
        elif k == 3:
            c.a1t = (c.a1t & 0xFF) | (v << 8)
        elif k == 4:
            c.a1b = v
        elif k == 5:
            c.das = (c.das & 0xFF00) | v
        elif k == 6:
            c.das = (c.das & 0xFF) | (v << 8)
        elif k == 7:
            c.dasb = v
        elif k == 8:
            c.a2a = (c.a2a & 0xFF00) | v
        elif k == 9:
            c.a2a = (c.a2a & 0xFF) | (v << 8)
        elif k == 0xA:
            c.ntrl = v
        else:
            c.unused = v

    def dma_read(self, r):
        c = self.ch[(r >> 4) & 7]
        k = r & 0xF
        return [c.dmap, c.bbad, c.a1t & 0xFF, c.a1t >> 8, c.a1b, c.das & 0xFF, c.das >> 8, c.dasb,
                c.a2a & 0xFF, c.a2a >> 8, c.ntrl, c.unused, c.unused, c.unused, c.unused, c.unused][k]

    def _b_addr(self, c, k):
        return 0x2100 | ((c.bbad + k) & 0xFF)

    def _xfer(self, c, a_addr, b, to_b):
        """one byte between the A bus and B-bus register b"""
        a_bank, a_off = a_addr >> 16, a_addr & 0xFFFF
        a_is_b = (a_bank & 0x40 == 0) and (0x2100 <= a_off < 0x2200 or 0x4300 <= a_off < 0x4380
                                            or a_off in (0x420B, 0x420C))
        if to_b:
            v = self.mdr if a_is_b else self.read(a_addr)
            self.write(b, v)
        else:
            v = self.read(b)
            if not a_is_b:
                self.write(a_addr, v)
        self.mdr = v
        self.mc += 8

    def run_dma(self, mask):
        self.mc += 8
        for n in range(8):
            if not mask & (1 << n):
                continue
            c = self.ch[n]
            self.mc += 8
            pat = _PATTERN[c.dmap & 7]
            to_b = not c.dmap & 0x80
            k = 0
            while True:
                self._xfer(c, (c.a1b << 16) | c.a1t, self._b_addr(c, pat[k % len(pat)]), to_b)
                k += 1
                if not c.dmap & 0x08:
                    c.a1t = (c.a1t + (-1 if c.dmap & 0x10 else 1)) & 0xFFFF
                c.das = (c.das - 1) & 0xFFFF
                if c.das == 0:
                    break

    def hdma_init(self):
        for n in range(8):
            c = self.ch[n]
            c.do_transfer = False
            c.hdma_done = False
            if not self.hdmaen & (1 << n):
                continue
            c.a2a = c.a1t
            c.ntrl = self.read((c.a1b << 16) | c.a2a)
            c.a2a = (c.a2a + 1) & 0xFFFF
            self.mc += 8
            if c.ntrl == 0:
                c.hdma_done = True
                continue
            if c.dmap & 0x40:
                lo = self.read((c.a1b << 16) | c.a2a)
                hi = self.read((c.a1b << 16) | ((c.a2a + 1) & 0xFFFF))
                c.das = lo | (hi << 8)
                c.a2a = (c.a2a + 2) & 0xFFFF
                self.mc += 16
            c.do_transfer = True

    def hdma_run(self):
        active = [n for n in range(8) if self.hdmaen & (1 << n) and not self.ch[n].hdma_done]
        if not active:
            return
        self.mc += 18
        for n in active:
            c = self.ch[n]
            self.mc += 8
            if c.do_transfer:
                pat = _PATTERN[c.dmap & 7]
                to_b = not c.dmap & 0x80
                for k in range(len(pat)):
                    if c.dmap & 0x40:
                        addr = (c.dasb << 16) | c.das
                        c.das = (c.das + 1) & 0xFFFF
                    else:
                        addr = (c.a1b << 16) | c.a2a
                        c.a2a = (c.a2a + 1) & 0xFFFF
                    self._xfer(c, addr, self._b_addr(c, pat[k]), to_b)
            c.ntrl = (c.ntrl - 1) & 0xFF
            c.do_transfer = bool(c.ntrl & 0x80)
            if c.ntrl & 0x7F == 0:
                c.ntrl = self.read((c.a1b << 16) | c.a2a)
                c.a2a = (c.a2a + 1) & 0xFFFF
                self.mc += 8
                if c.dmap & 0x40:
                    lo = self.read((c.a1b << 16) | c.a2a)
                    hi = self.read((c.a1b << 16) | ((c.a2a + 1) & 0xFFFF))
                    c.das = lo | (hi << 8)
                    c.a2a = (c.a2a + 2) & 0xFFFF
                    self.mc += 16
                if c.ntrl == 0:
                    c.hdma_done = True
                c.do_transfer = True

    # --- the frame ------------------------------------------------------------------------------
    def _line_events(self):
        """everything due up to the master clock now"""
        while True:
            h = self.mc - self.line_start
            if self.hdma_pending and h >= HDMA_H:
                self.hdma_pending = False
                if self.v <= self.ppu.lines():
                    self.hdma_run()
                continue
            if self.nmitimen & 0x30 and self.irq_done_line != self.v:
                mode = (self.nmitimen >> 4) & 3
                ht = self.htime * 4 + 14 if mode & 1 else 0
                if (mode == 1 or self.v == self.vtime) and h >= ht:
                    self.irq_done_line = self.v
                    self.timeup = True
            if h >= LINE:
                self.line_start += LINE
                self.v += 1
                if self.v == LINES:
                    self.v = 0
                    self.frame_no += 1
                self._new_line()
                continue
            break

    def _new_line(self):
        v = self.v
        self.hdma_pending = True
        p = self.ppu
        if v == 0:
            p.field ^= 1
            self.rdnmi = False
            p.stat77 = 0
            p.mosaic_line = 1
            self.hdma_init()
        elif v <= p.lines():
            if self.render:
                p.render_line(v)
        if v == p.lines() + 1:
            self.rdnmi = True
            if not p.inidisp & 0x80:
                p.oam_addr = (p.oamadd << 1) & 0x3FF     # (the OAM address reloads in vblank)
            if self.nmitimen & 0x80:
                self.cpu.nmi()

    def run_frames(self, n, render_last=2):
        target = self.frame_no + n
        c = self.cpu
        while self.frame_no < target:
            self.render = self.frame_no >= target - render_last
            if self.timeup and not c.p & w65816.I:
                c.irq()
            elif self.timeup and c.waiting:
                c.waiting = False
            c.step()
            self._line_events()

    # --- the picture ------------------------------------------------------------------------
    def image(self, w=256, h=224):
        """the frame as h rows of w RGB888 pixels: 512 x 448 is the whole frame (both fields,
        all columns); 256 x 224 averages the column pairs and takes the first field"""
        out = []
        for y in range(h):
            row = self.ppu.frame[y if h > 239 else 2 * y]
            line = []
            for x in range(w):
                a, b = (row[x], row[x]) if w > 256 else (row[2 * x], row[2 * x + 1])
                rgb = []
                for sh in (0, 5, 10):
                    c = (((a >> sh) & 31) + ((b >> sh) & 31)) / 2
                    rgb.append(int(c * 255 / 31 + 0.5))
                line.append(tuple(rgb))
            out.append(line)
        return out


def ref_size(ref_path):
    from PIL import Image
    w, h = Image.open(ref_path).size
    return (512, 448) if w >= 512 else (256, 224)


def compare(img, ref_path):
    from PIL import Image
    ref = Image.open(ref_path).convert('RGB')
    w, h = ref.size
    top = 1 if h in (225, 240) else 0                 # (a screenshot that kept line 0 at the top)
    w, h = min(w, len(img[0])), min(h - top, len(img))
    bad = 0
    for y in range(h):
        for x in range(w):
            r = ref.getpixel((x, y + top))
            g = img[y][x]
            if max(abs(r[i] - g[i]) for i in range(3)) > 8:
                bad += 1
    return bad, w * h


def save_png(img, path):
    from PIL import Image
    im = Image.new('RGB', (len(img[0]), len(img)))
    for y, line in enumerate(img):
        for x, px in enumerate(line):
            im.putpixel((x, y), px)
    im.save(path)


def main():
    args = sys.argv[1:]
    rom = open(args[0], 'rb').read()
    if len(rom) % 0x8000 == 512:
        rom = rom[512:]
    frames = int(args[args.index('--frames') + 1]) if '--frames' in args else 60
    s = Snes(rom)
    if '--joy' in args:
        s.joy1 = int(args[args.index('--joy') + 1], 16)
    s.run_frames(frames)
    size = ref_size(args[args.index('--ref') + 1]) if '--ref' in args else (256, 224)
    img = s.image(*size)
    if '--png' in args:
        save_png(img, args[args.index('--png') + 1])
    if '--ref' in args:
        bad, total = compare(img, args[args.index('--ref') + 1])
        print('%d of %d pixels differ' % (bad, total))


if __name__ == '__main__':
    main()
