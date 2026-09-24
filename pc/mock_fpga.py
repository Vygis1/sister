"""A fake FPGA that speaks fpgalink, so the host side can be built and tested
before any wire is soldered.

It synthesises what we expect to see on the PSR-2 key matrix: Port B scanning
one row low at a time, Port A reading columns back, with a few keys held down.
That makes it a decoder testbed as well as a UI backend -- if the matrix decoder
works against this, it is at least self-consistent before it meets real silicon.

    python pc/mock_fpga.py [--port 5005] [--verbose]
"""

import argparse
import random
import socket
import struct
import time

import fpgalink as fl

GATEWARE_VERSION = 0x00010000
SAMPLE_CLOCK_HZ = 50_000_000

# Keys the fake keyboard is holding down, as (scan row on port B, column on port A).
HELD_KEYS = [(2, 3), (2, 5), (5, 1)]

SCAN_SAMPLES = 64  # samples each row is held low for


class MockDevice:
    def __init__(self, verbose=False):
        self.verbose = verbose
        self.t0 = time.monotonic()
        self.scratch = 0
        self.regs = {
            fl.LA_CHAN_MASK: 0xFFFFFFFF,
            fl.LA_DIVISOR: 0,
            fl.LA_DEPTH: 4096,
            fl.LA_PRETRIG: 512,
            fl.LA_TRIG_MASK: 0,
            fl.LA_TRIG_VALUE: 0,
            fl.LA_TRIG_RISE: 0,
            fl.LA_TRIG_FALL: 0,
        }
        self.armed = False
        self.triggered = False
        self.done = False
        self.arm_time = 0.0
        self.buffer = []

    # --- synthetic capture ----------------------------------------------

    def _synthesize(self, depth):
        """Build a plausible matrix-scan trace.

        ch0-7   PA0-7, column readback, idle high, pulled low by a held key
        ch8-15  PB0-7, scan rows, one-hot low
        ch16    a slow square wave, so there is always something moving
        ch17    occasional noise, to make the UI job honest
        """
        out = []
        mask = self.regs[fl.LA_CHAN_MASK]
        for i in range(depth):
            row = (i // SCAN_SAMPLES) % 8
            portb = (~(1 << row)) & 0xFF  # active low, one-hot

            porta = 0xFF
            for key_row, key_col in HELD_KEYS:
                if key_row == row:
                    porta &= ~(1 << key_col) & 0xFF

            word = porta & 0xFF
            word |= (portb & 0xFF) << 8
            word |= (1 << 16) if (i // 512) % 2 else 0
            word |= (1 << 17) if random.random() < 0.02 else 0
            out.append(word & mask)
        return out

    def _sample_period(self):
        return (self.regs[fl.LA_DIVISOR] + 1) / SAMPLE_CLOCK_HZ

    def _capture_duration(self):
        # Real hardware takes depth * sample_period, but a divisor of 0 would
        # complete instantly; floor it so the UI gets to see the ARMED state.
        return max(self.regs[fl.LA_DEPTH] * self._sample_period(), 0.15)

    def _poll_capture(self):
        """Finish the capture once enough wall-clock time has passed for it."""
        if not self.armed or self.done:
            return
        if time.monotonic() - self.arm_time >= self._capture_duration():
            depth = self.regs[fl.LA_DEPTH]
            self.buffer = self._synthesize(depth)
            self.triggered = True
            self.done = True
            self.armed = False
            if self.verbose:
                print(f"  capture complete, {depth} samples")

    def _fill_level(self):
        if self.done:
            return self.regs[fl.LA_DEPTH]
        if not self.armed:
            return 0
        frac = min((time.monotonic() - self.arm_time) / self._capture_duration(), 1.0)
        return int(self.regs[fl.LA_DEPTH] * frac)

    # --- register access -------------------------------------------------

    def read(self, addr):
        self._poll_capture()

        if addr == fl.SYS_ID:
            return 0x46504741
        if addr == fl.SYS_VERSION:
            return GATEWARE_VERSION
        if addr == fl.SYS_SCRATCH:
            return self.scratch
        if addr == fl.SYS_UPTIME:
            return int((time.monotonic() - self.t0) * 1000) & 0xFFFFFFFF

        if addr == fl.LA_ID:
            return 0x4C410001
        if addr == fl.LA_CTRL:
            return fl.CTRL_ARM if self.armed else 0
        if addr == fl.LA_STATUS:
            status = 0
            status |= fl.STATUS_ARMED if self.armed else 0
            status |= fl.STATUS_TRIGGERED if self.triggered else 0
            status |= fl.STATUS_DONE if self.done else 0
            return status | ((self._fill_level() & 0xFFFF) << 16)
        if addr in self.regs:
            return self.regs[addr]

        if fl.LA_BUF_BASE <= addr < fl.LA_BUF_BASE + len(self.buffer) * 4:
            return self.buffer[(addr - fl.LA_BUF_BASE) // 4]

        raise KeyError(addr)

    def write(self, addr, value):
        self._poll_capture()

        if addr == fl.SYS_SCRATCH:
            self.scratch = value
            return
        if addr in (fl.SYS_ID, fl.SYS_VERSION, fl.SYS_UPTIME, fl.LA_ID, fl.LA_STATUS):
            raise PermissionError(addr)

        if addr == fl.LA_CTRL:
            if value & fl.CTRL_RESET:
                self.armed = self.triggered = self.done = False
                self.buffer = []
                if self.verbose:
                    print("  reset")
            if value & fl.CTRL_ARM:
                self.armed = True
                self.triggered = self.done = False
                self.buffer = []
                self.arm_time = time.monotonic()
                if self.verbose:
                    print(f"  armed, depth={self.regs[fl.LA_DEPTH]}")
            if value & fl.CTRL_FORCE_TRIG and self.armed:
                self.arm_time = 0.0  # complete on the next poll
            return

        if addr in self.regs:
            self.regs[addr] = value
            return

        raise KeyError(addr)


def _dispatch(dev, op, addr, count, data):
    if op == fl.OP_IDENT:
        return [0x46504741, GATEWARE_VERSION, 0x00000001,
                int((time.monotonic() - dev.t0) * 1000) & 0xFFFFFFFF]
    if op == fl.OP_READ:
        return [dev.read(addr)]
    if op == fl.OP_WRITE:
        payload = data[fl.HEADER_LEN:fl.HEADER_LEN + count * 4]
        for i, value in enumerate(struct.unpack(f">{count}I", payload)):
            dev.write(addr + i * 4, value)
        return []
    if op == fl.OP_READ_BLOCK:
        nwords = struct.unpack(">I", data[fl.HEADER_LEN:fl.HEADER_LEN + 4])[0]
        return [dev.read(addr + i * 4) for i in range(min(nwords, fl.MAX_WORDS))]
    raise ValueError(op)


def serve(port, verbose):
    dev = MockDevice(verbose)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", port))
    print(f"mock FPGA listening on udp/{port}  (ctrl-c to stop)")

    while True:
        data, peer = sock.recvfrom(65535)
        if len(data) < fl.HEADER_LEN:
            continue
        magic, ver, op, seq, _st, count, addr = fl.HEADER.unpack(data[:fl.HEADER_LEN])

        if magic != fl.MAGIC or ver != fl.VERSION:
            sock.sendto(fl.HEADER.pack(fl.MAGIC, fl.VERSION, op | fl.OP_RESPONSE,
                                       seq, 0x01, 0, addr), peer)
            continue

        try:
            words = _dispatch(dev, op, addr, count, data)
            status = 0
        except KeyError:
            words, status = [], 0x03
        except PermissionError:
            words, status = [], 0x04
        except ValueError:
            words, status = [], 0x02

        if verbose:
            print(f"{peer[0]}:{peer[1]} op=0x{op:02x} addr=0x{addr:08X} "
                  f"count={count} -> status={status} words={len(words)}")

        body = struct.pack(f">{len(words)}I", *words) if words else b""
        header = fl.HEADER.pack(fl.MAGIC, fl.VERSION, op | fl.OP_RESPONSE,
                                seq, status, len(words), addr)
        sock.sendto(header + body, peer)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Fake FPGA speaking the fpgalink protocol")
    ap.add_argument("--port", type=int, default=fl.DEFAULT_PORT)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    try:
        serve(args.port, args.verbose)
    except KeyboardInterrupt:
        print("\nstopped")
