"""Everything that has to be true of the PlayStation core, checked on the board.

    python tools/ps1verify.py

Runs the deterministic drawing tests, then boots the real BIOS with the disc on
the ESP32's card and watches what the game actually does. Prints a line per
check and ends with a verdict, so a build can be accepted or rejected without
squinting at a picture.
"""
import json, os, subprocess, sys, time, urllib.request

SERVER = "http://127.0.0.1:8080"
ESP = "http://" + os.environ.get("ESP_HOST", "192.168.178.94")    # ESP_HOST: the ESP32 on your network
BIOS = os.environ.get("PS1_BIOS", "")                            # your own BIOS dump, e.g. SCPH1001.BIN
DISC = "/discs/crash2.bin"
fails = []

def check(ok, what, detail=""):
    print("  %s  %s%s" % ("ok  " if ok else "FAIL", what, ("   " + detail) if detail else ""))
    if not ok:
        fails.append(what)

def tex(mode):
    out = subprocess.run([sys.executable, "tools/ps1texcheck.py", mode],
                         capture_output=True, text=True, timeout=600).stdout
    return out.strip().splitlines()

def frame():
    d = urllib.request.urlopen(SERVER + "/api/vid/frame", timeout=20)
    return d.read(), int(d.headers["X-Width"]), int(d.headers["X-Height"])

def diag():
    return json.load(urllib.request.urlopen(SERVER + "/api/vid/state", timeout=10))["stream_diag"]

print("--- drawing, on deterministic test programs ---")
for build, run, what in [("build", "run", "a 15-bit texture"),
                         ("build4", "run4", "a 4-bit paletted texture"),
                         ("buildstale", "runstale", "a texture replaced in place"),
                         ("buildgrad", "rungrad", "a polygon whose first vertex is not the top of its box"),
                         ("builddma", "rundma", "a texture uploaded by DMA")]:
    tex(build)
    lines = tex(run)
    tail = " ".join(lines[-3:])
    bad = ("FAIL" in tail) or (" 0 bad" not in tail and "0 of" not in tail
                               and "0 not" not in tail and "100.0%" not in tail)
    check(not bad, what, tail[-110:])

print("--- the game, from the disc on the card ---")
if not BIOS:
    sys.exit("set PS1_BIOS to your own BIOS dump (e.g. SCPH1001.BIN)")
rom = open(BIOS, "rb").read()
urllib.request.urlopen(urllib.request.Request(
    SERVER + "/api/nes/load", data=rom,
    headers={"Content-Type": "application/octet-stream"}, method="POST"), timeout=120).read()
time.sleep(1)
urllib.request.urlopen(urllib.request.Request(
    ESP + "/api/disc?path=" + DISC, method="POST"), timeout=15).read()
print("  (BIOS loaded, disc inserted; giving it 60 s to reach the menu)")
time.sleep(60)

d0 = diag()
lit_seen = 0
moving = 0
prev = None
for i in range(20):
    data, w, h = frame()
    lit = sum(1 for k in range(0, len(data), 64) if data[k] or data[k + 1])
    lit_seen = max(lit_seen, lit)
    if prev is not None and data != prev:
        moving += 1
    prev = data
    time.sleep(0.5)
d1 = diag()

check(lit_seen > 200, "the game is drawing a picture", "%d of %d sampled pixels lit" % (lit_seen, len(data) // 64))
check(moving >= 10, "the picture is moving", "%d of 19 frames differed" % moving)
check(d1["dup_complete"] - d0["dup_complete"] == 0, "no frame was merged with another",
      "merged %d" % (d1["dup_complete"] - d0["dup_complete"]))

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pc"))  # the GPU must not be stuck
import fpgalink as fl
link = fl.Link(fl.DEFAULT_HOST, 5005, timeout=1.0, retries=4)
N = 0x0008_0000
st = [link.read(N + 0x50) for _ in range(6)]
stuck = all(x == st[0] for x in st) and ((st[0] >> 30) & 1)
check(not stuck, "the drawing engine is not stuck", "gpu state %08x" % st[0])

print()
print("ALL CHECKS PASSED" if not fails else "%d FAILED: %s" % (len(fails), "; ".join(fails)))
sys.exit(1 if fails else 0)
