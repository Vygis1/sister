"""Web debugger for the fpgalink register bus.

Serves the UI in web/ and exposes the register bus over HTTP. Deliberately thin:
the HTTP API mirrors the register map rather than inventing a vocabulary of its
own, so adding a peripheral to the FPGA needs no changes here.

The exceptions are the three things a browser cannot do well one register at a
time. MDIO is a start-then-poll interface and doing that from JavaScript would
mean three HTTP round trips per register. Audio capture has to keep up with a
ring buffer. Installing a core is eight thousand pages. All three are wrapped
server-side, next to the socket.

    python pc/server.py --target 192.168.178.50
    python pc/server.py                          # a mock on localhost

Then open http://127.0.0.1:8080
"""

import argparse
import concurrent.futures
import glob
import json
import zlib
import urllib.request
import urllib.parse
import io
import os
import re
import struct
import subprocess
import tempfile
import threading
import time
import wave

from flask import Flask, Response, jsonify, request, send_file, send_from_directory

import fpgalink as fl
import socket

WEB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "web")

app = Flask(__name__, static_folder=None)

link = None
link_lock = threading.Lock()  # one UDP socket, many browser requests


def talk(fn, *a, **kw):
    """Run one bus transaction under the lock, turning link errors into 503s.

    Fails immediately while the board is known not to be answering. This is not
    an optimisation. A dead board costs a full round of UDP retries to establish,
    every route pays it while holding the bus lock, and the page polls several
    routes a second -- so requests pile up faster than they drain and a board
    that is merely unplugged presents as a web server that has hung. One shared
    verdict, re-tested a couple of times a second, keeps the page answering
    instantly with bad news instead of slowly with nothing.
    """
    if board_is_gone():
        raise fl.LinkTimeout(f"no answer from {link.addr[0]}:{link.addr[1]}")
    with link_lock:
        try:
            v = fn(*a, **kw)
            note_here()
            return v
        except (fl.LinkTimeout, TimeoutError):
            # Silence means the board may be gone. An error status does not: it
            # means the board is right there, objecting to the address it was
            # given -- which one debug panel polling a register the running core
            # does not implement will do all day. Latching "offline" on that
            # made a healthy board flicker in and out of existence.
            note_gone()
            raise


@app.errorhandler(fl.LinkError)
def on_link_error(err):
    return jsonify(error=str(err), target=f"{link.addr[0]}:{link.addr[1]}"), 503


# --- static UI ----------------------------------------------------------

@app.route("/")
def index():
    return send_from_directory(WEB_DIR, "index.html")


@app.route("/<path:path>")
def static_file(path):
    return send_from_directory(WEB_DIR, path)


@app.after_request
def no_stale_page(resp):
    # The page's scripts change with the cores. A browser that kept an old
    # synth.js played the PlayStation's stereo stream as mono -- half speed, and
    # twenty seconds behind after a minute -- because nothing told it to ask
    # again. Always revalidate the page's own files.
    if not request.path.startswith("/api/"):
        resp.headers["Cache-Control"] = "no-cache"
    return resp


# --- raw register access ------------------------------------------------

@app.route("/api/ident")
def api_ident():
    info = talk(link.ident)
    info["target"] = f"{link.addr[0]}:{link.addr[1]}"
    return jsonify(info)


@app.route("/api/reg/<addr>", methods=["GET", "POST"])
def api_reg(addr):
    a = int(addr, 0)
    if request.method == "POST":
        talk(link.write, a, int(request.json["value"]))
        return jsonify(ok=True)
    return jsonify(addr=a, value=talk(link.read, a))


@app.route("/api/sys")
def api_sys():
    return jsonify(
        id=talk(link.read, fl.SYS_ID),
        version=talk(link.read, fl.SYS_VERSION),
        uptime_ms=talk(link.read, fl.SYS_UPTIME),
        scratch=talk(link.read, fl.SYS_SCRATCH),
    )


@app.route("/api/selftest", methods=["POST"])
def api_selftest():
    """Prove the bus carries data both ways, with patterns that catch stuck bits."""
    results = []
    for value in (0x00000000, 0xFFFFFFFF, 0xAAAAAAAA, 0x55555555, 0xDEADBEEF):
        talk(link.write, fl.SYS_SCRATCH, value)
        got = talk(link.read, fl.SYS_SCRATCH)
        results.append({"wrote": value, "read": got, "ok": got == value})
    return jsonify(results=results, passed=all(r["ok"] for r in results))


# --- PHY over MDIO ------------------------------------------------------

MDIO_BASE = 0x0005_0000
MDIO_CMD = MDIO_BASE + 0x04
MDIO_STATUS = MDIO_BASE + 0x08
MDIO_WDATA = MDIO_BASE + 0x0C
MDIO_RDATA = MDIO_BASE + 0x10


def mdio_wait():
    for _ in range(200):
        if not talk(link.read, MDIO_STATUS) & 1:
            return True
        time.sleep(0.002)
    return False


def mdio_read(phy, reg):
    talk(link.write, MDIO_CMD, (phy << 8) | reg)
    if not mdio_wait():
        raise fl.LinkError("MDIO transaction did not complete")
    return talk(link.read, MDIO_RDATA)


def mdio_write(phy, reg, value):
    talk(link.write, MDIO_WDATA, value & 0xFFFF)
    talk(link.write, MDIO_CMD, (1 << 16) | (phy << 8) | reg)
    if not mdio_wait():
        raise fl.LinkError("MDIO transaction did not complete")


@app.route("/api/phy/scan")
def api_phy_scan():
    found = []
    for phy in range(32):
        v = mdio_read(phy, 2)
        if v not in (0x0000, 0xFFFF):
            found.append({"addr": phy, "id1": v, "id2": mdio_read(phy, 3)})
    return jsonify(found=found)


@app.route("/api/phy/status")
def api_phy_status():
    phy = int(request.args.get("phy", 1))
    bmcr = mdio_read(phy, 0)
    # BMSR bit 2 (link) is latch-low: a single read after any link event returns
    # the stale down state. Read twice and report the second.
    mdio_read(phy, 1)
    bmsr = mdio_read(phy, 1)
    scsr = mdio_read(phy, 31)
    mode = {1: "10 half", 2: "100 half", 5: "10 full", 6: "100 full"}
    return jsonify(
        phy=phy,
        id1=mdio_read(phy, 2),
        id2=mdio_read(phy, 3),
        bmcr=bmcr,
        bmsr=bmsr,
        scsr=scsr,
        link=bool(bmsr & 0x0004),
        autoneg_done=bool(bmsr & 0x0020),
        mode=mode.get((scsr >> 2) & 7, "unknown"),
        loopback=bool(bmcr & 0x4000),
        powerdown=bool(bmcr & 0x0800),
        isolate=bool(bmcr & 0x0400),
    )


@app.route("/api/phy/reg/<int:phy>/<int:reg>", methods=["GET", "POST"])
def api_phy_reg(phy, reg):
    if request.method == "POST":
        mdio_write(phy, reg, int(request.json["value"]))
        return jsonify(ok=True)
    return jsonify(phy=phy, reg=reg, value=mdio_read(phy, reg))


@app.route("/api/phy/dump/<int:phy>")
def api_phy_dump(phy):
    regs = {}
    for reg in list(range(0, 7)) + [17, 18, 26, 27, 29, 30, 31]:
        regs[reg] = mdio_read(phy, reg)
    return jsonify(phy=phy, regs=regs)


# --- logic analyzer -----------------------------------------------------

LA_CONFIG = {
    "chan_mask": fl.LA_CHAN_MASK,
    "divisor": fl.LA_DIVISOR,
    "depth": fl.LA_DEPTH,
    "pretrig": fl.LA_PRETRIG,
    "trig_mask": fl.LA_TRIG_MASK,
    "trig_value": fl.LA_TRIG_VALUE,
    "trig_rise": fl.LA_TRIG_RISE,
    "trig_fall": fl.LA_TRIG_FALL,
}


@app.route("/api/la/status")
def api_la_status():
    raw = talk(link.read, fl.LA_STATUS)
    return jsonify(
        raw=raw,
        armed=bool(raw & fl.STATUS_ARMED),
        triggered=bool(raw & fl.STATUS_TRIGGERED),
        done=bool(raw & fl.STATUS_DONE),
        fill=(raw >> 16) & 0xFFFF,
        depth=talk(link.read, fl.LA_DEPTH),
    )


@app.route("/api/la/config", methods=["GET", "POST"])
def api_la_config():
    if request.method == "POST":
        for name, value in (request.json or {}).items():
            if name not in LA_CONFIG:
                return jsonify(error=f"unknown setting {name!r}"), 400
            talk(link.write, LA_CONFIG[name], int(value))
        return jsonify(ok=True)
    return jsonify({name: talk(link.read, a) for name, a in LA_CONFIG.items()})


@app.route("/api/la/arm", methods=["POST"])
def api_la_arm():
    talk(link.write, fl.LA_CTRL, fl.CTRL_RESET)
    for name, value in (request.json or {}).items():
        if name in LA_CONFIG:
            talk(link.write, LA_CONFIG[name], int(value))
    talk(link.write, fl.LA_CTRL, fl.CTRL_ARM)
    return jsonify(ok=True)


@app.route("/api/la/force", methods=["POST"])
def api_la_force():
    talk(link.write, fl.LA_CTRL, fl.CTRL_ARM | fl.CTRL_FORCE_TRIG)
    return jsonify(ok=True)


@app.route("/api/la/data")
def api_la_data():
    status = talk(link.read, fl.LA_STATUS)
    if not status & fl.STATUS_DONE:
        return jsonify(error="capture not complete"), 409
    depth = talk(link.read, fl.LA_DEPTH)
    want = min(depth, int(request.args.get("max", depth)))
    return jsonify(
        depth=depth,
        returned=want,
        divisor=talk(link.read, fl.LA_DIVISOR),
        pretrig=talk(link.read, fl.LA_PRETRIG),
        samples=talk(link.read_block, fl.LA_BUF_BASE, want),
    )


# --- synthesiser --------------------------------------------------------

SYN = 0x0003_0000
SYN_ID = SYN + 0x00
SYN_CTRL = SYN + 0x04
SYN_MASTER = SYN + 0x08
SYN_RATE = SYN + 0x0C
SYN_ATTACK = SYN + 0x10
SYN_RELEASE = SYN + 0x14
SYN_WCOUNT = SYN + 0x20
SYN_PHASE = SYN + 0x40          # + voice*4
SYN_VOICE = SYN + 0x60          # + voice*4

ABUF = 0x0004_0000
ABUF_WORDS = 16384
VOICES = 8

# Which MIDI note each voice is playing, or None. The board knows the frequency
# but not the name, and the UI wants the name.
voice_note = [None] * VOICES


def syn_rate():
    r = talk(link.read, SYN_RATE)
    return r if r else 48000


def note_hz(midi):
    return 440.0 * (2.0 ** ((midi - 69) / 12.0))


def phase_inc(hz, rate):
    """The frequency control word: hz * 2^32 / sample_rate."""
    return int(round(hz * (1 << 32) / rate)) & 0xFFFFFFFF


@app.route("/api/syn/state")
def api_syn_state():
    return jsonify(
        voices=voice_note,
        rate=syn_rate(),
        enabled=bool(talk(link.read, SYN_CTRL) & 1),
    )


@app.route("/api/syn/config", methods=["POST"])
def api_syn_config():
    body = request.json or {}
    if "enable" in body:
        talk(link.write, SYN_CTRL, 1 if body["enable"] else 0)
    if "master" in body:
        talk(link.write, SYN_MASTER, int(body["master"]) & 0xFFFF)
    if "attack" in body:
        talk(link.write, SYN_ATTACK, int(body["attack"]) & 0xFFFF)
    if "release" in body:
        talk(link.write, SYN_RELEASE, int(body["release"]) & 0xFFFF)
    return jsonify(ok=True)


@app.route("/api/syn/noteon", methods=["POST"])
def api_syn_noteon():
    body = request.json or {}
    midi = int(body["midi"])
    wave_sel = int(body.get("wave", 2)) & 7
    if midi in voice_note:
        return jsonify(ok=True, voice=voice_note.index(midi))
    if None not in voice_note:
        return jsonify(error="all eight voices are in use"), 409
    v = voice_note.index(None)
    rate = syn_rate()
    talk(link.write, SYN_PHASE + v * 4, phase_inc(note_hz(midi), rate))
    talk(link.write, SYN_VOICE + v * 4, (0xC000 << 16) | (wave_sel << 1) | 1)
    voice_note[v] = midi
    return jsonify(ok=True, voice=v)


@app.route("/api/syn/noteoff", methods=["POST"])
def api_syn_noteoff():
    midi = int((request.json or {})["midi"])
    if midi not in voice_note:
        return jsonify(ok=True)
    v = voice_note.index(midi)
    cur = talk(link.read, SYN_VOICE + v * 4)
    talk(link.write, SYN_VOICE + v * 4, cur & ~1)
    voice_note[v] = None
    return jsonify(ok=True, voice=v)


@app.route("/api/syn/panic", methods=["POST"])
def api_syn_panic():
    for v in range(VOICES):
        talk(link.write, SYN_VOICE + v * 4, 0)
        voice_note[v] = None
    return jsonify(ok=True)


SYN_SIZE = SYN + 0x18
SYN_CHANS = SYN + 0x24


def ring_shape():
    """(words in the ring, channels), asked of the board rather than assumed.

    The synthesiser's ring is mono -- two offset-binary samples a word -- and
    answers 0x24 with a bus error. The PlayStation's (rtl/ps1_aring.v) is stereo:
    one {right, left} word per sample pair, signed, and says 2 there. The size
    was a constant here, 16384, while the synthesiser's ring is 8192.
    """
    try:
        words = talk(link.read, SYN_SIZE) or ABUF_WORDS
    except Exception:
        words = ABUF_WORDS
    try:
        chans = talk(link.read, SYN_CHANS)
    except Exception:
        chans = 1
    return words, (2 if chans == 2 else 1)


def ring_words(start, count, words=ABUF_WORDS, chans=1):
    """Read `count` words out of the audio ring, following the wrap.

    Mono: two samples a word, offset binary. Stereo: one {R, L} word per pair,
    signed, returned interleaved L, R, L, R.
    """
    runs = ([(start, count)] if start + count <= words
            else [(start, words - start), (0, count - (words - start))])
    out = []
    for base, n in runs:
        for word in talk(link.read_block, ABUF + base * 4, n):
            lo, hi = word & 0xFFFF, (word >> 16) & 0xFFFF
            if chans == 2:
                out.append(lo - 0x10000 if lo & 0x8000 else lo)
                out.append(hi - 0x10000 if hi & 0x8000 else hi)
            else:
                out.append(lo - 0x8000)
                out.append(hi - 0x8000)
    return out


def read_ring(cursor, limit, words=ABUF_WORDS, chans=1):
    """Pull whatever is new since `cursor`.

    Returns (new_cursor, samples, resync). `resync` means more than a buffer's
    worth went past between polls: those samples are genuinely gone, and
    splicing over the gap would produce a recording that sounds fine and is
    wrong.
    """
    now = talk(link.read, SYN_WCOUNT)
    if cursor is None:
        return now, [], False
    new = (now - cursor) & 0xFFFFFFFF
    if new == 0:
        return now, [], False
    if new > words:
        return now, [], True
    new = min(new, limit)
    return (cursor + new) & 0xFFFFFFFF, ring_words(cursor % words, new, words, chans), False


@app.route("/api/syn/scope")
def api_syn_scope():
    n = min(int(request.args.get("n", 1024)), 4096)
    size, chans = ring_shape()
    words = (n + 1) // 2
    now = talk(link.read, SYN_WCOUNT)
    out = ring_words((now - words) % size, words, size, chans)
    if chans == 2:
        out = [(out[i] + out[i + 1]) // 2 for i in range(0, len(out) - 1, 2)]   # the scope draws one trace
    return jsonify(samples=out[:n], rate=syn_rate())


class AudioPump:
    """Keeps the board's audio ring drained into memory, for the page to take.

    The page used to read the ring over the register link itself, on every poll,
    under the one bus lock -- so its latency was a poll interval plus a network
    round trip plus whatever else held the bus, and a single lost UDP packet cost
    a 0.25 s timeout, three times, which is longer than the margin the player
    keeps. The only cure for that was a big margin, and the margin IS the delay.

    So a thread reads the ring every few milliseconds on a socket of its own,
    with a timeout short enough that a lost packet costs a few ms, and keeps the
    last couple of seconds here. A page's request is answered from memory, at
    once. It runs only while somebody has asked for audio in the last few
    seconds, so a closed page costs the link nothing.
    """

    KEEP = 2 * 44100            # frames kept (two seconds)

    def __init__(self):
        self.lock = threading.Lock()
        self.frames = []        # interleaved samples, per `chans`
        self.base = 0           # absolute frame number of self.frames[0]
        self.chans = 1
        self.rate = 44100
        self.wanted = 0.0
        self.thread = None
        self.link = None

    def want(self):
        self.wanted = time.time()
        if self.thread is None or not self.thread.is_alive():
            self.thread = threading.Thread(target=self._run, daemon=True)
            self.thread.start()

    def _run(self):
        if self.link is None:
            self.link = fl.Link(link.addr[0], link.addr[1], timeout=0.02, retries=6)
        L = self.link
        cursor = None; words = ABUF_WORDS; shape_at = 0.0
        while time.time() - self.wanted < 5.0:
            try:
                if time.time() - shape_at > 2.0:
                    try: words = L.read(SYN_SIZE) or ABUF_WORDS
                    except fl.LinkError: pass
                    try: chans = 2 if L.read(SYN_CHANS) == 2 else 1
                    except fl.LinkError: chans = 1
                    try: self.rate = L.read(SYN_RATE) or 44100
                    except fl.LinkError: pass
                    if chans != self.chans:
                        with self.lock: self.frames = []; self.chans = chans
                    shape_at = time.time()
                now = L.read(SYN_WCOUNT)
                if cursor is None: cursor = now
                new = (now - cursor) & 0xFFFFFFFF
                if new > words:             # fell behind the ring: start again from here
                    cursor = now; new = 0
                    with self.lock: self.base += len(self.frames) // self.chans + 1; self.frames = []
                if new:
                    start = cursor % words
                    runs = ([(start, new)] if start + new <= words
                            else [(start, words - start), (0, new - (words - start))])
                    out = []
                    for b, n in runs:
                        for w in L.read_block(ABUF + b * 4, n):
                            lo, hi = w & 0xFFFF, (w >> 16) & 0xFFFF
                            if self.chans == 2:
                                out.append(lo - 0x10000 if lo & 0x8000 else lo)
                                out.append(hi - 0x10000 if hi & 0x8000 else hi)
                            else:
                                out.append(lo - 0x8000); out.append(hi - 0x8000)
                    cursor = (cursor + new) & 0xFFFFFFFF
                    with self.lock:
                        self.frames.extend(out)
                        per = self.chans if self.chans == 2 else 1
                        extra = len(self.frames) // per - self.KEEP
                        if extra > 0:
                            del self.frames[:extra * per]; self.base += extra
            except fl.LinkError:
                pass
            time.sleep(0.005)

    def take(self, cursor, stereo, limit=4096):
        """Frames after `cursor` (an absolute frame number), as the page wants them."""
        self.want()
        with self.lock:
            per = self.chans if self.chans == 2 else 1
            end = self.base + len(self.frames) // per
            if cursor is None or cursor > end:
                return end, [], False, self.chans
            resync = cursor < self.base
            if resync: cursor = end - min(end - self.base, 2205)   # rejoin 50 ms back
            n = min(end - cursor, limit)
            i = (cursor - self.base) * per
            out = self.frames[i:i + n * per]
            chans = self.chans
        # Stereo only to a page that asks for it: a page from before the
        # PlayStation had sound treats every sample as mono, and handed L, R, L, R
        # it plays at half speed and falls further behind every second.
        if chans == 2 and not stereo:
            out = [(out[k] + out[k + 1]) // 2 for k in range(0, len(out) - 1, 2)]
            chans = 1
        return cursor + n, out, resync, chans


audio_pump = AudioPump()


@app.route("/api/syn/stream")
def api_syn_stream():
    arg = request.args.get("cursor", "")
    cursor = int(arg) if arg not in ("", "null", "undefined") else None
    new_cursor, samples, resync, chans = audio_pump.take(cursor, request.args.get("stereo") == "1")
    return jsonify(cursor=new_cursor, samples=samples, channels=chans,
                   resync=resync, rate=audio_pump.rate)


@app.route("/api/syn/record")
def api_syn_record():
    seconds = min(float(request.args.get("seconds", 4)), 30.0)
    rate = syn_rate()
    words, chans = ring_shape()
    want = int(seconds * rate) * chans
    out = []
    cursor = talk(link.read, SYN_WCOUNT)
    t0 = time.monotonic()
    while len(out) < want:
        cursor, samples, resync = read_ring(cursor, words, words, chans)
        if resync:
            return jsonify(error="fell behind the ring buffer; samples were lost"), 500
        if not samples:
            time.sleep(0.002)
        out.extend(samples)
        if time.monotonic() - t0 > seconds * 8 + 5:
            return jsonify(error="capture is not keeping up with the sample rate"), 500

    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(chans)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack(
            f"<{want}h", *[max(-32768, min(32767, s)) for s in out[:want]]))
    buf.seek(0)
    return send_file(buf, mimetype="audio/wav",
                     as_attachment=True, download_name="fpga-synth.wav")


# --- video --------------------------------------------------------------

VID = 0x0006_0000
VID_CTRL = VID + 0x04
VID_FRAME = VID + 0x10
VID_PATTERN = VID + 0x14
# The framebuffer is 320 wide now, for the Mega Drive's H40, and 19200 words no
# longer fit the single page it used to live in -- so it moved up to 0x0010 and
# spans two.
VID_FB = 0x0010_0000
FB_W, FB_H = 320, 240
FB_WORDS = FB_W * FB_H // 4

# What each machine actually draws into that buffer. The stride is always FB_W;
# the narrower machines simply never touch the columns past their own width, so
# whatever reads the buffer has to crop rather than show 320 of everything.
CONSOLE_HEIGHT = {0: 240, 1: 192, 2: 224, 3: 240}
CONSOLE_WIDTH  = {0: 256, 1: 256, 2: 320, 3: 320}
_running = {"what": 0, "at": 0.0}


def running_console():
    """Which machine is selected, asked rarely.

    Every frame would mean a register read per frame per client, for something
    that changes when a cartridge is swapped and at no other time.
    """
    if time.time() - _running["at"] > 2.0:
        try:
            _running.update(what=talk(link.read, NES_CONSOLE) & 0xF,
                            at=time.time())
        except (fl.LinkError, TimeoutError):
            pass
    return _running["what"]


@app.route("/api/vid/state")
def api_vid_state():
    ctrl = talk(link.read, VID_CTRL)
    return jsonify(
        enabled=bool(ctrl & 1),
        external=bool(ctrl & 2),
        pattern=talk(link.read, VID_PATTERN) & 3,
        frame=talk(link.read, VID_FRAME),
        # stride is what a row occupies; width/height are what to show of it.
        stride=FB_W,
        width=CONSOLE_WIDTH.get(running_console(), FB_W),
        height=CONSOLE_HEIGHT.get(running_console(), FB_H),
        format="rgb555" if frame_is_ddr() else "rgb332",
        stream_diag=dict(frame_stream.diag),
    )


@app.route("/api/vid/config", methods=["POST"])
def api_vid_config():
    body = request.json or {}
    if "enable" in body or "external" in body:
        ctrl = talk(link.read, VID_CTRL)
        if "enable" in body:
            ctrl = (ctrl & ~1) | (1 if body["enable"] else 0)
        if "external" in body:
            ctrl = (ctrl & ~2) | (2 if body["external"] else 0)
        talk(link.write, VID_CTRL, ctrl)
    if "pattern" in body:
        talk(link.write, VID_PATTERN, int(body["pattern"]) & 3)
    return jsonify(ok=True)


# --- the frame in DDR3 (PlayStation builds) -------------------------------------
#
# The PlayStation draws 640 wide in 15-bit colour and its build has no block RAM
# left, so its frame lives in DDR3 (rtl/fb_ddr.v): the console captures one frame
# when asked (ctrl 0x98), says when it is whole, and the host reads it back as
# 16-bit RGB555 words through pages 0x10-0x19. The browser gets those bytes as
# they are, with the geometry in headers.
FB_CAP   = 0x0008_0000 + 0x98     # the console's capture register (NES + 0x98; NES is defined below)
FB_DDR   = 0x0010_0000
FB_DDR_STRIDE = 320          # words per row: 640 pixels, two to a word


_ddr_frame = {"v": None, "at": 0.0}


def frame_is_ddr():
    """Is the running image a PlayStation (frame streamed from DDR3)?

    Remembered, not asked per frame. It was a register read on every picture
    request, and one lost reply anywhere in the server latches the board as
    "gone" for a moment (see board_is_gone): cores_built() then said 0, the
    request fell through to the old RGB332 path, and that failed with a 503.
    Measured 2026-09-29 with the game at a steady 30: the page got 15 pictures
    a second, with 250-550 ms holes. The answer only changes when a different
    image is booted, so it is refreshed every two seconds and a failed refresh
    keeps what was known.
    """
    now = time.time()
    if _ddr_frame["v"] is None or now - _ddr_frame["at"] > 2.0:
        try:
            _ddr_frame.update(v=bool((talk(link.read, NES_CONSOLE) >> 16) & 0b1000), at=now)
        except (fl.LinkError, TimeoutError):
            if _ddr_frame["v"] is None:
                return False
            _ddr_frame["at"] = now - 1.5      # try again soon; keep what we knew
    return _ddr_frame["v"]


STREAM_PORT = 5006
STREAM_CTL   = 0x0008_0000 + 0xF0     # {enable, .., UDP port}
# Out of the DDR3 frame copy by default.
#
# This was switched to the direct scanout path for a day because the picture
# froze on the DDR3 one -- but the freeze was never the path. It was the
# restart deadlock in api_vid_frame (see display_geometry): the board stops
# streaming on a console reset, the server needed a completed capture to learn
# the size before re-arming, and a capture cannot complete while the scanout is
# idle. Fixed there, the DDR3 path runs fine.
#
# And it has to be the default, because THE DIRECT PATH SHOWS NOTHING DURING
# THE BOOT. The BIOS animation runs in 640x480 INTERLACED; measured across a
# reset, the DDR3 path delivers it (76,524 lit pixels at 2.5 s, the Sony logo,
# then the PlayStation one) and the direct path delivers black for the whole
# boot and only comes alive when the game switches to 256x240.
# Set STREAM_DDR=0 to take the direct path anyway.
STREAM_DDR   = os.environ.get("STREAM_DDR", "1") != "0"
STREAM_BASE  = 0x0008_0000 + 0xF4     # bus address of the frame
STREAM_WORDS = 0x0008_0000 + 0xF8     # words in it
STREAM_ROW   = 0x0008_0000 + 0xFC     # {row pitch, words per row}, both in words
FB_ROWS      = 240                    # the capture is always this tall


class FrameStream:
    """The board's frame streamer, received.

    net_core sends the captured frame, unasked, as UDP packets of up to 350
    words: 'F' 'S', frame id, word offset, words in the frame, words here, then
    the words big-endian as the register link carries them. A frame is complete
    when its words have all arrived; the latest complete one is what the page
    gets. Going this way instead of reading the frame through the register link
    (one 1 KB round trip at a time) is the difference between six frames a
    second and as many as the browser will take.

    The socket sends a small datagram to the board now and then: the board drops
    it (not an fpgalink packet) but Windows' firewall then treats what comes back
    from that address as replies and lets it in.
    """

    def __init__(self):
        self.sock = None
        self.thread = None
        self.lock = threading.Lock()
        self.latest = None          # (bytes, w, h)
        self.frames = {}            # frame id -> [buffer, words received]
        self.words = 0
        self.w = self.h = 0
        self.enabled = False
        self.count = 0
        # diagnostics: slices that did not follow the one before (by offset)
        self.diag = {"seq_break": 0, "backward": 0, "dup_complete": 0, "pkts": 0,
                     "held_incomplete": 0, "restarted": 0}
        self._seq = {}
        self.last_rx = 0.0
        self.last_want = 0.0
        self.mismatch = 0

    def start(self, w, h):
        """Configure the board to stream this frame size and start receiving."""
        self.w, self.h = w, h
        self.words = ((w + 1) // 2) * h
        if self.sock is None:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            if hasattr(socket, "SIO_UDP_CONNRESET"):   # see fpgalink.Link
                try: self.sock.ioctl(socket.SIO_UDP_CONNRESET, False)
                except OSError: pass
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
            self.sock.bind(("0.0.0.0", STREAM_PORT))
            self.sock.settimeout(0.5)
            self.thread = threading.Thread(target=self._run, daemon=True)
            self.thread.start()
        self._punch()
        talk(link.write, STREAM_BASE, FB_DDR)
        talk(link.write, STREAM_WORDS, self.words)
        # The capture writes each row at the full 640-pixel pitch and fills only
        # the left w of it, so the board is told to step over the rest rather
        # than send it: half the bytes on the wire, twice the frame rate.
        talk(link.write, STREAM_ROW, (FB_DDR_STRIDE << 16) | ((w + 1) // 2))
        # Bit 31 enables, bit 30 takes the picture at every vertical sync. The
        # alternative is to wait for the drawing engine to be idle, which is
        # measurably cleaner only while the BIOS draws its opening animation
        # straight to the screen it is showing; the menu and games draw into a
        # second buffer and swap, so a frame taken at a vertical sync is whole.
        # Waiting for idle halves the frame rate, 8.4 against 15.5, and buys
        # nothing once past the intro.
        # The PlayStation's frame is streamed from its DDR3 copy (bit 27): the
        # direct path couples the scanout to the network's pace, and its FIFO
        # hands out a stale slot when the network catches the scanout with it
        # empty -- a 1024-word-old ghost of the picture on scattered rows.
        # bit 27 = stream from the DDR3 copy (a capture at full speed, then the
        # network at its own pace); clear = straight off the scanout, paced by
        # the network, which tears a double-buffered game. STREAM_DDR selects.
        # WHICH PATH, decided per video mode rather than once and for all,
        # because each one fails where the other works. Measured on Crash:
        #
        #   direct (bit 27 clear)  ~18 new pictures a second in the game, and
        #                          NOTHING at all during the boot -- the BIOS
        #                          runs 640x480 interlaced and the direct path
        #                          delivers black until the game switches mode.
        #   DDR3 copy (bit 27)     the boot animation appears, and the game
        #                          crawls: 13 distinct frames in 144 requests,
        #                          1.6 a second, which on screen is a character
        #                          frozen for four frames and then snapping to
        #                          a new pose.
        #
        # The direct path splices in SOME scenes -- standing still in a level it
        # put the top of one picture and the bottom of another on the wire in
        # 40-46% of frames, split at row 60 of 240, and the DDR3 copy had none
        # of that. But the copy's speed depends on a whole capture finishing,
        # and in a heavy scene it collapses. Measured in the attract cycle's
        # temple level, alternating between the two, 2026-09-25:
        #
        #   direct off the scanout   28.8 and 26.1 frames a second
        #   from the DDR3 copy        6.4 and 15.1
        #
        # Six frames a second of a moving camera is far worse to watch than an
        # occasional splice, so the direct path stays and the splicing has to be
        # fixed where it happens instead of avoided here.
        # 2026-09-26, MEASURED ON THE BOARD, twice each way, Crash in a level:
        #
        #   path        frames a second   frames jumping vertically   with a band
        #   direct           16.7                   75%                   37%
        #   from DDR3         9.3                    0%                    0%
        #
        # The direct path's picture restarts part way down -- the top is the
        # frame just captured, the bottom is the NEXT capture starting again
        # from its first row -- because a capture may begin while the network
        # core is still sending. That is fixed in fb_stream.v (`want` clears
        # when a capture FINISHES, not when it starts) and gated by
        # sim/tb_fbstream.v, but until that image is on the board the copy is
        # the only clean picture. Half the frame rate and no glitching beats
        # twice the frame rate with three quarters of the frames broken.
        #
        # When the fixed image is flashed, put this back to the direct path and
        # re-measure with the same test before believing it.
        # The fbhandshake image (2026-09-27) fixes the direct path, so take it
        # again: it is clean AND fast. If the jumping ever comes back, flip this
        # to True and re-measure both ways before changing anything else.
        ddr = False
        try:
            d = talk(link.read, PS1_DISP)
            ddr = bool((d >> 28) & 3)      # interlaced: the direct path shows it black
        except Exception:
            pass
        self.from_ddr = ddr
        talk(link.write, STREAM_CTL, (0xC800_0000 if ddr else 0xC000_0000) | STREAM_PORT)
        talk(link.write, FB_CAP, 1)         # the first capture; the streamer re-arms after each frame
        self.mismatch = 0
        self.enabled = True

    def stop(self):
        if self.enabled:
            try:
                talk(link.write, STREAM_CTL, 0)
            except Exception:
                pass
        self.enabled = False

    def _punch(self):
        try:
            self.sock.sendto(b"\x00", (link.addr[0], link.addr[1]))
        except Exception:
            pass

    def _run(self):
        # Nothing one packet does may end this thread: when it died, the page
        # froze on its last picture with nothing in the log but a traceback.
        while True:
            try:
                return self._receive()
            except Exception as e:
                self.diag["crashed"] = self.diag.get("crashed", 0) + 1
                self.diag["last_error"] = repr(e)[:200]
                with self.lock:
                    self.frames.clear()
                self._seq.clear()
                time.sleep(0.01)

    def _receive(self):
        last_punch = 0.0
        while True:
            if time.time() - last_punch > 5.0:
                self._punch(); last_punch = time.time()
            # Nobody has asked for a picture in a while: tell the board to stop
            # pushing. Otherwise it keeps a few megabytes a second on the wire
            # for a page nobody is looking at, and shares the link with every
            # register the debugging tools want to read.
            if self.enabled and self.last_want and time.time() - self.last_want > 5.0:
                self.stop()
            try:
                data, _ = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            except ConnectionResetError:
                # Windows reports an ICMP "unreachable" for something this socket
                # sent as a reset on the next receive; it is not the end of the
                # stream, and returning here killed the thread for good
                continue
            except OSError:
                return
            if len(data) < 14 or data[0:2] != b"FS":
                continue
            fid, = struct.unpack(">H", data[2:4])
            off, total, n = struct.unpack(">IIH", data[4:14])
            if total != self.words:
                # The board works the frame size out from the picture it is
                # actually showing, so a total we did not expect means the video
                # mode changed under us. Take the new size from the packet and
                # carry on, rather than rejecting everything and waiting for a
                # timer: every packet is proof of what the board is sending, and
                # ignoring that left the page frozen on a stale black frame with
                # no way back except restarting the server.
                if total and total % FB_ROWS == 0:
                    self.words = total
                    self.w = (total // FB_ROWS) * 2
                    self.h = FB_ROWS
                    self.frames.clear()
                    self.mismatch = 0
                else:
                    self.mismatch += 1
                    continue
            if off + n > total or len(data) < 14 + n * 4:
                continue
            self.mismatch = 0
            self.diag["pkts"] += 1
            exp = self._seq.get(fid)
            restart = False
            if exp is not None and off != exp:
                self.diag["seq_break"] += 1
                if off < exp:
                    self.diag["backward"] += 1
                    restart = True
            self._seq[fid] = off + n
            with self.lock:
                entry = self.frames.get(fid)
                # The board starts the capture again from the top under the SAME
                # frame id, and what it sent before the restart is a picture of
                # the console one frame earlier. Keeping it and letting the new
                # words fill in around it hands the page a frame that is the top
                # of one picture and the bottom of another -- measured
                # 2026-09-25 on Crash: the split was at row 60 of 240 in 42 of
                # the 71 spliced pairs, and about half of all delivered frames
                # differed from the one before by 70% or more while the pad was
                # not being touched. That is the "everything wiggles". So a
                # restart throws away what came before it.
                if restart and entry is not None:
                    entry = None
                    del self.frames[fid]
                    self.diag["restarted"] = self.diag.get("restarted", 0) + 1
                # The frame changed size under this id -- the video mode changed
                # while it was on the wire (a console reset does that). Its buffer
                # was sized for the old one, and writing the new words into it
                # raised and killed this thread: the page froze on its last
                # picture until the server was restarted (2026-09-30).
                if entry is not None and len(entry[0]) != total * 4:
                    del self.frames[fid]
                    entry = None
                if entry is None:
                    if len(self.frames) > 4:      # forget stale partial frames
                        for k in sorted(self.frames)[:-2]:
                            del self.frames[k]
                    entry = self.frames[fid] = [bytearray(total * 4), 0, []]
                buf, got, spans = entry
                # A frame was counted as complete as soon as the WORDS RECEIVED
                # reached the frame's size. The board sometimes starts a frame
                # again from the top under the same id, and then the words that
                # arrive twice make up for the ones still missing: the count
                # says whole, and the page is handed a picture with a band of
                # black where the tail should be. That is the "half the screen
                # disappears" on a moving scene. So: remember WHICH words have
                # landed, and call a frame whole only when all of it has.
                words = struct.unpack(">%dI" % n, data[14:14 + n * 4])
                struct.pack_into("<%dI" % n, buf, off * 4, *words)
                spans.append((off, off + n))
                entry[1] = got + n
                self.last_rx = time.time()
                if entry[1] >= total:
                    if entry[1] > total: self.diag["dup_complete"] += 1
                    covered = 0
                    end = 0
                    for a, b in sorted(spans):
                        if a > end: break            # a gap: not whole yet
                        if b > end: end = b
                    covered = end
                    if covered < total:
                        self.diag["held_incomplete"] += 1
                        continue
                    self._seq.pop(fid, None)
                    self.latest = (bytes(buf), self.w, self.h)
                    self.count += 1
                    del self.frames[fid]

    def frame(self, wait=0.25):
        """The latest complete frame, waiting a little for a new one."""
        self.last_want = time.time()
        want = self.count + 1
        deadline = time.time() + wait
        while self.count < want and time.time() < deadline:
            time.sleep(0.002)
        return self.latest


frame_stream = FrameStream()


PS1_DISP = 0x0008_0000 + 0x6C   # {disp_on, hres, vres480, interlace, 0, disp_y, 0, disp_x}


def display_geometry():
    """What the console is showing, from ONE register.

    ddr_frame() also reports the size, but it has to complete a capture to do
    it, and a capture cannot complete unless the scanout is running -- which it
    only does while the stream is armed. Learning the size that way before
    arming is a deadlock, and it is why the page went black across a console
    reset and stayed black until the game had loaded: every request answered
    503 because the capture it needed could never finish.

    The size only has to be close: the receiver takes the real one from the
    first packet whose total does not match (see FrameStream.run).
    """
    try:
        d = talk(link.read, PS1_DISP)
    except Exception:
        return FB_W, FB_H
    w = (256, 320, 512, 640)[(d >> 29) & 3]
    if w > 320:
        w //= 2                     # wide modes are captured every other pixel
    return w, FB_H


def ddr_frame():
    """Capture a frame and read it back: (bytes of RGB555, width, height)."""
    talk(link.write, FB_CAP, 1)
    deadline = time.time() + 0.5
    while True:
        st = talk(link.read, FB_CAP)
        if st >> 31:
            break
        if time.time() > deadline:
            raise TimeoutError("the frame never finished capturing")
        time.sleep(0.005)
    w = st & 0x3FF or 320
    h = (st >> 10) & 0x1FF or 240
    words_per_row = (w + 1) // 2
    out = bytearray()
    for row in range(h):
        ws = talk(link.read_block, FB_DDR + row * FB_DDR_STRIDE * 4, words_per_row)
        out += b"".join(struct.pack("<I", x) for x in ws)
    return bytes(out), w, h


@app.route("/api/vid/frame")
def api_vid_frame():
    """One frame, raw: 256x240 bytes of RGB332 straight out of the framebuffer.

    A PlayStation build answers with RGB555 instead (see ddr_frame), and says so
    in the headers: X-Format, X-Width, X-Height.

    Raw rather than PNG on purpose. The browser draws this onto a canvas thirty
    times a second, and encoding it here would cost more than the register reads
    that fetched it.
    """
    if frame_is_ddr():
        try:
            frame_stream.last_want = time.time()
            if (not frame_stream.enabled or frame_stream.mismatch > 3
                    or time.time() - frame_stream.last_rx > 2.0):
                # ARM THE BOARD FIRST, from a register read rather than a
                # capture -- see display_geometry() for why the other order
                # cannot recover from a console reset.
                w, h = display_geometry()
                frame_stream.start(w, h)
            got = frame_stream.frame()
            if got is None:
                got = frame_stream.latest      # whatever came in last
            if got is None:
                data, w, h = ddr_frame()       # nothing has streamed yet
            else:
                data, w, h = got
        except (TimeoutError, fl.LinkError) as e:
            # A transient failure is not a reason to blank the page. Show the
            # last picture that arrived; only say nothing when there has never
            # been one.
            got = frame_stream.latest
            if got is None:
                return jsonify(error=str(e)), 503
            data, w, h = got
        resp = Response(data, mimetype="application/octet-stream")
        resp.headers["X-Format"] = "rgb555"
        resp.headers["X-Width"] = str(w)
        resp.headers["X-Height"] = str(h)
        resp.headers["X-Frame"] = str(frame_stream.count)
        return resp

    words = talk(link.read_block, VID_FB, FB_WORDS)
    frame = bytearray(b"".join(struct.pack("<I", w) for w in words))

    # Blank the rows the running machine does not draw.
    #
    # The framebuffer is 240 lines because that is what the NES needs. A Master
    # System fills 192 and a Mega Drive 224, and nothing clears what was there
    # before -- so the rows underneath keep whatever the last core, or the
    # power-up test pattern, left in them. On screen that is a band of colour
    # along the bottom of an otherwise black picture, which looks like the core
    # is broken and is really just a buffer nobody erased.
    #
    # Done here rather than in the fabric because the framebuffer is read-only
    # to the host -- a write to that page returns a bus error -- so clearing it
    # properly means an RTL change in every core. This costs one pass over
    # 61440 bytes on a frame that was already being copied.
    h = CONSOLE_HEIGHT.get(running_console(), FB_H)
    if h < FB_H:
        for i in range(h * FB_W, FB_H * FB_W):
            frame[i] = 0

    return Response(bytes(frame), mimetype="application/octet-stream")


# --- the console --------------------------------------------------------

NES = 0x0008_0000
NES_CTRL = NES + 0x04
NES_JOY1, NES_JOY2 = NES + 0x08, NES + 0x0C
NES_FRAME, NES_PC = NES + 0x10, NES + 0x14
NES_NMI = NES + 0x18
NES_MAPPER = NES + 0x1C
NES_CONSOLE = NES + 0x20         # which core is selected, and which are built
# Which 256 kB of the cartridge the write window points at, and the strobe that
# says the last word has been written.
#
# The window is four 64 kB pages and the tile memory sits immediately above it,
# so it cannot be widened. Writing a megabyte through one data register instead
# would be a UDP packet per four bytes -- forty times the traffic for the same
# cartridge -- so the window stays and the bank moves.
NES_CART_BANK = NES + 0x30
NES_FILL_END  = NES + 0x34
CART_BANK_BYTES = 256 * 1024
NES_Z80_PC = NES + 0x28
NES_PRG, NES_CHR = 0x0009_0000, 0x000D_0000

# What the running image can actually hold for each machine.
#
# The Mega Drive's cartridge is block RAM standing in for DDR3 (see
# rtl/md_cart.v), and it is small. Saying so up front is the difference between
# "this ROM is 1024 kB and the cartridge is 256" and a black screen.
# The NES and Master System share cart_mem's 256 kB program memory. The Mega
# Drive has md_cart instead, and MD_AW in console_top.v decides its size: 15 bits
# of 32-bit words is 128 kB. Raising it to 16 would cost another 29 block RAM
# tiles of the 37 spare and buy 256 kB, which is still nowhere near a real
# cartridge -- that needs the DDR3 controller, not a bigger slice of a part that
# has 600 kB in total.
# The Mega Drive's cartridge is in DDR3 now, so the limit is the machine's own:
# 4 MB is the largest cartridge one ever had. The other two still live in the
# block RAM they share.
CART_LIMIT = {0: 256 * 1024, 1: 256 * 1024, 2: 4 * 1024 * 1024, 3: 512 * 1024}
CONSOLE_NAMES = {0: "NES", 1: "Master System", 2: "Mega Drive", 3: "PlayStation"}


def cores_built():
    """Which machines are in the image that is currently running."""
    try:
        return (talk(link.read, NES_CONSOLE) >> 16) & 0xF
    except (fl.LinkError, TimeoutError):
        return 0


def is_megadrive(rom):
    """A Mega Drive cartridge says so at $100, in plain text.

    Every licensed cartridge and essentially all homebrew carries "SEGA" there
    -- "SEGA MEGA DRIVE" or "SEGA GENESIS" depending on the region it was sold
    in. There is no other header, so this is the identification.
    """
    return len(rom) > 0x110 and rom[0x100:0x104] == b"SEGA"

MAPPER_NAMES = {0: "NROM", 1: "MMC1", 2: "UxROM", 3: "CNROM", 4: "MMC3", 7: "AxROM"}


# --- the PlayStation's disc image, served to the ESP32 a range at a time ---------------
# The ESP32 has no card wired today, so the disc lives here: /api/disc/select names
# the .bin (raw 2352-byte sectors), /api/disc/image serves it with HTTP ranges, and
# the ESP32's disc task fetches runs of sectors ahead of what the drive asks for.
DISC = {"path": None, "size": 0}
DISC_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "disc.json")
# The selection outlives a restart: the ESP32 keeps fetching the image, and
# a server that came back with no disc selected left the console booting
# from an empty drive until somebody noticed.
try:
    _d = json.load(open(DISC_FILE))
    if _d.get("path") and os.path.isfile(_d["path"]):
        DISC["path"] = _d["path"]; DISC["size"] = os.path.getsize(_d["path"])
except (OSError, ValueError):
    pass

@app.route("/api/disc/select", methods=["POST"])
def api_disc_select():
    path = (request.get_json(silent=True) or {}).get("path") or request.args.get("path", "")
    if not path or not os.path.isfile(path):
        return jsonify(error="no such file", path=path), 404
    DISC["path"] = path
    DISC["size"] = os.path.getsize(path)
    try:
        json.dump({"path": path}, open(DISC_FILE, "w"))
    except OSError:
        pass
    return jsonify(ok=True, path=path, size=DISC["size"], sectors=DISC["size"] // 2352)

class HostDisc:
    """The PlayStation's disc straight from this PC, over the wired link.

    rtl/host_cd.v: ctrl 0x128 says what the drive wants {running, room, LBA},
    a 2352-byte raw sector goes into the window at ctrl 0x4000 by block write,
    and ctrl 0x12C commits it with its LBA. ctrl 0x130 = 3 hands the drive to
    the PC with a disc in. For when the ESP32 cannot: its SD card stopped
    answering on 2026-09-28, and its Wi-Fi disc path is known to lose a sector.

    A thread of its own, on a socket of its own, so the page and the tools do
    not wait behind it. It takes the drive back after the console is reset
    (a reset clears 0x130), and the choice survives a server restart.
    """

    CTRL = 0x0008_0000

    def __init__(self):
        self.on = False
        self.thread = None
        self.served = 0
        self.last_lba = None
        self.error = ""

    def start(self):
        self.on = True
        if self.thread is None or not self.thread.is_alive():
            self.thread = threading.Thread(target=self._run, daemon=True)
            self.thread.start()

    def stop(self):
        self.on = False

    def _run(self):
        L = fl.Link(link.addr[0], link.addr[1], timeout=0.03, retries=10)
        f = None; fpath = None; owned_at = 0.0
        while self.on:
            try:
                if DISC["path"] != fpath:
                    if f: f.close()
                    fpath = DISC["path"]; f = open(fpath, "rb") if fpath else None
                if time.time() - owned_at > 0.5:
                    if L.read(self.CTRL + 0x130) & 3 != 3:
                        L.write(self.CTRL + 0x130, 3 if f else 1)
                    owned_at = time.time()
                st = L.read(self.CTRL + 0x128)
                run, room, lba = st >> 31, (st >> 28) & 7, st & 0xFFFFFF
                if not (run and room and f):
                    time.sleep(0.001)
                    continue
                f.seek(lba * 2352)
                sec = f.read(2352)
                if len(sec) < 2352:
                    sec = sec.ljust(2352, bytes(1))
                L.write_block(self.CTRL + 0x4000, list(struct.unpack("<588I", sec)))
                L.write(self.CTRL + 0x12C, lba)
                self.served += 1; self.last_lba = lba; self.error = ""
            except fl.LinkError as e:
                self.error = str(e)
                time.sleep(0.01)
        try:
            L.write(self.CTRL + 0x130, 0)
        except fl.LinkError:
            pass


host_disc = HostDisc()


# --- the PlayStation's memory card -----------------------------------------------
CARD_LINE = 0x09_0000        # DDR3 line of the card's byte 0 (rtl/ps1_top.v)
CARD_BYTES = 128 * 1024
CARD_CTL = 0x0008_0000 + 0x134   # {fill aimed at the card, card in slot 1}
CARD_Q = 0x0008_0000 + 0x138     # {overflow, count[20:16], sector[9:0]}; write bit0 pops, bit31 clears overflow
CARD_FILE = os.environ.get("PS1_CARD", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                     "..", "saves", "card1.mcr"))


def blank_card():
    """A formatted, empty card, the way DuckStation formats one
    (MemoryCardImage::Format): the "MC" header frame, fifteen free directory
    frames, twenty empty broken-sector entries, and the header again in frame 63.
    Each of those frames ends in the XOR of its first 127 bytes."""
    d = bytearray(b"\xff" * CARD_BYTES)
    def frame(n, head=b"", chk=True):
        f = bytearray(128)
        f[:len(head)] = head
        if chk:
            c = 0
            for b in f[:127]:
                c ^= b
            f[127] = c
        d[n * 128:(n + 1) * 128] = f
    frame(0, b"MC")
    for n in range(1, 16):
        frame(n, b"\xa0\0\0\0\0\0\0\0\xff\xff")
    for n in range(16, 36):
        frame(n, b"\xff\xff\xff\xff\0\0\0\0\xff\xff")
    for n in range(36, 63):
        frame(n, chk=False)
    d[63 * 128:64 * 128] = d[0:128]
    return bytes(d)


class MemCard:
    """Memory card 1: a .mcr file here (raw 128 kB, the format DuckStation and
    most tools read), in DDR3 on the board while the console runs.

    The file goes into DDR3 whenever the BIOS does (ps1_load_bios), before the
    processor is let go. Every sector the console stores is queued on the board
    (ps1_sio.v); a thread of its own, on a socket of its own, reads each one back
    out of DDR3 and writes it into the file, so a save is on this disk within a
    fraction of a second of the game writing it. The first load of a session
    keeps a copy of the file as it was (.bak), in case something goes wrong.
    """

    def __init__(self):
        self.path = CARD_FILE
        self.lock = threading.Lock()        # the file, and loads against saves
        self.thread = None
        self.saved = 0
        self.error = ""
        self.backed_up = False

    def image(self):
        try:
            with open(self.path, "rb") as f:
                d = f.read()
            if len(d) == CARD_BYTES:
                return d
            self.error = "%s is %d bytes, not a 128 kB card image" % (self.path, len(d))
            return None
        except FileNotFoundError:
            os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
            d = blank_card()
            with open(self.path, "wb") as f:
                f.write(d)
            return d

    def load(self):
        """Put the file into DDR3 and the card in the slot, over the main link."""
        with self.lock:
            d = self.image()
            if d is None:
                talk(link.write, CARD_CTL, 0)
                return False
            if not self.backed_up:
                try:
                    with open(self.path + ".bak", "wb") as f:
                        f.write(d)
                    self.backed_up = True
                except OSError:
                    pass
            talk(link.write, CARD_CTL, 0b10)          # fill to the card, card out while it changes
            talk(link.write, NES_CART_BANK, 0)
            write_pages(NES_PRG, list(struct.unpack("<%dI" % (CARD_BYTES // 4), d)))
            talk(link.write, CARD_Q, 1 << 31)         # a fresh card owes the file nothing
            for _ in range(32):                       # nor does the one it replaces
                if not (talk(link.read, CARD_Q) >> 16) & 0x1F:
                    break
                talk(link.write, CARD_Q, 1)
            talk(link.write, CARD_CTL, 0b01)
            self.error = ""
        self.start()
        return True

    def start(self):
        if self.thread is None or not self.thread.is_alive():
            self.thread = threading.Thread(target=self._run, daemon=True)
            self.thread.start()

    def _line(self, L, line):
        L.write(NES + 0x7C, line)
        for _ in range(200):
            if L.read(NES + 0x7C) >> 31:
                return b"".join(struct.pack("<I", L.read(NES + 0x80 + 4 * k)) for k in range(4))
        raise fl.LinkError("DDR3 line %06x never came back" % line)

    def _run(self):
        L = fl.Link(link.addr[0], link.addr[1], timeout=0.05, retries=10)
        while True:
            time.sleep(0.05)
            try:
                q = L.read(CARD_Q)
                ovf, n, sec = q >> 31, (q >> 16) & 0x1F, q & 0x3FF
                if not (ovf or n):
                    continue
                with self.lock, hr_lock:
                    if ovf:
                        # more stored than the queue could hold: copy the whole card
                        d = b"".join(self._line(L, CARD_LINE + i) for i in range(CARD_BYTES // 16))
                        tmp = self.path + ".tmp"
                        with open(tmp, "wb") as f:
                            f.write(d)
                        os.replace(tmp, self.path)
                        L.write(CARD_Q, 1 << 31)
                        while (L.read(CARD_Q) >> 16) & 0x1F:
                            L.write(CARD_Q, 1)
                    else:
                        d = b"".join(self._line(L, CARD_LINE + sec * 8 + k) for k in range(8))
                        with open(self.path, "r+b") as f:
                            f.seek(sec * 128)
                            f.write(d)
                        L.write(CARD_Q, 1)
                    self.saved += 1
                    self.error = ""
            except (fl.LinkError, OSError) as e:
                self.error = str(e)
                time.sleep(0.5)


hr_lock = threading.Lock()       # ctrl 0x7C..0x8C, the one DDR3 line window
memcard = MemCard()


def ps1_load_bios(rom):
    """The BIOS into DDR3 and the console started, with the memory card in.
    The one way both the upload and the keepalive do it."""
    talk(link.write, NES_CTRL, 0)
    talk(link.write, NES_CONSOLE, 3)
    prg = rom.ljust((len(rom) + 3) // 4 * 4, b"\x00")
    talk(link.write, CARD_CTL, 0)               # the fill below is the BIOS's
    for bank, base in enumerate(range(0, len(prg), CART_BANK_BYTES)):
        chunk = prg[base:base + CART_BANK_BYTES]
        talk(link.write, NES_CART_BANK, bank)
        write_pages(NES_PRG, list(struct.unpack(f"<{len(chunk)//4}I", chunk)))
    talk(link.write, NES_FILL_END, 1)
    try:
        memcard.load()
    except (fl.LinkError, TimeoutError, OSError) as e:
        memcard.error = "card not loaded: %s" % e
    talk(link.write, VID_CTRL, 0b11)
    talk(link.write, NES_CTRL, 1)          # release the CPU from the reset vector


@app.route("/api/card/state")
def api_card_state():
    try:
        ctl = talk(link.read, CARD_CTL)
        q = talk(link.read, CARD_Q)
    except (fl.LinkError, TimeoutError):
        ctl = q = None
    return jsonify(path=os.path.abspath(memcard.path), exists=os.path.isfile(memcard.path),
                   inserted=None if ctl is None else bool(ctl & 1),
                   pending=None if q is None else (q >> 16) & 0x1F,
                   saved=memcard.saved, error=memcard.error)


@app.route("/api/card/select", methods=["POST"])
def api_card_select():
    """Use another card file (created blank if it does not exist). It goes in at
    the next BIOS load; {"now": true} swaps it in straight away, like pulling
    one card and pushing in another -- only safe while the game is not saving."""
    body = request.get_json(silent=True) or {}
    path = body.get("path", "")
    if not path.lower().endswith(".mcr"):
        return jsonify(error="a card file ends in .mcr"), 400
    with memcard.lock:
        memcard.path = path
        memcard.backed_up = False
    if body.get("now"):
        try:
            memcard.load()
        except (fl.LinkError, TimeoutError, OSError) as e:
            return jsonify(error=str(e)), 503
    return jsonify(ok=True, path=os.path.abspath(path))


@app.route("/api/disc/host", methods=["POST"])
def api_disc_host():
    on = bool((request.get_json(silent=True) or {}).get("on", request.args.get("on", "1") == "1"))
    if on: host_disc.start()
    else: host_disc.stop()
    try:
        d = json.load(open(DISC_FILE)) if os.path.isfile(DISC_FILE) else {}
        d["host"] = on
        json.dump(d, open(DISC_FILE, "w"))
    except (OSError, ValueError):
        pass
    return jsonify(ok=True, on=on)


@app.route("/api/disc/state")
def api_disc_state():
    return jsonify(path=DISC["path"], size=DISC["size"], sectors=DISC["size"] // 2352 if DISC["size"] else 0,
                   host=host_disc.on, served=host_disc.served, last_lba=host_disc.last_lba, error=host_disc.error)

@app.route("/api/disc/crc32")
def api_disc_crc32():
    """A CRC32 per megabyte of the image, so a copy of it elsewhere can be
    checked block by block and the bad blocks fetched again -- rather than
    trusting a byte count and finding out later that the disc will not read.

    Plain text so a microcontroller can parse it without a JSON library:
        <size>, then the block size, then the CRCs, one line each
    """
    if not DISC["path"]:
        return "no disc selected", 404
    block = max(65536, int(request.args.get("block", 1 << 20)))
    key = (DISC["path"], DISC["size"], block)
    if DISC.get("crc_key") != key:
        crcs = []
        with open(DISC["path"], "rb") as f:
            while True:
                chunk = f.read(block)
                if not chunk:
                    break
                crcs.append(zlib.crc32(chunk) & 0xFFFFFFFF)
        DISC["crc_key"], DISC["crcs"] = key, crcs
    body = "%d\n%d\n%s" % (DISC["size"], block, ",".join("%08x" % c for c in DISC["crcs"]))
    return Response(body, mimetype="text/plain")


@app.route("/api/disc/image", methods=["GET", "HEAD"])
def api_disc_image():
    if not DISC["path"]:
        return jsonify(error="no disc selected"), 404
    # conditional=True makes send_file honour Range requests; the range is logged
    # as sectors so the order the ESP32 fetched in can be read back later
    rng = request.headers.get("Range", "")
    if rng.startswith("bytes="):
        try:
            a, b = rng[6:].split("-"); print("disc range: sectors %d..%d" % (int(a) // 2352, int(b) // 2352), flush=True)
        except ValueError:
            pass
    return send_file(DISC["path"], mimetype="application/octet-stream", conditional=True)


@app.route("/api/nes/state")
def api_nes_state():
    ctrl = talk(link.read, NES_CTRL)
    # Two cores, two program counters. Reporting the 6502's while a Z80 is
    # running shows a number that never changes, which reads as "hung" when
    # nothing is wrong.
    con = talk(link.read, NES_CONSOLE)
    which = con & 0xF
    pc_reg = NES_Z80_PC if which == 1 else NES_PC
    pc = talk(link.read, pc_reg)
    # The 6502 and Z80 are 16-bit; the 68000 and R3000 are 32. Masking the wide
    # ones to 16 bits threw away most of the address and made a running PS1 look
    # like it was stuck in the bottom 64 kB.
    pc = pc & (0xFFFFFFFF if which in (2, 3) else 0xFFFF)
    built = (con >> 16) & 0xF
    return jsonify(
        id=talk(link.read, NES),
        running=bool(ctrl & 1),
        mirror_v=bool(ctrl & 2),
        frame=talk(link.read, NES_FRAME),
        pc=pc,
        console=which,
        console_name=CONSOLE_NAMES.get(which, f"core {which}"),
        built=[i for i in range(4) if built & (1 << i)],
        joy1=talk(link.read, NES_JOY1) & 0xFF,
    )


@app.route("/api/nes/config", methods=["POST"])
def api_nes_config():
    body = request.json or {}
    ctrl = talk(link.read, NES_CTRL)
    if "run" in body:
        ctrl = (ctrl & ~1) | (1 if body["run"] else 0)
    if "mirror_v" in body:
        ctrl = (ctrl & ~2) | (2 if body["mirror_v"] else 0)
    talk(link.write, NES_CTRL, ctrl)
    return jsonify(ok=True)


# The page sends one byte per pad in the NES's bit order, because that is the
# order it has always used and the one its bindings UI is written around:
#
#     0 a   1 b   2 select   3 start   4 up   5 down   6 left   7 right
#
# A Mega Drive pad is laid out differently -- md_top.v says so at its joy1 port:
#
#     0 up  1 down  2 left  3 right  4 B  5 C  6 A  7 start
#
# Nothing lines up. Sent untranslated, pressing Up sets bit 4, which the Mega
# Drive reads as B, and the game appears to ignore the controller entirely while
# doing something odd whenever you press a direction.
#
# Translating here rather than in the page keeps one bit order in the browser
# and gives every client the fix, including tools/playtest.py.
_NES_BITS = {"a": 0, "b": 1, "select": 2, "start": 3,
             "up": 4, "down": 5, "left": 6, "right": 7}
# a -> A and b -> B, with select standing in for the third face button.
_MD_BITS = {"up": 0, "down": 1, "left": 2, "right": 3,
            "b": 4, "select": 5, "a": 6, "start": 7}


# The PlayStation pad is a 16-bit word in the order the controller reports it
# (psx-spx, digital pad): 0 select, 3 start, 4 up, 5 right, 6 down, 7 left,
# 12 triangle, 13 circle, 14 cross, 15 square. The page's A is Cross (confirm)
# and B is Circle (back), as on the console's own menus.
_PS1_BITS = {"select": 0, "start": 3, "up": 4, "right": 5, "down": 6, "left": 7,
             "b": 13, "a": 14}


def pad_for_console(v, which):
    """Re-lay a NES-ordered pad byte for whichever machine is running."""
    if which == 2:
        table = _MD_BITS
    elif which == 3:
        table = _PS1_BITS
    else:                               # NES and Master System share the order
        return v & 0xFF
    out = 0
    for name, src in _NES_BITS.items():
        if v & (1 << src):
            out |= 1 << table[name]
    return out


@app.route("/api/nes/input", methods=["POST"])
def api_nes_input():
    body = request.json or {}
    which = talk(link.read, NES_CONSOLE) & 0xF
    if "joy1" in body:
        talk(link.write, NES_JOY1, pad_for_console(int(body["joy1"]), which))
    if "joy2" in body:
        talk(link.write, NES_JOY2, pad_for_console(int(body["joy2"]), which))
    return jsonify(ok=True)


def write_pages(base, words):
    """Fill a multi-page region. The page number is the top of the address, so
    the host side stays a plain linear write."""
    for i in range(0, len(words), 16384):
        talk(link.write_block, base + (i // 16384) * 0x0001_0000,
             words[i:i + 16384])


@app.route("/api/nes/load", methods=["POST"])
def api_nes_load():
    """Take a cartridge and start it.

    Which machine it is comes from the FILE, not from the user: an iNES header
    is self-announcing and anything else is a Master System ROM. Asking would be
    one more thing to get wrong about a question the bytes already answer.
    """
    rom = request.get_data()
    # Only enough to rule out a stray text file. The real floor differs per
    # machine and is checked in each branch below, because this test ran before
    # anything knew which machine the file was for -- and 1024 bytes, a sane
    # minimum for a NES or Master System cartridge, rejects a perfectly valid
    # Mega Drive one, which needs $200 bytes for its vectors and header and can
    # be legitimately tiny after that.
    if len(rom) < 512:
        return jsonify(error="that file is too small to be a cartridge"), 400

    # NOTHING is changed on the board until the cartridge has been checked.
    #
    # This used to reset the console here, before looking at the file at all, so
    # a cartridge that was then rejected -- wrong machine, too big -- left the
    # console stopped with the previous game still in it. Refusing to load
    # something should cost the player nothing; it used to cost them whatever
    # they were playing.
    if is_megadrive(rom):
        built = cores_built()
        if not (built & 0b100):
            return jsonify(error="this is a Mega Drive cartridge, and the core "
                                 "running on the board is not the Mega Drive. "
                                 "Install the md core first."), 409
        if len(rom) > CART_LIMIT[2]:
            return jsonify(error=f"this cartridge is {len(rom)//1024} kB and the "
                                 f"Mega Drive's cartridge memory is "
                                 f"{CART_LIMIT[2]//1024} kB. It is block RAM "
                                 f"standing in for DDR3; until the memory "
                                 f"controller exists, only ROMs this size or "
                                 f"smaller will run."), 413

        talk(link.write, NES_CTRL, 0)      # now it is safe to stop the machine
        prg = rom.ljust((len(rom) + 3) // 4 * 4, b"\x00")
        talk(link.write, NES_CONSOLE, 2)

        # A bank at a time. The window shows 256 kB of the cartridge; the bank
        # register says which 256 kB, so a 4 MB image is sixteen passes over the
        # same addresses rather than one impossible one.
        for bank, base in enumerate(range(0, len(prg), CART_BANK_BYTES)):
            chunk = prg[base:base + CART_BANK_BYTES]
            talk(link.write, NES_CART_BANK, bank)
            write_pages(NES_PRG, list(struct.unpack(f"<{len(chunk)//4}I", chunk)))

        # The last line of the cartridge is usually a partial one -- four host
        # words make a 128-bit line and few ROMs are a multiple of sixteen bytes
        # -- and without this it never leaves the gathering buffer. The tail of
        # a 68000 image is normally padding, so the symptom would be a machine
        # that works until something reads the very end of the cartridge.
        talk(link.write, NES_FILL_END, 1)

        talk(link.write, VID_CTRL, 0b11)
        talk(link.write, NES_CTRL, 1)
        name = rom[0x120:0x150].decode("ascii", "replace").strip()
        return jsonify(ok=True, console="Mega Drive", prg=len(prg), chr=0,
                       mapper=0, mapper_name=name or "Mega Drive",
                       mirror="n/a", signed=True)

    # --- PlayStation ---------------------------------------------------------
    # The BIOS carries no header the way an iNES or a Mega Drive file does, so
    # what makes a headerless file a PlayStation image is that the PlayStation is
    # the core on the board. One core per image: if the chip is a PlayStation and
    # the file is not plainly a NES cartridge, it is for the PlayStation.
    built = cores_built()
    if (built & 0b1000) and rom[:4] != b"NES" and not is_megadrive(rom):
        if len(rom) > CART_LIMIT[3]:
            return jsonify(error=f"this file is {len(rom)//1024} kB; the "
                                 f"PlayStation BIOS region is "
                                 f"{CART_LIMIT[3]//1024} kB."), 413
        # The BIOS loads into DDR3 the same way a Mega Drive cartridge does:
        # 256 kB banks through the fill window, then the end strobe, then run.
        # The memory card goes in with it.
        ps1_load_bios(rom)
        prg = rom.ljust((len(rom) + 3) // 4 * 4, b"\x00")
        return jsonify(ok=True, console="PlayStation", prg=len(prg), chr=0,
                       mapper=0, mapper_name="BIOS", mirror="n/a", signed=True)

    # The same courtesy the Mega Drive branch gets, for the other two.
    #
    # A single-core image is the normal case now -- the whole point of the shell
    # is that a core gets the entire chip rather than sharing it -- so "this
    # cartridge needs a machine this bitstream does not contain" is the ordinary
    # result of dragging the wrong file in, not an edge case worth skipping.
    #
    # Without this the load looks like it worked. The cartridge is written, the
    # CONSOLE register refuses the switch in hardware (which is correct, and why
    # nothing crashes), and whichever machine IS built sits there running a ROM
    # meant for a different one. The player gets a black screen and the API says
    # ok:true -- the least helpful pair of answers available.
    built = cores_built()
    if rom[:4] == b"NES":
        if not (built & 0b001):
            return jsonify(error="this is a NES cartridge, and the core running "
                                 "on the board is not the NES. Install the nes "
                                 "core first."), 409
    elif len(rom) >= 1024 and not (built & 0b010):
        # Size first: below that the file is not a Master System cartridge at
        # all, and "too small" further down is the more useful complaint.
        return jsonify(error="this is a Master System cartridge, and the core "
                             "running on the board is not the Master System. "
                             "Install the sms core first."), 409

    talk(link.write, NES_CTRL, 0)          # held in reset while the cart changes

    if rom[:4] == b"NES\x1a":
        prg_banks, chr_banks = rom[4], rom[5]
        mirror_v = bool(rom[6] & 1)
        mapper = (rom[6] >> 4) | (rom[7] & 0xF0)
        prg = rom[16:16 + prg_banks * 16384]
        if prg_banks == 1:
            prg = prg + prg                # a 16 kB cart appears in both halves
        chr_ = rom[16 + prg_banks * 16384:][:chr_banks * 8192]
        chr_is_ram = not chr_
        if chr_is_ram:
            chr_ = bytes(8192)

        # Pad to whole words; do not truncate -- an MMC3 cartridge is many times
        # bigger than the window the CPU sees.
        prg = prg.ljust((len(prg) + 3) // 4 * 4, b"\x00")
        chr_ = chr_.ljust((len(chr_) + 3) // 4 * 4, b"\x00")
        prg_last = max(len(prg) // 8192 - 1, 0)

        write_pages(NES_PRG, list(struct.unpack(f"<{len(prg)//4}I", prg)))
        write_pages(NES_CHR, list(struct.unpack(f"<{len(chr_)//4}I", chr_)))

        talk(link.write, NES_MAPPER,
             (mapper & 0xF) | (prg_last << 8) | (0x4000 if chr_is_ram else 0))
        talk(link.write, NES_CONSOLE, 0)
        talk(link.write, VID_CTRL, 0b11)
        talk(link.write, NES_CTRL, 1 | (2 if mirror_v else 0))

        return jsonify(ok=True, console="NES", prg=len(prg), chr=len(chr_),
                       mapper=mapper, mapper_name=MAPPER_NAMES.get(mapper),
                       mirror="vertical" if mirror_v else "horizontal",
                       signed=True)

    # Anything else is a Master System cartridge. There is no header to read, so
    # the size is all there is to go on, and the Sega mapper is the only one.
    if len(rom) < 1024:
        return jsonify(error="that file is too small to be a Master System "
                             "cartridge, and it carries neither an iNES header "
                             "nor a Mega Drive one"), 400
    prg = rom.ljust((len(rom) + 3) // 4 * 4, b"\x00")
    write_pages(NES_PRG, list(struct.unpack(f"<{len(prg)//4}I", prg)))
    talk(link.write, NES_CONSOLE, 1)
    talk(link.write, VID_CTRL, 0b11)
    talk(link.write, NES_CTRL, 1)
    return jsonify(ok=True, console="Master System", prg=len(prg), chr=0,
                   mapper=0, mapper_name="Sega", mirror="n/a", signed=True)


@app.route("/api/nes/console", methods=["GET", "POST"])
def api_nes_console():
    if request.method == "POST":
        talk(link.write, NES_CONSOLE, int((request.json or {})["console"]) & 0xF)
    v = talk(link.read, NES_CONSOLE)
    sel = v & 0xF
    # Which cores this bitstream actually contains, read rather than assumed: a
    # build without a given core reports that honestly instead of selecting it
    # and showing a black screen.
    built_mask = (v >> 16) & 0xF
    return jsonify(console=sel, name=CONSOLE_NAMES.get(sel, f"core {sel}"),
                   built=[i for i in range(4) if built_mask & (1 << i)],
                   names={str(k): n for k, n in CONSOLE_NAMES.items()})


@app.route("/api/nes/reset", methods=["POST"])
def api_nes_reset():
    ctrl = talk(link.read, NES_CTRL)
    talk(link.write, NES_CTRL, ctrl & ~1)
    time.sleep(0.05)
    talk(link.write, NES_CTRL, ctrl | 1)
    return jsonify(ok=True)


# --- the shell ----------------------------------------------------------
# When the board is running the golden image rather than a console, the register
# map is a different one entirely. The page at 0 answers "SHEL" instead of "NE",
# which is how the UI knows which of the two it is looking at without being told.

SHELL_ID, SHELL_VERSION = 0x0000_0000, 0x0000_0004
SHELL_STATUS, SHELL_CTRL, SHELL_BOOT = 0x0000_0008, 0x0000_0010, 0x0000_0018
SHELL_BUF = 0x0001_0000
# One core slot, and it is everything the shell is not using: $200000 to the top
# of an 8 MB flash. Three smaller slots would let cores sit resident and switch
# instantly, which saves about thirty seconds and costs slot allocation,
# eviction, and a page that has to explain which core is in which numbered hole.
SLOT_SIZE = 6 * 1024 * 1024
CORES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cores")

SYNC_WORD = bytes([0xAA, 0x99, 0x55, 0x66])

# One install at a time, and somewhere for the page to read progress from while
# it happens. A flash install is the better part of a minute; an HTTP request
# that simply blocked for that long would look like a hang and time out in most
# browsers.
install_state = {"busy": False, "stage": "", "done": 0, "total": 0, "error": "",
                 # The last thing Vivado said, and how long it has been going.
                 # Erasing eight megabytes takes a minute and a half during which
                 # a fixed label looks exactly like a hang; a line that keeps
                 # changing is the difference between waiting and worrying.
                 "line": "", "elapsed": 0}
install_lock = threading.Lock()


def shell_here():
    """Is the board running the shell, or a console? Ask it rather than guess.

    Goes through the same cheap, cached probe the status page uses, so a board
    that is not there costs a quarter of a second to rule out instead of four.
    """
    return what_is_running() == "shell"


def core_files():
    """The machines that can go in the slot.

    The shell's own bitstream lives in cores/ too, because that is where the
    build puts things, but it is not a machine you can install: every install
    writes it to address zero anyway, and putting a second copy in the core slot
    would give you a "start the core" button that returns you to the shell.
    """
    out = []
    if os.path.isdir(CORES_DIR):
        for n in sorted(os.listdir(CORES_DIR)):
            if n.endswith(".bin") and n != "shell.bin":
                out.append({"name": n[:-4],
                            "size": os.path.getsize(os.path.join(CORES_DIR, n))})
    return out


def shell_ctrl(op, offset=0):
    """Everything a flash operation needs, in one word: one packet per page."""
    return (op & 3) | ((offset & 0x7FFFFF) << 4)


def shell_wait(timeout=180.0):
    t0 = time.time()
    while talk(link.read, SHELL_STATUS) & 1:
        if time.time() - t0 > timeout:
            raise TimeoutError("the flash did not finish")
        time.sleep(0.001)


def shell_read_page(offset):
    talk(link.write, SHELL_CTRL, shell_ctrl(3, offset))
    shell_wait(5.0)
    words = talk(link.read_block, SHELL_BUF, 64)
    return b"".join(struct.pack("<I", w) for w in words)


SLOT_BASE = 0x20_0000           # where a core lives; see SLOT_BASE in shell_flash.v


def core_installed():
    # A configuration image opens with padding and then the sync word. Looking
    # for it asks the flash what is actually there, rather than trusting a note
    # kept somewhere else that could disagree with it.
    #
    # At the SLOT, not at zero. Reads take an absolute flash address -- erases
    # and programs are slot-relative, reads deliberately are not -- so asking
    # for page 0 was asking whether the SHELL was installed, which it always is.
    # This answered "yes, a core is installed" on a board with an empty slot.
    return SYNC_WORD in shell_read_page(SLOT_BASE)


CONSOLE_ID = 0x4650_4741        # "FPGA", what a console core answers with

# The last verdict and when it was reached.
#
# A board that is not there costs four seconds to establish -- four retries of a
# one-second UDP timeout -- and every one of those seconds is spent holding the
# bus lock, so the whole page stalls behind it. The page polls this twice a
# second. Without a cache, one unplugged board makes the entire UI unusable
# rather than merely showing bad news.
_verdict = {"what": "offline", "at": 0.0}
OFFLINE_RETRY_S = 2.0           # how often to re-ask a board that is not answering


def board_is_gone():
    """Has the board recently failed to answer? Cheap; no bus traffic."""
    return (_verdict["what"] == "offline"
            and time.time() - _verdict["at"] < OFFLINE_RETRY_S)


def note_gone():
    _verdict.update(what="offline", at=time.time())


def what_is_running():
    """Shell, console, or nothing -- asked rather than remembered.

    Asked cheaply: one try, a short timeout. A board that is going to answer
    answers in well under a millisecond, so waiting longer only makes a dead
    board more expensive, never a live one more likely to be found.
    """
    if install_state["busy"]:
        return "busy"

    if board_is_gone():
        return "offline"

    try:
        with link_lock:
            was_r, was_t = link.retries, link.sock.gettimeout()
            # Three tries at 150 ms. A board that is there replies in about one
            # millisecond, so this is 450 ms spent only on a board that is not --
            # while still surviving a dropped datagram, which one try did not.
            link.retries = 3
            link.sock.settimeout(0.15)
            try:
                v = link.read(SHELL_ID)
            finally:
                link.retries = was_r
                link.sock.settimeout(was_t)
    except (fl.LinkError, TimeoutError, OSError):
        note_gone()
        return "offline"

    what = ("shell" if v == 0x5348_454C
            else "console" if v == CONSOLE_ID
            else "unknown")
    _verdict.update(what=what, at=time.time())
    return what


def note_here():
    """Something answered, so the board is present whatever it is."""
    if _verdict["what"] == "offline":
        _verdict.update(what="unknown", at=0.0)


@app.route("/api/shell/state")
def api_shell_state():
    running = what_is_running()
    here = running == "shell"
    installed = None
    # Only the shell can be asked what is in the slot, and only when its flash
    # engine is idle. A console core is itself the answer.
    if here:
        try:
            installed = core_installed()
        except (fl.LinkError, TimeoutError):
            installed = None
    elif running == "console":
        installed = True
    version, busy = 0, False
    if here:
        # Only ask these of a board that just answered; a core has neither
        # register, and a board that has gone away between one read and the next
        # should not turn a status page into a timeout.
        try:
            version = talk(link.read, SHELL_VERSION)
            busy = bool(talk(link.read, SHELL_STATUS) & 1)
        except (fl.LinkError, TimeoutError):
            running, here = "offline", False
    return jsonify(
        running=running,
        shell=here,
        version=version,
        busy=busy,
        installed=installed,
        cores=core_files(),
        install=dict(install_state),
    )


def install_worker(path):
    try:
        data = open(path, "rb").read()
        if len(data) > SLOT_SIZE:
            install_state["error"] = f"{len(data)//1024} kB does not fit the slot"
            return
        # Only the sectors this image will occupy. Erasing all 6 MB takes three
        # minutes, most of it clearing space nothing is about to use.
        sectors = (len(data) + 65535) // 65536
        install_state.update(stage="erasing", done=0, total=sectors, error="")
        for i in range(sectors):
            talk(link.write, SHELL_CTRL, shell_ctrl(1, i * 65536))
            shell_wait(10.0)
            install_state["done"] = i + 1

        pages = (len(data) + 255) // 256
        install_state.update(stage="writing", total=pages)
        for i in range(pages):
            chunk = data[i * 256:(i + 1) * 256].ljust(256, b"\xFF")
            talk(link.write_block, SHELL_BUF, list(struct.unpack("<64I", chunk)))
            talk(link.write, SHELL_CTRL, shell_ctrl(2, i * 256))
            shell_wait(5.0)
            install_state["done"] = i + 1

        # Verified, always, and before anything is allowed to boot it. A core
        # that half wrote and a core that is fine look identical right up until
        # the moment the board tries to configure from it.
        install_state.update(stage="verifying", done=0)
        for i in range(pages):
            want = data[i * 256:(i + 1) * 256].ljust(256, b"\xFF")
            if shell_read_page(i * 256) != want:
                install_state["error"] = f"page {i} does not match what was written"
                return
            install_state["done"] = i + 1
        install_state["stage"] = "done"
    except Exception as e:
        install_state["error"] = str(e)
    finally:
        install_state["busy"] = False


# --- installing over JTAG ------------------------------------------------------
# The shell can write the flash itself, and for most of a day it could not: the
# controller deasserted chip select for twenty nanoseconds between a write
# enable and the command it enabled, the part wants fifty, and so every write
# was quietly refused. That is fixed in rtl/spi_flash.v, but the path this
# server uses to INSTALL a core does not have to depend on it -- Vivado can
# write the flash over JTAG, and that works whatever the shell is doing.
#
# So installing is done over the cable. It is slower to start, because Vivado
# takes a few seconds to load, and it cannot fail halfway leaving a board that
# will not boot.


def find_vivado():
    if os.environ.get("VIVADO"):
        return os.environ["VIVADO"]
    for pat in (r"C:\AMDDesignTools\*\Vivado\bin\vivado.bat",
                r"C:\Xilinx\Vivado\*\bin\vivado.bat",
                "/opt/Xilinx/Vivado/*/bin/vivado",
                "/tools/Xilinx/Vivado/*/bin/vivado"):
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[-1]
    return None


SHELL_BIT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                         "build", "shell_top", "shell_top.bit")


def jtag_script(core_path):
    """An image with the shell at the bottom and the core in its slot.

    Both are written together on purpose. Writing only the slot would leave the
    board bootable, but a half-erased shell is a board that needs a cable and a
    person, and the whole point of this is that it cannot end there.

    Built with plain substitution rather than an f-string: this is Tcl, every
    other line has braces in it, and doubling them all to escape them is how the
    braces end up in the output.
    """
    mcs = os.path.join(tempfile.gettempdir(), "console_install.mcs")
    fwd = lambda q: os.path.abspath(q).replace("\\", "/")
    tcl = """
write_cfgmem -force -format MCS -interface SPIx1 -size 8 -loadbit {up 0x00000000 @BIT@} -loaddata {up 0x00200000 @CORE@} -file @MCS@
open_hw_manager
connect_hw_server -quiet
open_hw_target
set d [lindex [get_hw_devices] 0]
current_hw_device $d
set part {}
foreach p [get_cfgmem_parts n25q64-3.3v-spi-x1_x2_x4] {
  if {[string match -nocase "*artix7*" [get_property COMPATIBLE_PARTS $p]]} {
    set part $p
    break
  }
}
create_hw_cfgmem -hw_device $d $part
set cm [get_property PROGRAM.HW_CFGMEM $d]
set_property PROGRAM.FILES [list {@MCS@}] $cm
set_property PROGRAM.ADDRESS_RANGE {use_file} $cm
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cm
set_property PROGRAM.BLANK_CHECK 0 $cm
set_property PROGRAM.ERASE 1 $cm
set_property PROGRAM.CFG_PROGRAM 1 $cm
set_property PROGRAM.VERIFY 1 $cm
create_hw_bitstream -hw_device $d [get_property PROGRAM.HW_CFGMEM_BITFILE $d]
program_hw_devices $d
program_hw_cfgmem -hw_cfgmem $cm
# Programming the flash leaves Vivado's own flash-programmer bitstream loaded in
# the chip, so at this point the board is answering as nothing at all. Reload it
# from the flash we just wrote, which lands in the shell -- an install that ends
# with a dark board looks exactly like an install that failed.
boot_hw_device $d
puts "INSTALL-OK"
"""
    tcl = (tcl.replace("@BIT@", fwd(SHELL_BIT))
              .replace("@CORE@", fwd(core_path))
              .replace("@MCS@", fwd(mcs)))
    return mcs, tcl


VIVADO_LOG = os.path.join(tempfile.gettempdir(), "console_install.log")


def run_vivado(tcl, on_line):
    viv = find_vivado()
    if not viv:
        raise RuntimeError("Vivado was not found; set the VIVADO environment "
                           "variable to its vivado.bat")
    path = os.path.join(tempfile.gettempdir(), "console_install.tcl")
    with open(path, "w") as f:
        f.write(tcl)
    proc = subprocess.Popen([viv, "-mode", "batch", "-nolog", "-nojournal",
                             "-source", path],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1)
    ok = False
    # Kept on disk as well: when an install goes wrong the one thing worth having
    # is what the tool actually said, and by then the process is gone.
    with open(VIVADO_LOG, "w") as log:
        for line in proc.stdout:
            line = line.rstrip()
            log.write(line + chr(10))
            log.flush()
            if "INSTALL-OK" in line:
                ok = True
            on_line(line)
    proc.wait()
    return ok


def jtag_install_worker(path, name):
    try:
        if not os.path.isfile(SHELL_BIT):
            install_state["error"] = ("build/shell_top/shell_top.bit is missing "
                                      "-- run tools/core.sh shell first")
            return
        mcs, tcl = jtag_script(path)
        install_state.update(stage="starting Vivado", done=0, total=4, error="")

        # Vivado says what it is doing; the UI should say the same thing rather
        # than a spinner that means nothing.
        t0 = time.time()

        def watch(line):
            low = line.lower()
            install_state["elapsed"] = int(time.time() - t0)
            # Anything Vivado says that is not noise is worth showing verbatim.
            # Guessing at its phrasing is how the stage label got stuck on
            # "erasing" for ninety seconds of an install that was going fine.
            if line.strip() and not low.startswith(("#", "****", "  ****")):
                install_state["line"] = line.strip()[:120]
            if "erase operation" in low:
                install_state.update(stage="erasing the flash", done=1)
            elif "program and verify" in low:
                install_state.update(stage="writing and verifying", done=2)
            elif "program operation" in low or "programming" in low:
                install_state.update(stage="writing the flash", done=2)
            elif "verify operation" in low or "verifying" in low:
                install_state.update(stage="verifying", done=3)
            elif "flash programming completed" in low:
                install_state.update(stage="restarting the board", done=3)
            elif low.startswith("error"):
                install_state["error"] = line.strip()

        if run_vivado(tcl, watch):
            install_state.update(stage="done", done=4)
        elif not install_state["error"]:
            install_state["error"] = "Vivado finished without programming the flash"
    except Exception as e:
        install_state["error"] = str(e)
    finally:
        install_state["busy"] = False


def jtag_boot_worker(which):
    """Reload the FPGA from flash over the cable.

    This is the only way back to the shell once a core is running: a core has no
    register that reconfigures the board, so from inside one there is nothing to
    ask. The cable can always do it."""
    try:
        install_state.update(stage="rebooting the board", done=0, total=1, error="")
        tcl = '''
open_hw_manager
connect_hw_server -quiet
open_hw_target
set d [lindex [get_hw_devices] 0]
current_hw_device $d
boot_hw_device $d
puts "INSTALL-OK"
'''
        if run_vivado(tcl, lambda l: None):
            install_state.update(stage="done", done=1)
        else:
            install_state["error"] = "the board did not reload"
    except Exception as e:
        install_state["error"] = str(e)
    finally:
        install_state["busy"] = False


@app.route("/api/shell/reboot", methods=["POST"])
def api_shell_reboot():
    """Back to the shell, from wherever the board currently is."""
    with install_lock:
        if install_state["busy"]:
            return jsonify(error="something is already running"), 409
        install_state.update(busy=True, stage="starting", done=0, total=1, error="")
    threading.Thread(target=jtag_boot_worker, args=(0,), daemon=True).start()
    return jsonify(ok=True)


@app.route("/api/shell/install", methods=["POST"])
def api_shell_install():
    # Deliberately NOT requiring the shell to be running. Installing goes over
    # the cable, so it works from a core as well -- and a board sitting in a core
    # is exactly when somebody wants to change which one.
    with install_lock:
        if install_state["busy"]:
            return jsonify(error="an install is already running"), 409
        body = request.json or {}
        name = os.path.basename(str(body.get("core", "")))
        path = os.path.join(CORES_DIR, name + ".bin")
        if not os.path.isfile(path):
            return jsonify(error=f"no such core: {name}"), 404
        install_state.update(busy=True, stage="starting", done=0, total=0, error="")
    threading.Thread(target=jtag_install_worker, args=(path, name),
                     daemon=True).start()
    return jsonify(ok=True)


@app.route("/api/shell/boot", methods=["POST"])
def api_shell_boot():
    if not shell_here():
        return jsonify(error="the board is not running the shell"), 409
    # 0 is back here, 1 is the core. There is nowhere else to go.
    which = 1 if (request.json or {}).get("core") else 0
    # No reply is possible past this point: the chip stops being the thing that
    # was listening, about half a microsecond later. So the write times out, and
    # the timeout IS the success -- reporting it as a failure told the user the
    # core had not started while they were looking at it running.
    try:
        talk(link.write, SHELL_BOOT, 0xB007_0000 | which)
    except (fl.LinkTimeout, TimeoutError):
        pass
    note_gone()        # it is reconfiguring; do not ask it anything for a moment
    return jsonify(ok=True)


# --- the ESP32, seen from this page ------------------------------------------------
#
# The ESP is a second web server on a second address, and having to know that is
# a worse experience than it needs to be. Everything it offers -- the card, the
# core library, the games, installing, booting, the way back to the shell --
# is proxied through here so there is ONE page.
#
# Proxied rather than reimplemented: the ESP owns the SD card and the SPI link to
# the board, and this end owns video and the register bus. Duplicating either
# side's logic here would give two things that have to agree about the state of a
# third, which is how they come to disagree.

ESP_HOST = os.environ.get("ESP_HOST", "")     # found automatically; see below
ESP_TIMEOUT = 8.0
_esp = {"host": "", "at": 0.0}


def esp_host():
    """Where the ESP is, remembered briefly.

    It is on the house network by DHCP, so the address can move. The board's own
    address is fixed and the ESP's is not, which is the wrong way round and the
    reason this looks it up rather than being told once.
    """
    if ESP_HOST:
        return ESP_HOST
    if _esp["host"] and time.time() - _esp["at"] < 60:
        return _esp["host"]
    return _esp["host"]


def esp_call(path, method="GET", body=None, ctype=None, timeout=ESP_TIMEOUT):
    host = esp_host()
    if not host:
        raise RuntimeError("the ESP32 has not been found on the network yet")
    url = f"http://{host}{path}"
    req = urllib.request.Request(url, data=body, method=method)
    if ctype:
        req.add_header("Content-Type", ctype)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read()


def esp_probe(host):
    """Is the ESP at this address? Its state reply is its own fingerprint."""
    try:
        with urllib.request.urlopen(f"http://{host}/api/state", timeout=0.6) as r:
            d = json.loads(r.read().decode("utf-8", "replace"))
            return isinstance(d, dict) and "cardWhy" in d and "ap" in d
    except Exception:
        return False


def esp_find(seed):
    """Look for it on the same network as the board.

    The board has a fixed address and the ESP gets one from DHCP, so the thing
    that moves is the thing that has to be found. Scanning a /24 with a short
    timeout takes a couple of seconds and saves making the user look it up on a
    router's admin page.
    """
    net = seed.rsplit(".", 1)[0]
    hosts = [f"{net}.{i}" for i in range(1, 255)]
    hosts.insert(0, "192.168.4.1")          # its own access point, if we are on it
    found = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
        for host, ok in zip(hosts, pool.map(esp_probe, hosts)):
            if ok:
                found.append(host)
    return found


@app.route("/api/esp/find", methods=["POST"])
def api_esp_find():
    seed = request.args.get("near") or link.addr[0]
    found = esp_find(seed)
    if found:
        _esp.update(host=found[0], at=time.time())
    return jsonify(found=found, host=esp_host())


@app.route("/api/esp/host", methods=["GET", "POST"])
def api_esp_host():
    """Tell this page where the ESP is, or ask it."""
    if request.method == "POST":
        host = str((request.json or {}).get("host", "")).strip()
        _esp.update(host=host, at=time.time())
    return jsonify(host=esp_host())


@app.route("/api/esp/state")
def api_esp_state():
    try:
        code, body = esp_call("/api/state", timeout=4.0)
        return app.response_class(body, status=code, mimetype="application/json")
    except Exception as e:
        return jsonify(error=str(e), host=esp_host()), 503


@app.route("/api/esp/<path:rest>", methods=["POST"])
def api_esp_post(rest):
    """Anything the ESP's page can do, done from this one.

    The path is passed straight through and the body with it, so a new endpoint
    on the ESP works here the day it is added rather than needing a matching
    change on this side.
    """
    allowed = {"install", "boot", "shell", "library", "roms", "forget", "join"}
    head = rest.split("?")[0].split("/")[0]
    if head not in allowed:
        return jsonify(error=f"not something the ESP is asked to do: {head}"), 400
    try:
        q = request.query_string.decode()
        code, body = esp_call(f"/api/{rest}" + (f"?{q}" if q else ""),
                              method="POST",
                              body=request.get_data() or None,
                              ctype=request.headers.get("Content-Type"),
                              timeout=300.0)
        return app.response_class(body, status=code, mimetype="text/plain")
    except Exception as e:
        return jsonify(error=str(e)), 503


@app.route("/api/esp/rom")
def api_esp_rom():
    """Fetch a game off the card and load it into the running console.

    This is the join between the two halves: the card holds the library, the
    register bus is the only thing fast enough to fill a cartridge, and neither
    end can do it alone.
    """
    name = request.args.get("name", "")
    try:
        code, rom = esp_call(f"/api/rom?name={urllib.parse.quote(name)}",
                             timeout=120.0)
    except Exception as e:
        return jsonify(error=str(e)), 503
    if code != 200:
        return jsonify(error=rom.decode("utf-8", "replace")), code
    with app.test_request_context("/api/nes/load", method="POST", data=rom):
        return api_nes_load()


# --- keeping the PlayStation alive across resets ----------------------------------
#
# The ESP32 reboots whenever it is reflashed or asked to reload the FPGA, and a
# reload empties DDR3 -- the BIOS with it. The board then sits there doing
# nothing, which from the outside looks like the console has died. This notices
# that the console is up without its BIOS and puts it back, then asks the ESP32
# to put the disc back in. It never touches a machine that is running.
# your own dump of a PlayStation BIOS (e.g. SCPH1001.BIN); the keepalive below
# puts it back after a console reset. Unset: no keepalive.
PS1_BIOS = os.environ.get("PS1_BIOS", "")
BIOS_LINE = 0x30000                      # where the BIOS sits in DDR3, in 16-byte lines

def _ddr_word(line):
    with hr_lock:
        talk(link.write, NES + 0x7C, line)
        for _ in range(60):
            if talk(link.read, NES + 0x7C) >> 31:
                break
        return talk(link.read, NES + 0x80)

def _bios_is_there(first_word):
    try:
        return _ddr_word(BIOS_LINE) == first_word
    except Exception:
        return True                      # cannot tell: leave it alone

KEEPALIVE_ON = os.environ.get("PS1_KEEPALIVE", "1") != "0"

def _keepalive():
    if not KEEPALIVE_ON:
        return                      # a test image is being run by hand; do not fight it
    try:
        with open(PS1_BIOS, "rb") as f:
            first = struct.unpack("<I", f.read(4))[0]
            f.seek(0); rom = f.read()
    except OSError:
        return
    while True:
        time.sleep(6.0)
        try:
            if board_is_gone() or running_console() != 3:
                continue
            if _bios_is_there(first):
                continue
            app.logger.info("PlayStation has no BIOS (a reset emptied it): putting it back")
            # the same path /api/nes/load takes, card and all
            ps1_load_bios(rom)
            if ESP_HOST:
                try:
                    urllib.request.urlopen(urllib.request.Request(
                        "http://%s/api/disc?path=%s" % (ESP_HOST, DISC_ON_CARD), method="POST"), timeout=8).read()
                except Exception:
                    pass
        except Exception as e:
            app.logger.info("keepalive: %s", e)

ESP_HOST = os.environ.get("ESP_HOST", "192.168.178.94")
DISC_ON_CARD = os.environ.get("DISC_ON_CARD", "/discs/disc.bin")   # the image on the ESP32's SD card


def main():
    global link
    ap = argparse.ArgumentParser(description="Web debugger for the fpgalink bus")
    ap.add_argument("--target", default="127.0.0.1",
                    help="FPGA address (default: localhost, i.e. mock_fpga.py)")
    ap.add_argument("--target-port", type=int, default=fl.DEFAULT_PORT)
    ap.add_argument("--host", default="127.0.0.1", help="where to serve the UI")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--esp", default="",
                    help="the ESP32's address; found automatically if omitted")
    args = ap.parse_args()

    # A board on the far end of a switch answers in well under a millisecond.
    # Four one-second retries only made an absent board four seconds expensive.
    link = fl.Link(args.target, args.target_port, timeout=0.25, retries=3)
    try:
        if json.load(open(DISC_FILE)).get("host"):
            host_disc.start()
    except (OSError, ValueError):
        pass

    # Look for the ESP in the background: it is a convenience, and the page has
    # to come up whether or not it is there.
    if args.esp:
        _esp.update(host=args.esp, at=time.time())
    else:
        def look():
            found = esp_find(args.target)
            if found:
                _esp.update(host=found[0], at=time.time())
                print(f"ESP32:      http://{found[0]}")
            else:
                print("ESP32:      not found on this network")
        threading.Thread(target=look, daemon=True).start()
    print(f"bus target: {args.target}:{args.target_port}")
    print(f"UI:         http://{args.host}:{args.port}")
    threading.Thread(target=_keepalive, daemon=True).start()
    app.run(host=args.host, port=args.port, threaded=True)


if __name__ == "__main__":
    main()
