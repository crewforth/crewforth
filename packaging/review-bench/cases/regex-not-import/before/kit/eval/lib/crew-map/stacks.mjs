// stacks.mjs — modules, their declared dependencies, their imports and their references to each other, for the
// five stacks. Every fact carries the line it was read from; what cannot be read is returned as notMeasured.
//
// A module is { id, name, stack, dir, manifest, tech[], evidence[], deps[], refs[], imports[], entry, entryEv,
//              aliases[], selfNames[], files[] }.
//   deps    { eco, name, version, dev, ev }                       declared in the manifest
//   refs    { to: <module name or manifest path>, by, ev, confidence }   this module names another one
//   imports { spec, root, ev, file }                              a source file imports a package
// `confidence` is 'evidence' when the line itself names the other module, 'inferred' when it was concluded
// (a namespace prefix, a Gradle line read by pattern).

import path from 'node:path';
import { parseJsonc, parseToml, parseXml, xKids, xKid, xText, xLine, xFind, Unsupported } from './parse.mjs';
import { ev, evFirst, lineOf, isTestPath } from './project.mjs';

const P = path.posix;
const dirOf = (f) => { const d = P.dirname(f); return d === '.' ? '.' : d; };
const under = (file, dir) => dir === '.' || file === dir || file.startsWith(dir + '/');
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const isComment = (l) => /^\s*(\/\/|#|\*|\/\*|<!--)/.test(l);

export const SOURCE_EXT = {
  node: /\.(m?[jt]sx?|cjs|cts|mts)$/, python: /\.py$/, go: /\.go$/, dotnet: /\.cs$/, java: /\.(java|kt)$/,
};

function mod(stack, name, manifest, dir) {
  return { id: `mod:${stack}:${name}`, name, stack, dir, manifest, tech: new Set(), evidence: [], deps: [], refs: [],
    imports: [], entry: false, entryEv: null, aliases: [], selfNames: [name], files: [] };
}

// A version the map may show. A dependency can be declared by URL (git+https://token@host/repo.git#v1), and a URL
// is never copied out: it reads as 'url', which no detector compares.
export function cleanVersion(v) {
  const s = String(v == null ? '' : v).trim();
  if (/:\/\/|@|^(git|github|gitlab|bitbucket|file|link|http)[+:]/i.test(s)) return 'url';
  return s.slice(0, 64);
}

// Packages that make a module something that is RUN (a server, a worker, a CLI), so it is an entry point even when
// nothing in the repository references it.
const RUNNABLE = { npm: ['express', 'fastify', '@nestjs/core', 'koa', '@hapi/hapi', 'next', 'nuxt', 'vite', 'react-scripts'],
  pypi: ['fastapi', 'flask', 'django', 'uvicorn', 'gunicorn', 'celery', 'streamlit', 'aiohttp', 'starlette', 'typer', 'click'] };
function runnable(m) {
  if (m.entry) return;
  const d = m.deps.find((x) => (RUNNABLE[x.eco] || []).includes(x.eco === 'pypi' ? x.name.toLowerCase() : x.name));
  if (d) { m.entry = true; m.entryEv = d.ev; }
}

// Hand each source file to the deepest module of its stack whose directory holds it.
// A file under a sample project's own manifest (left out of discovery) belongs to that sample, so to nobody here.
const MANIFEST = /(^|\/)(package\.json|pyproject\.toml|setup\.cfg|requirements[^/]*\.txt|go\.mod|[^/]+\.(cs|fs|vb)proj|pom\.xml|build\.gradle(\.kts)?|settings\.gradle(\.kts)?)$/;
function own(modules, files, stack) {
  const mine = modules.filter((m) => m.stack === stack).sort((a, b) => b.dir.length - a.dir.length);
  const samples = files.filter((f) => MANIFEST.test(f) && isTestPath(f)).map(dirOf);
  for (const f of files) {
    if (!SOURCE_EXT[stack].test(f)) continue;
    if (samples.some((d) => under(f, d))) continue;
    const m = mine.find((x) => under(f, x.dir));
    if (m) m.files.push(f);
  }
}

// ---- Node / TypeScript ---------------------------------------------------------------------------------------
function nodeStack(pj, out) {
  const manifests = pj.manifests.filter((f) => P.basename(f) === 'package.json');
  for (const f of manifests) {
    const src = pj.read(f); if (!src) continue;
    let doc; try { doc = parseJsonc(src.text); } catch (e) { out.notMeasured.push({ what: f, reason: `package.json could not be read: ${e.message}` }); continue; }
    const v = doc.value || {}; const L = (k) => doc.lines.get(k.join('\u0000')) || 1;
    const named = typeof v.name === 'string' && v.name.trim() !== '';
    const name = named ? v.name : (dirOf(f) === '.' ? 'root' : dirOf(f));
    const m = mod('node', name, f, dirOf(f));
    const brace = lineOf(src.lines, /\{/) || 1;
    m.evidence.push(named ? ev(f, L(['name']), v.name) : ev(f, brace, '{'));
    for (const [sect, dev] of [['dependencies', false], ['devDependencies', true], ['peerDependencies', true], ['optionalDependencies', false]]) {
      if (!v[sect] || typeof v[sect] !== 'object') continue;
      for (const [dn, ver] of Object.entries(v[sect])) m.deps.push({ eco: 'npm', name: dn, version: cleanVersion(ver), dev, peer: sect === 'peerDependencies', ev: ev(f, L([sect, dn]), dn) });
    }
    for (const fw of ['next', 'react', 'vue', 'svelte', '@angular/core', 'express', 'fastify', '@nestjs/core', 'vite']) {
      const d = m.deps.find((x) => x.name === fw && x.version !== 'url'); if (d) m.tech.add(`${fw}@${d.version.replace(/^[\^~>=<\s]+/, '')}`);
    }
    if (v.bin) { m.entry = true; m.entryEv = ev(f, L(['bin']), 'bin'); }
    else if (v.scripts && (v.scripts.start || v.scripts.dev)) { const k = v.scripts.start ? 'start' : 'dev'; m.entry = true; m.entryEv = ev(f, L(['scripts', k]), k); }
    else if (v.workspaces) { m.entry = true; m.entryEv = ev(f, L(['workspaces']), 'workspaces'); }
    if (v.imports && typeof v.imports === 'object') m.aliases.push(...Object.keys(v.imports).map((k) => k.replace(/\*.*$/, '')));
    runnable(m);
    out.modules.push(m);
  }
  // tsconfig paths are aliases, not packages.
  for (const f of pj.manifests.filter((x) => /(^|\/)tsconfig[^/]*\.json$|(^|\/)jsconfig\.json$/.test(x))) {
    const src = pj.read(f); if (!src) continue;
    let doc; try { doc = parseJsonc(src.text); } catch (e) { out.notMeasured.push({ what: f, reason: `could not be read: ${e.message}` }); continue; }
    const paths = doc.value && doc.value.compilerOptions && doc.value.compilerOptions.paths;
    if (!paths) continue;
    const owner = out.modules.filter((m) => m.stack === 'node' && under(f, m.dir)).sort((a, b) => b.dir.length - a.dir.length)[0];
    for (const k of Object.keys(paths)) (owner ? owner.aliases : out.globalAliases).push(k.replace(/\*.*$/, ''));
  }
  const mods = out.modules.filter((m) => m.stack === 'node');
  own(out.modules, pj.files, 'node');
  const byName = new Map(mods.map((m) => [m.name, m]));
  const IMP = [/\bfrom\s+(['"])([^'"]+)\1/g, /^\s*import\s+(['"])([^'"]+)\1/g, /\brequire\(\s*(['"])([^'"]+)\1\s*\)/g, /\bimport\(\s*(['"])([^'"]+)\1\s*\)/g];
  for (const m of mods) {
    for (const d of m.deps) {
      const t = byName.get(d.name);
      if (t && t !== m) m.refs.push({ to: t.id, toMod: t, ev: d.ev, confidence: 'evidence' });
    }
    for (const f of m.files) {
      const src = pj.read(f); if (!src) continue;
      src.lines.forEach((l, i) => {
        if (isComment(l)) return;
        for (const re of IMP) {
          re.lastIndex = 0;
          for (const x of l.matchAll(re)) {
            const spec = x[2];
            if (spec.startsWith('.') || spec.startsWith('/')) {
              const target = P.normalize(P.join(dirOf(f), spec));
              const t = mods.filter((o) => under(target, o.dir)).sort((a, b) => b.dir.length - a.dir.length)[0];
              if (t && t !== m) m.refs.push({ to: t.id, toMod: t, ev: ev(f, i + 1, spec), confidence: 'evidence' });
              continue;
            }
            // Built at run time, or a bundler's virtual module (astro:content, virtual:x): not a package.
            if (spec.includes('${') || /^[a-z][a-z0-9+.-]*:/.test(spec)) continue;
            const root = spec.startsWith('@') ? spec.split('/').slice(0, 2).join('/') : spec.split('/')[0];
            if (!/^(@[a-z0-9._~-]+\/)?[a-z0-9._~-]+$/i.test(root)) continue;
            m.imports.push({ spec, root, ev: ev(f, i + 1, spec), file: f });
          }
        }
      });
    }
  }
}

// ---- Python ---------------------------------------------------------------------------------------------------
const PEP508 = /^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*(\[[^\]]*\])?\s*([^;#]*)/;
function pythonStack(pj, out) {
  const dirs = new Map();
  const get = (dir, manifest) => {
    if (!dirs.has(dir)) {
      const m = mod('python', dir === '.' ? 'root' : dir, manifest, dir);
      dirs.set(dir, m);
    }
    return dirs.get(dir);
  };
  for (const f of pj.manifests) {
    const b = P.basename(f);
    const src = /^(pyproject\.toml|setup\.cfg|requirements[^/]*\.txt)$/.test(b) ? pj.read(f) : null;
    if (!src) continue;
    const m = get(dirOf(f), f);
    if (b === 'pyproject.toml') {
      let rows; try { rows = parseToml(src.text); } catch (e) { out.notMeasured.push({ what: f, reason: `pyproject.toml could not be read: ${e.message}` }); continue; }
      m.manifest = f;
      for (const r of rows) {
        if (r.table === 'project' && r.key === 'name' && typeof r.value === 'string') { m.name = r.value; m.selfNames.push(r.value); m.evidence.push(ev(f, r.line, r.value)); }
        if (r.table === 'tool.poetry' && r.key === 'name' && typeof r.value === 'string') { m.name = r.value; m.selfNames.push(r.value); m.evidence.push(ev(f, r.line, r.value)); }
        if ((r.table === 'project' && r.key === 'dependencies') || (r.table === 'project.optional-dependencies')) {
          const list = Array.isArray(r.value) ? r.value : [];
          for (const s of list) {
            const p = PEP508.exec(String(s)); if (!p) continue;
            const line = lineOf(src.lines, new RegExp(`["']${esc(p[1])}`), r.line - 1) || r.line;
            m.deps.push({ eco: 'pypi', name: p[1], version: cleanVersion(p[3]), dev: r.table !== 'project', ev: ev(f, line, p[1]) });
          }
        }
        if (/^tool\.poetry\.(dev-)?dependencies$|^tool\.poetry\.group\.[^.]+\.dependencies$/.test(r.table) && r.key !== 'python') {
          const ver = typeof r.value === 'string' ? r.value : (r.value && r.value.version) || '';
          m.deps.push({ eco: 'pypi', name: r.key, version: String(ver), dev: r.table !== 'tool.poetry.dependencies', ev: ev(f, r.line, r.key) });
        }
        if ((r.table === 'project.scripts' || r.table === 'tool.poetry.scripts') && !m.entry) { m.entry = true; m.entryEv = ev(f, r.line, r.key); }
      }
    } else if (b === 'setup.cfg') {
      let inReq = false;
      src.lines.forEach((l, i) => {
        if (/^\s*install_requires\s*=/.test(l)) { inReq = true; return; }
        if (inReq) {
          if (/^\S/.test(l) || /^\s*\[/.test(l)) { inReq = false; return; }
          const p = PEP508.exec(l); if (p && l.trim()) m.deps.push({ eco: 'pypi', name: p[1], version: cleanVersion(p[3]), dev: false, ev: ev(f, i + 1, p[1]) });
        }
        const n = /^\s*name\s*=\s*(\S+)/.exec(l); if (n && !inReq) { m.name = n[1]; m.selfNames.push(n[1]); }
      });
    } else {
      const dev = /dev|test|lint/.test(b);
      src.lines.forEach((l, i) => {
        // An option line, or a requirement given by URL or path: no package name to read, and a URL is not copied.
        if (/^\s*(#|-|$)/.test(l) || /^\s*([a-z][a-z0-9+.-]*:\/\/|git\+|\.{0,2}\/)/i.test(l)) return;
        const p = PEP508.exec(l); if (p) m.deps.push({ eco: 'pypi', name: p[1], version: cleanVersion(p[3]), dev, ev: ev(f, i + 1, p[1]) });
      });
    }
    if (!m.evidence.length) { const e = evFirst(f, src.lines); if (e) m.evidence.push(e); }
  }
  // A manifest with nothing in it (an empty requirements.txt) declares no module.
  const mods = [...dirs.values()].filter((m) => m.evidence.length || m.deps.length);
  for (const m of mods) { m.id = `mod:python:${m.name}`; if (!m.evidence.length) m.evidence.push(m.deps[0].ev); runnable(m); } // the declared name, once the manifests are read
  out.modules.push(...mods);
  own(out.modules, pj.files, 'python');
  for (const m of mods) {
    // Local top-level names: a package directory or a module file anywhere in this module is not a dependency.
    const local = new Set();
    for (const f of m.files) {
      const rel = m.dir === '.' ? f : f.slice(m.dir.length + 1);
      const segs = rel.split('/');
      for (let k = 0; k < segs.length; k++) local.add(segs[k].replace(/\.py$/, ''));
    }
    m.localNames = local;
    for (const f of m.files) {
      const src = pj.read(f); if (!src) continue;
      src.lines.forEach((l, i) => {
        if (/^\s*__name__\s*==|if\s+__name__\s*==\s*['"]__main__['"]/.test(l) && !m.entry) { m.entry = true; m.entryEv = ev(f, i + 1, '__main__'); }
        const a = /^\s*import\s+([\w.]+(?:\s+as\s+\w+)?(?:\s*,\s*[\w.]+(?:\s+as\s+\w+)?)*)\s*$/.exec(l);
        if (a) for (const part of a[1].split(',')) { const spec = part.trim().split(/\s+/)[0]; m.imports.push({ spec, root: spec.split('.')[0], ev: ev(f, i + 1, spec), file: f }); }
        const b2 = /^\s*from\s+([\w][\w.]*)\s+import\b/.exec(l);
        if (b2) m.imports.push({ spec: b2[1], root: b2[1].split('.')[0], ev: ev(f, i + 1, b2[1]), file: f });
      });
      if (/(^|\/)(__main__|manage)\.py$/.test(f) && !m.entry) { m.entry = true; m.entryEv = evFirst(f, src.lines); m.entryFile = f; }
    }
  }
}

// ---- Go -------------------------------------------------------------------------------------------------------
function goStack(pj, out) {
  for (const f of pj.manifests.filter((x) => P.basename(x) === 'go.mod')) {
    const src = pj.read(f); if (!src) continue;
    let name = null; let inReq = false; const deps = [];
    src.lines.forEach((l, i) => {
      const mm = /^\s*module\s+(\S+)/.exec(l); if (mm) name = { v: mm[1], line: i + 1 };
      if (/^\s*require\s*\(\s*$/.test(l)) { inReq = true; return; }
      if (inReq && /^\s*\)\s*$/.test(l)) { inReq = false; return; }
      const r = inReq ? /^\s*(\S+)\s+(\S+)(\s*\/\/\s*indirect)?/.exec(l) : /^\s*require\s+(\S+)\s+(\S+)(\s*\/\/\s*indirect)?/.exec(l);
      if (r && !isComment(l)) deps.push({ eco: 'go', name: r[1], version: cleanVersion(r[2]), dev: !!r[3], indirect: !!r[3], ev: ev(f, i + 1, r[1]) });
    });
    if (!name) { out.notMeasured.push({ what: f, reason: 'go.mod has no module line' }); continue; }
    const m = mod('go', name.v, f, dirOf(f));
    m.evidence.push(ev(f, name.line, name.v)); m.deps = deps;
    const gv = lineOf(src.lines, /^\s*go\s+\d/); if (gv) m.tech.add(`go@${src.lines[gv - 1].trim().split(/\s+/)[1]}`);
    out.modules.push(m);
  }
  const mods = out.modules.filter((m) => m.stack === 'go');
  own(out.modules, pj.files, 'go');
  for (const m of mods) {
    for (const f of m.files) {
      const src = pj.read(f); if (!src) continue;
      let block = false;
      src.lines.forEach((l, i) => {
        if (/^\s*package\s+main\b/.test(l) && !m.entry) { m.entry = true; m.entryEv = ev(f, i + 1, 'package main'); }
        if (/^\s*import\s*\(\s*$/.test(l)) { block = true; return; }
        if (block && /^\s*\)/.test(l)) { block = false; return; }
        const x = block ? /^\s*(?:[\w.]+\s+)?"([^"]+)"/.exec(l) : /^\s*import\s+(?:[\w.]+\s+)?"([^"]+)"/.exec(l);
        if (!x) return;
        const spec = x[1];
        const t = mods.filter((o) => spec === o.name || spec.startsWith(o.name + '/')).sort((a, b) => b.name.length - a.name.length)[0];
        if (t) { if (t !== m) m.refs.push({ to: t.id, toMod: t, ev: ev(f, i + 1, spec), confidence: 'evidence' }); return; }
        if (!spec.split('/')[0].includes('.')) return; // the standard library: no dot in the first element
        m.imports.push({ spec, root: spec, ev: ev(f, i + 1, spec), file: f });
      });
    }
  }
}

// ---- .NET ---------------------------------------------------------------------------------------------------
function dotnetStack(pj, out) {
  const central = new Map();
  for (const f of pj.manifests.filter((x) => P.basename(x) === 'Directory.Packages.props')) {
    const src = pj.read(f); if (!src) continue;
    try { for (const p of xFind(parseXml(src.text), 'PackageVersion')) central.set(p.attrs.Include, p.attrs.Version || ''); }
    catch (e) { out.notMeasured.push({ what: f, reason: `could not be read: ${e.message}` }); }
  }
  for (const f of pj.manifests.filter((x) => /\.(cs|fs|vb)proj$/.test(x))) {
    const src = pj.read(f); if (!src) continue;
    let x; try { x = parseXml(src.text); } catch (e) { out.notMeasured.push({ what: f, reason: `project file could not be read: ${e.message}` }); continue; }
    const proj = xKid(x, 'Project'); if (!proj) { out.notMeasured.push({ what: f, reason: 'no <Project> element' }); continue; }
    const name = P.basename(f).replace(/\.\w+proj$/, '');
    const m = mod('dotnet', name, f, dirOf(f));
    m.evidence.push(ev(f, proj.line, 'Project'));
    const prop = (n) => { for (const pg of xKids(proj, 'PropertyGroup')) { const e = xKid(pg, n); if (e) return e; } return null; };
    const tf = prop('TargetFramework') || prop('TargetFrameworks'); if (tf) m.tech.add(xText(tf));
    const sdk = proj.attrs.Sdk || '';
    if (sdk) m.tech.add(sdk);
    for (const n of ['RootNamespace', 'AssemblyName']) { const e = prop(n); if (e && xText(e)) m.selfNames.push(xText(e)); }
    const ot = prop('OutputType'); const tp = prop('IsTestProject');
    if (/Sdk\.(Web|Worker|BlazorWebAssembly|Razor)/.test(sdk)) { m.entry = true; m.entryEv = ev(f, proj.line, sdk); }
    else if (ot && /exe/i.test(xText(ot))) { m.entry = true; m.entryEv = ev(f, ot.line, 'OutputType'); }
    else if (tp && /true/i.test(xText(tp))) { m.entry = true; m.entryEv = ev(f, tp.line, 'IsTestProject'); }
    for (const ig of xKids(proj, 'ItemGroup')) {
      for (const p of xKids(ig, 'PackageReference')) {
        const n = p.attrs.Include || p.attrs.Update; if (!n) continue;
        const v = p.attrs.Version || xText(xKid(p, 'Version')) || central.get(n) || '';
        const at = p.attrLines.Include || p.attrLines.Update || p.line;
        m.deps.push({ eco: 'nuget', name: n, version: cleanVersion(v), dev: false, central: !p.attrs.Version && !xKid(p, 'Version') && central.has(n), ev: ev(f, at, n) });
        if (/^(Microsoft\.NET\.Test\.Sdk|xunit|NUnit|MSTest\.TestFramework)$/.test(n) && !m.entry) { m.entry = true; m.entryEv = ev(f, at, n); }
      }
      for (const r of xKids(ig, 'ProjectReference')) {
        const inc = (r.attrs.Include || '').replace(/\\/g, '/');
        if (!inc) continue;
        m.refs.push({ to: P.normalize(P.join(dirOf(f), inc)), ev: ev(f, r.attrLines.Include || r.line, P.basename(inc)), confidence: 'evidence', byManifest: true });
      }
    }
    out.modules.push(m);
  }
  const mods = out.modules.filter((m) => m.stack === 'dotnet');
  // Windows and macOS resolve a reference whatever its case, so the build does too: an exact match first, then the
  // one manifest that matches without case.
  for (const m of mods) for (const r of m.refs) if (r.byManifest) {
    const ci = mods.filter((o) => o.manifest.toLowerCase() === r.to.toLowerCase());
    const t = mods.find((o) => o.manifest === r.to) || (ci.length === 1 ? ci[0] : null);
    r.to = t ? t.id : `missing:${r.to}`; r.toMod = t;
  }
  own(out.modules, pj.files, 'dotnet');
  // `using` a namespace another project owns: concluded from the name, so inferred, and only when no
  // ProjectReference already says it.
  const owners = mods.flatMap((o) => o.selfNames.map((n) => ({ n, o }))).sort((a, b) => b.n.length - a.n.length);
  for (const m of mods) {
    const seen = new Set(m.refs.map((r) => r.to));
    for (const f of m.files) {
      const src = pj.read(f); if (!src) continue;
      src.lines.forEach((l, i) => {
        const u = /^\s*(?:global\s+)?using\s+(?:static\s+)?([\w.]+)\s*;/.exec(l); if (!u) return;
        const hit = owners.find(({ n }) => u[1] === n || u[1].startsWith(n + '.'));
        if (hit && hit.o !== m && !seen.has(hit.o.id)) { seen.add(hit.o.id); m.refs.push({ to: hit.o.id, toMod: hit.o, ev: ev(f, i + 1, u[1]), confidence: 'inferred' }); }
      });
    }
  }
  if (mods.length) out.notMeasured.push({ what: '.NET package usage (dep-unused, dep-undeclared)', reason: 'a NuGet package name does not say which namespaces it provides, so imports cannot be matched to packages' });
}

// ---- Java / Kotlin: Maven and Gradle ------------------------------------------------------------------------
function javaStack(pj, out) {
  for (const f of pj.manifests.filter((x) => P.basename(x) === 'pom.xml')) {
    const src = pj.read(f); if (!src) continue;
    let x; try { x = parseXml(src.text); } catch (e) { out.notMeasured.push({ what: f, reason: `pom.xml could not be read: ${e.message}` }); continue; }
    const p = xKid(x, 'project'); if (!p) continue;
    const aid = xKid(p, 'artifactId'); if (!aid) { out.notMeasured.push({ what: f, reason: 'pom.xml has no artifactId' }); continue; }
    const gid = xText(xKid(p, 'groupId')) || xText(xKid(xKid(p, 'parent'), 'groupId'));
    const m = mod('java', xText(aid), f, dirOf(f));
    m.selfNames.push(`${gid}:${xText(aid)}`);
    m.evidence.push(ev(f, xLine(aid), xText(aid)));
    const pk = xText(xKid(p, 'packaging')); if (pk) m.tech.add(`maven:${pk}`);
    const deps = xKid(p, 'dependencies');
    for (const d of xKids(deps, 'dependency')) {
      const g = xText(xKid(d, 'groupId')); const a = xText(xKid(d, 'artifactId')); const v = xText(xKid(d, 'version'));
      if (!a) continue;
      const scope = xText(xKid(d, 'scope'));
      m.deps.push({ eco: 'maven', name: `${g}:${a}`, version: cleanVersion(v), dev: scope === 'test', ev: ev(f, xLine(xKid(d, 'artifactId')), a) });
    }
    for (const mm of xKids(xKid(p, 'modules'), 'module')) m.refs.push({ to: `aggregates:${P.normalize(P.join(dirOf(f), xText(mm)))}`, ev: ev(f, xLine(mm), xText(mm)), confidence: 'evidence', aggregate: true });
    for (const pl of xFind(p, 'artifactId')) if (xText(pl) === 'spring-boot-maven-plugin' && !m.entry) { m.entry = true; m.entryEv = ev(f, xLine(pl), 'spring-boot-maven-plugin'); }
    out.modules.push(m);
  }
  const settings = pj.manifests.filter((x) => /(^|\/)settings\.gradle(\.kts)?$/.test(x));
  for (const f of settings) {
    const src = pj.read(f); if (!src) continue;
    src.lines.forEach((l, i) => {
      if (isComment(l) || !/^\s*include\b/.test(l)) return;
      for (const q of l.matchAll(/["']:?([\w.:-]+)["']/g)) {
        const name = q[1]; const dir = P.normalize(P.join(dirOf(f), name.replace(/:/g, '/')));
        const build = [`${dir}/build.gradle.kts`, `${dir}/build.gradle`].find((b) => pj.files.includes(b)) || null;
        const m = mod('java', name, build || f, dir); m.gradle = true;
        m.evidence.push(ev(f, i + 1, name));
        out.modules.push(m);
      }
    });
  }
  // A root build file with no settings: one module.
  for (const f of pj.manifests.filter((x) => /(^|\/)build\.gradle(\.kts)?$/.test(x))) {
    if (out.modules.some((m) => m.stack === 'java' && m.manifest === f)) continue;
    if (out.modules.some((m) => m.stack === 'java' && m.gradle && m.dir === dirOf(f))) continue;
    const first = evFirst(f, (pj.read(f) || { lines: [] }).lines);
    if (!first) continue; // an empty build file declares nothing
    const m = mod('java', dirOf(f) === '.' ? 'root' : dirOf(f), f, dirOf(f)); m.gradle = true;
    m.evidence.push(first);
    out.modules.push(m);
  }
  let catalog = 0;
  const gmods = out.modules.filter((m) => m.stack === 'java' && m.gradle);
  for (const m of gmods) {
    if (!/build\.gradle/.test(m.manifest)) continue;
    const src = pj.read(m.manifest); if (!src) continue;
    m.tech.add(m.manifest.endsWith('.kts') ? 'gradle-kotlin-dsl' : 'gradle');
    src.lines.forEach((l, i) => {
      if (isComment(l)) return;
      const pr = /\bproject\(\s*(?:path\s*[:=]\s*)?["']:?([\w.:-]+)["']\s*\)/.exec(l);
      if (pr) { m.refs.push({ to: `gradle:${pr[1]}`, ev: ev(m.manifest, i + 1, pr[1]), confidence: 'inferred' }); return; }
      const dep = /\b(implementation|api|compileOnly|runtimeOnly|testImplementation|kapt|ksp)\s*\(?\s*["']([\w.-]+):([\w.-]+)(?::([^"']+))?["']/.exec(l);
      if (dep) { m.deps.push({ eco: 'maven', name: `${dep[2]}:${dep[3]}`, version: cleanVersion(dep[4] || ''), dev: /^test/.test(dep[1]), inferred: true, ev: ev(m.manifest, i + 1, dep[3]) }); return; }
      if (/\b(implementation|api|compileOnly|runtimeOnly|testImplementation)\s*\(?\s*libs\./.test(l)) catalog++;
      if (/org\.springframework\.boot/.test(l) && !m.entry) { m.entry = true; m.entryEv = ev(m.manifest, i + 1, 'org.springframework.boot'); }
    });
  }
  if (catalog) out.notMeasured.push({ what: `Gradle version catalog references (${catalog})`, reason: 'libs.* entries live in a catalog this scanner does not resolve, so those dependencies are not listed' });
  if (gmods.length) out.notMeasured.push({ what: 'Gradle build logic', reason: 'build.gradle(.kts) is code; dependencies and project references are read by pattern, so they are marked inferred' });
  const mods = out.modules.filter((m) => m.stack === 'java');
  for (const m of mods) {
    for (const r of m.refs) {
      if (r.to.startsWith('gradle:')) { const n = r.to.slice(7); const t = mods.find((o) => o.gradle && (o.name === n || o.name.endsWith(':' + n))); r.to = t ? t.id : `missing:${n}`; r.toMod = t; }
      if (r.to.startsWith('aggregates:')) { const d = r.to.slice(11); const t = mods.find((o) => o.dir === d); r.to = t ? t.id : `missing:${d}`; r.toMod = t; }
    }
    for (const d of m.deps) {
      // groupId:artifactId, both: an artifactId alone also names third-party artifacts (org.thirdparty:api).
      const t = mods.find((o) => o !== m && o.selfNames.includes(d.name));
      if (t) m.refs.push({ to: t.id, toMod: t, ev: d.ev, confidence: d.inferred ? 'inferred' : 'evidence' });
    }
  }
  own(out.modules, pj.files, 'java');
  for (const m of mods) {
    if (m.entry) continue;
    for (const f of m.files) {
      const src = pj.read(f); if (!src) continue;
      const i = src.lines.findIndex((l) => /static\s+void\s+main\s*\(|^\s*fun\s+main\s*\(|@SpringBootApplication/.test(l));
      if (i >= 0) { m.entry = true; m.entryEv = ev(f, i + 1, src.lines[i].includes('@SpringBootApplication') ? '@SpringBootApplication' : 'main'); break; }
    }
  }
  if (mods.length) out.notMeasured.push({ what: 'Java/Kotlin package usage (dep-unused, dep-undeclared)', reason: 'a Maven artifact does not say which packages it provides, so imports cannot be matched to artifacts' });
}

export function scanStacks(pj0) {
  // A manifest under a test, fixture or example directory describes a sample project, not a module of this one.
  // Its source files still belong to the module that holds them (a test imports that module's dependencies).
  const pj = { ...pj0, manifests: pj0.files.filter((f) => !isTestPath(f)) };
  const out = { modules: [], notMeasured: [], globalAliases: [] };
  for (const fn of [nodeStack, pythonStack, goStack, dotnetStack, javaStack]) {
    try { fn(pj, out); } catch (e) {
      if (!(e instanceof Unsupported)) throw e;
      out.notMeasured.push({ what: fn.name, reason: e.message });
    }
  }
  // Two manifests with one name (a copy, a fork in a subdirectory) would share an id: the directory tells them apart.
  const count = new Map();
  for (const m of out.modules) count.set(m.id, (count.get(m.id) || 0) + 1);
  for (const m of out.modules) if (count.get(m.id) > 1) m.id = `${m.id}@${m.dir}`;
  // A reference holds its target module, so it follows the rename; the object is dropped once resolved.
  for (const m of out.modules) for (const r of m.refs) { if (r.toMod) r.to = r.toMod.id; delete r.toMod; }
  return out;
}
