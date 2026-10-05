"""An FPU test for the N64's CPU, run as SM64 runs its FPU: FCR31 = 0x01000800 (Flush
set, only Invalid enabled), so ADD/SUB/MUL.S go through rtl/vr4300.v's path where the
instruction goes on and the result comes later (fp_pend). Every result ends up in a
general register (MFC1, CFC1, or stored and loaded back), so

    python tools/n64/n64fptest.py [build/n64fp/FPTEST.N64]
    python tools/n64/n64rtltests.py --rom build/n64fp/FPTEST.N64

compares the RTL with the model instruction by instruction. It covers: integer work
beside a pending result; an FP load into another register and into the pending one;
an FP store of another register and of the pending one; a dependent FP operation;
MFC1, CFC1 and CTC1 behind a pending result; results that overflow and underflow
(Flush: no trap); a branch on a compare; FR clear (register pairs) and set; and the
same sequences in a delay slot and with a load-use in between.
"""
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))   # mipsasm
from mipsasm import *  # noqa: E402,F401,F403
from n64tlbtest import N64Asm, rom, C0_STATUS  # noqa: E402

S, D = 16, 17


class FPAsm(N64Asm):
    def lwc1(self, ft, off, base): self._i(0x31, base, ft, off)
    def swc1(self, ft, off, base): self._i(0x39, base, ft, off)
    def ldc1(self, ft, off, base): self._i(0x35, base, ft, off)
    def sdc1(self, ft, off, base): self._i(0x3D, base, ft, off)
    def mfc1(self, rt, fs): self._emit((0x11 << 26) | (0x00 << 21) | (rt << 16) | (fs << 11))
    def dmfc1(self, rt, fs): self._emit((0x11 << 26) | (0x01 << 21) | (rt << 16) | (fs << 11))
    def cfc1(self, rt, fs): self._emit((0x11 << 26) | (0x02 << 21) | (rt << 16) | (fs << 11))
    def mtc1(self, rt, fs): self._emit((0x11 << 26) | (0x04 << 21) | (rt << 16) | (fs << 11))
    def ctc1(self, rt, fs): self._emit((0x11 << 26) | (0x06 << 21) | (rt << 16) | (fs << 11))
    def fop(self, fn, fd, fs, ft, fmt=S): self._emit((0x11 << 26) | (fmt << 21) | (ft << 16) | (fs << 11) | (fd << 6) | fn)
    def add_s(self, fd, fs, ft): self.fop(0x00, fd, fs, ft)
    def sub_s(self, fd, fs, ft): self.fop(0x01, fd, fs, ft)
    def mul_s(self, fd, fs, ft): self.fop(0x02, fd, fs, ft)
    def mov_s(self, fd, fs): self.fop(0x06, fd, fs, 0)
    def c_lt_s(self, fs, ft): self.fop(0x3C, 0, fs, ft)
    def bc1t(self, name): self._branch(0x11, 8, 1, name)
    def bc1f(self, name): self._branch(0x11, 8, 0, name)


def f2u(x):
    return struct.unpack('>I', struct.pack('>f', x))[0]


def build():
    rng = random.Random(1)
    a = FPAsm(org=0x80000000)
    a.j('main'); a.nop()
    while a.pc < 0x80000400: a.nop()
    a.label('main')
    a.li(S0, 0x80010000)                                 # a scratch area (cached)
    a.li(V0, 0)                                          # a running sum of everything checked
    for fr in (1, 0):
        a.li(T0, 0x34000000 if fr else 0x30000000)       # Status: CU1 (and CU0), FR set or clear
        a.mtc0(T0, C0_STATUS); a.nop(); a.nop()
        a.li(T0, 0x01000800); a.ctc1(T0, 31)             # FCR31 as libultra sets it
        for rep in range(24):
            vals = [rng.choice([rng.uniform(-1e4, 1e4), rng.uniform(-1, 1), 1.5, -3.25, 1e30, -1e30, 1e-30, 3e-39 * 1e10])
                    for _ in range(6)]
            # the operands: through MTC1 and through LWC1
            for i, v in enumerate(vals[:3]):
                a.li(T0, f2u(v)); a.mtc1(T0, 2 * i)
            for i, v in enumerate(vals[3:]):
                a.li(T0, f2u(v)); a.sw(T0, 4 * i, S0)
            a.lwc1(6, 0, S0); a.lwc1(8, 4, S0); a.lwc1(10, 8, S0)
            op = rep % 6
            if op == 0:
                # integer work beside a pending multiply, then the result
                a.mul_s(12, 0, 2); a.addiu(T1, V0, 7); a.sll(T2, T1, 3); a.xor(T3, T2, T1); a.addu(V0, V0, T3)
                a.mfc1(T4, 12); a.addu(V0, V0, T4)
            elif op == 1:
                # an FP load into another register, then one into the pending register (it waits)
                a.add_s(14, 6, 8); a.lwc1(16, 0, S0); a.lwc1(14, 4, S0)
                a.mfc1(T4, 14); a.mfc1(T5, 16); a.addu(V0, V0, T4); a.addu(V0, V0, T5)
            elif op == 2:
                # a store of another register beside it, and of the pending one (it waits)
                a.sub_s(18, 2, 10); a.swc1(6, 16, S0); a.swc1(18, 20, S0)
                a.lw(T4, 16, S0); a.lw(T5, 20, S0); a.addu(V0, V0, T4); a.addu(V0, V0, T5)
            elif op == 3:
                # a dependent chain, then FCR31's cause and flags
                a.mul_s(20, 0, 2); a.add_s(22, 20, 4); a.mul_s(24, 22, 22)
                a.cfc1(T4, 31); a.mfc1(T5, 24); a.addu(V0, V0, T4); a.addu(V0, V0, T5)
                a.li(T0, 0x01000800); a.ctc1(T0, 31)       # (the flags cleared again)
            elif op == 4:
                # a compare and a branch on it, an operation in the delay slot
                a.c_lt_s(0, 2)
                a.bc1t('t%d_%d' % (fr, rep)); a.add_s(26, 0, 4)
                a.addiu(V0, V0, 1)
                a.label('t%d_%d' % (fr, rep))
                a.mfc1(T4, 26); a.addu(V0, V0, T4)
            else:
                # a load-use and a MOV behind a pending result
                a.mul_s(28, 6, 10); a.lw(T1, 0, S0); a.addu(T2, T1, T1); a.mov_s(30, 28)
                a.mfc1(T4, 30); a.addu(V0, V0, T4); a.addu(V0, V0, T2)
    a.cfc1(V1, 31)
    a.label('done')
    a.j('done'); a.nop()
    return a.words()


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', '..', 'build', 'n64fp', 'FPTEST.N64')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    open(out, 'wb').write(rom(build()))
    print(out)


if __name__ == '__main__':
    main()
