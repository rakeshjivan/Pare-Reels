// Launches the built app on GitHub's Windows machine and checks it really works:
// first-launch setup, a batch download (a plain video file, Vimeo and YouTube), and the video finder.
const { _electron: electron } = require('playwright-core');
const path = require('path');
const fs = require('fs');
const os = require('os');

const exe = path.join(__dirname, '..', 'dist', 'win-unpacked', 'Pare Reels.exe');
const out = fs.mkdtempSync(path.join(os.tmpdir(), 'pare-out-'));
const finderOut = path.join(os.tmpdir(), 'pare-finder.json');
const LINKS = [
  'https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4',   // a plain video file
  'https://vimeo.com/76979871',                                                // Vimeo
  'https://www.youtube.com/watch?v=jNQXAC9IVRw',                               // YouTube ("Me at the zoo")
];
const REQUIRED = 1;   // the plain file must work; Vimeo/YouTube often block data-centre machines, so they're reported only

(async () => {
  let failed = false;
  const app = await electron.launch({
    executablePath: exe,
    env: { ...process.env, PARE_SELFTEST_FINDER: 'https://interactive-examples.mdn.mozilla.net/pages/tabbed/video.html', PARE_SELFTEST_OUT: finderOut },
  });
  const page = await app.firstWindow();
  page.on('console', (m) => console.log('[page]', m.text()));
  console.log('Window title:', await page.title());

  console.log('Waiting for first-launch setup (downloads yt-dlp, Deno, ffmpeg)…');
  await page.waitForSelector('#download:not([disabled])', { timeout: 15 * 60 * 1000 });
  console.log('Setup done.');

  await page.evaluate((folder) => window.pare.settings({ folder }), out);
  await page.fill('#links', LINKS.join('\n'));
  await page.click('#download');
  await page.waitForFunction((n) => {
    const rows = [...document.querySelectorAll('.item')];
    return rows.length === n && rows.every((r) => /\b(done|failed|cancelled)\b/.test(r.className) || /Finding/.test(r.querySelector('.state').textContent));
  }, LINKS.length, { timeout: 10 * 60 * 1000 });
  const rows = await page.$$eval('.item', (els) => els.map((e) => ({ cls: e.className, title: e.querySelector('.title').textContent, state: e.querySelector('.state').textContent, detail: e.querySelector('.detail').textContent })));
  rows.forEach((r, i) => console.log(`Row ${i + 1}: ${r.state} | ${r.title} | ${r.detail}`));
  const files = fs.readdirSync(out).filter((f) => !f.endsWith('.part'));
  console.log('Files saved:', files);
  for (let i = 0; i < REQUIRED; i++) if (!/\bdone\b/.test(rows[i].cls)) { console.log(`FAIL: row ${i + 1} did not finish`); failed = true; }
  if (!files.some((f) => /\.mp4$/i.test(f))) { console.log('FAIL: no mp4 saved'); failed = true; }
  const leftovers = fs.readdirSync(out).filter((f) => /\.part|Frag|\.ytdl/.test(f));
  if (leftovers.length) { console.log('FAIL: unfinished pieces left in the folder:', leftovers); failed = true; }

  console.log('Checking the video finder…');
  for (let t = 0; t < 90 && !fs.existsSync(finderOut); t++) await new Promise((r) => setTimeout(r, 1000));
  const job = fs.existsSync(finderOut) ? JSON.parse(fs.readFileSync(finderOut, 'utf8')) : null;
  console.log('Finder found:', job && job.primary, job && job.primaryIsManifest ? '(stream)' : '');
  if (!job || !job.primary) { console.log('FAIL: the finder found nothing'); failed = true; }

  const log = await page.$eval('#log', (e) => e.textContent);
  console.log('---- app log ----\n' + log.slice(-6000));
  await app.close();
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
