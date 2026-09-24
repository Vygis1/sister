// Video tab. Pulls raw framebuffer bytes from the board and paints them.
// Loaded after app.js and reuses its $, api, post and say helpers.

const VW = 256, VH = 240;

// RGB332 -> 8-bit channels, precomputed. Doing this arithmetic per pixel per
// frame is 61440 divisions sixty times a second for no reason.
const R332 = new Uint8Array(8), G332 = new Uint8Array(8), B332 = new Uint8Array(4);
for (let i = 0; i < 8; i++) { R332[i] = Math.round(i * 255 / 7); G332[i] = R332[i]; }
for (let i = 0; i < 4; i++) { B332[i] = Math.round(i * 255 / 3);  }

let vidStreaming = false, vidInFlight = false;
let lastFrameAt = 0, fpsAvg = 0, bytesAvg = 0;

const screenCtx = $('screen').getContext('2d');
const imgData = screenCtx.createImageData(VW, VH);

function paint(bytes) {
  const d = imgData.data;
  for (let i = 0, o = 0; i < VW * VH; i++, o += 4) {
    const v = bytes[i];
    d[o]     = R332[v >> 5];
    d[o + 1] = G332[(v >> 2) & 7];
    d[o + 2] = B332[v & 3];
    d[o + 3] = 255;
  }
  screenCtx.putImageData(imgData, 0, 0);
}

async function grabFrame() {
  if (vidInFlight) return;
  vidInFlight = true;
  const t0 = performance.now();
  try {
    const res = await fetch('/api/vid/frame');
    if (!res.ok) throw new Error(res.statusText);
    const buf = await res.arrayBuffer();
    const bytes = new Uint8Array(buf);
    if (bytes.length < VW * VH) throw new Error('short frame: ' + bytes.length + ' bytes');
    paint(bytes);

    const now = performance.now();
    if (lastFrameAt) {
      const inst = 1000 / (now - lastFrameAt);
      // Smooth it, or the readout is unreadable noise.
      fpsAvg = fpsAvg ? fpsAvg * 0.8 + inst * 0.2 : inst;
      bytesAvg = bytes.length;
    }
    lastFrameAt = now;
    $('vid-stats').innerHTML =
      `<tr><td>frame rate</td><td class="num">${fpsAvg.toFixed(1)} fps</td></tr>` +
      `<tr><td>frame size</td><td class="num">${(bytesAvg / 1024).toFixed(0)} kB</td></tr>` +
      `<tr><td>throughput</td><td class="num">${(fpsAvg * bytesAvg / 1024).toFixed(0)} kB/s</td></tr>` +
      `<tr><td>fetch</td><td class="num">${(now - t0).toFixed(0)} ms</td></tr>` +
      `<tr><td>board frame</td><td class="num">${res.headers.get('X-Frame') || '?'}</td></tr>`;
  } catch (err) {
    say($('vid-msg'), err.message, 'err');
  } finally {
    vidInFlight = false;
  }
}

// requestAnimationFrame rather than setInterval: it matches the display's
// refresh and stops dead when the tab is hidden, instead of queueing frames
// nobody is looking at.
function videoLoop() {
  if (vidStreaming && $('tab-vid').classList.contains('on')) grabFrame();
  requestAnimationFrame(videoLoop);
}

function applyScale() {
  const c = $('screen');
  const v = $('vid-scale').value;
  if (v === 'fit') {
    // Snap to a whole multiple. A fractional scale on a 256-wide image makes
    // some pixels wider than others, which looks like a rendering fault.
    const avail = c.parentElement.clientWidth - 20;
    const k = Math.max(1, Math.floor(avail / VW));
    c.style.width = (VW * k) + 'px';
    c.style.height = (VH * k) + 'px';
  } else {
    const k = parseInt(v, 10);
    c.style.width = (VW * k) + 'px';
    c.style.height = (VH * k) + 'px';
  }
}
window.addEventListener('resize', applyScale);

$('vid-play').onclick = () => {
  vidStreaming = !vidStreaming;
  const b = $('vid-play');
  b.textContent = vidStreaming ? '■ Stop' : '▶ Stream';
  b.className = vidStreaming ? 'ghost' : 'act';
  if (!vidStreaming) { fpsAvg = 0; lastFrameAt = 0; }
  say($('vid-msg'), vidStreaming ? 'streaming' : '');
};

$('vid-shot').onclick = () => grabFrame();
$('vid-scale').onchange = applyScale;
$('vid-en').onchange = e => post('/api/vid/config', { enable: e.target.checked })
  .catch(err => say($('vid-msg'), err.message, 'err'));
$('vid-pattern').onchange = e => post('/api/vid/config', { pattern: +e.target.value })
  .catch(err => say($('vid-msg'), err.message, 'err'));

document.querySelectorAll('nav button').forEach(b => {
  b.addEventListener('click', () => {
    if (b.dataset.tab === 'vid') { syncFromBoard(); grabFrame(); }
  });
});

async function syncFromBoard() {
  try {
    const st = await api('/api/vid/state');
    $('vid-pattern').value = String(st.pattern);
    $('vid-en').checked = st.enabled;
  } catch (err) { /* the header already reports link trouble */ }
}

applyScale();
requestAnimationFrame(videoLoop);
syncFromBoard();
grabFrame();
