// The QR oracle, run by hand (not a gate: it needs Python with OpenCV). Writes every version 1-10 under every mask,
// plus one with the mask the encoder picks, as PGM images, and the list decode.py checks them against:
//   node packaging/studio-test/qr-oracle/gen.mjs "$PWD/kit/studio/web/qr.js" OUT
//   python3 -I packaging/studio-test/qr-oracle/decode.py OUT/list.json
// Measured 2026-10-17 with OpenCV 4.13: QRCodeDetectorAruco read 81 of 81, the plain detector 80 of 81 (one
// detection miss, never a wrong text); a twin whose format bits name another mask than the one applied read 0.
import fs from 'node:fs';
const { qr } = await import(process.argv[2]);
const out = process.argv[3];
const lens = [10, 20, 35, 55, 75, 95, 115, 140, 170, 205];
const list = [];
for (const L of lens) {
  let t = 'http://192.168.1.134:7777/?token='; let k = 0;
  while (t.length < L) t += 'abcdef0123456789-'[k++ % 17];
  t = t.slice(0, L);
  for (let mk = 0; mk < 8; mk++) {
    const { size, version, modules } = qr(t, { mask: mk });
    const q = 4, s = 8, n = (size + 2 * q) * s;
    const px = Buffer.alloc(n * n, 255);
    for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (modules[y][x])
      for (let dy = 0; dy < s; dy++) for (let dx = 0; dx < s; dx++) px[((y + q) * s + dy) * n + (x + q) * s + dx] = 0;
    const f = `${out}/v${version}-m${mk}.pgm`;
    fs.writeFileSync(f, Buffer.concat([Buffer.from(`P5\n${n} ${n}\n255\n`), px]));
    list.push({ f, t, version, mk });
  }
}
const FAKE = '00000000-0000-4000-8000-000000000000';   // a made-up token of the real length
const LINK = `http://192.168.1.134:7777/?token=${FAKE}`;
const auto = qr(LINK);
list.push({ f: (() => { const { size, modules } = auto; const q = 4, s = 8, n = (size + 2 * q) * s; const px = Buffer.alloc(n * n, 255); for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (modules[y][x]) for (let dy = 0; dy < s; dy++) for (let dx = 0; dx < s; dx++) px[((y + q) * s + dy) * n + (x + q) * s + dx] = 0; const f = `${out}/auto.pgm`; fs.writeFileSync(f, Buffer.concat([Buffer.from(`P5\n${n} ${n}\n255\n`), px])); return f; })(), t: LINK, version: auto.version, mk: `auto(${auto.mask})` });
fs.writeFileSync(`${out}/list.json`, JSON.stringify(list));
