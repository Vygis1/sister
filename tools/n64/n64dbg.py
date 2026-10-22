"""The N64 core's debug window on the board (n64_top.v, "the debug window"),
read through the server's register API.

    python tools/n64/n64dbg.py [--every SECONDS]
    python tools/n64/n64dbg.py --dma N        (the RSP's last N DMAs, up to 256)
"""
import json
import sys
import time

CTRL = 0x0008_0000
NAMES = (['SP_MEM_ADDR', 'SP_DRAM_ADDR', 'SP_RD_LEN', 'SP_WR_LEN', 'SP_STATUS', 'SP_DMA_FULL', 'SP_DMA_BUSY',
          'SP_SEMAPHORE', 'SP_PC'] +
         ['DPC_START', 'DPC_END', 'DPC_CURRENT', 'DPC_STATUS', 'DPC_CLOCK', 'DPC_BUFBUSY', 'DPC_PIPEBUSY', 'DPC_TMEM'] +
         ['MI mask|intr', 'RSP starts', 'SP interrupts', 'DP interrupts', 'AI interrupts', 'VI interrupts',
          'SI DMAs', 'PI DMAs', 'CPU exceptions', '  of them interrupts', 'last exception', 'last fault',
          'RSP halted|st|pc', 'RSP instruction', 'RSP last COP0 read'])


# The board has no network: its registers are read through the ESP32, whose USB serial
# port tools/pad.py holds and passes these through (127.0.0.1:5557, "R addr" / "W addr value").
TOOLS = ('127.0.0.1', 5557)
_sock = None


def reg(a, v=None):
    global _sock
    import socket
    for attempt in range(5):
        try:
            if _sock is None:
                _sock = socket.create_connection(TOOLS, timeout=5).makefile('rwb')
            _sock.write((('R %x' % a) if v is None else ('W %x %x' % (a, v & 0xFFFFFFFF))).encode() + b'\n')
            _sock.flush()
            ans = _sock.readline().decode().strip()
            if ans in ('timeout', 'busy', ''):
                raise IOError('the ESP32 says ' + (ans or 'nothing'))
            return None if v is not None else int(ans, 16)
        except (OSError, ValueError):
            _sock = None
            if attempt == 4:
                raise
            time.sleep(0.2)


def snapshot():
    out = []
    for i, name in enumerate(NAMES):
        reg(CTRL + 0x170, i)
        out.append((name, reg(CTRL + 0x174)))
    return out


def show(snap):
    for name, v in snap:
        if name.startswith('last'):
            print('  %-20s code %2d at pc ..%06x' % (name, v >> 27, v & 0xFFFFFF))
        elif name.startswith('MI'):
            print('  %-20s mask %02x intr %02x' % (name, (v >> 6) & 63, v & 63))
        else:
            print('  %-20s %08x  %d' % (name, v, v))


def dma_log(last=256):
    """the RSP's last DMAs (n64_rsp.v dlog), oldest first, as text"""
    reg(CTRL + 0x170, 32)
    n = reg(CTRL + 0x174)
    lines = []
    for k in range(max(0, n - min(last, 256)), n):
        w = []
        for sel in (33, 34, 35):
            reg(CTRL + 0x170, ((k & 255) << 8) | sel)
            w.append(reg(CTRL + 0x174))
        halted, rd, region, dram = w[0] >> 31, (w[0] >> 30) & 1, (w[0] >> 29) & 1, w[0] & 0xFFFFFF
        pc, pbus, count = w[1] >> 20, (w[1] >> 8) & 0xFFF, w[1] & 0xFF
        skip, length = w[2] >> 20, (w[2] >> 8) & 0xFFF
        lines.append('%6d %s %s h%d %s dram %06x pbus %03x len %03x count %02x skip %03x rsp_pc %03x' % (
            k, 'rd' if rd else 'wr', 'I' if region else 'D', halted, 'CPU' if halted else 'RSP',
            dram, pbus, length, count, skip, pc))
    return n, lines


if __name__ == '__main__':
    every = float(sys.argv[sys.argv.index('--every') + 1]) if '--every' in sys.argv else 0
    if '--dma' in sys.argv:
        n, lines = dma_log(int(sys.argv[sys.argv.index('--dma') + 1]))
        print('RSP DMAs started: %d' % n)
        print(chr(10).join(lines))
        sys.exit(0)
    while True:
        print(time.strftime('%H:%M:%S'))
        show(snapshot())
        if not every:
            break
        time.sleep(every)
