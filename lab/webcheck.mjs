// What Safari's engine (WebKit) and Chromium show for each file, drawn to a canvas.
import { webkit, chromium } from 'playwright';
import { writeFileSync } from 'node:fs';
import http from 'node:http';
import { readFileSync } from 'node:fs';
const files = process.argv.slice(2);
const server = http.createServer((q, s) => { try { const b = readFileSync('.' + decodeURIComponent(q.url)); s.writeHead(200, { 'Content-Type': q.url.endsWith('.mp4') ? 'video/mp4' : 'text/html' }); s.end(b); } catch { s.writeHead(404); s.end(); } }).listen(8899);
writeFileSync('page.html', '<video id=v muted playsinline></video>');
for (const [name, eng] of [['webkit', webkit], ['chromium', chromium]]) {
  let b; try { b = await eng.launch(); } catch (e) { console.log(`RESULT ${name} launch failed ${e.message.split('\n')[0]}`); continue; }
  const p = await b.newPage(); await p.goto('http://localhost:8899/page.html');
  for (const f of files) {
    try {
      const res = await p.evaluate(async (src) => {
        const v = document.getElementById('v'); v.src = src;
        await new Promise((ok, bad) => { v.onloadeddata = ok; v.onerror = () => bad(new Error('load error')); });
        v.currentTime = 1; await new Promise((ok) => { v.onseeked = ok; });
        const c = document.createElement('canvas'); c.width = v.videoWidth; c.height = v.videoHeight;
        c.getContext('2d').drawImage(v, 0, 0); return { w: v.videoWidth, h: v.videoHeight, png: c.toDataURL('image/png') };
      }, '/' + f);
      writeFileSync(`${f}.${name}.png`, Buffer.from(res.png.split(',')[1], 'base64'));
      console.log(`RESULT ${f} ${name} video=${res.w}x${res.h}`);
    } catch (e) { console.log(`RESULT ${f} ${name} ERROR ${e.message.split('\n')[0]}`); }
  }
  await b.close();
}
server.close();
