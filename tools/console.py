"""A window that runs one command and shows its output as it happens.

    pythonw tools/console.py "build the PS1 core" -- ./tools/core.sh ps1
    pythonw tools/console.py "flash" -- python tools/ps1flash.py

Everything long -- a build, a simulation run, a flash -- goes in one of these
instead of into a terminal that has already scrolled away. The window shows the
command, how long it has been going, the last lines of output, and what it
exited with, and it stays open afterwards so the result can actually be read.

Three things it does deliberately:

  no console flash   the child is started with CREATE_NO_WINDOW. Without it
                     Windows gives every child its own console window, which
                     pops up in front of whatever you are doing.
  it keeps a log     everything also goes to build/console/<slug>.log, so the
                     output survives the window being closed.
  it does not block  output is read on a thread and handed to the window
                     through a queue; a child that stops talking leaves the
                     window responsive rather than frozen.

--follow <file> shows a file being appended to instead of running anything.
--also <file> runs the command AND tails that file into the same window, which
is what core.sh and sim.sh need: they say almost nothing on stdout and put the
part worth watching in a log.

A window whose command succeeded closes itself after a few seconds. One whose
command failed stays open, because that is the one there is something to read
in.
"""
import os, re, sys, time, queue, threading, subprocess
import tkinter as tk
from tkinter import font as tkfont

BG, FG, DIM, OK, BAD, WARN = "#11131a", "#e6e9f0", "#7b8194", "#6ee7a8", "#ff7a7a", "#ffd166"
MAXLINES = 4000
LOGDIR = r"C:/fpga/build/console"

# Lines worth colouring. The build talks a lot; these are the parts that decide
# whether it worked.
RULES = [
    (re.compile(r"\bERROR\b|\bFAIL|\*\*\* .* FAILED|Traceback|CRITICAL WARNING", re.I), BAD),
    (re.compile(r"TIMING: FAILS|timing.*not met", re.I), BAD),
    (re.compile(r"TIMING: passes|all checks passed|=== .* passed ===|\bdone\b|Routing Is Done", re.I), OK),
    (re.compile(r"^(Phase|Start|Finished) |^INFO|WARNING", re.I), DIM),
]


class Console:
    def __init__(self, root, title, cmd, follow=None, also=None):
        self.root, self.cmd, self.follow, self.also = root, cmd, follow, also
        self.t0 = time.time()
        self.q = queue.Queue()
        self.proc = None
        self.done = None
        self.closing = 0

        root.title(title)
        root.configure(bg=BG)
        root.geometry("1000x600")

        head = tk.Frame(root, bg=BG); head.pack(fill="x", padx=12, pady=(10, 4))
        self.state = tk.Label(head, text="starting", bg=BG, fg=WARN,
                              font=("Consolas", 11, "bold"), anchor="w")
        self.state.pack(side="left")
        self.clock = tk.Label(head, text="", bg=BG, fg=DIM, font=("Consolas", 11), anchor="e")
        self.clock.pack(side="right")

        what = follow if follow else " ".join(cmd)
        tk.Label(root, text=what, bg=BG, fg=DIM, font=("Consolas", 9),
                 anchor="w", wraplength=960, justify="left").pack(fill="x", padx=12)

        body = tk.Frame(root, bg=BG); body.pack(fill="both", expand=True, padx=12, pady=(6, 10))
        sb = tk.Scrollbar(body); sb.pack(side="right", fill="y")
        self.txt = tk.Text(body, bg="#0b0d13", fg=FG, font=("Consolas", 9),
                           insertbackground=FG, wrap="none", yscrollcommand=sb.set,
                           relief="flat", padx=8, pady=6)
        self.txt.pack(side="left", fill="both", expand=True)
        sb.config(command=self.txt.yview)
        for name, colour in (("ok", OK), ("bad", BAD), ("dim", DIM), ("fg", FG)):
            self.txt.tag_configure(name, foreground=colour)
        self.txt.config(state="disabled")

        os.makedirs(LOGDIR, exist_ok=True)
        slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:40] or "run"
        self.logpath = os.path.join(LOGDIR, slug + ".log")
        try:
            self.log = open(self.logpath, "w", encoding="utf-8", errors="replace")
        except Exception:
            self.log = None

        threading.Thread(target=self.follow_loop if follow else self.run_loop,
                         daemon=True).start()
        if also:
            threading.Thread(target=self.also_loop, daemon=True).start()
        self.pump()
        self.tick()

    # --- the child ---------------------------------------------------------
    def run_loop(self):
        try:
            self.proc = subprocess.Popen(
                self.cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                bufsize=1, text=True, errors="replace", cwd=r"C:/fpga",
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except Exception as e:
            self.q.put("could not start: %s\n" % e)
            self.done = -1
            return
        for line in self.proc.stdout:
            self.q.put(line)
        self.done = self.proc.wait()

    def also_loop(self):
        # the log the command is really writing to, tailed alongside its stdout
        while not os.path.exists(self.also) and self.done is None:
            time.sleep(0.5)
        try:
            f = open(self.also, "r", errors="replace")
        except Exception:
            return
        f.seek(0, 2)
        quiet = 0
        while True:
            line = f.readline()
            if line:
                quiet = 0
                self.q.put(line)
            else:
                if self.done is not None:
                    quiet += 1
                    if quiet > 6:      # the command is over and the log went quiet
                        return
                time.sleep(0.3)

    def follow_loop(self):
        # wait for it to exist, then read it as it grows
        while not os.path.exists(self.follow):
            time.sleep(0.5)
        with open(self.follow, "r", errors="replace") as f:
            while True:
                line = f.readline()
                if line:
                    self.q.put(line)
                else:
                    time.sleep(0.3)

    # --- the window --------------------------------------------------------
    def pump(self):
        n = 0
        try:
            while n < 400:
                line = self.q.get_nowait()
                self.write(line)
                n += 1
        except queue.Empty:
            pass
        if n:
            self.txt.see("end")
            if self.log:
                try: self.log.flush()
                except Exception: pass
        self.root.after(120, self.pump)

    def write(self, line):
        if self.log:
            try: self.log.write(line)
            except Exception: pass
        tag = "fg"
        for rx, colour in RULES:
            if rx.search(line):
                tag = {OK: "ok", BAD: "bad", DIM: "dim"}[colour]
                break
        self.txt.config(state="normal")
        self.txt.insert("end", line, tag)
        # keep the window from growing without bound
        over = int(self.txt.index("end-1c").split(".")[0]) - MAXLINES
        if over > 0:
            self.txt.delete("1.0", "%d.0" % (over + 1))
        self.txt.config(state="disabled")

    def close_tick(self):
        self.closing -= 1
        if self.closing <= 0:
            try: self.root.destroy()
            except Exception: pass
            return
        self.state.config(text="finished, exit 0 - closing in %ds" % self.closing, fg=OK)
        self.root.after(1000, self.close_tick)

    def tick(self):
        el = int(time.time() - self.t0)
        self.clock.config(text="%d min %02d s" % divmod(el, 60))
        if self.follow:
            self.state.config(text="watching", fg=WARN)
        elif self.done is None:
            self.state.config(text="running", fg=WARN)
        else:
            self.state.config(text="finished, exit %d" % self.done,
                              fg=OK if self.done == 0 else BAD)
            self.root.title(("DONE - " if self.done == 0 else "FAILED - ") + self.root.title())
            if self.log:
                try: self.log.close()
                except Exception: pass
                self.log = None
            # A window that did its job and succeeded should not have to be shut
            # by hand; one that failed is the one worth leaving up to be read.
            if self.done == 0:
                self.closing = 6
                self.root.after(1000, self.close_tick)
            return
        self.root.after(1000, self.tick)


def main(argv):
    also = None
    if "--also" in argv:
        i = argv.index("--also")
        also = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if "--follow" in argv:
        i = argv.index("--follow")
        title = argv[1] if i > 1 else "watching"
        return title, None, argv[i + 1], also
    if "--" not in argv:
        sys.exit(__doc__)
    i = argv.index("--")
    return argv[1], argv[i + 1:], None, also


if __name__ == "__main__":
    title, cmd, follow, also = main(sys.argv)
    root = tk.Tk()
    Console(root, title, cmd, follow, also)
    root.mainloop()
