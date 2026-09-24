// The System panel: what the board currently IS, and how to change it.
//
// Two different machines answer at the same address. The golden shell reports
// itself as "SHEL" on the register bus; a console core reports "FPGA". The panel
// asks rather than remembers, because the board can change underneath the page
// at any moment -- booting a core reconfigures the chip, and the thing that was
// answering simply stops existing.
//
// There is one core slot and one core in it. Picking a machine means installing
// it and then booting it. No slot numbers, because there is nothing to number.
//
// --- why installing goes over the cable ------------------------------------------
//
// The shell can write the flash itself, and the server used to ask it to. It
// now asks Vivado instead, over JTAG. That is slower to start and it cannot
// half-finish: a core that is partly written and a core that is fine look
// identical right up until the board tries to configure from it and does not
// come back.
//
// It also means installing works while a CONSOLE is running, not just from the
// shell -- which is exactly when somebody wants to change machines.
//
// Everything here lives inside a function. Four scripts share one global scope
// in the browser, and two files declaring the same top-level name is a
// SyntaxError that silently kills whichever loads second. That cost a day once.

(function () {
  const el = id => document.getElementById(id);

  const get = async (path) => {
    const r = await fetch(path);
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || r.statusText);
    return body;
  };

  const send = async (path, payload) => {
    const r = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload || {}),
    });
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || r.statusText);
    return body;
  };

  function note(text, kind) {
    const m = el('sys-msg');
    if (!m) return;
    m.textContent = text || '';
    m.className = 'msg' + (kind ? ' ' + kind : '');
  }

  let working = false;
  // When the board was last reconfigured. Reloading the chip takes a few
  // seconds during which nothing answers, and that silence is expected -- saying
  // "no answer" there would call a successful install a failure.
  let restarted = 0;
  const STARTING_MS = 12000;

  async function install(core) {
    if (working) return;
    working = true;
    note('installing ' + core + ' over the cable — this takes a minute or two…');
    try {
      await send('/api/shell/install', { core });
    } catch (err) {
      working = false;
      note(err.message, 'err');
    }
    refresh();
  }

  async function boot(toCore) {
    // Past this point the board stops answering as whatever it was, so there is
    // no reply to wait for and no point polling for one.
    note(toCore ? 'starting the core…' : 'returning to the shell…');
    try {
      await send('/api/shell/boot', { core: toCore });
    } catch (err) {
      note(err.message, 'err');
      return;
    }
    restarted = Date.now();
    setTimeout(() => { note(toCore ? 'the core is running' : 'back in the shell', 'ok'); refresh(); }, 2500);
  }

  async function reboot() {
    // The way back from a console core. A core has no register that
    // reconfigures the chip, so there is nothing to ask it -- but the cable can
    // always reload the board from flash, and that lands in the shell.
    if (working) return;
    working = true;
    note('reloading the board from flash…');
    try {
      await send('/api/shell/reboot', {});
    } catch (err) {
      working = false;
      note(err.message, 'err');
    }
    refresh();
  }

  function coreButtons(st, label) {
    if (!(st.cores || []).length) {
      return '<div class="hint">No cores in <code>cores/</code>. ' +
             'Build one with <code>tools/core.sh nes</code>.</div>';
    }
    return '<div class="hint" style="margin-bottom:6px">' + label + '</div>' +
      st.cores.map(c =>
        '<button class="ghost sysinst" data-core="' + c.name + '">' + c.name +
        '<span class="meta"> · ' + Math.round(c.size / 1024) + ' kB</span></button>'
      ).join(' ');
  }

  function wireCoreButtons() {
    for (const b of document.querySelectorAll('.sysinst'))
      b.onclick = () => install(b.dataset.core);
  }

  function esc(t) {
    return String(t).replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  }

  function mmss(sec) {
    const s = Math.max(0, sec | 0);
    return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
  }

  function renderBusy(ins) {
    working = true;
    // There is no machine on the other end for the next two minutes; do not
    // leave a Run button and a cartridge slot sitting there inviting a click.
    document.body.classList.add('busy-mode');
    document.body.classList.remove('shell-mode');
    const pct = ins.total ? Math.round((ins.done / ins.total) * 100) : 0;

    // Erasing eight megabytes is most of two minutes with nothing to report. A
    // bar that does not move during it is indistinguishable from a hang, so the
    // elapsed time and Vivado's own last line carry the news instead.
    el('sys-what').innerHTML =
      '<div class="status"><b>Working</b><div class="meta">' +
      esc(ins.stage || 'starting') +
      (ins.elapsed ? ' · ' + mmss(ins.elapsed) : '') + '</div></div>';

    el('sys-slots').innerHTML =
      '<div class="bar"><i style="width:' + pct + '%"></i></div>' +
      (ins.line ? '<div class="meta mono">' + esc(ins.line) + '</div>' : '') +
      '<div class="hint">Leave this alone until it finishes. The board is ' +
      'being written over the JTAG cable; interrupting it means writing it ' +
      'again, not a broken board.</div>';
    el('sys-cores').innerHTML = '';
  }

  function settled(ins) {
    // It just finished. Say which way it went: a half-written core and a good
    // one look identical until the board tries to configure from it.
    working = false;
    restarted = Date.now();
    note(ins.error || 'installed and verified — the board is restarting',
         ins.error ? 'err' : 'ok');
  }

  // --- what this panel is for, and what it deliberately is not ----------------
  //
  // The Card panel above owns the LIBRARY: which machines and games exist, and
  // putting a new one there. This panel owns what the board is RIGHT NOW.
  //
  // They both grew an install button and a way back to the shell, which put two
  // of each on one page doing the same job by different routes -- and the two
  // routes are not equally good, so offering both is offering a worse one. The
  // Card panel's install goes through the ESP and works without this computer;
  // its way back pulls PROGRAM_B and works even on a core that has stopped
  // answering. Those win. What is left here is starting and stopping.
  function renderShell(st) {
    document.body.classList.add('shell-mode');
    document.body.classList.remove('busy-mode');
    el('sys-what').innerHTML =
      '<div class="status"><b>Shell</b><div class="meta">the golden image — ' +
      'no console is running</div></div>';

    el('sys-slots').innerHTML = st.installed
      ? '<button class="act" id="sysboot">&#9654; Start the installed core</button>'
      : '<div class="hint">No machine installed yet. Pick one from the card above.</div>';

    const bootBtn = el('sysboot');
    if (bootBtn) bootBtn.onclick = () => boot(true);

    el('sys-cores').innerHTML = '';
  }

  function renderConsole(st) {
    document.body.classList.remove('shell-mode');
    document.body.classList.remove('busy-mode');
    el('sys-what').innerHTML =
      '<div class="status"><b>Console</b><div class="meta">a core is running ' +
      'from the slot</div></div>';

    // No second "back to the shell" here. The Card panel's does it by pulling
    // PROGRAM_B, which works on a core that has stopped answering; this one
    // would reload over JTAG, which needs this computer. One way, the better one.
    el('sys-slots').innerHTML =
      '<div class="hint">Use <b>Back to the shell</b> on the card above to stop ' +
      'it. Drop a game on the screen, or pick one from the card.</div>';

    el('sys-cores').innerHTML = '';
  }

  function renderStarting() {
    document.body.classList.add('busy-mode');
    el('sys-what').innerHTML =
      '<div class="status"><b>Starting</b><div class="meta">the board is ' +
      'reloading from flash</div></div>';
    el('sys-slots').innerHTML =
      '<div class="hint">It comes back in a few seconds.</div>';
    el('sys-cores').innerHTML = '';
  }

  function renderOffline() {
    // Nothing is there to run, so nothing should look runnable.
    document.body.classList.add('busy-mode');
    document.body.classList.remove('shell-mode');
    el('sys-what').innerHTML =
      '<div class="status"><b>No answer</b><div class="meta">the board is not ' +
      'reachable</div></div>';
    el('sys-slots').innerHTML =
      '<div class="hint">Check that it has power at the barrel jack, and that ' +
      'the Ethernet lead is in. An unplugged barrel jack with the USB lead ' +
      'still connected looks exactly like a dead board.</div>';
    el('sys-cores').innerHTML = '';
  }

  async function refresh() {
    if (!el('sys-what')) return;
    let st;
    try {
      st = await get('/api/shell/state');
    } catch (err) {
      renderOffline();
      return;
    }

    const ins = st.install || {};
    if (ins.busy) { renderBusy(ins); return; }
    if (working) settled(ins);

    if (st.running === 'console') renderConsole(st);
    else if (st.running === 'shell') renderShell(st);
    else if (Date.now() - restarted < STARTING_MS) renderStarting();
    else renderOffline();
  }

  setInterval(() => refresh(), 1500);
  refresh();
})();
