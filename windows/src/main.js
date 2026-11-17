// Pare Reels for Windows: main process. Owns the window, settings, downloads, the video finder and updates.

const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const tools = require('./tools');
const { Downloader, QUALITIES } = require('./downloader');
const { findOnPage } = require('./finder');
const updater = require('./updater');

if (!app.requestSingleInstanceLock()) { app.quit(); }

const settingsFile = () => path.join(app.getPath('userData'), 'settings.json');
function loadSettings() {
  let s = {};
  try { s = JSON.parse(fs.readFileSync(settingsFile(), 'utf8')); } catch { /* first run */ }
  const folder = s.folder && fs.existsSync(s.folder) ? s.folder : app.getPath('downloads');
  return { folder, quality: QUALITIES[s.quality] ? s.quality : 'p1080', login: ['auto', 'none', 'firefox'].includes(s.login) ? s.login : 'auto' };
}
function saveSettings(s) {
  try { fs.mkdirSync(path.dirname(settingsFile()), { recursive: true }); fs.writeFileSync(settingsFile(), JSON.stringify(s)); } catch { /* not critical */ }
}

let win;
let settings;
let downloader;
let finderBusy = false;

const send = (ch, data) => { if (win && !win.isDestroyed()) win.webContents.send(ch, data); };
const publicItems = (items) => items.map(({ id, url, title, status, progress, detail, needsAuth, needsFinder }) => ({ id, url, title, status, progress, detail, needsAuth, needsFinder }));

/** After a run: open the finder for the next page that needs it. */
async function promptNext() {
  if (finderBusy || downloader.isRunning) return;
  const next = downloader.items.find((x) => x.needsFinder);
  if (!next) return;
  finderBusy = true;
  const job = await findOnPage(win, next.url);
  finderBusy = false;
  if (job) await downloader.startDirect(next.id, job);
  else downloader.finderCancelled(next.id);
  promptNext();
}

function createWindow() {
  win = new BrowserWindow({
    width: 980, height: 820, minWidth: 760, minHeight: 600,
    title: 'Pare Reels', icon: path.join(__dirname, '..', 'build', 'icon.png'),
    backgroundColor: '#ffffff',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true },
  });
  win.setMenuBarVisibility(false);
  win.loadFile(path.join(__dirname, 'ui', 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
}

app.whenReady().then(async () => {
  settings = loadSettings();
  downloader = new Downloader(settings);
  downloader.on('items', (items) => send('items', publicItems(items)));
  downloader.on('log', (line) => send('log', line));
  downloader.on('idle', () => { send('running', false); promptNext(); });
  createWindow();

  ipcMain.handle('init', () => ({ settings, qualities: Object.entries(QUALITIES).map(([k, v]) => ({ key: k, label: v.label })), version: updater.current() }));
  ipcMain.handle('setup', async () => {
    tools.stopLeftovers();
    try { await tools.setup((m) => send('setup', m)); return { ok: true }; }
    catch (e) { return { ok: false, error: e.message }; }
  });
  ipcMain.handle('settings', (_e, change) => { Object.assign(settings, change); saveSettings(settings); return settings; });
  ipcMain.handle('start', async (_e, text) => {
    send('running', true);
    const err = await downloader.start(text);
    if (err) send('running', false);
    return err;
  });
  ipcMain.handle('cancel', () => downloader.cancel());
  ipcMain.handle('unlock', async (_e, id, creds) => { send('running', true); await downloader.retryWith(id, creds); });
  ipcMain.handle('find', (_e, id) => {
    const it = downloader.items.find((x) => x.id === id);
    if (it) { it.needsFinder = true; promptNext(); }
  });
  ipcMain.handle('chooseFolder', async () => {
    const r = await dialog.showOpenDialog(win, { properties: ['openDirectory', 'createDirectory'], defaultPath: settings.folder, buttonLabel: 'Save Here' });
    if (!r.canceled && r.filePaths[0]) { settings.folder = r.filePaths[0]; saveSettings(settings); }
    return settings.folder;
  });
  ipcMain.handle('openFolder', () => shell.openPath(settings.folder));
  ipcMain.handle('checkUpdate', () => updater.check());
  ipcMain.handle('installUpdate', () => updater.install());

  // Automated check used by the Windows build on GitHub: run the video finder on a page and record what it found.
  if (process.env.PARE_SELFTEST_FINDER && process.env.PARE_SELFTEST_OUT) {
    win.webContents.once('did-finish-load', async () => {
      const job = await findOnPage(win, process.env.PARE_SELFTEST_FINDER);
      fs.writeFileSync(process.env.PARE_SELFTEST_OUT, JSON.stringify(job || { found: false }));
    });
  }

  app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
});

app.on('before-quit', () => { if (downloader) downloader.cancel(); });
app.on('window-all-closed', () => app.quit());
