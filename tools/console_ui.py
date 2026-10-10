"""console_ui.py - the console, from this PC: what is on the board, the flash and the card, and
the jobs that change them, each one checked.

    python tools/console_ui.py            then open http://localhost:8765

- Status: the ESP32 (Wi-Fi, the card), the FPGA (which console is running).
- Cores: the newest image built here for each console, what the card holds; "Put on the card"
  sends it, "Install" puts the card's image into the flash slot for good (shell, install,
  boot, and checks the console came up).
- Games: what is in Downloads (zip, bin/cue, z64, sfc, ...); "Add" unpacks and sends it to the
  console's folder on the card.

Files go to the card a piece at a time (the ESP32's /api/put), each piece checked by CRC against
what was sent, a failed piece sent again, and a stopped copy carried on from where it got to.
Nothing here loads anything over JTAG: what this puts on the board stays there.
ESP_IP picks the board (default 192.168.178.12).
"""
import glob, http.client, http.server, json, os, threading, time, urllib.parse, uuid, zipfile, zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
ESP = os.environ.get('ESP_IP', '192.168.178.12')
PORT = 8765
CHUNK = 2 * 1024 * 1024
DOWNLOADS = os.path.join(os.path.expanduser('~'), 'Downloads')
UNPACK = os.path.join(ROOT, 'build', 'games_new')

# the menu's consoles (esp32/console/menu.h MACHINES): folder/core name, status id, name
CONSOLES = [('nes', 78, 'NES'), ('sms', 83, 'Master System'), ('md', 77, 'Mega Drive'),
            ('n64', 54, 'Nintendo 64'), ('ps1', 80, 'PlayStation'), ('snes', 70, 'Super NES')]
CORE_NAME = {cid: name for _, cid, name in CONSOLES}
CORE_NAME[0] = 'the shell (no console running)'
EXT = {'.cue': 'ps1', '.iso': 'ps1', '.z64': 'n64', '.n64': 'n64', '.v64': 'n64', '.sfc': 'snes',
       '.smc': 'snes', '.md': 'md', '.gen': 'md', '.smd': 'md', '.nes': 'nes', '.sms': 'sms'}

# --- the ESP32 --------------------------------------------------------------------------------
def esp_get(path, timeout=10):
    c = http.client.HTTPConnection(ESP, timeout=timeout)
    c.request('GET', path)
    r = c.getresponse()
    body = r.read().decode('utf-8', 'replace')
    if r.status != 200:
        raise IOError('%s: HTTP %d %s' % (path, r.status, body[:200]))
    return json.loads(body) if body[:1] in '{[' else body

def esp_post(path, timeout=20):
    c = http.client.HTTPConnection(ESP, timeout=timeout)
    c.request('POST', path, b'', {'Content-Length': '0'})
    r = c.getresponse()
    body = r.read().decode('utf-8', 'replace')
    if r.status != 200:
        raise IOError('%s: HTTP %d %s' % (path, r.status, body[:200]))
    return body

def esp_put(path, off, blob):
    b = uuid.uuid4().hex
    body = (('--%s\r\nContent-Disposition: form-data; name="file"; filename="piece"\r\n'
             'Content-Type: application/octet-stream\r\n\r\n' % b).encode() + blob + ('\r\n--%s--\r\n' % b).encode())
    c = http.client.HTTPConnection(ESP, timeout=120)
    c.request('POST', '/api/put?path=%s&off=%d' % (urllib.parse.quote(path), off), body,
              {'Content-Type': 'multipart/form-data; boundary=' + b, 'Content-Length': str(len(body))})
    r = c.getresponse()
    text = r.read().decode('utf-8', 'replace')
    if r.status != 200:
        raise IOError('the card said: ' + text[:200])
    return json.loads(text)

def serial_line(cmd):
    """a line to the ESP32's USB serial, through pc/pad.py's tool port (it holds the port)"""
    import socket
    f = socket.create_connection(('127.0.0.1', 5557), timeout=10).makefile('rwb')
    f.write(b'S ' + cmd.encode() + b'\n'); f.flush(); f.readline(); f.close()

def card_size(path):
    return esp_get('/api/stat?path=' + urllib.parse.quote(path))['size']

def card_crc(path, off, n):
    return int(esp_get('/api/crc?path=%s&off=%d&len=%d' % (urllib.parse.quote(path), off, n), timeout=120)['crc'], 16)

# --- one job at a time, in the background -----------------------------------------------------
JOB = {'busy': False, 'what': '', 'stage': '', 'done': 0, 'total': 0, 'rate': 0.0, 'error': '', 'ok': ''}
LOG = []
lock = threading.Lock()

def log(msg):
    line = time.strftime('%H:%M:%S ') + msg
    print(line, flush=True)
    with lock:
        LOG.append(line)
        del LOG[:-200]

def run_job(what, fn, *args):
    with lock:
        if JOB['busy']:
            return False
        JOB.update(busy=True, what=what, stage='starting', done=0, total=0, rate=0.0, error='', ok='')
    def go():
        try:
            JOB['ok'] = fn(*args) or 'done'
            log(what + ': ' + JOB['ok'])
        except Exception as e:                       # (said on the page, in words)
            JOB['error'] = str(e)
            log(what + ': FAILED - ' + str(e))
        finally:
            JOB['busy'] = False
    threading.Thread(target=go, daemon=True).start()
    return True

def send_file(local, card_path):
    """local -> card_path, piece by piece, each piece checked; carries on a copy that stopped"""
    total = os.path.getsize(local)
    JOB.update(stage='looking at the card', total=total)
    have = card_size(card_path)
    start = 0
    with open(local, 'rb') as f:
        # Carry on only from what is really this file: every piece already there is checked
        # against ours first. (A different, shorter file under the same name -- yesterday's core --
        # was taken for a stopped copy of this one, and only the end was sent: a core made of two
        # halves went into the flash and did not start.)
        if have > 0:
            JOB['stage'] = 'checking what the card already has'
            good = 0
            while good + CHUNK <= min(have, total):
                f.seek(good); blob = f.read(CHUNK)
                if card_crc(card_path, good, CHUNK) != zlib.crc32(blob) & 0xFFFFFFFF:
                    break
                good += CHUNK
                JOB['done'] = good
            start = good if have <= total else 0     # (longer than ours: not a stopped copy of it)
            log('%s: %d MB of it already on the card and checked; sending from there' % (card_path, start >> 20)
                if start else '%s: what the card has is not this file; sending all of it' % card_path)
        off = start
        t0, sent = time.time(), 0
        while off < total:
            f.seek(off)
            blob = f.read(min(CHUNK, total - off))
            want = zlib.crc32(blob) & 0xFFFFFFFF
            for attempt in range(1, 7):
                JOB['stage'] = 'sending' + ('' if attempt == 1 else ' (try %d)' % attempt)
                try:
                    esp_put(card_path, off, blob)
                    got = card_crc(card_path, off, len(blob))
                    if got == want:
                        break
                    log('piece at %d MB came back different (crc %08x, sent %08x): again' % (off >> 20, got, want))
                except Exception as e:
                    log('piece at %d MB: %s -- again in 3 s' % (off >> 20, e))
                    time.sleep(3)
            else:
                raise IOError('the piece at %d MB would not go across in six tries -- run it again to carry on' % (off >> 20))
            off += len(blob); sent += len(blob)
            JOB['done'] = off
            JOB['rate'] = sent / max(0.001, time.time() - t0)
    size = card_size(card_path)
    if size != total:
        raise IOError('the card has %d bytes, the file is %d' % (size, total))
    if total <= 64 << 20:                            # (a core: the whole of it, once more, in one look)
        JOB['stage'] = 'checking the whole file on the card'
        with open(local, 'rb') as f:
            if card_crc(card_path, 0, total) != zlib.crc32(f.read()) & 0xFFFFFFFF:
                raise IOError('the whole file on the card is not this one -- send it again')
    return '%s on the card (%d MB, every piece checked)' % (card_path, total >> 20)

def wait_core(want, secs):
    t0 = time.time()
    while time.time() - t0 < secs:
        try:
            s = esp_get('/api/state', timeout=5)
            if s.get('alive') and s.get('core') == want:
                return True
        except Exception:
            pass
        time.sleep(1)
    return False

def install(core):
    cid = dict((c, i) for c, i, _ in CONSOLES)[core]
    JOB['stage'] = 'back to the shell'
    # The console's own reboot register first (SYS 0x0014 = B0070000, as the menu does), sent
    # through pc/pad.py's serial pass-through: the ESP32's PROGRAM_B wire does nothing on this
    # board (2026-10-10: the FPGA did not even blink). /api/shell as well, for a board where it does.
    if not wait_core(0, 1):
        try:
            serial_line('W 14 B0070000')
        except Exception as e:
            log('the reboot register through pad.py: %s' % e)
        if not wait_core(0, 8):
            esp_post('/api/shell')
    if not wait_core(0, 20):
        raise IOError('the board did not go back to the shell (is pc/pad.py running?)')
    JOB['stage'] = 'writing the flash from the card (about a minute)'
    esp_post('/api/install?core=' + core)
    t0 = time.time()
    while True:
        time.sleep(2)
        j = esp_get('/api/state')['job']
        JOB['done'], JOB['total'] = j.get('done', 0), j.get('total', 0)
        if not j['busy']:
            break
        if time.time() - t0 > 600:
            raise IOError('the install has not finished in ten minutes')
    if j.get('error'):
        raise IOError('install: ' + j['error'])
    # (asked up to three times: the first boot after an install does not always take -- the
    # menu's own switch asks twice for the same reason; seen here 2026-10-10, a good core stayed dark)
    for attempt in range(3):
        JOB['stage'] = 'starting the console' + ('' if attempt == 0 else ' (asking again)')
        esp_post('/api/boot?core=1')
        if wait_core(cid, 15):
            break
    else:
        raise IOError('installed, but the %s did not come up' % CORE_NAME[cid])
    return 'the %s core is in the flash and running -- it stays after power-off' % CORE_NAME[cid]

def add_game(src, console):
    """a download (zip, or the file itself) -> /roms/<console>/ on the card"""
    files = [src]
    if src.lower().endswith('.zip'):
        JOB['stage'] = 'unpacking'
        os.makedirs(UNPACK, exist_ok=True)
        with zipfile.ZipFile(src) as z:
            names = [n for n in z.namelist() if not n.endswith('/')]
            for n in names:
                out = os.path.join(UNPACK, os.path.basename(n))
                if not (os.path.exists(out) and os.path.getsize(out) == z.getinfo(n).file_size):
                    with z.open(n) as a, open(out, 'wb') as b:
                        while True:
                            buf = a.read(1 << 20)
                            if not buf: break
                            b.write(buf)
            files = [os.path.join(UNPACK, os.path.basename(n)) for n in names]
    sent = []
    cues = [f for f in files if f.lower().endswith('.cue')]
    if console == 'ps1' and cues:
        tracks = open(cues[0], errors='replace').read().upper().count('TRACK ')
        bins = [f for f in files if f.lower().endswith('.bin')]
        if tracks == 1 and len(bins) == 1:
            files = bins                            # one data track: the image alone, as the menu wants
        else:
            log('%d tracks: sending the cue sheet and every track file' % tracks)
    for f in files:
        dest = '/roms/%s/%s' % (console, os.path.basename(f))
        JOB['what'] = 'adding ' + os.path.basename(f)
        sent.append(send_file(f, dest))
    return ' / '.join(sent) + ' -- in the menu under %s' % dict((c, n) for c, _, n in CONSOLES)[console]

# --- what is here -----------------------------------------------------------------------------
def local_cores():
    out = []
    for core, _, name in CONSOLES:
        cands = [os.path.join(ROOT, 'cores', core + '.bin')]
        if core == 'ps1':
            cands += glob.glob(os.path.join(ROOT, 'build', 'ps1_dbg_t*.bin'))
        cands = [c for c in cands if os.path.exists(c)]
        if not cands:
            continue
        best = max(cands, key=os.path.getmtime)
        out.append({'core': core, 'name': name, 'file': os.path.relpath(best, ROOT).replace('\\', '/'),
                    'size': os.path.getsize(best),
                    'when': time.strftime('%d %b %H:%M', time.localtime(os.path.getmtime(best)))})
    return out

def downloads():
    out = []
    for f in sorted(glob.glob(os.path.join(DOWNLOADS, '*')), key=os.path.getmtime, reverse=True):
        ext = os.path.splitext(f)[1].lower()
        guess = EXT.get(ext)
        if ext == '.zip':
            try:
                with zipfile.ZipFile(f) as z:
                    exts = [os.path.splitext(n)[1].lower() for n in z.namelist()]
                guess = next((EXT[e] for e in exts if e in EXT), 'ps1' if '.bin' in exts else None)
            except Exception:
                continue
        elif ext == '.bin':
            guess = 'ps1' if os.path.getsize(f) > 32 << 20 else 'md'
        if guess is None:
            continue
        out.append({'path': f, 'name': os.path.basename(f), 'size': os.path.getsize(f), 'guess': guess,
                    'when': time.strftime('%d %b %H:%M', time.localtime(os.path.getmtime(f)))})
    return out[:40]

def status():
    s = {'esp': False}
    try:
        st = esp_get('/api/state', timeout=4)
        s.update(esp=True, alive=st.get('alive'), core=st.get('core'), console=CORE_NAME.get(st.get('core'), 'core %s' % st.get('core')),
                 ssid=st.get('ssid'), rssi=st.get('rssi'), card=st.get('cardWhy', ''),
                 cardcores={c['name']: c['size'] for c in st.get('cores', [])},
                 disc=(st.get('disc') or {}).get('path', ''), espjob=st.get('job'))
    except Exception as e:
        s['why'] = str(e)
    with lock:
        s.update(job=dict(JOB), log=LOG[-40:])
    return s

# --- the page ---------------------------------------------------------------------------------
PAGE = r"""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Console</title><style>
:root{--bg:#f5f5f2;--card:#fff;--ink:#1d1d1b;--mute:#6b6b66;--line:#e2e2dc;--acc:#2f6fdb;--ok:#1e8a4c;--bad:#c23b2f}
@media(prefers-color-scheme:dark){:root{--bg:#161616;--card:#202020;--ink:#ececea;--mute:#9a9a95;--line:#333;--acc:#6fa0ff;--ok:#4cc27e;--bad:#ff6b5e}}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 system-ui,Segoe UI,sans-serif}
main{max-width:980px;margin:0 auto;padding:20px 16px 60px}h1{font-size:22px;margin:0 0 14px}
h2{font-size:15px;text-transform:uppercase;letter-spacing:.06em;color:var(--mute);margin:26px 0 8px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px}
.row{display:flex;gap:12px;align-items:center;padding:9px 0;border-top:1px solid var(--line)}.row:first-child{border-top:0}
.grow{flex:1;min-width:0}.name{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.sub{color:var(--mute);font-size:13px}
button{font:inherit;padding:6px 12px;border-radius:7px;border:1px solid var(--line);background:var(--card);color:var(--ink);cursor:pointer}
button.pri{background:var(--acc);border-color:var(--acc);color:#fff}button:disabled{opacity:.45;cursor:default}
select{font:inherit;padding:5px;border-radius:7px;border:1px solid var(--line);background:var(--card);color:var(--ink)}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px;vertical-align:1px}
.bar{height:8px;background:var(--line);border-radius:4px;overflow:hidden;margin:8px 0}.bar>i{display:block;height:100%;background:var(--acc)}
.ok{color:var(--ok)}.bad{color:var(--bad)}pre{font:12px/1.4 ui-monospace,Consolas,monospace;white-space:pre-wrap;margin:0;max-height:220px;overflow:auto;color:var(--mute)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px}.k{color:var(--mute);font-size:13px}
</style></head><body><main><h1>Console</h1>
<div class="card grid" id="st">looking for the board...</div>
<h2>Now doing</h2><div class="card" id="job">nothing</div>
<h2>Cores</h2><div class="card" id="cores"></div>
<h2>Games in Downloads</h2><div class="card" id="games"></div>
<h2>Log</h2><div class="card"><pre id="log"></pre></div>
</main><script>
const $=id=>document.getElementById(id), mb=n=>(n/1048576).toFixed(n>1e8?0:1)+' MB';
const NAMES={nes:'NES',sms:'Master System',md:'Mega Drive',n64:'Nintendo 64',ps1:'PlayStation',snes:'Super NES'};
let S={}, busy=false;
async function act(url,body){const r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body||{})});
 const t=await r.text(); if(!r.ok) alert(t); tick();}
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
async function tick(){
 try{S=await (await fetch('/api/status')).json();}catch(e){$('st').textContent='this program stopped';return}
 busy=S.job.busy;
 $('st').innerHTML=S.esp?
  `<div><div class="k">ESP32</div><span class="dot" style="background:var(--ok)"></span>on Wi-Fi ${esc(S.ssid||'')} (${S.rssi} dBm)</div>
   <div><div class="k">FPGA</div>${S.alive?'<span class="dot" style="background:var(--ok)"></span>'+esc(S.console):'<span class="dot" style="background:var(--bad)"></span>not answering'}</div>
   <div><div class="k">Card</div>${esc((S.card||'').replace(/.*sees /,''))}</div>
   <div><div class="k">Disc in the drive</div>${esc((S.disc||'none').split('/').pop())}</div>`
  :`<div><span class="dot" style="background:var(--bad)"></span>The ESP32 does not answer on Wi-Fi.<div class="sub">${esc(S.why||'')}</div></div>`;
 const j=S.job; let h='nothing';
 if(j.busy||j.error||j.ok){const pc=j.total?Math.min(100,100*j.done/j.total):0;
  const eta=j.rate>0&&j.total?Math.round((j.total-j.done)/j.rate):0;
  h=`<div class="name">${esc(j.what)}</div><div class="sub">${esc(j.stage)}${j.total?` -- ${mb(j.done)} of ${mb(j.total)}`:''}${j.rate?` at ${(j.rate/1024).toFixed(0)} kB/s, about ${Math.floor(eta/60)} min ${eta%60} s left`:''}</div>
  ${j.busy&&j.total?`<div class="bar"><i style="width:${pc}%"></i></div>`:''}
  ${j.error?`<div class="bad">${esc(j.error)}</div>`:''}${!j.busy&&j.ok?`<div class="ok">${esc(j.ok)}</div>`:''}`}
 $('job').innerHTML=h;
 $('log').textContent=(S.log||[]).join('\n');
 if(!tick.loaded){tick.loaded=1;lists();}
 document.querySelectorAll('button').forEach(b=>b.disabled=busy||(!S.esp&&b.dataset.net));
}
async function lists(){
 const L=await (await fetch('/api/lists')).json();
 $('cores').innerHTML=L.cores.map(c=>{const onCard=(S.cardcores||{})[c.core];const same=onCard===c.size;
  return `<div class="row"><div class="grow"><div class="name">${esc(c.name)}</div>
   <div class="sub">newest here: ${esc(c.file)}, ${esc(c.when)} -- ${same?'<span class="ok">the card has this one</span>':(onCard?'the card has a different one':'not on the card')}</div></div>
   <button data-net=1 onclick="act('/api/sendcore',{core:'${c.core}',file:'${esc(c.file)}'})">Put on the card</button>
   <button data-net=1 class="pri" onclick="if(confirm('Install the card\\'s ${esc(c.name)} core into the flash? The board goes to the shell for about a minute.'))act('/api/install',{core:'${c.core}'})">Install</button></div>`}).join('')||'none built';
 $('games').innerHTML=L.games.map((g,i)=>`<div class="row"><div class="grow"><div class="name">${esc(g.name)}</div><div class="sub">${mb(g.size)}, ${esc(g.when)}</div></div>
   <select id="c${i}">${Object.keys(NAMES).map(k=>`<option value="${k}" ${k==g.guess?'selected':''}>${NAMES[k]}</option>`).join('')}</select>
   <button data-net=1 class="pri" onclick="act('/api/addgame',{path:${JSON.stringify(g.path).replace(/"/g,'&quot;')},console:$('c${i}').value})">Add</button></div>`).join('')||'nothing that looks like a game';
 tick();
}
tick(); setInterval(tick,1500); setInterval(lists,15000);
</script></body></html>"""

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body, ctype='application/json'):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path == '/':
            self.reply(200, PAGE, 'text/html; charset=utf-8')
        elif self.path == '/api/status':
            self.reply(200, json.dumps(status()))
        elif self.path == '/api/lists':
            self.reply(200, json.dumps({'cores': local_cores(), 'games': downloads()}))
        else:
            self.reply(404, 'no')
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        a = json.loads(self.rfile.read(n) or b'{}')
        if self.path == '/api/sendcore':
            core = a['core']; f = os.path.join(ROOT, a['file'])
            ok = run_job('putting the %s core on the card' % core, send_file, f, '/cores/%s.bin' % core)
        elif self.path == '/api/install':
            ok = run_job('installing the %s core' % a['core'], install, a['core'])
        elif self.path == '/api/addgame':
            if not os.path.isfile(a['path']) or a.get('console') not in EXT.values():
                return self.reply(400, 'no such file, or no such console')
            ok = run_job('adding ' + os.path.basename(a['path']), add_game, a['path'], a['console'])
        else:
            return self.reply(404, 'no')
        self.reply(200 if ok else 409, 'started' if ok else 'something else is being done -- wait for it')

if __name__ == '__main__':
    log('console interface on http://localhost:%d (the board at %s)' % (PORT, ESP))
    http.server.ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
