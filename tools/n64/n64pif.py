"""The N64's PIF and joybus, for tools/n64/n64model.py: controllers and the
cartridge's EEPROM, as the CPU reaches them through PIF RAM and the SI.

Behaviour follows ares (ares/n64/pif/hle.cpp, controller/gamepad/gamepad.cpp,
cartridge/joybus.cpp; ISC). Our boot skips IPL3, so the PIF starts where IPL3
leaves it -- running, with the boot handshake done -- and only the joybus
matters:

  - A write to PIF RAM (by the CPU, or an SI DMA from RDRAM) with bit 0 of the
    command byte (RAM[63]) set: the bit is cleared and the channels' packets
    are found (joyParse). From byte 0, each channel in turn gets either a
    packet -- send length, receive length, the bytes sent, room for the bytes
    received -- or 00 (skip the channel), FD (reset it), FF (padding, no
    channel), FE (the end).
  - An SI DMA from PIF RAM to RDRAM runs the packets found (joyRun), writing
    each device's answer into its packet; then the 64 bytes are copied. A
    channel with nothing on it gets bit 7 set in its receive-length byte; an
    answer longer than asked for, bit 6.

Channels 0-3 are the controllers (a gamepad, no pak), channel 4 the
cartridge's EEPROM (none, 4 kbit or 16 kbit). No timing: an SI DMA completes
at once, which is when the CPU sees it complete anyway.
"""


def address_crc(address):
    """the 5-bit CRC a controller pak address carries"""
    crc = 0
    for _ in range(16):
        x = 0x15 if crc & 0x10 else 0
        crc = (crc << 1) & 0x1F
        if address & 0x8000:
            crc |= 1
        address = (address << 1) & 0xFFFF
        crc ^= x
    return crc


def data_crc(data):
    """the 8-bit CRC over 32 bytes of pak data"""
    crc = 0
    for i in range(33):
        for j in range(7, -1, -1):
            x = 0x85 if crc & 0x80 else 0
            crc = (crc << 1) & 0xFF
            if i < 32 and data[i] & (1 << j):
                crc |= 1
            crc ^= x
    return crc


class Joybus:
    def __init__(self, ram):
        self.ram = ram                      # PIF RAM: 64 bytes, shared with the bus
        self.addr = [0] * 5
        self.skip = [1] * 5
        self.reset = [0] * 5
        # the controllers: the 32-bit word a read returns
        # (buttons in [31:16] -- A B Z Start Up Down Left Right, -, -, L R CU CD CL CR --
        # then the stick's X and Y as signed bytes), or None for nothing plugged in
        self.pads = [0, None, None, None]
        self.eeprom = None                  # bytearray(512) or bytearray(2048)

    # --- the command byte ------------------------------------------------------------
    def wrote(self):
        """after a write to PIF RAM: bit 0 of the command byte asks for the packets to be parsed"""
        if self.ram[63] & 0x01:
            self.ram[63] &= ~0x01
            self.skip = [1] * 5
            self.reset = [0] * 5
            self.parse()

    def before_read(self):
        """before an SI DMA out of PIF RAM: run the packets (bit 1 is the CIC challenge: not here)"""
        if self.ram[63] & 0x02:
            return
        self.run()

    def parse(self):
        off, ch = 0, 0
        while ch < 5 and off < 64:
            send = self.ram[off]; off += 1
            if send == 0xFE: break
            if send == 0xFF: continue
            if send == 0x00: ch += 1; continue
            if send == 0xFD: self.reset[ch] = 1; ch += 1; continue
            start = off - 1
            recv = self.ram[off & 63]; off += 1             # PIF RAM's addresses wrap
            off += (send & 0x3F) + (recv & 0x3F)
            if off < 64:
                self.addr[ch] = start
                self.skip[ch] = 0
                ch += 1

    def run(self):
        ram = self.ram
        for ch in range(4, -1, -1):
            if self.reset[ch] or self.skip[ch]:
                continue
            off = self.addr[ch]
            send = ram[off]; off += 1
            if send & 0x80 or send & 0x40:
                continue
            roff = off
            recv = ram[off] & 0x3F
            send &= 0x3F
            ram[off] = recv; off += 1
            inp = bytes(ram[(off + i) & 63] for i in range(send))
            off += send
            out = bytearray(64)
            valid, over = self.comm(ch, send, recv, inp, out)
            if not valid:
                ram[roff] = 0x80 | recv
            if over:
                ram[roff] = 0x40 | recv
            if valid:
                for i in range(recv):
                    ram[off & 63] = out[i]                  # PIF RAM's addresses wrap
                    off += 1

    def comm(self, ch, send, recv, inp, out):
        cmd = inp[0] if send else 0
        if ch < 4:
            pad = self.pads[ch]
            if pad is None:
                return False, False
            if cmd in (0x00, 0xFF):
                out[0:3] = bytes((0x05, 0x00, 0x02))          # a gamepad, no pak
                return True, False
            if cmd == 0x01:
                out[0:4] = pad.to_bytes(4, 'big')
                return True, recv > 4
            if cmd == 0x02 and send >= 3 and recv >= 1:       # pak read: no pak
                if recv >= 33:
                    out[32] = data_crc(bytes(32)) ^ 0xFF
                return True, False
            if cmd == 0x03 and send >= 4 and recv >= 1:       # pak write: no pak
                n = min(send - 3, 32)
                out[0] = (data_crc(inp[3:35]) if n == 32 else 0) ^ 0xFF
                return True, False
            return False, False
        # channel 4: the cartridge
        if self.eeprom is None:
            return False, False
        if cmd in (0x00, 0xFF):
            out[0:3] = bytes((0x00, 0x80 if len(self.eeprom) == 512 else 0xC0, 0x00))
            return True, False
        if cmd == 0x04 and send >= 2:
            a = inp[1] * 8
            for i in range(recv):
                out[i] = self.eeprom[(a + i) % len(self.eeprom)]
            return True, False
        if cmd == 0x05 and send >= 2 and recv >= 1:
            out[0] = 0x00
            a = inp[1] * 8
            for i in range(send - 2):
                self.eeprom[(a + i) % len(self.eeprom)] = inp[2 + i]
            return True, False
        return False, False
