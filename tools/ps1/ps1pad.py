"""Press controller buttons on the running console from the command line.
    python tools/ps1/ps1pad.py start            tap Start (250 ms)
    python tools/ps1/ps1pad.py a 1000           hold Cross for a second
    python tools/ps1/ps1pad.py down,a           two buttons together
Names: a (Cross) b (Circle) select start up down left right. Goes through the
web server's /api/nes/input, so the page's mapping applies.
"""
import sys, time, json, urllib.request
SERVER = "http://127.0.0.1:8080"
BITS = {"a": 0, "b": 1, "select": 2, "start": 3, "up": 4, "down": 5, "left": 6, "right": 7}
def send(v):
    req = urllib.request.Request(SERVER + "/api/nes/input", data=json.dumps({"joy1": v}).encode(), headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=5).read()
def main():
    names = sys.argv[1].split(","); hold = int(sys.argv[2]) / 1000 if len(sys.argv) > 2 else 0.25
    v = 0
    for n in names: v |= 1 << BITS[n]
    send(v); time.sleep(hold); send(0)
    print("pressed %s for %.2f s" % ("+".join(names), hold))
if __name__ == "__main__":
    main()
