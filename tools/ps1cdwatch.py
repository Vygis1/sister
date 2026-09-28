"""Reboot the console and watch a disc boot: the drive's commands as they
happen (decoded), where the CPU is, and whether it fell into the BIOS's
unresolved-exception loop.
    python tools/ps1cdwatch.py [original|fast] [seconds]
"""
import sys, time, collections
sys.path.insert(0, "pc")
import fpgalink as fl
N = 0x0008_0000
NAMES = {0x01:"GetStat",0x02:"Setloc",0x06:"ReadN",0x07:"MotorOn",0x08:"Stop",0x09:"Pause",0x0a:"Init",0x0b:"Mute",0x0c:"Demute",
         0x0d:"Setfilter",0x0e:"Setmode",0x0f:"Getparam",0x10:"GetlocL",0x11:"GetlocP",0x13:"GetTN",0x14:"GetTD",0x15:"SeekL",
         0x16:"SeekP",0x19:"Test",0x1a:"GetID",0x1b:"ReadS",0x1e:"ReadTOC",0xd3:"DMA3"}
A40 = {0x5c4,0x5c8,0x5cc,0x5d0,0x5d4,0x5d8,0x5dc,0xa0,0xa4,0xa8,0xac,0xbfc0d8e0,0xbfc0d8e4,0xbfc0d8e8}
def bcd(x): return (x >> 4) * 10 + (x & 15)
def entry(e):
    c = e >> 24; p = [(e >> 16) & 255, (e >> 8) & 255, e & 255]
    s = "%-8s %02x %02x %02x" % (NAMES.get(c, "%02x" % c), p[0], p[1], p[2])
    if c == 0x02: s += "  -> LBA %d" % (bcd(p[0]) * 4500 + bcd(p[1]) * 75 + bcd(p[2]) - 150)
    if c == 0xd3: s = "DMA3 start  chcr[27:24]=%x bcr=%05x" % (p[0] & 15, e & 0xFFFFF)
    if c == 0xd4: s = "DMA3 done   dry bytes=%d words so far=%d" % (p[0], e & 0xFFFF)
    if c == 0xb0: s = "HCHPCTL=%02x  ld_cnt=%d bfrd=%d fifo_has=%d load=%d r_cnt=%d" % (p[0], p[1] >> 4, (p[1] >> 3) & 1, (p[1] >> 2) & 1, (p[1] >> 1) & 1, p[2] >> 4)
    if c == 0x11: s = "INT1        sector at LBA %d" % (e & 0xFFFFFF)
    if c == 0x5b: s = "frame taken: header says LBA %d" % (e & 0xFFFFFF)
    if c == 0x5e: s = "FRAME REFUSED: header says LBA %d (not the one wanted)" % (e & 0xFFFFFF)
    return s
def main():
    pace = {"original": 0x1000, "fast": 0x2000, "cpu-fast": 0, "gpu-fast": 0x3000}[sys.argv[1] if len(sys.argv) > 1 else "cpu-fast"]   # see ps1pace.py
    secs = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    link = fl.Link("192.168.178.50", 5005, timeout=1.0, retries=4)
    ctrl = link.read(N + 4)
    link.write(N + 4, ctrl & ~1); time.sleep(0.05); link.write(N + 4, ctrl | 1); link.write(N + 0xEC, pace)
    t0 = time.time(); seen = 0; cls_last = None
    while time.time() - t0 < secs:
        wp = link.read(N + 0x110) & 0x3F
        n = (wp - seen) & 0x3F
        for i in range(n):
            link.write(N + 0x110, (seen + i) & 0x3F)
            print("%6.1fs  %2d: %s" % (time.time() - t0, (seen + i) & 0x3F, entry(link.read(N + 0x114))))
        seen = wp
        pcs = [link.read(N + 0x14) for _ in range(8)]
        cls = "A40h loop (unresolved exception)" if sum(p in A40 for p in pcs) >= 6 else "running"
        if cls != cls_last:
            print("%6.1fs  cpu: %s  pc %08x" % (time.time() - t0, cls, pcs[0])); cls_last = cls
        time.sleep(0.3)
    print("done: dma words %d, drive 0xAC %08x" % (link.read(N + 0x110) >> 16, link.read(N + 0xAC)))
if __name__ == "__main__":
    main()
