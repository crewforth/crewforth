// contracts.mjs — the rules a project writes down for its own code, and what holds them to the tree.
//
// .crewforth/contracts.md is written by the team (or by /crew-map when the user names a rule), never by the scanner,
// so a rescan cannot drop it. One section per contract:
//
//   ## totals-round-once
//   Order totals are rounded once, at the end, so a split order adds up to the same cents as the whole.
//   - Core/Orders.cs:Total
//   - Core/Invoices.cs:Sum
//
// The heading is the key (kebab case, unique in the file); the first paragraph is the rule, one or two sentences;
// each `- path:symbol` line is where the rule lives: a file of the project and a name that appears in it as a word.
// A symbol, not a line number: a rule outlives the edits that move it. Text before the first heading is free.
//
// Who reads it: map-stale.sh tells an agent, the moment it edits a cited file, which rules live there; at Stop it
// tells the user which keys the session's edits touched; crew-review-agent gives a verdict per touched key. The
// validator below (scan.mjs --contracts, and --validate when the file exists) keeps every cite pointing at code.

export const CONTRACTS_FILE = '.crewforth/contracts.md';
const KEY = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const SYMBOL = /^[A-Za-z_$/][\w$./-]*$/;
const MAX_RULE = 300;
const MAX_KEY = 60;

/** Parse the file: [{ key, line, rule, cites: [{ path, symbol, line }] }] and the problems a parse alone can see. */
export function parse(text) {
  const out = []; const problems = [];
  let cur = null; let para = null;
  String(text).split('\n').forEach((raw, i) => {
    const l = raw.replace(/\r$/, '');
    const h = /^##\s+(.*?)\s*$/.exec(l);
    if (h) { cur = { key: h[1], line: i + 1, rule: '', cites: [] }; out.push(cur); para = 'want'; return; }
    if (!cur) return;
    const c = /^\s*[-*]\s+(\S+)\s*$/.exec(l);
    if (c) {
      const at = c[1].lastIndexOf(':');
      cur.cites.push({ path: at > 0 ? c[1].slice(0, at) : c[1], symbol: at > 0 ? c[1].slice(at + 1) : '', line: i + 1 });
      if (para === 'in') para = 'done';
      return;
    }
    if (!l.trim()) { if (para === 'in') para = 'done'; return; }
    if (para === 'want') { cur.rule = l.trim(); para = 'in'; }
    else if (para === 'in') cur.rule += ` ${l.trim()}`;
    else problems.push({ at: `${cur.key}`, message: `line ${i + 1} is neither the rule nor a "- path:symbol" cite` });
  });
  return { contracts: out, problems };
}

const sentences = (t) => (String(t).trim().match(/[.!?](\s|$)/g) ?? []).length;
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * Hold the file to the tree. `files` is the scanner's listing (a Set), `read(rel)` its reader ({ text } or null).
 * Returns { contracts, problems: [{ at, message }] }; no problem means every rule is stated and every cite lands.
 */
export function validate(text, files, read) {
  const { contracts, problems } = parse(text);
  const seen = new Set();
  for (const c of contracts) {
    const at = c.key || `line ${c.line}`;
    if (!KEY.test(c.key) || c.key.length > MAX_KEY) problems.push({ at, message: `the key is not kebab case (a-z, 0-9 and single dashes, ${MAX_KEY} characters at most)` });
    if (seen.has(c.key)) problems.push({ at, message: 'the key is used twice: a review gives one verdict per key' });
    seen.add(c.key);
    if (!c.rule) problems.push({ at, message: 'states no rule: the first paragraph under the heading is the rule' });
    else if (c.rule.length > MAX_RULE || sentences(c.rule) > 2) problems.push({ at, message: `the rule runs past two sentences or ${MAX_RULE} characters` });
    if (!c.cites.length) problems.push({ at, message: 'cites nothing: a rule says where it lives with "- path:symbol"' });
    for (const x of c.cites) {
      const where = `${x.path}:${x.symbol}`;
      if (!x.symbol || !SYMBOL.test(x.symbol) || /^\d+$/.test(x.symbol)) { problems.push({ at, message: `${where} names no symbol (a function, type, key or route that appears in the file, not a line number)` }); continue; }
      if (x.path.startsWith('/') || /^[A-Za-z]:/.test(x.path) || x.path.split('/').includes('..') || !files.has(x.path)) { problems.push({ at, message: `${where}: ${x.path} is not a file of this project` }); continue; }
      const src = read(x.path);
      if (!src) { problems.push({ at, message: `${where}: ${x.path} could not be read` }); continue; }
      if (!new RegExp(`(^|[^\\w$])${escape(x.symbol)}($|[^\\w$])`, 'm').test(src.text)) problems.push({ at, message: `${where}: ${x.symbol} does not appear in ${x.path} (renamed or moved?)` });
    }
  }
  return { contracts, problems };
}
