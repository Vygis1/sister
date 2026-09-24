// Synth tab. Loaded after app.js and reuses its $, api, post and say helpers --
// top-level const in a classic script lands in the shared global scope.

const NOTE_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const IS_BLACK = n => [1, 3, 6, 8, 10].includes(n % 12);

// Computer keys laid out like one octave of a keyboard, relative to `octave`.
const KEYMAP = { a: 0, w: 1, s: 2, e: 3, d: 4, f: 5, t: 6, g: 7, y: 8, h: 9, u: 10, j: 11, k: 12 };

const LOW = 48, HIGH = 84;        // C3 .. C6

let octave = 4;                   // C4 = MIDI 60
const held = new Set();           // MIDI notes currently sounding

const synWave = () => parseInt($('syn-wave').value, 10);
const noteName = m => NOTE_NAMES[m % 12] + (Math.floor(m / 12) - 1);

// --- notes --------------------------------------------------------------

async function noteOn(midi) {
  if (held.has(midi)) return;     // key repeat, or a pointer re-entering a key
  held.add(midi);
  paintKey(midi, true);
  try {
    await post('/api/syn/noteon', { midi, wave: synWave() });
    refreshVoices();
  } catch (err) { say($('syn-msg'), err.message, 'err'); }
}

async function noteOff(midi) {
  if (!held.has(midi)) return;
  held.delete(midi);
  paintKey(midi, false);
  try {
    await post('/api/syn/noteoff', { midi });
    refreshVoices();
  } catch (err) { say($('syn-msg'), err.message, 'err'); }
}

// --- the piano ----------------------------------------------------------

function buildPiano() {
  const el = $('piano');
  el.innerHTML = '';

  const whites = [];
  for (let m = LOW; m <= HIGH; m++) if (!IS_BLACK(m)) whites.push(m);
  const wpc = 100 / whites.length;

  whites.forEach((m, i) => {
    const k = document.createElement('div');
    k.className = 'wkey';
    k.style.left = (i * wpc) + '%';
    k.style.width = wpc + '%';
    k.dataset.midi = m;
    if (m % 12 === 0) k.textContent = noteName(m);
    el.appendChild(k);
  });

  // Black keys straddle the gap between two whites, so they are positioned from
  // the running white-key index rather than from the semitone number.
  let wi = 0;
  for (let m = LOW; m <= HIGH; m++) {
    if (IS_BLACK(m)) {
      const k = document.createElement('div');
      k.className = 'bkey';
      k.style.left = (wi * wpc - wpc * 0.3) + '%';
      k.style.width = (wpc * 0.6) + '%';
      k.dataset.midi = m;
      el.appendChild(k);
    } else {
      wi++;
    }
  }
}

function paintKey(midi, down) {
  const k = $('piano').querySelector('[data-midi="' + midi + '"]');
  if (k) k.classList.toggle('down', down);
}

function releaseAll() {
  Array.from(held).forEach(noteOff);
}

(function wirePiano() {
  const el = $('piano');
  let dragging = false;

  el.addEventListener('pointerdown', e => {
    const m = e.target.dataset && e.target.dataset.midi;
    if (!m) return;
    dragging = true;
    noteOn(parseInt(m, 10));
  });

  // Glissando: sliding across keys plays them, and leaves the previous one.
  el.addEventListener('pointerover', e => {
    if (!dragging) return;
    const m = e.target.dataset && e.target.dataset.midi;
    if (!m) return;
    const midi = parseInt(m, 10);
    Array.from(held).filter(n => n !== midi).forEach(noteOff);
    noteOn(midi);
  });

  window.addEventListener('pointerup', () => {
    if (!dragging) return;
    dragging = false;
    releaseAll();
  });

  window.addEventListener('keydown', e => {
    if (!$('tab-syn').classList.contains('on')) return;
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') return;
    if (e.repeat) return;
    if (e.key === 'z') { octave = Math.max(1, octave - 1); return; }
    if (e.key === 'x') { octave = Math.min(7, octave + 1); return; }
    const off = KEYMAP[e.key];
    if (off === undefined) return;
    e.preventDefault();
    noteOn(12 * (octave + 1) + off);
  });

  window.addEventListener('keyup', e => {
    const off = KEYMAP[e.key];
    if (off !== undefined) noteOff(12 * (octave + 1) + off);
  });

  // Leaving the tab or the window with keys down would otherwise leave notes
  // sounding forever.
  window.addEventListener('blur', releaseAll);
})();

// --- controls -----------------------------------------------------------

async function pushConfig(patch) {
  try { await post('/api/syn/config', patch); }
  catch (err) { say($('syn-msg'), err.message, 'err'); }
}

$('syn-en').onchange      = e => pushConfig({ enable: e.target.checked });
$('syn-master').oninput   = e => pushConfig({ master: +e.target.value });
$('syn-attack').oninput   = e => pushConfig({ attack: +e.target.value });
$('syn-release').oninput  = e => pushConfig({ release: +e.target.value });

$('syn-panic').onclick = async () => {
  held.clear();
  document.querySelectorAll('#piano .down').forEach(k => k.classList.remove('down'));
  try {
    await post('/api/syn/panic');
    say($('syn-msg'), 'all notes off');
    refreshVoices();
  } catch (err) { say($('syn-msg'), err.message, 'err'); }
};

$('syn-rec').onclick = async () => {
  const secs = parseFloat($('syn-secs').value) || 4;
  const btn = $('syn-rec');
  btn.disabled = true;
  say($('syn-msg'), 'recording ' + secs + 's — play now…');
  try {
    const res = await fetch('/api/syn/record?seconds=' + secs);
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      throw new Error(body.error || res.statusText);
    }
    const blob = await res.blob();
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'fpga-synth.wav';
    a.click();
    URL.revokeObjectURL(a.href);
    say($('syn-msg'), 'saved ' + (blob.size / 1024).toFixed(0) + ' kB', 'ok');
  } catch (err) {
    say($('syn-msg'), err.message, 'err');
  } finally {
    btn.disabled = false;
  }
};

async function refreshVoices() {
  try {
    const st = await api('/api/syn/state');
    $('syn-voices').innerHTML = st.voices.map((n, i) =>
      'v' + i + ':' + (n === null ? '<span style="color:var(--dim)">—</span>'
                                  : '<b>' + noteName(n) + '</b>')
    ).join('&nbsp;&nbsp;');
  } catch (err) { /* the header already reports link trouble */ }
}

// --- scope --------------------------------------------------------------

async function drawScope() {
  if (!$('tab-syn').classList.contains('on')) return;

  let data;
  try { data = await api('/api/syn/scope?n=1024'); } catch (err) { return; }

  const c = $('scope');
  const W = c.clientWidth || 1200;
  c.width = W;
  const H = c.height;
  const ctx = c.getContext('2d');

  ctx.fillStyle = '#12141a';
  ctx.fillRect(0, 0, W, H);
  ctx.strokeStyle = '#2a2f3b';
  ctx.beginPath();
  ctx.moveTo(0, H / 2); ctx.lineTo(W, H / 2);
  ctx.stroke();

  const s = data.samples;
  if (!s.length) return;

  ctx.strokeStyle = '#7fd1b9';
  ctx.lineWidth = 1.4;
  ctx.beginPath();
  for (let px = 0; px < W; px++) {
    const i = Math.floor(px * s.length / W);
    const y = H / 2 - (s[i] / 32768) * (H / 2 - 6);
    if (px) ctx.lineTo(px, y); else ctx.moveTo(px, y);
  }
  ctx.stroke();

  let peak = 0;
  for (const v of s) if (Math.abs(v) > peak) peak = Math.abs(v);
  ctx.fillStyle = '#7c8698';
  ctx.font = '11px ui-monospace, Consolas, monospace';
  ctx.fillText('peak ' + peak + '   ' +
               (20 * Math.log10(peak / 32768 + 1e-9)).toFixed(1) + ' dBFS', 8, 14);
}

// --- go -----------------------------------------------------------------

document.querySelectorAll('nav button').forEach(b => {
  b.addEventListener('click', () => {
    if (b.dataset.tab === 'syn') { refreshVoices(); drawScope(); }
    else releaseAll();
  });
});

buildPiano();
window.addEventListener('resize', drawScope);
setInterval(drawScope, 150);
// 10000 keeps all eight voices inside full scale; the slider goes louder
// for when fewer notes are held.
pushConfig({ enable: true, master: 10000, attack: 600, release: 300 });
refreshVoices();

// ======================= live playback in the browser ====================
//
// The FPGA has no DAC, so "listening" means pulling samples over UDP and
// feeding them to Web Audio. Each poll returns whatever the ring buffer
// produced since the last cursor; those samples are wrapped in an AudioBuffer
// and scheduled back to back, so the browser's clock does the smoothing.
//
// Latency is the price: a poll interval plus the safety margin below, so
// roughly 150-200 ms. Fine for hearing what you played, too slow to feel like
// an instrument -- that needs the FPGA pushing packets rather than being asked.

let actx = null, again = null, cursor = "", playhead = 0, streaming = false;
let inFlight = false;   // setInterval does not wait for an async callback

const POLL_MS = 60;
const LEAD = 0.18;          // seconds of scheduling margin

async function pumpAudio() {
  if (!streaming || !actx || inFlight) return;
  inFlight = true;

  let d;
  try { d = await api('/api/syn/stream?cursor=' + cursor); }
  catch (err) { inFlight = false; return; }
  finally { inFlight = false; }

  cursor = d.cursor;
  if (d.resync) {
    // Buffer wrapped past us. Drop the playhead and start clean rather than
    // playing samples that are already stale.
    playhead = 0;
    return;
  }
  if (!d.samples.length) return;

  const buf = actx.createBuffer(1, d.samples.length, d.rate);
  const ch = buf.getChannelData(0);
  for (let i = 0; i < d.samples.length; i++) ch[i] = d.samples[i] / 32768;

  const src = actx.createBufferSource();
  src.buffer = buf;
  src.connect(again);

  // If the playhead has fallen into the past the stream underran; restart it
  // ahead of now instead of scheduling into a time that has already gone.
  const now = actx.currentTime;
  if (playhead < now + 0.01) playhead = now + LEAD;
  src.start(playhead);
  playhead += buf.duration;

  const buffered = ((playhead - now) * 1000).toFixed(0);
  $('syn-lat').textContent = 'buffered ' + buffered + ' ms';
  const el = $('snd-lat');
  if (el) el.textContent = buffered + ' ms';
}

// Starting and stopping live here rather than in the button handler, because
// the console view has its own control for the same stream and duplicating the
// AudioContext would give two playheads fighting over one ring buffer.
async function audioStart() {
  // A browser will not start audio at all without a user gesture, which is why
  // this is only ever called from a click.
  if (!actx) {
    actx = new (window.AudioContext || window.webkitAudioContext)();
    again = actx.createGain();
    again.gain.value = 0.9;
    again.connect(actx.destination);
  }
  await actx.resume();
  cursor = "";
  playhead = 0;
  streaming = true;
}

function audioStop() {
  streaming = false;
}

function audioRunning() { return streaming; }

function audioVolume(v) { if (again) again.gain.value = v; }

$('syn-listen').onclick = async () => {
  const btn = $('syn-listen');
  if (streaming) {
    audioStop();
    btn.textContent = '▶ Listen';
    btn.className = 'act';
    $('syn-lat').textContent = '';
    return;
  }
  await audioStart();
  btn.textContent = '■ Stop';
  btn.className = 'ghost';
  say($('syn-msg'), 'streaming audio from the board', 'ok');
};

setInterval(pumpAudio, POLL_MS);
