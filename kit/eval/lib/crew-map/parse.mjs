// parse.mjs — the four readers the scanner needs, each one a SUBSET written for the files it reads, and each one
// keeping the line every key came from so a fact can be cited. Node's standard library only.
//
// The rule that makes a subset safe: a construct the reader does not understand THROWS (Unsupported). It is never
// read partly. The scanner turns the throw into a notMeasured entry with the reason, so an unread file is visible
// instead of looking like a file that said nothing.

export class Unsupported extends Error {}

// ---- JSON with comments and trailing commas (package.json, tsconfig.json, appsettings*.json) ---------------
// Returns { value, lines } where `lines` maps a key path (keys joined by '\u0000') to the 1-based line of the key.
export function parseJsonc(text) {
  let i = 0; let line = 1;
  const lines = new Map();
  const ws = () => {
    for (;;) {
      const c = text[i];
      if (c === '\n') { line++; i++; }
      else if (c === ' ' || c === '\t' || c === '\r' || c === '﻿') i++;
      else if (c === '/' && text[i + 1] === '/') { while (i < text.length && text[i] !== '\n') i++; }
      else if (c === '/' && text[i + 1] === '*') {
        const end = text.indexOf('*/', i + 2);
        if (end === -1) throw new Unsupported(`unterminated comment at line ${line}`);
        for (let k = i; k < end; k++) if (text[k] === '\n') line++;
        i = end + 2;
      } else return;
    }
  };
  const str = () => {
    let out = ''; i++;
    for (;;) {
      const c = text[i];
      if (c === undefined || c === '\n') throw new Unsupported(`unterminated string at line ${line}`);
      if (c === '"') { i++; return out; }
      if (c === '\\') {
        const e = text[i + 1];
        if (e === 'u') { out += String.fromCharCode(parseInt(text.slice(i + 2, i + 6), 16)); i += 6; continue; }
        out += { n: '\n', t: '\t', r: '\r', b: '\b', f: '\f' }[e] ?? e; i += 2; continue;
      }
      out += c; i++;
    }
  };
  const val = (at) => {
    ws();
    const c = text[i];
    if (c === '{') {
      i++; const o = {};
      for (;;) {
        ws();
        if (text[i] === '}') { i++; return o; }
        if (text[i] !== '"') throw new Unsupported(`expected a key at line ${line}`);
        const kl = line; const k = str();
        lines.set([...at, k].join('\u0000'), kl);
        ws(); if (text[i] !== ':') throw new Unsupported(`expected ':' at line ${line}`); i++;
        o[k] = val([...at, k]);
        ws(); if (text[i] === ',') { i++; continue; }
        if (text[i] === '}') { i++; return o; }
        throw new Unsupported(`expected ',' or '}' at line ${line}`);
      }
    }
    if (c === '[') {
      i++; const a = [];
      for (;;) {
        ws();
        if (text[i] === ']') { i++; return a; }
        lines.set([...at, String(a.length)].join('\u0000'), line);
        a.push(val([...at, String(a.length)]));
        ws(); if (text[i] === ',') { i++; continue; }
        if (text[i] === ']') { i++; return a; }
        throw new Unsupported(`expected ',' or ']' at line ${line}`);
      }
    }
    if (c === '"') return str();
    const m = /^(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)/.exec(text.slice(i, i + 64));
    if (!m) throw new Unsupported(`unexpected character at line ${line}`);
    i += m[0].length;
    return JSON.parse(m[0]);
  };
  const value = val([]);
  ws();
  if (i < text.length) throw new Unsupported(`trailing content at line ${line}`);
  return { value, lines };
}

// ---- TOML subset (pyproject.toml) --------------------------------------------------------------------------
// Tables, dotted table names, key = value with strings, numbers, booleans, arrays (one or many lines) and inline
// tables of those. Returns a list of { table, key, value, line } in file order. Dates, multi-line strings and
// array-of-tables are refused.
export function parseToml(text) {
  const out = []; let table = '';
  const src = text.split('\n');
  for (let n = 0; n < src.length; n++) {
    let s = src[n].replace(/\r$/, '');
    const t = s.trim();
    if (t === '' || t.startsWith('#')) continue;
    if (t.startsWith('[[')) throw new Unsupported(`array of tables at line ${n + 1}`);
    const th = /^\[\s*([A-Za-z0-9_.\-"' ]+?)\s*\]\s*(#.*)?$/.exec(t);
    if (th) { table = th[1].replace(/["' ]/g, ''); continue; }
    const kv = /^([A-Za-z0-9_.\-"]+)\s*=\s*(.*)$/.exec(t);
    if (!kv) throw new Unsupported(`unreadable line ${n + 1}`);
    let rest = kv[2]; const line = n + 1;
    // An array may continue over several lines: gather until the brackets balance outside strings.
    while (depth(rest) > 0) {
      n++;
      if (n >= src.length) throw new Unsupported(`unterminated array from line ${line}`);
      rest += '\n' + src[n].replace(/\r$/, '');
    }
    const p = { s: rest, i: 0 };
    const value = tomlValue(p, line);
    skipTomlWs(p);
    if (p.i < p.s.length && p.s[p.i] !== '#') throw new Unsupported(`trailing content at line ${line}`);
    out.push({ table, key: kv[1].replace(/"/g, ''), value, line });
  }
  return out;
}
function depth(s) {
  let d = 0; let q = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === '\\' && q === '"') i++; else if (c === q) q = null; continue; }
    if (c === '"' || c === "'") { if (s.startsWith(c.repeat(3), i)) throw new Unsupported('multi-line string'); q = c; }
    else if (c === '#') { const nl = s.indexOf('\n', i); if (nl === -1) break; i = nl; }
    else if (c === '[' || c === '{') d++;
    else if (c === ']' || c === '}') d--;
  }
  return d;
}
function skipTomlWs(p) {
  for (;;) {
    const c = p.s[p.i];
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === ',') p.i++;
    else if (c === '#' && p.s.slice(p.i).includes('\n')) p.i = p.s.indexOf('\n', p.i) + 1;
    else return;
  }
}
function tomlValue(p, line) {
  while (p.s[p.i] === ' ' || p.s[p.i] === '\t') p.i++;
  const c = p.s[p.i];
  if (c === '"' || c === "'") {
    let out = ''; p.i++;
    for (;;) {
      const d = p.s[p.i];
      if (d === undefined || d === '\n') throw new Unsupported(`unterminated string at line ${line}`);
      if (d === c) { p.i++; return out; }
      if (d === '\\' && c === '"') { out += p.s[p.i + 1]; p.i += 2; continue; }
      out += d; p.i++;
    }
  }
  if (c === '[') {
    p.i++; const a = [];
    for (;;) { skipTomlWs(p); if (p.s[p.i] === ']') { p.i++; return a; } a.push(tomlValue(p, line)); }
  }
  if (c === '{') {
    p.i++; const o = {};
    for (;;) {
      skipTomlWs(p);
      if (p.s[p.i] === '}') { p.i++; return o; }
      const m = /^([A-Za-z0-9_\-"]+)\s*=\s*/.exec(p.s.slice(p.i));
      if (!m) throw new Unsupported(`unreadable inline table at line ${line}`);
      p.i += m[0].length; o[m[1].replace(/"/g, '')] = tomlValue(p, line);
    }
  }
  const m = /^(true|false|[+-]?\d[\d_]*(?:\.\d+)?)(?=[\s,\]}#]|$)/.exec(p.s.slice(p.i));
  if (!m) throw new Unsupported(`unsupported value at line ${line}`);
  p.i += m[0].length;
  return m[1] === 'true' ? true : m[1] === 'false' ? false : Number(m[1].replace(/_/g, ''));
}

// ---- YAML subset (docker-compose*.yml, application*.yml) ---------------------------------------------------
// Block maps and sequences by indentation, plain and quoted scalars, one-line flow sequences, comments. A block
// scalar (| or >) is kept as an opaque value. Anchors, aliases, merge keys, tags and multi-document files are
// refused: reading around them would invent structure.
// A node is { t: 'map', e: [{ k, line, v }] } | { t: 'seq', e: [{ line, v }] } | { t: 'str', v, line }.
export function parseYaml(text) {
  const rows = [];
  const src = text.split('\n');
  for (let n = 0; n < src.length; n++) {
    const raw = src[n].replace(/\r$/, '');
    if (/^\s*(#.*)?$/.test(raw)) continue;
    if (/^(---|\.\.\.)\s*$/.test(raw)) { if (rows.length) throw new Unsupported(`a second document at line ${n + 1}`); continue; }
    if (/\t/.test(raw.match(/^\s*/)[0])) throw new Unsupported(`tab indentation at line ${n + 1}`);
    rows.push({ ind: raw.match(/^ */)[0].length, s: stripComment(raw.trim()), line: n + 1 });
  }
  const p = { rows, i: 0 };
  if (!rows.length) return { t: 'map', e: [] };
  return yBlock(p, rows[0].ind);
}
function stripComment(s) {
  let q = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === q) q = null; continue; }
    if (c === '"' || c === "'") { if (i === 0 || /[\s:[,{-]/.test(s[i - 1])) q = c; }
    else if (c === '#' && (i === 0 || s[i - 1] === ' ')) return s.slice(0, i).trimEnd();
  }
  return s;
}
function yScalar(s, line) {
  if (/^[&*!]/.test(s)) throw new Unsupported(`anchor, alias or tag at line ${line}`);
  if (s.startsWith('[')) {
    if (!s.endsWith(']')) throw new Unsupported(`multi-line flow sequence at line ${line}`);
    const inner = s.slice(1, -1).trim();
    return { t: 'seq', e: inner === '' ? [] : inner.split(',').map((x) => ({ line, v: yScalar(x.trim(), line) })) };
  }
  if (s.startsWith('{')) throw new Unsupported(`flow mapping at line ${line}`);
  if ((s.startsWith('"') && s.endsWith('"') && s.length > 1) || (s.startsWith("'") && s.endsWith("'") && s.length > 1)) return { t: 'str', v: s.slice(1, -1), line };
  return { t: 'str', v: s, line };
}
function keyOf(s) {
  const m = /^("[^"]*"|'[^']*'|[^\s:"'][^:]*?)\s*:(?:\s+(.*)|$)/.exec(s);
  if (!m) return null;
  return { k: m[1].replace(/^["']|["']$/g, ''), rest: m[2] === undefined ? '' : m[2] };
}
function yBlock(p, ind) {
  const first = p.rows[p.i];
  if (first.s.startsWith('- ') || first.s === '-') {
    const node = { t: 'seq', e: [] };
    while (p.i < p.rows.length && p.rows[p.i].ind === ind && (p.rows[p.i].s.startsWith('- ') || p.rows[p.i].s === '-')) {
      const r = p.rows[p.i]; const rest = r.s === '-' ? '' : r.s.slice(2).trim();
      if (rest === '') { p.i++; node.e.push({ line: r.line, v: p.i < p.rows.length && p.rows[p.i].ind > ind ? yBlock(p, p.rows[p.i].ind) : { t: 'str', v: '', line: r.line } }); continue; }
      const kv = keyOf(rest);
      if (kv) {
        // "- key: value" opens a map whose first entry sits on the dash line; the rest are indented to the key.
        p.rows[p.i] = { ind: ind + 2, s: rest, line: r.line };
        node.e.push({ line: r.line, v: yBlock(p, ind + 2) });
        continue;
      }
      node.e.push({ line: r.line, v: yScalar(rest, r.line) }); p.i++;
    }
    return node;
  }
  const node = { t: 'map', e: [] };
  while (p.i < p.rows.length && p.rows[p.i].ind === ind) {
    const r = p.rows[p.i];
    if (r.s.startsWith('- ')) break;
    const kv = keyOf(r.s);
    if (!kv) throw new Unsupported(`unreadable line ${r.line}`);
    if (kv.k === '<<') throw new Unsupported(`merge key at line ${r.line}`);
    p.i++;
    let v;
    if (kv.rest === '') {
      v = p.i < p.rows.length && (p.rows[p.i].ind > ind || (p.rows[p.i].ind === ind && p.rows[p.i].s.startsWith('- ')))
        ? yBlock(p, p.rows[p.i].ind) : { t: 'str', v: '', line: r.line };
    } else if (/^[|>][+-]?\d*$/.test(kv.rest)) {
      while (p.i < p.rows.length && p.rows[p.i].ind > ind) p.i++;
      v = { t: 'str', v: '', line: r.line, opaque: true };
    } else v = yScalar(kv.rest, r.line);
    node.e.push({ k: kv.k, line: r.line, v });
  }
  if (p.i < p.rows.length && p.rows[p.i].ind > ind) throw new Unsupported(`unexpected indentation at line ${p.rows[p.i].line}`);
  return node;
}
export const yGet = (node, k) => (node && node.t === 'map' ? node.e.find((x) => x.k === k) : undefined);

// ---- XML, enough for *.csproj, *.props and pom.xml ----------------------------------------------------------
// Elements with attributes, text and comments. Returns the root { name, attrs, line, children, text }.
export function parseXml(text) {
  let i = 0; let line = 1;
  const root = { name: '#doc', attrs: {}, line: 1, children: [], text: '' };
  const stack = [root];
  const adv = (to) => { for (let k = i; k < to; k++) if (text[k] === '\n') line++; i = to; };
  while (i < text.length) {
    const lt = text.indexOf('<', i);
    if (lt === -1) { stack[stack.length - 1].text += text.slice(i); adv(text.length); break; }
    const top0 = stack[stack.length - 1]; const chunk = text.slice(i, lt);
    if (top0.textLine === undefined && /\S/.test(chunk)) top0.textLine = line + (chunk.slice(0, chunk.search(/\S/)).match(/\n/g) || []).length;
    top0.text += chunk; adv(lt);
    if (text.startsWith('<!--', i)) { const e = text.indexOf('-->', i); if (e === -1) throw new Unsupported(`unterminated comment at line ${line}`); adv(e + 3); continue; }
    if (text.startsWith('<?', i) || text.startsWith('<!', i)) { const e = text.indexOf('>', i); if (e === -1) throw new Unsupported(`unterminated declaration at line ${line}`); adv(e + 1); continue; }
    const gt = text.indexOf('>', i);
    if (gt === -1) throw new Unsupported(`unterminated tag at line ${line}`);
    const tag = text.slice(i + 1, gt); const at = line;
    adv(gt + 1);
    if (tag.startsWith('/')) {
      const name = tag.slice(1).trim();
      const top = stack.pop();
      if (!top || top.name !== name) throw new Unsupported(`</${name}> does not close <${top && top.name}> at line ${at}`);
      continue;
    }
    const self = tag.endsWith('/');
    const m = /^([\w:.-]+)([\s\S]*?)\/?$/.exec(tag);
    if (!m) throw new Unsupported(`unreadable tag at line ${at}`);
    // Each attribute keeps its own line: a tag may span several, and a citation must land where the value is.
    const attrs = {}; const attrLines = {};
    const off = 1 + m[1].length;
    for (const a of m[2].matchAll(/([\w:.-]+)\s*=\s*("([^"]*)"|'([^']*)')/g)) {
      attrs[a[1]] = a[3] ?? a[4];
      attrLines[a[1]] = at + (tag.slice(0, off + a.index).match(/\n/g) || []).length;
    }
    const el = { name: m[1], attrs, attrLines, line: at, children: [], text: '' };
    stack[stack.length - 1].children.push(el);
    if (!self) stack.push(el);
  }
  if (stack.length !== 1) throw new Unsupported(`<${stack[stack.length - 1].name}> is never closed`);
  return root;
}
export const xKids = (el, name) => (el ? el.children.filter((c) => c.name === name) : []);
export const xKid = (el, name) => xKids(el, name)[0];
export const xText = (el) => (el ? el.text.trim() : '');
// The line an element's text is on (a value may sit on the line after its tag).
export const xLine = (el) => (el ? (el.textLine ?? el.line) : 1);
export function xFind(el, name, out = []) {
  for (const c of el.children) { if (c.name === name) out.push(c); xFind(c, name, out); }
  return out;
}
