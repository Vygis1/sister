// Browser side of the fpgalink debugger. Talks only to the register-bus
// endpoints in pc/server.py -- it has no idea whether a real FPGA or
// mock_fpga.py is on the far end, which is the point.

const $ = id => document.getElementById(id);

// What eth_top wires the analyser probe to. Change it there and change it here;
// nothing else in the stack knows or cares what a channel means.
const CHANNELS = [
  'CRS_DV', 'RXD0', 'RXD1', 'TX_EN', 'TXD0', 'TXD1',
  'MDC', 'MDIO', 'rx_frame', 'tx_frame',
];

const REG_MAP = [
  ['SYS.ID',       0x00000000], ['SYS.VERSION', 0x00000004],
  ['SYS.SCRATCH',  0x00000008], ['SYS.UPTIME',  0x0000000C],
  ['LA.ID',        0x00010000], ['LA.STATUS',   0x00010008],
  ['LA.CHAN_MASK', 0x0001000C], ['LA.DIVISOR',  0x00010010],
  ['LA.DEPTH',     0x00010014], ['LA.PRETRIG',  0x00010018],
  ['MDIO.ID',      0x00050000], ['MDIO.STATUS', 0x00050008],
];

const PHY_REGS = {
  0: 'BMCR — control', 1: 'BMSR — status', 2: 'PHYIDR1', 3: 'PHYIDR2',
  4: 'ANAR — advertise', 5: 'ANLPAR — partner', 6: 'ANER — expansion',
  17: 'MCSR — mode control', 18: 'SMR — special modes',
  26: 'ERXSR — error count', 27: 'CSIR — control/status',
  29: 'ISR — interrupt', 30: 'IMR — interrupt mask', 31: 'SCSR — speed indication',
};

const hex = (v, n = 8) => '0x' + (v >>> 0).toString(16).toUpperCase().padStart(n, '0');

async function api(path, opts) {
  const res = await fetch(path, opts);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `${res.status} ${res.statusText}`);
  return body;
}
const post = (path, payload) => api(path, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(payload || {}),
});

function say(el, msg, cls) { el.textContent = msg; el.className = 'msg ' + (cls || ''); }

// --- tabs ---------------------------------------------------------------

document.querySelectorAll('nav button').forEach(b => {
  b.onclick = () => {
    document.querySelectorAll('nav button').forEach(x => x.classList.toggle('on', x === b));
    document.querySelectorAll('section').forEach(s =>
      s.classList.toggle('on', s.id === 'tab-' + b.dataset.tab));
    if (b.dataset.tab === 'phy') refreshPhy();
    if (b.dataset.tab === 'reg') refreshMap();
  };
});

// --- header -------------------------------------------------------------

async function refreshIdent() {
  try {
    const info = await api('/api/ident');
    $('dot').className = 'dot ok';
    // This is the BUS answering, not the core: the handshake word is "FPGA"
    // whatever is loaded. Labelling it by that word put "FPGA" in the header
    // while the System panel correctly said "Shell", which reads as the page
    // contradicting itself. The panel says what is running; this says the link
    // is up.
    $('ident').textContent = (info.release ? `v${info.release} · ` : '') + `link v${info.version >>> 16}.${info.version & 0xffff}`;
    $('target').textContent = info.target;
    const s = Math.floor(info.uptime_ms / 1000);
    $('uptime').textContent =
      `${String(Math.floor(s / 3600)).padStart(2, '0')}:` +
      `${String(Math.floor(s / 60) % 60).padStart(2, '0')}:` +
      `${String(s % 60).padStart(2, '0')}`;
  } catch (err) {
    $('dot').className = 'dot';
    $('ident').textContent = 'no device';
    $('target').textContent = err.message;
  }
}

// --- logic analyzer -----------------------------------------------------

CHANNELS.forEach((name, i) => {
  $('trigch').insertAdjacentHTML('beforeend', `<option value="${i}">${i} — ${name}</option>`);
});

function laConfig() {
  const ch = parseInt($('trigch').value, 10);
  const bit = (1 << ch) >>> 0;
  const mode = $('trigmode').value;
  return {
    depth: parseInt($('depth').value, 10),
    divisor: parseInt($('divisor').value, 10),
    pretrig: parseInt($('pretrig').value, 10),
    chan_mask: parseInt($('chan_mask').value, 16) >>> 0,
    trig_rise: mode === 'rise' ? bit : 0,
    trig_fall: mode === 'fall' ? bit : 0,
    trig_mask: mode === 'level' ? bit : 0,
    trig_value: mode === 'level' && $('triglvl').value === '1' ? bit : 0,
  };
}

let capture = null;

async function arm() {
  $('arm').disabled = true;
  try {
    say($('la-msg'), 'arming…');
    await post('/api/la/arm', laConfig());
    await pollUntilDone();
  } catch (err) {
    say($('la-msg'), err.message, 'err');
  } finally {
    $('arm').disabled = false;
  }
}

async function pollUntilDone() {
  for (let i = 0; i < 300; i++) {
    const st = await api('/api/la/status');
    if (st.done) {
      say($('la-msg'), 'reading buffer…');
      capture = await api('/api/la/data?max=4096');
      view = null;
      draw();
      say($('la-msg'), `${capture.samples.length} samples captured`, 'ok');
      return;
    }
    say($('la-msg'), st.triggered ? `triggered — ${st.fill}/${st.depth}`
                                  : `armed, waiting for trigger — ${st.fill}/${st.depth}`);
    await new Promise(r => setTimeout(r, 100));
  }
  say($('la-msg'), 'timed out — no trigger. Try Force, or free run.', 'err');
}

// --- waveform -----------------------------------------------------------

let view = null;   // {start, span} in samples

function draw() {
  const canvas = $('wave');
  const ctx = canvas.getContext('2d');
  const W = canvas.clientWidth || 1200;
  canvas.width = W;

  const labelW = 76, rowH = 30, top = 14;
  canvas.height = top * 2 + CHANNELS.length * rowH;
  const plotW = W - labelW - 12;

  ctx.fillStyle = '#12141a';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.font = '11px ui-monospace, Consolas, monospace';
  ctx.textBaseline = 'middle';

  if (!capture) {
    ctx.fillStyle = '#7c8698';
    ctx.fillText('no capture yet — press Arm', labelW, canvas.height / 2);
    return;
  }

  const s = capture.samples;
  if (!view) view = { start: 0, span: s.length };
  view.span = Math.max(16, Math.min(view.span, s.length));
  view.start = Math.max(0, Math.min(view.start, s.length - view.span));

  const perPx = view.span / plotW;

  // trigger marker
  const trigX = labelW + (capture.pretrig - view.start) / perPx;
  if (trigX >= labelW && trigX <= labelW + plotW) {
    ctx.strokeStyle = '#e0a33d';
    ctx.setLineDash([4, 4]);
    ctx.beginPath(); ctx.moveTo(trigX, 0); ctx.lineTo(trigX, canvas.height); ctx.stroke();
    ctx.setLineDash([]);
  }

  CHANNELS.forEach((name, ch) => {
    const y = top + ch * rowH;
    const hi = y + 5, lo = y + rowH - 11;

    ctx.fillStyle = '#7c8698';
    ctx.fillText(name, 6, (hi + lo) / 2);

    ctx.strokeStyle = '#2a2f3b';
    ctx.beginPath(); ctx.moveTo(labelW, lo + 4); ctx.lineTo(labelW + plotW, lo + 4); ctx.stroke();

    ctx.strokeStyle = '#7fd1b9';
    ctx.lineWidth = 1.4;
    ctx.beginPath();
    let prev = null;
    for (let px = 0; px < plotW; px++) {
      const a = Math.floor(view.start + px * perPx);
      const b = Math.max(a + 1, Math.floor(view.start + (px + 1) * perPx));
      // When zoomed out a pixel covers many samples; show "was it ever high"
      // rather than aliasing to whichever one happened to land on the pixel.
      let any = 0;
      for (let i = a; i < b && i < s.length; i++) any |= (s[i] >>> ch) & 1;
      const yy = any ? hi : lo;
      const x = labelW + px;
      if (prev === null) ctx.moveTo(x, yy);
      else if (yy !== prev) { ctx.lineTo(x, prev); ctx.lineTo(x, yy); }
      ctx.lineTo(x + 1, yy);
      prev = yy;
    }
    ctx.stroke();
  });

  ctx.fillStyle = '#7c8698';
  ctx.fillText(`${view.start} … ${view.start + view.span}  of ${s.length}`,
               labelW, canvas.height - 6);
}

(function wireWaveInteraction() {
  const c = $('wave');
  c.addEventListener('wheel', e => {
    if (!capture) return;
    e.preventDefault();
    const f = e.deltaY > 0 ? 1.25 : 0.8;
    const rel = (e.offsetX - 76) / (c.width - 88);
    const anchor = view.start + view.span * Math.max(0, Math.min(1, rel));
    view.span = Math.round(view.span * f);
    view.start = Math.round(anchor - view.span * Math.max(0, Math.min(1, rel)));
    draw();
  }, { passive: false });

  let dragging = false, lastX = 0;
  c.addEventListener('mousedown', e => { dragging = true; lastX = e.clientX; });
  window.addEventListener('mouseup', () => { dragging = false; });
  window.addEventListener('mousemove', e => {
    if (!dragging || !capture) return;
    const perPx = view.span / (c.width - 88);
    view.start = Math.round(view.start - (e.clientX - lastX) * perPx);
    lastX = e.clientX;
    draw();
  });
  window.addEventListener('resize', draw);
})();

$('arm').onclick = arm;
$('force').onclick = async () => {
  try { await post('/api/la/force'); say($('la-msg'), 'forced'); await pollUntilDone(); }
  catch (err) { say($('la-msg'), err.message, 'err'); }
};

// --- PHY ----------------------------------------------------------------

let phyAddr = 1;

async function refreshPhy() {
  try {
    const st = await api('/api/phy/status?phy=' + phyAddr);
    $('phy-summary').innerHTML =
      `<span class="pill ${st.link ? 'up' : 'down'}">${st.link ? 'LINK UP' : 'LINK DOWN'}</span>
       &nbsp;<b>${st.mode}</b><br>
       addr ${st.phy} · id ${hex(st.id1, 4)}/${hex(st.id2, 4)}<br>
       autoneg ${st.autoneg_done ? 'complete' : 'in progress'}
       ${st.loopback ? '· loopback' : ''}${st.powerdown ? '· powered down' : ''}`;
    say($('phy-msg'), '');

    const dump = await api('/api/phy/dump/' + phyAddr);
    $('phy-table').querySelector('tbody').innerHTML = Object.entries(dump.regs)
      .map(([r, v]) => `<tr><td>${r}</td><td class="num">${hex(v, 4)}</td>
                        <td style="color:var(--dim)">${PHY_REGS[r] || ''}</td></tr>`).join('');
  } catch (err) {
    say($('phy-msg'), err.message, 'err');
  }
}

$('phy-refresh').onclick = refreshPhy;
$('phy-scan').onclick = async () => {
  try {
    const r = await api('/api/phy/scan');
    if (!r.found.length) { say($('phy-msg'), 'nothing answered on any address', 'err'); return; }
    phyAddr = r.found[0].addr;
    say($('phy-msg'), 'found at ' + r.found.map(f => f.addr).join(', '), 'ok');
    refreshPhy();
  } catch (err) { say($('phy-msg'), err.message, 'err'); }
};
$('phy-write').onclick = async () => {
  try {
    await post(`/api/phy/reg/${phyAddr}/${parseInt($('phy-wreg').value, 10)}`,
               { value: parseInt($('phy-wval').value, 16) });
    say($('phy-msg'), 'written', 'ok');
    refreshPhy();
  } catch (err) { say($('phy-msg'), err.message, 'err'); }
};

// --- registers ----------------------------------------------------------

$('poke-read').onclick = async () => {
  try {
    const r = await api('/api/reg/' + $('poke-addr').value);
    say($('poke-msg'), `${hex(r.addr)} = ${hex(r.value)}  (${r.value >>> 0})`, 'ok');
  } catch (err) { say($('poke-msg'), err.message, 'err'); }
};
$('poke-write').onclick = async () => {
  try {
    await post('/api/reg/' + $('poke-addr').value,
               { value: parseInt($('poke-val').value, 16) >>> 0 });
    say($('poke-msg'), 'written', 'ok');
  } catch (err) { say($('poke-msg'), err.message, 'err'); }
};

$('selftest').onclick = async () => {
  try {
    const r = await post('/api/selftest');
    say($('selftest-msg'),
        r.results.map(x => `${hex(x.wrote)}→${hex(x.read)} ${x.ok ? 'ok' : 'MISMATCH'}`).join('\n'),
        r.passed ? 'ok' : 'err');
    $('selftest-msg').style.whiteSpace = 'pre';
  } catch (err) { say($('selftest-msg'), err.message, 'err'); }
};

async function refreshMap() {
  const body = $('map-table').querySelector('tbody');
  body.innerHTML = REG_MAP.map(([n, a]) =>
    `<tr><td>${n}</td><td style="color:var(--dim)">${hex(a)}</td>
     <td class="num" id="mv-${a}">…</td></tr>`).join('');
  for (const [, a] of REG_MAP) {
    try {
      const r = await api('/api/reg/' + a);
      const cell = $('mv-' + a);
      if (cell) cell.textContent = hex(r.value);
    } catch {
      const cell = $('mv-' + a);
      if (cell) { cell.textContent = 'error'; cell.style.color = 'var(--bad)'; }
    }
  }
}
$('map-refresh').onclick = refreshMap;

// --- go -----------------------------------------------------------------

refreshIdent();
setInterval(refreshIdent, 2000);
setInterval(() => {
  if ($('tab-phy').classList.contains('on') && $('phy-auto').checked) refreshPhy();
}, 3000);
draw();
