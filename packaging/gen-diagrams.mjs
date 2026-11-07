#!/usr/bin/env node
// The README and site diagrams, generated from the repository. Four diagrams × EN/TR × dark/light → assets/.
//
//   node packaging/gen-diagrams.mjs            write assets/*.svg
//   node packaging/gen-diagrams.mjs --check    exit 1 if any assets/*.svg differs from what this would write
//   node packaging/gen-diagrams.mjs --out DIR  write (or with --check, compare) DIR instead of assets/
//   node packaging/gen-diagrams.mjs --selftest the overflow gate's must-fail twin: an over-long label must throw
//
// No dependencies: Node reads the fonts itself (packaging/diagram-fonts/, OFL, subset to the glyphs used here). Text
// is drawn as outlines, so a diagram looks the same on every machine; each SVG carries role="img" and a <title> with
// its words. Every piece of text is measured with the font's own advances and kerning, and one that leaves its box,
// its column or the canvas stops the build — the diagrams it replaced shipped with labels drawn over each other.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FONTS = path.join(ROOT, 'packaging/diagram-fonts');

/* ------------------------------------------------------------------ fonts */

function readFont(file) {
  const b = fs.readFileSync(file);
  const u16 = (o) => b.readUInt16BE(o), i16 = (o) => b.readInt16BE(o), u32 = (o) => b.readUInt32BE(o);
  const tables = {};
  for (let i = 0, n = u16(4); i < n; i++) { const o = 12 + i * 16; tables[b.toString('latin1', o, o + 4)] = u32(o + 8); }
  const head = tables.head, hhea = tables.hhea, maxp = tables.maxp;
  const upem = u16(head + 18), locLong = i16(head + 50) === 1;
  const ascender = i16(hhea + 4), descender = i16(hhea + 6), lineGap = i16(hhea + 8), nHM = u16(hhea + 34);
  const numGlyphs = u16(maxp + 4);
  const adv = []; let last = 0;
  for (let g = 0; g < numGlyphs; g++) { if (g < nHM) last = u16(tables.hmtx + g * 4); adv.push(last); }
  // cmap: format 4 (BMP) from platform 3 / encoding 1, or format 12 from 3/10
  const cmap = new Map();
  const cm = tables.cmap;
  for (let i = 0, n = u16(cm + 2); i < n; i++) {
    const pid = u16(cm + 4 + i * 8), eid = u16(cm + 6 + i * 8), off = cm + u32(cm + 8 + i * 8), fmt = u16(off);
    if (pid !== 3 && pid !== 0) continue;
    if (fmt === 4) {
      const segX2 = u16(off + 6), ends = off + 14, starts = ends + segX2 + 2, deltas = starts + segX2, ranges = deltas + segX2;
      for (let s = 0; s < segX2 / 2; s++) {
        const end = u16(ends + s * 2), start = u16(starts + s * 2), delta = i16(deltas + s * 2), ro = u16(ranges + s * 2);
        for (let c = start; c <= end && c !== 0xffff; c++) {
          let g;
          if (ro === 0) g = (c + delta) & 0xffff;
          else { const gi = u16(ranges + s * 2 + ro + (c - start) * 2); g = gi ? (gi + delta) & 0xffff : 0; }
          if (g && !cmap.has(c)) cmap.set(c, g);
        }
      }
    } else if (fmt === 12) {
      for (let k = 0, n2 = u32(off + 12); k < n2; k++) {
        const o = off + 16 + k * 12, s0 = u32(o), e0 = u32(o + 4), g0 = u32(o + 8);
        for (let c = s0; c <= e0; c++) if (!cmap.has(c)) cmap.set(c, g0 + c - s0);
      }
    }
    void eid;
  }
  const loca = (g) => locLong ? u32(tables.loca + g * 4) : u16(tables.loca + g * 2) * 2;
  const outlines = new Map();
  function glyph(g) {
    if (outlines.has(g)) return outlines.get(g);
    const start = tables.glyf + loca(g), end = tables.glyf + loca(g + 1);
    let contours = [];
    if (end > start) {
      const nc = i16(start);
      if (nc >= 0) contours = simple(start, nc);
      else contours = composite(start);
    }
    outlines.set(g, contours); return contours;
  }
  function simple(o, nc) {
    const endPts = []; for (let i = 0; i < nc; i++) endPts.push(u16(o + 10 + i * 2));
    const nPts = nc ? endPts[nc - 1] + 1 : 0; let p = o + 10 + nc * 2; p += 2 + u16(p);
    const flags = [];
    while (flags.length < nPts) { const f = b[p++]; flags.push(f); if (f & 8) { let r = b[p++]; while (r--) flags.push(f); } }
    const xs = [], ys = []; let v = 0;
    for (const f of flags) { if (f & 2) { const d = b[p++]; v += (f & 16) ? d : -d; } else if (!(f & 16)) { v += i16(p); p += 2; } xs.push(v); }
    v = 0;
    for (const f of flags) { if (f & 4) { const d = b[p++]; v += (f & 32) ? d : -d; } else if (!(f & 32)) { v += i16(p); p += 2; } ys.push(v); }
    const out = []; let s = 0;
    for (const e of endPts) { const c = []; for (let i = s; i <= e; i++) c.push([xs[i], ys[i], (flags[i] & 1) === 1]); out.push(c); s = e + 1; }
    return out;
  }
  function composite(o) {
    let p = o + 10; const out = []; let more = true;
    while (more) {
      const f = u16(p), gi = u16(p + 2); p += 4;
      let dx, dy;
      if (f & 1) { dx = i16(p); dy = i16(p + 2); p += 4; } else { dx = b.readInt8(p); dy = b.readInt8(p + 1); p += 2; }
      let a = 1, bb = 0, c = 0, d = 1; const f2 = (q) => b.readInt16BE(q) / 16384;
      if (f & 8) { a = d = f2(p); p += 2; } else if (f & 0x40) { a = f2(p); d = f2(p + 2); p += 4; } else if (f & 0x80) { a = f2(p); bb = f2(p + 2); c = f2(p + 4); d = f2(p + 6); p += 8; }
      for (const ct of glyph(gi)) out.push(ct.map(([x, y, on]) => [a * x + c * y + dx, bb * x + d * y + dy, on]));
      more = (f & 0x20) !== 0;
    }
    return out;
  }
  // GPOS pair kerning: every PairPos (type 2, or wrapped in Extension type 9) the 'kern' feature points at.
  const kern = new Map();
  if (tables.GPOS) {
    const G = tables.GPOS, fl = G + u16(G + 6), ll = G + u16(G + 8);
    const lookupIdx = new Set();
    for (let i = 0, n = u16(fl); i < n; i++) {
      if (b.toString('latin1', fl + 2 + i * 6, fl + 6 + i * 6) !== 'kern') continue;
      const f = fl + u16(fl + 6 + i * 6); for (let k = 0, m = u16(f + 2); k < m; k++) lookupIdx.add(u16(f + 4 + k * 2));
    }
    const vsize = (vf) => { let n = 0; for (let x = vf; x; x >>= 1) n += x & 1; return n * 2; };
    const coverage = (o) => {
      const fmt = u16(o), list = [];
      if (fmt === 1) for (let i = 0, n = u16(o + 2); i < n; i++) list.push(u16(o + 4 + i * 2));
      else for (let i = 0, n = u16(o + 2); i < n; i++) { const r = o + 4 + i * 6; for (let g = u16(r); g <= u16(r + 2); g++) list.push(g); }
      return list;
    };
    const classDef = (o) => {
      const m = new Map(), fmt = u16(o);
      if (fmt === 1) { const s = u16(o + 2); for (let i = 0, n = u16(o + 4); i < n; i++) m.set(s + i, u16(o + 6 + i * 2)); }
      else for (let i = 0, n = u16(o + 2); i < n; i++) { const r = o + 4 + i * 6; for (let g = u16(r); g <= u16(r + 2); g++) m.set(g, u16(r + 4)); }
      return m;
    };
    const xAdv = (o, vf) => { let off = 0; if (vf & 1) off += 2; if (vf & 2) off += 2; return (vf & 4) ? i16(o + off) : 0; };
    const pairPos = (st) => {
      const fmt = u16(st), cov = coverage(st + u16(st + 2)), vf1 = u16(st + 4), vf2 = u16(st + 6), s1 = vsize(vf1), s2 = vsize(vf2);
      if (fmt === 1) {
        cov.forEach((g1, i) => {
          const ps = st + u16(st + 10 + i * 2);
          for (let k = 0, n = u16(ps); k < n; k++) { const r = ps + 2 + k * (2 + s1 + s2); const key = g1 * 65536 + u16(r); if (!kern.has(key)) kern.set(key, xAdv(r + 2, vf1)); }
        });
      } else if (fmt === 2) {
        const cd1 = classDef(st + u16(st + 8)), cd2 = classDef(st + u16(st + 10)), n2 = u16(st + 14);
        const byClass2 = new Map(); for (const [g, c] of cd2) { if (!byClass2.has(c)) byClass2.set(c, []); byClass2.get(c).push(g); }
        for (const g1 of cov) {
          const c1 = cd1.get(g1) ?? 0;
          for (let c2 = 0; c2 < n2; c2++) {
            const v = xAdv(st + 16 + (c1 * n2 + c2) * (s1 + s2), vf1); if (!v) continue;
            for (const g2 of (byClass2.get(c2) ?? [])) { const key = g1 * 65536 + g2; if (!kern.has(key)) kern.set(key, v); }
          }
        }
      }
    };
    for (const li of [...lookupIdx].sort((x, y) => x - y)) {
      const L = ll + u16(ll + 2 + li * 2), type = u16(L);
      for (let s = 0, n = u16(L + 4); s < n; s++) {
        let st = L + u16(L + 6 + s * 2), t = type;
        if (t === 9) { t = u16(st + 2); st = st + u32(st + 4); }
        if (t === 2) pairPos(st);
      }
    }
  }
  return { upem, ascender, descender, lineGap, adv, cmap, glyph, kern, name: path.basename(file, '.subset.ttf') };
}

const FACE = {
  sans400: readFont(path.join(FONTS, 'Inter-Regular.subset.ttf')),
  sans600: readFont(path.join(FONTS, 'Inter-SemiBold.subset.ttf')),
  sans700: readFont(path.join(FONTS, 'Inter-Bold.subset.ttf')),
  mono400: readFont(path.join(FONTS, 'JetBrainsMono-Regular.subset.ttf')),
  mono600: readFont(path.join(FONTS, 'JetBrainsMono-SemiBold.subset.ttf')),
};

/* ------------------------------------------------------------ text engine */

// One run of text in one style. letterSpacing is in px, added after every character as a browser does.
function shape(text, st) {
  const f = FACE[`${st.mono ? 'mono' : 'sans'}${st.weight ?? 400}`];
  if (!f) throw new Error(`no font for ${JSON.stringify(st)}`);
  const s = st.size / f.upem, glyphs = []; let x = 0, prev = null;
  for (const ch of text) {
    const g = f.cmap.get(ch.codePointAt(0));
    if (g === undefined) throw new Error(`glyph missing for "${ch}" (U+${ch.codePointAt(0).toString(16)}) in ${f.name} — add it to the font subset`);
    if (prev !== null) x += (f.kern.get(prev * 65536 + g) ?? 0) * s;
    glyphs.push({ g, x }); x += f.adv[g] * s + (st.letterSpacing ?? 0); prev = g;
  }
  return { f, s, glyphs, width: x - (st.letterSpacing ?? 0), st };
}
const width = (text, st) => shape(text, st).width;
// CSS "normal" line height for the face and where the baseline sits in a line box of height lh.
const normalLH = (st) => { const f = FACE[`${st.mono ? 'mono' : 'sans'}${st.weight ?? 400}`]; return (f.ascender - f.descender + f.lineGap) / f.upem * st.size; };
function baseline(top, lh, st) {
  const f = FACE[`${st.mono ? 'mono' : 'sans'}${st.weight ?? 400}`];
  const asc = f.ascender / f.upem * st.size, desc = -f.descender / f.upem * st.size;
  return top + (lh - (asc + desc)) / 2 + asc;
}
// Greedy wrap at spaces, the way a browser breaks a paragraph. A word wider than the box is an overflow.
function wrap(text, st, maxW, where) {
  const words = text.split(' '), lines = []; let cur = '';
  for (const w of words) {
    if (width(w, st) > maxW + 0.01) throw new Overflow(`${where}: "${w}" is ${width(w, st).toFixed(1)}px, wider than its ${maxW.toFixed(1)}px box`);
    const t = cur ? `${cur} ${w}` : w;
    if (width(t, st) <= maxW + 0.01) cur = t; else { lines.push(cur); cur = w; }
  }
  if (cur) lines.push(cur);
  return lines;
}
class Overflow extends Error {}
function fits(text, st, maxW, where) {
  const w = width(text, st);
  if (w > maxW + 0.01) throw new Overflow(`${where}: "${text}" is ${w.toFixed(1)}px, wider than its ${maxW.toFixed(1)}px box`);
  return w;
}

/* ------------------------------------------------------------- SVG writer */

const n = (v) => { const r = Math.round(v * 100) / 100; return Object.is(r, -0) ? '0' : String(r); };
class Canvas {
  constructor(w, h, c) { this.w = w; this.h = h; this.c = c; this.body = []; this.defs = new Map(); this.words = []; }
  rect(x, y, w, h, fill) { this.body.push(`<rect x="${n(x)}" y="${n(y)}" width="${n(w)}" height="${n(h)}" fill="${fill}"/>`); }
  dot(x, y, fill, line) { this.body.push(`<circle cx="${n(x + 8)}" cy="${n(y + 8)}" r="7" fill="${fill}" stroke="${line}" stroke-width="2"/>`); }
  // the three marks at the end of a rail; dir 'right' (a horizontal rail) or 'down' (a vertical one)
  chevrons(x, y, dir) {
    const c = this.c, P = dir === 'right'
      ? [['M3 3l7 7-7 7', c.ch1, 2.4, 0.55], ['M13 3l7 7-7 7', c.ch2, 2.4, 0.7], ['M23 3l7 7-7 7', c.ch3, 2.8, 1]]
      : [['M3 3l6 6 6-6', c.ch1, 2.4, 0.55], ['M3 12l6 6 6-6', c.ch2, 2.4, 0.7], ['M3 21l6 6 6-6', c.ch3, 2.8, 1]];
    this.body.push(`<g transform="translate(${n(x)} ${n(y)})" fill="none" stroke-linecap="round" stroke-linejoin="round">` +
      P.map(([d, col, w, o]) => `<path d="${d}" stroke="${col}" stroke-width="${w}"${o < 1 ? ` opacity="${o}"` : ''}/>`).join('') + '</g>');
  }
  glyphPath(f, g) {
    const id = `${f.name.replace(/[^A-Za-z0-9]/g, '')}-${g}`;
    if (!this.defs.has(id)) {
      let d = '';
      for (const ct of f.glyph(g)) {
        if (!ct.length) continue;
        const pts = ct; let startIdx = pts.findIndex((p) => p[2]);
        let start; if (startIdx < 0) { const a = pts[0], b2 = pts[1 % pts.length]; start = [(a[0] + b2[0]) / 2, (a[1] + b2[1]) / 2, true]; startIdx = 0; } else start = pts[startIdx];
        d += `M${start[0]} ${-start[1]}`;
        const L = pts.length; let pending = null;
        for (let k = 1; k <= L; k++) {
          const p = pts[(startIdx + k) % L];
          if (p[2]) { if (pending) { d += `Q${pending[0]} ${-pending[1]} ${p[0]} ${-p[1]}`; pending = null; } else d += `L${p[0]} ${-p[1]}`; }
          else if (pending) { const mx = (pending[0] + p[0]) / 2, my = (pending[1] + p[1]) / 2; d += `Q${pending[0]} ${-pending[1]} ${mx} ${-my}`; pending = p; }
          else pending = p;
        }
        if (pending) d += `Q${pending[0]} ${-pending[1]} ${start[0]} ${-start[1]}`;
        d += 'Z';
      }
      this.defs.set(id, d);
    }
    return id;
  }
  text(str, x, y, st, fill) {
    const sh = shape(str, st);
    const uses = [];
    for (const { g, x: gx } of sh.glyphs) {
      if (!sh.f.glyph(g).length) continue;
      const id = this.glyphPath(sh.f, g);
      uses.push(`<use href="#${id}" x="${n((x + gx) / sh.s)}"/>`);
    }
    if (uses.length) this.body.push(`<g fill="${fill}" transform="translate(0 ${n(y)}) scale(${n4(sh.s)})">${uses.join('')}</g>`);
    return sh.width;
  }
  say(s) { this.words.push(s); }
  // `where` (e.g. stages-en-dark) makes the ids unique to the file: a page that inlines two diagrams, or the same
  // diagram in two themes, must not end up with two elements called "t". The title names the diagram; the
  // description is every word drawn on it, in reading order.
  svg(label, where) {
    const defs = [...this.defs].map(([id, d]) => `<path id="${id}" d="${d}"/>`).join('');
    const words = esc(this.words.join(' · ').replace(/\s+/g, ' ').trim());
    const ti = `${where}-title`, de = `${where}-desc`;
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${this.w} ${this.h}" width="${this.w}" height="${this.h}" role="img" aria-labelledby="${ti}" aria-describedby="${de}">` +
      `<title id="${ti}">${esc(label)}</title><desc id="${de}">${words}</desc><defs>${defs}</defs><rect width="${this.w}" height="${this.h}" fill="${this.c.ground}"/>${this.body.join('')}</svg>\n`;
  }
}
const n4 = (v) => String(Math.round(v * 1e6) / 1e6);
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/* ------------------------------------------------------------ the source */

const COLORS = {
  dark: { ground: '#0B1020', line: '#262c39', ink: '#e6e9f0', dim: '#9aa7cc', accent: '#A78BFA', ch1: '#E5E7FB', ch2: '#B9BEF9', ch3: '#A78BFA' },
  light: { ground: '#f7f8fa', line: '#d9dde5', ink: '#1a1d24', dim: '#5c6472', accent: '#6D28D9', ch1: '#A8AEF6', ch2: '#7C83F5', ch3: '#6D28D9' },
};
const STAGES = ['understand', 'produce', 'audit', 'close', 'handoff'];
// Draft order inside a stage; an agent not listed here (a new one) is appended, so it is never dropped.
const AGENT_ORDER = ['crew-planner', 'crew-backend-expert', 'crew-database-expert', 'crew-frontend-expert', 'crew-devops-expert',
  'crew-security-expert', 'crew-privacy-agent', 'crew-test-expert', 'crew-performance-expert', 'crew-review-agent',
  'crew-commit-agent', 'crew-session-manager'];

function frontmatter(file) {
  const t = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
  const m = t.match(/^---\n([\s\S]*?)\n---\n/); if (!m) throw new Error(`${file}: no frontmatter`);
  return m[1];
}
function readSource() {
  const agents = [];
  for (const f of fs.readdirSync(path.join(ROOT, 'kit/agents')).filter((x) => /^crew-.*\.md$/.test(x)).sort()) {
    const fm = frontmatter(path.join(ROOT, 'kit/agents', f));
    const name = f.slice(0, -3);
    const stage = (fm.match(/\n {2}stage: ([a-z]+)/) || [])[1];
    const skills = ((fm.match(/\n {2}skills: \[([^\]]*)\]/) || [])[1] || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!STAGES.includes(stage)) throw new Error(`kit/agents/${f}: metadata.stage is missing or unknown`);
    agents.push({ name, stage, skills });
  }
  const rank = (a) => { const i = AGENT_ORDER.indexOf(a.name); return i < 0 ? 999 : i; };
  agents.sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name));
  const skills = [];
  for (const d of fs.readdirSync(path.join(ROOT, 'kit/skills')).sort()) {
    const p = path.join(ROOT, 'kit/skills', d, 'SKILL.md'); if (!fs.existsSync(p)) continue;
    const fm = frontmatter(p);
    skills.push({ name: d, command: /\n {2}kind: command/.test(fm), experimental: /\n {2}experimental: "?true"?/.test(fm) });
  }
  const shown = skills.filter((s) => !s.command && !s.experimental).map((s) => s.name);
  for (const a of agents) for (const s of a.skills) if (!skills.some((k) => k.name === s)) throw new Error(`${a.name}: metadata.skills names ${s}, which is not a skill`);
  const owned = new Set(agents.flatMap((a) => a.skills));
  const unowned = shown.filter((s) => !owned.has(s));
  return { agents, shownSkills: shown, unowned };
}

const T = {
  en: {
    stagesTitle: 'How a change moves', stagesTop: (a) => `${a} agents · 5 stages`,
    stages: [['UNDERSTAND', 'Understand', 'An unclear request becomes a plan.'], ['PRODUCE', 'Produce', 'The owning specialist builds it.'],
      ['AUDIT', 'Audit', 'Checked before anything lands.'], ['CLOSE', 'Close', 'A clean review, then your approval.'],
      ['HAND OFF', 'Hand off', 'State saved for the next session.']],
    stagesFoot: ['Nothing is committed until the audit is clean ', 'and you approve it.'],
    flow: [['/crew-plan', 'An unclear request becomes a plan.'], ['specialists', 'The owning agent writes the change.'],
      ['/crew-review', 'Security, privacy, tests, performance.'], ['/crew-ship', 'The commit waits for your approval.'],
      ['/crew-handoff', 'State saved, then /clear.']],
    flowFoot: ['Each step checks the one before it. The commit comes last, ', 'with your approval.'],
    handTitle: 'ADOPTING AN EXISTING PROJECT',
    hand: [['Detect', 'Stack, tools and what is already there.'], ['Propose', 'Seven decisions, shown before any write.'],
      ['Branch', 'A review branch of its own.'], ['Coexist', 'crew- agents beside yours.'], ['Discipline', 'Rules and settings in .claude/'],
      ['Proof', 'Each gate is tried once.'], ['Handover', 'HANDOVER.md and an ADR.']],
    handFoot: ['Every change lands on its own branch, staged and uncommitted. ', 'Your main branch is never touched.'],
    netTitle: 'Who applies which skill', netTop: (a, s) => `${a} agents · ${s} skills · by stage`,
    netStages: [['UNDERSTAND', 'Scope becomes a plan.'], ['PRODUCE', 'The domain owner builds.'], ['AUDIT', 'Checked before it lands.'],
      ['CLOSE', 'Review, then your approval.'], ['HAND OFF', 'State kept for next time.'], ['MAIN THREAD', 'Started by you, any time.']],
    noOwner: 'no single owner',
    label: { stages: 'Diagram, how a change moves', flow: 'Diagram, the command flow', handover: 'Diagram, adopting an existing project', network: 'Diagram, who applies which skill' },
  },
  tr: {
    stagesTitle: 'Bir değişiklik nasıl ilerler', stagesTop: (a) => `${a} ajan · 5 aşama`,
    stages: [['ANLA', 'Anla', 'Belirsiz bir istek plana dönüşür.'], ['ÜRET', 'Üret', 'İşin sahibi uzman yapar.'],
      ['DENETLE', 'Denetle', 'Hiçbir şey denetlenmeden girmez.'], ['KAPAT', 'Kapat', 'Temiz bir inceleme, sonra senin onayın.'],
      ['DEVRET', 'Devret', 'Durum bir sonraki oturum için kaydedilir.']],
    stagesFoot: ['Denetim temiz çıkmadan ', 've sen onaylamadan', ' hiçbir şey commit edilmez.'],
    flow: [['/crew-plan', 'Belirsiz bir istek plana dönüşür.'], ['uzmanlar', 'İşin sahibi ajan değişikliği yazar.'],
      ['/crew-review', 'Güvenlik, gizlilik, testler, performans.'], ['/crew-ship', 'Commit senin onayını bekler.'],
      ['/crew-handoff', 'Durum kaydedilir, sonra /clear.']],
    flowFoot: ['Her adım bir öncekini denetler. Commit en sona, ', 'senin onayınla', ' gelir.'],
    handTitle: 'MEVCUT BİR PROJEYİ DEVRALMAK',
    hand: [['Tespit', 'Yığın, araçlar ve zaten var olanlar.'], ['Öneri', 'Yazmadan önce gösterilen yedi karar.'],
      ['Dal', 'Kendine ait bir inceleme dalı.'], ['Birlikte', 'crew- ajanları seninkilerin yanında.'], ['Disiplin', 'Kurallar ve ayarlar .claude/ içinde.'],
      ['Kanıt', 'Her kapı bir kez denenir.'], ['Devir', 'HANDOVER.md ve bir ADR.']],
    handFoot: ['Her değişiklik kendi dalına, stage edilmiş ve commit edilmemiş olarak iner. ', 'Ana dalına hiç dokunulmaz.'],
    netTitle: "Hangi ajan hangi skill'i uygular", netTop: (a, s) => `${a} ajan · ${s} skill · aşamaya göre`,
    netStages: [['ANLA', 'Kapsam plana dönüşür.'], ['ÜRET', 'Alan sahibi üretir.'], ['DENETLE', 'Girmeden önce denetlenir.'],
      ['KAPAT', 'İnceleme, sonra senin onayın.'], ['DEVRET', 'Durum bir sonraki sefere saklanır.'], ['ANA HAT', 'Senin başlattığın, her an.']],
    noOwner: 'tek bir sahibi yok',
    label: { stages: 'Şema, bir değişiklik nasıl ilerler', flow: 'Şema, komut akışı', handover: 'Şema, mevcut bir projeyi devralmak', network: "Şema, hangi ajan hangi skill'i uygular" },
  },
};

/* --------------------------------------------------------------- layouts */

const W = 1200, PADX = 56, INNER = W - 2 * PADX;
const S = {
  title: { size: 26, weight: 700, letterSpacing: -0.3 }, top: { size: 13 }, label: { size: 12, weight: 600, letterSpacing: 0.96 },
  foot: { size: 14 }, footEm: { size: 14, weight: 600 },
};
const shortName = (a) => a.replace(/^crew-/, '').replace(/-(expert|agent|manager)$/, '');

// A row of mixed-weight runs ending the diagram; checked against the full width.
function footer(cv, y, runs, where) {
  let x = PADX; const c = cv.c; const total = runs.reduce((w, r, i) => w + width(r, i % 2 ? S.footEm : S.foot), 0);
  if (total > INNER + 0.01) throw new Overflow(`${where}: footer "${runs.join('')}" is ${total.toFixed(1)}px, wider than ${INNER}px`);
  runs.forEach((r, i) => { x += cv.text(r, x, y, i % 2 ? S.footEm : S.foot, i % 2 ? c.accent : c.dim); });
  cv.say(runs.join(''));
}
function header(cv, top, title, right, where) {
  const c = cv.c, tw = width(title, S.title), rw = width(right, S.top);
  if (tw + rw + 24 > INNER) throw new Overflow(`${where}: header "${title}" and "${right}" do not fit side by side`);
  const lh = normalLH(S.title), by = baseline(top, lh, S.title);
  cv.text(title, PADX, by, S.title, c.ink); cv.text(right, W - PADX - rw, by, S.top, c.dim);
  cv.say(title); cv.say(right);
  return top + lh;
}
// A horizontal rail of dots: grid columns over the inner width, the rail from the first dot to the chevrons.
function rail(cv, top, cols) {
  const c = cv.c;
  cv.rect(PADX + 7, top + 7, INNER - 7 - 44, 2, c.line);
  cv.chevrons(PADX + INNER - 34, top - 2, 'right');
  return INNER / cols;
}

function stagesSVG(src, loc, theme, t = T[loc]) {
  const c = COLORS[theme], H = 520, cv = new Canvas(W, H, c), where = `stages-${loc}-${theme}`;
  const top = header(cv, 52, t.stagesTitle, t.stagesTop(src.agents.length), where) + 40;
  const colW = rail(cv, top, 5), contentW = colW - 24;
  let bottom = 0;
  t.stages.forEach(([label, name, sub], i) => {
    const x = PADX + i * colW, hot = i === 3;
    cv.dot(x, top, hot ? c.accent : c.ground, hot ? c.accent : c.dim);
    let y = top + 16 + 12 + 10;
    const lLH = normalLH(S.label); fits(label, S.label, contentW, where); cv.text(label, x, baseline(y, lLH, S.label), S.label, hot ? c.accent : c.dim); y += lLH + 12;
    const nS = { size: 22, weight: 700 }; fits(name, nS, contentW, where); cv.text(name, x, baseline(y, 28, nS), nS, c.ink); y += 28 + 12;
    const sS = { size: 14 }; const lines = wrap(sub, sS, contentW, where);
    lines.forEach((l, k) => cv.text(l, x, baseline(y + k * 21, 21, sS), sS, c.dim)); y += Math.max(42, lines.length * 21) + 12 + 6;
    const mS = { size: 13, mono: true };
    const agents = src.agents.filter((a) => a.stage === STAGES[i]).map((a) => shortName(a.name));
    agents.forEach((a, k) => { fits(a, mS, contentW, where); cv.text(a, x, baseline(y + k * 24, 22, mS), mS, c.ink); });
    y += agents.length * 24 - 2;
    bottom = Math.max(bottom, y);
    cv.say(`${label}: ${name}. ${sub} ${agents.join(', ')}`);
  });
  const footTop = H - 52 - normalLH(S.foot);
  if (bottom > footTop - 17) throw new Overflow(`${where}: the stage columns end at ${bottom.toFixed(1)}px, into the footer at ${(footTop - 17).toFixed(1)}px`);
  cv.rect(PADX, footTop - 17, INNER, 1, c.line);
  footer(cv, baseline(footTop, normalLH(S.foot), S.foot), t.stagesFoot, where);
  return cv.svg(t.label.stages, where);
}

function stepsSVG(steps, loc, theme, o) {
  const c = COLORS[theme], cv = new Canvas(W, o.H, c), where = o.where;
  let top = 44;
  if (o.title) { const lh = normalLH(S.label); fits(o.title, S.label, INNER, where); cv.text(o.title, PADX, baseline(top, lh, S.label), S.label, c.dim); cv.say(o.title); top += lh + 26; }
  const colW = rail(cv, top, steps.length), contentW = colW - o.padR;
  let bottom = 0;
  steps.forEach(([head, sub], i) => {
    const x = PADX + i * colW, hot = i === o.hot;
    cv.dot(x, top, hot ? c.accent : c.ground, hot ? c.accent : c.dim);
    let y = top + 16 + o.gap + 8;
    const hS = o.headStyle, hLH = normalLH(hS);
    fits(head, hS, contentW, where); cv.text(head, x, baseline(y, hLH, hS), hS, hot ? c.accent : c.ink); y += hLH + o.gap;
    const lines = wrap(sub, o.subStyle, contentW, where);
    lines.forEach((l, k) => cv.text(l, x, baseline(y + k * o.subLH, o.subLH, o.subStyle), o.subStyle, c.dim)); y += lines.length * o.subLH;
    bottom = Math.max(bottom, y);
    cv.say(`${head}: ${sub}`);
  });
  const footTop = o.H - 36 - normalLH(S.foot);
  if (bottom > footTop - 12) throw new Overflow(`${where}: the steps end at ${bottom.toFixed(1)}px, into the footer at ${(footTop - 12).toFixed(1)}px`);
  footer(cv, baseline(footTop, normalLH(S.foot), S.foot), o.foot, where);
  return cv.svg(o.label, where);
}
const flowSVG = (src, loc, theme, t = T[loc]) => stepsSVG(t.flow, loc, theme, {
  H: 260, where: `flow-${loc}-${theme}`, hot: 3, padR: 24, gap: 10, headStyle: { size: 16, weight: 600, mono: true },
  subStyle: { size: 14 }, subLH: 21, foot: t.flowFoot, label: t.label.flow });
const handoverSVG = (src, loc, theme, t = T[loc]) => stepsSVG(t.hand, loc, theme, {
  H: 300, where: `handover-${loc}-${theme}`, title: t.handTitle, hot: 6, padR: 16, gap: 8, headStyle: { size: 17, weight: 700 },
  subStyle: { size: 13 }, subLH: 19, foot: t.handFoot, label: t.label.handover });

function networkSVG(src, loc, theme, t = T[loc]) {
  // The draft previewed at 1000px; the canvas is cut to the content instead, so no third of it is empty.
  const c = COLORS[theme], cv = new Canvas(W, 0, c), where = `network-${loc}-${theme}`;
  const top = header(cv, 52, t.netTitle, t.netTop(src.agents.length, src.shownSkills.length), where) + 36;
  const listX = PADX + 36, rightX = listX + 170 + 24, skillX = rightX + 230 + 16, skillW = W - PADX - skillX;
  const nameS = { size: 14, weight: 600, mono: true }, skillS = { size: 13, mono: true }, subS = { size: 13 };
  const rows = STAGES.map((s, i) => ({ i, agents: src.agents.filter((a) => a.stage === s).map((a) => [a.name, a.skills]) }));
  rows.push({ i: 5, agents: [[t.noOwner, src.unowned]] });
  let y = top; const railAt = cv.body.length;   // the rail goes under the dots: it is spliced in here once its length is known
  for (const { i, agents } of rows) {
    const [label, sub] = t.netStages[i], hot = i === 3;
    cv.dot(listX - 36, y + 2, hot ? c.accent : c.ground, hot ? c.accent : c.dim);
    fits(label, S.label, 170, where); cv.text(label, listX, baseline(y, 20, S.label), S.label, hot ? c.accent : c.dim);
    const subLines = wrap(sub, subS, 170, where);
    subLines.forEach((l, k) => cv.text(l, listX, baseline(y + 24 + k * 19, 19, subS), subS, c.dim));
    const leftH = 20 + 4 + subLines.length * 19;
    let ry = y;
    agents.forEach(([name, skills], k) => {
      if (k) ry += 10;
      fits(name, nameS, 230, where); cv.text(name, rightX, baseline(ry, 20, nameS), nameS, c.ink);
      const lines = wrap(skills.join(' · '), skillS, skillW, where);
      lines.forEach((l, m) => cv.text(l, skillX, baseline(ry + m * 20, 20, skillS), skillS, c.dim));
      ry += Math.max(1, lines.length) * 20;
      cv.say(`${label}: ${name}: ${skills.join(', ')}`);
    });
    y = Math.max(y + leftH, ry) + 22;
  }
  const listBottom = y - 22;
  // the vertical rail from the first dot to the chevrons under the last row, drawn beneath the dots
  const before = cv.body.length; cv.rect(listX - 36 + 7, top + 8, 2, listBottom - top - 8, c.line);
  cv.body.splice(railAt, 0, cv.body.splice(before, 1)[0]);
  cv.chevrons(listX - 36 - 1, listBottom + 4, 'down');
  cv.h = Math.ceil(listBottom + 4 + 30 + 52);
  if (cv.h > 1400) throw new Overflow(`${where}: the rows need ${cv.h}px, past the 1400px the README can show`);
  return cv.svg(t.label.network, where);
}

/* ----------------------------------------------------------------- main */

const DIAGRAMS = { stages: stagesSVG, flow: flowSVG, handover: handoverSVG, network: networkSVG };
export function renderAll(src = readSource()) {
  const out = {};
  for (const [name, fn] of Object.entries(DIAGRAMS)) for (const loc of ['en', 'tr']) for (const theme of ['dark', 'light'])
    out[`${name}-${loc}-${theme}.svg`] = fn(src, loc, theme);
  return out;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2), oi = args.indexOf('--out');
  const dir = oi >= 0 ? path.resolve(args[oi + 1]) : path.join(ROOT, 'assets');
  if (args.includes('--selftest')) {
    // Must-fail twin of the overflow gate: the same layout, one label made too long, has to stop the build.
    const long = JSON.parse(JSON.stringify(T.en, (k, v) => (typeof v === 'function' ? undefined : v)));
    long.stagesTop = T.en.stagesTop; long.netTop = T.en.netTop;
    long.stages[1][0] = 'PRODUCE THE CHANGE IN EVERY STACK AT ONCE';
    try { stagesSVG(readSource(), 'en', 'dark', long); console.error('gen-diagrams selftest: an over-long label did NOT stop the build'); process.exit(1); }
    catch (e) { if (!(e instanceof Overflow)) throw e; console.log(`gen-diagrams selftest: an over-long label stops the build — ${e.message}`); }
    // Every diagram names itself and describes itself with ids no other diagram uses; the twin is the old bare
    // `id="t"` form, which the same check must refuse.
    const labelled = (set) => {
      const seen = new Map(); const bad = [];
      for (const [f, svg] of Object.entries(set)) {
        const stem = f.replace(/\.svg$/, '');
        if (!svg.includes(`aria-labelledby="${stem}-title"`) || !svg.includes(`<title id="${stem}-title">`) || !new RegExp(`<desc id="${stem}-desc">[^<]{20,}</desc>`).test(svg)) bad.push(`${f}: no title and description under its own ids`);
        for (const [, id] of svg.matchAll(/<(?:title|desc) id="([^"]+)"/g)) { if (seen.has(id)) bad.push(`${f}: id ${id} also in ${seen.get(id)}`); seen.set(id, f); }
      }
      return bad;
    };
    const all = renderAll(); const bad = labelled(all);
    const bare = Object.fromEntries(Object.entries(all).map(([f, svg]) => [f, svg.replace(/aria-labelledby="[^"]+"/, 'aria-labelledby="t"').replace(/<title id="[^"]+">/, '<title id="t">')]));
    if (!labelled(bare).length) bad.push('twin: diagrams with the bare id="t" passed the check, so it proves nothing');
    if (bad.length) { console.error(`gen-diagrams selftest: ${bad.join('; ')}`); process.exit(1); }
    console.log(`gen-diagrams selftest: ${Object.keys(all).length} diagrams each carry a title and a description under their own ids; the bare-id twin is refused`);
    process.exit(0);
  }
  let files;
  try { files = renderAll(); } catch (e) { if (e instanceof Overflow) { console.error(`gen-diagrams: overflow — ${e.message}`); process.exit(1); } throw e; }
  if (args.includes('--check')) {
    const stale = Object.entries(files).filter(([f, s]) => !fs.existsSync(path.join(dir, f)) || fs.readFileSync(path.join(dir, f), 'utf8') !== s).map(([f]) => f);
    if (stale.length) { console.error(`gen-diagrams: ${stale.length} diagram(s) differ from the source — run node packaging/gen-diagrams.mjs: ${stale.join(' ')}`); process.exit(1); }
    console.log(`gen-diagrams: all ${Object.keys(files).length} diagrams match the source`);
  } else {
    fs.mkdirSync(dir, { recursive: true });
    for (const [f, s] of Object.entries(files)) fs.writeFileSync(path.join(dir, f), s);
    console.log(`gen-diagrams: wrote ${Object.keys(files).length} diagrams to ${path.relative(ROOT, dir) || '.'}`);
  }
}
