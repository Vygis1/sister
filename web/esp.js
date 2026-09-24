// The card panel: the ESP32's half of the console, on this page.
//
// There are two computers in this machine and the person using it should not
// have to know that. The ESP owns the SD card and the SPI link to the board; the
// PC owns video and the register bus. Each can do things the other cannot, and
// until now that meant two web pages on two addresses.
//
// So everything the ESP offers is proxied through this server and drawn here.
// Nothing is reimplemented on this side: the ESP remains the only thing that
// talks to the card, because two things that both believe they know what is on
// it is how they come to disagree.
//
// --- what belongs to which half -----------------------------------------------
//
//   the ESP   the card, the core library, the game library, installing a core,
//             booting it, and PROGRAM_B -- the way back from a core that hangs
//   this PC   video, audio, the register bus, and filling a cartridge, which
//             needs more bandwidth than the SPI link has
//
// Loading a game off the card uses both: the ESP hands the bytes over and this
// end pushes them into the running console.
//
// Inside a function, like every other file here: four scripts share one global
// scope and a duplicate top-level name is a silently fatal SyntaxError.

(function () {
  const el = id => document.getElementById(id);

  const get = async (path) => {
    const r = await fetch(path);
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || r.statusText);
    return body;
  };

  const post = async (path, opts) => {
    const r = await fetch(path, Object.assign({ method: 'POST' }, opts || {}));
    const text = await r.text();
    if (!r.ok) {
      let msg = text;
      try { msg = JSON.parse(text).error || text; } catch (e) { /* plain text */ }
      throw new Error(msg);
    }
    return text;
  };

  function esc(t) {
    return String(t).replace(/[&<>"]/g, c =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  }

  function note(text, kind) {
    const m = el('esp-msg');
    if (!m) return;
    m.textContent = text || '';
    m.className = 'msg' + (kind ? ' ' + kind : '');
  }

  let busy = false;
  let lastRoms = '';

  async function withBusy(what, fn) {
    if (busy) return;
    busy = true;
    note(what);
    try {
      const r = await fn();
      note(r || 'done', 'ok');
    } catch (err) {
      note(err.message, 'err');
    }
    busy = false;
    refresh();
  }

  // --- uploading ------------------------------------------------------------
  // Straight to the card, through this server, to the ESP. A core and a game go
  // to different endpoints because they land in different places and are named
  // by different rules -- a core becomes /cores/<name>.bin because that is what
  // the core listing looks for; a game keeps the name it arrived with, because
  // what machine it is for is decided by reading its bytes, not its extension.
  function upload(kind, file) {
    const body = new FormData();
    body.append('file', file, file.name);
    return withBusy(`sending ${file.name} to the card…`, async () => {
      await post('/api/esp/' + (kind === 'rom' ? 'roms' : 'library'), { body });
      return `${file.name} is on the card`;
    });
  }

  function wireUploads() {
    const core = el('esp-corefile'), rom = el('esp-romfile');
    if (core) core.onchange = () => core.files[0] && upload('core', core.files[0]);
    if (rom)  rom.onchange  = () => rom.files[0]  && upload('rom',  rom.files[0]);
  }

  // --- rendering ------------------------------------------------------------
  function renderOffline(err) {
    el('esp-what').innerHTML =
      '<div class="status"><b>No ESP32 found</b><div class="meta">' +
      esc(err || 'nothing answered on this network') + '</div></div>';
    el('esp-body').innerHTML =
      '<button class="ghost" id="esp-find">Look for it</button>' +
      '<div class="hint">The ESP32 holds the SD card and can install a core ' +
      'without this computer. It takes its address from DHCP, so it moves; this ' +
      'scans the board’s network for it.</div>';
    const b = el('esp-find');
    if (b) b.onclick = () => withBusy('scanning the network…', async () => {
      const r = await fetch('/api/esp/find', { method: 'POST' });
      const d = await r.json();
      return d.found && d.found.length ? 'found it at ' + d.found[0]
                                       : 'nothing answered';
    });
    el('esp-cores').innerHTML = '';
    el('esp-roms').innerHTML = '';
  }

  // The card's own line is long and full of detail -- "SDXC card, 238.3 GB,
  // FAT32 -- mounted, filesystem sees ..." -- which is exactly right in a log
  // and unreadable as a heading. Split it: the headline says whether there is a
  // card, the facts underneath carry the detail in aligned rows.
  function cardFacts(st) {
    const why = String(st.cardWhy || '');
    const size = (why.match(/([\d.]+ GB)/) || [])[1];
    const fs = /FAT32/.test(why) ? 'FAT32' : /exFAT/.test(why) ? 'exFAT' : null;
    const free = (why.match(/([\d.]+ GB) free/) || [])[1];
    const rows = [];
    if (size) rows.push(['Card', size + (fs ? ' · ' + fs : '')]);
    if (free) rows.push(['Free', free]);
    rows.push(['ESP32', st.sta || st.ap || '?']);
    if (st.ssid) rows.push([esc(st.ssid), st.rssi + ' dBm']);
    return '<div class="facts">' + rows.map(r =>
      '<div><span>' + r[0] + '</span><span>' + esc(r[1]) + '</span></div>').join('') +
      '</div>';
  }

  function render(st) {
    el('esp-what').innerHTML =
      '<div class="status"><b>' + (st.card ? 'Card ready' : 'No card') + '</b>' +
      '<div class="meta">' +
      esc(st.card ? 'cores and games are stored here'
                  : 'fit a card to keep cores and games on the console') +
      '</div></div>' + cardFacts(st);

    const j = st.job || {};
    el('esp-body').innerHTML =
      (j.busy
        ? '<div class="bar"><i style="width:' +
          (j.total ? Math.round(j.done / j.total * 100) : 0) + '%"></i></div>' +
          '<div class="meta mono">' + esc(j.stage || 'working') +
          (j.total ? ' ' + j.done + '/' + j.total : '') + '</div>'
        : '') +
      '<div class="rowhead"><span>Recovery</span></div>' +
      '<button class="ghost" id="esp-shell">&#8617; Back to the shell</button>' +
      '<div class="hint">Pulls PROGRAM_B — the way back from a core that has ' +
      'stopped answering. Works without this computer.</div>';

    const sh = el('esp-shell');
    if (sh) sh.onclick = () => withBusy('pulling PROGRAM_B…',
                                        () => post('/api/esp/shell'));

    // Cores on the card: installing one rewrites the flash slot, so it is
    // deliberately a two-step thing -- install, then start.
    el('esp-cores').innerHTML =
      '<div class="rowhead"><span>Machines</span>' +
      '<label class="linky">Add a core<input type="file" id="esp-corefile" ' +
      'accept=".bin" hidden></label></div>' +
      ((st.cores || []).length
        ? '<div class="chips">' + st.cores.map(c =>
            '<button class="ghost espinst" data-core="' + esc(c.name) + '">' +
            esc(c.name) + '<span class="meta"> ' +
            Math.round(c.size / 1024) + ' kB</span></button>').join('') + '</div>'
        : '<div class="hint">No cores on the card yet.</div>');

    for (const b of document.querySelectorAll('.espinst'))
      b.onclick = () => withBusy('installing ' + b.dataset.core +
                                 ' — this takes a minute…',
        () => post('/api/esp/install?core=' + encodeURIComponent(b.dataset.core)));

    // Games. Rendered only when the list changes, so that clicking one is not
    // interrupted by the panel redrawing underneath the pointer.
    const sig = JSON.stringify(st.roms || []);
    if (sig !== lastRoms) {
      lastRoms = sig;
      el('esp-roms').innerHTML =
        '<div class="rowhead"><span>Games</span>' +
        '<label class="linky">Add a game<input type="file" id="esp-romfile" hidden>' +
        '</label></div>' +
        ((st.roms || []).length
          ? '<div class="chips">' + st.roms.map(r =>
              '<button class="ghost esprom" data-rom="' + esc(r.name) + '">' +
              esc(r.name) + '<span class="meta"> ' +
              Math.round(r.size / 1024) + ' kB</span></button>').join('') + '</div>'
          : '<div class="hint">No games on the card yet.</div>');

      for (const b of document.querySelectorAll('.esprom'))
        b.onclick = () => withBusy('loading ' + b.dataset.rom + '…', async () => {
          // Off the card, through here, into the running console. Which machine
          // it is for is read out of the bytes at this end.
          const d = await get('/api/esp/rom?name=' + encodeURIComponent(b.dataset.rom));
          return d.console + ' cartridge loaded' +
                 (d.mapper_name ? ' — ' + d.mapper_name : '');
        });
      wireUploads();
    }
    wireUploads();
  }

  async function refresh() {
    if (!el('esp-what')) return;
    try {
      render(await get('/api/esp/state'));
    } catch (err) {
      renderOffline(err.message);
    }
  }

  setInterval(() => { if (!busy) refresh(); }, 2000);
  refresh();
})();
