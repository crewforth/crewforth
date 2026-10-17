// qr.js — a QR code for a viewer's link, made in the page: no dependency, no request.
//
// Byte mode, error correction level M (a phone reads it off a laptop screen at an angle), versions 1 to 10: up to
// 213 bytes, which a Wi-Fi link with a token (about 70) fits in with room to spare. The construction is ISO/IEC
// 18004's, in the order Project Nayuki's reference implementation lays it out: data and padding, Reed–Solomon error
// correction per block, interleaving, the function patterns, the codewords in their zigzag, the eight masks scored by
// the standard's four penalty rules, and the format (and, from version 7, version) bits. Checked against an
// independent decoder (OpenCV's QRCodeDetector) on every version and mask; the self-check pins the result.

const ECC_M = { perBlock: [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26], blocks: [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5], formatBits: 0 };
const MAX_VERSION = 10;

function rawModules(ver) {
  let n = (16 * ver + 128) * ver + 64;
  if (ver >= 2) {
    const align = Math.floor(ver / 7) + 2;
    n -= (25 * align - 10) * align - 55;
    if (ver >= 7) n -= 36;
  }
  return n;
}
const dataCodewords = (ver) => Math.floor(rawModules(ver) / 8) - ECC_M.perBlock[ver] * ECC_M.blocks[ver];

// GF(256) with the QR polynomial x^8 + x^4 + x^3 + x^2 + 1.
function mul(x, y) {
  let z = 0;
  for (let i = 7; i >= 0; i--) { z = (z << 1) ^ ((z >>> 7) * 0x11d); z ^= ((y >>> i) & 1) * x; }
  return z & 0xff;
}
function divisor(degree) {
  const r = new Array(degree).fill(0); r[degree - 1] = 1;
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < r.length; j++) { r[j] = mul(r[j], root); if (j + 1 < r.length) r[j] ^= r[j + 1]; }
    root = mul(root, 0x02);
  }
  return r;
}
function remainder(data, div) {
  const r = div.map(() => 0);
  for (const b of data) {
    const f = b ^ r.shift(); r.push(0);
    div.forEach((c, i) => { r[i] ^= mul(c, f); });
  }
  return r;
}

function alignmentPositions(ver) {
  if (ver === 1) return [];
  const n = Math.floor(ver / 7) + 2;
  const size = ver * 4 + 17;
  const step = Math.ceil((ver * 4 + 4) / (n * 2 - 2)) * 2;
  const out = [6];
  for (let pos = size - 7; out.length < n; pos -= step) out.splice(1, 0, pos);
  return out;
}

/** The bytes of `text` (UTF-8) as the codewords of the smallest version that holds them, error correction included. */
function codewords(bytes) {
  let ver = 1;
  for (; ver <= MAX_VERSION; ver++) {
    const cap = dataCodewords(ver) * 8;
    if (4 + (ver < 10 ? 8 : 16) + bytes.length * 8 <= cap) break;
  }
  if (ver > MAX_VERSION) throw new Error(`qr: ${bytes.length} bytes do not fit version ${MAX_VERSION}`);
  const bits = [];
  const put = (v, n) => { for (let i = n - 1; i >= 0; i--) bits.push((v >>> i) & 1); };
  put(0b0100, 4); put(bytes.length, ver < 10 ? 8 : 16);
  for (const b of bytes) put(b, 8);
  const cap = dataCodewords(ver) * 8;
  put(0, Math.min(4, cap - bits.length));
  put(0, (8 - (bits.length % 8)) % 8);
  for (let pad = 0xec; bits.length < cap; pad ^= 0xec ^ 0x11) put(pad, 8);
  const data = [];
  for (let i = 0; i < bits.length; i += 8) data.push(bits.slice(i, i + 8).reduce((a, b) => (a << 1) | b, 0));

  const nBlocks = ECC_M.blocks[ver]; const eccLen = ECC_M.perBlock[ver];
  const raw = Math.floor(rawModules(ver) / 8);
  const nShort = nBlocks - (raw % nBlocks); const shortLen = Math.floor(raw / nBlocks);
  const div = divisor(eccLen);
  const blocks = [];
  for (let i = 0, k = 0; i < nBlocks; i++) {
    const d = data.slice(k, k + shortLen - eccLen + (i < nShort ? 0 : 1)); k += d.length;
    const e = remainder(d, div);
    if (i < nShort) d.push(0);                   // a placeholder, skipped when interleaving
    blocks.push(d.concat(e));
  }
  const out = [];
  for (let i = 0; i < blocks[0].length; i++) {
    blocks.forEach((b, j) => { if (i !== shortLen - eccLen || j >= nShort) out.push(b[i]); });
  }
  return { ver, out };
}

const MASKS = [
  (x, y) => (x + y) % 2 === 0, (x, y) => y % 2 === 0, (x) => x % 3 === 0, (x, y) => (x + y) % 3 === 0,
  (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0, (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
  (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0, (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
];

/**
 * The QR code for `text`: { size, modules } where modules[y][x] is true for a dark module, quiet zone not included.
 * `mask` forces one of the eight masks (the self-check reads every one); otherwise the one the penalty rules pick.
 */
export function qr(text, { mask = null } = {}) {
  const bytes = [...new TextEncoder().encode(String(text))];
  const { ver, out } = codewords(bytes);
  const size = ver * 4 + 17;
  const m = Array.from({ length: size }, () => new Array(size).fill(false));
  const fn = Array.from({ length: size }, () => new Array(size).fill(false));
  const set = (x, y, dark) => { m[y][x] = dark; fn[y][x] = true; };

  for (let i = 0; i < size; i++) { set(6, i, i % 2 === 0); set(i, 6, i % 2 === 0); }
  for (const [cx, cy] of [[3, 3], [size - 4, 3], [3, size - 4]]) {
    for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) {
      const x = cx + dx; const y = cy + dy;
      if (x >= 0 && x < size && y >= 0 && y < size) { const d = Math.max(Math.abs(dx), Math.abs(dy)); set(x, y, d !== 2 && d !== 4); }
    }
  }
  const al = alignmentPositions(ver);
  al.forEach((ax, i) => al.forEach((ay, j) => {
    if ((i === 0 && j === 0) || (i === 0 && j === al.length - 1) || (i === al.length - 1 && j === 0)) return;
    for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) set(ax + dx, ay + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
  }));
  const format = (mk) => {
    const d = (ECC_M.formatBits << 3) | mk;
    let r = d; for (let i = 0; i < 10; i++) r = (r << 1) ^ ((r >>> 9) * 0x537);
    const b = ((d << 10) | r) ^ 0x5412; const bit = (i) => ((b >>> i) & 1) === 1;
    for (let i = 0; i <= 5; i++) set(8, i, bit(i));
    set(8, 7, bit(6)); set(8, 8, bit(7)); set(7, 8, bit(8));
    for (let i = 9; i < 15; i++) set(14 - i, 8, bit(i));
    for (let i = 0; i < 8; i++) set(size - 1 - i, 8, bit(i));
    for (let i = 8; i < 15; i++) set(8, size - 15 + i, bit(i));
    set(8, size - 8, true);
  };
  format(0);                                       // reserves the format area before the data is drawn
  if (ver >= 7) {
    let r = ver; for (let i = 0; i < 12; i++) r = (r << 1) ^ ((r >>> 11) * 0x1f25);
    const b = (ver << 12) | r;
    for (let i = 0; i < 18; i++) { const dark = ((b >>> i) & 1) === 1; const a = size - 11 + (i % 3); const c = Math.floor(i / 3); set(a, c, dark); set(c, a, dark); }
  }

  let i = 0;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let v = 0; v < size; v++) for (let j = 0; j < 2; j++) {
      const x = right - j; const up = ((right + 1) & 2) === 0; const y = up ? size - 1 - v : v;
      if (!fn[y][x] && i < out.length * 8) { m[y][x] = ((out[i >>> 3] >>> (7 - (i & 7))) & 1) === 1; i++; }
    }
  }

  const apply = (mk) => { for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (!fn[y][x] && MASKS[mk](x, y)) m[y][x] = !m[y][x]; };
  let chosen = mask;
  if (chosen === null) {
    let best = Infinity;
    for (let mk = 0; mk < 8; mk++) {
      apply(mk); format(mk);
      const p = penalty(m, size);
      if (p < best) { best = p; chosen = mk; }
      apply(mk);
    }
  }
  apply(chosen); format(chosen);
  return { size, version: ver, mask: chosen, modules: m };
}

// The standard's four penalty rules: runs of five or more, 2x2 blocks, finder-like patterns, dark/light balance.
function penalty(m, size) {
  let p = 0;
  const line = (get) => {
    let run = 0; let prev = null; const hist = [];
    for (let i = 0; i < size; i++) {
      const c = get(i);
      if (c === prev) { run++; if (run === 5) p += 3; else if (run > 5) p += 1; } else { run = 1; prev = c; }
      hist.push(c ? 1 : 0);
    }
    const s = hist.join('');
    for (const pat of ['10111010000', '00001011101']) { let k = s.indexOf(pat); while (k !== -1) { p += 40; k = s.indexOf(pat, k + 1); } }
  };
  for (let y = 0; y < size; y++) line((x) => m[y][x]);
  for (let x = 0; x < size; x++) line((y) => m[y][x]);
  let dark = 0;
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    if (m[y][x]) dark++;
    if (x < size - 1 && y < size - 1 && m[y][x] === m[y][x + 1] && m[y][x] === m[y + 1][x] && m[y][x] === m[y + 1][x + 1]) p += 3;
  }
  const total = size * size;
  p += Math.floor(Math.abs(dark * 20 - total * 10) / total) * 10;
  return p;
}

/** The code as an SVG string: one path and a quiet zone of four modules. Its two colours are tokens.css's
 *  --qr-dark and --qr-light, the same in both themes: a camera reads contrast, not the palette. */
export function qrSvg(text, { px = 4 } = {}) {
  const { size, modules } = qr(text);
  const q = 4; const n = size + q * 2;
  let d = '';
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (modules[y][x]) d += `M${x + q} ${y + q}h1v1h-1z`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${n} ${n}" width="${n * px}" height="${n * px}" shape-rendering="crispEdges" role="img" aria-label="QR code of the viewer link"><rect class="qr-light" width="${n}" height="${n}"/><path class="qr-dark" d="${d}"/></svg>`;
}
