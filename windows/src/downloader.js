// The download engine: the same rules as the Mac app. One link in, one file out; YouTube in many
// pieces at once; several videos at once in a batch; webinar pages handed to the video finder.

const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { spawn } = require('child_process');
const { EventEmitter } = require('events');
const tools = require('./tools');

const QUALITIES = {
  best: { label: 'Best available', height: null },
  p2160: { label: '4K (2160p)', height: 2160 },
  p1440: { label: '1440p', height: 1440 },
  p1080: { label: '1080p', height: 1080 },
  p720: { label: '720p', height: 720 },
  p480: { label: '480p', height: 480 },
  audio: { label: 'Audio only (MP3)', height: null, audio: true },
};

/** Sites the downloader can't read: go straight to finding the file on the page. */
const FINDER_HOSTS = ['gotowebinar.com', 'goto.com', 'gotomeeting.com', 'gotostage.com', 'gotowebinar.cn',
  'teachable.com', 'thinkific.com', 'kajabi.com', 'mykajabi.com', 'podia.com', 'learnworlds.com'];
const YOUTUBE_HOSTS = ['youtube.com', 'youtu.be', 'youtube-nocookie.com'];
const BATCH_AT_ONCE = 3;
const PROGRESS = 'download:PROG %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s';

function hostIn(link, list) {
  let h; try { h = new URL(link).hostname.toLowerCase(); } catch { return false; }
  return list.some((d) => h === d || h.endsWith('.' + d));
}
const isYouTube = (u) => hostIn(u, YOUTUBE_HOSTS);
const needsFinder = (u) => hostIn(u, FINDER_HOSTS);

/** Unwraps Outlook "Safe Links" to the real address. */
function unwrap(link) {
  try {
    const u = new URL(link);
    if (u.hostname.toLowerCase().endsWith('safelinks.protection.outlook.com')) {
      const inner = u.searchParams.get('url');
      if (inner && /^http/i.test(inner)) return inner;
    }
  } catch { /* not a URL */ }
  return link;
}

const lower = (s) => String(s || '').toLowerCase();
const isAuthError = (e) => ['password', 'private video', 'sign in', 'log in', 'login', 'logged-in', 'authentication',
  'cookies', 'members-only', 'registration', 'register'].some((h) => lower(e).includes(h));
const isFinderError = (e) => ['unsupported url', 'no video formats', 'unable to extract', 'no media', 'not a valid url']
  .some((h) => lower(e).includes(h));
const needsRegistration = (e) => ['registration', 'register', 'email authentication', 'requires email', 'sign up']
  .some((h) => lower(e).includes(h));

function friendly(err) {
  const e = lower(err);
  if (e.includes('drm')) return "This is a paid streaming service with copy protection, so it can't be downloaded. Use the service's own app to save it for offline viewing.";
  if (isAuthError(err)) return 'This video needs a login or password. Click "Unlock…" to enter it.';
  if (e.includes('unsupported url')) return "This site isn't supported.";
  return String(err).replace(/^ERROR:\s*/, '');
}

function safeName(title) {
  const cleaned = String(title || '').replace(/[\/\\:*?"<>|\r\n\t]/g, '-').trim();
  return cleaned ? cleaned.slice(0, 120) : 'Webinar';
}

function uniquePath(dir, name, ext) {
  let p = path.join(dir, `${name}.${ext}`);
  for (let n = 2; fs.existsSync(p); n++) p = path.join(dir, `${name} (${n}).${ext}`);
  return p;
}

const firefoxInstalled = () => fs.existsSync(path.join(process.env.APPDATA || '', 'Mozilla', 'Firefox', 'Profiles'));

class Downloader extends EventEmitter {
  constructor(settings) {
    super();
    this.settings = settings;          // { folder, quality, login: 'auto' | 'none' | 'firefox' }
    this.items = [];
    this.running = new Map();          // row -> child process
    this.cancelRequested = false;
    this.sharing = false;
    this.isRunning = false;
  }

  changed() { this.emit('items', this.items); }
  log(s) { this.emit('log', s); }

  ffmpegDir() { return tools.has('ffmpeg') ? tools.dir : null; }
  partsDir(item) { return path.join(tools.partsRoot, item.id); }

  async start(text) {
    const urls = String(text).split(/\s+/).map((s) => s.trim()).filter((s) => /^http/i.test(s)).map(unwrap);
    if (!urls.length) return 'Paste at least one link starting with http.';
    this.items = urls.map((url) => ({ id: crypto.randomUUID(), url, title: url, status: 'waiting', progress: 0, detail: '', needsAuth: false, needsFinder: false, credentials: {} }));
    this.isRunning = true; this.cancelRequested = false;
    const queue = [];
    this.items.forEach((it, i) => {
      if (needsFinder(it.url)) { it.needsFinder = true; it.detail = 'Finding the video on the page…'; }
      else queue.push(i);
    });
    this.changed();
    this.sharing = queue.length > 1;
    // Several videos at once: each one on its own is limited by the site, not your connection.
    const workers = Array.from({ length: Math.min(BATCH_AT_ONCE, queue.length) }, async () => {
      while (queue.length) {
        const i = queue.shift();
        if (this.cancelRequested) { this.items[i].status = 'cancelled'; this.changed(); continue; }
        await this.download(i);
      }
    });
    await Promise.all(workers);
    this.isRunning = false;
    this.emit('idle');
    return null;
  }

  async runOne(id, change) {
    const i = this.items.findIndex((x) => x.id === id);
    if (i < 0 || this.isRunning) return;
    Object.assign(this.items[i], change, { progress: 0, status: 'waiting' });
    this.isRunning = true; this.cancelRequested = false; this.sharing = false;
    await this.download(i);
    this.isRunning = false;
    this.emit('idle');
  }

  retryWith(id, credentials) { return this.runOne(id, { credentials, needsAuth: false }); }
  startDirect(id, job) {
    const it = this.items.find((x) => x.id === id);
    return this.runOne(id, { direct: job, needsFinder: false, title: job.title || (it && it.title) });
  }
  finderCancelled(id) {
    const it = this.items.find((x) => x.id === id);
    if (!it) return;
    Object.assign(it, { needsFinder: false, needsAuth: true, status: 'cancelled', detail: 'Cancelled. Click "Unlock…" to use a password instead.' });
    this.changed();
  }

  cancel() {
    this.cancelRequested = true;
    for (const p of this.running.values()) tools.killTree(p);
  }

  formatArgs() {
    const q = QUALITIES[this.settings.quality] || QUALITIES.p1080;
    if (this.ffmpegDir()) {
      const a = ['--ffmpeg-location', this.ffmpegDir()];
      if (q.audio) return a.concat(['-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '0']);
      const res = q.height ? `res:${q.height}` : 'res';
      // Prefer H.264 + AAC at each size so files play everywhere; 1440p/4K on YouTube only exist as VP9/AV1.
      return a.concat(['-f', 'bv*+ba/b', '-S', `${res},vcodec:h264,acodec:m4a`, '--merge-output-format', 'mp4']);
    }
    if (q.audio) return ['-f', 'ba[ext=m4a]/ba'];
    return ['-f', q.height ? `b[height<=${q.height}]/b` : 'b'];
  }

  args(item, { useLogin = true, login = null, gentle = false } = {}) {
    const pieces = (this.sharing ? 16 : 32) / (gentle ? 2 : 1);
    let a = ['--newline', '--color', 'never', '--no-playlist', '-N', '8',
      '-P', this.settings.folder, '-P', `temp:${this.partsDir(item)}`,
      '-o', '%(title).100B [%(id)s].%(ext)s', '--trim-filenames', '180', '--windows-filenames',
      '--progress-template', PROGRESS, '--print', 'before_dl:TITLE %(title)s', '--no-simulate', '--progress'];
    if (isYouTube(item.url)) {
      // YouTube serves each file as one slow stream; asking for it as many small pieces lets them come down at once.
      // A refused piece must stop the download, never be silently left out of the file.
      a.push('--extractor-args', 'youtube:formats=dashy', '-N', String(pieces), '--abort-on-unavailable-fragments', '--fragment-retries', '10');
    }
    a = a.concat(this.formatArgs());
    const browser = login || this.settings.login;
    if (useLogin && browser === 'firefox') a.push('--cookies-from-browser', 'firefox');
    const c = item.credentials || {};
    if (c.videoPassword) a.push('--video-password', c.videoPassword);
    if (c.username) a.push('--username', c.username);
    if (c.password) a.push('--password', c.password);
    a.push('--', item.url);
    return a;
  }

  async download(i) {
    const item = this.items[i];
    Object.assign(item, { status: 'downloading', detail: 'Starting…', lastError: null });
    this.changed();
    this.log(`▶ ${item.url}`);
    const parts = this.partsDir(item);
    fs.mkdirSync(parts, { recursive: true });
    let ok = false, note = '';
    try {
      if (item.direct) {
        [ok, note] = await this.downloadDirect(i, item.direct);
        try { fs.rmSync(item.direct.cookiesFile, { force: true }); } catch { /* gone */ }
      } else {
        ok = (await this.ytdlp(this.args(item), i)) === 0;
        if (!ok && !this.cancelRequested && isYouTube(item.url) && !isAuthError(item.lastError)) {
          this.log('YouTube pushed back: continuing with fewer pieces at once…');
          item.lastError = null; item.detail = 'Continuing more gently…'; this.changed();
          ok = (await this.ytdlp(this.args(item, { gentle: true }), i)) === 0;
        }
        if (!ok && !this.cancelRequested && this.settings.login === 'auto' && isAuthError(item.lastError) && firefoxInstalled()) {
          this.log('Login needed: trying again with your Firefox login…');
          item.lastError = null; item.detail = 'Trying with your Firefox login…'; this.changed();
          ok = (await this.ytdlp(this.args(item, { login: 'firefox' }), i)) === 0;
        }
        if (!ok && !this.cancelRequested && this.settings.login === 'firefox' && isYouTube(item.url)) {
          this.log('Retrying without the browser login…');
          item.lastError = null; item.detail = 'Retrying…'; this.changed();
          ok = (await this.ytdlp(this.args(item, { useLogin: false, gentle: true }), i)) === 0;
        }
      }
    } finally {
      fs.rmSync(parts, { recursive: true, force: true });   // unfinished pieces never stay behind
    }

    if (this.cancelRequested) Object.assign(item, { status: 'cancelled', detail: '' });
    else if (ok) Object.assign(item, { status: 'done', progress: 1, detail: note });
    else {
      const err = item.lastError || "The download didn't finish. See the log.";
      item.status = 'failed';
      const c = item.credentials || {};
      const typed = !!(c.videoPassword || c.username);
      if (!item.direct && !isYouTube(item.url) && (isFinderError(err) || needsRegistration(err) || (isAuthError(err) && !typed))) {
        // The downloader can't get it on its own: play the page in the finder window and take the file from there.
        Object.assign(item, { needsFinder: true, detail: 'Finding the video on the page…' });
      } else {
        item.needsAuth = !item.direct && isAuthError(err);
        item.detail = friendly(err);
      }
    }
    this.changed();
  }

  ytdlp(args, i) {
    return new Promise((resolve) => {
      const item = this.items[i];
      const env = { ...process.env, PATH: `${tools.dir};${process.env.PATH || ''}` };
      let p;
      try {
        p = spawn(tools.exe('yt-dlp'), args, { cwd: this.settings.folder, env, windowsHide: true });
      } catch (e) {
        this.log(`Could not start yt-dlp: ${e.message}`);
        return resolve(-1);
      }
      this.running.set(i, p);
      let buf = '';
      const onData = (d) => {
        buf += d.toString('utf8');
        const lines = buf.split(/[\r\n]+/);
        buf = lines.pop();
        for (const l of lines) if (l) this.handle(l, item);
      };
      p.stdout.on('data', onData);
      p.stderr.on('data', onData);
      p.on('error', (e) => { this.log(`Could not start yt-dlp: ${e.message}`); });
      p.on('close', (code) => {
        if (buf) this.handle(buf, item);
        if (this.running.get(i) === p) this.running.delete(i);
        resolve(code ?? -1);
      });
    });
  }

  handle(line, item) {
    if (line.startsWith('ERROR')) item.lastError = line;
    if (line.startsWith('FILE ')) item.lastFile = line.slice(5);
    if (['done', 'failed', 'cancelled'].includes(item.status)) { this.log(line); return; }
    if (line.startsWith('PROG ')) {
      const [pct, speed = '', eta = ''] = line.slice(5).split('|').map((s) => s.trim());
      const n = parseFloat(String(pct).replace('%', ''));
      if (!Number.isNaN(n)) item.progress = n / 100;
      item.status = 'downloading';
      item.detail = [speed, eta && eta !== 'NA' ? `${eta} left` : ''].filter((x) => x && x !== 'NA').join(' · ');
      this.changed();
      return;
    }
    if (line.startsWith('TITLE ')) { item.title = line.slice(6); this.changed(); }
    else if (/^\[(Merger|ExtractAudio|VideoConvertor|FixupM3u8)\]/.test(line)) {
      item.status = 'processing'; item.detail = 'Merging / converting…'; this.changed();
    }
    this.log(line);
  }

  // ── Files found on a page ──
  directArgs(job, item, output, intoParts) {
    const parts = this.partsDir(item);
    const a = ['--newline', '--color', 'never', '--no-playlist', '-N', '8',
      '-P', intoParts ? parts : this.settings.folder, '-P', `temp:${parts}`, '-o', output, '--windows-filenames',
      '--progress-template', PROGRESS, '--print', 'after_move:FILE %(filepath)s', '--no-simulate', '--progress',
      '--referer', job.referer, '--add-header', `User-Agent:${job.userAgent}`, '--cookies', job.cookiesFile];
    if (this.ffmpegDir()) a.push('--ffmpeg-location', this.ffmpegDir());
    return a;
  }

  async streams(file) {
    const r = await tools.run(tools.exe('ffprobe'), ['-v', 'error', '-show_entries', 'stream=codec_type', '-of', 'csv=p=0', file]);
    return new Set(r.stdout.split(/\r?\n/).map((s) => s.trim()).filter(Boolean));
  }

  finalize(file, name) {
    const dest = uniquePath(this.settings.folder, name, path.extname(file).slice(1) || 'mp4');
    try { fs.renameSync(file, dest); } catch { fs.copyFileSync(file, dest); fs.rmSync(file, { force: true }); }
    this.log(`Saved ${dest}`);
  }

  async downloadDirect(i, job) {
    const item = this.items[i];
    const name = safeName(job.title);
    const template = name.replace(/%/g, '%%');
    // A stream link (m3u8/mpd) already describes picture + sound; the downloader joins them.
    if (job.primaryIsManifest) {
      const a = this.directArgs(job, item, `${template}.%(ext)s`, false).concat(this.ffmpegDir() ? this.formatArgs() : []);
      return [(await this.ytdlp(a.concat(['--', job.primary]), i)) === 0, ''];
    }
    // A whole file: download it, then check it has sound.
    item.lastFile = null;
    if ((await this.ytdlp(this.directArgs(job, item, `${template}.part-video.%(ext)s`, true).concat(['--', job.primary]), i)) !== 0 || !item.lastFile) return [false, ''];
    const video = item.lastFile;
    if (!tools.has('ffmpeg') || !tools.has('ffprobe')) { this.finalize(video, name); return [true, '']; }
    const vs = await this.streams(video);
    if (vs.has('audio') || !vs.has('video')) { this.finalize(video, name); return [true, '']; }
    // Picture only: find the separate sound file and join the two.
    let n = 0;
    for (const cand of [...job.audioCandidates, ...job.otherVideos]) {
      if (this.cancelRequested) break;
      n++;
      item.detail = 'Getting the sound…'; this.changed();
      item.lastFile = null;
      if ((await this.ytdlp(this.directArgs(job, item, `${template}.part-sound${n}.%(ext)s`, true).concat(['--', cand]), i)) !== 0 || !item.lastFile) continue;
      const sound = item.lastFile;
      const s = await this.streams(sound);
      if (!s.has('audio') || s.has('video')) { fs.rmSync(sound, { force: true }); continue; }
      item.status = 'processing'; item.detail = 'Joining picture and sound…'; this.changed();
      const out = uniquePath(this.settings.folder, name, 'mp4');
      let r = await tools.run(tools.exe('ffmpeg'), ['-y', '-loglevel', 'error', '-i', video, '-i', sound, '-map', '0:v:0', '-map', '1:a:0', '-c', 'copy', '-movflags', '+faststart', out]);
      if (r.code !== 0) r = await tools.run(tools.exe('ffmpeg'), ['-y', '-loglevel', 'error', '-i', video, '-i', sound, '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', out]);
      fs.rmSync(sound, { force: true });
      if (r.code === 0) { fs.rmSync(video, { force: true }); this.log(`Saved ${out}`); return [true, '']; }
    }
    this.finalize(video, name);
    return [true, 'Saved, but no sound track was found on the page.'];
  }
}

module.exports = { Downloader, QUALITIES, isYouTube, needsFinder, unwrap, safeName, friendly, isAuthError };
