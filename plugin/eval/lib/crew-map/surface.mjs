// surface.mjs — what a project touches outside its own modules: external resources, configuration, endpoints
// and containers. Patterns, not compilers: a route built at run time, a config key assembled from parts or a URL
// read from somewhere else is not seen, and the scanner says which families it does not read (notMeasured).

import path from 'node:path';
import { parseJsonc, parseYaml, yGet, Unsupported } from './parse.mjs';
import { ev, isTestPath, isLocalHost, risky } from './project.mjs';

const P = path.posix;
const dirOf = (f) => { const d = P.dirname(f); return d === '.' ? '.' : d; };
const under = (file, dir) => dir === '.' || file === dir || file.startsWith(dir + '/');
const isComment = (l) => /^\s*(\/\/|#|\*|\/\*|<!--)/.test(l);

// The deepest module holding a path, any stack.
export function ownerOf(modules, file) {
  return modules.filter((m) => under(file, m.dir)).sort((a, b) => b.dir.length - a.dir.length || (a.id < b.id ? -1 : 1))[0] || null;
}

// ---- external resources ---------------------------------------------------------------------------------------
export function externals(pj, st, rules, hostOf, out) {
  const ext = new Map();
  const node = (kind, label) => {
    const id = `ext:${kind}:${label}`;
    if (!ext.has(id)) ext.set(id, { id, kind: 'external', resource: kind, label, hosts: new Set(), evidence: [] });
    return ext.get(id);
  };
  const ecoRules = { npm: rules.npm, nuget: rules.nuget, pypi: rules.pypi, go: rules.go, maven: rules.maven };
  const pyNorm = (s) => s.toLowerCase().replace(/[_.]/g, '-');
  for (const m of st.modules) {
    for (const d of m.deps) {
      const table = ecoRules[d.eco]; if (!table) continue;
      let hit = null;
      if (d.eco === 'pypi') { const k = Object.keys(table).find((x) => pyNorm(x) === pyNorm(d.name)); hit = k && table[k]; }
      else if (d.eco === 'go') { const k = Object.keys(table).find((x) => d.name === x || d.name.startsWith(x + '/')); hit = k && table[k]; }
      else hit = table[d.name];
      if (!hit) continue;
      const n = node(hit[0], hit[1]);
      n.evidence.push(d.ev);
      out.edges.push({ from: m.id, to: n.id, kind: `uses-${hit[0]}`, confidence: 'evidence', via: 'package', evidence: [d.ev] });
    }
  }
  return { ext, node };
}

// A value's scheme or shape, read only to name the kind. Returns [kind, label, host] or null.
function classify(value, key, rules, hostOf) {
  const v = String(value).trim().replace(/^["']|["']$/g, '').replace(/^jdbc:/i, '');
  const s = /^([a-z][a-z0-9+.-]*):\/\/([^\s"']*)/i.exec(v);
  if (s) {
    const scheme = s[1].toLowerCase();
    if (rules.schemes[scheme]) return [...rules.schemes[scheme], hostOf(v)];
    if (scheme === 'http' || scheme === 'https') return ['http-api', null, hostOf(v)];
    return null;
  }
  const kv = /(?:^|;)\s*(Host|Server|Data Source|Address|Addr)\s*=\s*([^;]+)/i.exec(v);
  if (kv && /;/.test(v)) {
    const label = /^host$/i.test(kv[1]) ? 'postgres' : /\.db$|\.sqlite3?$/i.test(kv[2]) ? 'sqlite' : 'sql';
    return ['db', label, hostOf(kv[2].replace(/^tcp:/i, '').split(',')[0])];
  }
  if (/connection|conn_?str|database_url|db_url/i.test(key) && v) return ['db', 'sql', null];
  return null;
}

// ---- configuration: where keys are defined, and where code reads them ------------------------------------------
// defs  { key, file, line, source: env|appsettings|properties|yaml|compose|dockerfile, ev }
// reads { key, prefix: bool, hasDefault: bool, file, line, ev }
export function configuration(pj, st, rules, hostOf, ex, out) {
  const defs = []; const reads = [];
  const def = (key, file, line, source, value) => {
    // A "key" that is itself a secret (a token pasted on a line of its own) would travel in titles and data, which
    // no quote net covers: the line is not read.
    if (risky(key, out.patterns) >= 0) { out.notMeasured.push({ what: `a line of ${file}`, reason: 'its key looks like a secret, so the line was not read' }); return; }
    const e = ev(file, line, key);
    defs.push({ key, file, line, source, ev: e });
    if (value === undefined || value === null || value === '') return;
    const c = classify(value, key, rules, hostOf);
    if (!c) return;
    if (c[0] === 'http-api' && isLocalHost(c[2])) return;
    const label = c[1] || (c[2] && c[2] !== '[masked]' ? c[2] : 'unknown');
    const n = ex.node(c[0], label);
    if (c[2]) n.hosts.add(c[2]);
    n.evidence.push(e);
    const m = ownerOf(st.modules, file);
    if (m) out.edges.push({ from: m.id, to: n.id, kind: `configured-${c[0]}`, confidence: 'evidence', via: 'config', evidence: [e] });
    if (c[0] === 'http-api') out.configUrls.push({ key, host: c[2], ext: n.id, ev: e });
  };
  for (const f of pj.files) {
    if (isTestPath(f)) continue; // a sample project's configuration is not this project's
    const b = P.basename(f).toLowerCase();
    if (b.startsWith('.env')) {
      const src = pj.read(f); if (!src) continue;
      src.lines.forEach((l, i) => { const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*)$/.exec(l); if (m) def(m[1], f, i + 1, 'env', m[2]); });
    } else if (/^appsettings.*\.json$/.test(b)) {
      const src = pj.read(f); if (!src) continue;
      let doc; try { doc = parseJsonc(src.text); } catch (e) { out.notMeasured.push({ what: f, reason: `could not be read: ${e.message}` }); continue; }
      const walk = (v, at) => {
        if (v && typeof v === 'object' && !Array.isArray(v)) { for (const k of Object.keys(v)) walk(v[k], [...at, k]); return; }
        if (Array.isArray(v)) return; // an array is one value of its key; the key is defined by the parent walk below
        const line = doc.lines.get(at.join('\u0000')) || 1;
        def(at.join(':'), f, line, 'appsettings', typeof v === 'string' ? v : '');
        // The anchor must be on the cited line: the leaf name is, the full path is not.
        defs[defs.length - 1].ev.text = at[at.length - 1];
      };
      walk(doc.value, []);
    } else if (/^application.*\.properties$/.test(b)) {
      const src = pj.read(f); if (!src) continue;
      src.lines.forEach((l, i) => { if (isComment(l) || /^\s*!/.test(l)) return; const m = /^\s*([\w.\-[\]]+)\s*[=:]\s*(.*)$/.exec(l); if (m) def(m[1], f, i + 1, 'properties', m[2]); });
    } else if (/^application.*\.ya?ml$/.test(b)) {
      const src = pj.read(f); if (!src) continue;
      let y; try { y = parseYaml(src.text); } catch (e) { out.notMeasured.push({ what: f, reason: `YAML outside the subset this scanner reads: ${e.message}` }); continue; }
      const walk = (node, at) => {
        if (node.t === 'map') { for (const e of node.e) { if (e.v.t === 'str') { def([...at, e.k].join('.'), f, e.line, 'yaml', e.v.v); defs[defs.length - 1].ev.text = e.k; } else walk(e.v, [...at, e.k]); } }
      };
      walk(y, []);
    } else if (b === 'dockerfile' || b.endsWith('.dockerfile')) {
      const src = pj.read(f); if (!src) continue;
      src.lines.forEach((l, i) => {
        const m = /^\s*(ENV|ARG)\s+([A-Za-z_][A-Za-z0-9_]*)/i.exec(l); if (m) def(m[2], f, i + 1, 'dockerfile');
        const from = /^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)/i.exec(l);
        if (from) { const o = ownerOf(st.modules, f); if (o) o.tech.add('Docker'); }   // the image itself is the line's evidence
      });
    }
  }
  // Reads, per language. A read with an inline fallback is not a missing key.
  const READS = [
    { ext: /\.(m?[jt]sx?|cjs)$/, re: [/process\.env\.([A-Za-z_][A-Za-z0-9_]*)/g, /process\.env\[\s*['"]([^'"]+)['"]\s*\]/g, /import\.meta\.env\.([A-Za-z_][A-Za-z0-9_]*)/g], dflt: /\?\?|\|\|/ },
    { ext: /\.py$/, re: [/os\.environ\[\s*['"]([^'"]+)['"]\s*\]/g, /os\.environ\.get\(\s*['"]([^'"]+)['"]/g, /os\.getenv\(\s*['"]([^'"]+)['"]/g, /env\(\s*['"]([A-Z][A-Z0-9_]*)['"]/g], dflt: /,\s*[^)]/ },
    { ext: /\.go$/, re: [/os\.(?:Getenv|LookupEnv)\(\s*"([^"]+)"/g] },
    { ext: /\.cs$/, re: [/Configuration\s*\[\s*"([^"]+)"\s*\]/g, /\.GetValue<[^>]+>\(\s*"([^"]+)"/g, /GetConnectionString\(\s*"([^"]+)"/g, /Environment\.GetEnvironmentVariable\(\s*"([^"]+)"/g, /\b\w*[Cc]onfig\w*\s*\[\s*"([^"]+)"\s*\]/g], dflt: /\?\?/ },
    // environment.getProperty is Spring configuration; System.getProperty is a JVM property (user.home), not a key.
    { ext: /\.(java|kt)$/, re: [/@Value\(\s*"\$\{([^}:]+)(:[^}]*)?\}"/g, /System\.getenv\(\s*"([^"]+)"/g, /\b(?:env|environment)\.getProperty\(\s*"([^"]+)"/g], dflt: /^\s*,/ },
  ];
  const SECTION = [/GetSection\(\s*"([^"]+)"/g, /@ConfigurationProperties\(\s*(?:prefix\s*=\s*)?"([^"]+)"/g];
  for (const m of st.modules) {
    for (const f of m.files) {
      if (isTestPath(f)) continue;
      const lang = READS.find((r) => r.ext.test(f)); if (!lang) continue;
      const src = pj.read(f); if (!src) continue;
      src.lines.forEach((l, i) => {
        if (isComment(l)) return;
        for (const re of lang.re) for (const x of l.matchAll(re)) {
          let key = x[1]; if (/GetConnectionString/.test(x[0])) key = `ConnectionStrings:${key}`;
          const hasDefault = !!x[2] || (lang.dflt ? lang.dflt.test(l.slice(x.index + x[0].length)) : false);
          reads.push({ key, prefix: false, hasDefault, file: f, line: i + 1, ev: ev(f, i + 1, x[1]) });
        }
        for (const re of SECTION) for (const x of l.matchAll(re)) reads.push({ key: x[1], prefix: true, hasDefault: false, file: f, line: i + 1, ev: ev(f, i + 1, x[1]) });
      });
    }
  }
  // A schema read by a tool rather than by code: Prisma's env("DATABASE_URL").
  for (const f of pj.files.filter((x) => /\.prisma$/.test(x))) {
    const src = pj.read(f); if (!src) continue;
    src.lines.forEach((l, i) => { for (const x of l.matchAll(/\benv\(\s*"([^"]+)"\s*\)/g)) reads.push({ key: x[1], prefix: false, hasDefault: false, file: f, line: i + 1, ev: ev(f, i + 1, x[1]) }); });
  }
  return { defs, reads };
}

// Two spellings of one key: case, '-' and the separators of .NET (':' and '__'), Spring ('.') and env ('_').
export const canon = (k) => String(k).toLowerCase().replace(/__|[:._]/g, '.').replace(/-/g, '');

// ---- code: literal URLs ---------------------------------------------------------------------------------------
const NOT_APIS = /(^|\.)(w3\.org|json-schema\.org|schemas\.microsoft\.com|maven\.apache\.org|xmlns\.com|schemas\.xmlsoap\.org|example\.(com|org|net))$/;
export function codeUrls(pj, st, hostOf, ex, out) {
  for (const m of st.modules) {
    for (const f of m.files) {
      if (isTestPath(f)) continue;
      const src = pj.read(f); if (!src) continue;
      src.lines.forEach((l, i) => {
        if (isComment(l)) return;
        for (const x of l.matchAll(/["'`](https?:\/\/[^"'`\s$]+)/g)) {
          const host = hostOf(x[1]);
          if (!host || NOT_APIS.test(host) || isLocalHost(host)) continue;
          // Cited in the line's own spelling (the host is kept lower-cased), after any userinfo.
          const auth = x[1].slice(x[1].indexOf('://') + 3);
          const spelled = (auth.includes('@') ? auth.slice(auth.lastIndexOf('@') + 1) : auth).split(/[/?#]/)[0];
          const anchor = host === '[masked]' || !spelled ? x[1].slice(0, x[1].indexOf('://') + 3) : spelled;
          const n = ex.node('http-api', host === '[masked]' ? 'unknown' : host);
          n.hosts.add(host);
          const e = ev(f, i + 1, anchor);
          n.evidence.push(e);
          out.edges.push({ from: m.id, to: n.id, kind: 'uses-http-api', confidence: 'evidence', via: 'code', evidence: [e] });
          out.codeHosts.add(host);
        }
      });
    }
  }
}

// ---- one module calling another at the address it is served on -----------------------------------------------
// A module says where it is served in its own deployment file: wrangler routes and custom domains (Cloudflare
// Workers), the app of fly.toml (<app>.fly.dev). Another module that writes that host, quoted on its own or as the
// host of a URL, calls it: an app that builds Uri(host: 'api.x.app') never spells a URL, and before this a call
// to the project's own server was drawn as an external API, or not at all.
const SERVED_FILES = /(^|\/)(wrangler\.toml|wrangler\.jsonc?|fly\.toml)$/;
export function servedCalls(pj, st, ex, out) {
  const served = new Map();   // host -> module
  for (const m of st.modules) {
    for (const f of pj.files.filter((x) => SERVED_FILES.test(x) && dirOf(x) === m.dir)) {
      const src = pj.read(f); if (!src) continue;
      src.lines.forEach((l, i) => {
        if (isComment(l)) return;
        const hosts = [];
        for (const x of l.matchAll(/["']?(?:pattern|route)["']?\s*[=:]\s*["']([^"']+)["']/g)) hosts.push(x[1]);
        if (/fly\.toml$/.test(f)) { const a = /^\s*app\s*=\s*["']([a-z0-9-]+)["']/.exec(l); if (a) hosts.push(`${a[1]}.fly.dev`); }
        for (const raw of hosts) {
          const h = raw.replace(/^https?:\/\//, '').replace(/^\*\.?/, '').split('/')[0].toLowerCase();
          if (!/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(h) || isLocalHost(h) || served.has(h)) continue;
          served.set(h, m); m.evidence.push(ev(f, i + 1, raw));
        }
      });
    }
  }
  out.served = served;
  if (!served.size) return;
  for (const [h, to] of served) {
    const q = h.replace(/[.]/g, '\\.');
    const re = new RegExp(`(["'\`])${q}\\1|://${q}(?=[/:"'\`]|$)`);
    for (const m of st.modules) {
      if (m === to) continue;
      for (const f of m.files) {
        if (isTestPath(f)) continue;
        const src = pj.read(f); if (!src) continue;
        src.lines.forEach((l, i) => { if (!isComment(l) && re.test(l)) out.edges.push({ from: m.id, to: to.id, kind: 'calls', confidence: 'evidence', via: 'code', evidence: [ev(f, i + 1, h)] }); });
      }
    }
    // The host was read as an external API: it is the project's own module, so its edges go there and the node goes.
    const id = `ext:http-api:${h}`;
    if (!ex.ext.has(id)) continue;
    for (const e of out.edges) if (e.to === id) { e.to = to.id; e.kind = 'calls'; }
    out.edges = out.edges.filter((e) => e.from !== e.to);
    ex.ext.delete(id);
  }
}

// ---- endpoints ----------------------------------------------------------------------------------------------
// A path is compared in one spelling: lower case, one leading slash, no trailing slash, every parameter ({id},
// :id, ${id}, <int:id>, {id:int}) as {}. A path whose start was built at run time (a variable before the first
// literal segment) is kept as written and marked unresolved; it is never matched.
export function normPath(raw) {
  let p = String(raw).trim();
  let resolved = true;
  // A run-time base in front (`${API}`, `{BASE}`) is dropped; what follows it is the path, if it starts with '/'.
  const lead = /^(\$\{[^}]*\}|\{[A-Za-z_][\w.]*\})/.exec(p);
  if (lead) { p = p.slice(lead[0].length); if (!p.startsWith('/')) resolved = false; }
  const base = lead ? lead[0] : null;
  if (/^https?:\/\//i.test(p)) return null;
  if (p.startsWith('$') || p === '') resolved = false;
  p = p.split(/[?#]/)[0];
  p = p.replace(/\$\{[^}]*\}|\{[^}/]*\}|<[^>/]*>|(^|\/):[A-Za-z_]\w*/g, (s0, lead2) => `${lead2 || ''}{}`);
  if (/\[(controller|action)\]/i.test(p)) resolved = false;
  if (!p.startsWith('/')) p = '/' + p;
  p = p.replace(/\/{2,}/g, '/');
  if (p.length > 1) p = p.replace(/\/$/, '');
  return { path: p.toLowerCase(), resolved, base };
}
const join = (a, b) => `${a || ''}/${b || ''}`;
// The first string argument of a call whose `(` ends at `from` on line i: on that line, or, when nothing follows
// the `(` (a formatter's way with a long call), on the next line that has something on it. `at` is the line the
// string is on, which is the line cited.
const ARG = /^\s*(?:path\s*=\s*)?f?r?(['"`])((?:(?!\1)[^\\]|\\.)*)\1/;
function firstArg(L, i, from) {
  const rest = L[i].slice(from);
  let x = ARG.exec(rest);
  if (x) return { s: x[2], at: i };
  if (rest.trim()) return null;
  for (let j = i + 1; j < Math.min(L.length, i + 4); j++) {
    if (!L[j].trim()) continue;
    x = ARG.exec(L[j]);
    return x ? { s: x[2], at: j } : null;
  }
  return null;
}
// The arguments of a call whose `(` ends at `from` on line i, up to its own `)`, across at most four lines: strings
// and nested brackets are stepped over, so `method:` is read from this call's options and never from the next call's.
function callArgs(L, i, from) {
  let out = ''; let depth = 0; let q = null;
  for (let j = i; j < Math.min(L.length, i + 4); j++) {
    const s = j === i ? L[i].slice(from) : L[j];
    for (let k = 0; k < s.length; k++) {
      const c = s[k];
      if (q) { if (c === '\\') { out += c + (s[k + 1] ?? ''); k += 1; continue; } if (c === q) q = null; }
      else if (c === '"' || c === "'" || c === '`') q = c;
      else if (c === '(' || c === '[' || c === '{') depth += 1;
      else if (c === ')' || c === ']' || c === '}') { if (depth === 0) return out; depth -= 1; }
      out += c;
    }
    out += ' ';
  }
  return out;
}
// The names a module calls HTTP through: axios, and every `x = axios.create(…)` in any of its files (a client made
// in lib/api.ts is called from every component). A name a file itself makes a server of is not one there.
function httpClients(pj, m) {
  const out = new Set(['axios']);
  for (const f of m.files) {
    if (!/\.(m?[jt]sx?|cjs)$/.test(f)) continue;
    const src = pj.read(f); if (!src) continue;
    for (const x of src.text.matchAll(/(\w+)\s*=\s*axios\.create\(/g)) out.add(x[1]);
  }
  return out;
}

export function endpoints(pj, st, out) {
  const provides = []; const consumes = [];
  const mounts = [];
  let dynamic = 0; // routes a server registers with a path that is not a literal: `app.get(path, …)` in a loop
  const add = (list, m, method, raw, f, i, anchor, unresolved = false) => {
    const n = normPath(raw); if (!n) return;
    if (unresolved) n.resolved = false;
    // A route or a call is cited up to its query: `?apiKey=...` stays out of the document.
    if (/^[/$\{]/.test(anchor)) anchor = anchor.split(/[?#]/)[0] || anchor[0];
    // A route whose own path is empty (`@router.get("")`, Django's `path('', …)`) is cited by the call that declares
    // it: an empty quote is not a piece of the line anyone can check.
    if (!anchor) anchor = /([\w.]+)\(\s*(?:[rf$]?(['"`])\2|$)/.exec(pj.read(f)?.lines[i] ?? '')?.[1] ?? '';
    if (!anchor) return;
    if (/\.[a-z0-9]{2,5}$/i.test(n.path)) return; // a static file (/icons/x.svg, /app.js), not an API route
    const e = { module: m.id, method: method.toUpperCase(), path: n.path, resolved: n.resolved, evidence: [ev(f, i + 1, anchor)] };
    // A call whose host is a run-time value (`${baseURL}/x`, f"{base}/x") may be to this repo or to anyone's: it
    // can find its provider here, but its absence here proves nothing.
    if (n.base) e.base = n.base;
    list.push(e);
  };
  for (const m of st.modules) {
    let moduleClients = null;
    for (const f of m.files) {
      if (isTestPath(f)) continue;
      const src = pj.read(f); if (!src) continue;
      const L = src.lines;
      const text = src.text;
      // .NET: attribute routing and minimal APIs
      if (/\.cs$/.test(f)) {
        let prefix = null; let cls = null; const groups = new Map();
        L.forEach((l, i) => {
          if (isComment(l)) return;
          const r = /^\s*\[Route\(\s*"([^"]*)"\s*\)\]/.exec(l);
          const c = /\bclass\s+(\w+)/.exec(l);
          if (r && !cls) { prefix = r[1]; }
          if (c) { cls = c[1]; if (prefix !== null) prefix = prefix.replace(/\[controller\]/gi, cls.replace(/Controller$/, '')); }
          const h = /^\s*\[Http(Get|Post|Put|Patch|Delete)(?:\(\s*"([^"]*)"\s*\))?\]/.exec(l);
          if (h && cls) add(provides, m, h[1], h[2] && h[2].startsWith('/') ? h[2] : join(prefix, h[2]), f, i, `Http${h[1]}`);
          const g = /(\w+)\s*=\s*(\w+)\.MapGroup\(\s*"([^"]*)"/.exec(l);
          if (g) groups.set(g[1], join(groups.get(g[2]) || '', g[3]));
          const mp = /(\w+)\.Map(Get|Post|Put|Patch|Delete)\(\s*"([^"]*)"/.exec(l);
          if (mp) add(provides, m, mp[2], join(groups.get(mp[1]) || '', mp[3]), f, i, `Map${mp[2]}`);
          const refit = /^\s*\[(Get|Post|Put|Patch|Delete)\(\s*"([^"]+)"\s*\)\]/.exec(l);
          if (refit) add(consumes, m, refit[1], refit[2], f, i, refit[2]);
          const hc = /\.(Get|Post|Put|Patch|Delete)(?:FromJson|AsJson)?Async\(\s*\$?"([^"]*)"/.exec(l);
          if (hc) add(consumes, m, hc[1], hc[2], f, i, hc[2]);
        });
      }
      // Node: Express / Fastify / Nest providers; fetch / axios consumers
      if (/\.(m?[jt]sx?|cjs)$/.test(f)) {
        const clients = new Set(moduleClients ??= httpClients(pj, m));
        for (const x of text.matchAll(/(\w+)\s*=\s*(?:express|fastify|Fastify|Router|express\.Router)\(|(\w+)\s*=\s*new\s+Hono\b/g)) clients.delete(x[1] ?? x[2]);
        // Express routers: a route on a router is served under the path it is mounted at. Mounted in this file, the
        // prefix is known; mounted elsewhere it is not, and the route is listed but never matched.
        const routers = new Set([...text.matchAll(/(\w+)\s*=\s*(?:express\.)?Router\(/g)].map((x) => x[1]));
        const mountedHere = new Map();
        for (const x of text.matchAll(/\b(\w+)\.use\(\s*(['"`])(\/[^'"`]*)\2\s*,\s*(\w+)/g)) {
          if (routers.has(x[4])) mountedHere.set(x[4], x[3]);
          else mounts.push(normPath(x[3]).path);
        }
        let nest = null;
        L.forEach((l, i) => {
          if (isComment(l)) return;
          const dyn = /\b(app|router|server|fastify|api|routes)\.(get|post|put|patch|delete|all)\(\s*[A-Za-z_$][\w.$]*\s*,/.exec(l);
          if (dyn && !clients.has(dyn[1])) dynamic += 1;
          const ex = /\b(app|router|server|fastify|api|routes)\.(get|post|put|patch|delete|all)\(\s*(['"`])(\/[^'"`]*)\3/.exec(l);
          if (ex && !clients.has(ex[1])) {
            const onRouter = routers.has(ex[1]) || ex[1] === 'router' || ex[1] === 'routes';
            const pre = onRouter ? mountedHere.get(ex[1]) : '';
            add(provides, m, ex[2] === 'all' ? '*' : ex[2], onRouter && pre !== undefined ? join(pre, ex[4]) : ex[4], f, i, ex[4], onRouter && pre === undefined);
          }
          const nc = /@Controller\(\s*['"]([^'"]*)['"]\s*\)/.exec(l); if (nc) nest = nc[1];
          const nm = /@(Get|Post|Put|Patch|Delete|All)\(\s*(?:['"]([^'"]*)['"])?\s*\)/.exec(l);
          if (nm && nest !== null) add(provides, m, nm[1] === 'All' ? '*' : nm[1], join(nest, nm[2] || ''), f, i, `@${nm[1]}`);
          const fe = /\bfetch\(\s*(['"`])([^'"`]+)\1/.exec(l);
          if (fe && !/^https?:/.test(fe[2])) {
            const mt = /method\s*:\s*['"](\w+)['"]/.exec(callArgs(L, i, fe.index + l.slice(fe.index).indexOf('(') + 1));
            add(consumes, m, mt ? mt[1] : 'GET', fe[2], f, i, fe[2]);
          }
          // `api.get<User[]>("/x")` and a call whose path is on the next line read alike.
          const ax = /\b(\w+)\.(get|post|put|patch|delete)(?:<[^()]*?>)?\(/.exec(l);
          const axa = ax && clients.has(ax[1]) ? firstArg(L, i, ax.index + ax[0].length) : null;
          if (axa && axa.s && !/^https?:/.test(axa.s)) add(consumes, m, ax[2], axa.s, f, axa.at, axa.s);
        });
      }
      // Dart consumers: a Dio client's relative path, and a full URL (http.get(Uri.parse(…)), Uri.https(host, path))
      // only when its host is one this project serves; any other host is someone else's API. `$id` is a parameter.
      if (/\.dart$/.test(f)) {
        const ours = (h) => out.served?.has(h.toLowerCase());
        const dp = (s) => s.replace(/\$\{[^}]*\}|\$\w+/g, '{x}');
        L.forEach((l, i) => {
          if (isComment(l)) return;
          const dio = /\b(\w*[dD]io\w*|_?client|_?api)\.(get|post|put|patch|delete)(?:<[^()]*?>)?\(\s*(['"])(\/[^'"]*)\3/.exec(l);
          if (dio) add(consumes, m, dio[2], dp(dio[4]), f, i, dio[4]);
          const hp = /\.(get|post|put|patch|delete)\(\s*Uri\.parse\(\s*(['"])https?:\/\/([^/'"$]+)(\/[^'"]*)\2/.exec(l);
          if (hp && ours(hp[3])) add(consumes, m, hp[1], dp(hp[4]), f, i, hp[4]);
          const uh = /\bUri\.https?\(\s*(['"])([^'"$]+)\1\s*,\s*(['"])(\/[^'"]*)\3/.exec(l);
          if (uh && ours(uh[2])) add(consumes, m, 'GET', dp(uh[4]), f, i, uh[4]);
        });
      }
      // Python: FastAPI / Flask / Django providers; requests / httpx consumers
      if (/\.py$/.test(f)) {
        const pre = new Map();
        for (const x of text.matchAll(/(\w+)\s*=\s*(?:APIRouter|Blueprint)\([^)]*?(?:prefix|url_prefix)\s*=\s*['"]([^'"]+)['"]/g)) pre.set(x[1], x[2]);
        L.forEach((l, i) => {
          if (isComment(l)) return;
          // A decorator's path on its own line, as black writes a long one, reads like one on the decorator's.
          const fa = /^\s*@(\w+)\.(get|post|put|patch|delete)\(/.exec(l);
          const faa = fa && firstArg(L, i, fa[0].length);
          if (faa) add(provides, m, fa[2], join(pre.get(fa[1]) || '', faa.s), f, faa.s ? faa.at : i, faa.s);
          const flo = /^\s*@(\w+)\.route\(/.exec(l);
          const fla = flo && firstArg(L, i, flo[0].length);
          if (fla) {
            const fl = [null, flo[1], fla.s];
            const ms = /methods\s*=\s*\[([^\]]*)\]/.exec(L.slice(i, fla.at + 4).join(' '));
            const methods = ms ? [...ms[1].matchAll(/['"](\w+)['"]/g)].map((x) => x[1]) : ['GET'];
            for (const mt of methods) add(provides, m, mt, join(pre.get(fl[1]) || '', fl[2]), f, fl[2] ? fla.at : i, fl[2]);
          }
          if (/(^|\/)urls\.py$/.test(f)) {
            const dj = /\b(?:re_)?path\(\s*r?['"]([^'"]*)['"]\s*,\s*(?!include\()/.exec(l);
            if (dj) add(provides, m, '*', dj[1], f, i, dj[1]);
          }
          const rq = /\b(requests|httpx|client|session)\.(get|post|put|patch|delete)\(\s*f?['"]([^'"]+)['"]/.exec(l);
          if (rq && !/^https?:/.test(rq[3])) add(consumes, m, rq[2], rq[3], f, i, rq[3]);
        });
      }
      // Go: net/http, gin, chi providers; http.Get / NewRequest consumers
      if (/\.go$/.test(f)) {
        const pre = new Map();
        L.forEach((l, i) => {
          if (isComment(l)) return;
          const gr = /(\w+)\s*:?=\s*(\w+)\.Group\(\s*"([^"]*)"/.exec(l); if (gr) pre.set(gr[1], join(pre.get(gr[2]) || '', gr[3]));
          const hf = /\b(\w+)\.HandleFunc\(\s*"(?:(GET|POST|PUT|PATCH|DELETE)\s+)?(\/[^"]*)"/.exec(l);
          if (hf) add(provides, m, hf[2] || '*', join(pre.get(hf[1]) || '', hf[3]), f, i, hf[3]);
          const gn = /\b(\w+)\.(GET|POST|PUT|PATCH|DELETE|Get|Post|Put|Patch|Delete)\(\s*"(\/[^"]*)"/.exec(l);
          if (gn && gn[1] !== 'http') add(provides, m, gn[2], join(pre.get(gn[1]) || '', gn[3]), f, i, gn[3]);
          const hg = /\bhttp\.(Get|Post|Head)\(\s*"(\/[^"]*)"/.exec(l); if (hg) add(consumes, m, hg[1], hg[2], f, i, hg[2]);
          const nr = /http\.NewRequest(?:WithContext)?\([^"]*"(GET|POST|PUT|PATCH|DELETE)"\s*,\s*"(\/[^"]*)"/.exec(l); if (nr) add(consumes, m, nr[1], nr[2], f, i, nr[2]);
        });
      }
      // Spring (Java/Kotlin). A @FeignClient interface declares calls, so its mappings are consumed.
      if (/\.(java|kt)$/.test(f)) {
        const feign = /@FeignClient\b/.test(text);
        let base = null; let seenClass = false;
        L.forEach((l, i) => {
          if (isComment(l)) return;
          const rm = /@RequestMapping\(\s*(?:value\s*=\s*|path\s*=\s*)?"([^"]*)"(.*)$/.exec(l);
          if (/\b(class|interface)\s+\w+/.test(l)) seenClass = true;
          if (rm && !seenClass) { base = rm[1]; return; }
          const gm = /@(Get|Post|Put|Patch|Delete)Mapping(?:\(\s*(?:value\s*=\s*|path\s*=\s*)?"([^"]*)")?/.exec(l);
          if (gm && seenClass) add(feign ? consumes : provides, m, gm[1], join(base, gm[2] || ''), f, i, `@${gm[1]}Mapping`);
          if (rm && seenClass) { const mt = /RequestMethod\.(\w+)/.exec(rm[2]); add(feign ? consumes : provides, m, mt ? mt[1] : '*', join(base, rm[1]), f, i, '@RequestMapping'); }
          const rt = /\.(getForObject|getForEntity|postForObject|postForEntity|put|delete)\(\s*"(\/[^"]*)"/.exec(l);
          if (rt) add(consumes, m, rt[1].startsWith('get') ? 'GET' : rt[1].startsWith('post') ? 'POST' : rt[1].toUpperCase(), rt[2], f, i, rt[2]);
          const wc = /\.(get|post|put|patch|delete)\(\)\s*\.uri\(\s*"(\/[^"]*)"/.exec(l); if (wc) add(consumes, m, wc[1], wc[2], f, i, wc[2]);
        });
      }
    }
  }
  // A route a platform calls rather than code: a compose or Dockerfile healthcheck (`curl -f http://localhost:8000/health`)
  // and a Kubernetes probe (`httpGet: path: /healthz`). Not on the map as a call, since no module makes it; only the
  // provider is spared being reported unused.
  const probes = [];
  for (const f of pj.files) {
    const compose = /(^|\/)(docker-)?compose[^/]*\.ya?ml$/.test(f); const docker = /(^|\/)Dockerfile[^/]*$/.test(f);
    const k8s = /\.ya?ml$/.test(f) && !compose;
    if (!(compose || docker || k8s) || isTestPath(f)) continue;
    const src = pj.read(f); if (!src) continue;
    if (k8s && !/\b(liveness|readiness|startup)Probe\s*:/.test(src.text)) continue;
    src.lines.forEach((l) => {
      if (isComment(l)) return;
      if (k8s) { const kp = /^\s*path\s*:\s*['"]?(\/[^\s'"]*)/.exec(l); if (kp) probes.push(normPath(kp[1]).path); return; }
      for (const x of l.matchAll(/https?:\/\/([^/\s'"]+)(\/[^\s'"\]),;)]*)/g)) if (isLocalHost(x[1])) probes.push(normPath(x[2]).path);
    });
  }
  if (dynamic) out.notMeasured.push({ what: `routes registered with a run-time path (${dynamic})`, reason: 'the path is a variable, not a literal, so the route is not on the map' });
  return { provides, consumes, mounts: [...new Set(mounts)].sort(), probes: [...new Set(probes)].sort() };
}

// ---- containers ---------------------------------------------------------------------------------------------
export function containers(pj, st, rules, hostOf, ex, cfg, out) {
  const services = [];
  for (const f of pj.files.filter((x) => /(^|\/)(docker-)?compose[^/]*\.ya?ml$/.test(x) && !isTestPath(x))) {
    const src = pj.read(f); if (!src) continue;
    let y; try { y = parseYaml(src.text); } catch (e) { out.notMeasured.push({ what: f, reason: `YAML outside the subset this scanner reads: ${e.message}` }); continue; }
    // ${VAR} substitution in a compose file reads the variable.
    src.lines.forEach((l, i) => { for (const x of l.matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*)/g)) cfg.reads.push({ key: x[1], prefix: false, hasDefault: /:-|-/.test(l.slice(x.index, l.indexOf('}', x.index))), file: f, line: i + 1, ev: ev(f, i + 1, x[1]) }); });
    const svcs = yGet(y, 'services'); if (!svcs || svcs.v.t !== 'map') continue;
    for (const s of svcs.v.e) {
      // One service, however many files define it (docker-compose.yml + docker-compose.override.yml).
      const id = `svc:${s.k}`;
      let node = services.find((x) => x.id === id);
      if (node) node.evidence.push(ev(f, s.line, s.k));
      else { node = { id, kind: 'service', name: s.k, file: f, evidence: [ev(f, s.line, s.k)] }; services.push(node); }
      const img = yGet(s.v, 'image');
      if (img && img.v.t === 'str') {
        const name = img.v.v.replace(/^[^/]+\.[^/]+\//, (r) => (/^(mcr\.microsoft\.com|quay\.io|docker\.elastic\.co)\//.test(r) ? r : '')).split(/[:@]/)[0];
        if (!node.image) node.image = img.v.v;
        const hit = rules.images[name] || rules.images[name.replace(/^library\//, '')];
        if (hit) {
          const n = ex.node(hit[0], hit[1]); const e = ev(f, img.line, 'image'); n.evidence.push(e);
          out.edges.push({ from: id, to: n.id, kind: 'runs', confidence: 'evidence', via: 'compose', evidence: [e] });
        }
      }
      const build = yGet(s.v, 'build');
      if (build) {
        const ctx = build.v.t === 'str' ? build.v.v : (yGet(build.v, 'context') || { v: { v: '.' } }).v.v;
        const dir = P.normalize(P.join(dirOf(f), ctx)).replace(/\/$/, '') || '.';
        const t = st.modules.filter((m) => m.dir === dir || under(m.dir, dir)).sort((a, b) => a.dir.length - b.dir.length)[0];
        if (t) { const e = ev(f, build.line, 'build'); out.edges.push({ from: id, to: t.id, kind: 'builds', confidence: 'evidence', via: 'compose', evidence: [e] }); t.deployed = e; }
      }
      for (const k of ['depends_on', 'links']) {
        const d = yGet(s.v, k); if (!d) continue;
        const names = d.v.t === 'seq' ? d.v.e.map((x) => ({ n: x.v.v, line: x.line })) : d.v.t === 'map' ? d.v.e.map((x) => ({ n: x.k, line: x.line })) : [];
        for (const { n, line } of names) {
          const target = String(n).split(':')[0];
          out.edges.push({ from: id, to: `svc:${target}`, kind: 'depends-on', confidence: 'evidence', via: 'compose', evidence: [ev(f, line, target)] });
        }
      }
      const env = yGet(s.v, 'environment');
      if (env) {
        const items = env.v.t === 'map' ? env.v.e.map((x) => ({ k: x.k, v: x.v.v, line: x.line }))
          : env.v.t === 'seq' ? env.v.e.map((x) => { const [k, ...r] = String(x.v.v).split('='); return { k, v: r.join('='), line: x.line }; }) : [];
        for (const it of items) cfg.defs.push({ key: it.k, file: f, line: it.line, source: 'compose', ev: ev(f, it.line, it.k) });
      }
    }
  }
  const kube = pj.files.filter((f) => /(^|\/)(k8s|kubernetes|manifests|deploy)\/.*\.ya?ml$/.test(f) && !isTestPath(f));
  if (kube.length) out.notMeasured.push({ what: `Kubernetes manifests (${kube.length} file${kube.length === 1 ? '' : 's'})`, reason: 'not parsed: services and resources declared there are not on the map' });
  const helm = pj.files.filter((f) => /(^|\/)Chart\.ya?ml$/.test(f) && !isTestPath(f));
  if (helm.length) out.notMeasured.push({ what: `Helm charts (${helm.length})`, reason: 'templates are not rendered, so nothing in them is on the map' });
  return services;
}
