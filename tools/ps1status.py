"""A window that just sits there and tells you what the board and the build are doing.

    pythonw tools/ps1status.py          (or: python tools/ps1status.py)

Polls three things on its own timers and never blocks the window on any of them:

  the build   the phase Vivado is in, how long it has been going, and the last
              timing result -- the number that decides whether an image is safe
              to put on the board
  the board   whether it answers at all, where the processor is, how fast it is
              going, and how hard the memory is being pushed
  the picture what the web page is being served, and how often

Every read is wrapped: a board that has stopped answering shows as stopped
rather than freezing the window, which matters because "stopped answering" is
the interesting state.
"""
import os, re, sys, time, json, threading, subprocess
import tkinter as tk
import urllib.request

sys.path.insert(0, r"C:/fpga/pc")
try:
    import fpgalink as fl
except Exception:
    fl = None

LOG    = r"C:/fpga/build/core_ps1.log"
BOARD  = "192.168.178.50"
SERVER = "http://127.0.0.1:8080"
N      = 0x0008_0000

BG, FG, DIM, OK, BAD, WARN = "#11131a", "#e6e9f0", "#7b8194", "#6ee7a8", "#ff7a7a", "#ffd166"


class Status:
    def __init__(self, root):
        self.root = root
        root.title("PlayStation core - status")
        root.configure(bg=BG)
        root.geometry("760x420")

        self.rows = {}
        def section(title):
            tk.Label(root, text=title, bg=BG, fg=DIM, font=("Consolas", 9, "bold"),
                     anchor="w").pack(fill="x", padx=14, pady=(12, 2))
        def row(key, label):
            f = tk.Frame(root, bg=BG); f.pack(fill="x", padx=14)
            tk.Label(f, text=label, bg=BG, fg=DIM, font=("Consolas", 10),
                     width=26, anchor="w").pack(side="left")
            v = tk.Label(f, text="-", bg=BG, fg=FG, font=("Consolas", 10), anchor="w")
            v.pack(side="left", fill="x", expand=True)
            self.rows[key] = v

        section("BUILD")
        row("build_state", "state")
        row("build_phase", "phase")
        row("build_timing", "last timing result")

        section("BOARD")
        row("board_link", "link")
        row("board_pc", "processor at")
        row("board_mips", "speed")
        row("board_mem", "memory")
        row("board_gpu", "drawing engine")

        section("PICTURE")
        row("pic_size", "served to the page")
        row("pic_fps", "frames a second")

        self.note = tk.Label(root, text="", bg=BG, fg=DIM, font=("Consolas", 9),
                             anchor="w", justify="left", wraplength=720)
        self.note.pack(fill="x", padx=14, pady=(14, 8))

        self.link = None
        self.prev = None
        self.fps_n = 0
        self.fps_t = time.time()

        threading.Thread(target=self.board_loop, daemon=True).start()
        threading.Thread(target=self.pic_loop, daemon=True).start()
        self.build_tick()

    def set(self, key, text, colour=FG):
        self.rows[key].config(text=text, fg=colour)

    # --- the build ---------------------------------------------------------
    def build_tick(self):
        try:
            # CREATE_NO_WINDOW, or Windows flashes a console window every
            # time this runs -- which at one poll every two seconds is a
            # terminal popping up in your face all day.
            running = "vivado.exe" in subprocess.run(
                ["tasklist", "/FI", "IMAGENAME eq vivado.exe"],
                capture_output=True, text=True, timeout=4,
                creationflags=0x08000000).stdout
            phase, started, timing = "-", None, "-"
            if os.path.exists(LOG):
                with open(LOG, "r", errors="ignore") as f:
                    for line in f:
                        if line.startswith("Phase ") or line.startswith("Start "):
                            phase = line.strip()[:70]
                        elif "Start of session at:" in line:
                            started = line.split("at:")[1].strip()
                        elif line.startswith(" TIMING:"):
                            timing = line.strip()
            if running:
                el = ""
                if started:
                    try:
                        t = time.mktime(time.strptime(started, "%a %b %d %H:%M:%S %Y"))
                        el = "  (%d min %02d s)" % divmod(int(time.time() - t), 60)
                    except Exception:
                        pass
                self.set("build_state", "running" + el, WARN)
            else:
                self.set("build_state", "idle", DIM)
            self.set("build_phase", phase, FG if running else DIM)
            good = "passes" in timing
            self.set("build_timing", timing, OK if good else (BAD if "FAIL" in timing else DIM))
        except Exception as e:
            self.set("build_state", "cannot tell: %s" % type(e).__name__, BAD)
        self.root.after(4000, self.build_tick)

    # --- the board ---------------------------------------------------------
    def board_loop(self):
        while True:
            try:
                if fl is None:
                    raise RuntimeError("fpgalink not importable")
                if self.link is None:
                    self.link = fl.Link(BOARD, 5005, timeout=0.4, retries=2)
                cur = []
                for i in range(16):
                    self.link.write(N + 0xEC, i)
                    cur.append(self.link.read(N + 0xEC))
                pc = self.link.read(N + 0x14)
                now = time.time()
                self.set("board_link", "answering", OK)
                self.set("board_pc", "%08x" % pc)
                if self.prev:
                    dt = now - self.prev[1]
                    d = [(y - x) & 0xFFFFFFFF for x, y in zip(self.prev[0], cur)]
                    clk = d[0] or 1
                    self.set("board_mips", "%.1f MIPS   %.2f clocks per instruction   (console: 33.9)"
                             % (d[3] / dt / 1e6, clk / float(d[3] or 1)))
                    self.set("board_mem", "{:,} accesses a second   (was capped near 1,000,000)"
                             .format(int(d[1] / dt)))
                    self.set("board_gpu", "busy %.0f%% of the time" % (100.0 * d[7] / clk),
                             BAD if d[7] > 0.98 * clk else FG)
                self.prev = (cur, now)
            except Exception as e:
                self.link = None
                self.prev = None
                self.set("board_link", "not answering (%s)" % type(e).__name__, BAD)
                self.set("board_mips", "-", DIM)
                self.set("board_mem", "-", DIM)
                self.set("board_gpu", "-", DIM)
            time.sleep(2.0)

    # --- the picture -------------------------------------------------------
    def pic_loop(self):
        while True:
            try:
                r = urllib.request.urlopen(SERVER + "/api/vid/frame", timeout=8)
                b = r.read()
                w = r.headers.get("X-Width", "?"); h = r.headers.get("X-Height", "?")
                lit = sum(1 for k in range(0, len(b), 2) if b[k:k+2] != b"\x00\x00")
                self.set("pic_size", "%sx%s   %.0f%% of it lit" % (w, h, 100.0 * lit / (len(b) // 2 or 1)))
                self.fps_n += 1
                if time.time() - self.fps_t > 3.0:
                    self.set("pic_fps", "%.1f" % (self.fps_n / (time.time() - self.fps_t)))
                    self.fps_n = 0; self.fps_t = time.time()
            except Exception as e:
                self.set("pic_size", "no picture (%s)" % type(e).__name__, BAD)
                self.set("pic_fps", "-", DIM)
                time.sleep(2.0)


if __name__ == "__main__":
    root = tk.Tk()
    s = Status(root)
    s.note.config(text="Reads the build log, the board's own counters and the web page. "
                       "Nothing here changes anything -- it only looks.")
    root.mainloop()
