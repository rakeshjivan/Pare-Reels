// mp4edit.js — lossless crop + keyframe trim for MP4 / MOV files, entirely on-device.
// No dependencies, no uploads. The video is never decoded or re-encoded:
//   • Crop rewrites the "cropping window" inside the H.264 / HEVC sequence header (a few bytes).
//   • Trim keeps only the samples in the chosen range, starting at the nearest keyframe.
// The output is assembled as a Blob of slices of the original file, so even multi-GB
// videos use very little memory (only the index, "moov", is read into memory).
//
// API:
//   const info = await inspectVideo(file)
//   const { blob, start, end } = await editVideo(file, info, { crop: {x,y,w,h} | null, start, end })

export class VideoEditError extends Error {}

// ───────────────────────── small byte helpers ─────────────────────────

const td = new TextDecoder('latin1');
const te = (s) => Uint8Array.from(s, (c) => c.charCodeAt(0));
const typeAt = (u8, o) => td.decode(u8.subarray(o, o + 4));

function dv(u8) { return new DataView(u8.buffer, u8.byteOffset, u8.byteLength); }

async function readBytes(file, start, len) {
  return new Uint8Array(await file.slice(start, start + len).arrayBuffer());
}

class Writer {
  constructor(size = 1024) { this.buf = new Uint8Array(size); this.len = 0; }
  ensure(n) {
    if (this.len + n <= this.buf.length) return;
    let cap = this.buf.length * 2;
    while (cap < this.len + n) cap *= 2;
    const b = new Uint8Array(cap); b.set(this.buf.subarray(0, this.len)); this.buf = b;
  }
  u8(v) { this.ensure(1); this.buf[this.len++] = v & 255; }
  u16(v) { this.ensure(2); dv(this.buf).setUint16(this.len, v); this.len += 2; }
  u32(v) { this.ensure(4); dv(this.buf).setUint32(this.len, v >>> 0); this.len += 4; }
  i32(v) { this.ensure(4); dv(this.buf).setInt32(this.len, v); this.len += 4; }
  u64(v) { this.ensure(8); dv(this.buf).setBigUint64(this.len, BigInt(Math.round(v))); this.len += 8; }
  i64(v) { this.ensure(8); dv(this.buf).setBigInt64(this.len, BigInt(Math.round(v))); this.len += 8; }
  bytes(b) { this.ensure(b.length); this.buf.set(b, this.len); this.len += b.length; }
  done() { return this.buf.slice(0, this.len); }
}

// ───────────────────────── box tree ─────────────────────────

const CONTAINERS = new Set(['moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'mvex']);

function parseBoxes(u8, start, end) {
  const out = [];
  const v = dv(u8);
  let o = start;
  while (o + 8 <= end) {
    let size = v.getUint32(o);
    const type = typeAt(u8, o + 4);
    let hdr = 8;
    if (size === 1) { size = Number(v.getBigUint64(o + 8)); hdr = 16; }
    else if (size === 0) size = end - o;
    if (size < hdr || o + size > end) break;
    const node = { type };
    if (CONTAINERS.has(type)) node.children = parseBoxes(u8, o + hdr, o + size);
    else node.data = u8.subarray(o + hdr, o + size);
    out.push(node);
    o += size;
  }
  return out;
}

function box(type, payload) {
  const size = payload.length + 8;
  const w = new Writer(size);
  w.u32(size); w.bytes(te(type)); w.bytes(payload);
  return w.done();
}

function serialize(node) {
  if (node.children) {
    const parts = node.children.map(serialize);
    const total = parts.reduce((a, p) => a + p.length, 0);
    const payload = new Uint8Array(total);
    let o = 0; for (const p of parts) { payload.set(p, o); o += p.length; }
    return box(node.type, payload);
  }
  return box(node.type, node.data);
}

const child = (node, type) => node?.children?.find((c) => c.type === type);
const path = (node, ...types) => types.reduce((n, t) => child(n, t), node);

// ───────────────────────── bit reading / writing (for SPS) ─────────────────────────

function unescapeRbsp(nal) {
  const out = []; let zeros = 0;
  for (let i = 0; i < nal.length; i++) {
    const b = nal[i];
    if (zeros >= 2 && b === 3) { zeros = 0; continue; }
    out.push(b);
    zeros = b === 0 ? zeros + 1 : 0;
  }
  return Uint8Array.from(out);
}

function escapeRbsp(rbsp) {
  const out = []; let zeros = 0;
  for (const b of rbsp) {
    if (zeros >= 2 && b <= 3) { out.push(3); zeros = 0; }
    out.push(b);
    zeros = b === 0 ? zeros + 1 : 0;
  }
  return Uint8Array.from(out);
}

class BitReader {
  constructor(u8, bitPos = 0) { this.u8 = u8; this.pos = bitPos; }
  bit() {
    if (this.pos >= this.u8.length * 8) throw new VideoEditError('Unexpected end of video header.');
    const b = (this.u8[this.pos >> 3] >> (7 - (this.pos & 7))) & 1; this.pos++; return b;
  }
  u(n) { let v = 0; for (let i = 0; i < n; i++) v = v * 2 + this.bit(); return v; }
  skip(n) { this.pos += n; }
  ue() { let z = 0; while (this.bit() === 0) { z++; if (z > 31) throw new VideoEditError('Bad video header.'); } return (2 ** z - 1) + this.u(z); }
  se() { const k = this.ue(); return k & 1 ? (k + 1) / 2 : -(k / 2); }
}

class BitWriter {
  constructor() { this.bytes = []; this.cur = 0; this.n = 0; }
  bit(b) { this.cur = (this.cur << 1) | (b & 1); this.n++; if (this.n === 8) { this.bytes.push(this.cur); this.cur = 0; this.n = 0; } }
  u(v, n) { for (let i = n - 1; i >= 0; i--) this.bit(Math.floor(v / 2 ** i) & 1); }
  ue(v) { const x = v + 1; const len = Math.floor(Math.log2(x)); for (let i = 0; i < len; i++) this.bit(0); this.u(x, len + 1); }
  copy(reader, from, to) { for (let p = from; p < to; p++) this.bit((reader.u8[p >> 3] >> (7 - (p & 7))) & 1); }
  finish() { this.bit(1); while (this.n !== 0) this.bit(0); return Uint8Array.from(this.bytes); } // rbsp_stop_one_bit + alignment
}

function lastOneBit(rbsp) {
  for (let i = rbsp.length - 1; i >= 0; i--) {
    if (rbsp[i]) { for (let b = 0; b < 8; b++) if ((rbsp[i] >> b) & 1) return i * 8 + (7 - b); }
  }
  return -1;
}

// ── H.264 SPS ──

const H264_HIGH = new Set([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]);

function skipScalingList(br, size) {
  let last = 8, next = 8;
  for (let j = 0; j < size; j++) {
    if (next !== 0) next = (last + br.se() + 256) % 256;
    last = next === 0 ? last : next;
  }
}

function parseH264Sps(nal) {
  const rbsp = unescapeRbsp(nal);
  const br = new BitReader(rbsp, 8); // skip NAL header byte
  const profile = br.u(8); br.skip(16); br.ue();
  let chroma = 1;
  if (H264_HIGH.has(profile)) {
    chroma = br.ue();
    if (chroma === 3) br.skip(1);
    br.ue(); br.ue(); br.skip(1);
    if (br.bit()) for (let i = 0; i < (chroma === 3 ? 12 : 8); i++) if (br.bit()) skipScalingList(br, i < 6 ? 16 : 64);
  }
  br.ue();
  const pocType = br.ue();
  if (pocType === 0) br.ue();
  else if (pocType === 1) { br.skip(1); br.se(); br.se(); const n = br.ue(); for (let i = 0; i < n; i++) br.se(); }
  br.ue(); br.skip(1);
  const wMbs = br.ue() + 1, hMap = br.ue() + 1;
  const fmo = br.bit();
  if (!fmo) br.skip(1);
  br.skip(1);
  const flagPos = br.pos;
  const crop = br.bit() ? [br.ue(), br.ue(), br.ue(), br.ue()] : [0, 0, 0, 0];
  const afterCrop = br.pos;
  const subW = chroma === 3 ? 1 : 2, subH = chroma === 1 ? 2 : 1;
  const unitX = chroma === 0 ? 1 : subW;
  const unitY = (chroma === 0 ? 1 : subH) * (2 - fmo);
  const codedW = wMbs * 16, codedH = (2 - fmo) * hMap * 16;
  return { rbsp, flagPos, afterCrop, crop, unitX, unitY, codedW, codedH, headerBits: 8 };
}

// ── HEVC SPS ──

function skipPTL(br, maxSub) {
  br.skip(8); br.skip(32); br.skip(48); br.skip(8);
  const pp = [], lp = [];
  for (let i = 0; i < maxSub; i++) { pp.push(br.bit()); lp.push(br.bit()); }
  if (maxSub > 0) for (let i = maxSub; i < 8; i++) br.skip(2);
  for (let i = 0; i < maxSub; i++) { if (pp[i]) br.skip(88); if (lp[i]) br.skip(8); }
}

function parseHevcSps(nal) {
  const rbsp = unescapeRbsp(nal);
  const br = new BitReader(rbsp, 16); // 2-byte NAL header
  br.skip(4);
  const maxSub = br.u(3); br.skip(1);
  skipPTL(br, maxSub);
  br.ue();
  const chroma = br.ue();
  if (chroma === 3) br.skip(1);
  const codedW = br.ue(), codedH = br.ue();
  const flagPos = br.pos;
  const crop = br.bit() ? [br.ue(), br.ue(), br.ue(), br.ue()] : [0, 0, 0, 0];
  const afterCrop = br.pos;
  const unitX = chroma === 1 || chroma === 2 ? 2 : 1;
  const unitY = chroma === 1 ? 2 : 1;
  return { rbsp, flagPos, afterCrop, crop, unitX, unitY, codedW, codedH, headerBits: 16 };
}

function displayFromSps(s) {
  const [l, r, t, b] = s.crop;
  return {
    x0: l * s.unitX, y0: t * s.unitY,
    width: s.codedW - (l + r) * s.unitX,
    height: s.codedH - (t + b) * s.unitY,
  };
}

/** Writes a new cropping window into the SPS. rect is in display pixels. */
function rewriteSps(nal, s, rect) {
  const d = displayFromSps(s);
  const x = d.x0 + rect.x, y = d.y0 + rect.y;
  const l = x / s.unitX, r = (s.codedW - x - rect.w) / s.unitX;
  const t = y / s.unitY, b = (s.codedH - y - rect.h) / s.unitY;
  if (![l, r, t, b].every((v) => Number.isInteger(v) && v >= 0)) throw new VideoEditError('Crop must line up with the video\'s pixel grid.');
  const br = new BitReader(s.rbsp);
  const end = lastOneBit(s.rbsp);
  const bw = new BitWriter();
  bw.copy(br, 0, s.flagPos);
  bw.bit(1); bw.ue(l); bw.ue(r); bw.ue(t); bw.ue(b);
  bw.copy(br, s.afterCrop, end);
  return escapeRbsp(bw.finish());
}

// ── avcC / hvcC ──

function avcSps(avcC) {
  const n = avcC[5] & 31; let o = 6; const list = [];
  for (let i = 0; i < n; i++) { const len = (avcC[o] << 8) | avcC[o + 1]; list.push({ o, len }); o += 2 + len; }
  return list;
}

function rewriteAvcC(avcC, rect) {
  const list = avcSps(avcC);
  const w = new Writer(avcC.length + 32);
  w.bytes(avcC.subarray(0, 6));
  for (const { o, len } of list) {
    const nal = avcC.subarray(o + 2, o + 2 + len);
    const out = rewriteSps(nal, parseH264Sps(nal), rect);
    w.u16(out.length); w.bytes(out);
  }
  const rest = list.length ? list[list.length - 1].o + 2 + list[list.length - 1].len : 6;
  w.bytes(avcC.subarray(rest));
  return w.done();
}

function hvcArrays(hvcC) {
  let o = 22; const n = hvcC[o++]; const arrays = [];
  for (let i = 0; i < n; i++) {
    const head = hvcC[o]; const type = head & 63; const count = (hvcC[o + 1] << 8) | hvcC[o + 2]; o += 3;
    const nals = [];
    for (let j = 0; j < count; j++) { const len = (hvcC[o] << 8) | hvcC[o + 1]; nals.push(hvcC.subarray(o + 2, o + 2 + len)); o += 2 + len; }
    arrays.push({ head, type, nals });
  }
  return arrays;
}

function rewriteHvcC(hvcC, rect) {
  const arrays = hvcArrays(hvcC);
  const w = new Writer(hvcC.length + 32);
  w.bytes(hvcC.subarray(0, 22)); w.u8(arrays.length);
  for (const a of arrays) {
    w.u8(a.head); w.u16(a.nals.length);
    for (const nal of a.nals) {
      const out = a.type === 33 ? rewriteSps(nal, parseHevcSps(nal), rect) : nal;
      w.u16(out.length); w.bytes(out);
    }
  }
  return w.done();
}

// ───────────────────────── sample tables ─────────────────────────

function fullBox(data) { const v = dv(data); return { version: data[0], v }; }

function readTables(stbl) {
  const stsz = child(stbl, 'stsz');
  if (!stsz) throw new VideoEditError('This video uses a layout that isn\'t supported (compact sample sizes).');
  const sv = dv(stsz.data);
  const fixed = sv.getUint32(4), count = sv.getUint32(8);
  const size = new Uint32Array(count);
  for (let i = 0; i < count; i++) size[i] = fixed || sv.getUint32(12 + i * 4);

  const dts = new Float64Array(count), dur = new Float64Array(count);
  {
    const v = dv(child(stbl, 'stts').data); const n = v.getUint32(4); let i = 0, t = 0;
    for (let e = 0; e < n; e++) {
      const c = v.getUint32(8 + e * 8), d = v.getUint32(12 + e * 8);
      for (let k = 0; k < c && i < count; k++, i++) { dts[i] = t; dur[i] = d; t += d; }
    }
  }
  let cts = null;
  const ctts = child(stbl, 'ctts');
  if (ctts) {
    cts = new Int32Array(count);
    const v = dv(ctts.data); const n = v.getUint32(4); let i = 0;
    for (let e = 0; e < n; e++) {
      const c = v.getUint32(8 + e * 8), off = v.getInt32(12 + e * 8);
      for (let k = 0; k < c && i < count; k++, i++) cts[i] = off;
    }
  }
  let sync = null;
  const stss = child(stbl, 'stss');
  if (stss) {
    sync = new Uint8Array(count);
    const v = dv(stss.data); const n = v.getUint32(4);
    for (let e = 0; e < n; e++) { const idx = v.getUint32(8 + e * 4) - 1; if (idx < count) sync[idx] = 1; }
  }
  const offset = new Float64Array(count), desc = new Uint32Array(count);
  {
    const stco = child(stbl, 'stco'), co64 = child(stbl, 'co64');
    const cv = dv((stco || co64).data); const nChunks = cv.getUint32(4);
    const chunkOff = (c) => (stco ? cv.getUint32(8 + c * 4) : Number(cv.getBigUint64(8 + c * 8)));
    const sc = dv(child(stbl, 'stsc').data); const ne = sc.getUint32(4);
    const ents = [];
    for (let e = 0; e < ne; e++) ents.push([sc.getUint32(8 + e * 12) - 1, sc.getUint32(12 + e * 12), sc.getUint32(16 + e * 12)]);
    let i = 0;
    for (let e = 0; e < ents.length; e++) {
      const [first, per, d] = ents[e]; const last = e + 1 < ents.length ? ents[e + 1][0] : nChunks;
      for (let c = first; c < last && i < count; c++) {
        let o = chunkOff(c);
        for (let k = 0; k < per && i < count; k++, i++) { offset[i] = o; desc[i] = d; o += size[i]; }
      }
    }
  }
  return { count, size, dts, dur, cts, ctsVersion: ctts ? ctts.data[0] : 0, sync, offset, desc };
}

function readEdit(trak) {
  const elst = path(trak, 'edts', 'elst');
  if (!elst) return { mediaTime: 0 };
  const { version, v } = fullBox(elst.data); const n = v.getUint32(4); let o = 8;
  for (let e = 0; e < n; e++) {
    const mt = version === 1 ? Number(v.getBigInt64(o + 8)) : v.getInt32(o + 4);
    o += version === 1 ? 20 : 12;
    if (mt >= 0) return { mediaTime: mt };
  }
  return { mediaTime: 0 };
}

// ───────────────────────── inspect ─────────────────────────

async function findTopLevel(file) {
  const boxes = []; let off = 0;
  while (off + 8 <= file.size) {
    const h = await readBytes(file, off, 16); const v = dv(h);
    let size = v.getUint32(0); const type = typeAt(h, 4); let hdr = 8;
    if (size === 1) { size = Number(v.getBigUint64(8)); hdr = 16; } else if (size === 0) size = file.size - off;
    if (size < hdr) throw new VideoEditError('This file looks damaged.');
    boxes.push({ type, start: off, size, hdr });
    off += size;
  }
  return boxes;
}

export async function inspectVideo(file) {
  const head = await readBytes(file, 0, 12);
  if (head.length < 12 || !['ftyp', 'moov', 'mdat', 'wide', 'free', 'skip'].includes(typeAt(head, 4))) {
    throw new VideoEditError('Only MP4 and MOV videos are supported.');
  }
  const top = await findTopLevel(file);
  const moovBox = top.find((b) => b.type === 'moov');
  if (!moovBox) throw new VideoEditError('This video has no index (it may be incomplete).');
  if (top.some((b) => b.type === 'moof')) throw new VideoEditError('This video is a streaming (fragmented) MP4, which isn\'t supported yet.');
  const ftypBox = top.find((b) => b.type === 'ftyp');
  const moovBytes = await readBytes(file, moovBox.start, moovBox.size);
  const moov = { type: 'moov', children: parseBoxes(moovBytes, moovBox.hdr, moovBox.size) };
  const ftyp = ftypBox ? await readBytes(file, ftypBox.start, ftypBox.size) : null;

  const mvhd = child(moov, 'mvhd');
  const mv = fullBox(mvhd.data);
  const movieTs = mv.version === 1 ? mv.v.getUint32(20) : mv.v.getUint32(12);

  const tracks = [];
  for (const trak of moov.children.filter((c) => c.type === 'trak')) {
    const hdlr = path(trak, 'mdia', 'hdlr');
    const handler = typeAt(hdlr.data, 8);
    if (handler !== 'vide' && handler !== 'soun') continue;
    const md = fullBox(path(trak, 'mdia', 'mdhd').data);
    const ts = md.version === 1 ? md.v.getUint32(20) : md.v.getUint32(12);
    const stbl = path(trak, 'mdia', 'minf', 'stbl');
    const stsd = child(stbl, 'stsd');
    const entryType = typeAt(stsd.data, 12);
    tracks.push({ trak, handler, ts, stbl, entryType });
  }
  const video = tracks.find((t) => t.handler === 'vide');
  if (!video) throw new VideoEditError('No video track found in this file.');
  const audio = tracks.find((t) => t.handler === 'soun') || null;

  // Size, rotation and whether we can crop.
  const tk = fullBox(child(video.trak, 'tkhd').data);
  const tkd = child(video.trak, 'tkhd').data;
  const m = (i) => tk.v.getInt32(tkd.length - 44 + i * 4);
  // Display rotation from the track matrix (a b / c d). Mirrored or skewed matrices aren't supported.
  const [a, b, c, d] = [m(0), m(1), m(3), m(4)].map((x) => Math.round(x / 0x10000));
  const rotation = a === 1 && d === 1 && !b && !c ? 0 : !a && b === 1 && c === -1 && !d ? 90
    : a === -1 && d === -1 && !b && !c ? 180 : !a && b === -1 && c === 1 && !d ? 270 : null;
  const rotated = rotation !== 0;
  const entry = child(video.stbl, 'stsd').data; // payload: version/flags(4) count(4) entry...
  const entryBoxes = parseBoxes(entry, 8 + 86, 8 + dv(entry).getUint32(8));
  let sps = null, codec = 'other';
  const t = video.entryType;
  if (t === 'avc1') { codec = 'h264'; const c = entryBoxes.find((b) => b.type === 'avcC'); const l = c && avcSps(c.data)[0]; if (l) sps = parseH264Sps(c.data.subarray(l.o + 2, l.o + 2 + l.len)); }
  if (t === 'hvc1') { codec = 'hevc'; const c = entryBoxes.find((b) => b.type === 'hvcC'); const a = c && hvcArrays(c.data).find((x) => x.type === 33); if (a) sps = parseHevcSps(a.nals[0]); }
  const sampleW = dv(entry).getUint16(8 + 32), sampleH = dv(entry).getUint16(8 + 34);
  const disp = sps ? displayFromSps(sps) : { width: sampleW, height: sampleH };

  let cropReason = null;
  if (!sps) cropReason = t === 'avc3' || t === 'hev1' ? 'This video stores its settings in a way that can\'t be cropped instantly.' : 'Instant crop works with H.264 and HEVC videos only.';
  else if (rotation === null) cropReason = 'This video is mirrored or skewed, so it can\'t be cropped instantly.';
  const sideways = rotation === 90 || rotation === 270;

  const movieDur = mv.version === 1 ? Number(mv.v.getBigUint64(24)) : mv.v.getUint32(16);
  return {
    file, ftyp, moov, movieTs, video, audio,
    codec,
    // Width/height/units are as the video is shown on screen (after rotation).
    width: sideways ? disp.height : disp.width, height: sideways ? disp.width : disp.height,
    codedWidth: disp.width, codedHeight: disp.height,
    unitX: (sideways ? sps?.unitY : sps?.unitX) || 2, unitY: (sideways ? sps?.unitX : sps?.unitY) || 2,
    canCrop: !cropReason, cropReason, rotated, rotation,
    duration: movieDur / movieTs,
    container: ftyp && typeAt(ftyp, 8) === 'qt  ' ? 'mov' : 'mp4',
  };
}

// ───────────────────────── edit ─────────────────────────

function rle(values) {
  const out = [];
  for (const v of values) { const l = out[out.length - 1]; if (l && l[1] === v) l[0]++; else out.push([1, v]); }
  return out;
}

function fullHeader(w, version) { w.u8(version); w.u8(0); w.u8(0); w.u8(0); }

function buildStbl(origStbl, sel, chunks, offsets, newStsd) {
  const keep = [];
  // stsd
  keep.push({ type: 'stsd', data: newStsd || child(origStbl, 'stsd').data });
  // stts
  { const r = rle(sel.dur); const w = new Writer(8 + r.length * 8); fullHeader(w, 0); w.u32(r.length); for (const [c, d] of r) { w.u32(c); w.u32(d); } keep.push({ type: 'stts', data: w.done() }); }
  // ctts
  if (sel.cts) {
    const r = rle(sel.cts); const neg = sel.cts.some((x) => x < 0);
    const w = new Writer(8 + r.length * 8); fullHeader(w, neg ? 1 : sel.ctsVersion); w.u32(r.length);
    for (const [c, off] of r) { w.u32(c); w.i32(off); }
    keep.push({ type: 'ctts', data: w.done() });
  }
  // stss
  if (sel.sync) {
    const idx = []; sel.sync.forEach((s, i) => { if (s) idx.push(i + 1); });
    const w = new Writer(8 + idx.length * 4); fullHeader(w, 0); w.u32(idx.length); idx.forEach((i) => w.u32(i));
    keep.push({ type: 'stss', data: w.done() });
  }
  // stsc
  {
    const ents = [];
    chunks.forEach((c, i) => { const l = ents[ents.length - 1]; if (!l || l[1] !== c.count || l[2] !== c.desc) ents.push([i + 1, c.count, c.desc]); });
    const w = new Writer(8 + ents.length * 12); fullHeader(w, 0); w.u32(ents.length);
    for (const [f, n, d] of ents) { w.u32(f); w.u32(n); w.u32(d); }
    keep.push({ type: 'stsc', data: w.done() });
  }
  // stsz
  { const w = new Writer(12 + sel.size.length * 4); fullHeader(w, 0); w.u32(0); w.u32(sel.size.length); sel.size.forEach((s) => w.u32(s)); keep.push({ type: 'stsz', data: w.done() }); }
  // co64
  { const w = new Writer(8 + chunks.length * 8); fullHeader(w, 0); w.u32(chunks.length); chunks.forEach((c) => w.u64(offsets ? offsets[c.outIndex] : 0)); keep.push({ type: 'co64', data: w.done() }); }
  return { type: 'stbl', children: keep };
}

function patchDuration(data, version, offV0, offV1, value) {
  const d = data.slice(); const v = dv(d);
  if (version === 1) v.setBigUint64(offV1, BigInt(Math.round(value))); else v.setUint32(offV0, Math.min(0xffffffff, Math.round(value)));
  return d;
}

function makeElst(dur, mediaTime) {
  const w = new Writer(28); fullHeader(w, 1); w.u32(1); w.u64(dur); w.i64(mediaTime); w.u16(1); w.u16(0);
  return { type: 'edts', children: [{ type: 'elst', data: w.done() }] };
}

function clapBox(info, rect) {
  // Clean aperture: size and centre offset relative to the stored picture.
  const W = info.codedWidth, H = info.codedHeight;
  const w = new Writer(32);
  w.u32(rect.w); w.u32(1); w.u32(rect.h); w.u32(1);
  w.i32(2 * rect.x + rect.w - W); w.u32(2); w.i32(2 * rect.y + rect.h - H); w.u32(2);
  return { type: 'clap', data: w.done() };
}

function newVideoStsd(info, rect, mode = 'sps') {
  const old = child(info.video.stbl, 'stsd').data;
  const entrySize = dv(old).getUint32(8);
  const entry = old.subarray(8, 8 + entrySize);
  const head = entry.slice(8, 86); // sample entry fields (after size+type)
  const v = dv(head);
  if (mode === 'sps' || mode === 'both') { v.setUint16(24, rect.w); v.setUint16(26, rect.h); }
  let kids = parseBoxes(entry, 86, entrySize).filter((b) => b.type !== 'clap');
  if (mode === 'sps' || mode === 'both') {
    for (const k of kids) {
      if (k.type === 'avcC') k.data = rewriteAvcC(k.data, rect);
      if (k.type === 'hvcC') k.data = rewriteHvcC(k.data, rect);
    }
  }
  if (mode !== 'sps') {
    const clap = mode === 'both' ? clapBox({ codedWidth: rect.w, codedHeight: rect.h }, { x: 0, y: 0, w: rect.w, h: rect.h }) : clapBox(info, rect);
    const at = kids.findIndex((b) => b.type === 'pasp');
    kids = at >= 0 ? [...kids.slice(0, at), clap, ...kids.slice(at)] : [...kids, clap];
  }
  const kidBytes = kids.map(serialize);
  const w = new Writer(old.length + 64);
  w.bytes(old.subarray(0, 8));
  const entryPayload = new Writer(); entryPayload.bytes(head); kidBytes.forEach((b) => entryPayload.bytes(b));
  w.bytes(box(info.video.entryType, entryPayload.done()));
  w.bytes(old.subarray(8 + entrySize)); // any further sample entries, unchanged
  return w.done();
}

/** Converts a crop rectangle from on-screen orientation to the stored orientation. */
function toStored(info, r) {
  const W = info.codedWidth, H = info.codedHeight;
  switch (info.rotation) {
    case 90: return { x: r.y, y: H - r.x - r.w, w: r.h, h: r.w };
    case 180: return { x: W - r.x - r.w, y: H - r.y - r.h, w: r.w, h: r.h };
    case 270: return { x: W - r.y - r.h, y: r.x, w: r.h, h: r.w };
    default: return { ...r };
  }
}

export async function editVideo(file, info, { crop = null, start = 0, end = Infinity, _cropMode = 'sps', _trackDims = 'crop' } = {}) {
  if (crop && !info.canCrop) throw new VideoEditError(info.cropReason);
  if (crop) {
    const r = crop;
    if (r.x < 0 || r.y < 0 || r.w < 16 || r.h < 16 || r.x + r.w > info.width || r.y + r.h > info.height) throw new VideoEditError('The crop box is outside the video.');
    crop = toStored(info, r);
  }
  const tracks = [info.video, info.audio].filter(Boolean).map((t) => ({ ...t, tab: readTables(t.stbl), edit: readEdit(t.trak) }));
  const V = tracks[0];
  const vt = V.tab;
  const pts = (i) => vt.dts[i] + (vt.cts ? vt.cts[i] : 0) - V.edit.mediaTime; // presentation ticks
  const startTicks = Math.max(0, start) * V.ts;
  const endTicks = Math.min(end, info.duration) * V.ts;

  // Video: start at the last keyframe at or before the requested start.
  let k = 0;
  for (let i = 0; i < vt.count; i++) {
    if ((!vt.sync || vt.sync[i]) && pts(i) <= startTicks + 1) k = i;
    if (vt.dts[i] - V.edit.mediaTime > startTicks + V.ts * 30) break;
  }
  let kEnd = vt.count;
  for (let i = k + 1; i < vt.count; i++) if (pts(i) >= endTicks && vt.dts[i] - V.edit.mediaTime >= endTicks) { kEnd = i; break; }
  const S = pts(k) / V.ts;                       // actual start, seconds
  const E = Math.min(endTicks / V.ts, info.duration);
  if (E - S <= 0.05) throw new VideoEditError('The trimmed part is too short.');

  const sels = [];
  const pick = (T, a, b) => {
    const t = T.tab; const n = b - a;
    const s = {
      size: Array.from(t.size.subarray(a, b)), dur: Array.from(t.dur.subarray(a, b)),
      cts: t.cts ? Array.from(t.cts.subarray(a, b)) : null, ctsVersion: t.ctsVersion,
      sync: t.sync ? Array.from(t.sync.subarray(a, b)) : null,
      offset: Array.from(t.offset.subarray(a, b)), desc: Array.from(t.desc.subarray(a, b)), n,
    };
    s.mediaDur = s.dur.reduce((x, y) => x + y, 0);
    return s;
  };
  const vSel = pick(V, k, kEnd);
  vSel.mediaTime = vt.cts ? vt.cts[k] : 0;
  sels.push(vSel);

  if (tracks[1]) {
    const A = tracks[1]; const at = A.tab;
    const ap = (i) => at.dts[i] - A.edit.mediaTime;
    const sA = S * A.ts, eA = E * A.ts;
    let a = 0; while (a < at.count - 1 && ap(a) + at.dur[a] <= sA) a++;
    let b = a; while (b < at.count && ap(b) < eA) b++;
    if (b > a) {
      const aSel = pick(A, a, b);
      aSel.mediaTime = Math.max(0, Math.round(sA + A.edit.mediaTime - at.dts[a]));
      sels.push(aSel);
    } else tracks.pop();
  }

  // Lay out the new media data in the original order (keeps audio and video interleaved).
  const order = [];
  sels.forEach((s, ti) => { for (let i = 0; i < s.n; i++) order.push([s.offset[i], ti, i]); });
  order.sort((x, y) => x[0] - y[0]);
  const chunksPerTrack = sels.map(() => []);
  const runs = []; let outPos = 0; let prev = null; let outIndex = 0;
  const chunkStarts = [];
  for (const [off, ti, i] of order) {
    const size = sels[ti].size[i];
    const list = chunksPerTrack[ti];
    const last = list[list.length - 1];
    if (prev && prev.ti === ti && prev.end === off && last && last.desc === sels[ti].desc[i]) last.count++;
    else { list.push({ count: 1, desc: sels[ti].desc[i], outIndex }); chunkStarts.push(outPos); outIndex++; }
    const r = runs[runs.length - 1];
    if (r && r.end === off) r.end += size; else runs.push({ start: off, end: off + size });
    prev = { ti, end: off + size };
    outPos += size;
  }
  const mdatLen = outPos;
  const mdatHdr = mdatLen + 8 > 0xffffffff ? 16 : 8;

  // Movie-level durations.
  const movieDur = Math.round((E - S) * info.movieTs);

  const buildMoov = (offsets) => {
    const children = [];
    for (const c of info.moov.children) {
      if (c.type === 'mvhd') {
        const { version } = fullBox(c.data);
        const d = patchDuration(c.data, version, 16, 24, movieDur);
        const v = dv(d); v.setUint32(d.length - 4, tracks.length + 1); // next_track_ID
        children.push({ type: 'mvhd', data: d });
      } else if (c.type === 'trak') {
        const ti = tracks.findIndex((t) => t.trak === c);
        if (ti < 0) continue;
        const T = tracks[ti], s = sels[ti];
        const tkhd = child(c, 'tkhd'); const tv = fullBox(tkhd.data);
        let td2 = patchDuration(tkhd.data, tv.version, 20, 28, movieDur);
        const tdv = dv(td2);
        tdv.setUint32(tv.version === 1 ? 20 : 12, ti + 1); // track_ID
        if (ti === 0 && crop && _trackDims === 'crop') { tdv.setUint32(td2.length - 8, crop.w * 65536); tdv.setUint32(td2.length - 4, crop.h * 65536); }
        const mdia = child(c, 'mdia');
        const mdhd = child(mdia, 'mdhd'); const mdv = fullBox(mdhd.data);
        const minf = child(mdia, 'minf');
        const stbl = buildStbl(child(minf, 'stbl'), s, chunksPerTrack[ti], offsets, ti === 0 && crop ? newVideoStsd(info, crop, _cropMode) : null);
        const newMinf = { type: 'minf', children: minf.children.map((x) => (x.type === 'stbl' ? stbl : x)) };
        const newMdia = { type: 'mdia', children: mdia.children.map((x) => (x.type === 'mdhd' ? { type: 'mdhd', data: patchDuration(mdhd.data, mdv.version, 16, 24, s.mediaDur) } : x.type === 'minf' ? newMinf : x)) };
        const kids = [{ type: 'tkhd', data: td2 }, makeElst(movieDur, s.mediaTime), newMdia];
        children.push({ type: 'trak', children: kids });
      } else if (c.type === 'udta') {
        children.push(c);
      }
    }
    return serialize({ type: 'moov', children });
  };

  const ftyp = info.ftyp || box('ftyp', te('isom\0\0\x02\0isomiso2avc1mp41'));
  const probe = buildMoov(null);
  const dataStart = ftyp.length + probe.length + mdatHdr;
  const offsets = chunkStarts.map((p) => dataStart + p);
  const moov = buildMoov(offsets);
  if (moov.length !== probe.length) throw new VideoEditError('Internal size mismatch.');

  const mdatHeader = new Writer(16);
  if (mdatHdr === 16) { mdatHeader.u32(1); mdatHeader.bytes(te('mdat')); mdatHeader.u64(mdatLen + 16); }
  else { mdatHeader.u32(mdatLen + 8); mdatHeader.bytes(te('mdat')); }

  const parts = [ftyp, moov, mdatHeader.done(), ...runs.map((r) => file.slice(r.start, r.end))];
  const blob = new Blob(parts, { type: info.container === 'mov' ? 'video/quicktime' : 'video/mp4' });
  return { blob, start: S, end: E };
}

// ───────────────────────── secure (re-encoded) save ─────────────────────────
// Decodes the video, draws only the kept area, and re-encodes it with the browser's
// hardware video encoder (WebCodecs). Cropped-out pixels are permanently gone and
// trims are frame-exact. Audio is copied as-is (trimmed to the same range).

function hex2(n) { return n.toString(16).padStart(2, '0'); }

function hevcCodecString(h) {
  const space = h[1] >> 6, tier = (h[1] >> 5) & 1, profile = h[1] & 31;
  let compat = ((h[2] << 24) | (h[3] << 16) | (h[4] << 8) | h[5]) >>> 0;
  let rev = 0; for (let i = 0; i < 32; i++) { rev = (rev << 1) | (compat & 1); compat >>>= 1; }
  const cons = Array.from(h.subarray(6, 12));
  while (cons.length && cons[cons.length - 1] === 0) cons.pop();
  return ['hvc1', (space ? String.fromCharCode(64 + space) : '') + profile, (rev >>> 0).toString(16),
    (tier ? 'H' : 'L') + h[12], ...cons.map((b) => b.toString(16).toUpperCase())].join('.');
}

function decoderConfigFor(info) {
  const stsd = child(info.video.stbl, 'stsd').data;
  const entrySize = dv(stsd).getUint32(8);
  const kids = parseBoxes(stsd, 8 + 86, 8 + entrySize);
  const codedWidth = dv(stsd).getUint16(40), codedHeight = dv(stsd).getUint16(42);
  if (info.codec === 'h264') {
    const c = kids.find((b) => b.type === 'avcC');
    return { codec: `avc1.${hex2(c.data[1])}${hex2(c.data[2])}${hex2(c.data[3])}`, description: c.data.slice(), codedWidth, codedHeight };
  }
  if (info.codec === 'hevc') {
    const c = kids.find((b) => b.type === 'hvcC');
    return { codec: hevcCodecString(c.data), description: c.data.slice(), codedWidth, codedHeight };
  }
  return null;
}

async function pickEncoderConfig(w, h, fps) {
  const bitrate = Math.round(Math.min(20e6, Math.max(1e6, w * h * fps * 0.12)));
  const mbs = Math.ceil(w / 16) * Math.ceil(h / 16) * fps;
  const level = mbs <= 245760 ? '28' : mbs <= 522240 ? '2a' : mbs <= 983040 ? '33' : '34';
  const base = { width: w, height: h, bitrate, framerate: fps, avc: { format: 'avc' }, latencyMode: 'quality' };
  for (const codec of [`avc1.6400${level}`, `avc1.4d00${level}`, `avc1.4200${level}`]) {
    for (const hardwareAcceleration of ['prefer-hardware', 'no-preference']) {
      const cfg = { ...base, codec, hardwareAcceleration };
      try { if ((await VideoEncoder.isConfigSupported(cfg)).supported) return cfg; } catch { /* try next */ }
    }
  }
  throw new VideoEditError('This browser can\'t encode video. Try the latest Chrome, Edge or Safari.');
}

function visualSampleEntry(type, w, h, children) {
  const wr = new Writer(128);
  for (let i = 0; i < 6; i++) wr.u8(0);
  wr.u16(1);                       // data_reference_index
  for (let i = 0; i < 16; i++) wr.u8(0);
  wr.u16(w); wr.u16(h);
  wr.u32(0x00480000); wr.u32(0x00480000); wr.u32(0); wr.u16(1);
  for (let i = 0; i < 32; i++) wr.u8(0);
  wr.u16(0x18); wr.u16(0xffff);
  children.forEach((c) => wr.bytes(c));
  return box(type, wr.done());
}

/**
 * Re-encodes the kept part of the video. crop is in on-screen pixels (or null).
 * onProgress(fraction) is called as frames are processed.
 */
export async function secureEditVideo(file, info, { crop = null, start = 0, end = Infinity, onProgress = () => {} } = {}) {
  if (typeof VideoDecoder === 'undefined' || typeof VideoEncoder === 'undefined') {
    throw new VideoEditError('This browser can\'t do a secure save. Use the latest Chrome, Edge or Safari.');
  }
  const decCfg = decoderConfigFor(info);
  if (!decCfg) throw new VideoEditError('Secure save works with H.264 and HEVC videos only.');
  if (info.rotation === null) throw new VideoEditError('This video is mirrored or skewed and can\'t be re-encoded here.');
  let decAccel = null;
  for (const hardwareAcceleration of ['prefer-hardware', 'no-preference']) {
    try { if ((await VideoDecoder.isConfigSupported({ ...decCfg, hardwareAcceleration })).supported) { decAccel = hardwareAcceleration; break; } } catch { /* next */ }
  }
  if (!decAccel) throw new VideoEditError('This browser can\'t decode this video (HEVC isn\'t supported in every browser). Try Safari or Chrome.');

  const W = info.width, H = info.height;               // on-screen size
  const r = crop ? { ...crop } : { x: 0, y: 0, w: W, h: H };
  r.w -= r.w % 2; r.h -= r.h % 2;
  const s = toStored(info, r);                          // the same area in stored orientation

  const V = { ...info.video, tab: readTables(info.video.stbl), edit: readEdit(info.video.trak) };
  const vt = V.tab;
  const ptsT = (i) => vt.dts[i] + (vt.cts ? vt.cts[i] : 0) - V.edit.mediaTime;
  const S = Math.max(0, start), E = Math.min(end, info.duration);
  if (E - S <= 0.05) throw new VideoEditError('The trimmed part is too short.');
  const sT = S * V.ts, eT = E * V.ts;

  // Decode from the keyframe before the start; keep only frames inside [S, E).
  let k = 0;
  for (let i = 0; i < vt.count; i++) {
    if ((!vt.sync || vt.sync[i]) && ptsT(i) <= sT + 1) k = i;
    if (vt.dts[i] - V.edit.mediaTime > sT + V.ts * 30) break;
  }
  let kEnd = vt.count;
  for (let i = k + 1; i < vt.count; i++) if (vt.dts[i] - V.edit.mediaTime >= eT + V.ts * 2) { kEnd = i; break; }
  let keepFrames = 0;
  for (let i = k; i < kEnd; i++) { const p = ptsT(i); if (p >= sT - 1 && p < eT) keepFrames++; }
  const fps = Math.min(120, Math.max(1, Math.round((keepFrames / (E - S)) * 100) / 100)) || 30;

  const encCfg = await pickEncoderConfig(r.w, r.h, fps);
  const canvas = typeof OffscreenCanvas !== 'undefined' ? new OffscreenCanvas(r.w, r.h) : Object.assign(document.createElement('canvas'), { width: r.w, height: r.h });
  const ctx = canvas.getContext('2d', { alpha: false });
  const rot = info.rotation || 0;

  const out = [];                 // encoded chunks: { data, pts, dur, key }
  let avcC = null, err = null;
  const encoder = new VideoEncoder({
    output: (chunk, meta) => {
      if (meta?.decoderConfig?.description && !avcC) avcC = new Uint8Array(meta.decoderConfig.description);
      const data = new Uint8Array(chunk.byteLength); chunk.copyTo(data);
      out.push({ data, pts: chunk.timestamp, dur: chunk.duration || 0, key: chunk.type === 'key' });
    },
    error: (e) => { err = e; },
  });
  encoder.configure(encCfg);

  const startUs = S * 1e6, endUs = E * 1e6;
  const gopUs = 2e6; let lastKeyUs = -Infinity; let done = 0;
  const decoder = new VideoDecoder({
    output: (frame) => {
      try {
        const t = frame.timestamp;
        if (t < startUs - 500 || t >= endUs) return;
        ctx.save();
        if (rot === 90) { ctx.translate(s.h, 0); ctx.rotate(Math.PI / 2); }
        else if (rot === 180) { ctx.translate(s.w, s.h); ctx.rotate(Math.PI); }
        else if (rot === 270) { ctx.translate(0, s.w); ctx.rotate(-Math.PI / 2); }
        ctx.drawImage(frame, s.x, s.y, s.w, s.h, 0, 0, s.w, s.h);
        ctx.restore();
        const ts = Math.max(0, Math.round(t - startUs));
        const vf = new VideoFrame(canvas, { timestamp: ts, duration: frame.duration || Math.round(1e6 / fps) });
        const key = ts - lastKeyUs >= gopUs;
        if (key) lastKeyUs = ts;
        encoder.encode(vf, { keyFrame: key });
        vf.close();
        done++; if (done % 15 === 0) onProgress(Math.min(0.99, done / keepFrames));
      } finally { frame.close(); }
    },
    error: (e) => { err = e; },
  });
  decoder.configure({ ...decCfg, hardwareAcceleration: decAccel });

  // Feed samples, reading the file in large blocks.
  const WINDOW = 8 * 1024 * 1024;
  let buf = null, bufStart = 0;
  const readSample = async (off, size) => {
    if (!buf || off < bufStart || off + size > bufStart + buf.length) {
      buf = await readBytes(file, off, Math.max(WINDOW, size)); bufStart = off;
    }
    return buf.subarray(off - bufStart, off - bufStart + size);
  };
  const waitQueues = () => new Promise((res) => {
    const check = () => (decoder.decodeQueueSize < 6 && encoder.encodeQueueSize < 6 ? res() : setTimeout(check, 2));
    check();
  });
  for (let i = k; i < kEnd; i++) {
    if (err) throw new VideoEditError(`The browser's video engine stopped: ${err.message || err}`);
    await waitQueues();
    if (err || decoder.state === 'closed') throw new VideoEditError(`The browser's video engine stopped: ${err?.message || err || 'closed'}`);
    const data = await readSample(vt.offset[i], vt.size[i]);
    decoder.decode(new EncodedVideoChunk({
      type: (!vt.sync || vt.sync[i]) ? 'key' : 'delta',
      timestamp: Math.round((ptsT(i) / V.ts) * 1e6),
      duration: Math.round((vt.dur[i] / V.ts) * 1e6),
      data,
    }));
  }
  await decoder.flush(); decoder.close();
  await encoder.flush(); encoder.close();
  if (err) throw new VideoEditError(`The browser's video engine stopped: ${err.message || err}`);
  if (!out.length || !avcC) throw new VideoEditError('Nothing was encoded.');

  // ── Video track timing (encoder output is in decode order).
  const TS = 90000;
  const vPts = out.map((c) => Math.round((c.pts / 1e6) * TS));
  const sortedPts = [...vPts].sort((a, b) => a - b);
  let shift = 0; vPts.forEach((p, i) => { shift = Math.max(shift, sortedPts[i] - p); });
  const vDts = sortedPts.map((p) => p - shift);
  const frameTicks = Math.round(TS / fps);
  const vDur = vDts.map((d, i) => (i + 1 < vDts.length ? vDts[i + 1] - d : frameTicks));
  const vCts = vPts.map((p, i) => p - vDts[i]);
  const hasCts = vCts.some((x) => x !== 0);
  const vSel = {
    size: out.map((c) => c.data.length), dur: vDur, cts: hasCts ? vCts : null, ctsVersion: 0,
    sync: out.map((c) => (c.key ? 1 : 0)), desc: out.map(() => 1), n: out.length,
  };
  vSel.mediaDur = vDur.reduce((a, b) => a + b, 0);
  const vMediaTime = hasCts ? Math.min(...vCts.map((c, i) => vDts[i] + c)) : 0;
  const videoBlob = new Blob(out.map((c) => c.data));
  let vOff = 0; const vOffsets = out.map((c) => { const o = vOff; vOff += c.data.length; return o; });

  // ── Audio: copy the original samples covering [S, E).
  let A = null, aSel = null;
  if (info.audio) {
    A = { ...info.audio, tab: readTables(info.audio.stbl), edit: readEdit(info.audio.trak) };
    const at = A.tab; const ap = (i) => at.dts[i] - A.edit.mediaTime;
    const sA = S * A.ts, eA = E * A.ts;
    let a = 0; while (a < at.count - 1 && ap(a) + at.dur[a] <= sA) a++;
    let b = a; while (b < at.count && ap(b) < eA) b++;
    if (b > a) {
      aSel = {
        size: Array.from(at.size.subarray(a, b)), dur: Array.from(at.dur.subarray(a, b)), cts: null, ctsVersion: 0,
        sync: at.sync ? Array.from(at.sync.subarray(a, b)) : null, offset: Array.from(at.offset.subarray(a, b)),
        desc: Array.from(at.desc.subarray(a, b)), n: b - a,
      };
      aSel.mediaDur = aSel.dur.reduce((x, y) => x + y, 0);
      aSel.mediaTime = Math.max(0, Math.round(sA + A.edit.mediaTime - at.dts[a]));
      aSel.times = aSel.dur.reduce((acc, d, i) => { acc.push(i ? acc[i - 1] + aSel.dur[i - 1] : 0); return acc; }, []).map((t) => (t - aSel.mediaTime) / A.ts);
    }
  }

  // ── Interleave about one second of video, then the matching audio.
  const vTimes = vDts.map((d) => (d - vMediaTime) / TS);
  const parts = []; const vChunks = [], aChunks = []; const chunkStarts = []; let pos = 0;
  let vi = 0, ai = 0, outIndex = 0;
  const audioReads = [];   // [partIndex, start, end] filled in after layout
  const pushRun = (list, src, offs, sizes, from, to, isVideo) => {
    if (to <= from) return;
    list.push({ count: to - from, desc: 1, outIndex: outIndex++ });
    chunkStarts.push(pos);
    if (isVideo) { parts.push(src.slice(offs[from], offs[to - 1] + sizes[to - 1])); for (let i = from; i < to; i++) pos += sizes[i]; }
    else {
      // audio: original file slices (coalesce contiguous samples)
      let runS = offs[from], runE = offs[from];
      for (let i = from; i < to; i++) {
        if (offs[i] !== runE) { audioReads.push([parts.length, runS, runE]); parts.push(null); runS = offs[i]; runE = offs[i]; }
        runE += sizes[i]; pos += sizes[i];
      }
      audioReads.push([parts.length, runS, runE]); parts.push(null);
    }
  };
  for (let t = 1; vi < vSel.n || (aSel && ai < aSel.n); t += 1) {
    const v0 = vi; while (vi < vSel.n && vTimes[vi] < t) vi++;
    pushRun(vChunks, videoBlob, vOffsets, vSel.size, v0, vi, true);
    if (aSel) { const a0 = ai; while (ai < aSel.n && aSel.times[ai] < t) ai++; pushRun(aChunks, null, aSel.offset, aSel.size, a0, ai, false); }
  }
  const mdatLen = pos, mdatHdr = mdatLen + 8 > 0xffffffff ? 16 : 8;
  for (const [pi, a, b] of audioReads) parts[pi] = await readBytes(file, a, b - a);

  // ── Movie header.
  const movieTs = info.movieTs, movieDur = Math.round((E - S) * movieTs);
  const avcBox = box('avcC', avcC);
  const newStsd = (() => { const w = new Writer(); fullHeader(w, 0); w.u32(1); w.bytes(visualSampleEntry('avc1', r.w, r.h, [avcBox])); return w.done(); })();

  const buildMoov = (offsets) => {
    const kids = [];
    for (const c of info.moov.children) {
      if (c.type === 'mvhd') {
        const { version } = fullBox(c.data);
        const d = patchDuration(c.data, version, 16, 24, movieDur);
        dv(d).setUint32(d.length - 4, aSel ? 3 : 2);
        kids.push({ type: 'mvhd', data: d });
      }
    }
    // video track
    {
      const tkhd = child(info.video.trak, 'tkhd'); const tv = fullBox(tkhd.data);
      const t = patchDuration(tkhd.data, tv.version, 20, 28, movieDur); const v = dv(t);
      v.setUint32(tv.version === 1 ? 20 : 12, 1);
      const mOff = t.length - 44; [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000].forEach((x, i) => v.setInt32(mOff + i * 4, x));
      v.setUint32(t.length - 8, r.w * 65536); v.setUint32(t.length - 4, r.h * 65536);
      const mdia = child(info.video.trak, 'mdia');
      const md = new Writer(); fullHeader(md, 1); md.u64(0); md.u64(0); md.u32(TS); md.u64(vSel.mediaDur); md.u16(0x55c4); md.u16(0);
      const minf = child(mdia, 'minf');
      const stbl = buildStbl(child(minf, 'stbl'), vSel, vChunks, offsets, newStsd);
      kids.push({ type: 'trak', children: [
        { type: 'tkhd', data: t }, makeElst(movieDur, vMediaTime),
        { type: 'mdia', children: [{ type: 'mdhd', data: md.done() }, child(mdia, 'hdlr'),
          { type: 'minf', children: minf.children.map((x) => (x.type === 'stbl' ? stbl : x)) }] },
      ] });
    }
    if (aSel) {
      const tkhd = child(A.trak, 'tkhd'); const tv = fullBox(tkhd.data);
      const t = patchDuration(tkhd.data, tv.version, 20, 28, movieDur);
      dv(t).setUint32(tv.version === 1 ? 20 : 12, 2);
      const mdia = child(A.trak, 'mdia'); const mdhd = child(mdia, 'mdhd'); const mv = fullBox(mdhd.data);
      const minf = child(mdia, 'minf');
      const stbl = buildStbl(child(minf, 'stbl'), aSel, aChunks, offsets, null);
      kids.push({ type: 'trak', children: [
        { type: 'tkhd', data: t }, makeElst(movieDur, aSel.mediaTime),
        { type: 'mdia', children: mdia.children.map((x) => (x.type === 'mdhd' ? { type: 'mdhd', data: patchDuration(mdhd.data, mv.version, 16, 24, aSel.mediaDur) }
          : x.type === 'minf' ? { type: 'minf', children: minf.children.map((y) => (y.type === 'stbl' ? stbl : y)) } : x)) },
      ] });
    }
    return serialize({ type: 'moov', children: kids });
  };

  const ftyp = box('ftyp', te('isom\0\0\x02\0isomiso2avc1mp41'));
  const probe = buildMoov(null);
  const dataStart = ftyp.length + probe.length + mdatHdr;
  const moov = buildMoov(chunkStarts.map((p) => dataStart + p));
  const mh = new Writer(16);
  if (mdatHdr === 16) { mh.u32(1); mh.bytes(te('mdat')); mh.u64(mdatLen + 16); } else { mh.u32(mdatLen + 8); mh.bytes(te('mdat')); }
  onProgress(1);
  return { blob: new Blob([ftyp, moov, mh.done(), ...parts], { type: 'video/mp4' }), start: S, end: E, width: r.w, height: r.h, encoder: encCfg.codec };
}
