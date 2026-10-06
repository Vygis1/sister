"""dsp.py - the SNES sound chip (S-DSP), as a model: eight BRR voices with Gaussian
interpolation, ADSR / GAIN envelopes, pitch modulation, noise, the echo with its 8-tap FIR, and
the mixer; one stereo sample every 32 SPC700 cycles (32 kHz).

Written from Fullsnes ("SNES APU DSP ..." chapters; the Gauss table is the one it lists) and
checked with blargg's SPC tests (sim/roms/snes/blargg) run through tools/snes/snes.py.
The registers live in a 128-byte array as the chip has them; ENVX / OUTX / ENDX are written
back by the chip each sample.
"""

GAUSS = [
    0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000,
    0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x002, 0x002, 0x002, 0x002, 0x002,
    0x002, 0x002, 0x003, 0x003, 0x003, 0x003, 0x003, 0x004, 0x004, 0x004, 0x004, 0x004, 0x005, 0x005, 0x005, 0x005,
    0x006, 0x006, 0x006, 0x006, 0x007, 0x007, 0x007, 0x008, 0x008, 0x008, 0x009, 0x009, 0x009, 0x00A, 0x00A, 0x00A,
    0x00B, 0x00B, 0x00B, 0x00C, 0x00C, 0x00D, 0x00D, 0x00E, 0x00E, 0x00F, 0x00F, 0x00F, 0x010, 0x010, 0x011, 0x011,
    0x012, 0x013, 0x013, 0x014, 0x014, 0x015, 0x015, 0x016, 0x017, 0x017, 0x018, 0x018, 0x019, 0x01A, 0x01B, 0x01B,
    0x01C, 0x01D, 0x01D, 0x01E, 0x01F, 0x020, 0x020, 0x021, 0x022, 0x023, 0x024, 0x024, 0x025, 0x026, 0x027, 0x028,
    0x029, 0x02A, 0x02B, 0x02C, 0x02D, 0x02E, 0x02F, 0x030, 0x031, 0x032, 0x033, 0x034, 0x035, 0x036, 0x037, 0x038,
    0x03A, 0x03B, 0x03C, 0x03D, 0x03E, 0x040, 0x041, 0x042, 0x043, 0x045, 0x046, 0x047, 0x049, 0x04A, 0x04C, 0x04D,
    0x04E, 0x050, 0x051, 0x053, 0x054, 0x056, 0x057, 0x059, 0x05A, 0x05C, 0x05E, 0x05F, 0x061, 0x063, 0x064, 0x066,
    0x068, 0x06A, 0x06B, 0x06D, 0x06F, 0x071, 0x073, 0x075, 0x076, 0x078, 0x07A, 0x07C, 0x07E, 0x080, 0x082, 0x084,
    0x086, 0x089, 0x08B, 0x08D, 0x08F, 0x091, 0x093, 0x096, 0x098, 0x09A, 0x09C, 0x09F, 0x0A1, 0x0A3, 0x0A6, 0x0A8,
    0x0AB, 0x0AD, 0x0AF, 0x0B2, 0x0B4, 0x0B7, 0x0BA, 0x0BC, 0x0BF, 0x0C1, 0x0C4, 0x0C7, 0x0C9, 0x0CC, 0x0CF, 0x0D2,
    0x0D4, 0x0D7, 0x0DA, 0x0DD, 0x0E0, 0x0E3, 0x0E6, 0x0E9, 0x0EC, 0x0EF, 0x0F2, 0x0F5, 0x0F8, 0x0FB, 0x0FE, 0x101,
    0x104, 0x107, 0x10B, 0x10E, 0x111, 0x114, 0x118, 0x11B, 0x11E, 0x122, 0x125, 0x129, 0x12C, 0x130, 0x133, 0x137,
    0x13A, 0x13E, 0x141, 0x145, 0x148, 0x14C, 0x150, 0x153, 0x157, 0x15B, 0x15F, 0x162, 0x166, 0x16A, 0x16E, 0x172,
    0x176, 0x17A, 0x17D, 0x181, 0x185, 0x189, 0x18D, 0x191, 0x195, 0x19A, 0x19E, 0x1A2, 0x1A6, 0x1AA, 0x1AE, 0x1B2,
    0x1B7, 0x1BB, 0x1BF, 0x1C3, 0x1C8, 0x1CC, 0x1D0, 0x1D5, 0x1D9, 0x1DD, 0x1E2, 0x1E6, 0x1EB, 0x1EF, 0x1F3, 0x1F8,
    0x1FC, 0x201, 0x205, 0x20A, 0x20F, 0x213, 0x218, 0x21C, 0x221, 0x226, 0x22A, 0x22F, 0x233, 0x238, 0x23D, 0x241,
    0x246, 0x24B, 0x250, 0x254, 0x259, 0x25E, 0x263, 0x267, 0x26C, 0x271, 0x276, 0x27B, 0x280, 0x284, 0x289, 0x28E,
    0x293, 0x298, 0x29D, 0x2A2, 0x2A6, 0x2AB, 0x2B0, 0x2B5, 0x2BA, 0x2BF, 0x2C4, 0x2C9, 0x2CE, 0x2D3, 0x2D8, 0x2DC,
    0x2E1, 0x2E6, 0x2EB, 0x2F0, 0x2F5, 0x2FA, 0x2FF, 0x304, 0x309, 0x30E, 0x313, 0x318, 0x31D, 0x322, 0x326, 0x32B,
    0x330, 0x335, 0x33A, 0x33F, 0x344, 0x349, 0x34E, 0x353, 0x357, 0x35C, 0x361, 0x366, 0x36B, 0x370, 0x374, 0x379,
    0x37E, 0x383, 0x388, 0x38C, 0x391, 0x396, 0x39B, 0x39F, 0x3A4, 0x3A9, 0x3AD, 0x3B2, 0x3B7, 0x3BB, 0x3C0, 0x3C5,
    0x3C9, 0x3CE, 0x3D2, 0x3D7, 0x3DC, 0x3E0, 0x3E5, 0x3E9, 0x3ED, 0x3F2, 0x3F6, 0x3FB, 0x3FF, 0x403, 0x408, 0x40C,
    0x410, 0x415, 0x419, 0x41D, 0x421, 0x425, 0x42A, 0x42E, 0x432, 0x436, 0x43A, 0x43E, 0x442, 0x446, 0x44A, 0x44E,
    0x452, 0x455, 0x459, 0x45D, 0x461, 0x465, 0x468, 0x46C, 0x470, 0x473, 0x477, 0x47A, 0x47E, 0x481, 0x485, 0x488,
    0x48C, 0x48F, 0x492, 0x496, 0x499, 0x49C, 0x49F, 0x4A2, 0x4A6, 0x4A9, 0x4AC, 0x4AF, 0x4B2, 0x4B5, 0x4B7, 0x4BA,
    0x4BD, 0x4C0, 0x4C3, 0x4C5, 0x4C8, 0x4CB, 0x4CD, 0x4D0, 0x4D2, 0x4D5, 0x4D7, 0x4D9, 0x4DC, 0x4DE, 0x4E0, 0x4E3,
    0x4E5, 0x4E7, 0x4E9, 0x4EB, 0x4ED, 0x4EF, 0x4F1, 0x4F3, 0x4F5, 0x4F6, 0x4F8, 0x4FA, 0x4FB, 0x4FD, 0x4FF, 0x500,
    0x502, 0x503, 0x504, 0x506, 0x507, 0x508, 0x50A, 0x50B, 0x50C, 0x50D, 0x50E, 0x50F, 0x510, 0x511, 0x511, 0x512,
    0x513, 0x514, 0x514, 0x515, 0x516, 0x516, 0x517, 0x517, 0x517, 0x518, 0x518, 0x518, 0x518, 0x518, 0x519, 0x519,
]

# samples between envelope / noise steps, by 5-bit rate (0 = never)
RATE = [0, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192, 160, 128, 96, 80,
        64, 48, 40, 32, 24, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1]
# where in the shared counter each kind of rate (1, 3, 5 shl n) fires
OFFSET = [0] + [(0, 1040, 536)[(r - 1) % 3] for r in range(1, 32)]

ATTACK, DECAY, SUSTAIN, RELEASE = range(4)


def _s8(v):
    return v - 256 if v & 0x80 else v


def _clamp16(v):
    return -0x8000 if v < -0x8000 else (0x7FFF if v > 0x7FFF else v)


def _s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def _s15(v):
    """the 15-bit value the BRR decoder keeps (bit 15 of the 16-bit clamp is lost)"""
    return _s16(v << 1) >> 1


class Voice:
    def __init__(self):
        self.env = 0
        self.mode = RELEASE
        self.kon_delay = 0
        self.brr_addr = 0           # the block being decoded
        self.brr_off = 1            # the next data byte in it (1..8)
        self.buf = [0] * 12
        self.bufpos = 0
        self.pos = 0                # the pitch counter (0..7FFFh)
        self.out = 0                # this sample's 15-bit output (after the envelope)
        self.hidden = 0             # the envelope as last clipped (for bent increase)


class DSP:
    def __init__(self, ram):
        self.ram = ram              # the APU's 64 kB, shared with the SPC700
        self.r = bytearray(128)
        self.r[0x6C] = 0xE0
        self.v = [Voice() for _ in range(8)]
        self.counter = 0
        self.noise = 0x4000
        self.kon = 0                # KON as written, until the chip takes it
        self.new_kon = 0
        self.every_other = False
        self.echo_idx = 0
        self.echo_len = 0
        self.fir_l = [0] * 8
        self.fir_r = [0] * 8
        self.fir_i = 0
        self.out = []               # (left, right) samples, when collecting

    # --- the SPC700's side ($F2 / $F3) ---------------------------------------------------
    def read(self, a):
        return self.r[a & 0x7F]

    def write(self, a, v):
        if a & 0x80:
            return                                  # (80h-FFh: read-only mirrors)
        self.r[a] = v
        if a == 0x4C:
            self.new_kon = v
        elif a == 0x7C:
            self.r[0x7C] = 0                        # (any write clears ENDX)

    # --- rates ------------------------------------------------------------------------------
    def fires(self, rate):
        if rate == 0:
            return False
        return (self.counter + OFFSET[rate]) % RATE[rate] == 0

    # --- BRR ------------------------------------------------------------------------------------
    def _decode4(self, x, vc):
        """four more samples of voice x into its ring"""
        hdr = self.ram[vc.brr_addr]
        shift, filt = hdr >> 4, (hdr >> 2) & 3
        for k in range(2):
            byte = self.ram[(vc.brr_addr + vc.brr_off + k) & 0xFFFF]
            for nib in (byte >> 4, byte & 15):
                s = nib - 16 if nib & 8 else nib
                if shift <= 12:
                    s = (s << shift) >> 1
                else:
                    s = -2048 if s < 0 else 0
                p1 = vc.buf[(vc.bufpos - 1) % 12]
                p2 = vc.buf[(vc.bufpos - 2) % 12]
                if filt == 1:
                    s += p1 + ((-p1) >> 4)
                elif filt == 2:
                    s += (p1 << 1) + ((-(p1 * 3)) >> 5) - p2 + (p2 >> 4)
                elif filt == 3:
                    s += (p1 << 1) + ((-(p1 * 13)) >> 6) - p2 + ((p2 * 3) >> 4)
                vc.buf[vc.bufpos] = _s15(_clamp16(s))
                vc.bufpos = (vc.bufpos + 1) % 12
        vc.brr_off += 2
        if vc.brr_off > 8:                          # the block is done: the next one
            if hdr & 1:
                self.r[0x7C] |= 1 << x
                dirent = (self.r[0x5D] << 8) + self.r[(x << 4) | 4] * 4
                vc.brr_addr = self.ram[(dirent + 2) & 0xFFFF] | (self.ram[(dirent + 3) & 0xFFFF] << 8)
                if not hdr & 2:
                    vc.mode = RELEASE
                    vc.env = 0
            else:
                vc.brr_addr = (vc.brr_addr + 9) & 0xFFFF
            vc.brr_off = 1

    def _interp(self, vc):
        i = (vc.pos >> 4) & 0xFF
        p = vc.bufpos + (vc.pos >> 12)
        s0, s1, s2, s3 = (vc.buf[(p + k) % 12] for k in range(4))
        out = (GAUSS[0xFF - i] * s0) >> 10
        out += (GAUSS[0x1FF - i] * s1) >> 10
        out = _s16(out + ((GAUSS[0x100 + i] * s2) >> 10))
        out = _clamp16(out + ((GAUSS[i] * s3) >> 10))
        return out >> 1

    # --- envelopes ----------------------------------------------------------------------------
    def _envelope(self, x, vc):
        env = vc.env
        if vc.mode == RELEASE:
            env -= 8
            vc.env = max(env, 0)
            return
        a1 = self.r[(x << 4) | 5]
        a2 = self.r[(x << 4) | 6]
        gain = self.r[(x << 4) | 7]
        if a1 & 0x80:
            if vc.mode == ATTACK:
                rate = (a1 & 15) * 2 + 1
                step = 1024 if rate == 31 else 32
            elif vc.mode == DECAY:
                rate = ((a1 >> 4) & 7) * 2 + 16
                step = -(((env - 1) >> 8) + 1)
            else:
                rate = a2 & 31
                step = -(((env - 1) >> 8) + 1)
            sl = a2 >> 5
        else:
            sl = gain >> 5
            if not gain & 0x80:
                vc.env = vc.hidden = (gain & 0x7F) * 16
                rate, step = 0, 0
                env = vc.env
            else:
                rate = gain & 31
                m = (gain >> 5) & 3
                if m == 0:
                    step = -32
                elif m == 1:
                    step = -(((env - 1) >> 8) + 1)
                elif m == 2:
                    step = 32
                else:
                    step = 32 if vc.hidden < 0x600 else 8
        if vc.mode == DECAY and (env >> 8) == sl:
            vc.mode = SUSTAIN
        if self.fires(rate):
            env += step
            vc.hidden = env & 0x7FF
            if env < 0:
                env = 0
            elif env > 0x7FF:
                env = 0x7FF
            vc.env = env
        if vc.mode == ATTACK and vc.env >= 0x7E0:
            vc.mode = DECAY

    # --- one sample --------------------------------------------------------------------------
    def sample(self):
        r = self.r
        flg = r[0x6C]
        # the shared rate counter
        self.counter = 0x77FF if self.counter == 0 else self.counter - 1
        if self.fires(flg & 31):
            n = self.noise
            self.noise = ((n >> 1) & 0x3FFF) | (((n ^ (n >> 1)) & 1) << 14)
        noise15 = self.noise - 0x8000 if self.noise & 0x4000 else self.noise
        # KON / KOFF are taken every other sample
        self.every_other = not self.every_other
        if self.every_other:
            self.kon = self.new_kon
            self.new_kon = 0
            koff = r[0x5C]
        else:
            koff = None
        main_l = main_r = echo_l = echo_r = 0
        pmon, non, eon = r[0x2D], r[0x3D], r[0x4D]
        prev_out = 0
        for x in range(8):
            vc = self.v[x]
            bit = 1 << x
            base = x << 4
            if koff is not None:
                if self.kon & bit:
                    vc.kon_delay = 5
                    vc.mode = ATTACK
                    vc.env = vc.hidden = 0
                    vc.pos = 0
                    vc.bufpos = 0
                    vc.buf = [0] * 12
                    dirent = (r[0x5D] << 8) + r[base | 4] * 4
                    vc.brr_addr = self.ram[dirent & 0xFFFF] | (self.ram[(dirent + 1) & 0xFFFF] << 8)
                    vc.brr_off = 1
                    r[0x7C] &= ~bit
                if koff & bit:
                    vc.mode = RELEASE
            if flg & 0x80:
                vc.mode = RELEASE
                vc.env = 0
            if vc.kon_delay:
                vc.kon_delay -= 1
                if vc.kon_delay in (3, 2, 1):           # (the first 12 samples come in)
                    self._decode4(x, vc)
                vc.out = 0
                vc.pos = 0
            else:
                s = noise15 if non & bit else self._interp(vc)
                vc.out = ((s * vc.env) >> 11) & ~1
                self._envelope(x, vc)
                step = r[base | 2] | ((r[base | 3] & 0x3F) << 8)
                if pmon & bit and x > 0:
                    step = (step * ((prev_out >> 4) + 0x400)) >> 10
                vc.pos = min(vc.pos + step, 0x7FFF)
                if vc.pos >= 0x4000:
                    self._decode4(x, vc)
                    vc.pos -= 0x4000
            prev_out = vc.out
            r[base | 8] = vc.env >> 4
            r[base | 9] = (vc.out >> 7) & 0xFF
            vl, vr = _s8(r[base]), _s8(r[base | 1])
            main_l = _clamp16(main_l + ((vc.out * vl) >> 6))
            main_r = _clamp16(main_r + ((vc.out * vr) >> 6))
            if eon & bit:
                echo_l = _clamp16(echo_l + ((vc.out * vl) >> 6))
                echo_r = _clamp16(echo_r + ((vc.out * vr) >> 6))
        if koff is not None:
            self.kon = 0

        # the echo: the oldest entry out of the ring, through the FIR, the new one in
        addr = ((r[0x6D] << 8) + self.echo_idx * 4) & 0xFFFF
        ram = self.ram

        def rd16(a):
            return _s16(ram[a & 0xFFFF] | (ram[(a + 1) & 0xFFFF] << 8))
        self.fir_i = (self.fir_i + 1) & 7
        self.fir_l[self.fir_i] = rd16(addr) >> 1
        self.fir_r[self.fir_i] = rd16(addr + 2) >> 1
        sums = []
        for buf in (self.fir_l, self.fir_r):
            acc = 0
            for k in range(7):
                acc += (buf[(self.fir_i - 7 + k) & 7] * _s8(r[(k << 4) | 0xF])) >> 6
            acc = _s16(acc)
            acc = _clamp16(acc + ((buf[self.fir_i] * _s8(r[0x7F])) >> 6))
            sums.append(acc)
        fl, fr = sums
        out_l = _clamp16(((main_l * _s8(r[0x0C])) >> 7) + ((fl * _s8(r[0x2C])) >> 7))
        out_r = _clamp16(((main_r * _s8(r[0x1C])) >> 7) + ((fr * _s8(r[0x3C])) >> 7))
        if flg & 0x40:
            out_l = out_r = 0
        efb = _s8(r[0x0D])
        in_l = _clamp16(echo_l + ((fl * efb) >> 7)) & 0xFFFE
        in_r = _clamp16(echo_r + ((fr * efb) >> 7)) & 0xFFFE
        if not flg & 0x20:
            for a, v in ((addr, in_l), (addr + 2, in_r)):
                ram[a & 0xFFFF] = v & 0xFF
                ram[(a + 1) & 0xFFFF] = (v >> 8) & 0xFF
        if self.echo_idx == 0:
            self.echo_len = (r[0x7D] & 15) << 9
        self.echo_idx += 1
        if self.echo_idx >= self.echo_len:
            self.echo_idx = 0
        self.out.append((out_l, out_r))
        if len(self.out) > 65536:
            del self.out[:32768]
