// The console: a screen, a slot for a game or a BIOS, a controller, and a way to
// change which machine the board is. The board is the emulator -- nothing here
// emulates anything. This file moves a ROM onto it, streams the framebuffer
// back, turns key presses into one byte in a register, and drives the shell when
// you pick a different core.
//
// Loaded after app.js (its $, api, post, say, hex helpers), video.js (the RGB332
// tables) and synth.js (audioStart/Stop). Classic scripts share one global
// scope, so the top-level names here must not collide with those files'.

// ---------------------------------------------------------------------------
// what each machine is called, how big its picture is, and what it takes in its
// slot. The server is the source of truth for which cores a bitstream contains;
// this is only for labelling.
const CONSOLES = {
  0: { name: 'NES',           w: 256, h: 240, slot: 'cartridge', accept: '.nes' },
  1: { name: 'Master System', w: 256, h: 192, slot: 'cartridge', accept: '.sms,.gg' },
  2: { name: 'Mega Drive',    w: 320, h: 224, slot: 'cartridge', accept: '.gen,.md,.bin' },
  3: { name: 'PlayStation',   w: 320, h: 240, slot: 'BIOS / disc', accept: '.bin' },
};
const STRIDE = 320;

let curConsole = 0;      // which machine is selected on the board
let builtCores = [];     // which cores this bitstream contains
let running = false, haveMedia = false;
let fps = 0, lastFrame = 0, tvBusy = false;

// ---------------------------------------------------------------------------
// the screen
// ---------------------------------------------------------------------------
const tv = $('tv');
const tvCtx = tv.getContext('2d');
let screenW = 320, screenH = 240;
// what the last frame was: the PlayStation's frame arrives as 16-bit RGB555 at its
// own size (640 wide, usually); every other machine's as 320x240 RGB332
let frameFormat = 'rgb332';
let tvImg = tvCtx.createImageData(screenW, screenH);

function tvResize(w, h) {
  if (w === screenW && h === screenH) return;
  screenW = w; screenH = h;
  tv.width = w; tv.height = h;
  tvImg = tvCtx.createImageData(w, h);
}

function tvPaint(bytes) {
  const d = tvImg.data;
  let o = 0;
  for (let y = 0; y < screenH; y++) {
    let i = y * STRIDE;
    for (let x = 0; x < screenW; x++, i++, o += 4) {
      const v = bytes[i];
      d[o] = R332[v >> 5]; d[o + 1] = G332[(v >> 2) & 7]; d[o + 2] = B332[v & 3]; d[o + 3] = 255;
    }
  }
  tvCtx.putImageData(tvImg, 0, 0);
}

// A PlayStation frame: 16-bit words, 5 bits each of red, green, blue from the
// bottom up, exactly as VRAM holds them. The canvas takes the picture at its own
// width and height, which the server states in the headers.
function tvPaint555(bytes, w, h) {
  tvResize(w, h);
  const d = tvImg.data;
  const px = new Uint16Array(bytes.buffer, bytes.byteOffset, (bytes.byteLength >> 1));
  let o = 0;
  for (let i = 0; i < w * h; i++, o += 4) {
    const v = px[i];
    d[o] = (v & 31) << 3 | (v & 31) >> 2;
    d[o + 1] = ((v >> 5) & 31) << 3 | ((v >> 5) & 31) >> 2;
    d[o + 2] = ((v >> 10) & 31) << 3 | ((v >> 10) & 31) >> 2;
    d[o + 3] = 255;
  }
  tvCtx.putImageData(tvImg, 0, 0);
}

async function pullFrame() {
  if (tvBusy) return;
  tvBusy = true;
  try {
    const res = await fetch('/api/vid/frame');
    if (!res.ok) throw new Error(res.statusText);
    const bytes = new Uint8Array(await res.arrayBuffer());
    if (res.headers.get('X-Format') === 'rgb555') {
      frameFormat = 'rgb555';
      const w = +res.headers.get('X-Width'), h = +res.headers.get('X-Height');
      if (bytes.length >= w * h * 2) tvPaint555(bytes, w, h);
    } else {
      if (frameFormat !== 'rgb332') {
        frameFormat = 'rgb332';
        const info = CONSOLES[curConsole] || { w: 320, h: 240 };
        if (frameFormat !== 'rgb555') tvResize(info.w, info.h);   // a 16-bit frame sets its own size
      }
      if (bytes.length >= STRIDE * screenH) tvPaint(bytes);
    }
    $('stage-screen').classList.remove('empty');   // a picture came: nothing to drop here
    const now = performance.now();
    if (lastFrame) { const inst = 1000 / (now - lastFrame); fps = fps ? fps * 0.85 + inst * 0.15 : inst; }
    lastFrame = now;
  } catch (err) { /* the header reports link trouble */ }
  finally { tvBusy = false; }
}

// ---------------------------------------------------------------------------
// the controller
// ---------------------------------------------------------------------------
// The bit order the server expects (pc/server.py _NES_BITS): the NES's eight,
// then the rest of a modern pad, which only the PlayStation has buttons for.
const BUTTONS = ['a', 'b', 'x', 'y', 'l1', 'r1', 'l2', 'r2', 'select', 'start', 'up', 'down', 'left', 'right'];
const BIT = { a: 1, b: 2, select: 4, start: 8, up: 16, down: 32, left: 64, right: 128,
              x: 256, y: 512, l1: 1024, r1: 2048, l2: 4096, r2: 8192 };
const DEFAULT_KEYS = {
  up: 'ArrowUp', down: 'ArrowDown', left: 'ArrowLeft', right: 'ArrowRight',
  a: 'KeyZ', b: 'KeyX', x: 'KeyA', y: 'KeyS',
  l1: 'KeyQ', r1: 'KeyW', l2: 'Digit1', r2: 'Digit2',
  select: 'ShiftLeft', start: 'Enter',
};
// the standard gamepad layout: 0-3 face (bottom, right, left, top), 4-7 shoulders
const DEFAULT_PADS = { a: 0, b: 1, x: 2, y: 3, l1: 4, r1: 5, l2: 6, r2: 7,
                       select: 8, start: 9, up: 12, down: 13, left: 14, right: 15 };
// What each machine calls them, and which it has at all.
const PAD_LABELS = {
  0: { a: 'A', b: 'B', select: 'Select', start: 'Start' },
  1: { a: '1', b: '2', select: 'Pause', start: 'Start' },
  2: { a: 'A', b: 'B', select: 'C', start: 'Start' },
  3: { a: '\u2715', b: '\u25CB', x: '\u25A1', y: '\u25B3', l1: 'L1', r1: 'R1', l2: 'L2', r2: 'R2',
       select: 'Select', start: 'Start' },
};
const padLabels = () => PAD_LABELS[curConsole] || PAD_LABELS[0];
let keyMap = { ...DEFAULT_KEYS }, padMap = { ...DEFAULT_PADS };

function loadBindings() {
  try {
    // 'bindings2': the layout grew (and B moved to the right face button), so
    // bindings saved by the older page are not carried over
    const saved = JSON.parse(localStorage.getItem('bindings2') || '{}');
    if (saved.keys) keyMap = { ...DEFAULT_KEYS, ...saved.keys };
    if (saved.pads) padMap = { ...DEFAULT_PADS, ...saved.pads };
  } catch (err) { /* defaults are fine */ }
}
function saveBindings() {
  try { localStorage.setItem('bindings2', JSON.stringify({ keys: keyMap, pads: padMap })); }
  catch (err) { /* not worth losing the session over */ }
}
loadBindings();

let keyState = 0, padState = 0, sentState = -1;

// the buttons this machine has, in the order a pad shows them
function padButtons() {
  const L = padLabels();
  return ['l2', 'l1', 'select', 'start', 'r1', 'r2', 'x', 'y', 'b', 'a'].filter(b => L[b]);
}
function renderPadView() {
  const L = padLabels();
  $('padbuttons').innerHTML = padButtons().map(b => `<i data-b="${b}">${L[b]}</i>`).join(' ');
}
function drawPad(v) {
  const dpad = $('padview').querySelector('.dpad').children;
  [['up', 0], ['left', 1], ['right', 2], ['down', 3]].forEach(([b, i]) =>
    dpad[i].classList.toggle('on', !!(v & BIT[b])));
  $('padview').querySelectorAll('i[data-b]').forEach(el =>
    el.classList.toggle('on', !!(v & BIT[el.dataset.b])));
}

async function pushPad() {
  const v = keyState | padState;
  drawPad(v);
  if (v === sentState) return;
  sentState = v;
  try { await post('/api/nes/input', { joy1: v }); } catch (err) { /* header reports it */ }
}

let listeningFor = null;
function onKey(down) {
  return e => {
    if (listeningFor && down) {
      keyMap[listeningFor] = e.code; saveBindings(); renderBindings(); listeningFor = null;
      e.preventDefault(); return;
    }
    if (!document.body.classList.contains('play')) return;
    const button = BUTTONS.find(b => keyMap[b] === e.code);
    if (!button) return;
    e.preventDefault();
    keyState = down ? (keyState | BIT[button]) : (keyState & ~BIT[button]);
    pushPad();
  };
}
window.addEventListener('keydown', onKey(true));
window.addEventListener('keyup', onKey(false));
window.addEventListener('blur', () => { keyState = 0; pushPad(); });

function pollPad() {
  const pads = navigator.getGamepads ? navigator.getGamepads() : [];
  const gp = [...pads].find(p => p && p.connected);
  if (!gp) {
    if (padState) { padState = 0; pushPad(); }
    $('pad-src').textContent = 'keyboard';
    return;
  }
  $('pad-src').textContent = gp.id.slice(0, 40);
  if (listeningFor) {
    const pressed = gp.buttons.findIndex(b => b.pressed);
    if (pressed >= 0) { padMap[listeningFor] = pressed; saveBindings(); renderBindings(); listeningFor = null; }
    return;
  }
  let v = 0;
  for (const b of BUTTONS) { const i = padMap[b]; if (gp.buttons[i] && gp.buttons[i].pressed) v |= BIT[b]; }
  const [ax, ay] = [gp.axes[0] || 0, gp.axes[1] || 0];
  if (ax < -0.5) v |= BIT.left; if (ax > 0.5) v |= BIT.right;
  if (ay < -0.5) v |= BIT.up; if (ay > 0.5) v |= BIT.down;
  if (v !== padState) { padState = v; pushPad(); }
}

const KEY_LABEL = code => code.replace(/^Key/, '').replace(/^Digit/, '')
  .replace(/^Arrow/, '').replace(/^Shift(Left|Right)$/, 'Shift');

function renderBindings() {
  const L = padLabels();
  const shown = ['up', 'down', 'left', 'right', ...padButtons()];
  $('bindlist').innerHTML = shown.map(b => `
    <div class="bindrow"><span>${L[b] || b}</span>
      <button data-bind="${b}"><span class="keycap">${KEY_LABEL(keyMap[b])}</span> / pad ${padMap[b]}</button>
    </div>`).join('');
  $('bindlist').querySelectorAll('button[data-bind]').forEach(el => {
    el.onclick = () => {
      listeningFor = el.dataset.bind; renderBindings();
      el.classList.add('listening'); el.textContent = 'press a key or pad button…';
    };
  });
}
renderBindings();
renderPadView();
$('bind-reset').onclick = () => { keyMap = { ...DEFAULT_KEYS }; padMap = { ...DEFAULT_PADS }; saveBindings(); renderBindings(); };
$('bindbtn').onclick = () => { const p = $('bindpanel'); p.style.display = p.style.display === 'none' ? 'block' : 'none'; };

// ---------------------------------------------------------------------------
// the slot: load a game or a BIOS
// ---------------------------------------------------------------------------
async function insert(file) {
  say($('media-msg'), `reading ${file.name}…`);
  try {
    const buf = await file.arrayBuffer();
    const res = await fetch('/api/nes/load', {
      method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: buf,
    });
    const body = await res.json();
    if (!res.ok) throw new Error(body.error || res.statusText);
    $('media-name').textContent = file.name.replace(/\.[^.]+$/, '');
    const size = body.chr ? `${body.prg / 1024} + ${body.chr / 1024} kB` : `${(body.prg / 1024) | 0} kB`;
    $('media-info').textContent = `${body.console} · ${size} · ${body.mapper_name || 'mapper ' + body.mapper}`;
    say($('media-msg'), 'loaded — running', 'ok');
    haveMedia = true;
    $('stage-screen').classList.remove('empty');
    setRunning(true);
    await refreshConsole();
    tv.focus();
  } catch (err) { say($('media-msg'), err.message, 'err'); }
}
$('media-file').onchange = e => { if (e.target.files[0]) insert(e.target.files[0]); };

['dragenter', 'dragover'].forEach(t => window.addEventListener(t, e => { e.preventDefault(); document.body.classList.add('dragging'); }));
['dragleave', 'drop'].forEach(t => window.addEventListener(t, e => {
  e.preventDefault(); if (t === 'dragleave' && e.relatedTarget) return;
  document.body.classList.remove('dragging');
}));
window.addEventListener('drop', e => { const f = e.dataTransfer && e.dataTransfer.files[0]; if (f) insert(f); });

// ---------------------------------------------------------------------------
// what the board is: a console, the shell with a core waiting, or nothing.
//
// Two different machines answer at the same address. A console core maps the NES
// register page ($80000) and answers /api/nes/*; the golden shell does not, and
// asking it those questions gets "address not mapped". So the state comes from
// /api/shell/state, which reads the board's own ID and reports which of the two
// -- or neither -- is on the far end. Everything else follows from that.
// ---------------------------------------------------------------------------
const CORE_LABEL = { nes: 'NES', sms: 'Master System', md: 'Mega Drive', ps1: 'PlayStation' };
const BUILT_NAME = { 0: 'nes', 1: 'sms', 2: 'md', 3: 'ps1' };
let switching = false, booting = false, cachedCores = [];
let padConsole = -1;      // the machine the pad view was last drawn for

function setNoConsole(on) { document.body.classList.toggle('no-console', on); }

async function refreshSystem() {
  let st;
  try { st = await (await fetch('/api/shell/state')).json(); }
  catch (err) { renderOffline(); return; }

  if (st.cores) cachedCores = st.cores;
  const ins = st.install || {};
  if (ins.busy || switching) { renderBusy(ins); return; }

  if (st.running === 'console') {
    setNoConsole(false);
    document.body.classList.remove('busy-mode');
    await refreshConsole();
  } else if (st.running === 'shell') {
    renderShell(st);
  } else {
    renderOffline();
  }
}

// The running console: which machine, its screen size, and the slot it wants.
async function refreshConsole() {
  try {
    const c = await api('/api/nes/console');
    curConsole = c.console;
    builtCores = c.built || [];
    const info = CONSOLES[c.console] || { name: c.name, w: 320, h: 240, slot: 'media', accept: '' };
    if (frameFormat !== 'rgb555') tvResize(info.w, info.h);   // a 16-bit frame sets its own size
    $('sys-running').textContent = info.name;
    $('sys-sub').textContent = 'the machine that is running';
    $('sys-action').innerHTML =
      '<button class="ghost" id="sys-back">Back to the shell</button>';
    $('sys-back').onclick = backToShell;
    $('sys-cores-label').textContent = 'switch machine';
    // (only when the machine changes: redrawing mid-remap would cancel it)
    if (c.console !== padConsole) { padConsole = c.console; renderPadView(); renderBindings(); }
    // the PlayStation's BIOS, disc and card have a panel of their own
    const ps1 = c.console === 3;
    $('slot-panel').style.display = ps1 ? 'none' : '';
    $('ps1-panel').style.display = ps1 ? '' : 'none';
    if (ps1) refreshPs1Media();
    $('media-file').setAttribute('accept', info.accept);
    $('media-slot-label').textContent = info.slot;
    renderCoreChips(BUILT_NAME[c.console]);
    return c;
  } catch (err) { renderOffline(); return null; }
}

function renderShell(st) {
  setNoConsole(true);
  document.body.classList.remove('busy-mode');
  $('sys-running').textContent = 'Shell';
  $('sys-sub').textContent = st.installed
    ? 'the golden image — a machine is installed and ready to start'
    : 'the golden image — no machine installed yet';
  $('sys-action').innerHTML = st.installed
    ? '<button class="act" id="sys-boot">&#9654; Start the installed machine</button>'
    : '<div class="hint">Pick a machine below to install and start it.</div>';
  const boot = $('sys-boot'); if (boot) boot.onclick = startInstalled;
  $('sys-cores-label').textContent = st.installed ? 'or install a different machine' : 'install a machine';
  renderCoreChips(null);
}

function renderOffline() {
  setNoConsole(true);
  document.body.classList.remove('busy-mode');
  $('sys-running').textContent = 'No answer';
  $('sys-sub').textContent = 'the board is not reachable';
  $('sys-action').innerHTML =
    '<div class="hint">Check power at the barrel jack and the Ethernet lead. A ' +
    'board with only USB plugged in looks exactly like a dead one.</div>';
  $('sys-cores').innerHTML = '';
}

function renderBusy(ins) {
  document.body.classList.add('busy-mode');
  $('sys-running').textContent = 'Working';
  const pct = ins.total ? Math.round((ins.done / ins.total) * 100) : 0;
  $('sys-sub').textContent = `${ins.stage || 'starting'}${ins.elapsed ? ' · ' + ins.elapsed + 's' : ''}${pct ? ' · ' + pct + '%' : ''}`;
  $('sys-action').innerHTML =
    '<div class="bar"><i style="width:' + pct + '%"></i></div>' +
    (ins.line ? '<div class="meta mono">' + ins.line.replace(/[<>&]/g, '') + '</div>' : '') +
    '<div class="hint">The board is being written over the cable. Leave it be — ' +
    'interrupting means writing it again, not a broken board.</div>';
  $('sys-cores').innerHTML = '';
}

// The core chips: every machine this build can be switched to. Installing one
// programs the flash over the cable and the board reboots into it, so it works
// from the shell AND from a running console.
function renderCoreChips(runningName) {
  const host = $('sys-cores');
  if (!host) return;
  const cores = cachedCores.filter(c => CORE_LABEL[c.name]);
  if (!cores.length) {
    host.innerHTML = '<div class="hint">No cores in <code>cores/</code>. Build one with <code>tools/core.sh nes</code>.</div>';
    return;
  }
  host.innerHTML = cores.map(c => {
    const on = c.name === runningName;
    return `<button class="ghost coreswitch${on ? ' on' : ''}" data-core="${c.name}" ${on ? 'disabled' : ''}>` +
           `${CORE_LABEL[c.name]}${on ? ' <span class="meta">· running</span>' : ''}</button>`;
  }).join(' ');
  host.querySelectorAll('.coreswitch').forEach(b => { b.onclick = () => switchCore(b.dataset.core); });
}

async function startInstalled() {
  if (booting) return;
  booting = true;
  document.body.classList.add('busy-mode');
  say($('sys-msg'), 'starting the installed machine…');
  try {
    await post('/api/shell/boot', { core: true });
    await new Promise(r => setTimeout(r, 4000));   // it reconfigures; give it a moment
    say($('sys-msg'), '', 'ok');
  } catch (err) { say($('sys-msg'), err.message, 'err'); }
  finally { booting = false; document.body.classList.remove('busy-mode'); refreshSystem(); }
}

async function backToShell() {
  if (booting) return;
  booting = true;
  document.body.classList.add('busy-mode');
  say($('sys-msg'), 'reloading the board into the shell…');
  try {
    await post('/api/shell/reboot', {});
    await new Promise(r => setTimeout(r, 4000));
    say($('sys-msg'), '', 'ok');
  } catch (err) { say($('sys-msg'), err.message, 'err'); }
  finally { booting = false; document.body.classList.remove('busy-mode'); refreshSystem(); }
}

async function switchCore(core) {
  if (switching) return;
  switching = true;
  document.body.classList.add('busy-mode');
  say($('sys-msg'), `installing ${core} over the cable and rebooting — this takes a minute or two…`);
  try {
    const r = await fetch('/api/shell/install', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ core }),
    });
    const body = await r.json();
    if (!r.ok) throw new Error(body.error || r.statusText);
    await waitForInstall();
    // Installing programs the flash and lands the board back in the shell with
    // the core in the slot; one more step actually starts it.
    say($('sys-msg'), `starting ${core}…`);
    try { await post('/api/shell/boot', { core: true }); } catch (err) { /* it reconfigures; no reply */ }
    await new Promise(r => setTimeout(r, 4000));
    say($('sys-msg'), `${core} installed and running`, 'ok');
  } catch (err) {
    say($('sys-msg'), err.message, 'err');
  } finally {
    switching = false;
    haveMedia = false;
    $('stage-screen').classList.add('empty');
    $('media-name').textContent = 'nothing loaded'; $('media-info').textContent = '';
    document.body.classList.remove('busy-mode');
    refreshSystem();
  }
}

async function waitForInstall() {
  for (let i = 0; i < 900; i++) {
    let st;
    try { st = await (await fetch('/api/shell/state')).json(); } catch (err) { st = null; }
    const ins = (st && st.install) || {};
    if (st && !ins.busy) {
      if (ins.error) throw new Error(ins.error);
      await new Promise(r => setTimeout(r, 3000));
      return;
    }
    renderBusy(ins);
    await new Promise(r => setTimeout(r, 800));
  }
  throw new Error('the install did not finish');
}

// ---------------------------------------------------------------------------
// transport
// ---------------------------------------------------------------------------
function setRunning(on) {
  running = on;
  $('play').innerHTML = on ? '&#9632; Stop' : '&#9654; Run';
  $('play').className = on ? 'ghost' : 'act';
}
$('play').onclick = async () => {
  setRunning(!running);
  try { await post('/api/nes/config', { run: running }); } catch (err) {}
  if (running) tv.focus();
};
$('reset').onclick = async () => {
  try { await post('/api/nes/reset'); say($('media-msg'), 'reset', 'ok'); }
  catch (err) { say($('media-msg'), err.message, 'err'); }
};
$('sound').onclick = async () => {
  const btn = $('sound');
  if (audioRunning()) {
    audioStop(); btn.textContent = '\u{1F507} Sound'; btn.className = 'ghost'; $('snd-lat').textContent = '';
  } else {
    try { await audioStart(); btn.textContent = '\u{1F50A} Sound'; btn.className = 'act'; }
    catch (err) { say($('media-msg'), 'could not start audio: ' + err.message, 'err'); }
  }
};
$('fullscreen').onclick = () => {
  const el = $('stage-screen');
  if (document.fullscreenElement) document.exitFullscreen();
  else el.requestFullscreen && el.requestFullscreen();
};
tv.onclick = () => tv.focus();

// ---------------------------------------------------------------------------
// console / developer mode
// ---------------------------------------------------------------------------
function setPlay(on) {
  document.body.classList.toggle('play', on);
  $('devtoggle').textContent = on ? 'Developer' : 'Console';
  $('brand').textContent = on ? 'FPGA Console' : 'fpgalink debugger';
  try { localStorage.setItem('devmode', on ? '0' : '1'); } catch (err) {}
}
$('devtoggle').onclick = () => setPlay(!document.body.classList.contains('play'));
let startInPlay = true;
try { startInPlay = localStorage.getItem('devmode') !== '1'; } catch (err) {}
setPlay(startInPlay);

// ---------------------------------------------------------------------------
// loops
// ---------------------------------------------------------------------------
// only stream a picture when there is actually a console on the other end
function consoleLive() {
  return document.body.classList.contains('play') &&
         !document.body.classList.contains('busy-mode') &&
         !document.body.classList.contains('no-console');
}

function tick() {
  pollPad();
  if (running && consoleLive()) pullFrame();
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);

async function refreshStats() {
  if (!consoleLive()) return;
  try {
    const st = await api('/api/nes/state');
    const wide = st.console === 2 || st.console === 3;
    $('stage-stats').textContent = `${fps.toFixed(0)} fps · ${screenW}×${screenH}` + (st.running ? '' : ' · paused');
    $('con-stats').innerHTML =
      `<tr><td>machine</td><td class="num">${st.console_name || CONSOLES[st.console]?.name || st.console}</td></tr>` +
      `<tr><td>running</td><td class="num">${st.running ? 'yes' : 'no'}</td></tr>` +
      `<tr><td>frames</td><td class="num">${st.frame}</td></tr>` +
      `<tr><td>CPU PC</td><td class="num">${hex(st.pc, wide ? 8 : 4)}</td></tr>`;
    setRunning(st.running);
    if (st.frame > 0) { $('stage-screen').classList.remove('empty'); haveMedia = true; }
  } catch (err) { /* the board may have just changed under us; refreshSystem sorts it */ }
}
setInterval(refreshStats, 1000);

// ---------------------------------------------------------------------------
// the PlayStation: BIOS, disc and memory card, all kept by the server
// ---------------------------------------------------------------------------
const esc = t => String(t).replace(/[<>&"]/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c]));
let ps1Busy = false;
async function refreshPs1Media() {
  if (curConsole !== 3 || ps1Busy) return;
  let m;
  try { m = await api('/api/ps1/media'); } catch (err) { return; }
  $('ps1-bios').innerHTML = m.bios
    ? `<b>${esc(m.bios)}</b><span class="meta">loaded after every reset</span>`
    : `<b>none set</b><span class="meta">drop your BIOS file on the page, or set PS1_BIOS in local.env</span>`;
  const d = m.disc;
  const from = d.source === 'pc' ? 'from this PC' : 'from the SD card';
  const other = d.source === 'pc' ? 'Use the SD card' : 'Use this PC';
  $('ps1-disc').innerHTML =
    (d.name ? `<b>${esc(d.name)}</b>` : '<b>no disc</b>') +
    `<span class="meta">${from}${d.name ? ' · ' + d.served + ' sectors read' : ''}</span>` +
    (d.error ? `<span class="meta" style="color:var(--warn)"> · ${esc(d.error)}</span>` : '') +
    `<br><button class="ghost" id="ps1-disc-swap">${other}</button>`;
  $('ps1-disc-swap').onclick = async () => {
    ps1Busy = true;
    try { await post('/api/disc/host', { on: d.source !== 'pc' }); say($('ps1-msg'), 'disc now ' + (d.source === 'pc' ? 'from the SD card' : 'from this PC'), 'ok'); }
    catch (err) { say($('ps1-msg'), err.message, 'err'); }
    finally { ps1Busy = false; refreshPs1Media(); }
  };
  const c = m.card;
  $('ps1-card').innerHTML =
    `<b>${esc(c.name)}</b>` +
    `<span class="meta">${c.inserted ? 'in slot 1' : 'not in the slot'} · ${c.saved} sectors saved this session</span>` +
    (c.error ? `<span class="meta" style="color:var(--warn)"> · ${esc(c.error)}</span>` : '');
}
setInterval(refreshPs1Media, 3000);
// The board can change what it is at any moment -- a boot, an install, a reset
// -- so re-check which of shell/console/nothing it is on a slow beat, not just
// once at load. This is what makes the page notice a core starting.
setInterval(refreshSystem, 2500);
refreshSystem();
