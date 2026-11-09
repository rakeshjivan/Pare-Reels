// Makes the same crop several different ways, to see which one Apple's video engine honours.
import { openAsBlob } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { inspectVideo, editVideo } from './mp4edit.js';
const crop = { x: 400, y: 200, w: 1080, h: 660 };
const file = await openAsBlob('src.mp4');
const info = await inspectVideo(file);
const variants = {
  A_sps: { _cropMode: 'sps', _trackDims: 'crop' },
  B_clap_cropdims: { _cropMode: 'clap', _trackDims: 'crop' },
  C_clap_origdims: { _cropMode: 'clap', _trackDims: 'orig' },
  D_both: { _cropMode: 'both', _trackDims: 'crop' },
};
for (const [name, opts] of Object.entries(variants)) {
  const r = await editVideo(file, info, { crop, ...opts });
  await writeFile(`${name}.mp4`, Buffer.from(await r.blob.arrayBuffer()));
}
// Control: same size but anchored top-left (no offsets) -> tells us if size alone is honoured.
const r = await editVideo(file, info, { crop: { x: 0, y: 0, w: 1080, h: 660 } });
await writeFile('Z_topleft_control.mp4', Buffer.from(await r.blob.arrayBuffer()));
console.log('variants written');
