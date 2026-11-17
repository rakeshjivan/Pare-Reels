// Fetches and keeps current the programs Pare Reels drives: yt-dlp (the downloader),
// ffmpeg/ffprobe (joining picture and sound, MP3) and Deno (needed for YouTube).
// They live in %LOCALAPPDATA%\Pare Reels\bin, never inside the app, so they can update on their own.

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn, execFile } = require('child_process');
const { Readable, Transform } = require('stream');
const { pipeline } = require('stream/promises');
const extract = require('extract-zip');

const home = path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'Pare Reels');
const dir = path.join(home, 'bin');
const partsRoot = path.join(home, 'parts');

const exe = (name) => path.join(dir, process.platform === 'win32' ? `${name}.exe` : name);

const URLS = {
  ytdlp: 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
  ffmpeg: 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip',
  deno: 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip',
};

async function download(url, dest, onProgress) {
  const res = await fetch(url, { redirect: 'follow', headers: { 'User-Agent': 'PareReels' } });
  if (!res.ok || !res.body) throw new Error(`download failed (${res.status}) for ${url}`);
  const total = Number(res.headers.get('content-length')) || 0;
  let got = 0;
  const tmp = dest + '.part';
  // Count bytes as they pass through on their way to the file (nothing is read twice or lost).
  const counter = new Transform({
    transform(chunk, _enc, cb) { got += chunk.length; if (total && onProgress) onProgress(got / total); cb(null, chunk); },
  });
  await pipeline(Readable.fromWeb(res.body), counter, fs.createWriteStream(tmp));
  if (total && got !== total) throw new Error(`download incomplete (${got} of ${total} bytes) for ${url}`);
  fs.renameSync(tmp, dest);
}

function findIn(root, file) {
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const p = path.join(root, entry.name);
    if (entry.isDirectory()) { const f = findIn(p, file); if (f) return f; }
    else if (entry.name.toLowerCase() === file.toLowerCase()) return p;
  }
  return null;
}

async function installFromZip(url, files, onProgress) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'pare-reels-'));
  try {
    const zip = path.join(work, 'x.zip');
    await download(url, zip, onProgress);
    const out = path.join(work, 'x');
    await extract(zip, { dir: out });
    for (const f of files) {
      const found = findIn(out, f);
      if (!found) throw new Error(`${f} not found in download`);
      fs.copyFileSync(found, path.join(dir, f));
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

const has = (name) => fs.existsSync(exe(name));

function run(file, args, opts = {}) {
  return new Promise((resolve) => {
    execFile(file, args, { windowsHide: true, timeout: opts.timeout || 0, maxBuffer: 16 * 1024 * 1024 },
      (err, stdout, stderr) => resolve({ code: err ? (err.code ?? 1) : 0, stdout: String(stdout || ''), stderr: String(stderr || '') }));
  });
}

/** First launch: fetch what's missing. Later launches: let yt-dlp update itself. */
async function setup(say) {
  fs.mkdirSync(dir, { recursive: true });
  fs.rmSync(partsRoot, { recursive: true, force: true });   // unfinished pieces from last time
  const pct = (label) => (f) => say(`${label} ${Math.round(f * 100)}%`);
  if (!has('yt-dlp')) {
    say('Downloading yt-dlp (first launch only)…');
    await download(URLS.ytdlp, exe('yt-dlp'), pct('Downloading yt-dlp (first launch only)…'));
  } else {
    say('Checking for updates…');
    await run(exe('yt-dlp'), ['-U'], { timeout: 60000 });
  }
  if (!has('deno')) {
    say('Downloading Deno (needed for YouTube)…');
    try { await installFromZip(URLS.deno, ['deno.exe'], pct('Downloading Deno (needed for YouTube)…')); }
    catch (e) { say(`Deno download failed: ${e.message}`); }
  }
  if (!has('ffmpeg') || !has('ffprobe')) {
    say('Downloading ffmpeg (needed for HD and MP3)…');
    try { await installFromZip(URLS.ffmpeg, ['ffmpeg.exe', 'ffprobe.exe'], pct('Downloading ffmpeg (needed for HD and MP3)…')); }
    catch (e) { say(`ffmpeg download failed: ${e.message}`); }
  }
}

/** Ends a program and anything it started (yt-dlp starts ffmpeg). */
function killTree(child) {
  if (!child || child.exitCode !== null) return;
  if (process.platform === 'win32') {
    spawn('taskkill', ['/pid', String(child.pid), '/T', '/F'], { windowsHide: true });
  } else {
    child.kill('SIGTERM');
  }
}

/** Stops downloads left running by an earlier session (e.g. after a crash). */
function stopLeftovers() {
  if (process.platform !== 'win32') return;
  for (const name of ['yt-dlp.exe', 'ffmpeg.exe']) {
    // Only ours: filter by the folder they run from.
    const ps = `Get-CimInstance Win32_Process -Filter "Name='${name}'" | Where-Object { $_.ExecutablePath -like '${dir.replace(/'/g, "''")}*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }`;
    spawn('powershell', ['-NoProfile', '-Command', ps], { windowsHide: true });
  }
}

module.exports = { home, dir, partsRoot, exe, has, setup, run, killTree, stopLeftovers, download };
