"""While the board's RSP is frozen (n64_rsp.v DEBUG_FREEZE), its DMEM and IMEM
through the debug window (tools/n64dbg.py), to build/n64_frozen_{dmem,imem}.bin.

    python tools/n64dmem.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import n64dbg


def read_dw(i):
    n64dbg.reg(n64dbg.CTRL + 0x170, (i << 16) | 36)
    n64dbg.reg(n64dbg.CTRL + 0x174)                 # (the read is issued over the next few clocks)
    hi = n64dbg.reg(n64dbg.CTRL + 0x174)
    n64dbg.reg(n64dbg.CTRL + 0x170, (i << 16) | 37)
    lo = n64dbg.reg(n64dbg.CTRL + 0x174)
    return (hi << 32) | lo


if __name__ == '__main__':
    n64dbg.reg(n64dbg.CTRL + 0x170, 38)
    if not n64dbg.reg(n64dbg.CTRL + 0x174):
        sys.exit('the RSP is not frozen')
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'build')
    for name, base in (('dmem', 0), ('imem', 512)):
        data = b''.join(read_dw(base + i).to_bytes(8, 'big') for i in range(512))
        open(os.path.join(out, 'n64_frozen_%s.bin' % name), 'wb').write(data)
        print(name, 'read')
