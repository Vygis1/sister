"""Put the freshly built PlayStation core on the board and start it.

    python tools/ps1/ps1flash.py            install, boot, load the BIOS
    python tools/ps1/ps1flash.py boot       skip the install; just boot and load

Refuses an image older than the newest source file. A build that is interrupted
leaves the PREVIOUS bitstream in build/ and tools/core.sh will happily copy that
into cores/, which publishes a stale image that looks exactly like your change
not working. That happened; this is the guard.
"""
import sys, os, time, json, glob, urllib.request

SERVER = "http://127.0.0.1:8080"
BIOS = os.environ.get("PS1_BIOS", "")         # your own BIOS dump, e.g. SCPH1001.BIN
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
IMAGE = os.path.join(ROOT, "cores", "ps1.bin")


def get(path, timeout=60):
    return json.loads(urllib.request.urlopen(SERVER + path, timeout=timeout).read())


def post(path, body=None, raw=None):
    data = raw if raw is not None else json.dumps(body or {}).encode()
    kind = "application/octet-stream" if raw is not None else "application/json"
    req = urllib.request.Request(SERVER + path, data=data, method="POST",
                                 headers={"Content-Type": kind})
    return json.loads(urllib.request.urlopen(req, timeout=300).read())


def check_fresh():
    bin_t = os.path.getmtime(IMAGE)
    newest = max((os.path.getmtime(f), f) for f in glob.glob(os.path.join(ROOT, "rtl", "*.v")))
    if newest[0] > bin_t:
        sys.exit("cores/ps1.bin is older than %s -- the build did not finish"
                 % os.path.basename(newest[1]))
    print("  image is %.0f s newer than the last source change" % (bin_t - newest[0]))


def install():
    check_fresh()
    print("install:", post("/api/shell/install", {"core": "ps1"}))
    t0 = time.time()
    while True:
        time.sleep(5)
        inst = get("/api/shell/state").get("install", {})
        if not inst.get("busy"):
            break
    print("  %.0fs %s %r" % (time.time() - t0, inst.get("stage"), inst.get("error")))
    if inst.get("error"):
        sys.exit("install failed")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] != "boot":
        install()
        time.sleep(3)
    print("boot:", post("/api/shell/boot", {"core": 1}))
    time.sleep(8)
    print("running:", get("/api/shell/state")["running"])
    if not BIOS:
        sys.exit("set PS1_BIOS to your own BIOS dump (e.g. SCPH1001.BIN)")
    print("BIOS:", post("/api/nes/load", raw=open(BIOS, "rb").read())["ok"])
