# The Z80, and the mistake worth not repeating

Developer notes on `rtl/z80.v` (with `z80_decode.vh` and `z80_resume.vh`). It is the CPU of the
Master System and Game Gear, and the Mega Drive's sound CPU.

It passes both exercisers on the board, by CRC:

    zexdoc   67 / 67    every documented instruction
    zexall   67 / 67    the same, plus the undocumented X and Y flag bits

and `prelim.com` and `sim/tb_z80_unit.v`.

ZEXALL is the one that matters for the flags. Nothing is supposed to depend on bits 3 and 5 of
F, plenty of software does, and it is the only test that notices when `CP` takes them from the
operand instead of the result, or when `BIT`'s memory forms take them from the address.

A first attempt is kept in `rtl/wip/` because the mistake it made is the useful part of this
note. The second attempt was built from what follows.

## What went wrong in the first attempt

The sequencer gathers operands in shared states -- fetch an immediate, read memory, pop a word
-- and each of them returns to a state held in `ret_st`. Every multi-cycle instruction set
`ret_st <= S_EXEC`, meaning "come back to me when you have it".

But `S_EXEC` is the decode. Arriving there re-reads `op` and starts the instruction over, which
gathers the operand again, which returns to `S_EXEC`. The CPU could not execute a single
multi-cycle instruction.

The sign was there while writing it: the decode set flags with names like `ldst`, `alust`,
`incst` that nothing ever read. They were reaching for a continuation that was never designed. A
register that is only ever written is a design that has not been finished.

## The shape that works

Split "decode" from "resume". One continuation code, set by the decode, checked at the top of
the execute state:

    S_EXEC:
        if (cont != C_NONE) <resume: dispatch on cont>
        else                <decode: dispatch on op>

An instruction like `ADD A,(HL)` then reads:

    decode:  wz <= HL; cont <= C_ALU; ret_st <= S_EXEC; st <= S_MRD;
    resume:  C_ALU: do_alu(alukind, A, tmp); A <= alu_r; F <= alu_f;
                    cont <= C_NONE;

`cont` must be cleared on every path that finishes an instruction, for the same reason `pfx`,
`cb` and `ed` are: the next instruction has to start clean.

Instructions that need two gathering steps -- `LD (IX+d),n` fetches a displacement and then an
immediate -- need two continuation codes, not one flag. That is the case to design against,
because a single flag cannot express it.

The 68000 (`rtl/m68k.v`) uses the same structure.

## Decisions worth keeping

- **Registers in an array indexed by the Z80's own 3-bit code**, so `LD r,r'` is two array
  accesses. Slot 6, where `(HL)` would be, is scratch.
- **Prefix redirection takes a `plain` argument.** Under DD/FD, codes 4 and 5 become the halves
  of IX/IY -- but not when the operand is the other side of `LD r,(IX+d)`. Passing that decision
  in at each call site keeps the exception visible instead of buried.
- **Flags carry X and Y.** They are undocumented copies of result bits 3 and 5, nothing is
  supposed to read them, and ZEXALL checks them. `CP` takes them from the *operand*.
- **The prefix state clears at the top of the decode**, so a prefix opcode re-asserts it and
  falls through to the next fetch.

## Two things that only showed up once it ran

**Memory latency is two cycles, not one.** An address assigned with `<=` is not on the bus
until the end of that cycle, so the memory latches it at the end of the next one and the data is
readable in the one after. The word-sized transfers had the gap by accident -- they present a
second address in between -- so only the byte-sized reads were wrong, and the symptom was a CPU
that fetched one opcode and then stopped.

**The prefix has to be cleared when an instruction finishes, not when the next one starts
decoding.** A multi-cycle prefixed instruction keeps its prefix alive across the continuation
and finishes in the resume branch, which never ran a clear placed in the decode. So
`RLC (IX+4)` worked and the instruction after it was decoded as a CB opcode. `tb_z80_unit`
catches this by following a DDCB with an ordinary instruction; testing the DDCB alone would
pass.

## Tests

The exercisers are CP/M `.COM` files in `sim/roms/z80/`:

1. `prelim.com` -- a preliminary check, small enough to debug against.
2. `zexdoc.com` -- every documented instruction, by CRC.
3. `zexall.com` -- the same, with the undocumented flag bits.

A CP/M program expects to be entered at `$0100` with a stack, a BDOS entry at `$0005`, and
somewhere to go when it finishes. `tools/sms/z80shim.py` provides those as a few bytes of Z80
code in low memory: a bootstrap that sets the stack and enters at `$0100` once, a BDOS handler
(function 0 exits, 2 prints E, 9 prints the `$`-terminated string at DE) that sends characters
to an I/O port, and a stop for a finished program. `tools/sms/z80rom.py` turns a `.COM` file
into hex for the benches.

- `sim/tb_z80_unit.v` -- directed checks: flags (including X, Y and `CP`'s rule), INC/DEC,
  16-bit adds, the stack, CALL/RET, JR/DJNZ, the CB page, `(HL)`, `(IX+d)`, DDCB, the exchanges
  and DAA. It runs in seconds and is the inner loop.
- `sim/tb_z80.v` -- runs a `.COM` file through the shim. `prelim.com` passes in simulation.
- ZEXDOC and ZEXALL run on the board, not in a simulator: xsim runs this core at about 1.4
  million cycles a second, and ZEXDOC had not finished its first of 67 tests after 1.4 billion.
  The board does the whole run in minutes.

For the board runs, the Master System image (not a `RELEASE=1` build) keeps a bare-Z80 mode:
bit 8 of the console's CONSOLE register replaces the Master System with the Z80 alone, using
the cartridge's program memory as its 64 kB of RAM (`rtl/console_top.v`, "slot 1"). There is
currently no PC tool in the tree that loads a `.COM` file into it.

## Instruction coverage

Implemented: the whole main page, the whole CB page, DD/FD including DDCB and FDCB, and on the
ED page ADC/SBC HL, LD (nn),dd and back, NEG, RETN/RETI, IM, LD A,I and LD A,R, IN r,(C),
OUT (C),r, RRD, RLD, and all sixteen block instructions.

Not implemented: interrupt mode 2's vector fetch (mode 1 is what the Master System uses; modes 0
and 2 take the mode 1 restart), and the undocumented ED holes.
