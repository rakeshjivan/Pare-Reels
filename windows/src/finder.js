// The video finder: opens the webinar page in a built-in browser window, lets you sign in or
// register if needed, and watches for the real video/sound files the page's player loads
// (what you'd otherwise dig out of the browser's Network inspector by hand).

const { BrowserWindow, session } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');

const PARTITION = 'persist:finder';   // keeps you signed in between uses
const USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

/** manifest (stream link with picture + sound) < video < audio; segments (pieces of a stream) are ignored. */
function classify(url) {
  const l = url.toLowerCase();
  let p; try { p = new URL(url).pathname.toLowerCase(); } catch { p = l; }
  const ends = (xs) => xs.some((x) => p.endsWith(x));
  if (ends(['.m3u8', '.mpd']) || l.includes('.m3u8') || l.includes('format=m3u8')) return 'manifest';
  if (p.endsWith('/videomanifest') || l.includes('/videomanifest?')) return 'manifest';   // Teams / Stream recordings
  if (ends(['.ts', '.m4s', '.cmfv', '.cmfa'])) return 'segment';
  if (l.includes('/range/') || l.includes('range=') || l.includes('bytes=')) return 'segment';
  if (/(seg|segment|chunk|frag|fragment|part)[-_]?\d+/i.test(p)) return 'segment';
  if (ends(['.m4a', '.mp3', '.aac', '.opus', '.oga', '.weba']) || l.includes('mime=audio')) return 'audio';
  if (ends(['.mp4', '.m4v', '.mov', '.webm', '.mkv']) || l.includes('mime=video')) return p.includes('audio') ? 'audio' : 'video';
  return null;
}
const RANK = { manifest: 0, video: 1, audio: 2 };

/**
 * Opens the finder for one page. Resolves with a job for the downloader, or null if cancelled.
 * `parent` is the main window.
 */
function findOnPage(parent, pageURL) {
  return new Promise((resolve) => {
    const ses = session.fromPartition(PARTITION);
    ses.setUserAgent(USER_AGENT);
    const found = [];
    let done = false, timer = null;
    const win = new BrowserWindow({
      parent, width: 1000, height: 760, title: 'Finding the video… (sign in, register or press Play here if the page asks)',
      icon: path.join(__dirname, '..', 'build', 'icon.png'),
      webPreferences: {
        partition: PARTITION,
        preload: path.join(__dirname, 'finder-preload.js'),
        contextIsolation: true,
        nodeIntegrationInSubFrames: true,
        autoplayPolicy: 'no-user-gesture-required',
      },
    });
    win.setMenuBarVisibility(false);

    const add = (url) => {
      if (done || !/^https?:/i.test(url)) return;
      const l = url.toLowerCase();
      if (l.includes('googlevideo.com') || l.includes('youtube.com/')) return;   // only work inside YouTube's player
      if (found.some((f) => f.url === url)) return;
      const kind = classify(url);
      if (!kind || kind === 'segment') return;
      found.push({ url, kind, order: found.length });
      win.setTitle('Found the video. Checking for a separate sound file…');
      // Wait a moment after the first find so a separate sound file can show up too, then go.
      if (!timer) timer = setTimeout(finish, found[0].kind === 'manifest' ? 2000 : 5000);
    };

    // Every request the page (and its frames) makes.
    const filter = { urls: ['http://*/*', 'https://*/*'] };
    const onReq = (details, cb) => { try { add(details.url); } catch { /* ignore */ } cb({}); };
    ses.webRequest.onBeforeRequest(filter, onReq);
    const onHeaders = (details, cb) => {
      const ct = String((details.responseHeaders && (details.responseHeaders['content-type'] || details.responseHeaders['Content-Type'])) || '').toLowerCase();
      if (/^(video|audio)\//.test(ct) || ct.includes('mpegurl') || ct.includes('dash+xml')) {
        // A file whose address gives no clue, but the server says it's video or sound.
        if (!classify(details.url) && !done && !found.some((f) => f.url === details.url)) {
          found.push({ url: details.url, kind: ct.startsWith('audio') ? 'audio' : (ct.includes('mpegurl') || ct.includes('dash')) ? 'manifest' : 'video', order: found.length });
          if (!timer) timer = setTimeout(finish, 3000);
        }
      }
      cb({});
    };
    ses.webRequest.onHeadersReceived(filter, onHeaders);
    // Links the page script reports (e.g. Vimeo's player configuration).
    const onMsg = (_e, url) => add(url);
    win.webContents.ipc.on('pare-found', onMsg);

    // Sign-in popups (Google, Microsoft…) open as small windows sharing the same login.
    win.webContents.setWindowOpenHandler((d) => {
      if (/width|height/i.test(d.features || '')) {
        return { action: 'allow', overrideBrowserWindowOptions: { parent: win, width: 520, height: 680, title: 'Sign in', webPreferences: { partition: PARTITION } } };
      }
      win.loadURL(d.url);   // ordinary "open in new tab" links open here instead
      return { action: 'deny' };
    });

    const cleanup = () => {
      ses.webRequest.onBeforeRequest(null);
      ses.webRequest.onHeadersReceived(null);
      clearTimeout(timer);
    };

    async function finish() {
      if (done) return;
      const usable = found.filter((f) => RANK[f.kind] !== undefined).sort((a, b) => RANK[a.kind] - RANK[b.kind] || a.order - b.order);
      const primary = usable[0];
      if (!primary) return;
      done = true;
      try { await win.webContents.executeJavaScript("window.__pareReelsDone = true; document.querySelectorAll('video,audio').forEach(function(m){m.pause()}); 0", true); } catch { /* page gone */ }
      // Save the window's login cookies for the downloader.
      const cookies = await ses.cookies.get({});
      let text = '# Netscape HTTP Cookie File\n';
      for (const c of cookies) {
        const domain = (c.httpOnly ? '#HttpOnly_' : '') + (c.hostOnly ? c.domain : (c.domain.startsWith('.') ? c.domain : '.' + c.domain));
        const sub = c.hostOnly ? 'FALSE' : 'TRUE';
        text += [domain, sub, c.path || '/', c.secure ? 'TRUE' : 'FALSE', String(Math.floor(c.expirationDate || 0)), c.name, c.value].join('\t') + '\n';
      }
      const cookiesFile = path.join(os.tmpdir(), `pare-reels-cookies-${crypto.randomUUID()}.txt`);
      fs.writeFileSync(cookiesFile, text, { mode: 0o600 });
      const job = {
        primary: primary.url,
        primaryIsManifest: primary.kind === 'manifest',
        audioCandidates: usable.filter((f) => f.kind === 'audio' && f.url !== primary.url).map((f) => f.url),
        otherVideos: usable.filter((f) => f.kind === 'video' && f.url !== primary.url).map((f) => f.url),
        referer: win.webContents.getURL() || pageURL,
        userAgent: USER_AGENT,
        cookiesFile,
        title: win.webContents.getTitle() || 'Webinar',
      };
      cleanup();
      win.destroy();
      resolve(job);
    }

    win.on('closed', () => { if (!done) { done = true; cleanup(); resolve(null); } });
    setTimeout(() => { if (!done && !found.length) win.setTitle('Still looking. Press Play on the video if it hasn\'t started.'); }, 60000);
    win.loadURL(pageURL, { userAgent: USER_AGENT });
  });
}

module.exports = { findOnPage, classify };
