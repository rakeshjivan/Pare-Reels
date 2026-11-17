// The window: links box, quality and login choices, save folder, one row per download.
const $ = (id) => document.getElementById(id);
let running = false;
let ready = false;
let items = [];

const STATES = { waiting: 'Waiting', downloading: 'Downloading', processing: 'Finishing', done: 'Done', failed: 'Failed', cancelled: 'Cancelled' };

function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }

function render() {
  $('items').innerHTML = items.map((it) => `
    <div class="item ${it.status}" data-id="${it.id}">
      <div class="top">
        <span class="title" title="${esc(it.url)}">${esc(it.title || it.url)}</span>
        ${it.needsAuth && !running ? '<button data-act="unlock">Unlock…</button>' : ''}
        <span class="state">${it.needsFinder && it.status !== 'done' ? 'Finding' : STATES[it.status] || ''}</span>
      </div>
      <div class="bar"><div style="width:${Math.round((it.progress || 0) * 100)}%"></div></div>
      <div class="detail">${esc(it.detail || '')}</div>
    </div>`).join('');
}

function setRunning(on) {
  running = on;
  $('download').hidden = on;
  $('cancel').hidden = !on;
  $('download').disabled = !ready;
  for (const id of ['links', 'quality', 'login', 'change', 'clear']) $(id).disabled = on;
  render();
}

function appendLog(line) {
  const pre = $('log');
  pre.textContent += line + '\n';
  if (pre.textContent.length > 60000) pre.textContent = pre.textContent.slice(-40000);
  pre.scrollTop = pre.scrollHeight;
}

async function runSetup() {
  $('setup').hidden = false;
  $('setupRetry').hidden = true;
  $('setupText').textContent = 'Getting things ready…';
  const r = await window.pare.setup();
  if (r.ok) {
    $('setup').hidden = true;
    ready = true;
    $('download').disabled = running;
  } else {
    $('setupText').textContent = `Setup failed: ${r.error}. Check your internet connection.`;
    $('setupRetry').hidden = false;
  }
}

async function checkUpdate(manual) {
  $('updateStatus').textContent = manual ? 'Checking…' : '';
  const r = await window.pare.checkUpdate();
  if (r.state === 'ready') {
    $('update').hidden = false;
    $('updateText').textContent = `Pare Reels build ${r.build} is ready to install.`;
    $('updateStatus').textContent = '';
  } else if (manual) {
    $('updateStatus').textContent = r.state === 'current' ? `You're up to date (build ${r.build}).` : "Couldn't check right now. Try again later.";
  }
}

(async function init() {
  const { settings, qualities, version } = await window.pare.init();
  $('quality').innerHTML = qualities.map((q) => `<option value="${q.key}">${esc(q.label)}</option>`).join('');
  $('quality').value = settings.quality;
  $('login').value = settings.login;
  $('folder').textContent = settings.folder;
  $('build').textContent = `build ${version}`;

  window.pare.on('setup', (m) => { $('setupText').textContent = m; });
  window.pare.on('items', (list) => { items = list; render(); });
  window.pare.on('log', appendLog);
  window.pare.on('running', setRunning);

  $('quality').onchange = () => window.pare.settings({ quality: $('quality').value });
  $('login').onchange = () => window.pare.settings({ login: $('login').value });
  $('change').onclick = async () => { $('folder').textContent = await window.pare.chooseFolder(); };
  $('open').onclick = () => window.pare.openFolder();
  $('setupRetry').onclick = runSetup;
  $('checkUpdate').onclick = () => checkUpdate(true);
  $('updateBtn').onclick = () => { if (!running) window.pare.installUpdate(); else $('updateText').textContent = 'Finish or cancel the downloads first, then restart to update.'; };

  $('download').onclick = async () => {
    $('notice').textContent = '';
    $('log').textContent = '';
    const err = await window.pare.start($('links').value);
    if (err) $('notice').textContent = err;
  };
  $('cancel').onclick = () => window.pare.cancel();
  $('clear').onclick = () => { if (running) return; $('links').value = ''; items = []; render(); $('notice').textContent = ''; $('log').textContent = ''; };

  // Unlock: a password for this download only.
  let unlockId = null;
  $('items').addEventListener('click', (e) => {
    const b = e.target.closest('button[data-act="unlock"]');
    if (!b) return;
    unlockId = b.closest('.item').dataset.id;
    const it = items.find((x) => x.id === unlockId);
    $('unlockFor').textContent = it ? it.url : '';
    for (const id of ['vpass', 'user', 'pass']) $(id).value = '';
    $('unlock').showModal();
  });
  $('unlock').addEventListener('close', () => {
    const v = $('unlock').returnValue;
    if (v === 'ok') {
      window.pare.unlock(unlockId, { videoPassword: $('vpass').value, username: $('user').value, password: $('pass').value });
    } else if (v === 'find') {
      window.pare.find(unlockId);
    }
    for (const id of ['vpass', 'user', 'pass']) $(id).value = '';
  });

  setRunning(false);
  await runSetup();
  checkUpdate(false);
})();
