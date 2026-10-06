"""An interrupt test for the N64's CPU: stores and the loads that read them back, while
interrupts arrive at random (sim/tb_vr4300.v IRQ1 raises IP2 every few hundred clocks and
drops it when the handler writes 0x0430_0000).

    python tools/n64/n64irqtest.py [ITERATIONS]      builds the ROM, runs the bench, checks

krom's tests run with interrupts off, so an exception taken between a store and the load
that reads it back -- the store killed, or replayed, or lost -- was never exercised. SM64
takes thousands a second; a store lost that way hung it (a function's prologue read back
the argument it had just saved, and dereferenced garbage).

The program counts the mismatches itself (s6), and the interrupts it took (s7), and writes
both to RDRAM 0x200000 with a marker; the check reads them out of the RDRAM the bench left.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..'))
from mipsasm import *  # noqa: E402,F401,F403
from n64tlbtest import N64Asm, rom  # noqa: E402
from n64fptest import FPAsm  # noqa: E402

C0_STATUS, C0_CAUSE, C0_COUNT, C0_COMPARE = 12, 13, 9, 11


def build(iterations):
    a = FPAsm(org=0x80000000)
    a.j('main'); a.nop()
    while a.pc < 0x80000180: a.nop()
    # the general vector: the timer (IP7) -- Compare again, 60..187 ticks on (writing it is the
    # acknowledge); or the bench's IP2 -- its acknowledge, a write to 0x0430_xxxx. Count them.
    a.mfc0(K0, C0_CAUSE)
    a.andi(K0, K0, 0x8000)
    a.beq(K0, ZERO, 'ip2'); a.nop()
    a.mfc0(K0, C0_COUNT)
    a.andi(K1, S7, 0x7F); a.addu(K0, K0, K1); a.addiu(K0, K0, 60)
    a.mtc0(K0, C0_COMPARE)
    a.j('irq_out'); a.nop()
    a.label('ip2')
    a.lui(K0, 0xA430)
    a.sw(ZERO, 0, K0)
    a.label('irq_out')
    a.addiu(S7, S7, 1)
    a.nop(); a.nop()
    a.eret()
    while a.pc < 0x80000400: a.nop()

    a.label('main')
    a.li(S6, 0); a.li(S7, 0)
    a.li(SP, 0x80100000)
    a.li(S1, 0x80108000)
    a.li(S4, 0x80200100)                    # where mismatches are noted
    a.li(A0, 0x13572468); a.li(A1, 0x7EADBEEF)
    a.li(A2, 0x01020305); a.li(A3, 0x00F1E2D3)
    a.li(S5, iterations)
    # the timer's first, then interrupts on: IE, IM2 (the bench's), IM7 (the timer); EXL / ERL off
    a.mfc0(T0, C0_COUNT); a.addiu(T0, T0, 100); a.mtc0(T0, C0_COMPARE)
    a.mfc0(T0, C0_STATUS)
    a.li(T1, 0xFFFFFFF9); a.and_(T0, T0, T1)
    a.ori(T0, T0, 0x8401)
    a.lui(T1, 0x2000); a.or_(T0, T0, T1)        # CU1: the FPU, for the float checks
    a.mtc0(T0, C0_STATUS)
    a.nop(); a.nop()

    n = [0]

    def check(got, want, tag):
        n[0] += 1
        ok = 'ok%d' % n[0]
        a.beq(got, want, ok); a.nop()
        a.addiu(S6, S6, 1)
        a.li(T5, tag); a.sw(T5, 0, S4); a.sw(got, 4, S4); a.sw(want, 8, S4)
        a.label(ok)

    a.label('loop')
    # 1: SM64's prologue (0x80183b20): save the argument, another register, read it back
    a.sw(A0, 48, SP); a.sw(S0, 24, SP); a.lw(T6, 48, SP); a.nop()
    check(T6, A0, 1)
    # 2: a store, and the load right behind it
    a.sw(A1, 8, SP); a.lw(T7, 8, SP)
    check(T7, A1, 2)
    # 3: a doubleword
    a.sd(A0, 16, SP); a.ld(T8, 16, SP)
    check(T8, A0, 3)
    # 4: a byte
    a.sb(A0, 3, SP); a.lbu(T9, 3, SP); a.andi(T1, A0, 0xFF)
    check(T9, T1, 4)
    # 5: two lines, stored then loaded
    a.sw(A0, 0, S1); a.sw(A1, 64, S1); a.lw(T2, 0, S1); a.lw(T3, 64, S1)
    check(T2, A0, 5)
    check(T3, A1, 6)
    # 6: a store in a branch's delay slot, the load after
    a.beq(ZERO, ZERO, 'p6'); a.sw(A0, 32, SP)
    a.label('p6')
    a.lw(T4, 32, SP)
    check(T4, A0, 7)
    # 7: the FPU, while the interrupts come: exact single-precision answers, and the loop's
    # count through a float and back (a float op takes several clocks: a wider window)
    a.li(T0, 0x40400000); a.mtc1(T0, 2)        # 3.0
    a.li(T0, 0x40A00000); a.mtc1(T0, 4)        # 5.0
    a.mul_s(6, 2, 4)                           # 15.0
    a.fop(0x03, 8, 6, 2)                       # div.s: 5.0
    a.li(T0, 0x41800000); a.mtc1(T0, 10)       # 16.0
    a.fop(0x04, 12, 10, 0)                     # sqrt.s: 4.0
    a.add_s(14, 8, 12)                         # 9.0
    a.fop(0x24, 16, 6, 0)                      # cvt.w.s 15.0 -> 15
    a.mfc1(T1, 16); a.li(T2, 15)
    check(T1, T2, 8)
    a.mfc1(T1, 14); a.li(T2, 0x41100000)
    check(T1, T2, 9)
    a.mtc1(S5, 18); a.fop(0x20, 20, 18, 0, fmt=20)   # cvt.s.w: the count as a float
    a.add_s(20, 20, 20)                        # doubled
    a.fop(0x24, 22, 20, 0)                     # and back
    a.mfc1(T1, 22); a.addu(T2, S5, S5)
    check(T1, T2, 10)
    # the values move on; round again
    a.addu(A0, A0, A2); a.addu(A1, A1, A3)
    a.addiu(S5, S5, -1)
    a.bne(S5, ZERO, 'loop'); a.nop()

    # the results: errors, interrupts, a marker
    a.li(T0, 0x80200000)
    a.sw(S6, 0, T0); a.sw(S7, 4, T0)
    a.li(T1, 0x600DF00D); a.sw(T1, 8, T0)
    a.label('done')
    a.j('done'); a.nop()
    return a.words()


def main_system(iters, out):
    """the same program on the whole N64 (sim/tb_n64_top.v): our boot, n64_top's caches and
    write buffer, the DDR3 model -- the timer's interrupts only"""
    subprocess.run([sys.executable, os.path.join(HERE, 'n64sim.py'), out, '--system'],
                   check=True, capture_output=True)
    r = subprocess.run(['bash', 'tools/sim.sh', 'tb_n64_top'], cwd=ROOT, capture_output=True, text=True)
    for l in r.stdout.splitlines():
        if 'tb_n64_top' in l and ('done' in l or 'FAIL' in l or 'TIMED' in l):
            print(l)
    lines = [int(l, 16) for l in open(os.path.join(ROOT, 'sim', 'n64', 'sys_rdram.hex'))]
    def word(a):                               # (a line's byte k at bits 8k+7:8k; the CPU's words big-endian)
        b = lines[a >> 4].to_bytes(16, 'little')
        return int.from_bytes(b[a & 15:(a & 15) + 4], 'big')
    return word(0x200000), word(0x200004), word(0x200008), word(0x200100), word(0x200104)


def main():
    iters = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    if '--system' in sys.argv:
        out = os.path.join(ROOT, 'build', 'n64irq', 'IRQTEST.N64')
        os.makedirs(os.path.dirname(out), exist_ok=True)
        open(out, 'wb').write(rom(build(iters)))
        errors, irqs, marker, tag, got = main_system(iters, out)
        if marker != 0x600DF00D:
            print('n64irqtest: FAIL - the program did not finish (marker %08x)' % marker); sys.exit(1)
        print('n64irqtest (system): %d iterations, %d interrupts taken, %d mismatches%s'
              % (iters, irqs, errors, '' if not errors else ' -- first: test %d, got %08x' % (tag, got)))
        ok = errors == 0 and irqs > 0
        print('n64irqtest: all checks passed' if ok else 'n64irqtest: FAIL')
        sys.exit(0 if ok else 1)
    out = os.path.join(ROOT, 'build', 'n64irq', 'IRQTEST.N64')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, 'wb').write(rom(build(iters)))
    # RDRAM and the boot as the model leaves them (its trace is not compared: the interrupts
    # come when the bench says)
    subprocess.run([sys.executable, os.path.join(HERE, 'n64sim.py'), out, '--steps', '2000'],
                   check=True, capture_output=True)
    r = subprocess.run(['bash', 'tools/sim.sh', 'tb_vr4300', 'STEPS%d' % (iters * 120 + 100000),
                        'FINISH1', 'WAITS1', 'IRQ1'], cwd=ROOT, capture_output=True, text=True)
    print('\n'.join(l for l in r.stdout.splitlines() if 'tb_vr4300' in l))
    words = [int(l, 16) for l in open(os.path.join(ROOT, 'sim', 'n64', 'rtl_rdram.hex'))]
    w0, w1 = words[0x200000 >> 3], words[(0x200000 >> 3) + 1]
    errors, irqs, marker = w0 >> 32, w0 & 0xFFFFFFFF, w1 >> 32
    if marker != 0x600DF00D:
        print('n64irqtest: FAIL - the program did not finish (marker %08x)' % marker)
        sys.exit(1)
    first = words[0x200100 >> 3]
    print('n64irqtest: %d iterations, %d interrupts taken, %d mismatches%s'
          % (iters, irqs, errors, '' if not errors else ' -- first: test %d, got %08x' % (first >> 32, first & 0xFFFFFFFF)))
    print('n64irqtest: all checks passed' if errors == 0 and irqs > 0 else 'n64irqtest: FAIL')
    sys.exit(0 if errors == 0 and irqs > 0 else 1)


if __name__ == '__main__':
    main()
