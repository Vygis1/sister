"""The N64 core's debug window on the board (n64_top.v, "the debug window"),
read through the server's register API.

    python tools/n64dbg.py [--every SECONDS]
"""
import json
import sys
import time
import urllib.request

SERVER = 'http://localhost:8080'
CTRL = 0x0008_0000
NAMES = (['SP_MEM_ADDR', 'SP_DRAM_ADDR', 'SP_RD_LEN', 'SP_WR_LEN', 'SP_STATUS', 'SP_DMA_FULL', 'SP_DMA_BUSY',
          'SP_SEMAPHORE', 'SP_PC'] +
         ['DPC_START', 'DPC_END', 'DPC_CURRENT', 'DPC_STATUS', 'DPC_CLOCK', 'DPC_BUFBUSY', 'DPC_PIPEBUSY', 'DPC_TMEM'] +
         ['MI mask|intr', 'RSP starts', 'SP interrupts', 'DP interrupts', 'AI interrupts', 'VI interrupts',
          'SI DMAs', 'PI DMAs', 'CPU exceptions', '  of them interrupts', 'last exception', 'last fault'])


def reg(a, v=None):
    url = '%s/api/reg/0x%x' % (SERVER, a)
    if v is None:
        return json.load(urllib.request.urlopen(url, timeout=10))['value']
    req = urllib.request.Request(url, data=json.dumps({'value': v}).encode(),
                                 headers={'Content-Type': 'application/json'}, method='POST')
    urllib.request.urlopen(req, timeout=10).read()


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


if __name__ == '__main__':
    every = float(sys.argv[sys.argv.index('--every') + 1]) if '--every' in sys.argv else 0
    while True:
        print(time.strftime('%H:%M:%S'))
        show(snapshot())
        if not every:
            break
        time.sleep(every)
