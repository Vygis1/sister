# fpgalink — register bus over UDP

The PC talks to the FPGA by reading and writing 32-bit registers at 32-bit
addresses. That is the whole protocol. Every feature — logic analyzer, synth,
YM7137 bus master — is a peripheral in the address map, not a new endpoint.

Transport is UDP on port **5005**. Request/response, one transaction per packet.
UDP because it is small enough to implement in RTL without a CPU; reliability is
the host's problem (retry on timeout, match `seq`).

All fields are **big-endian** — network order, and the natural order for a shift
register in hardware.

## Packet

    offset size field
    0      2    magic   0x4641 ("FA")
    2      1    version 1
    3      1    opcode
    4      2    seq     echoed in the response
    6      1    status  0 in requests; 0 = OK in responses
    7      1    count   payload length in 32-bit words, 1..255
    8      4    addr
    12     ..   payload (count * 4 bytes)

12-byte header, word-aligned, no variable-length fields before the payload.
That is deliberate: the RTL parser is a counter and a shift register.

## Opcodes

| code | name       | payload (req) | payload (resp) |
|------|------------|---------------|----------------|
| 0x01 | READ       | none          | `count` words  |
| 0x02 | WRITE      | `count` words | none           |
| 0x03 | READ_BLOCK | none          | `count` words, `addr` auto-increments |
| 0x04 | IDENT      | none          | 4 words: magic, version, caps, uptime |

Responses set bit 7 of the opcode (`READ` -> `0x81`).

## Status codes

| code | meaning |
|------|---------|
| 0x00 | OK |
| 0x01 | bad magic or version |
| 0x02 | unknown opcode |
| 0x03 | address not mapped |
| 0x04 | write to a read-only register |

## Address map

| base        | peripheral |
|-------------|------------|
| 0x0000_0000 | SYS — identity, scratch, uptime |
| 0x0001_0000 | LA  — logic analyzer control |
| 0x0002_0000 | LA capture buffer (read via READ_BLOCK) |
| 0x0003_0000 | SYN — eight-voice oscillator bank |
| 0x0004_0000 | SYN — audio ring buffer |
| 0x0005_0000 | MDIO — a window onto the PHY's own registers |

### SYS — 0x0000_0000

| offset | access | name    | notes |
|--------|--------|---------|-------|
| 0x00   | ro     | ID      | 0x46504741 ("FPGA") |
| 0x04   | ro     | VERSION | gateware version |
| 0x08   | rw     | SCRATCH | writable, does nothing — proves the bus both ways |
| 0x0C   | ro     | UPTIME  | free-running counter, 1 kHz ticks |

`SCRATCH` is the first thing to test on real hardware: write a value, read it
back. If that works the whole transport works.

### LA — 0x0001_0000

| offset | access | name        | notes |
|--------|--------|-------------|-------|
| 0x00   | ro     | ID          | 0x4C41_0001 |
| 0x04   | rw     | CTRL        | bit0 ARM, bit1 FORCE_TRIG, bit2 RESET |
| 0x08   | ro     | STATUS      | bit0 ARMED, bit1 TRIGGERED, bit2 DONE; bits 31:16 fill level |
| 0x0C   | rw     | CHAN_MASK   | which of the 32 channels to record |
| 0x10   | rw     | DIVISOR     | sample rate = 50 MHz / (DIVISOR + 1) |
| 0x14   | rw     | DEPTH       | samples to capture |
| 0x18   | rw     | PRETRIG     | samples retained from before the trigger |
| 0x1C   | rw     | TRIG_MASK   | channels the trigger looks at |
| 0x20   | rw     | TRIG_VALUE  | level to match on masked channels |
| 0x24   | rw     | TRIG_RISE   | channels that trigger on a rising edge |
| 0x28   | rw     | TRIG_FALL   | channels that trigger on a falling edge |

Arming sequence: RESET, configure, then ARM. Poll STATUS until DONE, then
READ_BLOCK the buffer at 0x0002_0000.

### MDIO — 0x0005_0000

A window onto the Ethernet PHY's internal registers. The PHY is a separate chip
with its own register space; this reaches it over the two-wire management bus.

| offset | access | name   | notes |
|--------|--------|--------|-------|
| 0x00   | ro     | ID     | 0x4D44_0001 |
| 0x04   | rw     | CMD    | writing starts a transaction: bit 16 = write, bits 12:8 = PHY address, bits 4:0 = register |
| 0x08   | ro     | STATUS | bit 0 = busy |
| 0x0C   | rw     | WDATA  | data for a write transaction |
| 0x10   | ro     | RDATA  | result of the last read |

A transaction takes about 40 us, far too long to stall a UDP reply for, so a
write to CMD only starts one. Poll STATUS until busy clears, then read RDATA.

Two traps worth knowing, both found the hard way on real hardware:

- **BMSR bit 2 (link status) is latch-low.** A single read after any link event
  returns the stale "down" state. Read it twice and believe the second.
- **The LAN8720 turns the bus around early**, driving the first turnaround bit
  rather than the second. A master that samples the textbook window reads back
  `(value << 1) | 1` — stable, plausible and wrong.

## Debugging the bus with itself

MDC and MDIO are wired to channels 6 and 7 of the logic analyzer, so a capture
triggered on MDC shows the management bus bit by bit. That is how both traps
above were found: the register readings were self-consistent, and only the wire
showed what was actually happening.

### SYN — 0x0003_0000

Eight voices, 48828.125 Hz, no DAC: samples leave as UDP so the audio arrives in
software bit-exact.

| offset | access | name | notes |
|--------|--------|------|-------|
| 0x00 | ro | ID | 0x5359_0001 |
| 0x04 | rw | CTRL | bit 0 = enable |
| 0x08 | rw | MASTER_VOL | 0..65535 |
| 0x0C | ro | SAMPLE_RATE | Hz, truncated — the exact rate is 50e6/1024 |
| 0x10 | rw | ATTACK | envelope step per sample while gated |
| 0x14 | rw | RELEASE | envelope step per sample while released |
| 0x20 | ro | WCOUNT | total words ever written to the ring buffer |
| 0x40 + v*4 | rw | PHASE_INC[v] | `freq * 2^32 / rate`, about 87961 per Hz |
| 0x60 + v*4 | rw | VOICE[v] | bit 0 gate, bits 3:1 wave, bits 31:16 volume |

Waveforms: 0 square, 1 saw, 2 triangle, 3 noise. Voices span 32 bytes each side
of the map, not 16 — an address decode covering only 0x40-0x4F silently drops
voices 4 to 7.

The ring buffer is page 0x0004_0000: 4096 words, two 16-bit samples per word,
low half first, so about 167 ms of history and 510 samples per READ_BLOCK.
WCOUNT is a free-running total rather than an index so a host can tell "nothing
new" from "I fell behind and the buffer wrapped".

## One request at a time

The FPGA **drops any frame that arrives while it is transmitting a reply** — the
packet engine is in its transmit state and not listening. That is fine for a
strict request/response client and fatal for a pipelined one, and it means
dropped requests are normal rather than exceptional.

So keep the timeout short. The board answers in microseconds; `fpgalink.py` uses
50 ms with eight retries. A one-second timeout turns each ordinary drop into a
one-second stall, which is how a real-time capture ends up a full second behind
the ring buffer.

Concurrent callers need one lock around the socket, which `Link` now owns: one
socket and one sequence counter means two threads otherwise match each other's
replies to their own requests and both time out.
