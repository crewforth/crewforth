// detect.mjs — the ten gap detectors. Each returns findings in the shape of the findings core
// (kit/eval/lib/findings): every one cites the lines it was read from.
//
// Two classes, and the class is the rule's, not the finding's:
//   proven    the cited lines show it on their own (a cycle, an import with no declaration, a read with no key)
//   inferred  concluded from absence in THIS repository — an external caller, reflection, a CLI or a framework can use
//             what the scan did not see. These are written with data.defaultHidden = true: a reader sees them only
//             when asking for them, until their false-positive rate has been measured in the field.
// The wording describes what was searched, never who is at fault: "no caller found in this repo".

import crypto from 'node:crypto';
import { canon } from './surface.mjs';
import { sortEv } from './project.mjs';

export const RULES = ['cycle', 'module-orphan', 'version-drift', 'dep-undeclared', 'dep-unused', 'config-missing',
  'config-unread', 'endpoint-missing', 'endpoint-unused', 'external-unowned'];
// module-orphan and config-unread conclude from absence too: a service started from a CLI, or settings bound by
// name (pydantic BaseSettings), leave nothing in the lines for a scan to see.
export const INFERRED = new Set(['dep-unused', 'endpoint-unused', 'external-unowned', 'module-orphan', 'config-unread']);
const HIDDEN_REASON = 'inferred from absence in this repository; shown on request until its false-positive rate is measured';
const MAX_EV = 5;

// Collected raw, built once: the same rule and subject seen twice (a missing endpoint called from two places)
// is ONE finding citing both places, never two findings with one id.
function finding(rule, subject, title, evidence, data = {}) { return { rule, subject, title, evidence, data }; }
function build(raw) {
  const by = new Map();
  for (const r of raw) {
    const k = `${r.rule}\u0000${r.subject}`;
    if (by.has(k)) by.get(k).evidence.push(...r.evidence); else by.set(k, { ...r, evidence: [...r.evidence] });
  }
  return [...by.values()].map(({ rule, subject, title, evidence, data }) => {
    const slug = subject.toLowerCase().replace(/[^a-z0-9._:-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 120) || 'x';
    const h = crypto.createHash('sha1').update(`${rule}\u0000${subject}`).digest('hex').slice(0, 8);
    const all = sortEv(evidence);
    const f = { id: `${rule}:${slug}:${h}`, rule, title: title.slice(0, 200),
      confidence: INFERRED.has(rule) ? 'inferred' : 'proven', evidence: all.slice(0, MAX_EV) };
    const d = { subject, ...data };
    if (all.length > MAX_EV) d.evidenceTotal = all.length;
    if (INFERRED.has(rule)) { d.defaultHidden = true; d.hiddenReason = HIDDEN_REASON; }
    f.data = d;
    return f;
  });
}

// Endpoint match: same method or either is '*'; same segment count; segments equal or either is a parameter.
function epMatch(a, b) {
  if (a.method !== b.method && a.method !== '*' && b.method !== '*') return false;
  const x = a.path.split('/'); const y = b.path.split('/');
  return x.length === y.length && x.every((s, i) => s === y[i] || s === '{}' || y[i] === '{}');
}

export function detect(ctx) {
  const { st, cfg, eps, names, stdlib, notMeasured } = ctx;
  const out = [];
  const mods = st.modules;
  const byId = new Map(mods.map((m) => [m.id, m]));
  const refs = mods.flatMap((m) => m.refs.filter((r) => byId.has(r.to)).map((r) => ({ from: m.id, ...r })));

  // ---- cycle (evidence edges only: a cycle through an inferred edge is not shown by the lines) ----
  {
    const adj = new Map(mods.map((m) => [m.id, []]));
    for (const r of refs) if (r.confidence === 'evidence' && r.from !== r.to) adj.get(r.from).push(r.to);
    let idx = 0; const index = new Map(); const low = new Map(); const stack = []; const on = new Set(); const sccs = [];
    const strong = (v) => {
      index.set(v, idx); low.set(v, idx); idx++; stack.push(v); on.add(v);
      for (const w of [...new Set(adj.get(v))].sort()) {
        if (!index.has(w)) { strong(w); low.set(v, Math.min(low.get(v), low.get(w))); }
        else if (on.has(w)) low.set(v, Math.min(low.get(v), index.get(w)));
      }
      if (low.get(v) === index.get(v)) { const c = []; let w; do { w = stack.pop(); on.delete(w); c.push(w); } while (w !== v); if (c.length > 1) sccs.push(c.sort()); }
    };
    for (const id of [...adj.keys()].sort()) if (!index.has(id)) strong(id);
    for (const c of sccs) {
      const inC = new Set(c);
      const e = refs.filter((r) => r.confidence === 'evidence' && inC.has(r.from) && inC.has(r.to)).map((r) => r.ev);
      const names2 = c.map((id) => byId.get(id).name);
      out.push(finding('cycle', c.join(' '), `Modules reference each other in a cycle: ${names2.join(' → ')} → ${names2[0]}`, e, { modules: c }));
    }
  }

  // ---- module-orphan ----
  if (mods.length >= 2) {
    const incoming = new Set(refs.map((r) => r.to));
    for (const m of mods) {
      if (m.dir === '.' || m.entry || m.deployed || incoming.has(m.id)) continue;
      if (m.tech.has('maven:pom')) continue; // an aggregator is a build entry point
      out.push(finding('module-orphan', m.id, `No module references ${m.name}, and it has no entry point`, m.evidence, { module: m.id }));
    }
  }

  // ---- version-drift ----
  {
    const by = new Map();
    for (const m of mods) for (const d of m.deps) {
      // A peer range is a range by design, and a URL is not a version.
      if (!d.version || d.central || d.peer || d.version === 'url' || /^(workspace:|file:|link:|\*$)/.test(d.version)) continue;
      const k = `${d.eco}\u0000${d.name}`;
      if (!by.has(k)) by.set(k, []);
      by.get(k).push({ m, d });
    }
    for (const [k, list] of [...by.entries()].sort()) {
      const versions = [...new Set(list.map((x) => x.d.version))].sort();
      if (versions.length < 2 || new Set(list.map((x) => x.m.id)).size < 2) continue; // drift is between modules
      const name = k.split('\u0000')[1];
      out.push(finding('version-drift', k.replace('\u0000', ':'), `${name} is declared at ${versions.length} versions: ${versions.join(', ')}`,
        list.map((x) => x.d.ev), { package: name, versions, modules: [...new Set(list.map((x) => x.m.id))].sort() }));
    }
  }

  // ---- dep-undeclared / dep-unused (node, python, go) ----
  const builtins = new Set(names.nodeBuiltins.names);
  const pyAlias = names.pythonImportNames.map;
  const pyImportName = (dist) => (pyAlias[dist.toLowerCase()] || dist).toLowerCase().replace(/-/g, '_');
  const pyLocal = new Set(mods.filter((m) => m.stack === 'python').flatMap((m) => [...(m.localNames || []), ...m.selfNames.map((n) => n.toLowerCase().replace(/-/g, '_'))]));
  for (const m of mods) {
    if (!['node', 'python', 'go'].includes(m.stack) || !m.manifest) continue;
    const ancestors = mods.filter((o) => o.stack === m.stack && o !== m && (o.dir === '.' || m.dir.startsWith(o.dir + '/')));
    const declared = new Set([...m.deps, ...ancestors.flatMap((o) => o.deps)].map((d) => d.name));
    const roots = new Map();
    for (const im of m.imports) { if (!roots.has(im.root)) roots.set(im.root, []); roots.get(im.root).push(im.ev); }
    if (m.stack === 'node') {
      const aliases = [...m.aliases, ...ancestors.flatMap((o) => o.aliases), ...st.globalAliases].filter(Boolean);
      for (const [root, evs] of roots) {
        const bare = root.replace(/^node:/, '');
        if (root.startsWith('node:') || builtins.has(bare) || builtins.has(bare.split('/')[0])) continue;
        if (/^(@\/|~\/|#|virtual:|bun:|data:|https?:)|[!?]/.test(root) || root === '@' || root === '~') continue;
        if (aliases.some((a) => root === a.replace(/\/$/, '') || root.startsWith(a))) continue;
        if (declared.has(root) || m.selfNames.includes(root) || declared.has(`@types/${root}`)) continue;
        out.push(finding('dep-undeclared', `${m.id} ${root}`, `${root} is imported but not declared in ${m.manifest}`, evs, { module: m.id, package: root }));
      }
      const used = new Set(roots.keys());
      for (const d of m.deps) {
        if (d.dev || d.name.startsWith('@types/') || used.has(d.name)) continue;
        out.push(finding('dep-unused', `${m.id} ${d.name}`, `${d.name} is declared but no import of it was found in this repo`, [d.ev], { module: m.id, package: d.name }));
      }
    } else if (m.stack === 'python') {
      const decl = new Set([...declared].map(pyImportName));
      for (const [root, evs] of roots) {
        const r = root.toLowerCase();
        if (stdlib.has(root) || root === '__future__' || pyLocal.has(root) || pyLocal.has(r) || decl.has(r)) continue;
        out.push(finding('dep-undeclared', `${m.id} ${root}`, `${root} is imported but not declared in ${m.manifest}`, evs, { module: m.id, package: root }));
      }
      const used = new Set([...roots.keys()].map((x) => x.toLowerCase()));
      for (const d of m.deps) {
        if (d.dev || used.has(pyImportName(d.name))) continue;
        out.push(finding('dep-unused', `${m.id} ${d.name}`, `${d.name} is declared but no import of it was found in this repo`, [d.ev], { module: m.id, package: d.name }));
      }
    } else {
      const req = m.deps.map((d) => d.name);
      for (const [root, evs] of roots) {
        if (req.some((r) => root === r || root.startsWith(r + '/'))) continue;
        out.push(finding('dep-undeclared', `${m.id} ${root}`, `${root} is imported but not required in ${m.manifest}`, evs, { module: m.id, package: root }));
      }
      for (const d of m.deps) {
        if (d.indirect || [...roots.keys()].some((r) => r === d.name || r.startsWith(d.name + '/'))) continue;
        out.push(finding('dep-unused', `${m.id} ${d.name}`, `${d.name} is required but no import of it was found in this repo`, [d.ev], { module: m.id, package: d.name }));
      }
    }
  }

  // ---- config-missing / config-unread ----
  {
    const platform = new Set(names.platformEnv.names.map(canon));
    const framework = names.frameworkConfig.names;
    const defined = new Set(cfg.defs.map((d) => canon(d.key)));
    const exactReads = new Set(cfg.reads.filter((r) => !r.prefix).map((r) => canon(r.key)));
    const prefixReads = cfg.reads.filter((r) => r.prefix).map((r) => canon(r.key));
    const missing = new Map();
    const fileDefs = cfg.defs.filter((d) => ['env', 'appsettings', 'properties', 'yaml'].includes(d.source)).length;
    if (!fileDefs && cfg.reads.some((r) => !r.prefix && !r.hasDefault)) notMeasured.push({ what: 'config-missing', reason: 'this repository has no configuration file (.env, appsettings, application.properties/yml), so where its keys are meant to come from is not on disk' });
    for (const r of fileDefs ? cfg.reads : []) {
      if (r.prefix || r.hasDefault) continue;
      const c = canon(r.key);
      if (defined.has(c) || platform.has(c)) continue;
      if (!missing.has(c)) missing.set(c, { key: r.key, evs: [] });
      missing.get(c).evs.push(r.ev);
    }
    for (const [c, x] of [...missing.entries()].sort()) out.push(finding('config-missing', c, `${x.key} is read but defined in no configuration file`, x.evs, { key: x.key }));
    if (mods.length) {
      for (const d of cfg.defs) {
        if (!['env', 'appsettings', 'properties', 'yaml'].includes(d.source)) continue;
        const c = canon(d.key);
        if (exactReads.has(c) || prefixReads.some((p) => c === p || c.startsWith(p + '.'))) continue;
        if (framework.some((fw) => (/[:.]$/.test(fw) ? d.key.startsWith(fw) || d.key === fw.slice(0, -1) : d.key === fw))) continue;
        out.push(finding('config-unread', `${d.file} ${d.key}`, `${d.key} is configured in ${d.file} but no read of it was found`, [d.ev], { key: d.key, file: d.file }));
      }
    }
  }

  // ---- endpoint-missing / endpoint-unused ----
  {
    const prov = eps.provides.filter((e) => e.resolved); const cons = eps.consumes.filter((e) => e.resolved);
    if (eps.provides.length) {
      // A call is judged only against a provider it could belong to: one that shares its first path segment. A
      // path no provider here begins with is most likely another service's, and is left to that service's map.
      const firsts = new Set(prov.map((p) => p.path.split('/')[1]));
      // Under a router mounted elsewhere the provider's full path is not known, so a call there is not judged.
      const under = (c) => eps.mounts.some((mt) => c.path === mt || c.path.startsWith(mt === '/' ? '/' : mt + '/'));
      for (const c of cons) {
        if (prov.some((p) => epMatch(p, c))) continue;
        if (!firsts.has(c.path.split('/')[1]) || under(c)) continue;
        out.push(finding('endpoint-missing', `${c.module} ${c.method} ${c.path}`, `${c.method} ${c.path} is called but no endpoint in this repo provides it`, c.evidence, { method: c.method, path: c.path, module: c.module }));
      }
    } else if (eps.consumes.length) {
      notMeasured.push({ what: 'endpoint-missing', reason: 'this repository provides no endpoint, so the paths it calls can only be matched against the provider\'s own map' });
    }
    if (eps.consumes.length) {
      for (const p of prov) {
        if (cons.some((c) => epMatch(p, c))) continue;
        out.push(finding('endpoint-unused', `${p.module} ${p.method} ${p.path}`, `${p.method} ${p.path} is provided but no caller found in this repo`, p.evidence, { method: p.method, path: p.path, module: p.module }));
      }
    } else if (eps.provides.length) {
      notMeasured.push({ what: 'endpoint-unused', reason: 'this repository calls none of its own endpoints, so their callers are elsewhere' });
    }
    const unresolved = [...eps.provides, ...eps.consumes].filter((e) => !e.resolved).length;
    if (unresolved) notMeasured.push({ what: `endpoints with a run-time path (${unresolved})`, reason: 'the start of the path is built at run time, so they are listed but never matched' });
  }

  // ---- external-unowned ----
  {
    const readCanon = new Set(cfg.reads.map((r) => canon(r.key)));
    for (const u of ctx.configUrls) {
      if (!u.host || u.host === '[masked]') continue;
      if (readCanon.has(canon(u.key)) || ctx.codeHosts.has(u.host)) continue;
      out.push(finding('external-unowned', `${u.ev.file} ${u.key}`, `${u.host} is configured under ${u.key} but no client using it was found`, [u.ev], { key: u.key, host: u.host }));
    }
  }
  return build(out);
}
