// page.cpp - the page a phone gets.
//
// One file, no framework, no CDN. This is served off the chip's own flash to a
// device that has just joined an access point with no route to the internet, so
// anything fetched from elsewhere would simply never arrive.
//
// It is deliberately the SHORT interface. The full one -- screen, controllers,
// debug panels -- lives in web/ and comes down the Ethernet link, because that
// is where the picture is. This is the appliance panel: what am I, what is in
// me, and how do I get on the network.

#include <Arduino.h>

// `extern` on the DEFINITION, not just the declaration. A const at file scope
// has internal linkage in C++, so without it this symbol exists only inside
// this translation unit and the sketch fails to link against it.
extern const char PAGE_HTML[] PROGMEM = R"HTML(<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>console</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin:0; background:#101014; color:#e8e8ea;
         font:16px/1.5 system-ui,-apple-system,sans-serif; }
  main { max-width:34rem; margin:0 auto; padding:1.25rem 1rem 4rem; }
  h1 { font-size:1rem; letter-spacing:.18em; text-transform:uppercase;
       color:#8a8a95; margin:0 0 1rem; }
  h2 { font-size:.75rem; letter-spacing:.14em; text-transform:uppercase;
       color:#8a8a95; margin:1.75rem 0 .5rem; }
  .card { background:#1b1b21; border:1px solid #2a2a33; border-radius:.7rem;
          padding:.9rem 1rem; }
  .big { font-size:1.2rem; font-weight:600; }
  .meta { font-size:.8rem; color:#8a8a95; }
  button, select, input { font:inherit; }
  button { padding:.75rem 1rem; border:1px solid #33333c; border-radius:.6rem;
           background:#1b1b21; color:#e8e8ea; cursor:pointer; }
  button:hover:not(:disabled) { border-color:#5a5a68; }
  button:disabled { opacity:.45; cursor:default; }
  button.act { background:#16281d; border-color:#6ee7a0; color:#b8f5d0; }
  button.danger { border-color:#5a2a2a; color:#ff9c9c; }
  .row { display:flex; gap:.5rem; flex-wrap:wrap; align-items:center; }
  .row > * { flex:1 1 auto; }
  input, select { padding:.7rem; border:1px solid #33333c; border-radius:.6rem;
                  background:#101014; color:#e8e8ea; width:100%; }
  .bar { height:.5rem; background:#2a2a33; border-radius:.3rem; overflow:hidden;
         margin-top:.6rem; }
  .bar > i { display:block; height:100%; background:#6ee7a0; width:0; }
  .msg { margin-top:.6rem; font-size:.85rem; min-height:1.2em; color:#b6b6c0; }
  .msg.err { color:#ff9c9c; }
  .msg.ok  { color:#6ee7a0; }
  .dot { display:inline-block; width:.55rem; height:.55rem; border-radius:50%;
         background:#ff9c9c; margin-right:.45rem; vertical-align:middle; }
  .dot.on { background:#6ee7a0; }
  ul { list-style:none; margin:.5rem 0 0; padding:0; }
  li { margin-bottom:.35rem; }
  li button { width:100%; text-align:left; }
  code { background:#101014; padding:.1rem .3rem; border-radius:.25rem; }
</style></head><body><main>

<h1>Console</h1>

<div class="card">
  <div class="big"><span class="dot" id="dot"></span><span id="what">checking…</span></div>
  <div class="meta" id="detail"></div>
</div>

<h2>Machine</h2>
<div id="machine"></div>
<div class="msg" id="m-msg"></div>

<h2>Install a core</h2>
<div class="card">
  <div id="cores"></div>
  <div style="margin-top:.7rem">
    <input type="file" id="file" accept=".bin">
    <div class="meta" style="margin-top:.4rem">
      A raw <code>.bin</code>, not a <code>.bit</code> — build one with
      <code>tools/core.sh nes</code>.
    </div>
    <button id="up" style="margin-top:.6rem">Upload and install</button>
  </div>
  <div class="bar"><i id="bar"></i></div>
  <div class="msg" id="i-msg"></div>
</div>

<h2>Network</h2>
<div class="card">
  <div class="meta" id="net"></div>
  <div class="row" style="margin-top:.7rem">
    <select id="ssid"><option value="">— scanning —</option></select>
    <button id="rescan" style="flex:0 0 auto">Scan</button>
  </div>
  <input type="password" id="pass" placeholder="password" style="margin-top:.5rem">
  <div class="row" style="margin-top:.5rem">
    <button class="act" id="join">Join</button>
    <button id="forget" style="flex:0 0 auto">Forget</button>
  </div>
  <div class="msg" id="n-msg"></div>
</div>

<h2>If something goes wrong</h2>
<div class="row">
  <button class="danger" id="toshell">Back to the shell</button>
</div>
<div class="msg" id="s-msg"></div>

<script>
const $ = id => document.getElementById(id);
const post = (u, q) => fetch(u + (q ? '?' + q : ''), { method:'POST' })
                        .then(async r => { const t = await r.text();
                                           if (!r.ok) throw new Error(t); return t; });
const say = (el, t, k) => { el.textContent = t || ''; el.className = 'msg' + (k ? ' ' + k : ''); };

let uploading = false;

async function refresh() {
  if (uploading) return;
  let s;
  try { s = await (await fetch('/api/state')).json(); }
  catch { $('what').textContent = 'no answer from the ESP32'; return; }

  $('dot').className = 'dot' + (s.alive ? ' on' : '');
  $('what').textContent = !s.alive ? 'FPGA not answering'
                        : s.core === 0 ? 'Shell' : 'Console core ' + s.core;
  $('detail').textContent = !s.alive
    ? 'check the four SPI wires and that the board has power'
    : 'protocol v' + s.version + (s.busy ? ' · flash busy' : ' · idle')
      + (s.card ? ' · SD card' : ' · no SD card');

  // The shell can start a core; a core cannot send itself anywhere, because it
  // has no ICAP in it. Saying so beats a button that quietly does nothing.
  $('machine').innerHTML = !s.alive ? ''
    : s.core === 0
      ? '<button class="act" id="boot">&#9654; Start the installed core</button>'
      : '<div class="card meta">A console core is running. Power-cycle the board '
        + 'to return to the shell — a core cannot reconfigure the chip itself.</div>';
  if ($('boot')) $('boot').onclick = async () => {
    say($('m-msg'), 'starting…');
    try { await post('/api/boot', 'core=1');
          setTimeout(() => say($('m-msg'), 'the core should be running', 'ok'), 2500); }
    catch (e) { say($('m-msg'), e.message, 'err'); }
  };

  const j = s.job || {};
  if (j.busy) {
    const pct = j.total ? Math.round(j.done / j.total * 100) : 0;
    $('bar').style.width = pct + '%';
    say($('i-msg'), j.stage + ' — ' + pct + '% (' + j.done + '/' + j.total + ')');
  } else if (j.error) {
    $('bar').style.width = '0';
    say($('i-msg'), j.error, 'err');
  } else if (j.stage === 'done') {
    $('bar').style.width = '100%';
    say($('i-msg'), 'installed and verified', 'ok');
  }

  $('cores').innerHTML = (s.cores || []).length
    ? '<ul>' + s.cores.map(c =>
        `<li><button class="fromcard" data-n="${c.name}">${c.name}` +
        `<span class="meta"> · ${Math.round(c.size/1024)} kB</span></button></li>`
      ).join('') + '</ul>'
    : '<div class="meta">' + (s.card ? 'Nothing in /cores on the card.'
                                     : 'No SD card — upload a core below.') + '</div>';
  for (const b of document.querySelectorAll('.fromcard'))
    b.onclick = () => post('/api/install', 'core=' + encodeURIComponent(b.dataset.n))
                        .catch(e => say($('i-msg'), e.message, 'err'));

  $('net').innerHTML = 'Access point <b>console</b> at <code>' + s.ap + '</code>'
    + (s.sta ? '<br>Also on <b>' + s.ssid + '</b> at <code>' + s.sta + '</code>'
               + ' (' + s.rssi + ' dBm)'
             : '<br>Not joined to any network');
}

$('rescan').onclick = async () => {
  say($('n-msg'), 'scanning…');
  try {
    const nets = await (await fetch('/api/scan')).json();
    $('ssid').innerHTML = nets.length
      ? nets.map(n => `<option value="${n.ssid}">${n.ssid} (${n.rssi} dBm)` +
                      `${n.open ? ' · open' : ''}</option>`).join('')
      : '<option value="">none found</option>';
    say($('n-msg'), nets.length + ' networks', 'ok');
  } catch (e) { say($('n-msg'), e.message, 'err'); }
};

$('join').onclick = async () => {
  say($('n-msg'), 'joining… (this page stays up either way)');
  try {
    const ip = await post('/api/join', 'ssid=' + encodeURIComponent($('ssid').value)
                                     + '&pass=' + encodeURIComponent($('pass').value));
    say($('n-msg'), 'joined — also reachable at ' + ip, 'ok');
  } catch (e) { say($('n-msg'), e.message, 'err'); }
  refresh();
};

$('forget').onclick = () => post('/api/forget')
  .then(() => { say($('n-msg'), 'forgotten', 'ok'); refresh(); });

$('toshell').onclick = () => post('/api/shell')
  .then(t => say($('s-msg'), t, t === 'ok' ? 'ok' : 'err'))
  .catch(e => say($('s-msg'), e.message, 'err'));

// The upload goes straight through to the flash as it arrives, so progress here
// is the browser's own upload progress -- which is the honest thing to show.
$('up').onclick = () => {
  const f = $('file').files[0];
  if (!f) { say($('i-msg'), 'pick a .bin first', 'err'); return; }
  uploading = true;
  $('up').disabled = true;
  say($('i-msg'), 'uploading ' + f.name + '…');

  const fd = new FormData();
  fd.append('core', f, f.name);
  const xhr = new XMLHttpRequest();
  xhr.open('POST', '/api/upload');
  xhr.upload.onprogress = e => {
    if (!e.lengthComputable) return;
    const pct = Math.round(e.loaded / e.total * 100);
    $('bar').style.width = pct + '%';
    say($('i-msg'), 'writing to flash — ' + pct + '%');
  };
  xhr.onload = () => {
    uploading = false;
    $('up').disabled = false;
    const ok = xhr.status === 200 && xhr.responseText === 'ok';
    say($('i-msg'), ok ? 'installed and verified' : xhr.responseText, ok ? 'ok' : 'err');
    refresh();
  };
  xhr.onerror = () => {
    uploading = false; $('up').disabled = false;
    say($('i-msg'), 'the upload was cut off', 'err');
  };
  xhr.send(fd);
};

refresh();
setInterval(refresh, 1500);
$('rescan').click();
</script>
</main></body></html>)HTML";
