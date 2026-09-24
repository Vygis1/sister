"""Host side of the fpgalink register bus. See docs/PROTOCOL.md.

Nothing here knows what a logic analyzer is. It reads and writes registers;
the peripherals are just addresses.
"""

import socket
import struct
import threading

MAGIC = 0x4641
VERSION = 1
DEFAULT_PORT = 5005

OP_READ = 0x01
OP_WRITE = 0x02
OP_READ_BLOCK = 0x03
OP_IDENT = 0x04
OP_RESPONSE = 0x80

HEADER = struct.Struct(">HBBHBBI")  # magic, ver, op, seq, status, count, addr
HEADER_LEN = HEADER.size

STATUS_TEXT = {
    0x00: "OK",
    0x01: "bad magic or version",
    0x02: "unknown opcode",
    0x03: "address not mapped",
    0x04: "read-only register",
}

# Address map (docs/PROTOCOL.md)
SYS_BASE = 0x0000_0000
SYS_ID = SYS_BASE + 0x00
SYS_VERSION = SYS_BASE + 0x04
SYS_SCRATCH = SYS_BASE + 0x08
SYS_UPTIME = SYS_BASE + 0x0C

LA_BASE = 0x0001_0000
LA_ID = LA_BASE + 0x00
LA_CTRL = LA_BASE + 0x04
LA_STATUS = LA_BASE + 0x08
LA_CHAN_MASK = LA_BASE + 0x0C
LA_DIVISOR = LA_BASE + 0x10
LA_DEPTH = LA_BASE + 0x14
LA_PRETRIG = LA_BASE + 0x18
LA_TRIG_MASK = LA_BASE + 0x1C
LA_TRIG_VALUE = LA_BASE + 0x20
LA_TRIG_RISE = LA_BASE + 0x24
LA_TRIG_FALL = LA_BASE + 0x28

LA_BUF_BASE = 0x0002_0000

CTRL_ARM = 1 << 0
CTRL_FORCE_TRIG = 1 << 1
CTRL_RESET = 1 << 2

STATUS_ARMED = 1 << 0
STATUS_TRIGGERED = 1 << 1
STATUS_DONE = 1 << 2

MAX_WORDS = 255  # count is one byte


class LinkError(Exception):
    pass


class LinkTimeout(LinkError):
    """Nobody answered at all, as opposed to answering with a complaint.

    Worth its own type: callers that decide whether the board is still there
    must not be fooled by a board that is plainly there and merely objecting to
    the address it was handed.
    """
    pass


class Link:
    """A UDP register bus to one FPGA (or to mock_fpga.py)."""

    def __init__(self, host="127.0.0.1", port=DEFAULT_PORT, timeout=0.05, retries=8):
        self.addr = (host, port)
        self.retries = retries
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(timeout)
        # Windows turns an ICMP "port unreachable" for anything this socket ever
        # sent into a ConnectionResetError on the next recv -- and keeps doing
        # it. One stray reply while the board reboots then poisons every read
        # after. Tell the stack not to do that.
        if hasattr(socket, "SIO_UDP_CONNRESET"):
            try: self.sock.ioctl(socket.SIO_UDP_CONNRESET, False)
            except OSError: pass
        self._seq = 0
        # One socket and one sequence counter, so concurrent callers would match
        # each other's replies to their own requests and both time out. Owning
        # the lock here means callers never have to know that.
        self._lock = threading.Lock()

    def close(self):
        self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _next_seq(self):
        self._seq = (self._seq + 1) & 0xFFFF
        return self._seq

    def _transact(self, opcode, addr, words=()):
        """Send one request, return the payload words of the response.

        Retries on timeout and on a stale seq, because UDP.
        """
        with self._lock:
            return self._transact_locked(opcode, addr, words)

    def _transact_locked(self, opcode, addr, words=()):
        seq = self._next_seq()
        payload = struct.pack(f">{len(words)}I", *words) if words else b""
        count = len(words) if words else 1
        if count > MAX_WORDS:
            raise LinkError(f"count {count} exceeds {MAX_WORDS} words per packet")
        pkt = HEADER.pack(MAGIC, VERSION, opcode, seq, 0, count, addr) + payload

        last = None
        for _ in range(self.retries):
            self.sock.sendto(pkt, self.addr)
            try:
                reply = self._recv_matching(seq)
            except socket.timeout:
                last = LinkTimeout(
                    f"timeout talking to {self.addr[0]}:{self.addr[1]}")
                continue
            return reply
        raise last or LinkTimeout("no response")

    def _recv_matching(self, seq):
        """Read datagrams until one matches seq; ignore late replies to old requests."""
        while True:
            try:
                data, _ = self.sock.recvfrom(65535)
            except ConnectionResetError:
                continue        # Windows: an ICMP unreachable for an old send, not a reply; keep waiting
            if len(data) < HEADER_LEN:
                continue
            magic, ver, op, rseq, status, count, _addr = HEADER.unpack(data[:HEADER_LEN])
            if magic != MAGIC or ver != VERSION or not (op & OP_RESPONSE):
                continue
            if rseq != seq:
                continue  # stale reply from a retried request
            if status != 0:
                raise LinkError(STATUS_TEXT.get(status, f"status 0x{status:02x}"))
            body = data[HEADER_LEN:HEADER_LEN + count * 4]
            if len(body) < count * 4:
                raise LinkError("short packet: header claims more words than arrived")
            return list(struct.unpack(f">{count}I", body))

    # --- register access -------------------------------------------------

    def read(self, addr):
        return self._transact(OP_READ, addr)[0]

    def write(self, addr, value):
        self._transact(OP_WRITE, addr, [value & 0xFFFFFFFF])

    def write_block(self, addr, words):
        """Write consecutive registers, chunked to fit the one-byte count.

        The protocol has always carried multiple words per WRITE; sending them
        one at a time turns a 40 KB ROM upload into ten thousand round trips.
        """
        i = 0
        while i < len(words):
            chunk = words[i:i + MAX_WORDS]
            self._transact(OP_WRITE, addr + i * 4, [w & 0xFFFFFFFF for w in chunk])
            i += len(chunk)

    def read_block_pipelined(self, addr, nwords, depth=8):
        """Read nwords with up to `depth` requests in flight.

        One request per round trip is what read_block does, and a 640x240 frame
        is 300 of them: 95 ms, six frames a second. The link tags every reply
        with its request's seq, so several can be outstanding; a chunk whose
        reply does not come back is simply asked for again.

        MEASURED: the FPGA side takes one request at a time and drops the rest,
        so any depth above 1 is SLOWER (retries). Kept for a link with an RX
        queue; do not use it against the current shell.
        """
        chunks = list(range(0, nwords, MAX_WORDS))
        out = [None] * len(chunks)
        with self._lock:
            pending = {}            # seq -> chunk index
            nxt = 0
            def send(ci):
                seq = self._next_seq()
                n = min(MAX_WORDS, nwords - chunks[ci])
                # a block read carries its word count as the single payload word
                pkt = HEADER.pack(MAGIC, VERSION, OP_READ_BLOCK, seq, 0, 1, addr + chunks[ci] * 4) + struct.pack(">I", n)
                self.sock.sendto(pkt, self.addr)
                pending[seq] = ci
            tries = 0
            while nxt < len(chunks) or pending:
                while nxt < len(chunks) and len(pending) < depth:
                    send(nxt); nxt += 1
                try:
                    data, _ = self.sock.recvfrom(65535)
                except socket.timeout:
                    tries += 1
                    if tries > self.retries * 4:
                        raise LinkTimeout(f"timeout talking to {self.addr[0]}:{self.addr[1]}")
                    for seq in list(pending):        # ask again for everything outstanding
                        ci = pending.pop(seq); send(ci)
                    continue
                if len(data) < HEADER_LEN:
                    continue
                magic, ver, op, rseq, status, count, _a = HEADER.unpack(data[:HEADER_LEN])
                if magic != MAGIC or ver != VERSION or not (op & OP_RESPONSE) or rseq not in pending:
                    continue
                ci = pending.pop(rseq)
                if status != 0:
                    raise LinkError(STATUS_TEXT.get(status, f"status 0x{status:02x}"))
                body = data[HEADER_LEN:HEADER_LEN + count * 4]
                if len(body) < count * 4:
                    send(ci); continue
                out[ci] = struct.unpack(f">{count}I", body)
        result = []
        for c in out: result.extend(c)
        return result

    def read_block(self, addr, nwords):
        """Read nwords consecutive registers, chunked to fit the one-byte count."""
        out = []
        while nwords > 0:
            chunk = min(nwords, MAX_WORDS)
            out.extend(self._transact(OP_READ_BLOCK, addr + len(out) * 4, [chunk]))
            nwords -= chunk
        return out

    def ident(self):
        magic, version, caps, uptime = self._transact(OP_IDENT, 0)
        return {
            "magic": f"0x{magic:08X}",
            "name": struct.pack(">I", magic).decode("ascii", "replace"),
            "version": version,
            "caps": caps,
            "uptime_ms": uptime,
        }

    def ping(self):
        """Prove the bus works in both directions using the scratch register."""
        token = 0xDEADBEEF
        self.write(SYS_SCRATCH, token)
        got = self.read(SYS_SCRATCH)
        if got != token:
            raise LinkError(f"scratch readback 0x{got:08X}, expected 0x{token:08X}")
        return True
