"""Assemble a bank-switching test cartridge that proves its own banking.

    python tools/nes/uxtest.py sim/roms/uxtest.nes 2      # UxROM
    python tools/nes/uxtest.py sim/roms/mmc1test.nes 1    # MMC1

128 kB of program ROM in eight 16 kB banks. Seven of them hold a routine that
writes its own number to a known address; the eighth is the fixed upper bank
that does the switching, because UxROM always maps the LAST bank at $C000 and
that is where the vectors have to live.

The fixed bank switches to each of the other seven in turn and calls into it.
If banking works, 0..6 appear in order. If it does not -- if every window read
comes from the same place -- the same number appears seven times, which is
exactly the failure a test that only asked "does it run" would sail past.

There is no tile ROM, so the board has to treat tile memory as RAM.
"""
import sys

MAPPER = int(sys.argv[2]) if len(sys.argv) > 2 else 2
BANKS = 8
BANK_SIZE = 16 * 1024

# --- the switchable banks -------------------------------------------------------
# Each is entered at $8000 and writes its number to $0300 + n.
banks = []
for n in range(BANKS):
    code = bytearray(BANK_SIZE)
    # LD A,n is 6502: LDA #n ; STA $0300+n ; RTS
    body = bytes([0xA9, n, 0x8D, 0x00 + n, 0x03, 0x60])
    code[0:len(body)] = body
    banks.append(code)

# --- the fixed bank -------------------------------------------------------------
fixed = bytearray(BANK_SIZE)
p = 0
def emit(*xs):
    global p
    fixed[p:p+len(xs)] = bytes(xs)
    p += len(xs)

# Reset: walk every bank, call it, then loop forever.
emit(0x78)                          # SEI
emit(0xA2, 0x00)                    # LDX #0
loop = p
emit(0x8A)                          # TXA
if MAPPER == 2:
    emit(0x8D, 0x00, 0x80)          # STA $8000   -- UxROM: one plain write
else:
    # MMC1 takes its registers one BIT at a time, low bit first, five writes to
    # the address range that selects the register. $E000 is the PRG bank. The
    # $80 first resets the shift register, in case anything was part-way through.
    emit(0x48)                      # PHA
    emit(0xA9, 0x80)                # LDA #$80
    emit(0x8D, 0x00, 0x80)          # STA $8000   -- reset
    emit(0x68)                      # PLA
    for _ in range(5):
        emit(0x8D, 0x00, 0xE0)      # STA $E000
        emit(0x4A)                  # LSR A
    emit(0x8A)                      # TXA  -- restore, LSR destroyed it
emit(0x20, 0x00, 0x80)              # JSR $8000   -- call into it
emit(0xE8)                          # INX
emit(0xE0, BANKS - 1)               # CPX -- the last bank is the fixed one
emit(0xD0, (loop - (p + 2)) & 0xFF) # BNE loop
here = p
emit(0x4C, 0x00 | (0xC000 + here) & 0xFF, ((0xC000 + here) >> 8))  # JMP here

# Vectors live in the fixed bank, which is why UxROM fixes the top half at all.
fixed[BANK_SIZE - 6:BANK_SIZE] = bytes([0x00, 0xC0,   # NMI
                                        0x00, 0xC0,   # RESET
                                        0x00, 0xC0])  # IRQ

prg = b"".join(banks[:BANKS - 1]) + bytes(fixed)
# The last 16 kB must be the fixed bank, so it goes last and the switchable
# banks fill everything below it.
prg = b"".join(banks) 
prg = prg[:BANK_SIZE * (BANKS - 1)] + bytes(fixed)

header = bytes([0x4E, 0x45, 0x53, 0x1A,
                len(prg) // 16384,   # PRG banks
                0,                   # no CHR ROM: the board gives it RAM
                (MAPPER << 4) | 1,   # mapper number, vertical mirroring
                0x00]) + bytes(8)

open(sys.argv[1], "wb").write(header + prg)

# Alongside the ROM, the two things the testbench needs to know: which mapper
# to behave as, and where to read the image from. A config file rather than a
# simulator command-line argument, because that is the pattern that already
# works in this tree.
from pathlib import Path
out = Path(sys.argv[1]).parent
tag = "mmc1" if MAPPER == 1 else "ux"
(out / (tag + "_prg.hex")).write_text("".join("%02X" % b + chr(10) for b in prg))
(out / "bank_cfg.txt").write_text(str(MAPPER) + chr(10))
print(f"{sys.argv[1]}: {len(prg)//1024} kB in {len(prg)//BANK_SIZE} banks, "
      f"mapper {MAPPER}, CHR RAM")
