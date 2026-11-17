// Updates: Windows builds are published on GitHub as "win-N" releases. The app checks on launch,
// downloads the newer installer in the background, and installs it when you click Restart to Update.

const { app } = require('electron');
const path = require('path');
const os = require('os');
const fs = require('fs');
const { spawn } = require('child_process');
const tools = require('./tools');

const REPO = 'rakeshjivan/Pare-Reels';
const current = () => Number(String(app.getVersion()).split('.').pop()) || 0;

async function latest() {
  const res = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=30`, {
    headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'PareReels' },
  });
  if (!res.ok) throw new Error(`GitHub said ${res.status}`);
  const list = await res.json();
  let best = null;
  for (const r of list) {
    const m = /^win-(\d+)$/.exec(r.tag_name || '');
    if (!m || r.draft) continue;
    const asset = (r.assets || []).find((a) => /\.exe$/i.test(a.name));
    if (asset && (!best || Number(m[1]) > best.build)) best = { build: Number(m[1]), url: asset.browser_download_url };
  }
  return best;
}

let ready = null;   // path of a downloaded installer

/** Returns { state: 'current' | 'ready' | 'failed', build } */
async function check() {
  try {
    const l = await latest();
    if (!l || l.build <= current()) return { state: 'current', build: current() };
    const file = path.join(os.tmpdir(), `Pare-Reels-Setup-${l.build}.exe`);
    if (!fs.existsSync(file)) await tools.download(l.url, file);
    ready = file;
    return { state: 'ready', build: l.build };
  } catch (e) {
    return { state: 'failed', build: current(), error: e.message };
  }
}

/** Runs the new installer quietly; it reopens Pare Reels when it's done. */
function install() {
  if (!ready) return false;
  spawn(ready, ['/S', '--force-run'], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
  app.quit();
  return true;
}

module.exports = { check, install, current };
