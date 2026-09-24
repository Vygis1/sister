# The Z80, and the mistake worth not repeating

Status: **verified.** `rtl/z80.v` with `z80_decode.vh` and `z80_resume.vh`
passes both exercisers on hardware, by CRC, with nothing failing:

    zexdoc   67 / 67    every documented instruction        784 s
    zexall   67 / 67    the same, plus the undocumented
                        X and Y flag bits                  1422 s

plus `prelim.com` and 57 checks in `sim/tb_z80_unit.v`.

ZEXALL is the one that matters for the flags. Nothing is supposed to depend on
bits 3 and 5 of F, plenty of software does, and it is the only test that
notices when `CP` takes them from the operand instead of the result, or when
`BIT`'s memory forms take them from the address.

The first attempt is still in `rtl/wip/` because the mistake it made is the
interesting part of this file's history, and the note below is what the second
attempt was built from.

## What went wrong the first time

The sequencer gathers operands in shared states -- fetch an immediate, read
memory, pop a word -- and each of them returns to a state held in `ret_st`.
Every multi-cycle instruction set `ret_st <= S_EXEC`, meaning "come back to me
when you have it".

But `S_EXEC` is the decode. Arriving there re-reads `op` and starts the
instruction over, which gathers the operand again, which returns to `S_EXEC`.
The CPU would not execute a single multi-cycle instruction.

The tell was there while writing it: the decode kept setting flags with names
like `ldst`, `alust`, `incst` that nothing ever read. Those flags were reaching
for a continuation that was never designed. A register that is only ever
written is a design that has not finished being thought through.

## The shape that worked

Split "decode" from "resume". One continuation code, set by the decode, checked
at the top of the execute state:

    S_EXEC:
        if (cont != C_NONE) <resume: dispatch on cont>
        else                <decode: dispatch on op>

Then an instruction like `ADD A,(HL)` reads:

    decode:  wz <= HL; cont <= C_ALU; ret_st <= S_EXEC; st <= S_MRD;
    resume:  C_ALU: do_alu(alukind, A, tmp); A <= alu_r; F <= alu_f;
                    cont <= C_NONE;

`cont` must be cleared on every path that finishes an instruction, for the same
reason `pfx`, `cb` and `ed` are: the next instruction has to start clean.

Instructions needing two gathering steps -- `LD (IX+d),n` fetches a
displacement and then an immediate -- need two continuation codes, not one flag.
That is the case to design against, because it is the one a single flag cannot
express.

## Decisions already made that are worth keeping

- **Registers in an array indexed by the Z80's own 3-bit code**, so `LD r,r'`
  is two array accesses. Slot 6, where `(HL)` would be, is scratch.
- **Prefix redirection takes a `plain` argument.** Under DD/FD, codes 4 and 5
  become the halves of IX/IY -- but not when the operand is the other side of
  `LD r,(IX+d)`. Passing that decision in at each call site is what keeps the
  exception visible instead of buried.
- **Flags carry X and Y.** They are undocumented copies of result bits 3 and 5,
  nothing is supposed to read them, and ZEXALL checks them. `CP` takes them
  from the *operand* rather than the result, which is the kind of detail the
  test exists to catch.
- **The prefix state clears at the top of the decode**, so a prefix opcode
  simply re-asserts it and falls through to the next fetch.

## Verification plan

Three programs, in order, all CP/M `.COM` files in `sim/roms/z80/`:

1. `prelim.com` (1280 bytes) -- a preliminary check. Small enough to debug
   against, and it fails early and loudly.
2. `zexdoc.com` (8704 bytes) -- every documented instruction, by CRC.
3. `zexall.com` (8704 bytes) -- the same, including the undocumented flag bits.

The harness is a CP/M shim: load at `$0100`, `RET` at `$0005`, `HALT` at
`$0000`. Watch for an opcode fetch at `$0005` and service the BDOS call from
the debug register outputs -- function 2 prints the character in E, function 9
prints the `$`-terminated string at DE. This is the same idea as the blargg
ROMs reporting to `$6000`: let the test say whether it passed, rather than
reading waveforms and guessing.


## Two more things that only showed up once it ran

**Memory latency is two cycles, not one.** An address assigned with `<=` is not
on the bus until the end of that cycle, so the memory latches it at the end of
the *next* one and the data is readable in the one after. The word-sized
transfers had the gap by accident -- they present a second address in between --
so only the byte-sized reads were wrong, and the symptom was a CPU that fetched
exactly one opcode and then sat still forever.

**The prefix has to be cleared when an instruction finishes, not when the next
one starts decoding.** Clearing it on the way into a decode looks equivalent and
is not: a multi-cycle prefixed instruction keeps its prefix alive across the
continuation and finishes in the *resume* branch, which never ran that clear. So
`RLC (IX+4)` worked and the instruction after it was decoded as a CB opcode.
`tb_z80_unit` catches this by following a DDCB with an ordinary instruction --
testing the DDCB alone would have passed.

## Verification status

- `prelim.com` -- **passes**, 6454 cycles.
- `sim/tb_z80_unit.v` -- **57/57**, covering flags (including the undocumented
  X and Y bits and CP taking them from the operand), INC/DEC, 16-bit adds,
  stack, CALL/RET, JR/DJNZ, the CB page, `(HL)`, `(IX+d)`, DDCB, the exchanges
  and DAA. Runs in seconds, which is the point: ZEXDOC cannot be the inner loop.
- `zexdoc.com` -- **67/67 on hardware**, 784 s. In simulation it does not
  finish its first test in a day; see below.
- `zexall.com` -- **67/67 on hardware**, 1422 s, undocumented flags included.
- Synthesis: **1875 LUTs, 333 registers, no block RAM**, and no multi-driven
  nets. Roughly twice the 6502 next door, which is about right.

## ZEXDOC does not belong in a simulator

Measured here: xsim runs this core at about **1.4 million cycles a second**. At
1.4 *billion* cycles -- seventeen minutes of wall clock -- ZEXDOC had still not
finished the **first of its sixty-seven tests**. Extrapolating, a full run is
somewhere north of a day.

So it is not a slow test to be run overnight; it is the wrong machine for the
job. The board runs at 50 MHz, thirty-five times faster, and turns that day into
well under an hour.

So it runs on the board instead, and that is now built. The Z80 sits in console
slot 1 with the cartridge's program memory as its 64 kB of RAM -- there is not
enough spare block RAM on the part for a second 64 kB, and there does not need
to be, because only one core runs at a time.

`tools/z80hw.py` uploads a .COM file like any other cartridge, selects the Z80,
and reads the console output back over the same register bus the NES uses.
There is no operating system: the handful of things a CP/M program needs are
assembled as Z80 code in `tools/z80shim.py` and dropped into low memory --
a bootstrap that sets the stack and enters at $0100, a BDOS handler at $0005
that sends characters to an I/O port, and a flag so that a finished program
returning to $0000 stops instead of starting again.

`prelim.com` runs on the board in **one second**. ZEXDOC -- all sixty-seven
tests, the first of which 1.4 billion simulated cycles could not finish --
completes in **784 seconds, 67 passed, 0 failed**.

The one thing that went wrong on the first full run was not the CPU: ZEXDOC
finishes by calling BDOS function 0 rather than by jumping to $0000, the shim
did not implement it, so the program returned and ran on into rubbish after
printing "Tests complete". The result was already in by then, but the shim now
handles function 0 properly.

## Instruction coverage

Implemented: the whole main page, the whole CB page, DD/FD including DDCB and
FDCB, and on the ED page -- ADC/SBC HL, LD (nn),dd and back, NEG, RETN/RETI,
IM, LD A,I and LD A,R, IN r,(C), OUT (C),r, RRD, RLD, and all sixteen block
instructions.

Not implemented: interrupt mode 2's vector fetch (mode 1 is what the Master
System uses, and modes 0 and 2 currently take the mode 1 restart), and the
undocumented ED holes.
