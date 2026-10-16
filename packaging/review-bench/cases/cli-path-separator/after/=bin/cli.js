#!/usr/bin/env node
'use strict';
// Runner for the Claude Starter Kit. The kit is a set of bash scripts (start.sh / adopt.sh)
// plus the claude-starter/ payload, all bundled in this npm package. This wrapper stages the
// payload in a temp dir and runs the requested script with the user's project as the CWD, so
// the script's self-cleanup only ever removes the temp copies — never the package or the CWD.

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const pkgDir = path.join(__dirname, '..');
const argv = process.argv.slice(2);
const sub = argv[0];

if (sub === '--help' || sub === '-h' || sub === 'help') {
  console.log(`Claude Starter Kit

Usage:
  npx @byerlikaya/claude-starter-kit [init] [--private|--shared] [--yes]
      Set up the kit in a fresh project (start.sh wizard). Every install ships the whole kit and
      is stack-agnostic: the stack is recorded per project in CLAUDE.md ## Stack.
      (--dotnet was removed in 3.0; it is still accepted, warns, and installs the same kit.)
  npx @byerlikaya/claude-starter-kit adopt
      Hand the kit over onto an existing project (adopt.sh).
  npx @byerlikaya/claude-starter-kit@latest update
      Refresh a project that already has the kit. Alias of 'adopt': it reads .claude/kit.conf,
      migrates a pre-3.0 .NET install (its pattern skill stays, as a project skill), and
      restores anything missing. Your CLAUDE.md is never touched.

  npx crewforth studio [--no-open] [--port <n>] [--selftest]
      Open the Studio panel on your own Claude Code sessions — nothing is installed. Needs Node 18+.
  npx crewforth add <name...> | add --list
      Copy one agent or skill (and the skills an agent uses) into ./.claude — not the full install.
      --list shows the catalogue; --force replaces a file that differs; --no-deps adds the agent alone.

  npx @byerlikaya/claude-starter-kit --version
      Print the kit version and exit.

Run any of them at the root of your target project.
On Windows, run inside Git Bash for the smoothest experience (WSL works as a fallback).`);
  process.exit(0);
}

// Answered here, before anything is staged. It used to fall through to start.sh, which cost a copy of the whole
// payload into a temp dir and then refused the flag as an unknown parameter.
if (sub === '--version' || sub === '-v') {
  let version = 'unknown';
  try { version = fs.readFileSync(path.join(pkgDir, 'VERSION'), 'utf8').split(/\r?\n/)[0].trim() || 'unknown'; } catch (_) { /* no VERSION shipped */ }
  console.log(version);
  process.exit(0);
}

// ================================ add ================================
// In this file, not a module beside it: the kit's own repo-bloat gate refuses any NEW file under bin/ (bin/ is build
// output in .NET and Java). Tracked files are exempt, which is how bin/cli.js itself passes.
// `add <name...>` — copy one agent or skill (and the skills an agent names) into a project, without the full
// install. Pure Node: no bash, no temp dir, nothing outside ./.claude is ever written.
//
// Paths are built from CATALOGUE names only. A name the user typed is looked up in the catalogue and never used as a
// path segment itself, so `..`, an absolute path or a separator cannot reach the file system.

// The one place the agent suffix is spelled. Phase 5 renames it; a user's `add security-expert` must not change.
const AGENT_SUFFIX = '-csk';
const NAME_RE = /^[a-z0-9][a-z0-9-]*$/;
const RECORD = 'crewforth-added.json';

function payloadDir(pkgDir) { return path.join(pkgDir, 'claude-starter'); }

function catalogue(pkgDir) {
  const root = payloadDir(pkgDir);
  const agents = fs.readdirSync(path.join(root, 'agents'))
    .filter((f) => f.endsWith('.md'))
    .map((f) => f.slice(0, -3))
    .sort();
  const skillsDir = path.join(root, 'skills');
  const skills = fs.readdirSync(skillsDir)
    .filter((d) => fs.statSync(path.join(skillsDir, d)).isDirectory() && fs.existsSync(path.join(skillsDir, d, 'SKILL.md')))
    .sort();
  return { root, agents, skills };
}

// Resolve what the user typed to a catalogue entry. Order: agent `<name><suffix>`, skill `<name>`, skill
// `<name><suffix>` (a few skills carry the suffix too). A typed suffix is accepted and stripped first.
function resolveName(cat, typed) {
  if (typeof typed !== 'string' || !NAME_RE.test(typed)) return null;
  const base = typed.endsWith(AGENT_SUFFIX) ? typed.slice(0, -AGENT_SUFFIX.length) : typed;
  if (cat.agents.includes(base + AGENT_SUFFIX)) return { type: 'agent', name: base + AGENT_SUFFIX };
  if (cat.skills.includes(base)) return { type: 'skill', name: base };
  if (cat.skills.includes(base + AGENT_SUFFIX)) return { type: 'skill', name: base + AGENT_SUFFIX };
  return null;
}

// THE dependency rule, and the only place it lives: every catalogue skill an agent's text names in backticks.
// Measured over the 12 agents when this was written: 1 to 11 skills (devops-expert 11, backend-expert 9); the list
// is always printed before anything is written, and --no-deps installs the agent alone.
function inferSkills(agentText, skillNames) {
  const known = new Set(skillNames);
  const out = [];
  for (const m of agentText.matchAll(/`([a-z0-9][a-z0-9-]*)`/g)) {
    if (known.has(m[1]) && !out.includes(m[1])) out.push(m[1]);
  }
  return out;
}

// Other agents an agent hands work to. Listed, never installed.
function pairedAgents(agentText, agentNames, self) {
  return agentNames.filter((a) => a !== self && new RegExp(`(^|[^a-z0-9-])${a}([^a-z0-9-]|$)`).test(agentText));
}

// Levenshtein, for "did you mean". Names are short; the quadratic cost is irrelevant.
function distance(a, b) {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 1; j <= b.length; j += 1) d[0][j] = j;
  for (let i = 1; i <= a.length; i += 1) {
    for (let j = 1; j <= b.length; j += 1) {
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
  }
  return d[a.length][b.length];
}
function suggest(cat, typed) {
  const shown = [...cat.agents.map((a) => a.slice(0, -AGENT_SUFFIX.length)), ...cat.skills];
  const t = String(typed).toLowerCase();
  return shown.map((n) => [n, distance(t, n)]).sort((x, y) => x[1] - y[1] || x[0].localeCompare(y[0])).slice(0, 3).map((x) => x[0]);
}

// First sentence of a frontmatter description (block scalar `|` or inline).
function firstSentence(file) {
  let text = '';
  try { text = fs.readFileSync(file, 'utf8'); } catch (_) { return ''; }
  const fm = text.replace(/^\uFEFF/, '').split(/^---[ \t]*\r?$/m)[1] || '';
  const lines = fm.split(/\r?\n/);
  const i = lines.findIndex((l) => /^description:/.test(l));
  if (i < 0) return '';
  let desc = lines[i].replace(/^description:\s*\|?\s*/, '');
  for (let k = i + 1; k < lines.length && /^\s+\S/.test(lines[k]); k += 1) desc += ` ${lines[k].trim()}`;
  desc = desc.replace(/\*\*/g, '').trim();
  const m = desc.match(/^(.+?[.!?])(\s|$)/);
  return (m ? m[1] : desc).trim();
}

// Every file under a source directory, as paths relative to it. Symlinks in the payload are refused, not followed.
function listFiles(dir, rel = '') {
  const out = [];
  for (const e of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
    const r = path.join(rel, e.name);
    if (e.isSymbolicLink()) throw new Error(`refusing a symlink in the payload: ${r}`);
    if (e.isDirectory()) out.push(...listFiles(dir, r));
    else if (e.isFile()) out.push(r);
  }
  return out;
}

// Refuse to write through a symlink anywhere between the project root and the target, and anywhere outside it.
function assertSafeTarget(projectRoot, target) {
  const rel = path.relative(projectRoot, target);
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) throw new Error(`refusing to write outside the project: ${target}`);
  let cur = projectRoot;
  for (const part of rel.split(path.sep)) {
    cur = path.join(cur, part);
    let st;
    try { st = fs.lstatSync(cur); } catch (_) { return; } // the rest does not exist yet
    if (st.isSymbolicLink()) throw new Error(`refusing to write through a symlink: ${path.relative(projectRoot, cur)}`);
  }
}

// Every existing component between the project root and a target's directory must BE a directory. Checked while
// planning, so a regular file in the way (`.claude/skills` as a file) stops the run before anything is written.
function assertDirsOrAbsent(projectRoot, dir) {
  let cur = projectRoot;
  for (const part of path.relative(projectRoot, dir).split(path.sep).filter(Boolean)) {
    cur = path.join(cur, part);
    let st;
    try { st = fs.statSync(cur); } catch (_) { return; }
    if (!st.isDirectory()) throw new Error(`${path.relative(projectRoot, cur)} exists and is not a directory`);
  }
}

function listCommand(pkgDir, log) {
  const cat = catalogue(pkgDir);
  log(`Agents (${cat.agents.length}) — npx crewforth add <name>`);
  for (const a of cat.agents) log(`  ${a.slice(0, -AGENT_SUFFIX.length).padEnd(22)} ${firstSentence(path.join(cat.root, 'agents', `${a}.md`))}`);
  log('');
  log(`Skills (${cat.skills.length})`);
  for (const s of cat.skills) log(`  ${s.padEnd(22)} ${firstSentence(path.join(cat.root, 'skills', s, 'SKILL.md'))}`);
  return 0;
}

function addCommand(pkgDir, args, opts = {}) {
  const log = opts.log || ((s) => process.stdout.write(`${s}\n`));
  const err = opts.err || ((s) => process.stderr.write(`${s}\n`));
  const projectRoot = path.resolve(opts.cwd || process.cwd());

  if (args.includes('--help') || args.includes('-h')) {
    log('Usage: npx crewforth add <name...> [--force] [--no-deps]   ·   npx crewforth add --list');
    log('  Copies an agent (and the skills it names) or a skill into ./.claude. Not the full install: no hooks, no gates.');
    log('  --force replaces a file that differs · --no-deps adds an agent without its skills · --list shows the catalogue');
    return 0;
  }
  if (args.includes('--list')) return listCommand(pkgDir, log);
  const force = args.includes('--force');
  const noDeps = args.includes('--no-deps');
  const names = args.filter((a) => !a.startsWith('-'));
  const unknownFlags = args.filter((a) => a.startsWith('-') && !['--force', '--no-deps', '--list'].includes(a));
  if (unknownFlags.length) { err(`add: unknown option ${unknownFlags.join(' ')}`); return 2; }
  if (!names.length) { err('add: name at least one agent or skill — see `npx crewforth add --list`'); return 2; }

  if (fs.existsSync(path.join(projectRoot, '.claude', 'kit.conf'))) {
    log('This project has the full install; use `npx crewforth update` instead. Nothing was written.');
    return 0;
  }

  const cat = catalogue(pkgDir);
  // All or nothing: every name must resolve before anything is planned.
  const resolved = []; const unknown = [];
  for (const n of names) { const r = resolveName(cat, n); if (r) resolved.push(r); else unknown.push(n); }
  if (unknown.length) {
    for (const u of unknown) err(`add: unknown agent or skill '${u}' — did you mean: ${suggest(cat, u).join(', ')}?`);
    err('Nothing was written.');
    return 2;
  }

  // Expand agents into their skills; keep a stable, de-duplicated order.
  const items = []; const pairs = new Set();
  const push = (it) => { if (!items.some((x) => x.type === it.type && x.name === it.name)) items.push(it); };
  for (const r of resolved) {
    push(r);
    if (r.type !== 'agent') continue;
    const text = fs.readFileSync(path.join(cat.root, 'agents', `${r.name}.md`), 'utf8');
    const deps = noDeps ? [] : inferSkills(text, cat.skills);
    if (deps.length) log(`${r.name.slice(0, -AGENT_SUFFIX.length)} uses ${deps.length} skill(s), adding them too: ${deps.join(', ')}`);
    for (const d of deps) push({ type: 'skill', name: d });
    for (const p of pairedAgents(text, cat.agents, r.name)) pairs.add(p);
  }
  for (const it of items) if (it.type === 'agent') pairs.delete(it.name);

  // Plan every file, then decide, then write — so a conflict leaves the tree exactly as it was.
  const plan = [];
  for (const it of items) {
    const files = it.type === 'agent'
      ? [{ src: path.join(cat.root, 'agents', `${it.name}.md`), dst: path.join(projectRoot, '.claude', 'agents', `${it.name}.md`) }]
      : listFiles(path.join(cat.root, 'skills', it.name)).map((r) => ({
        src: path.join(cat.root, 'skills', it.name, r), dst: path.join(projectRoot, '.claude', 'skills', it.name, r) }));
    for (const f of files) {
      assertSafeTarget(projectRoot, f.dst);
      assertDirsOrAbsent(projectRoot, path.dirname(f.dst));
      const body = fs.readFileSync(f.src);
      let state = 'new';
      if (fs.existsSync(f.dst)) state = Buffer.compare(fs.readFileSync(f.dst), body) === 0 ? 'same' : 'differs';
      plan.push({ ...f, body, state, item: it });
    }
  }
  const conflicts = plan.filter((p) => p.state === 'differs');
  if (conflicts.length && !force) {
    for (const c of conflicts) err(`add: ${path.relative(projectRoot, c.dst)} exists with different content — not overwritten (use --force to replace it)`);
    err('Nothing was written.');
    return 1;
  }

  // The record is computed BEFORE anything is written, from whatever is there now — so a malformed record
  // (`[]`, `null`, a string) is replaced by a well-formed one instead of failing after the files landed.
  const recFile = path.join(projectRoot, '.claude', RECORD);
  assertSafeTarget(projectRoot, recFile);
  let prev = null;
  try { prev = JSON.parse(fs.readFileSync(recFile, 'utf8')); } catch (_) { /* first add, or unreadable */ }
  const rec = { version: 'unknown', items: (prev && !Array.isArray(prev) && typeof prev === 'object' && Array.isArray(prev.items)) ? prev.items : [] };
  try { rec.version = fs.readFileSync(path.join(pkgDir, 'VERSION'), 'utf8').split(/\r?\n/)[0].trim() || 'unknown'; } catch (_) { /* keep 'unknown' */ }
  for (const it of items) {
    const files = plan.filter((p) => p.item === it).map((p) => path.relative(projectRoot, p.dst).split(path.sep).join('/'));
    rec.items = rec.items.filter((x) => !(x && x.type === it.type && x.name === it.name));
    rec.items.push({ type: it.type, name: it.name, files });
  }
  const recBody = `${JSON.stringify(rec, null, 2)}\n`;
  let recOld = null; try { recOld = fs.readFileSync(recFile, 'utf8'); } catch (_) { /* none */ }
  const writes = plan.filter((p) => p.state !== 'same');
  if (recOld !== recBody) writes.push({ dst: recFile, body: Buffer.from(recBody), record: true });

  // All or nothing, for real: a write that fails midway (permissions, a locked file on Windows) undoes the ones
  // before it — new files are removed, replaced files get their old bytes back — and the run says nothing changed.
  const done = []; const madeDirs = [];
  try {
    for (const w of writes) {
      const before = fs.existsSync(w.dst) ? fs.readFileSync(w.dst) : null;
      const made = fs.mkdirSync(path.dirname(w.dst), { recursive: true });   // the first directory it CREATED, if any
      if (made) madeDirs.push(made);
      fs.writeFileSync(w.dst, w.body);
      done.push({ dst: w.dst, before });
    }
  } catch (e) {
    for (const d of done.reverse()) {
      try { if (d.before === null) fs.unlinkSync(d.dst); else fs.writeFileSync(d.dst, d.before); } catch (_) { /* best effort */ }
    }
    // Directories this run created hold only files it has just removed — take them away too, deepest first.
    for (const m of madeDirs.reverse()) { try { fs.rmSync(m, { recursive: true, force: true }); } catch (_) { /* best effort */ } }
    err(`add: could not write (${e.code || e.message}) — the files written so far were rolled back. Nothing was changed.`);
    return 1;
  }
  const wrote = writes.filter((w) => !w.record).length; const same = plan.length - wrote;

  for (const it of items) log(`  ${it.type === 'agent' ? 'agent' : 'skill'}  ${it.name}`);
  log(wrote ? `${wrote} file(s) written${same ? `, ${same} already up to date` : ''}.` : `Already up to date — ${same} file(s) unchanged.`);
  if (pairs.size) log(`Works well with: ${[...pairs].sort().map((a) => a.slice(0, -AGENT_SUFFIX.length)).join(', ')} (not installed — add them the same way).`);
  log("Added the agent's instructions. The gates (hooks, commit checks) come with the full install: `npx crewforth init`.");
  return 0;
}
// ============================== /add ================================

// ---- studio and add: pure Node, handled BEFORE the bash probe below, so neither needs Git Bash on Windows. ----

// `studio`: run the panel straight from the package — no stage, no copy. It only READS its own directory (web/,
// hooks/); its state goes to ~/.claude/studio-runtime and os.tmpdir(), so a read-only npx cache is fine.
// IN THIS PROCESS, not as a child: with a child, anything that terminates this wrapper without a signal handler —
// every programmatic kill on Windows is TerminateProcess — would leave the panel running and holding its port.
// One process means Ctrl-C, SIGTERM and the panel's own cleanup (clearStateSync, stopping its sessions) are the
// panel's, with nothing in between. index.js starts main() only when argv[1] is its own path, so argv is set first.
if (sub === 'studio') {
  const major = Number(process.versions.node.split('.')[0]);
  if (major < 18) {
    console.error(`crewforth studio needs Node 18 or newer (this is ${process.version}).`);
    process.exit(1);
  }
  const rest = argv.slice(1);
  const noOpen = rest.includes('--no-open');
  const pass = rest.filter((a) => a !== '--no-open');
  // --open is the default; not added to an offline or informational run.
  if (!noOpen && !pass.some((a) => ['--open', '-o', '--selftest', '--help', '-h'].includes(a))) pass.push('--open');
  const entry = path.join(pkgDir, 'claude-starter', 'studio', 'server', 'index.js');
  process.argv = [process.argv[0], entry, ...pass];
  import(require('url').pathToFileURL(entry).href).catch((e) => {
    console.error(`crewforth studio: ${e && e.message ? e.message : e}`);
    process.exit(1);
  });
  return;
}

if (sub === 'add') {
  let code;
  try { code = addCommand(pkgDir, argv.slice(1)); } catch (e) { console.error(`crewforth add: ${e.message}`); code = 1; }
  process.exit(code);
}

const isAdopt = sub === 'adopt' || sub === 'update';
const isInit = sub === 'init';
const script = isAdopt ? 'adopt.sh' : 'start.sh';
const passArgs = (isAdopt || isInit) ? argv.slice(1) : argv;

// On Windows, prefer Git Bash (MINGW: shares the Win32 namespace, accepts C:/... natively) over WSL's
// System32 bash.exe (its drvfs / 8.3 / /mnt/c handling is the fragile path). Fall back to 'bash' on PATH.
function findBash() {
  if (process.platform !== 'win32') return 'bash';
  const roots = [
    process.env['ProgramFiles'],
    process.env['ProgramW6432'],
    process.env['ProgramFiles(x86)'],
    process.env['LOCALAPPDATA'] && path.join(process.env['LOCALAPPDATA'], 'Programs'),
  ].filter(Boolean);
  for (const r of roots) {
    for (const rel of ['Git\\bin\\bash.exe', 'Git\\usr\\bin\\bash.exe']) {
      const p = path.join(r, rel);
      try { if (fs.existsSync(p)) return p; } catch (_) { /* ignore */ }
    }
  }
  return 'bash'; // likely WSL; the runner below converts C:/... -> /mnt/c/... for that case
}
const BASH = findBash();

// bash is required (macOS / Linux have it; on Windows: Git Bash or WSL)
const probe = spawnSync(BASH, ['-c', 'exit 0']);
if (probe.error) {
  console.error('This kit needs bash — macOS/Linux have it; on Windows install Git Bash (git-scm.com) or use WSL.');
  process.exit(1);
}

// Expand 8.3 short names (e.g. C:\Users\LONGNA~1.DEV) to their real long form before staging — WSL's drvfs
// exposes only long names, so an unexpanded short path yields a "correct-looking" /mnt/c/... that still ENOENTs.
// No-op / safe on macOS & Linux.
const realpath = (p) => { try { return fs.realpathSync.native(p); } catch (_) { return p; } };

// Stage the bundled payload in a temp dir so the script's self-cleanup is harmless.
const stage = fs.mkdtempSync(path.join(realpath(os.tmpdir()), 'claude-starter-kit-'));
try {
  for (const item of [script, 'claude-starter', 'VERSION']) {
    const src = path.join(pkgDir, item);
    if (fs.existsSync(src)) fs.cpSync(src, path.join(stage, item), { recursive: true });
  }

  let res;
  if (process.platform !== 'win32') {
    // macOS / Linux: run the staged script directly. cwd = the user's project so it installs there;
    // $0 resolves to the stage so the payload (claude-starter/) is found next to it. No path munging —
    // a backslash is a legal Unix filename char, and rewriting it would corrupt real paths.
    res = spawnSync(BASH, [path.join(stage, script), ...passArgs], {
      stdio: 'inherit',
      cwd: process.cwd(),
    });
  } else {
    // Windows: forward-slash so bash's argv parsing doesn't eat '\'; then translate the Windows paths to
    // the running shell's convention INSIDE bash, dispatched deterministically by shell flavour:
    //   Git Bash / MSYS / Cygwin -> cygpath -u (C:/... also works as-is);  WSL -> wslpath -u -> /mnt/c/...
    const fwd = (p) => p.replace(/\\/g, '/');
    const stageFwd = fwd(realpath(stage));
    const projFwd = fwd(realpath(process.cwd()));
    const runner = [
      'conv(){',
      // The `return` used to fire whether or not the converter WORKED, so a cygpath/wslpath that resolves and
      // produces nothing yielded an empty path and the pass-through below — which the comment promises works —
      // was never reached. The user then got "bash cannot read the staged script at /adopt.sh" and went hunting
      // for 8.3 names and TEMP settings, for what was a path-converter failure.
      '  _o=""',
      '  case "$(uname -s)" in',
      '    MINGW*|MSYS*|CYGWIN*) command -v cygpath >/dev/null 2>&1 && _o="$(cygpath -u \"$1\" 2>/dev/null)" && [ -n "$_o" ] && { printf %s "$_o"; return; } ;;',
      '    *)                    command -v wslpath >/dev/null 2>&1 && _o="$(wslpath -u \"$1\" 2>/dev/null)" && [ -n "$_o" ] && { printf %s "$_o"; return; } ;;',
      '  esac',
      '  printf %s "$1"',
      '}',
      'S=$(conv "$1"); C=$(conv "$2"); shift 2',
      '[ -r "$S/' + script + '" ] || { echo "kit: bash cannot read the staged script at $S/' + script +
        ' — run inside Git Bash, or set TEMP to a long (non-8.3, ASCII) path." >&2; exit 127; }',
      'cd "$C" || { echo "kit: cannot enter the project directory $C" >&2; exit 1; }',
      'exec bash "$S/' + script + '" "$@"',
    ].join('\n');
    res = spawnSync(BASH, ['-c', runner, 'kit', stageFwd, projFwd, ...passArgs], {
      stdio: 'inherit',
    });
  }

  process.exitCode = res.status == null ? 1 : res.status;
} finally {
  try { fs.rmSync(stage, { recursive: true, force: true }); } catch (_) { /* best effort */ }
}
