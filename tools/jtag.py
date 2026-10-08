"""jtag.py - the console's register bus over the JTAG cable (a debug build: core.sh JTAG=1, the
jtag_axi core + rtl/jtag_bus.v). One Vivado session is kept open and driven over a pipe, so a read
costs a transaction, not a Vivado start.

    from jtag import Jtag
    j = Jtag()                      # opens the hardware manager, finds the JTAG-AXI master
    j.read(0x80014)                 # one word
    j.read_block(0x100000, 4096)    # many, in bursts of 256
    j.write(0x80004, 1)
    j.close()

    python tools/jtag.py R 80014            one word, hex
    python tools/jtag.py W 80004 1          write
    python tools/jtag.py D 100000 64        a block
"""
import os
import subprocess
import sys
import glob

MARK = '@@JTAG@@'


def vivado_exe():
    for pat in (r'C:\AMDDesignTools\*\Vivado\bin\vivado.bat', r'C:\Xilinx\Vivado\*\bin\vivado.bat'):
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[-1]
    raise SystemExit('no Vivado found')


class Jtag:
    def __init__(self, verbose=False):
        self.v = verbose
        self.p = subprocess.Popen([vivado_exe(), '-mode', 'tcl', '-nojournal', '-nolog'],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  text=True, bufsize=1)
        out = self.tcl('open_hw_manager; connect_hw_server -allow_non_jtag; open_hw_target; '
                       'current_hw_device [lindex [get_hw_devices xc7a100t*] 0]; '
                       'refresh_hw_device [current_hw_device]; puts "axis=[get_hw_axis]"')
        axis = [l for l in out.splitlines() if l.startswith('axis=')]
        if not axis or axis[-1] == 'axis=':
            raise SystemExit('no JTAG-AXI master in the FPGA (is a JTAG=1 debug build loaded?)\n' + out[-2000:])
        self.axi = axis[-1][5:].split()[0]
        self.tcl('set A [get_hw_axis %s]' % self.axi)

    def tcl(self, cmd):
        self.p.stdin.write(cmd + '\nputs "%s"\n' % MARK)
        self.p.stdin.flush()
        lines = []
        while True:
            l = self.p.stdout.readline()
            if not l:
                raise SystemExit('Vivado went away:\n' + ''.join(lines[-30:]))
            if l.strip() == MARK:
                break
            lines.append(l)
            if self.v:
                sys.stdout.write(l)
        return ''.join(lines)

    def _words(self, out, n):
        # DATA is one hex string, the LAST beat first
        val = [l for l in out.splitlines() if l.startswith('data=')][-1][5:].strip()
        val = val.rjust(8 * n, '0')
        beats = [int(val[8 * i:8 * i + 8], 16) for i in range(n)]
        return beats[::-1]

    def read_block(self, addr, n):
        words = []
        while n > 0:
            k = min(n, 256)
            out = self.tcl('create_hw_axi_txn -force rd $A -type read -address %08x -len %d; '
                           'run_hw_axi -quiet [get_hw_axi_txns rd]; '
                           'puts "data=[get_property DATA [get_hw_axi_txns rd]]"' % (addr, k))
            words += self._words(out, k)
            addr += 4 * k; n -= k
        return words

    def read(self, addr):
        return self.read_block(addr, 1)[0]

    def write_block(self, addr, words):
        while words:
            k = min(len(words), 256)
            data = ''.join('%08x' % w for w in reversed(words[:k]))
            self.tcl('create_hw_axi_txn -force wr $A -type write -address %08x -len %d -data %s; '
                     'run_hw_axi -quiet [get_hw_axi_txns wr]' % (addr, k, data))
            addr += 4 * k; words = words[k:]

    def write(self, addr, value):
        self.write_block(addr, [value])

    def close(self):
        try:
            self.p.stdin.write('exit\n'); self.p.stdin.flush(); self.p.wait(timeout=30)
        except Exception:
            self.p.kill()


def main():
    j = Jtag()
    op = sys.argv[1].upper()
    if op == 'R':
        print('%08x' % j.read(int(sys.argv[2], 16)))
    elif op == 'W':
        j.write(int(sys.argv[2], 16), int(sys.argv[3], 16))
    elif op == 'D':
        a, n = int(sys.argv[2], 16), int(sys.argv[3], 16) if len(sys.argv) > 3 else 16
        w = j.read_block(a, n)
        for i in range(0, len(w), 8):
            print('%08x: %s' % (a + 4 * i, ' '.join('%08x' % x for x in w[i:i + 8])))
    j.close()


if __name__ == '__main__':
    main()
