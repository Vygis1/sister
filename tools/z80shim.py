"""The few bytes of Z80 that stand in for CP/M, shared by the board and the sim.

A CP/M .COM file expects three things that do not exist here: to be entered at
$0100 with a stack set up, a BDOS entry at $0005, and somewhere to jump when it
has finished. None of that is worth putting in hardware, so it is written as
Z80 code and dropped into low memory.

The layout keeps out of the way of the two addresses CP/M fixes:

    $0000  JP bootstrap    a finished program jumps here
    $0005  JP bdos         programs call here for operating system services
    $0040  bootstrap       set the stack, then enter at $0100 -- but only the
                           FIRST time, because a finished program arrives back
                           at $0000 and must stop rather than run again
    $005F  a flag byte, which is how "first time" is remembered
    $0060  bdos            function 0 is "exit", function 2 prints E, function
                           9 prints the string at DE; anything else returns

Function 0 matters: ZEXDOC finishes by calling it rather than by jumping to
$0000, so without it the shim returned and the program ran on into whatever
followed, filling the output buffer with rubbish after "Tests complete".

Relative jumps count from the address AFTER the instruction. Getting that wrong
printed the function number as the first character and started every string one
byte late, so the targets are written out beside each one.
"""

HALT_AT = 0x0050          # where a finished program comes to rest

SHIM = {
    0x0000: [0xC3, 0x40, 0x00],            # JP $0040
    0x0005: [0xC3, 0x60, 0x00],            # JP $0060

    0x0040: [
        0x31, 0x00, 0xF0,                  # LD SP,$F000
        0x3A, 0x5F, 0x00,                  # LD A,($005F)   have we been here?
        0xB7,                              # OR A
        0x20, 0x07,                        # JR NZ,+7  -> $0050, we have
        0x3C,                              # INC A
        0x32, 0x5F, 0x00,                  # LD ($005F),A   remember that we have
        0xC3, 0x00, 0x01,                  # JP $0100       run the program
        0x76,                              # $0050: HALT    it has finished
    ],

    0x0060: [
        0x79,                              # LD A,C
        0xB7,                              # OR A            function 0?
        0xCA, 0x50, 0x00,                  # JP Z,$0050      exit: go and halt
        0xFE, 0x02,                        # CP 2
        0x28, 0x05,                        # JR Z,+5   -> $006E
        0xFE, 0x09,                        # CP 9
        0x28, 0x05,                        # JR Z,+5   -> $0072
        0xC9,                              # RET             anything else
        0x7B,                              # $006E: LD A,E
        0xD3, 0x00,                        # OUT ($00),A
        0xC9,                              # RET
        0x1A,                              # $0072: LD A,(DE)
        0xFE, 0x24,                        # CP '$'
        0xC8,                              # RET Z
        0xD3, 0x00,                        # OUT ($00),A
        0x13,                              # INC DE
        0x18, 0xF7,                        # JR -9     -> $0072
    ],
}


def apply_to(mem):
    """Drop the shim into a 64 kB bytearray."""
    for base, code in SHIM.items():
        mem[base:base + len(code)] = bytes(code)
    return mem


if __name__ == "__main__":
    # Written out so the testbench loads exactly the same bytes the board runs.
    from pathlib import Path
    low = bytearray(256)
    apply_to(low)
    out = Path("sim/roms/z80/shim.hex")
    out.write_text("".join(f"{b:02X}\n" for b in low))
    print(f"wrote {out}, {len(low)} bytes, halt at ${HALT_AT:04X}")
