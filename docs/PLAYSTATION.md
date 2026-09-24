# PlayStation

Where this stands, what the target is, and the order the rest happens in. Each
step is testable on its own, and none of them waits on a later one.

## The target

**The BIOS menu on the dashboard.** Power on with no disc and a PlayStation
shows the Sony logo, the PlayStation logo turning in 3D, and then a menu for
the memory cards and the CD player. Getting there needs the CPU, the GTE (the
logo is 3D), the GPU (Gouraud polygons, textured rectangles for the font,
fills and copies), the DMA controller, the interrupt controller and the root
counters. It does not need the SPU or the CD drive: the menu appears without
either.

That is the milestone because it is the smallest thing that is visibly a
PlayStation, and because everything a game then needs sits on top of it.

## What is needed from outside

**A BIOS image.** SCPH-1001 or any of its siblings, 512 kB. There is no
PlayStation without it -- the logo screen *is* the BIOS -- and there is not
one on this machine. Until there is, every part below is built against its own
test program, the way the other three CPUs were; the BIOS boot is the
integration test that runs the moment the file exists.

**Crash Bandicoot** is in `Downloads/Crash Bandicoot (USA)/`, a clean
MODE2/2352 image: 268,743 sectors, valid sync, ISO descriptor at sector 16.
It is the game for after the menu.

## Done

### The CPU -- `rtl/r3000.v`

A MIPS I R3000A as the console has it: no TLB, no FPU, the segment bits
stripped to make a physical address, SR.IsC honoured by dropping stores. Every
integer instruction, the unaligned four, multiply and divide into HI/LO with
the chip's own divide-by-zero answers, COP0 with SR/CAUSE/EPC/BadVaddr/PRID,
exceptions with the right code and EPC and BD, RFE, six interrupt lines.

Both delay slots are what the architecture says they are. A load's destination
is not visible to the next instruction, which reads the old value; the sweep
has a case for it, and it was the one case that failed on the first run,
because the first version wrote the register one fetch too early. A CPU that
interlocks loads runs PlayStation code wrongly in ways that take a long time to
find, because the code was written for the one that does not.

Verified by `tools/mipstest.py` against `tools/mipsasm.py`: a Python model of
the instruction set generates a 28,159-word program that computes every case
twice and stops at the first disagreement. **2,251 checks**, `sim/tb_r3000.v`:
the ALU on the flag boundaries, both immediate extensions, shifts by immediate
and by register, MULT/MULTU/DIV/DIVU including the overflow and divide-by-zero
results, every load and store width, LWL/LWR/SWL/SWR at every alignment, the
load delay slot, every branch taken and not with the slot proven executed,
JAL/JALR/BGEZAL link values, overflow/SYSCALL/BREAK/address-error exceptions
with EPC and BD, and an external interrupt.

Multi-cycle rather than pipelined: three or four enables per instruction, with
the bus answering two enables after the address like everything else here. Not
fast. Fast is a replacement for later, and the sweep says whether the
replacement is right.

## First light

The R3000, the GPU, the VRAM cache and the register fabric run together
(`rtl/ps1_top.v`, `sim/tb_ps1.v`): the CPU executes tools/ps1demo.py's program
out of a boot ROM, writes GPU commands itself, and draws a boot screen -- a
Gouraud-shaded diamond and a menu bar, rendered to VRAM in DDR3 and scanned out
320x240. `docs/ps1_boot.png` is that frame, straight off the simulated display.

Three bugs found getting there, each by a measurement:

* The GPU's command FIFO pop was registered, so `f_rd` advanced a cycle late
  and every multi-word command read its own header as its first argument.
  Combinational now.
* The CPU bus had two pipeline registers where the CPU allows one wait cycle,
  so it read the previous fetch -- every branch's delay slot ran against the
  wrong instruction and the program wandered off its own end. One register now.
* The boot program polled "GPU fully idle" before every command WORD, but a
  multi-word command makes the GPU busy after word one, so the CPU would not
  send word two and the engine waited forever. It polls once per command and
  pushes the whole command -- header and arguments -- into the sixteen-deep
  FIFO at once.

## Next, in order

1. **The GTE.** COP2: RTPS/RTPT, NCLIP, AVSZ, MVMVA, NCDS and the rest of the
   ~30 ops, 16-bit fixed point with the flag register. Same method: a Python
   model and a generated sweep.
2. **The machine.** `rtl/ps1_top.v`: the CPU behind an instruction cache and a
   line buffer into DDR3 through `mem_arb`, 2 MB RAM and the BIOS in DDR3, the
   1 kB scratchpad in block RAM, the interrupt controller at $1F801070, the
   three root counters at $1F801100, the DMA controller at $1F801080, stubs
   at the SPU, CD and joypad addresses so the BIOS's probes get answers.
3. **The GPU.** VRAM in DDR3 -- 1 MB, 1024x512x16 -- through the arbiter.
   GP0: fills, CPU-to-VRAM, VRAM-to-VRAM, flat and Gouraud triangles and
   quads, textured rectangles with the CLUT. GP1: display area and enable.
   The display scans the active area into the 320-wide framebuffer.
4. **The BIOS boot**, which is 1-3 running the real thing. Then the disc.

## Resources

The Mega Drive core sits at 18.5k LUTs and 81.5 block RAM tiles with its
cartridge in DDR3. A PlayStation is its own image and gets the whole chip:
63,400 LUTs, 135 tiles, 256 MB. The GPU is where the LUTs go.

## Status 2026-09-18: the BIOS boots and runs on hardware

Five bugs fixed, all verified in sim and on the A100T, no regressions:

* **CPU cache stall** (`ps1_top.v`) — the `served` flag leaked a registered cache
  ack from one access onto the next, corrupting stores and branch delay slots.
  Pinned to one presentation. `tb_ps1_bios` PASSES.
* **DMA request pulse** (`ps1_dma.v`) — `r_req` was one cycle; the shared cache
  only takes a port-B request while idle, so it was missed and the DMA hung.
  Held until `r_ack` in every wait state.
* **GPU VRAM request pulse** (`ps1_gpu.v`) — `v_req` cleared unconditionally each
  cycle; the draw engine hung mid-polygon. Default changed to clear on `v_ack`.
* **Arbiter re-issue** (`mem_arb.v`) — held `m_req` as a level; a MIG (and the sim
  model) re-accepts a held command every ready cycle, flooding the read queue with
  duplicates so real data never routed back. Rewrote to one command per pulse.
  Only bites with >1 concurrent client (MD used one port). Regression tests pass.
* **IRQ source mapping** (`ps1_top.v`) — DMA/timer/GPU interrupt lines were on the
  wrong bits; the BIOS's boot handlers never saw them. Corrected to 0 VBLANK,
  1 GPU, 2 CDROM, 3 DMA, 4/5/6 TMR.

On hardware the BIOS clears RAM, relocates and runs its kernel, VSync fires (~78 Hz),
interrupts are serviced, the GPU actively draws 300+ commands, and the display
enables. The screen shows the BIOS's rendered background.

**Next: the GTE (COP2).** The visible frame is the background; the PlayStation logo
does not appear because its 3D vertices come from the GTE, still a stub. Getting the
logo and then the memory-card/CD menu on screen is the GTE step (docs above), built
the same way the CPUs were: a Python model and a generated self-checking sweep.
Debug registers for continued work are exposed via console_top ctrl reads 0x38-0x50.
