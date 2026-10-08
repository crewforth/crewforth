#!/usr/bin/env node
// Studio's offline gate. No network, no CLI, no tokens spent — so it can be
// wired into CI and run on every change.
//
// Everything here is hermetic: fixtures and temp directories only, never this
// checkout's own state. An assertion that reads the author's machine is a gate
// that is green for one person and red for everyone else.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { _internals } from '../../kit/studio/server/lib/fleet.js';
import { contextFill } from '../../kit/studio/server/lib/transcript.js';
import { encodeCwd } from '../../kit/studio/server/lib/projects.js';
import { _internals as graphInternals } from '../../kit/studio/server/lib/graph.js';
import { palette, _internals as paletteInternals } from '../../kit/studio/server/lib/palette.js';
import { renderMarkdown } from '../../kit/studio/web/md.js';
import { ALLOWED_MODES } from '../../kit/studio/server/lib/session.js';
import { parsePeers } from '../../kit/studio/server/lib/peers.js';
import { writeAllowed, signature } from '../../kit/studio/server/index.js';
import { prepare, decide, pending, cleanup, revoke, alwaysList, _internals as permInternals } from '../../kit/studio/server/lib/permissions.js';
import { execFileSync, spawnSync } from 'node:child_process';
import os from 'node:os';
import { quickReplies } from '../../kit/studio/web/chat.js';
import { installDom } from './dom-stub.mjs';
import { plan as terminalPlan } from '../../kit/studio/server/lib/terminal.js';
import { gateLog, gateReport, board, sessionStats, _internals as kitInternals } from '../../kit/studio/server/lib/kit-telemetry.js';
import { parseRoster, remoteRoster } from '../../kit/studio/server/lib/roster.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
// The suite lives beside the other gates rather than inside the panel, because
// kit/ is shipped whole: a test directory under it would travel to
// every user through all three channels only to be deleted by the installer.
// 104 KB of it, measured. So the panel is named from the repo root, not walked
// up to from here.
const REPO = path.resolve(HERE, '..', '..');
const PAYLOAD = path.join(REPO, 'kit');
const STUDIO = path.join(PAYLOAD, 'studio');
const WEB_ROOT = path.join(STUDIO, 'web');

let pass = 0;
let fail = 0;
let skipped = 0;
let na = 0;
const failures = [];

function check(name, ok, detail) {
  if (ok) {
    pass += 1;
  } else {
    fail += 1;
    failures.push(`${name}${detail ? ` — ${detail}` : ''}`);
  }
  process.stdout.write(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` — ${detail}` : ''}\n`);
}

/**
 * A check that could not run, said out loud.
 *
 * `tool` means the machine is missing something the check needs. Under
 * CREW_VERIFY_STRICT — which CI sets — that is a broken runner, not an honest
 * boundary, so it goes red. Every other class stays a skip.
 */
/**
 * An assertion that does not apply on this platform, and is measured on another.
 *
 * Distinct from skip() on purpose. `tool` skips mean "this could have been
 * measured and was not", so CREW_VERIFY_STRICT turns them red — a runner missing
 * a tool is a broken runner. A capability the platform does not have is a
 * different statement: it stays green here because it is red-or-green somewhere
 * else, and saying so is the only way the strict rule keeps its meaning.
 *
 * Use it only where another assertion covers the same ground on the platform
 * that has the feature. Never as a way to make a failing check quiet.
 */
function notApplicable(name, why, coveredBy) {
  na += 1;
  process.stdout.write(`N/A  ${name} — ${why}; covered by: ${coveredBy}\n`);
}

function skip(name, kind, why) {
  const strict = process.env.CREW_VERIFY_STRICT === '1' && kind === 'tool';
  if (strict) {
    fail += 1;
    failures.push(`${name} — required ${kind} missing: ${why}`);
  } else {
    skipped += 1;
  }
  process.stdout.write(`${strict ? 'FAIL' : 'SKIP'} ${name} — ${kind}: ${why}\n`);
}

function read(p) {
  try { return fs.readFileSync(p, 'utf8'); } catch { return null; }
}

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === 'node_modules' || e.name === '.git' || e.name === 'recordings') continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

/* ---------------------------------------------------------------- §1 pins
   Five assertions that keep Studio on its side of the fence. Each one is a
   boundary that, once crossed, is expensive to walk back. */

process.stdout.write('\n== §1 boundary pins ==\n');

const rootPkg = JSON.parse(read(path.join(REPO, 'package.json')) ?? '{}');

// Inverted, not deleted. The old pin held the panel OUT of every channel; a
// real project then updated, ran the documented command and got ENOENT, because
// nothing had ever installed it. The claim now runs the other way and has to
// fail the moment the panel stops shipping: `kit/` is the one string
// every channel already carries (npm files[], make-release.sh's whitelist,
// bin/cli.js's staging list, the Homebrew formula), so living under it is what
// makes "installed" true rather than a fourth place to remember.
const shipsPayload = Array.isArray(rootPkg.files) && rootPkg.files.some((f) => String(f).replace(/\/$/, '') === 'kit');
const insidePayload = path.basename(PAYLOAD) === 'kit';
const carried = ['server/index.js', 'web/index.html', 'package.json', 'ensure-node.sh']
  .filter((f) => fs.existsSync(path.join(STUDIO, f)));
check(
  'pin: studio ships inside the payload every channel installs',
  shipsPayload && insidePayload && carried.length === 4,
  `payload dir = ${path.basename(PAYLOAD)}, files[] = ${JSON.stringify(rootPkg.files)}, carried = ${carried.join(' ')}`,
);

// Silently load-bearing: every server file is ESM. Without this manifest beside
// them node reads them as CommonJS and the panel installs cleanly, then dies on
// its first import — a failure the user meets, not the build.
const typeField = JSON.parse(read(path.join(STUDIO, 'package.json')) ?? '{}').type;
check(
  'pin: the installed tree declares "type": "module"',
  typeField === 'module',
  `type = ${JSON.stringify(typeField)}`,
);

const rootDeps = Object.keys(rootPkg.dependencies ?? {}).length;
const rootDevDeps = Object.keys(rootPkg.devDependencies ?? {}).length;
check(
  'pin: the root package still carries zero dependencies',
  rootDeps === 0 && rootDevDeps === 0,
  `${rootDeps} deps, ${rootDevDeps} devDeps`,
);

const studioPkg = JSON.parse(read(path.join(STUDIO, 'package.json')) ?? '{}');
const sDeps = Object.keys(studioPkg.dependencies ?? {}).length;
check(
  'pin: studio itself carries zero dependencies',
  sDeps === 0 && !fs.existsSync(path.join(STUDIO, 'node_modules')),
  `${sDeps} deps, node_modules ${fs.existsSync(path.join(STUDIO, 'node_modules')) ? 'PRESENT' : 'absent'}`,
);

const studioFiles = walk(STUDIO).filter((f) => /\.(js|mjs|sh|py|html|css|json|md)$/.test(f));
const bypassHits = studioFiles.filter((f) => {
  const src = read(f) ?? '';
  return /bypassPermissions|dangerously-skip-permissions/.test(src);
});
check(
  'pin: studio never names a permission bypass',
  bypassHits.length === 0,
  bypassHits.length ? bypassHits.map((f) => path.relative(REPO, f)).join(', ') : `${studioFiles.length} files scanned`,
);

const serverSrc = read(path.join(STUDIO, 'server', 'index.js')) ?? '';
check(
  'pin: the server binds loopback and nothing else',
  serverSrc.includes("const LOOPBACK = '127.0.0.1'") &&
    !/0\.0\.0\.0|::\s*'|listen\([^)]*,\s*['"]0/.test(serverSrc),
  null,
);

/* ------------------------------------------------------- §2 static guard
   Proved directly, because a live HTTP probe cannot reach this branch: the
   URL parser collapses "/../" before the handler sees it. A gate that only
   ever passes through a second gate has not been measured. */

process.stdout.write('\n== §2 static path guard ==\n');

function guard(urlPath) {
  const rel = urlPath === '/' ? '/index.html' : urlPath;
  const abs = path.resolve(WEB_ROOT, `.${rel}`);
  return abs === WEB_ROOT || abs.startsWith(WEB_ROOT + path.sep);
}

for (const [p, want] of [
  ['/', true],
  ['/index.html', true],
  ['/app.js', true],
  ['/style.css', true],
  ['/../package.json', false],
  ['/../../VERSION', false],
  ['/../../../etc/passwd', false],
  ['/a/b/../../../../secrets', false],
]) {
  check(`guard ${want ? 'allows' : 'blocks'} ${p}`, guard(p) === want, null);
}

/* ------------------------------------------------- §3 fleet normalisation
   "Not measured" and "nothing running" must never collapse into each other,
   and an unknown field must survive rather than be dropped. */

process.stdout.write('\n== §3 fleet normalisation ==\n');

const { normalise } = _internals;

const real = normalise({
  pid: 71288, cwd: '/tmp/x', kind: 'interactive',
  startedAt: 1787667229756, sessionId: 'abc-123', name: 'mac-session', status: 'busy',
});
check('normalise keeps the identifying fields', real?.sessionId === 'abc-123' && real.name === 'mac-session' && real.status === 'busy');
check('normalise surfaces waitingFor when present',
  normalise({ sessionId: 'w', status: 'waiting', waitingFor: 'input needed' })?.waitingFor === 'input needed');
check('normalise keeps waitingFor null when absent', real?.waitingFor === null);
check('normalise drops rows with no session id', normalise({ pid: 1 }) === null);
check('normalise survives junk', normalise(null) === null && normalise('x') === null && normalise(42) === null);
check('normalise labels an unknown status rather than guessing',
  normalise({ sessionId: 'u', status: 'teleporting' })?.status === 'teleporting');
check('normalise defaults a missing status to "unknown"',
  normalise({ sessionId: 'u' })?.status === 'unknown');
check('normalise carries unknown fields through untouched',
  normalise({ sessionId: 'u', futureField: 7 })?.raw?.futureField === 7);

/* ------------------------------------------------------ §4 honest states
   The UI must have a distinct rendering for "nothing was read". Pin the
   strings, because this is the one lie the panel exists to prevent. */

process.stdout.write('\n== §4 honest empty states ==\n');

const appSrc = read(path.join(WEB_ROOT, 'app.js')) ?? '';
check('ui: renders a distinct "Not measured" state', /Not measured/.test(appSrc));
check('ui: says outright that unmeasured is not the same as empty',
  /not the same as "nothing is running"/i.test(appSrc));
check('ui: has a separate state for a measured but empty fleet',
  /No sessions running/.test(appSrc));
check('ui: reports the reason a read failed', /data\.reason/.test(appSrc));

/* ------------------------------------------------------- §5 the poison
   The kit paid for this lesson once: a 92%-full context reported as 0.9%.
   When a subagent returns, its tool_result lands in the MAIN transcript as a
   `type:"user"` record carrying `toolUseResult.usage`. That is the subagent's
   spend, not the session's. Same fixture as smoke-test.sh:980. */

process.stdout.write('\n== §5 context fill, the poisoned record ==\n');

const A_REC = { type: 'assistant', isSidechain: false, message: { usage: { input_tokens: 1000, cache_creation_input_tokens: 0, cache_read_input_tokens: 800000, output_tokens: 5 } } };
const SIDE_REC = { type: 'assistant', isSidechain: true, message: { usage: { input_tokens: 5, cache_creation_input_tokens: 0, cache_read_input_tokens: 30000, output_tokens: 1 } } };
const POISON_REC = { type: 'user', isSidechain: false, message: { role: 'user', content: 'x' }, toolUseResult: { usage: { input_tokens: 25, cache_creation_input_tokens: 1344, cache_read_input_tokens: 8000, output_tokens: 9 } } };

const fill = contextFill([A_REC, SIDE_REC, POISON_REC]);
check("a returning subagent's toolUseResult.usage is NOT the session's fill", fill === 801000, `expected 801000, measured ${fill}`);
check('a sidechain record does not count toward the session', fill !== 831005);
check('an empty transcript yields null, not zero', contextFill([]) === null);

/* -------------------------------------------------- §6 transcript paths */

process.stdout.write('\n== §6 transcript path encoding ==\n');

check('cwd folds : \\ / . _ down to -',
  encodeCwd('/Users/x/Projects/my.app_v2') === '-Users-x-Projects-my-app-v2',
  encodeCwd('/Users/x/Projects/my.app_v2'));
// C: contributes two dashes (the colon and the following separator); each
// remaining backslash contributes one. Verified against the encoder, not guessed.
check('a windows path folds too',
  encodeCwd('C:\\Users\\x\\proj') === 'C--Users-x-proj',
  encodeCwd('C:\\Users\\x\\proj'));

/* --------------------------------------------- §7 completion harvesting */

process.stdout.write('\n== §7 completion notices ==\n');

const seen = new Map();
graphInternals.harvestCompletions(
  '<task-notification><task-id>abc123</task-id><status>completed</status></task-notification>', seen);
check('a completion notice is read out of prose', seen.get('abc123') === 'completed');

const multi = new Map();
graphInternals.harvestCompletions(
  '<task-id>one</task-id><status>completed</status> ... <task-id>two</task-id><status>failed</status>', multi);
check('two notices in one blob are both read', multi.get('one') === 'completed' && multi.get('two') === 'failed');
check('a status other than completed is carried, not normalised', multi.get('two') === 'failed');

const none = new Map();
graphInternals.harvestCompletions('no notice here', none);
check('prose without a notice yields nothing', none.size === 0);

/* --------------------------------------------------------- §8 palette */

process.stdout.write('\n== §8 palette ==\n');

const pal = palette();
// Counted off disk in this same run rather than pinned to a constant: an agent
// added to the payload must not turn this red, and a resolver that finds the
// wrong directory must not stay green because it happened to find twelve of
// something. `>= 12` would have passed on a partial read.
const agentsOnDisk = fs.readdirSync(path.join(PAYLOAD, 'agents')).filter((f) => f.endsWith('.md')).length;
check('every kit agent in the payload is in the palette',
  pal.measured === true && pal.kitAgents === agentsOnDisk,
  `${pal.kitAgents} in the palette, ${agentsOnDisk} .md files in ${path.relative(REPO, path.join(PAYLOAD, 'agents'))}`);
check('a declared colour resolves to a hex value', /^#[0-9a-f]{6}$/i.test(pal.map['crew-security-expert']?.hex ?? ''));
check('an undeclared agent type falls back to neutral, never a borrowed colour',
  !pal.map['no-such-agent-type'] && /^#[0-9a-f]{6}$/i.test(pal.unknown));

// The resolver against synthetic trees, because the claim is "one rule, every
// layout" and this checkout can only ever demonstrate one of them. Install and
// repo differ in depth and in the parent's name; the rule may read neither.
const palHome = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-studio-palette-'));
try {
  const shapes = {
    install: path.join(palHome, 'install', '.claude'),
    repo: path.join(palHome, 'repo', 'kit'),
    // The third layout, and the one the comment above claimed in prose while nothing measured it: a
    // plugin root has no `.claude` or `kit` segment at all — agents/ and studio/ sit
    // directly in it. Now that the plugin edition ships the panel, this is a real deployment.
    plugin: path.join(palHome, 'plugin', 'crewforth'),
  };
  for (const base of Object.values(shapes)) {
    fs.mkdirSync(path.join(base, 'agents'), { recursive: true });
    fs.mkdirSync(path.join(base, 'studio', 'server', 'lib'), { recursive: true });
  }
  for (const [name, base] of Object.entries(shapes)) {
    const got = paletteInternals.agentsDirFor(path.join(base, 'studio', 'server', 'lib'));
    check(`palette resolves the agents dir in the ${name} layout`,
      got === path.join(base, 'agents'), `got ${got}`);
  }
  const orphan = path.join(palHome, 'orphan', 'studio', 'server', 'lib');
  fs.mkdirSync(orphan, { recursive: true });
  check('palette returns null where no agents dir sits beside the panel',
    paletteInternals.agentsDirFor(orphan) === null,
    `got ${paletteInternals.agentsDirFor(orphan)}`);
} finally {
  fs.rmSync(palHome, { recursive: true, force: true });
}
// …and the unresolved case must be reported, not drawn. `palette()` caches, so
// the shape is asserted on the module's own contract: measured false carries a
// reason, and the UI reads that flag rather than an empty map.
check('an unresolved palette is reported as not measured, with the directory it looked in',
  pal.measured === true ? typeof pal.agentsDir === 'string' && pal.reason === null
    : pal.reason?.includes(pal.agentsDir) === true,
  `measured=${pal.measured} dir=${pal.agentsDir}`);
check('ui: an unresolved palette is labelled, not drawn as neutral rings',
  /p\.measured === false/.test(read(path.join(WEB_ROOT, 'app.js')) ?? ''));

/* ---------------------------------------------- §9 report rendering ---
   Agent reports are untrusted text: an agent can quote anything it read from
   the repo, including markup. Only known constructs are re-introduced after
   escaping, so nothing in a report can become an element. */

process.stdout.write('\n== §9 markdown is escaped before it is rendered ==\n');

const ALLOWED = /^(\/?)(p|h[1-6]|ul|ol|li|code|pre|strong|em|hr|blockquote|div|table|thead|tbody|tr|th|td|span)\b/;
const attacks = [
  '<script>alert(1)</script>',
  '**bold** <img src=x onerror=alert(1)>',
  '> quote with <svg onload=alert(1)>',
  '`<iframe src=evil>`',
  '| a | <b>x</b> |\n|---|---|\n| y | z |',
];
for (const a of attacks) {
  const tags = [...renderMarkdown(a).matchAll(/<([^>]*)>/g)].map((m) => m[1]);
  const bad = tags.filter((t) => !ALLOWED.test(t));
  check(`report text cannot inject markup: ${JSON.stringify(a.slice(0, 30))}`, bad.length === 0, bad.join(', ') || null);
}
check('a link never becomes an href', !/href/i.test(renderMarkdown('[x](javascript:alert(1))')));
check('headings and tables still render', /<h\d/.test(renderMarkdown('## h')) && /<table/.test(renderMarkdown('| a |\n|---|\n| 1 |')));

/* ------------------------------------------- §10 the write surface ---
   The panel can now start a session and send it messages, which makes it
   worth attacking. These pin the shape of that surface. */

process.stdout.write('\n== §10 owned sessions ==\n');

check('permission modes are an allow-list, not a deny-list',
  Array.isArray(ALLOWED_MODES) && ALLOWED_MODES.length > 0 && ALLOWED_MODES.every((m) => typeof m === 'string'),
  ALLOWED_MODES.join(', '));
check('the default mode is the least permissive one offered',
  ALLOWED_MODES[0] === 'plan',
  `first is ${ALLOWED_MODES[0]}`);

const idxSrc = read(path.join(STUDIO, 'server', 'index.js')) ?? '';
// Exercised, not grepped. An earlier version of this pin only looked for the
// header's name in the source, and survived the check being replaced with
// `if (false)` — a gate that cannot fail is not a gate.
const req = (headers) => ({ headers });
check('a request without the header is refused',
  writeAllowed(req({})).ok === false);
check('a request with the wrong header value is refused',
  writeAllowed(req({ 'x-crew-studio': '0' })).ok === false);
check('a same-origin request with the header is allowed',
  writeAllowed(req({ 'x-crew-studio': '1', origin: 'http://127.0.0.1:7777' })).ok === true);
check('localhost counts as same-origin',
  writeAllowed(req({ 'x-crew-studio': '1', origin: 'http://localhost:7777' })).ok === true);
check('a cross-origin request is refused even with the header',
  writeAllowed(req({ 'x-crew-studio': '1', origin: 'https://evil.example' })).ok === false);
check('an unparseable Origin is refused rather than ignored',
  writeAllowed(req({ 'x-crew-studio': '1', origin: 'not a url' })).ok === false);
check('a request with no Origin at all still needs the header',
  writeAllowed(req({ 'x-crew-studio': '1' })).ok === true &&
  writeAllowed(req({ origin: 'http://127.0.0.1:7777' })).ok === false);
check('a token always exists, generated when none was supplied',
  /CREW_STUDIO_TOKEN \|\| randomUUID\(\)/.test(idxSrc));
check('the token gate covers every /api/ path',
  /url\.pathname\.startsWith\('\/api\/'\) && !authorised/.test(idxSrc));

const sessSrc = read(path.join(STUDIO, 'server', 'lib', 'session.js')) ?? '';
check('owned sessions are spawned with an id we chose, so the transcript lands where the graph reads it',
  /'--session-id', this\.id/.test(sessSrc));
check('children are stopped when the server is', /stopAll/.test(idxSrc) && /export function stopAll/.test(sessSrc));

/* ------------------------------------------------------- §11 peers ---
   A peer is another machine. Reaching one must never widen this one. */

process.stdout.write('\n== §11 peers ==\n');

const [p1] = parsePeers(['http://127.0.0.1:7778']);
check('a bare peer URL parses', p1.base === 'http://127.0.0.1:7778' && !p1.token);
const [p2] = parsePeers(['http://:tok@127.0.0.1:7780']);
check('a peer token is taken off the URL, not left in it', p2.token === 'tok' && !p2.base.includes('tok'));
const [p3] = parsePeers([']]not a url']);
check('an unparseable peer is reported, not silently dropped', p3.error === 'not a URL');
check('the server binds loopback whatever the peer list says',
  /server\.listen\(args\.port, LOOPBACK/.test(idxSrc));

/* ------------------------------------------- §12 the permission gate ---
   Measured on this machine: a PreToolUse hook killed at its configured timeout
   emits nothing and the tool PROCEEDS — permission_denials came back 0 and the
   command ran. So the hook must decide for itself first, and these pin the
   invariant that makes that true. */

process.stdout.write('\n== §12 permission bridge ==\n');

const { HOOK, HOOK_WAIT_S, HARNESS_TIMEOUT_S } = permInternals;

check('the hook exists and is executable', (() => {
  try { fs.accessSync(HOOK, fs.constants.X_OK); return true; } catch { return false; }
})(), HOOK);

check('the hook answers well before the harness would kill it',
  HOOK_WAIT_S < HARNESS_TIMEOUT_S,
  `hook ${HOOK_WAIT_S}s vs harness ${HARNESS_TIMEOUT_S}s`);

const probeId = `selfcheck-${process.pid}`;
const gate = prepare(probeId);
check('prepare writes a settings file', Boolean(gate) && fs.existsSync(gate.settingsPath));

if (gate) {
  const cfg = JSON.parse(fs.readFileSync(gate.settingsPath, 'utf8'));
  const entry = cfg.hooks?.PreToolUse?.[0];
  check('the gate covers every tool, not a chosen few', entry?.matcher === '*', `matcher ${entry?.matcher}`);
  check('the settings file is ours, not the user\'s',
    gate.settingsPath.startsWith(os.tmpdir()), gate.settingsPath);
  check('the configured timeout leaves the hook room to answer',
    entry?.hooks?.[0]?.timeout > HOOK_WAIT_S);
  // Left to the default, Claude Code runs the hook through PowerShell on Windows when it does not detect Git Bash; the
  // VAR=… prefix is not PowerShell and the gate fails open.
  check('the gate names its shell (bash), so PowerShell never runs it',
    entry?.hooks?.[0]?.shell === 'bash', `shell ${entry?.hooks?.[0]?.shell}`);

  // Behaviour, not text. Each case runs the real hook.
  const payload = JSON.stringify({
    session_id: probeId, tool_name: 'Bash', tool_use_id: 'toolu_probe',
    tool_input: { command: 'echo probe' },
  });
  const runHook = (env = {}) => {
    try {
      execFileSync('bash', [HOOK, gate.spool], {
        input: payload,
        env: { ...process.env, CREW_GATE_WAIT: '1', ...env },
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      return 0;
    } catch (e) {
      return e.status ?? -1;
    }
  };

  check('silence is a denial, not an opening', runHook() === 2);

  fs.writeFileSync(path.join(gate.spool, 'ans', 'toolu_probe'), 'deny\n');
  check('a deny blocks', runHook() === 2);

  fs.writeFileSync(path.join(gate.spool, 'ans', 'toolu_probe'), 'allow\n');
  check('an allow lets the tool through', runHook() === 0);

  // The discriminating control: without the answer file the same call is
  // refused, so the allow above measured the answer rather than the harness.
  check('the allow was the answer, not the absence of a gate', runHook() === 2);

  fs.writeFileSync(path.join(gate.spool, 'always', 'Bash'), '');
  check('an always-allowed tool skips the round trip', runHook() === 0);
  fs.rmSync(path.join(gate.spool, 'always', 'Bash'));

  check('a request is visible to the panel while the hook waits', (() => {
    fs.writeFileSync(path.join(gate.spool, 'req', 'toolu_seen.json'), payload);
    const seen = pending(probeId).find((r) => r.toolUseId === 'toolu_seen');
    // The command itself, not just the tool's name: nobody can approve what
    // they cannot read.
    return seen?.toolName === 'Bash' && seen?.detail === 'echo probe';
  })());

  check('an unknown verdict is refused', decide(probeId, 'toolu_probe', 'maybe').ok === false);
  check('a tool use id that is not an identifier is refused',
    decide(probeId, '../escape', 'allow').ok === false);

  // What an allowance says to Claude Code. Exit 0 with nothing on stdout is "no decision": the harness then
  // runs its own permission flow, and a headless session has nobody to ask. Measured in real sessions: Edit,
  // Write and a writing Bash were refused after being allowed in the dock. So outside plan mode the hook says
  // "allow" in the documented JSON — and in plan mode, or with no mode, it must say nothing at all.
  const runHookOut = (env = {}, extra = {}) => {
    const input = JSON.stringify({ ...JSON.parse(payload), ...extra });
    try {
      const out = execFileSync('bash', [HOOK, gate.spool], {
        input, env: { ...process.env, CREW_GATE_WAIT: '1', ...env }, stdio: ['pipe', 'pipe', 'pipe'],
      });
      return { status: 0, stdout: String(out).trim() };
    } catch (e) {
      return { status: e.status ?? -1, stdout: String(e.stdout ?? '').trim() };
    }
  };
  const answered = (verdict, env, extra) => {
    fs.writeFileSync(path.join(gate.spool, 'ans', 'toolu_probe'), `${verdict}\n`);
    return runHookOut(env, extra);
  };
  const decisionOf = (r) => { try { return JSON.parse(r.stdout).hookSpecificOutput ?? null; } catch { return null; } };
  for (const mode of ['default', 'acceptEdits']) {
    const r = answered('allow', { CREW_GATE_MODE: mode });
    const d = decisionOf(r);
    check(`in ${mode} mode an allowance is an approval the harness can read`,
      r.status === 0 && d?.hookEventName === 'PreToolUse' && d?.permissionDecision === 'allow'
      && r.stdout.startsWith('{') && r.stdout.endsWith('}'),
      r.stdout.slice(0, 120) || 'nothing on stdout');
  }
  const inPlan = answered('allow', { CREW_GATE_MODE: 'plan' });
  check('in plan mode an allowance approves nothing: the hook exits 0 and says nothing',
    inPlan.status === 0 && inPlan.stdout === '', `stdout "${inPlan.stdout.slice(0, 80)}"`);
  const noMode = answered('allow', { CREW_GATE_MODE: '' });
  check('with no mode configured the hook approves nothing', noMode.status === 0 && noMode.stdout === '');
  const odd = answered('allow', { CREW_GATE_MODE: 'bypassPermissions' });
  check('a mode the hook does not name gets no approval: the list is the two it knows',
    odd.status === 0 && odd.stdout === '', 'an allow-list; a mode added to the server later is silent until it is added here');
  const sessionInPlan = answered('allow', { CREW_GATE_MODE: 'default' }, { permission_mode: 'plan' });
  check('a session the harness reports as plan gets no approval, whatever the hook was configured with',
    sessionInPlan.status === 0 && sessionInPlan.stdout === '');
  const sessionAgrees = answered('allow', { CREW_GATE_MODE: 'default' }, { permission_mode: 'default' });
  check('the control: the same call with the harness reporting default is approved',
    decisionOf(sessionAgrees)?.permissionDecision === 'allow');
  fs.writeFileSync(path.join(gate.spool, 'always', 'Bash'), '');
  const alwaysOn = runHookOut({ CREW_GATE_MODE: 'default' });
  const alwaysPlan = runHookOut({ CREW_GATE_MODE: 'plan' });
  fs.rmSync(path.join(gate.spool, 'always', 'Bash'));
  // A session allowance is not an approval. Nobody saw the calls that come after it, so the hook lets them
  // through without a word and the harness decides as it would have with no panel: what it would have asked a
  // person about is refused, not run unseen. The click that GAVE the allowance was seen, and is approved.
  check('a tool allowed for the session passes the hook in silence, in every mode: nobody saw that call',
    alwaysOn.status === 0 && alwaysOn.stdout === '' && alwaysPlan.status === 0 && alwaysPlan.stdout === '',
    `default: "${alwaysOn.stdout.slice(0, 60)}"`);
  check('twin: the call on which the allowance was given was seen, and is approved',
    decisionOf(answered('always', { CREW_GATE_MODE: 'default' }))?.permissionDecision === 'allow');
  const denied = answered('deny', { CREW_GATE_MODE: 'default' });
  const silent = runHookOut({ CREW_GATE_MODE: 'default' });
  check('a denial and a timeout are exit 2 with nothing on stdout, in a mode that may write too',
    denied.status === 2 && denied.stdout === '' && silent.status === 2 && silent.stdout === '');

  // The mode reaches the hook from the server, and only as a plain word.
  const modeOf = (id, mode) => {
    const g = prepare(id, mode);
    const cmd = JSON.parse(fs.readFileSync(g.settingsPath, 'utf8')).hooks.PreToolUse[0].hooks[0].command;
    cleanup(id);
    return cmd;
  };
  check('the server tells the hook which mode the session was started in',
    / CREW_GATE_MODE=acceptEdits bash /.test(modeOf(`${probeId}-m1`, 'acceptEdits'))
    && / CREW_GATE_MODE=plan bash /.test(modeOf(`${probeId}-m2`, 'plan')));
  check('a mode that is not a plain word never reaches the command line',
    !/CREW_GATE_MODE/.test(modeOf(`${probeId}-m3`, 'default; rm -rf x')) && !/CREW_GATE_MODE/.test(modeOf(`${probeId}-m4`, null)));

  // What the allowance cannot do. Studio's settings file carries one hook and nothing else: no permission
  // rule of its own, nothing that turns other hooks off. A deny rule in the project's settings and a gate of
  // Crewforth's own are therefore untouched by it — whether Claude Code lets them win over this hook's
  // "allow" is a fact about Claude Code, measured in a real session and not here.
  const loosens = (settings) => [
    ...Object.keys(settings).filter((k) => k !== 'hooks'),
    ...Object.keys(settings.hooks ?? {}).filter((k) => k !== 'PreToolUse'),
    ...((settings.hooks?.PreToolUse ?? []).length === 1 && settings.hooks.PreToolUse[0].hooks?.length === 1 ? [] : ['more than one hook']),
  ];
  check('Studio\'s settings file carries its one hook and nothing that loosens the session',
    loosens(cfg).length === 0, loosens(cfg).join(', ') || 'keys: hooks.PreToolUse[0].hooks[0]');
  check('twin: a settings file with a permission rule or a hook switch in it is caught',
    loosens({ ...cfg, permissions: { allow: ['Bash(rm:*)'] } }).join() === 'permissions'
    && loosens({ ...cfg, disableAllHooks: true }).join() === 'disableAllHooks');

  // Crewforth's own gate decides from the command alone. It is run here on the same call Studio's hook has
  // just approved: the approval is not something it can see, so it cannot be talked out of a block by it.
  const guard = path.join(PAYLOAD, 'hooks', 'guard-bash.sh');
  if (!fs.existsSync(guard)) {
    skip('Crewforth\'s own gate still blocks a call Studio allowed', 'scope', 'kit/hooks/guard-bash.sh is not in this tree');
  } else {
    const runGuard = (command) => {
      try {
        execFileSync('bash', [guard], {
          input: JSON.stringify({ session_id: probeId, hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_use_id: 'toolu_probe', tool_input: { command } }),
          stdio: ['pipe', 'pipe', 'pipe'],
        });
        return 0;
      } catch (e) { return e.status ?? -1; }
    };
    const force = { tool_input: { command: 'git push --force origin main' } };
    const studioSays = answered('allow', { CREW_GATE_MODE: 'default' }, force);
    const guardSays = runGuard('git push --force origin main');
    check('Crewforth\'s own gate still blocks a call Studio allowed',
      decisionOf(studioSays)?.permissionDecision === 'allow' && guardSays === 2,
      `Studio's hook: allow · guard-bash.sh: exit ${guardSays}`);
    check('twin: the same gate lets a harmless command through, so the 2 was about the command',
      runGuard('git status') === 0);
    check('Crewforth\'s gate does not read Studio\'s spool: an allowance cannot reach it',
      !/crew-studio-gate|CREW_GATE_MODE|studio-gate/.test(read(guard) ?? ''));
  }

  // Who asked. Claude Code names the subagent in the hook's input only when the call came from inside one.
  const asks = (extra) => {
    fs.writeFileSync(path.join(gate.spool, 'req', 'toolu_who.json'), JSON.stringify({
      session_id: probeId, tool_name: 'Bash', tool_use_id: 'toolu_who', tool_input: { command: 'echo who' }, ...extra,
    }));
    const r = pending(probeId).find((x) => x.toolUseId === 'toolu_who');
    fs.rmSync(path.join(gate.spool, 'req', 'toolu_who.json'));
    return r;
  };
  const fromAgent = asks({ agent_id: 'a1b2c3d4', agent_type: 'crew-test-expert' });
  check('a request from inside a subagent says which one asked',
    fromAgent?.agentId === 'a1b2c3d4' && fromAgent?.agentType === 'crew-test-expert',
    `${fromAgent?.agentId} / ${fromAgent?.agentType}`);
  const fromSession = asks({});
  check('a request with no agent in it is the session asking, not an unknown agent',
    fromSession && fromSession.agentId === null && fromSession.agentType === null);
  check('an agent id that is not an identifier is not passed on',
    asks({ agent_id: '../../etc', agent_type: 'x' })?.agentId === null,
    'the page uses it to find a card; it never becomes a path, and it is still refused');

  // Taking back "allow for this session". Behaviour: after the revoke the real hook asks again.
  fs.writeFileSync(path.join(gate.spool, 'always', 'Bash'), '');
  const before = alwaysList(probeId);
  const took = revoke(probeId, 'Bash');
  check('a tool allowed for the session is listed, and revoking it takes it off the list',
    before.includes('Bash') && took.ok && took.revoked === true && !alwaysList(probeId).includes('Bash'),
    `before [${before}] after [${alwaysList(probeId)}]`);
  check('after a revoke the hook asks again', runHook() === 2,
    'with nobody answering, asking again ends in a denial; exit 0 here would mean the allowance survived');
  const again = revoke(probeId, 'Bash');
  check('revoking what is not allowed is said, not counted as a revoke', again.ok && again.revoked === false);
  fs.writeFileSync(path.join(gate.spool, 'ans', 'keep'), 'x');
  check('a tool name that is not an identifier is refused, and nothing outside always/ is removed',
    revoke(probeId, '../ans/keep').ok === false && fs.existsSync(path.join(gate.spool, 'ans', 'keep')));
  fs.rmSync(path.join(gate.spool, 'ans', 'keep'));

  cleanup(probeId);
  check('cleanup removes the spool', !fs.existsSync(gate.spool));
}

/* -------------------------------------------- §13 quick replies ------
   A headless session is not given AskUserQuestion — measured: absent from the
   78-tool list in both permission modes, present in an interactive session. So
   options arrive as prose, and the panel only makes them clickable. The rule
   for when prose counts as a question is what these pin: too loose and every
   bulleted list grows buttons. */

process.stdout.write('\n== §13 quick replies ==\n');

const qr = [
  ['two options under a question', 'Which do you prefer?\n\n1. **Tabs**\n2. **Spaces**', 2],
  ['three options', 'How should I proceed?\n- Rebase\n- Merge\n- Leave it', 3],
  ['a list that answers rather than asks', 'Here is what I found:\n- one\n- two\n- three', 0],
  ['a single option is not a choice', 'Shall I?\n1. Yes', 0],
  ['a long list is a report', 'Which?\n1. a\n2. b\n3. c\n4. d\n5. e\n6. f', 0],
  ['a paragraph-length item is not a button', `Which?\n1. ${'x'.repeat(90)}\n2. short`, 0],
  ['nothing at all', '', 0],
  ['prose with no list', 'Do you want me to continue?', 0],
];
for (const [name, text, want] of qr) {
  const got = quickReplies(text).length;
  check(`quick replies: ${name}`, got === want, `${got} offered, expected ${want}`);
}
check('emphasis is stripped from the label',
  quickReplies('Which?\n1. **Tabs**\n2. `Spaces`')[0] === 'Tabs');

/* ------------------------------------------ §14 no raw shell, no python ---
   The panel once offered raw shells behind a flag. They were the one surface the
   kit's gates could not see — a command typed there never becomes a tool call —
   and the only reason the panel needed python3. Shell work goes through a
   session's Bash tool, where the gates apply. These pin that it stays that way:
   one bash path, no python3, on every OS. They read this checkout's files and
   run its server entry point, nothing about the machine. */

process.stdout.write('\n== §14 no raw shell, no python ==\n');
{
  const RAW_SHELL = /python3|pty-bridge|\/api\/pty|enable-pty/;
  const files = walk(STUDIO);
  const hits = files.filter((f) => RAW_SHELL.test(read(f) ?? ''))
    .map((f) => path.relative(REPO, f));
  // A scan that saw nothing proves nothing, so the count is part of the verdict.
  check(`no studio file names python3, the pty bridge, /api/pty or --enable-pty (${files.length} files read)`,
    files.length > 0 && hits.length === 0,
    files.length === 0 ? 'the walk found no files — the scan is broken, not clean' : hits.join(', '));

  // Behaviour, not text: the server's own parser has to turn the flag away. An
  // unknown argument is rejected with exit 64 and says which one, so a flag that
  // was quietly re-accepted, or quietly ignored, both show here.
  const r = spawnSync(process.execPath, [path.join(STUDIO, 'server', 'index.js'), '--enable-pty'],
    { encoding: 'utf8', timeout: 20000 });
  check('the server rejects --enable-pty as an unknown argument',
    r.status === 64 && /unknown argument: --enable-pty/.test(r.stderr ?? ''),
    `rc=${r.status} stderr=${JSON.stringify((r.stderr ?? '').trim().slice(0, 200))}`);
}

// Behaviour: the plan a terminal launch would run, quoted.
process.stdout.write('\n== §15 handing a session to a real terminal ==\n');

const tp = terminalPlan({ cwd: "/tmp/it's here", sessionId: 'abc-123' });
check('a path with a quote in it cannot break out of the command',
  tp.line.includes("/tmp/it'\\''s here") || tp.line.includes(String.raw`it'\''s here`),
  tp.line);
check('the session id is quoted too', tp.line.includes("'abc-123'"));
check('the plan is inspectable before anything launches', typeof tp.line === 'string' && tp.line.length > 0);

/* ------------------------------------------- §16 the kit's own numbers ---
   The panel reports what the kit's tools said, including when they said they
   could not answer. The distinction these pin is the one that would be easiest
   to lose: a decision found in a log is not a decision seen happening. */

process.stdout.write('\n== §16 kit telemetry ==\n');

// A fixture, not this checkout. These read a gate log, and a gate log only
// exists on a machine that has actually run the guard hooks — it is gitignored.
// Pointed at REPO these four passed here and failed 4/4 on a fresh clone, which
// is the worst kind of gate: green for the author, red for everyone else, and
// silent about the difference.
const logHome = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-studio-gatelog-'));
fs.mkdirSync(path.join(logHome, '.claude'), { recursive: true });
fs.writeFileSync(path.join(logHome, '.claude', 'gate-log.tsv'),
  ['BLOCK\t§4.1\tdestructive\tgit reset --hard',
    'BLOCK\t§4.1\tdestructive\trm -rf /',
    'ASK\t§2.3\tcommit-approval\tgit commit -m x',
    'ALLOW\t§2.3\tcommit-approval\tgit status',
    ''].join('\n'));

let own;
try {
  own = gateLog(logHome);
} finally {
  fs.rmSync(logHome, { recursive: true, force: true });
}
check('the gate log is read where it exists', own.measured === true, own.reason ?? `${own.total} entries`);
check('every record in the fixture is read back, and no more',
  own.total === 4 && own.counts.BLOCK === 2 && own.counts.ASK === 1 && own.counts.ALLOW === 1,
  `a parser that drops or invents records would still satisfy a "> 0 entries" check (got ${JSON.stringify(own.counts)})`);
check('the log is marked as carrying no timestamps',
  own.measured && own.timestamped === false,
  'the format has no timestamp column, and the panel must not imply one');
check('whether commands were recorded is stated, not assumed',
  own.measured && own.commandsRecorded === true);
check('verdicts are counted', own.measured && typeof own.counts?.BLOCK === 'number', JSON.stringify(own.counts));

const noLog = gateLog(os.tmpdir());
check('a project with no gate log says so rather than showing an empty list',
  noLog.measured === false && /no .claude\/gate-log/.test(noLog.reason ?? ''),
  noLog.reason);
check('"not measured" never carries entries', (noLog.entries ?? []).length === 0);

check('the kit is found in an installed layout and in this source checkout',
  kitInternals.kitPaths(REPO)?.kind === 'source' && kitInternals.kitPaths(os.tmpdir()) === null);

const rep = await gateReport(os.tmpdir());
check('a directory without the kit is told so', rep.measured === false, rep.reason);

// On a repository of its own. Asked of this checkout, board.sh also asks `origin` whether a board exists there,
// so the answer depended on the network and on whatever else was using the same .git: it came back empty in one
// run of two, and red in a copy of the tree that had no .git at all.
{
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-studio-board-'));
  try {
    const made = spawnSync('git', ['init', '-q', home], { encoding: 'utf8' });
    if (made.status !== 0) {
      skip('a repo with no board reports a state, not a failure', 'tool', 'git is not available to make the fixture repository');
    } else {
      fs.mkdirSync(path.join(home, '.claude'), { recursive: true });
      fs.cpSync(path.join(PAYLOAD, 'hooks'), path.join(home, '.claude', 'hooks'), { recursive: true });
      const brd = await board(home);
      check('a repo with no board reports a state, not a failure',
        brd.measured === true && brd.present === false,
        brd.text ?? brd.reason);
    }
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
}

const st = await sessionStats(REPO, path.join(os.tmpdir(), 'definitely-not-a-transcript.jsonl'));
check('missing transcript is reported rather than guessed at', st.measured === false, st.reason);

/* ------------------------------------------ §17 reach and continuity ---
   Two things a reader tried and could not do. */

process.stdout.write('\n== §17 opening and continuing ==\n');

// What a click on a card does is asserted where the canvas is run: §27, "a click does what the card says".

const sessSrc2 = read(path.join(STUDIO, 'server', 'lib', 'session.js')) ?? '';
check('an existing conversation can be continued rather than started over',
  /--resume/.test(sessSrc2));
check('continuing forks, so the original transcript is never the one being written',
  /--fork-session/.test(sessSrc2));
check('the session to resume must be an identifier',
  /is not an identifier/.test(sessSrc2));

/* ---------------------------------------- §18 sessions on other machines ---
   Only a session connected to Remote Control can see them — measured: a
   headless session's ListAgents returns the local peers where a connected one
   returns those plus five remote, and passing --remote-control to a headless
   session does not change it. So the panel reads what a connected session
   already recorded, and says when. */

process.stdout.write('\n== §18 remote roster ==\n');

// Synthetic throughout. Real session names are machine-private, and a fixture
// is exactly where one would slip into the repo unnoticed.
const sample = [
  'This session is alpha [aaa111] — the name other sessions use to message it.',
  '',
  'Peer sessions (3):',
  '  bravo [bbb222]  ·  interactive  ·  idle  ·  started 3h ago',
  '  charlie [ccc333]  ·  Remote Control  ·  running',
  '  delta [ddd444]  ·  Remote Control  ·  offline',
].join('\n');

const parsed = parseRoster(sample);
check('the roster block is parsed', parsed !== null && parsed.peers.length === 3);
check('the session names itself', parsed?.self?.name === 'alpha');
check('a machine elsewhere is told apart from one here',
  parsed?.peers.filter((p) => p.remote).length === 2);
check('status survives', parsed?.peers.find((p) => p.name === 'charlie')?.status === 'running');
check('free text after the status is carried, not parsed into a time it may not be',
  parsed?.peers.find((p) => p.name === 'bravo')?.note === 'started 3h ago');
check('prose without a roster yields nothing', parseRoster('there are no peers here') === null);
check('an empty block yields nothing, not an empty roster', parseRoster('Peer sessions (0):') === null);

const live = await remoteRoster();
check('the roster is either measured or says why not',
  live.measured === true || typeof live.reason === 'string',
  live.measured ? `${live.remotes} remote, seen ${new Date(live.seenAt).toISOString()}` : live.reason);
check('a measured roster says when it was seen, never implying now',
  live.measured !== true || (typeof live.seenAt === 'number' && live.live === false));

const rosterSrc = read(path.join(STUDIO, 'server', 'lib', 'roster.js')) ?? '';
check('records are parsed rather than grepped, because the block is JSON-escaped',
  /JSON\.parse\(line\)/.test(rosterSrc),
  'a line-anchored regex over the raw tail matched nothing: the newlines in it are two characters, not one');

/* ------------------------------------------------------- §19 history ---
   A resumed session remembers what was said; the panel did not draw it, so
   continuing a conversation looked exactly like starting one. And a session
   the panel cannot write to is still one it can read. */

process.stdout.write('\n== §19 conversation history ==\n');

const chatSrc2 = read(path.join(STUDIO, 'web', 'chat.js')) ?? '';
check('a resumed pane loads what was said before it',
  /loadHistory/.test(chatSrc2) && /resumedFrom/.test(chatSrc2));
check('the seam between history and this run is drawn, not implied',
  /chat-seam/.test(chatSrc2) && /forked from \$\{from/.test(chatSrc2));
check('an observed session is shown but not writable',
  /openReadOnly/.test(chatSrc2) && /readOnly/.test(chatSrc2));
check('the read-only pane says why it cannot be written to, and what to do instead',
  /This session was not started here\./.test(chatSrc2) && /cannot write to it or answer its approvals/.test(chatSrc2)
  && /'Continue here'/.test(chatSrc2) && /'Open in terminal'/.test(chatSrc2));
// A fork reads as "I am now typing into that session" unless the UI says
// otherwise, and the user then wonders why their terminal stays silent. Both
// the seam and the read-only notice must say the two are separate.
check('the panel never lets a fork pass for the session it copied',
  /the original does not see this/.test(chatSrc2)
  && /never reach your terminal/.test(chatSrc2),
  'calling it "continued" made a copy look like a live channel into the terminal');

// The fix that made this worth distinguishing: a terminal continues a session
// by resuming it, and so does the panel now — but only when nothing else holds
// it open. Forking unconditionally was the bug; forking never would be worse.
{
  const sess = read(path.join(STUDIO, 'server', 'lib', 'session.js')) ?? '';
  check('a resume is only forked when the session is still held open',
    /const forked = resume \? await isHeldOpen/.test(sess),
    'forking every resume moved the user to a stranger; forking none would let two processes write one transcript');
  check('a true continuation keeps the id it is continuing',
    /const sessionId = resume && !forked \? String\(resume\) : randomUUID\(\)/.test(sess));
  check('--session-id is not sent alongside a bare resume',
    /args\.push\('--resume', this\.resumedFrom\);/.test(sess)
    && /\} else \{\s*\n\s*args\.push\('--session-id', this\.id\);/.test(sess),
    'asking for a new id while resuming an old one is a contradiction the CLI has to resolve');
  check('an unreadable fleet forks rather than risking two writers',
    /if \(fleet && fleet\.measured === false\) return true;/.test(sess),
    'treating "not measured" as "not running" is the kit\'s oldest mistake, in a new place');
  check('the panel refuses to run one session twice',
    /the panel is already running that session/.test(sess));
}

const graphSrc = read(path.join(STUDIO, 'server', 'lib', 'graph.js')) ?? '';
check('a subagent exchange is left out of the conversation it was not part of',
  /isSidechain === true\) continue/.test(graphSrc) && /parent_tool_use_id\) continue/.test(graphSrc));
check('command envelopes are not shown as things someone said',
  /command-name\|command-message/.test(graphSrc));
check('a truncated history says how much was left out',
  /truncated/.test(graphSrc) && /total - conv\.messages\.length|conv\.total/.test(chatSrc2));

/* -------------------------------------------- §20 the modules evaluate ---
   A syntax check parses; it does not run. Both of today's page-killing bugs
   parsed cleanly — a const read inside its temporal dead zone, and an
   identifier whose declaration had been deleted out from under it. Each module
   is loaded against a stub DOM so that class of failure is caught here rather
   than by a blank page. */

process.stdout.write('\n== §20 browser modules load ==\n');

{
  const cleanup = installDom();
  for (const mod of ['md.js', 'canvas.js', 'chat.js', 'app.js']) {
    let err = null;
    try {
      // Cache-busted so a module is really evaluated on every run.
      await import(`../../kit/studio/web/${mod}?t=${Date.now()}`);
    } catch (e) {
      err = e;
    }
    check(`${mod} evaluates`, err === null, err ? `${err.name}: ${err.message}` : null);
  }
  // Loading a module runs what runs at load. Rendering is where the rest of it
  // lives — and a method calling a helper this file never had threw there,
  // silently, leaving the group labels missing with no error anyone saw.
  {
    let err = null;
    try {
      const { Canvas } = await import(`../../kit/studio/web/canvas.js?render=${Date.now()}`);
      const host = document.createElement('div');
      const c = new Canvas(host, {});
      c.setPalette({ map: { Explore: { hex: '#26c6e6', source: 'builtin' } }, unknown: '#94a3c8' });
      c.setSession('fixture');
      c.render({
        nodes: [
          { id: 'session', kind: 'session', label: 's', turns: 1, cwd: '/x' },
          { id: 'a1', kind: 'agent', agentType: 'Explore', status: 'done', spawnDepth: 1, parentId: 'session', tools: { Bash: 2 }, toolCount: 2 },
          { id: 'a2', kind: 'agent', agentType: 'Explore', status: 'running', spawnDepth: 1, parentId: 'session', tools: {}, toolCount: 0 },
          { id: 'w1', kind: 'workflow', members: 3, byStatus: { done: 3 }, spawnDepth: 1, parentId: 'session' },
        ],
        edges: [
          { id: 'e1', source: 'session', target: 'a1', kind: 'spawn' },
          { id: 'e2', source: 'session', target: 'a2', kind: 'spawn' },
          { id: 'e3', source: 'session', target: 'w1', kind: 'spawn' },
        ],
        stats: {},
      });
    } catch (e) {
      err = e;
    }
    check('the canvas renders a graph without throwing', err === null,
      err ? `${err.name}: ${err.message}` : null);
  }

  cleanup();
}

/* --------------------------------- §21 nothing is used undeclared ------
   Loading a module proves what runs at load. It says nothing about a handler
   that only runs on a click — which is where the second of today's bugs lived:
   a Set used in three places whose declaration had been deleted, so the module
   evaluated fine and the page broke the moment anyone clicked.
 
   This looks for the shape that bug had: a name used as a collection, but
   declared nowhere in its file. Narrow on purpose — a general scope checker is
   a linter, and this is the failure that actually happened. */

process.stdout.write('\n== §21 collections are declared ==\n');

// Not preceded by a dot: `this.collapsed.has(...)` is a property, not a name
// this file has to declare.
const COLLECTION_USE = /(?<![.\w$])([a-z][A-Za-z0-9_]*)\.(?:has|add|delete|clear)\(/g;
const GLOBALS = new Set(['localStorage', 'sessionStorage', 'classList', 'dataset', 'document', 'window', 'store', 'headers', 'params', 'searchParams']);

for (const mod of ['app.js', 'chat.js', 'canvas.js']) {
  const src = read(path.join(STUDIO, 'web', mod)) ?? '';
  const used = new Set();
  let m;
  while ((m = COLLECTION_USE.exec(src)) !== null) used.add(m[1]);

  const missing = [];
  for (const name of used) {
    if (GLOBALS.has(name)) continue;
    // Declared here, imported here, or bound as a parameter of a function in
    // this file. Anything else is a name nothing in the file creates.
    const declared = new RegExp(
      String.raw`(?:const|let|var|function|class)\s+${name}\b`
      + String.raw`|import[^;]*\b${name}\b`
      + String.raw`|\(\s*(?:[^)]*,\s*)?${name}\s*[,)]`
      + String.raw`|\{[^}]*\b${name}\b[^}]*\}\s*=`,
    ).test(src);
    if (!declared) missing.push(name);
  }
  check(`${mod}: every collection it uses is declared in it`, missing.length === 0,
    missing.length ? `used but never declared: ${missing.join(', ')}` : `${used.size} checked`);
}

/* ------------------------------------------------------ §22 the layout ---
   Three columns, two dividers, and a conversation that reads like one. */

process.stdout.write('\n== §22 layout ==\n');

const cssSrc = read(path.join(STUDIO, 'web', 'style.css')) ?? '';
// Six columns since the redesign: the inspector has one of its own between the
// stage and the conversation. The claim is unchanged — the conversation is the
// last column of the same row as the stage.
check('the conversation is a column beside the graph, not a drawer under it',
  /\.shell\s*\{[^}]*grid-template-columns:\s*var\(--side-w,\s*var\(--nav-w\)\)\s+5px\s+minmax\(0,\s*1fr\)\s+auto\s+5px\s+var\(--chat-w/.test(cssSrc.replace(/\/\*[\s\S]*?\*\//g, '')));
check('who spoke is read from which side it sits on',
  /\.msg-user\s*\{\s*align-items:\s*flex-end/.test(cssSrc)
  && /\.msg-assistant\s*\{\s*align-items:\s*stretch/.test(cssSrc)
  && /el\('div', 'msg-role', 'Session'\)/.test(chatSrc2),
  'what the viewer wrote is a bubble on the right; what the session said runs the width under its name');
check('either panel can be collapsed without leaving a gap where it was',
  /\.shell\.no-side/.test(cssSrc) && /\.shell\.no-chat/.test(cssSrc));
// A hidden grid child occupies no cell, so auto-flow slides everything after it
// one column left: hiding the sidebar handed the graph the rail's 22px and gave
// the conversation the rest of the window.
check('every column is placed explicitly rather than by auto-flow',
  /\.shell > \.stage\s*\{\s*grid-column:\s*3/.test(cssSrc)
  && /\.shell > \.chat,\s*\.shell > \.newpanel\s*\{\s*grid-column:\s*6/.test(cssSrc)
  && /\.shell\.no-chat > \.inspector\s*\{[^}]*grid-column:\s*4/.test(cssSrc),
  'stage 3, docked inspector 4, conversation 6');
check('the control that reopens the sidebar is on the edge it acts on',
  /\.side-rail\s*\{[^}]*left:\s*0/.test(cssSrc),
  'it started in the header, in the opposite corner from the panel it opens');

const appSrc2 = read(path.join(STUDIO, 'web', 'app.js')) ?? '';
check('the right-hand divider grows its panel when dragged left',
  /edge === 'right' \? -1 : 1/.test(appSrc2),
  'sharing one handler without inverting the delta shrank the panel being opened');
check('both widths are remembered', /crewforth-studio-side-w/.test(appSrc2) && /crewforth-studio-chat-w/.test(appSrc2));

// 3.0 renamed the saved-layout keys. The move is run against a Map-backed storage, so what is asserted is the
// behaviour — the layout survives, the old key is gone, a value already under the new name is not overwritten —
// and not the source text. And the panel must call it before it reads any key.
{
  const { migrateStorage } = await import(`../../kit/studio/web/storage-migrate.js?t=${Date.now()}`);
  const m = new Map([['csk-studio-theme', 'dark'], ['csk-studio-layout:down:s1', '{"a":1}'],
    ['csk-studio-side-w', '300'], ['crewforth-studio-side-w', '410'], ['unrelated', 'x']]);
  const ls = { get length() { return m.size; }, key: (i) => [...m.keys()][i] ?? null,
    getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) };
  const moved = migrateStorage(ls);
  check('a 2.x saved layout survives the key rename (moved, old key removed, newer value kept)',
    moved === 3 && m.get('crewforth-studio-theme') === 'dark' && m.get('crewforth-studio-layout:down:s1') === '{"a":1}'
      && m.get('crewforth-studio-side-w') === '410' && m.get('unrelated') === 'x'
      && ![...m.keys()].some((k) => k.startsWith('csk-studio-')),
    JSON.stringify([...m.entries()]));
  check('a second open moves nothing', migrateStorage(ls) === 0);
  const firstRead = appSrc2.search(/store\.get\(|localStorage\.getItem\(/);
  // The theme is read inside theme.js now, so the call that starts it is a read too.
  const themeRead = appSrc2.indexOf('initTheme(');
  check('the panel migrates the keys before it reads any', /migrateStorage\(localStorage\)/.test(appSrc2)
    && appSrc2.indexOf('migrateStorage(localStorage)') < firstRead
    && themeRead !== -1 && appSrc2.indexOf('migrateStorage(localStorage)') < themeRead,
  `first read at ${firstRead}, theme read at ${themeRead}`);
}


/* ------------------------------------------- §23 launching from a symlink */

// Every global install path puts a symlink on PATH: `npm link`, `npm i -g`,
// Homebrew. The direct-run guard compares import.meta.url against argv[1], and
// argv[1] is then the symlink while import.meta.url is the real file. Getting
// this wrong is invisible — the command exits 0 having printed nothing.
//
// Grepping for `realpathSync` would pass on a guard wrapped in `if (false)`.
// So run it: a symlink into a temp dir, invoked with --help, must produce the
// usage text. A regressed guard prints nothing and still exits 0.
{
  const entry = path.join(STUDIO, 'server', 'index.js');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-studio-link-'));
  const link = path.join(dir, 'crewforth-studio');
  let viaLink = '';
  let viaReal = '';
  try {
    fs.symlinkSync(entry, link);
    const run = (target) => execFileSync(process.execPath, [target, '--help'], {
      encoding: 'utf8', timeout: 20000, stdio: ['ignore', 'pipe', 'pipe'],
    });
    viaLink = run(link);
    viaReal = run(entry);
  } catch (e) {
    viaLink = `ERROR ${e?.message ?? e}`;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }

  check('the entry point runs when invoked through a symlink',
    /--port/.test(viaLink),
    `a symlinked bin printed nothing — comparing raw argv[1] to import.meta.url `
    + `makes every global install a silent no-op. got: ${JSON.stringify(viaLink.slice(0, 120))}`);
  check('the symlinked invocation matches the direct one',
    viaLink === viaReal && viaReal.length > 0,
    'the two paths diverged, so the guard is doing something path-dependent');
}


/* --------------------------------- §26 delegation reads as motion ------
   The graph was correct and inert. A viewer could see that two cards were
   connected and could not see which way the work went or which branch was
   alive, which is the one thing the panel exists to show.

   Grepping the stylesheet for "animation" would pass on a sheet that animates
   nothing, and grepping for a keyframe name would pass on one whose rule never
   matches any element. So this section does two things instead. It renders
   real fixtures through the canvas and reads what the canvas produced. And it
   resolves the stylesheet the way a browser would — parse, match, sort by
   specificity then source order — and asserts the values that come out. The
   second half caught a real bug on its first run: the reduced-motion rules
   were a hundred points of specificity short of the rules they had to beat,
   so asking for less motion changed nothing. */

process.stdout.write('\n== §26 delegation reads as motion ==\n');

/* A cascade small enough to trust — enough CSS to answer "what would the
   browser compute here", which is the only question this section asks. */

function cssRules(src) {
  const clean = src.replace(/\/\*[\s\S]*?\*\//g, '');
  const out = [];
  let order = 0;
  const walk = (text, media) => {
    let i = 0;
    while (i < text.length) {
      const open = text.indexOf('{', i);
      if (open === -1) break;
      const prelude = text.slice(i, open).trim();
      let depth = 1;
      let j = open + 1;
      while (j < text.length && depth > 0) {
        if (text[j] === '{') depth += 1;
        else if (text[j] === '}') depth -= 1;
        j += 1;
      }
      const body = text.slice(open + 1, j - 1);
      if (/^@media\b/.test(prelude)) {
        walk(body, media.concat(prelude.replace(/^@media\s*/, '').trim()));
      } else if (!prelude.startsWith('@')) {
        // Keyframe blocks are not cascade rules and drop out here with every
        // other at-rule; they are read separately, by name, below.
        const decls = new Map();
        for (const part of body.split(';')) {
          const k = part.indexOf(':');
          if (k === -1) continue;
          const prop = part.slice(0, k).trim();
          if (prop) decls.set(prop, part.slice(k + 1).trim());
        }
        for (const sel of prelude.split(',')) {
          const s = sel.trim();
          if (s) out.push({ sel: s, decls, media, order: (order += 1) });
        }
      }
      i = j;
    }
  };
  walk(clean, []);
  return out;
}

/** The body of a named at-rule, brace-balanced. */
function atRule(src, name) {
  const i = src.indexOf(name);
  if (i === -1) return '';
  const open = src.indexOf('{', i);
  if (open === -1) return '';
  let depth = 1;
  let j = open + 1;
  while (j < src.length && depth > 0) {
    if (src[j] === '{') depth += 1;
    else if (src[j] === '}') depth -= 1;
    j += 1;
  }
  return src.slice(open + 1, j - 1);
}

/** Which properties a keyframe block actually animates. */
function animates(body) {
  return new Set([...body.matchAll(/([a-z-]+)\s*:/g)].map((m) => m[1]));
}

const CSS_TOKEN = /^[a-zA-Z][\w-]*|\.[\w-]+|#[\w-]+|\[[^\]]*\]|::?[\w-]+(?:\([^)]*\))?|\*/g;

function compound(s) {
  const out = { tag: null, id: null, classes: [], attrs: [], pseudos: [], bad: false };
  for (const t of s.match(CSS_TOKEN) ?? []) {
    if (t === '*') continue;
    else if (t.startsWith(':')) out.pseudos.push(t);
    else if (t.startsWith('.')) out.classes.push(t.slice(1));
    else if (t.startsWith('#')) out.id = t.slice(1);
    else if (t.startsWith('[')) {
      const m = /^\[([\w-]+)(?:=["']?([^\]"']*)["']?)?\]$/.exec(t);
      if (m) out.attrs.push([m[1], m[2] ?? null]); else out.bad = true;
    } else out.tag = t.toLowerCase();
  }
  return out;
}

/** An element is `{ tag, classes:Set, attrs:{}, pseudo }`. A pseudo-class the
 *  probes do not model — `:hover`, `:not(…)` — never matches, which is the
 *  right answer here: none of these probes is hovered or is the root. */
function hits(c, el) {
  if (c.bad || c.id) return false;
  if (c.tag && c.tag !== el.tag) return false;
  for (const k of c.classes) if (!el.classes.has(k)) return false;
  for (const [name, val] of c.attrs) {
    const have = el.attrs[name];
    if (have === undefined) return false;
    if (val !== null && String(have) !== val) return false;
  }
  const want = c.pseudos.map((p) => (p.startsWith('::') ? p : `:${p}`));
  if (want.length === 0) return el.pseudo == null;
  return want.length === 1 && want[0] === el.pseudo;
}

function selMatches(sel, el, ancestors) {
  const toks = sel.trim().split(/\s+/).filter(Boolean);
  const last = toks.pop();
  if (!hits(compound(last), el)) return false;
  let ai = ancestors.length - 1;                 // ancestors run outermost first
  for (let i = toks.length - 1; i >= 0; i -= 1) {
    const t = toks[i];
    if (t === '+' || t === '~') return false;    // siblings are not modelled
    if (t === '>') {
      i -= 1;
      if (ai < 0 || !hits(compound(toks[i]), ancestors[ai])) return false;
      ai -= 1;
      continue;
    }
    const c = compound(t);
    let found = false;
    while (ai >= 0) {
      const anc = ancestors[ai];
      ai -= 1;
      if (hits(c, anc)) { found = true; break; }
    }
    if (!found) return false;
  }
  return true;
}

function specificity(sel) {
  let b = 0;
  let c = 0;
  for (const t of sel.split(/\s+|>|\+|~/).filter(Boolean)) {
    const p = compound(t);
    b += p.classes.length + p.attrs.length + p.pseudos.filter((x) => !x.startsWith('::')).length;
    c += (p.tag ? 1 : 0) + p.pseudos.filter((x) => x.startsWith('::')).length;
  }
  return b * 100 + c;
}

function computed(rules, el, ancestors, media = []) {
  const on = new Set(media);
  const won = rules
    .filter((r) => r.media.every((m) => on.has(m)) && selMatches(r.sel, el, ancestors))
    .sort((x, y) => specificity(x.sel) - specificity(y.sel) || x.order - y.order);
  const out = new Map();
  for (const r of won) for (const [k, v] of r.decls) out.set(k, v);
  return out;
}

{
  const dom = installDom();
  const cssText = read(path.join(STUDIO, 'web', 'style.css')) ?? '';
  const rules = cssRules(cssText);
  const REDUCE = ['(prefers-reduced-motion: reduce)'];

  const { Canvas } = await import(`../../kit/studio/web/canvas.js?motion=${Date.now()}`);
  // The palette says whose an agent is. Its colours are no longer read here: colour is status.
  const PAL = {
    measured: true,
    map: {
      Explore: { source: 'builtin' },
      Plan: { source: 'builtin' },
      reviewer: { source: 'kit' },
      tester: { source: 'kit' },
    },
  };

  const kid = (id, status, type = 'Explore', parentId = 'session') =>
    ({ id, kind: 'agent', agentType: type, status, spawnDepth: 1, parentId, tools: {}, toolCount: 0 });
  const root = (turns = 1) => ({ id: 'session', kind: 'session', status: 'session', turns, cwd: '/x' });
  // A canvas that draws every node as its own card, so a claim about one wire is about that wire.
  const plain = (name) => {
    const c = new Canvas(document.createElement('div'), {});
    c.setPalette(PAL);
    c.setSession(name);
    c.setDensity('comfortable');
    return c;
  };

  const FIXTURE = {
    nodes: [
      root(3),
      // One status each, and all of one type: nothing about an agent's type
      // reaches a wire any more, and this fixture would show it if it did.
      kid('live', 'running'),
      kid('wake', 'starting'),
      kid('fin', 'done'),
      kid('bad', 'failed'),
      kid('over', 'ended'),
      kid('old', 'stale'),
      kid('alt', 'done', 'reviewer'),
      { id: 'w1', kind: 'workflow', workflowId: 'wf-fixture', status: 'running', members: 3, byStatus: { running: 3 }, spawnDepth: 1, parentId: 'session' },
      kid('m1', 'running', 'Explore', 'w1'),
      kid('m2', 'running', 'reviewer', 'w1'),
      kid('m3', 'failed', 'tester', 'w1'),
    ],
    edges: [],
  };

  const canvas = plain('motion-fixture');
  canvas.render(FIXTURE);
  // Every wire in a first render is an arrival, so all of them are drawing
  // themselves right now. Wait the arrival out before reading steady state —
  // and the wait is itself the assertion below that the class comes off again.
  await new Promise((r) => { setTimeout(r, 500); });

  // The canvas keys a wire by its endpoints joined on NUL, the one character
  // a node id cannot contain. Built here rather than pasted, so a literal
  // control byte stays out of this file.
  const SEP = String.fromCharCode(0);
  const edgeIn = (cv, from, to) => cv.edgeEls.get([from, to].join(SEP));
  const edge = (from, to) => edgeIn(canvas, from, to);
  const dataAttrs = (el) => Object.fromEntries(
    Object.entries(el.dataset).map(([k, v]) => [`data-${k.replace(/[A-Z]/g, (m) => `-${m.toLowerCase()}`)}`, v]),
  );
  // The stub keeps setAttribute('class') and classList apart; a browser does
  // not, and the canvas legitimately uses both on one path.
  const classesOf = (el) => new Set([
    ...String(el.getAttribute('class') ?? '').split(/\s+/).filter(Boolean),
    ...el.classList._s,
  ]);
  // The chain a path really hangs in, carrying the root's own attributes — the
  // motion budget is expressed there, so a probe that invented the chain would
  // never see it.
  const chainFor = (cv) => [
    { tag: 'div', classes: new Set(['cv-root']), attrs: dataAttrs(cv.root), pseudo: null },
    { tag: 'div', classes: new Set(['cv-viewport']), attrs: {}, pseudo: null },
    { tag: 'svg', classes: new Set(['cv-edges']), attrs: {}, pseudo: null },
    { tag: 'g', classes: new Set(['cv-edge-g']), attrs: {}, pseudo: null },
  ];
  const pathStyle = (cv, el, media) => computed(
    rules, { tag: 'path', classes: classesOf(el), attrs: dataAttrs(el), pseudo: null }, chainFor(cv), media,
  );
  const styleOf = (el, media) => pathStyle(canvas, el, media);
  const asDrawing = (state, media) => computed(rules, {
    tag: 'path', classes: new Set(['cv-edge', 'cv-drawing']), attrs: { 'data-state': state }, pseudo: null,
  }, chainFor(canvas), media);

  const moving = (m) => {
    const a = m.get('animation');
    return Boolean(a) && a !== 'none' && !/(^|\s)0s(\s|$)/.test(a);
  };

  // A probe that matched nothing would make every assertion below vacuously
  // true, so it is asked for a value that is known to be there first.
  check('the cascade probe resolves a rule that is known to exist',
    styleOf(edge('session', 'live')).get('fill') === 'none',
    'the selector matcher found no .cv-edge rule at all — every result below would be empty');
  // An arrival that never ends is a graph where every wire animates the
  // draw-in forever and no wire ever shows its status.
  check('the draw-in takes itself off again',
    [...canvas.edgeEls.values()].every((p) => !p.classList.contains('cv-drawing')),
    `${[...canvas.edgeEls.values()].filter((p) => p.classList.contains('cv-drawing')).length}`
    + ' wires were still drawing half a second after they arrived');

  /* -- 1. motion, and which way it points ------------------------------- */

  const live = styleOf(edge('session', 'live'));
  const fin = styleOf(edge('session', 'fin'));
  check('an edge into a working agent is in motion', moving(live),
    `resolved animation: ${JSON.stringify(live.get('animation') ?? null)}`);
  check('an edge into a finished agent is not', !moving(fin),
    `resolved animation: ${JSON.stringify(fin.get('animation') ?? null)}`);

  // Direction is two facts together: the curve is drawn starting at the
  // parent, and the offset animates negative, which walks the pattern toward
  // the far end. Either one alone says nothing about which way work flows.
  const start = /^M\s*([-\d.]+)\s+([-\d.]+)/.exec(edge('session', 'live').getAttribute('d') ?? '');
  const parentPos = canvas.pos.get('session');
  const childPos = canvas.pos.get('live');
  check('the curve starts at the parent\'s right edge, so "along the path" means "toward the child"',
    Boolean(start) && Number(start[1]) === parentPos.x + 200
    && Number(start[2]) > parentPos.y && Number(start[2]) < parentPos.y + 84
    && childPos.x > Number(start[1]),
    `d starts at ${start ? `${start[1]},${start[2]}` : '?'}; the session sits at ${parentPos.x},${parentPos.y} and the child at x ${childPos.x}`);
  check('the dash travels parent to child rather than back up the wire',
    /stroke-dashoffset:\s*calc\(\s*-1\s*\*/.test(atRule(cssText, '@keyframes cv-flow')),
    `a positive offset runs the dashes the wrong way. keyframe: ${JSON.stringify(atRule(cssText, '@keyframes cv-flow').trim())}`);

  // A dash pattern and a travel distance that disagree put a seam in every
  // loop, and the two moving states do not share a pattern.
  for (const [id, want] of [['live', '6px 7px'], ['wake', '2px 7px']]) {
    const m = styleOf(edge('session', id));
    const period = Number(String(m.get('--dash-period') ?? '').replace('px', ''));
    const sum = String(m.get('stroke-dasharray') ?? '').split(/\s+/)
      .reduce((t, v) => t + Number(String(v).replace('px', '')), 0);
    check(`the ${id} edge advances exactly one dash period per loop`,
      m.get('stroke-dasharray') === want && period === sum && period > 0,
      `dasharray ${m.get('stroke-dasharray')} sums to ${sum}, period is ${period}`);
  }

  /* -- 2. a wire says the state of what it leads to --------------------- */

  const strokeOf = (id) => styleOf(edge('session', id)).get('stroke');
  check('a wire is drawn in the colour its state has everywhere else',
    strokeOf('live') === 'var(--status-busy)' && strokeOf('fin') === 'var(--edge-rest)' && strokeOf('bad') === 'var(--cv-fail)',
    `running ${strokeOf('live')}, done ${strokeOf('fin')}, failed ${strokeOf('bad')}`);
  check('two agents of different types in the same state are wired alike: type is not a colour',
    strokeOf('fin') === strokeOf('alt') && edge('session', 'fin').dataset.state === edge('session', 'alt').dataset.state);
  check('the canvas sets no colour of its own on a wire or a card',
    [...canvas.edgeEls.values()].every((p) => !p.style.stroke)
    && [...canvas.els.values()].every((n) => !n.style.borderColor && !n.style.background && !n.style.color),
    'every colour comes from the stylesheet, by state');
  check('a wire into a workflow run speaks for the run: it is still working',
    edge('session', 'w1').dataset.state === 'live' && strokeOf('w1') === 'var(--status-busy)',
    `state ${edge('session', 'w1').dataset.state}`);

  /* -- 3. a run's members are inside it ----------------------------------- */

  check('a run\'s members sit inside the run; no wire is drawn to them',
    ['m1', 'm2', 'm3'].every((id) => canvas.cellEls.has(id) && !canvas.els.has(id) && !edgeIn(canvas, 'w1', id)),
    `${canvas.cellEls.size} members drawn inside; ${[...canvas.edgeEls.keys()].filter((k) => k.startsWith('w1')).length} wires leave the run`);
  check('every member carries its own state and its word',
    canvas.cellEls.get('m3').dataset.state === 'failed' && canvas.cellEls.get('m3').parts.word.textContent === 'Failed'
    && canvas.cellEls.get('m1').dataset.state === 'live' && canvas.cellEls.get('m1').parts.word.textContent === 'Running');
  {
    const c5 = plain('quiet-run');
    c5.render({ nodes: [root(1),
      { id: 'w', kind: 'workflow', workflowId: 'wf-q', status: 'done', spawnDepth: 1, parentId: 'session' },
      kid('q1', 'done', 'Explore', 'w'), kid('q2', 'failed', 'Plan', 'w'), kid('q3', 'done', 'tester', 'w')], edges: [] });
    const wire = edgeIn(c5, 'session', 'w');
    const runEl = c5.els.get('w');
    check('one failed member does not redden the wire into eleven others; the run\'s bar and the member say it',
      wire.dataset.state === 'done' && runEl.dataset.status === 'failed'
      && runEl.parts.bar.children.some((seg) => seg.dataset.tone === 'fail')
      && c5.cellEls.get('q2').dataset.state === 'failed',
      `wire ${wire.dataset.state}; bar ${runEl.parts.bar.children.map((x) => x.dataset.tone).join('+')}`);
  }

  /* -- 4. arrival ------------------------------------------------------- */

  {
    const c2 = plain('arrival');
    c2.render({ nodes: [root(1), kid('a1', 'running')], edges: [] });
    const first = edgeIn(c2, 'session', 'a1');
    check('an edge to a node that just arrived draws itself',
      first.classList.contains('cv-drawing'));

    c2.render({ nodes: [root(2), kid('a1', 'running'), kid('a2', 'starting', 'Plan')], edges: [] });
    check('only the new arrival draws; the edge that was already there does not',
      edgeIn(c2, 'session', 'a2').classList.contains('cv-drawing')
      && edgeIn(c2, 'session', 'a1') === first,
      'replaying a settled edge would perform the whole graph on every poll');

    // Opening is not arriving. A wire revealed by opening a group is new to
    // the DOM but its node is not new to the session, and treating the two the
    // same makes opening a 105-agent run perform itself.
    {
      const c4 = plain('unfold');
      const grouped = {
        nodes: [
          root(1),
          { id: 'w', kind: 'workflow', workflowId: 'wf-u', status: 'running', spawnDepth: 1, parentId: 'session' },
          kid('u1', 'running', 'Explore', 'w'), kid('u2', 'running', 'Plan', 'w'), kid('u3', 'done', 'tester', 'w'),
          kid('g1', 'done', 'Explore', 'u1'), kid('g2', 'done', 'Plan', 'u2'), kid('g3', 'done', 'tester', 'u3'),
        ],
        edges: [],
      };
      c4.render(grouped);
      c4.toggle('w');
      const pairs = [['u1', 'g1'], ['u2', 'g2'], ['u3', 'g3']];
      const hidden = pairs.every(([a, b]) => !edgeIn(c4, a, b));
      c4.toggle('w');
      check('unfolding a group reveals its edges rather than performing them',
        hidden && pairs.every(([a, b]) => edgeIn(c4, a, b) && !edgeIn(c4, a, b).classList.contains('cv-drawing')),
        hidden
          ? `${pairs.filter(([a, b]) => edgeIn(c4, a, b)?.classList.contains('cv-drawing')).length}`
            + ' of 3 revealed edges started drawing themselves'
          : 'folding did not take the wires behind the run out of the layer, so the test proves nothing');
    }

    // The draw and the flow both drive stroke-dashoffset, so if the draw did
    // not win outright the two would fight and the arrival would stutter.
    check('the draw-in outranks the flow it briefly replaces',
      /cv-draw/.test(String(asDrawing('live').get('animation') ?? '')),
      `resolved to ${JSON.stringify(asDrawing('live').get('animation') ?? null)}`);
    // With the animation gone, the pattern has to go with it — a dasharray on
    // the class itself would survive animation:none and freeze a live edge
    // solid, or half drawn, for as long as the class is on.
    const drawKf = animates(atRule(cssText, '@keyframes cv-draw'));
    const drawnStill = asDrawing('live', REDUCE);
    check('an arriving edge with motion off shows its own status dash, not a stuck one',
      drawKf.has('stroke-dasharray') && drawKf.has('stroke-dashoffset')
      && drawnStill.get('animation') === 'none'
      && drawnStill.get('stroke-dasharray') === '6px 7px',
      `keyframe animates ${[...drawKf].join('+')}; still resolves to `
      + `${JSON.stringify(drawnStill.get('stroke-dasharray') ?? null)}`);
  }

  /* -- 5. a live card is legibly alive ---------------------------------- */

  const cardRing = (state, media) => computed(rules, {
    tag: 'div',
    classes: new Set(['cv-node']),
    attrs: { 'data-kind': 'agent', 'data-state': state },
    pseudo: '::after',
  }, [chainFor(canvas)[0]], media);

  check('a running card carries a pulse', moving(cardRing('live')),
    `resolved animation: ${JSON.stringify(cardRing('live').get('animation') ?? null)}`);
  check('a finished card does not', !moving(cardRing('done')));
  const pulseKf = animates(atRule(cssText, '@keyframes cv-pulse'));
  check('the pulse animates opacity and nothing that has to be repainted',
    pulseKf.size === 1 && pulseKf.has('opacity'),
    `it animates ${[...pulseKf].join(', ')} — box-shadow or filter here rasterises every live card, every frame`);
  check('the ring the pulse fades is drawn whether or not it fades',
    Boolean(cardRing('live').get('box-shadow')),
    'a ring that lived only inside the keyframes would mean motion off is status gone');
  check('a card carries its state where CSS can reach it',
    canvas.els.get('live').dataset.state === 'live'
    && canvas.els.get('bad').dataset.state === 'failed');

  /* -- 6. motion off, status still readable ----------------------------- */

  const still = (id) => styleOf(edge('session', id), REDUCE);

  check('reduced motion stops the flowing edge', !moving(still('live')),
    `resolved animation: ${JSON.stringify(still('live').get('animation') ?? null)}`
    + ' — a media query adds no specificity, so this rule has to out-rank the one it cancels');
  check('reduced motion stops the arriving edge',
    asDrawing('live', REDUCE).get('animation') === 'none');
  check('reduced motion stops the card pulse', !moving(cardRing('live', REDUCE)));
  check('past the motion budget the card pulse stands still as well',
    !moving(computed(rules, { tag: 'div', classes: new Set(['cv-node']), attrs: { 'data-kind': 'agent', 'data-state': 'live' }, pseudo: '::after' },
      [{ tag: 'div', classes: new Set(['cv-root']), attrs: { 'data-motion': 'still' }, pseudo: null }])),
    'the rule that stops it has to out-rank the rule that starts it');
  check('a card born under reduced motion arrives placed rather than invisible',
    computed(rules, {
      tag: 'div', classes: new Set(['cv-node', 'cv-born']), attrs: { 'data-state': 'live' }, pseudo: null,
    }, [], REDUCE).get('opacity') === '1',
    'with the transition gone, opacity:0 is a card that never appears');

  // The point of the whole section. With every animation off, the states have
  // to remain five different pictures. Ended and stale are deliberately one of
  // those five — both mean "still and quiet" — and that is asserted rather
  // than assumed.
  const IDS = ['live', 'wake', 'fin', 'bad', 'over'];
  const signature = (id) => {
    const m = still(id);
    return JSON.stringify([m.get('stroke-width'), m.get('stroke-dasharray'), m.get('opacity'), m.get('stroke')]);
  };
  const sigs = new Map(IDS.map((id) => [id, signature(id)]));
  const clashes = [];
  for (let i = 0; i < IDS.length; i += 1) {
    for (let j = i + 1; j < IDS.length; j += 1) {
      if (sigs.get(IDS[i]) === sigs.get(IDS[j])) clashes.push(`${IDS[i]}=${IDS[j]}`);
    }
  }
  check('with motion off every status is still a different picture',
    clashes.length === 0,
    clashes.length
      ? `indistinguishable: ${clashes.join(', ')} — motion was the only channel carrying them`
      : [...sigs].map(([k, v]) => `${k} ${v}`).join(' | '));
  // Colour is never the only channel either: take it away and they still differ.
  const colourless = new Map(IDS.map((id) => {
    const m = still(id);
    return [id, JSON.stringify([m.get('stroke-width'), m.get('stroke-dasharray'), m.get('opacity')])];
  }));
  check('and with colour taken away as well, working, waking, finished and quiet still differ',
    new Set(['live', 'wake', 'fin', 'over'].map((id) => colourless.get(id))).size === 4,
    [...colourless].map(([k, v]) => `${k} ${v}`).join(' | '));
  check('ended and stale are one quiet state on purpose',
    edge('session', 'over').dataset.state === 'quiet' && edge('session', 'old').dataset.state === 'quiet');

  check('a failed branch is wrong in colour, not only in a word',
    strokeOf('bad') === 'var(--cv-fail)'
    && ['live', 'wake', 'fin', 'over'].every((id) => strokeOf(id) !== 'var(--cv-fail)'),
    `got ${strokeOf('bad')}`);
  check('killed and stopped read as the failure they are',
    ['failed', 'killed', 'stopped'].every((s) => {
      const c3 = plain(`s-${s}`);
      c3.render({ nodes: [root(1), kid('x', s)], edges: [] });
      return edgeIn(c3, 'session', 'x').dataset.state === 'failed' && c3.els.get('x').dataset.state === 'failed';
    }),
    'they come off the transcript verbatim and mean the same thing to a reader');

  /* -- 7. both themes --------------------------------------------------- */

  // The three blocks are the ones tokens.css is generated with: dark on a bare
  // :root, light when the system asks and the viewer has not chosen dark, light
  // when the viewer chose it. A token defined in two of them is a stroke that
  // keeps its dark weight on a light ground for one of the two ways to get there.
  const bareRoot = rules.filter((r) => r.sel === ':root' && r.media.length === 0);
  const lightSystem = rules.filter((r) => r.sel === ':root:not([data-theme="dark"])'
    && r.media.length === 1 && r.media[0] === '(prefers-color-scheme: light)');
  const lightChosen = rules.filter((r) => r.sel === ':root[data-theme="light"]' && r.media.length === 0);
  const used = new Set();
  const collect = (v) => { for (const m of String(v).matchAll(/var\((--[\w-]+)\)/g)) used.add(m[1]); };
  for (const id of IDS) for (const v of still(id).values()) collect(v);
  for (const v of cardRing('live').values()) collect(v);
  // --cv-fail is an alias of the status-fail token, which tokens.css themes; the
  // weights are the ones this file has to theme itself.
  const themed = [...used].filter((t) => t.startsWith('--cv-edge-'));
  check('a failed edge takes its colour from the status token',
    bareRoot.some((r) => r.decls.get('--cv-fail') === 'var(--status-fail)') && used.has('--cv-fail'),
    'an alias with a literal behind it would not follow the theme');
  check('the edge states are expressed as tokens rather than literals',
    themed.length >= 2 && used.has('--status-busy') && used.has('--edge-rest'),
    `tokens in play: ${[...used].join(', ') || 'none'}`);
  const orphan = themed.filter((t) => !bareRoot.some((r) => r.decls.has(t))
    || !lightSystem.some((r) => r.decls.has(t))
    || !lightChosen.some((r) => r.decls.has(t)));
  check('every edge token is defined on bare :root and redefined in both light blocks',
    orphan.length === 0,
    orphan.length ? `only partly defined: ${orphan.join(', ')}` : `${themed.length} tokens, three blocks each`);

  /* -- 8. the cost, measured -------------------------------------------- */

  // 250 nodes is a session size this project has reached. Two numbers decide
  // whether motion is affordable there: how much of the wire layer the canvas
  // rebuilds per poll, and how many strokes are moving at once. Every agent is
  // drawn as its own card here (no grouping, cards not chips), which is the
  // most the canvas can be asked to draw.
  {
    const N = 250;
    const TYPES = ['Explore', 'Plan', 'reviewer', 'tester'];
    const big = { nodes: [root(1)], edges: [] };
    for (let i = 0; i < N; i += 1) big.nodes.push(kid(`n${i}`, 'running', TYPES[i % TYPES.length]));

    let made = 0;
    const realNS = document.createElementNS;
    document.createElementNS = (ns, tag) => { if (tag === 'path') made += 1; return realNS(ns, tag); };

    const cBig = plain('big');
    cBig.setGroup('none');
    cBig.render(big);
    const firstPass = made;

    made = 0;
    const POLLS = 20;
    const t0 = process.hrtime.bigint();
    for (let i = 0; i < POLLS; i += 1) cBig.render(big);
    const perPoll = Number(process.hrtime.bigint() - t0) / 1e6 / POLLS;
    const churn = made;
    document.createElementNS = realNS;

    // This is the fix that made CSS-only motion possible at all. An element
    // that leaves the document restarts its animations, so rebuilding the wire
    // layer each poll reset every travelling dash twice a second — and every
    // frame of a drag, which calls the same code.
    check(`re-polling ${N} nodes rebuilds no edge elements`,
      churn === 0 && firstPass === N,
      `first pass built ${firstPass} paths (expected ${N}); ${POLLS} further polls built ${churn} more`);
    check(`the edge layer stays at ${N} elements across polls`,
      cBig.edgeEls.size === N, `${cBig.edgeEls.size} paths held`);
    check('the minimap keeps its boxes across polls too',
      cBig.mapRects.size === N + 1, `${cBig.mapRects.size} boxes for ${N + 1} drawn items`);

    // A dash travelling along a stroke is paint work, not compositor work, so
    // the honest limit is on how many strokes travel at once rather than on
    // how many exist.
    check('past the motion budget the canvas stops moving and keeps saying the same things',
      cBig.root.dataset.motion === 'still',
      `${N} running agents left data-motion at ${JSON.stringify(cBig.root.dataset.motion)}`);
    const bigEdge = edgeIn(cBig, 'session', 'n0');
    const stillBig = pathStyle(cBig, bigEdge);
    check('the budget actually reaches the stroke, not just the root element',
      stillBig.get('animation') === 'none',
      `resolved to ${JSON.stringify(stillBig.get('animation') ?? null)}`);
    check('a live edge under the budget still moves',
      moving(styleOf(edge('session', 'live'))) && canvas.root.dataset.motion === 'flow',
      `the small fixture is at ${JSON.stringify(canvas.root.dataset.motion)}`);
    check('the budget is a ceiling on motion, not on the graph',
      stillBig.get('stroke-dasharray') === '6px 7px'
      && stillBig.get('opacity') === 'var(--cv-edge-live)',
      'dropping the live styling along with the animation would hide which branches are alive');

    // The budget is only a real gate if it has an edge. Found by walking to it
    // rather than by naming the constant a second time — a threshold written
    // down twice is a threshold that drifts.
    const motionAt = (n) => {
      const c = plain(`edge-${n}`);
      c.setGroup('none');
      c.render({ nodes: [root(1), ...Array.from({ length: n }, (_, i) => kid(`k${i}`, 'running'))], edges: [] });
      return c.root.dataset.motion;
    };
    let last = 0;
    for (let n = 1; n <= 200 && motionAt(n) === 'flow'; n += 1) last = n;
    check('the budget has a sharp edge, and it is not at one or two agents',
      last >= 20 && last <= 160 && motionAt(last) === 'flow' && motionAt(last + 1) === 'still',
      `motion holds up to ${last} flowing edges and stops at ${last + 1}`);

    process.stdout.write(`     ${N} nodes, every one a card: ${cBig.edgeEls.size} paths held, ${churn} rebuilt`
      + ` over ${POLLS} polls, ${perPoll.toFixed(1)} ms of JS per poll\n`);
  }

  /* -- 9. the method six call sites depend on --------------------------- */

  // Deleted by accident in an earlier layout change while app.js kept calling
  // it in six places, so every fold and every panel resize threw. Call it
  // rather than grep for it.
  {
    let err = null;
    try { canvas.fitIfUntouched(); } catch (e) { err = e; }
    check('the canvas still answers the fit call the rest of the page makes',
      err === null && typeof canvas.fitIfUntouched === 'function',
      err ? `${err.name}: ${err.message}` : null);
  }

  dom();
}


/* ------------------------------------------------- §24 navigator tabs ---
   The three folding blocks became three tabs. What this section guards is the
   same class of defect it always did: a rule that hides something losing to a
   rule that displays it, and a choice that is lost because storage refused.
   It sits after §26 because it resolves the cascade with §26's resolver. */

// The kit has been bitten twice by a hide rule losing to a display rule:
// `[hidden]` lost to `display: grid`, and a `display: none` grid child stopped
// occupying its cell. So assert the cascade, not the intent.
{
  const html = read(path.join(STUDIO, 'web', 'index.html')) ?? '';
  const css = read(path.join(STUDIO, 'web', 'style.css')) ?? '';
  const app = read(path.join(STUDIO, 'web', 'app.js')) ?? '';

  for (const [tab, panel] of [['projects', 'sessions'], ['live', 'fleet'], ['machines', 'reach']]) {
    check(`the ${tab} tab has a control and the panel it shows`,
      new RegExp(`role="tab"[^>]*data-tab="${tab}"[^>]*aria-controls="${panel}"`).test(html)
      && new RegExp(`<div id="${panel}" class="nav-list" role="tabpanel"`).test(html)
      && new RegExp(`data-rail-tab="${tab}"`).test(html),
      'a tab with no panel wired to it switches nothing; the collapsed rail carries the same three');
  }
  check('the search box sits above the tabs and searches whichever one is showing',
    (html.match(/id="filter"/g) ?? []).length === 1
    && html.indexOf('id="filter"') < html.indexOf('role="tablist"')
    && /el\.filter\.addEventListener\('input', \(\) => \{[^}]*paintProjects\(\);[^}]*paintLive\(\);/.test(app),
    'a search that only reaches the first tab looks like a broken search on the second');

  // Every element the page ships hidden has to resolve to display:none against
  // the class that gives it a display.
  const tabRules = cssRules(css);
  // `hidden` the attribute, not the tail of `aria-hidden`.
  const hiddenOnes = [...html.matchAll(/<(\w+)\b([^>]*\s)hidden(?=[\s>])([^>]*)>/g)].map(([m, tag, pre, post]) => [m, tag, pre + post]).map(([, tag, attrs]) => ({
    tag,
    id: /\bid="([^"]+)"/.exec(attrs)?.[1] ?? tag,
    classes: (/\bclass="([^"]+)"/.exec(attrs)?.[1] ?? '').split(/\s+/).filter(Boolean),
  }));
  const stillShown = hiddenOnes.filter((h) => {
    const shown = computed(tabRules, { tag: h.tag, classes: new Set(h.classes), attrs: {}, pseudo: null }, []).get('display');
    const hidden = computed(tabRules, { tag: h.tag, classes: new Set(h.classes), attrs: { hidden: '' }, pseudo: null }, []).get('display');
    return shown !== undefined && hidden !== 'none';
  });
  const mustBeAmong = ['side-rail', 'fleet', 'reach', 'other-machines', 'inspector', 'chat', 'toast', 'menu', 'live-count'];
  const notSeen = mustBeAmong.filter((id) => !hiddenOnes.some((h) => h.id === id));
  check('a hidden panel stays hidden against the rule that lays it out',
    notSeen.length === 0 && !hiddenOnes.some((h) => h.tag === 'svg') && stillShown.length === 0,
    notSeen.length ? `the scan did not see: ${notSeen.join(', ')}`
      : stillShown.length ? `still displayed: ${stillShown.map((h) => h.id).join(', ')}`
      : `${hiddenOnes.length} elements ship hidden: ${hiddenOnes.map((h) => h.id).join(', ')}`);
  check('twin: a class that sets display with no [hidden] rule is caught', (() => {
    const rules = cssRules('.nav-list { display: flex; }');
    return computed(rules, { tag: 'div', classes: new Set(['nav-list']), attrs: { hidden: '' }, pseudo: null }, []).get('display') === 'flex';
  })(), 'this is the defect: the attribute alone does not win');

  check('the tab choice is remembered per browser',
    /store\.set\('crewforth-studio-nav-tab', navTab\)/.test(app)
    && /setTab\(store\.get\('crewforth-studio-nav-tab'\)/.test(app));
  check('a browser that refuses localStorage still switches tabs',
    /set\(k, v\) \{ try \{ localStorage\.setItem\(k, v\); \} catch/.test(app)
    && !/localStorage\.setItem\(/.test(app.replace(/set\(k, v\) \{ try \{ localStorage\.setItem\(k, v\); \} catch/, '')),
    'private mode throws on setItem; every write in app.js goes through the one guarded wrapper');
}

process.stdout.write('\n== §27 where everything on the graph goes ==\n');

/* The graph is a tree that reads left to right. Where each thing sits is
   decided by web/graph-plan.js, which touches no page, so most of this section
   calls it directly. The rest runs the canvas against the DOM stub and reads
   what it drew. What used to be here — three "readings" that redrew a card's
   words at a constant screen size as the canvas zoomed out — is gone: a crowd
   is now answered by grouping and density, and a zoomed-out canvas by the
   minimap and the attention list. The claims that guarded honesty were
   rewritten for the new picture, not dropped. */

{
  const dom = installDom();
  const gp = await import(`../../kit/studio/web/graph-plan.js?t=${Date.now()}`);
  const { Canvas } = await import(`../../kit/studio/web/canvas.js?plan=${Date.now()}`);
  const canvasSrc = read(path.join(STUDIO, 'web', 'canvas.js')) ?? '';
  const PAL = { measured: true, map: { Explore: { source: 'builtin' }, 'general-purpose': { source: 'builtin' }, 'crew-backend-expert': { source: 'kit' }, 'crew-test-expert': { source: 'kit' } } };

  const S = () => ({ id: 'session', kind: 'session', status: 'session', turns: 3, cwd: '/x', gitBranch: 'feat/x' });
  const A = (id, type, extra = {}) => ({ id, kind: 'agent', agentType: type, status: 'done', parentId: 'session', description: `task of ${id}`, ...extra });
  const RUN = (id, extra = {}) => ({ id, kind: 'workflow', workflowId: id.replace('wf:', ''), status: 'done', parentId: 'session', ...extra });
  const agentsOf = (nodes) => nodes.filter((n) => n.kind === 'agent').length;
  const at = (p, id) => p.items.find((it) => it.id === id);
  const boxes = (p) => new Map(p.items.map((it) => [it.id, `${it.x},${it.y}`]));
  const made = (nodes, name = 'plan') => {
    const c = new Canvas(document.createElement('div'), {});
    c.setPalette(PAL);
    c.setSession(`${name}-${Math.random().toString(36).slice(2)}`);
    c.render({ nodes, edges: [] });
    return c;
  };

  // The design's own first screen: seven agents, a run of four, and two grandchildren.
  const screenOne = () => {
    const n = [S(), A('e1', 'Explore', { startedAt: 1 }), A('e2', 'Explore', { startedAt: 2, status: 'starting' }),
      A('b', 'crew-backend-expert', { startedAt: 3 }), A('d', 'crew-database-expert', { startedAt: 4, status: 'running' }),
      A('f', 'crew-frontend-expert', { startedAt: 5, status: 'running' }), A('p', 'crew-performance-expert', { startedAt: 6, status: 'running' }),
      A('g', 'general-purpose', { startedAt: 7, status: 'ended' }), RUN('wf:audit', { startedAt: 8 })];
    for (const [i, t] of ['claude-code-guide', 'crew-review-agent', 'crew-security-expert', 'crew-test-expert'].entries()) {
      n.push(A(`w${i}`, t, { parentId: 'wf:audit', workflow: 'audit', startedAt: 10 + i, status: i === 0 ? 'failed' : 'done', errors: i === 0 ? 3 : 0 }));
    }
    n.push(A('k1', 'general-purpose', { parentId: 'b', startedAt: 20 }), A('k2', 'general-purpose', { parentId: 'w3', startedAt: 21 }));
    return n;
  };

  /* -- 1. a tree that reads left to right ------------------------------- */

  const one = gp.plan(screenOne(), {});
  const col = (p, d) => p.items.filter((it) => it.depth === d);
  check('the session is on the left, what it spawned in the next column, what those spawned in the one after',
    at(one, 'session').x < at(one, 'b').x && at(one, 'b').x < at(one, 'k1').x
    && new Set(col(one, 1).map((it) => it.x)).size === 1 && new Set(col(one, 2).map((it) => it.x)).size === 1,
    `columns at x ${[...new Set(one.items.map((it) => it.x))].sort((a, b) => a - b).join(', ')}`);
  const overlap = (p) => p.items.filter((a) => p.items.some((b) => a !== b && a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h));
  check('siblings stack downward and nothing overlaps',
    overlap(one).length === 0 && col(one, 1).every((it, i, a) => i === 0 || it.y >= a[i - 1].y + a[i - 1].h),
    overlap(one).length ? `overlapping: ${overlap(one).map((it) => it.id).join(', ')}` : `${one.items.length} boxes`);
  check('a child starts level with what spawned it',
    Math.abs((at(one, 'k1').y + at(one, 'k1').h / 2) - (at(one, 'b').y + at(one, 'b').h / 2)) < 1,
    `parent centre ${at(one, 'b').y + at(one, 'b').h / 2}, child centre ${at(one, 'k1').y + at(one, 'k1').h / 2}`);
  check('every wire leaves a right edge and enters a left edge',
    one.edges.length === one.items.length - 1 && one.edges.every((e) => e.to.x > e.from.x),
    `${one.edges.length} wires for ${one.items.length} boxes`);
  {
    const e = one.edges.find((x) => x.target === 'k2');
    const run = at(one, 'wf:audit');
    const cell = run.cells.find((c) => c.id === 'w3');
    check('a wire out of a run\'s member leaves from that member\'s row',
      Math.abs(e.from.y - (run.y + cell.y + cell.h / 2)) < 1 && e.source === 'w3',
      `wire leaves at y ${e.from.y}; the row's centre is ${run.y + cell.y + cell.h / 2}`);
  }
  check('the measures are the design\'s: session 200x84, card 248x64, 56 between columns, 12 between siblings',
    at(one, 'session').w === 200 && at(one, 'session').h === 84 && at(one, 'b').w === 248 && at(one, 'b').h === 64
    && at(one, 'b').x - (at(one, 'session').x + 200) === 56 && col(one, 1)[1].y - (col(one, 1)[0].y + col(one, 1)[0].h) === 12);

  /* -- 2. arrival appends ------------------------------------------------ */

  {
    const nodes = screenOne();
    const seq = gp.sequence(nodes);
    // Cards throughout: Auto turning cards into chips is its own reflow, asserted in its own section.
    const before = gp.plan(nodes, { seq, density: 'comfortable' });
    // A new agent whose clock says it started BEFORE the others: arrival is what counts, not the timestamp.
    const more = [...nodes, A('late', 'crew-docs-agent', { startedAt: 0 })];
    gp.sequence(more, seq);
    const after = gp.plan(more, { seq, density: 'comfortable', sessionY: before.sessionY });
    const was = boxes(before);
    const moved = [...was].filter(([id, xy]) => boxes(after).get(id) !== xy).map(([id]) => id);
    check('a new agent lands at the end of its column and nothing already drawn moves',
      moved.length === 0 && col(after, 1).at(-1).id === 'late',
      moved.length ? `moved: ${moved.join(', ')}` : `${was.size} boxes held; the new one is last of ${col(after, 1).length}`);

    const grown = [...more, A('w9', 'crew-docs-agent', { parentId: 'wf:audit', workflow: 'audit', startedAt: 99 })];
    gp.sequence(grown, seq);
    const after2 = gp.plan(grown, { seq, density: 'comfortable', sessionY: before.sessionY });
    const runY = at(after2, 'wf:audit').y;
    const above = col(after, 1).filter((it) => it.y < at(after, 'wf:audit').y).map((it) => it.id);
    check('a run that gains a member grows; what sits above it stays, what sits below it is pushed down',
      at(after2, 'wf:audit').h > at(after, 'wf:audit').h && runY === at(after, 'wf:audit').y
      && above.every((id) => boxes(after2).get(id) === boxes(after).get(id))
      && at(after2, 'late').y > at(after, 'late').y,
      `run ${at(after, 'wf:audit').h} -> ${at(after2, 'wf:audit').h} tall; ${above.length} boxes above it held`);
    check('twin: without the remembered order, the same arrival would have been sorted in by its timestamp',
      gp.plan(more, { seq: gp.sequence(more), density: 'comfortable' }).items.filter((it) => it.depth === 1)[0].id === 'late',
      'so it is the sequence, not luck, that kept the column still');
  }

  /* -- 3. zoom moves nothing -------------------------------------------- */

  {
    const c = made(screenOne(), 'zoom');
    const snap = () => JSON.stringify([...c.pos]) + [...c.els.values()].map((el) => el.box).join('|');
    const first = snap();
    for (const k of [0.25, 0.4, 0.75, 1, 1.6, 2, 0.5]) c.zoomTo(k);
    check('zooming across the whole range moves no card and resizes none',
      snap() === first, 'positions are a function of the nodes and the viewer\'s choices, never of the view');
    check('a zoom is one transform on the viewport and nothing per card',
      /scale\(0\.5\)/.test(c.viewport.style.transform) && !canvasSrc.includes("setProperty('--k'"),
      `transform: ${c.viewport.style.transform}`);
    c.zoomTo(0.01);
    const low = c.view.k;
    c.zoomTo(9);
    check('the zoom runs from 25% to 200% and no further', low === 0.25 && c.view.k === 2 && gp.ZOOM.min === 0.25 && gp.ZOOM.max === 2,
      `floor ${low}, ceiling ${c.view.k}`);
    c.fit();
    check('fitting never enlarges past 100%', c.view.k <= 1 && gp.fitZoom(100, 100, 2000, 2000) === 1);
  }

  /* -- 4. grouping ------------------------------------------------------- */

  {
    const nodes = screenOne();
    const kinds = (p) => p.items.filter((it) => it.kind === 'group').map((it) => `${it.type}:${it.label}`).join(' | ');
    const run = gp.plan(nodes, { group: 'run', density: 'comfortable' });
    const type = gp.plan(nodes, { group: 'type', density: 'comfortable' });
    const parent = gp.plan([...nodes, A('k3', 'Explore', { parentId: 'b', startedAt: 30 })], { group: 'parent', density: 'comfortable' });
    const none = gp.plan(nodes, { group: 'none', density: 'comfortable' });
    check('by workflow run: a run is one group holding its agents',
      kinds(run) === 'run:audit' && at(run, 'wf:audit').members.length === 4 && at(run, 'wf:audit').open === true, kinds(run));
    check('by agent type: siblings of one type are a group too, folded until asked for',
      kinds(type) === 'type:Explore | run:audit' && at(type, 'type:session:Explore').count === 2
      && at(type, 'type:session:Explore').open === false, kinds(type));
    check('by parent: an agent\'s children are a group',
      kinds(parent).includes('parent:Backend → 2'), kinds(parent));
    check('with no grouping a run is an ordinary card and its agents come after it',
      kinds(none) === '' && at(none, 'wf:audit').kind === 'run-card' && at(none, 'w0').x > at(none, 'wf:audit').x, kinds(none) || 'no groups');
    check('a folded group is one card; open, it holds its members where the card was',
      at(type, 'type:session:Explore').h === 64 && at(run, 'wf:audit').cells.length === 4
      && at(run, 'wf:audit').x === at(run, 'b').x);
    const folded = gp.plan(nodes, { group: 'run', density: 'comfortable', open: new Map([['wf:audit', false]]) });
    check('folding a group takes what its members spawned with it',
      !at(folded, 'k2') && at(run, 'k2') && folded.edges.every((e) => e.target !== 'k2'));
    check('a group\'s wire is alive or at rest, never red: what failed inside it is said inside it',
      run.edges.find((e) => e.target === 'wf:audit').state === 'done' && at(run, 'wf:audit').status === 'failed'
      && at(run, 'wf:audit').counts.failed === 1);
    const big = [S(), RUN('wf:big'), ...Array.from({ length: 40 }, (_, i) => A(`m${i}`, 'Explore', { parentId: 'wf:big', workflow: 'big', startedAt: i }))];
    const grid = at(gp.plan(big, { density: 'comfortable' }), 'wf:big');
    check('a large open group lays its members out as a grid, four across at most',
      grid.grid === true && grid.cols === 4 && grid.w > 248 && grid.cells.length === 40
      && new Set(grid.cells.map((c) => c.x)).size === 4, `${grid.cols} columns, ${grid.w}px wide`);
  }

  /* -- 5. Auto density, and where its thresholds come from --------------- */

  {
    const many = (n, type = (i) => `type-${i}`) => [S(), ...Array.from({ length: n }, (_, i) => A(`a${i}`, type(i), { startedAt: i }))];
    const s1 = gp.plan(screenOne(), {});
    check('the design\'s own first screen stays cards: thirteen agents, nothing folded, nothing shrunk',
      s1.density === 'comfortable' && s1.stacked === false && s1.drawn === agentsOf(screenOne()) - 0
      && s1.height <= gp.AUTO.tallest, `${s1.density}, ${s1.drawn} drawn, ${s1.height}px tall (limit ${gp.AUTO.tallest})`);
    // The limit is not a number someone liked. It is the reference canvas, less the fit margin, at the smallest
    // zoom a card's 12px name still reads at.
    const derived = (724 - 2 * gp.ZOOM.pad) / 0.75;
    check('the height limit is the reference canvas at the smallest readable zoom',
      Math.abs(gp.AUTO.tallest - derived) < 2 && gp.fitZoom(900, gp.AUTO.tallest, 2000, 724) >= 0.75
      && gp.fitZoom(900, gp.AUTO.tallest + 40, 2000, 724) < 0.75,
      `(724 - ${2 * gp.ZOOM.pad}) / 0.75 = ${derived.toFixed(0)}; limit ${gp.AUTO.tallest}`);
    let last = 1;
    while (gp.plan(many(last + 1), {}).density === 'comfortable') last += 1;
    check('cards stay cards up to the limit and become chips one agent past it',
      gp.plan(many(last), {}).height <= gp.AUTO.tallest && gp.plan(many(last + 1), { density: 'comfortable' }).height > gp.AUTO.tallest
      && gp.plan(many(last + 1), {}).density === 'compact' && last >= 9 && last <= 13,
      `${last} distinct agents are cards (${gp.plan(many(last), {}).height}px); ${last + 1} are chips`);
    // Nine agents of ONE type fit as cards, so they are shown as nine cards: folding them would hide the tasks
    // of a session that had room for every one.
    const nineAlike = gp.plan(many(9, () => 'Explore'), {});
    check('nothing is folded away while the open picture is short enough to read',
      nineAlike.stacked === false && nineAlike.drawn === 9 && nineAlike.items.every((it) => it.kind !== 'group'),
      `9 Explore agents: ${nineAlike.drawn} drawn, stacked ${nineAlike.stacked}`);
    const crowd = many(24, (i) => (i < 20 ? ['Explore', 'general-purpose'][i % 2] : `solo-${i}`));
    const stacked = gp.plan(crowd, {});
    check('too tall, and agents of one type fold together first: cards survive if that is enough',
      stacked.stacked === true && stacked.density === 'comfortable'
      && stacked.items.filter((it) => it.kind === 'group' && it.type === 'type').length === 2 && stacked.height <= gp.AUTO.tallest,
      `${stacked.drawn} drawn in ${stacked.items.length - 1} boxes, ${stacked.height}px, ${stacked.density}`);
    check(`a pair is not a crowd: folding starts at ${gp.AUTO.stackAt} of a type`,
      gp.AUTO.stackAt === 3 && !gp.plan(many(30, (i) => (i < 2 ? 'Explore' : `solo-${i}`)), {}).items.some((it) => it.kind === 'group'));
    check('still too tall, and cards become chips', gp.plan(many(16), {}).density === 'compact'
      && gp.plan(many(16), {}).items.find((it) => it.id === 'a0').h === 36);
    check('Comfortable and Compact are the viewer\'s word and are never overridden',
      gp.plan(many(60), { density: 'comfortable' }).density === 'comfortable'
      && gp.plan(many(60), { density: 'comfortable' }).stacked === false
      && gp.plan(many(2), { density: 'compact' }).density === 'compact');
    check('None means none: nothing is folded together under it, at any size',
      gp.plan(many(40, () => 'Explore'), { group: 'none' }).items.every((it) => it.kind !== 'group'));
    // A session that opens too tall even as chips starts with its largest groups folded.
    const huge = [S()];
    for (let r = 0; r < 3; r += 1) {
      huge.push(RUN(`wf:r${r}`, { startedAt: r }));
      for (let i = 0; i < [60, 30, 4][r]; i += 1) huge.push(A(`r${r}-${i}`, 'Explore', { parentId: `wf:r${r}`, workflow: `r${r}`, startedAt: 100 * r + i }));
    }
    const folds = gp.crowdFolds(huge, {});
    const opened = gp.plan(huge, { open: new Map(folds.map((id) => [id, false])) });
    check('a session that opens too tall even as chips starts with its largest groups folded, largest first',
      folds[0] === 'wf:r0' && !folds.includes('wf:r2') && opened.height <= gp.AUTO.tallest,
      `folded ${folds.join(', ')}; ${opened.height}px`);
    check('a session that fits folds nothing', gp.crowdFolds(screenOne(), {}).length === 0
      && gp.crowdFolds(huge, { density: 'comfortable' }).length === 0);
  }

  /* -- 6. 250 nodes ------------------------------------------------------- */

  {
    const TYPES = ['Explore', 'general-purpose', 'crew-backend-expert', 'crew-test-expert', 'reviewer', 'Plan'];
    const big = [S()];
    for (let r = 0; r < 5; r += 1) {
      big.push(RUN(`wf:run-${r}`, { startedAt: r }));
      for (let i = 0; i < 20; i += 1) big.push(A(`w${r}-${i}`, TYPES[i % 6], { parentId: `wf:run-${r}`, workflow: `run-${r}`, startedAt: 10 + r * 20 + i, status: i % 4 === 0 ? 'running' : 'done' }));
    }
    for (let i = 0; i < 150; i += 1) big.push(A(`a${i}`, TYPES[i % 6], { startedAt: 500 + i, status: i % 31 === 0 ? 'failed' : 'done' }));
    const t0 = process.hrtime.bigint();
    const folds = gp.crowdFolds(big, {});
    const p = gp.plan(big, { open: new Map(folds.map((id) => [id, false])) });
    const planMs = Number(process.hrtime.bigint() - t0) / 1e6;
    check('250 agents open as a picture short enough to read, with every agent accounted for',
      agentsOf(big) === 250 && p.height <= gp.AUTO.tallest && p.items.length < 40
      && p.items.filter((it) => it.kind === 'group').reduce((n, it) => n + it.members.length, 0) === 250,
      `${p.items.length} boxes, ${p.height}px tall, ${p.density}; planned in ${planMs.toFixed(1)} ms`);
    const c = made(big, 'big');
    const t1 = process.hrtime.bigint();
    for (let i = 0; i < 20; i += 1) c.render({ nodes: big, edges: [] });
    const pollMs = Number(process.hrtime.bigint() - t1) / 1e6 / 20;
    c.expandAll();
    const openEls = c.els.size + c.cellEls.size;
    check('with everything expanded all 250 are drawn, each one a member of its group',
      c.cellEls.size === 250 && c.drawn === 250, `${c.els.size} boxes and ${c.cellEls.size} members`);
    // A poll that changed nothing must write nothing: each element remembers what it last drew.
    const writes = [];
    for (const el of [...c.els.values(), ...c.cellEls.values()]) {
      const real = el.setAttribute.bind(el);
      el.setAttribute = (k, v) => { writes.push(k); real(k, v); };
    }
    c.render({ nodes: big, edges: [] });
    check('a poll that changed nothing writes nothing to any card', writes.length === 0,
      `${writes.length} attribute writes across ${openEls} elements`);
    const changed = big.map((n) => (n.id === 'a3' ? { ...n, status: 'failed' } : n));
    c.render({ nodes: changed, edges: [] });
    check('a poll that changed one agent writes to that agent and its group only',
      writes.length > 0 && writes.length <= 4, `${writes.length} attribute writes`);
    process.stdout.write(`     250 agents: ${p.items.length} boxes as opened, ${planMs.toFixed(1)} ms to plan, ${pollMs.toFixed(1)} ms of JS per unchanged poll\n`);

    /* -- 7. every card says what it is, to everyone ---------------------- */

    const all = [...c.els.values(), ...c.cellEls.values()];
    const unnamed = all.filter((el) => !el.getAttribute('aria-label'));
    check('every card names itself for a screen reader, whatever it is drawn as',
      unnamed.length === 0 && all.length > 250
      && /^Explore, (Running|Done), task of w0-0 \(Claude Code built-in agent\)$/.test(c.cellEls.get('w0-0').getAttribute('aria-label')),
      `${all.length - unnamed.length} of ${all.length} carried an aria-label; one reads ${JSON.stringify(c.cellEls.get('w0-0').getAttribute('aria-label'))}`);
    check('status is never colour alone: every member carries its word beside its dot',
      [...c.cellEls.values()].every((el) => el.parts.word.textContent.length > 2 && el.parts.dot.dataset.tone));
  }

  {
    const c = made([S(), A('k', 'crew-backend-expert', { status: 'running' }), A('b', 'Explore'), A('u', 'someone-elses-agent'),
      A('z', 'Explore', { status: 'hibernating' })], 'identity');
    c.setIcons({ builtin: '<svg data-file="builtin"></svg>' });
    const tile = (id) => c.els.get(id).parts.tile;
    check('whose agent it is, is said by its mark: Crewforth\'s chevrons, or the one file for everyone else',
      tile('k').dataset.source === 'kit' && /chevron-3/.test(tile('k').innerHTML)
      && tile('b').dataset.source === 'builtin' && tile('b').innerHTML === '<svg data-file="builtin"></svg>');
    check('an agent type nobody declared is marked as unrecognised, never quietly drawn as built-in',
      tile('u').dataset.source === 'unknown' && /does not recognise/.test(tile('u').title)
      && /does not recognise/.test(c.els.get('u').getAttribute('aria-label'))
      && cssRules(read(path.join(STUDIO, 'web', 'style.css')) ?? '').some((r) => r.sel === '.cv-tile[data-source="unknown"]::after' && r.decls.get('content') === "'?'"),
      `source ${tile('u').dataset.source}; title ${JSON.stringify(tile('u').title)}`);
    check('a status nobody recognises keeps its own word and gets no colour',
      c.els.get('z').parts.pill.word.textContent === 'hibernating' && c.els.get('z').parts.pill.dot.dataset.tone === 'none'
      && c.els.get('z').dataset.state === 'unknown' && c.els.get('z').parts.pill.el.classList.contains('cv-unknown'));
    check('the mark for other agents lives in one file and nowhere in the canvas',
      fs.existsSync(path.join(WEB_ROOT, 'icons', 'builtin.svg'))
      && /currentColor/.test(read(path.join(WEB_ROOT, 'icons', 'builtin.svg')) ?? '')
      && !/builtin:\s*'<(svg|g)/.test(canvasSrc) && /setIcons\(\{ builtin: svg \}\)/.test(read(path.join(WEB_ROOT, 'app.js')) ?? ''),
      'replacing it is replacing web/icons/builtin.svg');

    const unread = new Canvas(document.createElement('div'), {});
    unread.setPalette({ measured: false, reason: 'no agents directory beside the panel', map: {} });
    unread.setSession('unread');
    unread.render({ nodes: [S(), A('k', 'crew-backend-expert'), A('b', 'Explore')], edges: [] });
    check('a palette that could not be read makes every agent unrecognised, and says why',
      ['k', 'b'].every((id) => unread.els.get(id).parts.tile.dataset.source === 'unknown'
        && /not measured — no agents directory beside the panel/.test(unread.els.get(id).parts.tile.title)),
      unread.els.get('k').parts.tile.title);
  }

  /* -- 8. what needs someone stays in view ------------------------------- */

  {
    const nodes = screenOne().map((n) => (n.id === 'd' ? { ...n, status: 'killed', endedAt: 50 } : n.id === 'w0' ? { ...n, endedAt: 90 } : n));
    const list = gp.attention(nodes, new Set(['f']));
    check('the attention list is who is waiting on the viewer, then who failed, newest first',
      list.map((a) => `${a.id}:${a.tone}`).join() === 'f:waiting,w0:fail,d:fail', list.map((a) => `${a.id}:${a.tone}`).join());
    check('each entry says what happened, in words',
      list[0].says === 'waiting for you' && list[1].says === 'failed · 3 errors · in audit' && list[2].says === 'killed');
    check('nobody failing and nobody waiting is an empty list, and the strip takes no room',
      gp.attention(screenOne().map((n) => ({ ...n, status: n.kind === 'agent' ? 'done' : n.status })), new Set()).length === 0
      && /el\.attention\.hidden = list\.length === 0/.test(read(path.join(WEB_ROOT, 'app.js')) ?? ''));

    const c = made(nodes, 'attention');
    c.toggle('wf:audit');
    const picked = [];
    c.onSelect = (n) => picked.push(n?.id ?? null);
    const hiddenBefore = !c.cellEls.has('w0');
    c.zoomTo(0.25);
    const ok = c.focus('w0');
    check('going to a failed agent opens the group it is folded into, selects it, and comes close enough to read',
      hiddenBefore && ok && c.cellEls.has('w0') && c.selected === 'w0' && picked.at(-1) === 'w0' && c.view.k >= 1,
      `was hidden ${hiddenBefore}; zoom ${c.view.k}`);

    // Zoomed out to the floor a card's words cannot be read. What has to stay findable is where things are and
    // which of them need someone, and neither depends on the zoom.
    c.setWaiting(['f']);
    c.zoomTo(0.25);
    const tones = [...c.mapRects].map(([id, r]) => `${id}:${r.dataset.tone}`);
    check('at the smallest zoom the minimap still shows every box, and which ones need someone',
      c.mapRects.size === c.els.size && c.mapRects.get('f').dataset.tone === 'waiting'
      && c.mapRects.get('d').dataset.tone === 'fail' && c.mapRects.get('wf:audit').dataset.tone === 'fail'
      && c.mapRects.get('b').dataset.tone === 'none' && c.mapEl.hidden === false,
      tones.filter((t) => !t.endsWith(':none')).join(', '));
    check('an agent waiting on the viewer says so on its card, its wire and the map',
      c.els.get('f').dataset.state === 'waiting' && c.els.get('f').parts.pill.word.textContent === 'Needs you'
      && c.edgeEls.get(['session', 'f'].join(String.fromCharCode(0))).dataset.state === 'waiting');
    const frame = () => ['x', 'y', 'width', 'height'].map((k) => c.mapFrame.getAttribute(k)).join(',');
    const f1 = frame();
    c.view.x -= 300;
    c.applyView();
    check('the minimap\'s frame follows the pane', frame() !== f1, `${f1} -> ${frame()}`);
  }

  /* -- 9. a click does what the card says -------------------------------- */

  {
    const nodes = [...screenOne(), A('e3', 'Explore', { startedAt: 40 })];
    const c = new Canvas(document.createElement('div'), {});
    c.setPalette(PAL);
    c.setSession('clicks');
    c.setGroup('type');
    const picked = [];
    c.onSelect = (n) => picked.push(n?.id ?? null);
    c.render({ nodes, edges: [] });
    const stack = c.els.get('type:session:Explore');
    check('a folded group says what a click will do', /Click to show 3 agents/.test(stack.title)
      && stack.parts.fold.getAttribute('aria-label') === 'Open Explore × 3');
    stack.emit('click');
    check('a group opens when its card is clicked, not only its small control',
      c.cellEls.has('e1') && c.cellEls.has('e3') && picked.length === 0,
      `${c.cellEls.size} members drawn after the click`);
    c.els.get('session').emit('click');
    check('the session selects rather than folds when its card is clicked: it is the conversation',
      picked.at(-1) === 'session' && c.els.size > 3 && c.els.has('b'), `selected ${picked.at(-1)}; ${c.els.size} boxes still drawn`);
    c.cellEls.get('e2').emit('click');
    const key = ['session', 'type:session:Explore'].join(String.fromCharCode(0));
    check('a member selects itself, and the way to it from the session is marked',
      picked.at(-1) === 'e2' && c.cellEls.get('e2').classList.contains('cv-selected')
      && c.edgeEls.get(key).classList.contains('cv-path'));
    const menus = [];
    c.onMenu = (n, where) => menus.push([n?.id, where.x]);
    c.els.get('b').emit('contextmenu', { clientX: 40, clientY: 50 });
    check('a right click on an agent asks the page for its menu', menus.length === 1 && menus[0][0] === 'b' && menus[0][1] === 40);
    c.setFocus('b');
    check('focusing a branch shows what led to it and what it spawned, and nothing else',
      [...c.els.keys()].sort().join() === 'b,k1,session' && c.state().focus === 'Backend',
      [...c.els.keys()].join(', '));
    c.setFocus(null);
    check('and letting go of the focus brings the rest back', c.els.has('wf:audit') && c.state().focus === null);
  }

  /* -- 9b. roles on screen, and an agent group that opens beside itself --- */

  {
    const nm = await import(`../../kit/studio/web/names.js?t=${Date.now()}`);
    const kitTypes = fs.readdirSync(path.join(PAYLOAD, 'agents')).filter((f) => f.endsWith('.md')).map((f) => f.slice(0, -3));
    const roles = kitTypes.map(nm.roleName).sort().join(', ');
    check('each of the kit\'s agents is shown by its role, without the prefix and the suffix its file has',
      roles === 'Backend, Commit, Database, DevOps, Frontend, Performance, Planner, Privacy, Review, Security, Session Manager, Test',
      roles);
    check('a built-in agent is shown by its words, and a name that is not hyphenated words is left as it came',
      nm.roleName('general-purpose') === 'General Purpose' && nm.roleName('Explore') === 'Explore'
      && nm.roleName('unknown agent') === 'unknown agent' && nm.shownType({}) === 'unknown agent' && nm.roleName('crew-') === 'crew-');
    check('hovering says the type as it is declared and the task in full',
      nm.hoverOf({ agentType: 'crew-test-expert', description: 'Prove both keys verify' }) === 'crew-test-expert\nProve both keys verify'
      && nm.hoverOf({ agentType: 'Explore' }) === 'Explore' && nm.hoverOf({}) === '');

    const nodes = [...screenOne(), A('e3', 'Explore', { startedAt: 40 }), A('b2', 'crew-backend-expert', { startedAt: 41 })];
    const open = new Map([['type:session:Explore', true]]);
    const down = gp.plan(nodes, { group: 'type', density: 'comfortable', open });
    const side = gp.plan(nodes, { group: 'type', density: 'comfortable', open, aside: true });
    const at = (p, id) => p.items.find((it) => it.id === id);
    const g = at(side, 'type:session:Explore');
    const members = side.items.filter((it) => it.member && it.parent === g);
    check('several agents of one type are one card: the role is its name, the number a badge, the type its key',
      g.label === 'Explore' && g.count === 3 && at(side, 'type:session:crew-backend-expert').label === 'Backend'
      && at(side, 'type:session:crew-backend-expert').real === 'crew-backend-expert');
    check('in a window with room an agent group opens beside itself: it stays a card, and its agents are the next column',
      g.open === true && g.boxed === false && g.h === gp.SIZE.card.h && g.cells === null && members.length === 3
      && members.every((m) => m.kind === 'agent' && m.depth === g.depth + 1 && m.x > g.x + g.w)
      && side.edges.filter((e) => e.source === g.id).length === 3,
      `${members.length} agents beside the card, at x ${members.map((m) => m.x).join(', ')} against the card's ${g.x}`);
    check('without the room it opens downward as before: a container that holds its members',
      at(down, 'type:session:Explore').boxed === true && at(down, 'type:session:Explore').cells.length === 3
      && at(down, 'type:session:Explore').h > gp.SIZE.card.h && !down.items.some((it) => it.member));
    check('opened either way the same agents are counted once',
      side.drawn === down.drawn, `${side.drawn} beside, ${down.drawn} downward`);
    check('a folded agent group is the same card whichever way it would open',
      at(gp.plan(nodes, { group: 'type', density: 'comfortable', aside: true }), 'type:session:Explore').boxed === false
      && !gp.plan(nodes, { group: 'type', density: 'comfortable', aside: true }).items.some((it) => it.member));

    const c = new Canvas(document.createElement('div'), {});
    c.setPalette(PAL);
    c.setSession('aside');
    c.setGroup('type');
    c.setAside(true);
    c.render({ nodes, edges: [] });
    const explore = c.els.get('type:session:Explore');
    check('the card carries the badge, and the type as it is declared on hover',
      explore.parts.name.textContent === 'Explore' && explore.parts.sub.textContent === '× 3'
      && c.els.get('type:session:crew-backend-expert').parts.name.title === 'crew-backend-expert'
      && explore.parts.fold.getAttribute('aria-label') === 'Open Explore × 3');
    explore.emit('click');
    check('a click opens the group beside itself: its agents are cards of their own',
      c.els.has('e1') && c.els.has('e3') && !c.cellEls.has('e1') && c.els.get('type:session:Explore').dataset.aside === 'true',
      `${[...c.els.keys()].filter((k) => /^e\d/.test(k)).join(', ')} drawn as cards`);
    check('an agent\'s card says its task in full on hover',
      c.els.get('e1').parts.task.title === 'task of e1' && c.els.get('e1').parts.name.title === 'Explore');
    c.els.get('type:session:crew-backend-expert').emit('click');
    check('one agent group is open at a time: opening another folds the first',
      c.els.has('b2') && !c.els.has('e1') && c.els.get('type:session:Explore').dataset.aside === 'false',
      [...c.els.keys()].join(', '));
    c.expandAll();
    check('"Expand all" leaves agent groups to their own cards while they open beside themselves',
      !c.els.has('e1') && c.els.has('b2'));
    c.setAside(false);
    check('when the window narrows the open group is a container again',
      !c.els.has('b2') && c.cellEls.has('b2') && c.els.get('type:session:crew-backend-expert').classList.contains('cv-open'));
    check('the window decides which way: beside itself above the band where the navigator is a rail',
      /canvas\.setAside\(!railBand\.matches\);\s*railBand\.addEventListener\('change', \(\) => canvas\.setAside\(!railBand\.matches\)\);/.test(read(path.join(WEB_ROOT, 'app.js')) ?? ''));
  }

  /* -- 10. the viewer's own arrangement is kept --------------------------- */

  {
    const sessionId = `keep-${Date.now()}`;
    const c = new Canvas(document.createElement('div'), {});
    c.setPalette(PAL);
    c.setSession(sessionId);
    c.render({ nodes: screenOne(), edges: [] });
    c.setGroup('type');
    c.toggle('wf:audit');
    const again = new Canvas(document.createElement('div'), {});
    again.setPalette(PAL);
    again.setSession(sessionId);
    again.render({ nodes: screenOne(), edges: [] });
    check('the grouping and the folds are remembered per session',
      again.state().group === 'type' && again.lastPlan.items.find((it) => it.id === 'wf:audit').open === false
      && new Canvas(document.createElement('div'), {}).state().group === 'run');
    c.pinned.set('b', { x: 900, y: 40 });
    c.resetLayout();
    check('Reset layout forgets every hand-placed card', c.pinned.size === 0 && c.pos.get('b').x < 900);
    c.showLegend(false);
    check('the legend is shown until it is closed, and then stays closed',
      new Canvas(document.createElement('div'), {}).legendEl.hidden === true);
    c.showLegend(true);
    check('and comes back when asked for', new Canvas(document.createElement('div'), {}).legendEl.hidden === false
      && /e\.key === '\?'/.test(read(path.join(WEB_ROOT, 'app.js')) ?? ''));
  }

  /* -- 11. what is gone --------------------------------------------------- */

  check('the canvas has one direction and no on-canvas controls: they are in the toolbar',
    !/setFlow|cv-hud|data-act=/.test(canvasSrc) && !/crewforth-studio-flow/.test(canvasSrc)
    && ['tb-group', 'tb-density', 'tb-show', 'tb-expand', 'tb-fold', 'tb-zoom-out', 'tb-zoom', 'tb-zoom-in', 'tb-fit']
      .every((id) => (read(path.join(WEB_ROOT, 'index.html')) ?? '').includes(`id="${id}"`)));
  check('the three readings are gone: nothing in the canvas or the stylesheet depends on the zoom',
    !/data-lod|LABEL_BUDGET|LOD_/.test(canvasSrc) && !/var\(--k\)|data-lod/.test(read(path.join(STUDIO, 'web', 'style.css')) ?? ''));

  dom();
}


/* --------------------------------------------------------------- verdict */


process.stdout.write('\n== §28 the instance record — finding a panel that is already running ==\n');

/* The panel used to print its tokenised URL once, to one session's stdout, and
   keep the token nowhere else. A second session could see the port was taken but
   not that the holder was our own panel, and had no way to reach it — measured in
   the field, two sessions and one live panel that nobody could open.

   A state file answers that, and every assertion below is about NOT trusting it.
   Files outlive processes: a killed panel, a recycled port and a hand-edited
   record all produce a file that says a panel is there when none is. So the
   record is believed only when the port answers /api/health with the token it
   names AND reports the pid it names, and a record that fails is deleted rather
   than kept. The must-NOT-find cases are the point of the section; the one
   happy path is easy and would be green on its own with no checking at all. */

{
  const rtDir = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-inst-'));
  const prevRt = process.env.CREW_STUDIO_RUNTIME;
  process.env.CREW_STUDIO_RUNTIME = rtDir;
  const inst = await import('../../kit/studio/server/lib/instance.js');

  check('the record lives under the runtime directory the env var names',
    inst.statePath(7777) === path.join(rtDir, 'instance-7777.json'),
    inst.statePath(7777));

  // A fake panel: /api/health is all findRunning consults, and answering it here
  // keeps the section hermetic — no real server, no fixed port, nothing to leak.
  const http = await import('node:http');
  const fakePanel = (pid) => new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, pid }));
    });
    srv.listen(0, '127.0.0.1', () => resolve({ srv, port: srv.address().port }));
  });

  const live = await fakePanel(4242);
  await inst.writeState(live.port, { token: 'tok-abc', name: 'testbox', pid: 4242 });

  const found = await inst.findRunning(live.port);
  check('a live panel is found and its URL carries the recorded token',
    found?.url === `http://127.0.0.1:${live.port}/?token=tok-abc`, found?.url);
  check('the record survives being found (finding is not consuming)',
    fs.existsSync(inst.statePath(live.port)));

  // Same port, same file, a DIFFERENT process answering. A health response alone
  // is not identity: ports get recycled, and /api/health reports its own pid so
  // this comparison is possible at all.
  const mismatch = await inst.findRunning(live.port + 0) && null;
  await inst.writeState(live.port, { token: 'tok-abc', name: 'testbox', pid: 999999 });
  check('a record whose pid does not match the answering process is refused',
    (await inst.findRunning(live.port)) === null, String(mismatch));
  check('...and that stale record is removed rather than left to mislead the next start',
    !fs.existsSync(inst.statePath(live.port)));

  live.srv.close();

  // Nothing listening at all: the ordinary aftermath of a crash or a kill -9.
  const deadPort = live.port;
  await inst.writeState(deadPort, { token: 'tok-dead', name: 'ghost', pid: 4242 });
  check('a record with nothing listening behind it is refused',
    (await inst.findRunning(deadPort)) === null);
  check('...and it is removed too, so a crashed panel cleans up the next time anyone looks',
    !fs.existsSync(inst.statePath(deadPort)));

  check('no record at all reads as "not ours", not as an error',
    (await inst.findRunning(deadPort)) === null);

  // The token is a credential, so the mode is part of the contract and not a
  // detail. Windows has no POSIX mode bits — the file's protection there is that
  // it sits under the user's own profile — so the check states that rather than
  // pretending to pass.
  await inst.writeState(deadPort, { token: 'tok-mode', name: 'm', pid: 1 });
  if (process.platform === 'win32') {
    // This said "covered by: the Windows session" before anyone had asked whether it was, and it was not -- that
    // machine had no node and could not start the panel at all. It now names the coverer only for what was
    // actually measured there: icacls on the written record, and two panels handing back the same token. What
    // is STILL uncovered is the third question, whether a gentle stop clears the record: MSYS `kill -TERM`
    // cannot reach a Windows process at all ("No such process", separate pid spaces) and `taskkill` without
    // /F is refused by Windows, so a real console Ctrl-C could not be produced from that harness. A hard
    // `taskkill /F` does leave the record behind, which is expected -- no handler runs -- and the next panel
    // discards the stale pid and starts fresh, which was measured.
    notApplicable('the record holding the token is written 0600', 'POSIX mode bits are advisory on win32; the file inherits the user profile ACL instead — measured: SYSTEM, Administrators and the owner, no Everyone or Users, so weaker than 0600 and written down as such', 'windows-crew for the ACL and the shared-token path; NOBODY YET for whether a gentle stop clears the record');
  } else {
    const mode = fs.statSync(inst.statePath(deadPort)).mode & 0o777;
    check('the record holding the token is written 0600', mode === 0o600, mode.toString(8));
  }
  await inst.clearState(deadPort);
  check('clearState removes the record', !fs.existsSync(inst.statePath(deadPort)));

  fs.rmSync(rtDir, { recursive: true, force: true });
  if (prevRt === undefined) delete process.env.CREW_STUDIO_RUNTIME;
  else process.env.CREW_STUDIO_RUNTIME = prevRt;
}

process.stdout.write('\n');
if (pass + fail === 0) {
  // The branch that audits the harness itself. An empty run is a broken
  // measurement, not a clean bill of health.
  process.stdout.write('FAIL selfcheck ran zero assertions — the measurement is broken, not the code\n');
  process.exit(1);
}
if (fail) {
  process.stdout.write(`${failures.length} failure(s):\n`);
  for (const f of failures) process.stdout.write(`  - ${f}\n`);
}
// ---- the stream signature: what decides whether a status change ever reaches the panel ----
// Both of these were measured over a 45-second SSE capture against the previous version, with a synthetic
// session built on disk: an agent that goes quiet held `running` FOREVER (1 graph frame in 150 s), and three
// writes to a workflow agent's transcript produced NO frame at all. Those captures proved the defects; these
// assertions are what stops them coming back, because a two-minute timing test is one nobody runs twice.
{
  const sigHome = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-studio-sig-'));
  const sess = { file: path.join(sigHome, 's.jsonl'), subagentsDir: path.join(sigHome, 'subagents') };
  fs.writeFileSync(sess.file, '{}\n');
  const wfDir = path.join(sess.subagentsDir, 'workflows', 'wf_1');
  fs.mkdirSync(wfDir, { recursive: true });
  const flat = path.join(sess.subagentsDir, 'agent-aflat.jsonl');
  const nested = path.join(wfDir, 'agent-anested.jsonl');
  fs.writeFileSync(flat, 'x\n');
  fs.writeFileSync(nested, 'x\n');

  // A workflow agent lives one level down. A flat readdir sees only the `workflows` DIRECTORY, whose size does
  // not move when a transcript inside it grows, so its updates were invisible to the stream.
  const beforeGrow = await signature(sess);
  fs.appendFileSync(nested, 'yy\n');
  const afterGrow = await signature(sess);
  check('stream signature notices a NESTED (workflow) agent growing',
    beforeGrow !== afterGrow, `${beforeGrow} vs ${afterGrow}`);
  check('stream signature names the nested file, not just its directory',
    afterGrow.includes('wf_1/agent-anested.jsonl'), afterGrow);

  // A STATUS CHANGES ON THE CLOCK ALONE: `running` becomes `stale` with nothing written. The signature must
  // therefore carry a coarse clock component while something is recent enough to still be called running, and
  // must NOT carry one otherwise — an idle session's signature has to stay as stable as it was before.
  const fresh = await signature(sess);
  check('a recent agent puts a clock bucket in the signature', /\|t:\d+$/.test(fresh), fresh);
  const old = Date.now() / 1000 - 600;
  fs.utimesSync(flat, old, old);
  fs.utimesSync(nested, old, old);
  const quiet = await signature(sess);
  check('an agent quiet for longer than the stale window does NOT', !/\|t:\d+/.test(quiet), quiet);

  // The bucket is derived from the clock rather than from a counter, so it is the same for two calls inside one
  // bucket. Pinned because a per-tick value would rebuild the graph 85 times a bucket for no new information.
  fs.utimesSync(flat, Date.now() / 1000, Date.now() / 1000);
  const a = await signature(sess);
  const b = await signature(sess);
  check('two calls inside one bucket agree', a === b, `${a} vs ${b}`);
  fs.rmSync(sigHome, { recursive: true, force: true });
}

/* --------------------------------------- §29 design tokens and the frame ---
   The redesign's first step. Every claim below is about one of three things:
   the colours come from the design system and from nowhere else, the frame has
   the spec's measures, and the theme the viewer picked is the one drawn.

   Each gate is run three ways where three ways exist. The real tree must pass.
   A twin with the defect planted must fail, and it is planted in memory, never
   in the checkout — a gate that edits the tree it guards is green for whoever
   ran it last. And on a machine without node this whole file does not run:
   verify.sh reports the step as SKIPPED, which CREW_VERIFY_STRICT turns red. */

process.stdout.write('\n== §29 design tokens and the frame ==\n');

{
  const gen = await import(`../gen-studio-tokens.mjs?t=${Date.now()}`);
  const tokenSrc = read(gen.SOURCE);
  const tokensCss = read(path.join(WEB_ROOT, 'tokens.css'));
  const styleCss = read(path.join(WEB_ROOT, 'style.css')) ?? '';
  const indexHtml = read(path.join(WEB_ROOT, 'index.html')) ?? '';
  const appJs = read(path.join(WEB_ROOT, 'app.js')) ?? '';
  const tokens = JSON.parse(tokenSrc ?? '{}');
  const clone = () => JSON.parse(tokenSrc);
  const noComments = (css) => css.replace(/\/\*[\s\S]*?\*\//g, '');

  /* -- 1. freshness ------------------------------------------------------ */

  const rendered = gen.render(tokens);
  check('tokens.css is byte for byte what the generator writes',
    tokensCss !== null && tokensCss === rendered,
    tokensCss === null ? 'kit/studio/web/tokens.css is missing'
      : `${Buffer.byteLength(tokensCss)} bytes on disk, ${Buffer.byteLength(rendered)} generated`
        + (tokensCss === rendered ? '' : ' — run: node packaging/gen-studio-tokens.mjs'));
  {
    // The twin: one colour changed in the source and nothing regenerated.
    const stale = clone();
    stale.color.tokens.find((t) => t.name === 'line').value.dark = '#262c3a';
    check('a token changed in the JSON and not regenerated is caught',
      gen.render(stale) !== tokensCss, 'the comparison would pass on anything if this were equal');
  }
  check('the generated file ends every line with LF and carries no CR',
    !/\r/.test(rendered) && rendered.endsWith('}\n'),
    'a CRLF checkout would otherwise differ from the generator on Windows alone');

  // A token the generator cannot place must stop the build, not be written as it came.
  const refuses = (mutate) => { const t = clone(); mutate(t); try { gen.render(t); return false; } catch { return true; } };
  check('a colour with no light value stops the generator',
    refuses((t) => { delete t.color.tokens.find((x) => x.name === 'ink').value.light; }));
  check('a reference to a colour that does not exist stops the generator',
    refuses((t) => { t.color.tokens.find((x) => x.name === 'chevron-3').value.dark = '{acent}'; }));
  check('a value that is neither #rrggbb nor a reference stops the generator',
    refuses((t) => { t.color.tokens.find((x) => x.name === 'ink').value.dark = 'red; } body { display: none'; }));
  check('the source as it stands does not', !refuses(() => {}));

  /* -- 2. both ways to light carry every colour -------------------------- */

  const themeGaps = (css) => {
    const rules = cssRules(css);
    const pick = (sel, media) => rules.find((r) => r.sel === sel
      && r.media.length === (media ? 1 : 0) && (!media || r.media[0] === media));
    const dark = pick(gen.DARK);
    const sys = pick(gen.LIGHT_SYSTEM, gen.LIGHT_SYSTEM_MEDIA);
    const chosen = pick(gen.LIGHT_CHOSEN);
    if (!dark || !sys || !chosen) return { colours: 0, gaps: ['a theme block is missing'] };
    const colours = tokens.color.tokens.map((t) => `--${t.name}`);
    const gaps = colours.filter((c) => !dark.decls.has(c) || !sys.decls.has(c) || !chosen.decls.has(c));
    const differ = colours.filter((c) => sys.decls.get(c) !== chosen.decls.get(c));
    return { colours: colours.length, gaps: gaps.concat(differ.map((c) => `${c} differs between the two light blocks`)) };
  };
  const real = themeGaps(tokensCss ?? '');
  check('every colour token is defined for dark and for both ways to light',
    real.colours === tokens.color.tokens.length && real.colours > 0 && real.gaps.length === 0,
    real.gaps.length ? real.gaps.join(', ') : `${real.colours} colours, three blocks each`);
  {
    // The twin: one colour dropped from the block the theme button selects.
    const cut = (tokensCss ?? '').replace(/(:root\[data-theme="light"\] \{[\s\S]*?)\n {2}--ink: [^;]+;/, '$1');
    const holed = themeGaps(cut);
    check('a colour missing from one light block is caught',
      cut !== tokensCss && holed.gaps.includes('--ink'), `reported: ${holed.gaps.join(', ') || 'nothing'}`);
  }

  /* -- 3. no colour literal outside tokens.css --------------------------- */

  // What counts as a colour literal: a hex of a colour's length, or a functional
  // notation with a number in it. In a stylesheet only declarations are read —
  // comments are prose, and `#fade` in a selector is an id. NOT seen: a named
  // colour (`white`), which no rule here can tell from a word.
  const HEX_RE = /(?<![&\w])#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})(?![\w-])/g;
  const FN_RE = /\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch)\(\s*[\d.]/g;
  const literals = (name, text) => {
    const out = [];
    if (name.endsWith('.css')) {
      const css = noComments(text);
      for (const m of css.matchAll(HEX_RE)) {
        // A value sits after the `:` of its declaration; a selector sits after `}` or `{`'s end.
        const before = css.slice(0, m.index);
        const at = Math.max(before.lastIndexOf('{'), before.lastIndexOf('}'), before.lastIndexOf(';'));
        if (before.slice(at + 1).includes(':') && before.lastIndexOf('{') > before.lastIndexOf('}')) out.push(m[0]);
      }
      for (const m of css.matchAll(FN_RE)) out.push(m[0]);
    } else {
      for (const m of text.matchAll(HEX_RE)) out.push(m[0]);
      for (const m of text.matchAll(FN_RE)) out.push(m[0]);
    }
    return out;
  };

  // There are no exceptions. There were four, all agent-identity colours in canvas.js; they went when colour
  // stopped carrying identity. The mechanism stays, for the twins below and for whoever needs one next: an
  // exception is one literal, in one file, once.
  const ALLOWED = {};

  const webFiles = walk(WEB_ROOT).map((f) => path.relative(WEB_ROOT, f).split(path.sep).join('/')).sort();
  const scanned = webFiles.filter((f) => f !== 'tokens.css');
  /** entries: [name, text]. An excepted literal is excepted once per file, not per occurrence. */
  const scan = (entries, allowed = ALLOWED) => {
    const found = [];
    const allowedSeen = [];
    for (const [f, text] of entries) {
      const seen = new Map();
      for (const lit of literals(f, text)) seen.set(lit, (seen.get(lit) ?? 0) + 1);
      for (const [lit, n] of seen) {
        if (allowed[f]?.[lit] && n === 1) allowedSeen.push(`${f} ${lit}`);
        else found.push(`${f} ${lit}${n > 1 ? ` ×${n}` : ''}`);
      }
    }
    return { found, allowedSeen };
  };
  const { found, allowedSeen } = scan(scanned.map((f) => [f, read(path.join(WEB_ROOT, f)) ?? '']));
  // The scanned set against the set that has to be scanned: every file the panel
  // serves except the generated one. "N files, 0 findings" says nothing if the
  // file that carries the colours is not among the N.
  const mustScan = ['app.js', 'canvas.js', 'chat.js', 'graph-plan.js', 'icons/builtin.svg', 'index.html', 'liveness.js', 'md.js', 'nav.js', 'style.css', 'theme.js'];
  const unscanned = mustScan.filter((f) => !scanned.includes(f));
  check('the colour scan reads every file the panel serves except tokens.css',
    unscanned.length === 0 && webFiles.includes('tokens.css') && scanned.length === webFiles.length - 1,
    unscanned.length ? `not scanned: ${unscanned.join(', ')}` : `${scanned.length} of ${webFiles.length} files: ${scanned.join(', ')}`);
  check('no colour literal in web/ outside tokens.css',
    found.length === 0,
    found.length ? found.join(' · ') : `0 literals in ${scanned.length} files; ${allowedSeen.length} named exceptions`);
  const allowedCount = Object.values(ALLOWED).reduce((n, o) => n + Object.keys(o).length, 0);
  check('no exception is left open: the four identity colours are gone from canvas.js',
    allowedCount === 0 && allowedSeen.length === 0
    && literals('canvas.js', read(path.join(WEB_ROOT, 'canvas.js')) ?? '').length === 0,
    `${allowedCount} exceptions listed; ${literals('canvas.js', read(path.join(WEB_ROOT, 'canvas.js')) ?? '').length} literals in canvas.js`);

  // Calibration, on inputs whose answer is known before the scan runs.
  const count = (name, text) => literals(name, text).length;
  check('twin: a hex added to style.css is caught',
    count('style.css', `${styleCss}\n.x { color: #ff00aa; }\n`) === count('style.css', styleCss) + 1
    && count('style.css', styleCss) === 0);
  check('twin: a short hex and an rgb() literal are caught too',
    count('style.css', '.x { border: 1px solid #abc; background: rgb(91 140 255 / 0.4); }') === 2);
  check('twin: a hex in a script is caught',
    count('app.js', `${appJs}\nel.style.color = '#1a2b3c';\n`) === count('app.js', appJs) + 1);
  {
    // The twins run on a table of their own, since the real one is empty.
    const table = { 'canvas.js': { '#5b8cff': 'a fixture exception' } };
    const once = scan([['canvas.js', "const a = '#5b8cff';"]], table);
    const twice = scan([['canvas.js', "const a = '#5b8cff';\nconst again = '#5b8cff';\n"]], table);
    check('twin: a second copy of an excepted literal is not excepted',
      once.found.length === 0 && once.allowedSeen.length === 1 && twice.found.join() === 'canvas.js #5b8cff ×2',
      `reported: ${twice.found.join(', ') || 'nothing'}`);
    const elsewhere = scan([['app.js', "const c = '#5b8cff';"]], table);
    check('twin: an excepted literal in another file is not excepted', elsewhere.found.join() === 'app.js #5b8cff');
  }
  check('calibration: what only looks like a colour is not counted',
    count('style.css', '/* was #0d1017 */ #fade { color: var(--ink); } #add:hover { top: 0; } .a { background: url(#abc123-grad); }') === 0
    && count('index.html', '<a href="#">x</a> &#9662; <use href="#icon-add"/>') === 0
    && count('app.js', 'const rgb = (h) => h; rgb(a); location.hash = "#top";') === 0,
    'a comment, an id selector, a url fragment, an entity, a function called rgb');

  /* -- 4. every var() resolves ------------------------------------------- */

  // A renamed token leaves `var(--old-name)` behind, which is not an error: the
  // declaration is dropped and the element is drawn with whatever it inherits.
  const defined = new Set();
  for (const css of [tokensCss ?? '', styleCss]) {
    for (const m of noComments(css).matchAll(/(?:^|[{;\s])(--[\w-]+)\s*:/g)) defined.add(m[1]);
  }
  // Set from script, per element or on the root, never in a stylesheet.
  const FROM_SCRIPT = ['--side-w', '--chat-w', '--edge-len', '--dock-h'];
  const scriptText = scanned.filter((f) => f.endsWith('.js')).map((f) => read(path.join(WEB_ROOT, f)) ?? '').join('\n');
  const notSet = FROM_SCRIPT.filter((v) => !scriptText.includes(`'${v}'`));
  check('every property expected from script is set by one', notSet.length === 0,
    notSet.length ? `never set: ${notSet.join(', ')}` : `${FROM_SCRIPT.join(', ')}`);
  const unresolved = (css) => [...new Set([...noComments(css).matchAll(/var\(\s*(--[\w-]+)/g)].map((m) => m[1]))]
    .filter((v) => !defined.has(v) && !FROM_SCRIPT.includes(v));
  const dangling = unresolved(styleCss);
  const usedVars = new Set([...noComments(styleCss).matchAll(/var\(\s*(--[\w-]+)/g)].map((m) => m[1]));
  check('every var() in style.css names a property that exists',
    dangling.length === 0 && usedVars.size > 20,
    dangling.length ? `undefined: ${dangling.join(', ')}` : `${usedVars.size} distinct properties`);
  check('twin: a var() left behind by a rename is caught',
    unresolved(`${styleCss}\n.x { color: var(--surface-2); }`).join() === '--surface-2');
  check('index.html loads the tokens before the stylesheet that reads them',
    indexHtml.indexOf('href="/tokens.css"') !== -1
    && indexHtml.indexOf('href="/tokens.css"') < indexHtml.indexOf('href="/style.css"'));

  /* -- 5. the frame's measures ------------------------------------------- */

  const frameOf = (css) => {
    const rules = cssRules(css);
    const root = rules.filter((r) => r.sel === ':root' && r.media.length === 0);
    const prop = (name) => root.map((r) => r.decls.get(name)).find(Boolean) ?? null;
    const decl = (sel, name) => rules.filter((r) => r.sel === sel && r.media.length === 0)
      .map((r) => r.decls.get(name)).find(Boolean) ?? null;
    return {
      bar: [prop('--bar-h'), decl('.bar', 'height')],
      navigator: [prop('--nav-w'), decl('.shell', 'grid-template-columns')],
      toolbar: [prop('--toolbar-h'), decl('.toolbar', 'height')],
      inspector: [prop('--inspector-w'), decl('.inspector', 'width')],
      rail: [prop('--rail-w'), decl('.side-rail', 'width')],
    };
  };
  const WANT = {
    bar: ['56px', 'var(--bar-h)'],
    navigator: ['272px', /^var\(--side-w, var\(--nav-w\)\) /],
    toolbar: ['48px', 'var(--toolbar-h)'],
    inspector: ['344px', 'var(--inspector-w)'],
    rail: ['56px', 'var(--rail-w)'],
  };
  const frameMisses = (css) => {
    const got = frameOf(css);
    return Object.keys(WANT).filter((k) => got[k][0] !== WANT[k][0]
      || !(WANT[k][1] instanceof RegExp ? WANT[k][1].test(got[k][1] ?? '') : got[k][1] === WANT[k][1]));
  };
  const misses = frameMisses(styleCss);
  check('the frame has the spec\'s measures: bar 56, navigator 272, toolbar 48, inspector 344, rail 56',
    misses.length === 0,
    misses.length ? `off: ${misses.map((k) => `${k} ${JSON.stringify(frameOf(styleCss)[k])}`).join(', ')}`
      : 'each is a property on :root AND the declaration that uses it');
  check('twin: a measure that exists only in a comment is not the frame',
    frameMisses(styleCss.replace(/--toolbar-h: 48px;/, '/* --toolbar-h: 48px; */ --toolbar-h: 52px;')).join() === 'toolbar');
  check('twin: a measure nothing uses is not the frame',
    frameMisses(styleCss.replace(/height: var\(--toolbar-h\);/, 'height: 40px;')).join() === 'toolbar');
  check('the navigator opens at the same width without a remembered one',
    /side:\s*\{[^}]*\bdef:\s*272\b/.test(appJs), 'app.js sets --side-w from this before the stylesheet\'s fallback is ever used');
  check('the toolbar and the inspector are in the page', /class="toolbar"/.test(indexHtml)
    && /<main class="stage">\s*<div id="phone-head"[^>]*><\/div>\s*<div class="toolbar"[\s\S]*?<div id="canvas"/.test(indexHtml)
    && /<\/main>\s*<aside id="inspector"/.test(indexHtml),
  'toolbar above the canvas inside the stage; inspector a column of the shell, not a child of the stage');

  /* -- 6. four widths ----------------------------------------------------- */

  const widthQueries = (css) => [...new Set([...noComments(css).matchAll(/@media\s*([^{]+)\{/g)]
    .map((m) => m[1].trim()).filter((q) => /width/.test(q)))].sort();
  const BANDS = ['(max-width: 1023px)', '(max-width: 1279px)', '(max-width: 639px)', '(min-width: 1280px)'];
  check('the stylesheet breaks at the spec\'s widths and at no other',
    widthQueries(styleCss).join() === BANDS.join(), `queries: ${widthQueries(styleCss).join(' ')}`);
  check('twin: a query at any other width is caught',
    widthQueries(`${styleCss}\n@media (max-width: 900px) { .side { display: none; } }`).join() !== BANDS.join());

  // What each band does, resolved through the cascade rather than read off the text.
  const rules = cssRules(styleCss);
  const node = (classes, attrs = {}) => ({ tag: 'div', classes: new Set(classes), attrs, pseudo: null });
  const WIDE = ['(min-width: 1280px)'];
  const MID = ['(max-width: 1279px)'];
  const NARROW = ['(max-width: 1279px)', '(max-width: 1023px)'];
  const PHONE = ['(max-width: 1279px)', '(max-width: 1023px)', '(max-width: 639px)'];
  const inspectorIn = (shell, media) => computed(rules, node(['inspector']), [node(shell)], media);
  check('at 1280 and up the inspector is docked in its own column',
    inspectorIn(['shell', 'no-chat'], WIDE).get('position') === 'relative'
    && inspectorIn(['shell', 'no-chat'], WIDE).get('grid-column') === '4');
  check('with a conversation open it floats instead, at any width',
    inspectorIn(['shell'], WIDE).get('position') === 'absolute'
    && inspectorIn(['shell'], WIDE).get('grid-column') === undefined,
    'navigator, inspector and conversation side by side leave no graph');
  check('between 1024 and 1279 the inspector floats and the canvas keeps its width',
    inspectorIn(['shell', 'no-chat'], MID).get('position') === 'absolute'
    && inspectorIn(['shell', 'no-chat'], MID).get('top') === 'var(--toolbar-h)');
  const shellIn = (classes, media) => computed(rules, node(classes), [], media).get('grid-template-columns') ?? '';
  check('at 1024 and up an open navigator is a column of its own width',
    shellIn(['shell', 'no-chat'], MID).startsWith('var(--side-w, var(--nav-w)) 5px '));
  check('below 1024 the navigator\'s column is the rail whether it is open or not',
    shellIn(['shell', 'no-chat'], NARROW).startsWith('var(--rail-w) 0 ')
    && shellIn(['shell', 'no-side', 'no-chat'], NARROW).startsWith('var(--rail-w) 0 ')
    && computed(rules, node(['side']), [node(['shell'])], NARROW).get('position') === 'absolute',
    'opened there, it floats over the canvas');
  check('below 640 the stage is the only column',
    ['shell', 'no-chat', 'no-side'].every((c) => shellIn(['shell', c], PHONE).startsWith('0 0 minmax(0, 1fr) '))
    && computed(rules, node(['side-rail']), [node(['shell'])], PHONE).get('display') === 'none');
  check('the narrow band collapses the navigator without overwriting the viewer\'s choice',
    /matchMedia\('\(max-width: 1023px\)'\)/.test(appJs)
    && /persist = !railBand\.matches/.test(appJs)
    && /if \(persist\) store\.set\('crewforth-studio-side-hidden'/.test(appJs));

  /* -- 7. the theme button ------------------------------------------------ */

  const { initTheme, effectiveTheme, THEME_KEY } = await import(`../../kit/studio/web/theme.js?t=${Date.now()}`);
  const rig = (saved, systemLight, broken = false) => {
    const m = new Map(saved ? [[THEME_KEY, saved]] : []);
    const ls = broken
      ? { getItem() { throw new Error('blocked'); }, setItem() { throw new Error('blocked'); } }
      : { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)) };
    const root = { dataset: {} };
    const button = { attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, addEventListener(_e, fn) { this.click = fn; } };
    initTheme(root, button, ls, () => systemLight);
    return { root, button, m };
  };
  check('with nothing chosen the theme is the system\'s, and dark unless it asks for light',
    effectiveTheme(undefined, false) === 'dark' && effectiveTheme(undefined, true) === 'light'
    && effectiveTheme('dark', true) === 'dark' && effectiveTheme('light', false) === 'light'
    && effectiveTheme('sepia', false) === 'dark');
  {
    const t = rig('light', false);
    check('a remembered theme is applied before anything is drawn', t.root.dataset.theme === 'light'
      && t.button.attrs['aria-label'] === 'Switch to dark theme');
    t.button.click();
    check('the button switches the theme and remembers it',
      t.root.dataset.theme === 'dark' && t.m.get(THEME_KEY) === 'dark'
      && t.button.attrs['aria-label'] === 'Switch to light theme');
  }
  {
    // The case the old button got wrong: no choice yet, and the system is light.
    const t = rig(null, true);
    const before = t.root.dataset.theme;
    t.button.click();
    check('on a light system the first click goes to dark, not to the theme already showing',
      before === undefined && t.root.dataset.theme === 'dark',
      `first click set ${t.root.dataset.theme}`);
  }
  {
    const t = rig(null, false, true);
    t.button.click();
    check('a browser that refuses storage still switches the theme', t.root.dataset.theme === 'light');
  }
  check('a remembered value that is not a theme is ignored', rig('sepia', false).root.dataset.theme === undefined);

  /* -- 8. controls that are only an icon say what they are ---------------- */

  // The static page only. A control app.js builds at run time is not in this
  // file and is not seen here.
  const unlabelled = (html) => [...html.matchAll(/<button\b([^>]*)>([\s\S]*?)<\/button>/g)]
    .filter(([, attrs, body]) => !/[A-Za-z]{2}/.test(body.replace(/<[^>]+>/g, '').replace(/&\w+;/g, ''))
      && !/\baria-label="[^"]+"/.test(attrs))
    .map(([, attrs]) => (/\bid="([^"]+)"/.exec(attrs)?.[1] ?? attrs.trim()));
  const buttons = [...indexHtml.matchAll(/<button\b/g)].length;
  check('every icon-only button in index.html has an aria-label',
    buttons > 0 && unlabelled(indexHtml).length === 0,
    unlabelled(indexHtml).length ? `no label: ${unlabelled(indexHtml).join(', ')}` : `${buttons} buttons read`);
  check('twin: an icon-only button with a title and no aria-label is caught',
    unlabelled('<button id="x" title="Widen">⇥</button><button id="y">+ session</button>').join() === 'x');
  check('the focus ring is 2px of the accent, 2px off the control',
    cssRules(styleCss).some((r) => r.sel === ':focus-visible' && r.media.length === 0
      && r.decls.get('outline') === '2px solid var(--accent)' && r.decls.get('outline-offset') === '2px')
    && !/outline:\s*(none|0)\b/.test(noComments(styleCss)),
    'and nothing in the stylesheet switches an outline off');
}

/* ------------------------------------- §30 the top bar and the navigator ---
   What the bar and the navigator SAY is in web/nav.js and web/liveness.js as
   functions of the server's data, so it is asserted here by calling them. What
   the server adds for them — a session's branch, a project's update command —
   is asserted against real files in a temp directory. */

process.stdout.write('\n== §30 the top bar and the navigator ==\n');

{
  const nav = await import(`../../kit/studio/web/nav.js?t=${Date.now()}`);
  const live = await import(`../../kit/studio/web/liveness.js?t=${Date.now()}`);
  const { kitStatus, _internals: kitInt } = await import(`../../kit/studio/server/lib/kit.js?t=${Date.now()}`);
  const { sessionTail, listSessions } = await import(`../../kit/studio/server/lib/projects.js?t=${Date.now()}`);
  const appJs = read(path.join(WEB_ROOT, 'app.js')) ?? '';
  const indexHtml = read(path.join(WEB_ROOT, 'index.html')) ?? '';
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-studio-nav-'));

  try {
    /* -- 1. the update command comes from the server, per install type ------ */

    const fileInstall = path.join(tmp, 'file-install');
    fs.mkdirSync(path.join(fileInstall, '.claude'), { recursive: true });
    fs.writeFileSync(path.join(fileInstall, '.claude', 'VERSION'), '2.12.0\n');
    // What a plugin install looks like from a project: a directory with no Crewforth file in it.
    const pluginShape = path.join(tmp, 'plugin-shape');
    fs.mkdirSync(path.join(pluginShape, '.claude'), { recursive: true });
    fs.writeFileSync(path.join(pluginShape, '.claude', 'settings.json'), '{}\n');
    const latest = { measured: true, version: '3.0.1' };

    const behind = await kitStatus(fileInstall, latest);
    check('a file install that is behind is told how to update, by the server',
      behind.installed && behind.outdated && behind.updateCommand === kitInt.FILE_INSTALL_UPDATE
      && behind.updateCommand === 'npx crewforth@latest update --here',
      `updateCommand: ${JSON.stringify(behind.updateCommand)}`);
    const badgeBehind = nav.badgeFor(behind);
    check('its badge copies exactly that command and says so',
      badgeBehind.copy === behind.updateCommand && badgeBehind.text === '2.12.0 · update'
      && badgeBehind.title.includes(behind.updateCommand), JSON.stringify(badgeBehind));

    const plugin = await kitStatus(pluginShape, latest);
    check('a project with no Crewforth files gets no command: a plugin install cannot be told apart from here',
      plugin.installed === false && plugin.updateCommand === null,
      `updateCommand: ${JSON.stringify(plugin.updateCommand)}`);
    const badgePlugin = nav.badgeFor(plugin);
    check('its badge copies nothing and points at /crew-update instead of inventing a command',
      badgePlugin.copy === null && /\/crew-update/.test(badgePlugin.title) && badgePlugin.text === 'no Crewforth'
      && !/npx/.test(JSON.stringify(badgePlugin)), JSON.stringify(badgePlugin));

    const current = nav.badgeFor(await kitStatus(fileInstall, { measured: true, version: '2.12.0' }));
    const uncompared = nav.badgeFor(await kitStatus(fileInstall, { measured: false, reason: 'offline' }));
    check('a current project and an uncompared one offer nothing to copy',
      current.copy === null && current.tone === 'current'
      && uncompared.copy === null && uncompared.tone === 'unknown' && /not compared: offline/.test(uncompared.title),
      'not compared is not "current", and neither is a reason to run an update');
    check('a badge never copies a command the server did not send',
      nav.badgeFor({ installed: true, version: '2.0.0', compared: true, outdated: true, latest: '3.0.1' }).copy === null
      && /\/crew-update/.test(nav.badgeFor({ installed: true, version: '2.0.0', compared: true, outdated: true, latest: '3.0.1' }).title),
      'an older server sends no updateCommand; the badge falls back to the hint');

    // The command text has one home. Nothing the browser loads may carry a copy of it.
    const typed = (text) => /npx\s+(--yes\s+)?crewforth|crewforth@latest/.test(text);
    const webFiles = walk(WEB_ROOT);
    const carriers = webFiles.filter((f) => typed(read(f) ?? '')).map((f) => path.basename(f));
    check('no file under web/ types the update command itself',
      webFiles.length >= 9 && carriers.length === 0,
      carriers.length ? `typed in: ${carriers.join(', ')}` : `${webFiles.length} files read`);
    check('twin: a command typed into a script is caught',
      typed("copyText('npx crewforth@latest update --here')") && typed('npx --yes crewforth@latest update')
      && !typed('run /crew-update in this project'));

    /* -- 2. a session's branch, read from its transcript --------------------- */

    const tDir = path.join(tmp, 'transcripts');
    fs.mkdirSync(tDir);
    const writeT = (name, lines) => {
      const f = path.join(tDir, name);
      fs.writeFileSync(f, lines.map((l) => (typeof l === 'string' ? l : JSON.stringify(l))).join('\n') + '\n');
      const st = fs.statSync(f);
      return [f, st.size, st.mtimeMs];
    };
    const moved = await sessionTail(...writeT('moved.jsonl', [
      { type: 'user', cwd: '/x', gitBranch: 'main', message: { content: 'start' } },
      { type: 'ai-title', aiTitle: 'Refund rounding' },
      { type: 'user', cwd: '/x', gitBranch: 'fix/refund-rounding', message: { content: 'go on' } },
    ]));
    check('the branch is the one the session is on now, and the title still comes from the same read',
      moved.branch === 'fix/refund-rounding' && moved.title === 'Refund rounding', JSON.stringify(moved));
    const none = await sessionTail(...writeT('none.jsonl', [{ type: 'user', cwd: '/x', message: { content: 'hi' } }]));
    const empty = await sessionTail(...writeT('empty.jsonl', [{ type: 'user', cwd: '/x', gitBranch: '', message: { content: 'hi' } }]));
    check('a transcript with no branch, or an empty one, yields null and not a guess',
      none.branch === null && empty.branch === null, `${JSON.stringify(none.branch)} / ${JSON.stringify(empty.branch)}`);
    const quoted = await sessionTail(...writeT('quoted.jsonl', [
      { type: 'user', cwd: '/x', gitBranch: 'real', message: { content: 'the record says "gitBranch":"fake" somewhere' } },
    ]));
    check('text that merely mentions the field is not read as the branch', quoted.branch === 'real', JSON.stringify(quoted.branch));
    const odd = await sessionTail(...writeT('odd.jsonl', [{ type: 'user', cwd: '/x', gitBranch: 'feat/"q"\\ü' }]));
    check('a branch with escaped characters comes back as it was written', odd.branch === 'feat/"q"\\ü', JSON.stringify(odd.branch));
    const listed = (await listSessions(tDir)).find((s) => s.sessionId === 'moved');
    check('the session list carries the branch beside the title', listed?.branch === 'fix/refund-rounding' && listed?.title === 'Refund rounding');

    /* -- 3. what a row is called, and what is under it ----------------------- */

    const sn = { sessionId: '7f3c1d20-9a4e', title: 'Refund rounding', branch: 'fix/refund-rounding', agentCount: 3 };
    check('a row is called by its label, then its title, then its id — never by a branch',
      nav.sessionName(sn, { '7f3c1d20-9a4e': 'mine' }) === 'mine'
      && nav.sessionName(sn, {}) === 'Refund rounding'
      && nav.sessionName({ ...sn, title: null }, {}) === '7f3c1d20'
      && nav.sessionName({ ...sn, title: null }, { '7f3c1d20-9a4e': '   ' }) === '7f3c1d20');
    const running = { key: 'busy', word: 'Running', tone: 'busy', known: true };
    check('the line under it is branch, state and agents',
      nav.sessionSub(sn, running) === 'fix/refund-rounding · Running · 3 agents'
      && nav.sessionSub({ ...sn, agentCount: 1 }, running) === 'fix/refund-rounding · Running · 1 agent');
    const bare = nav.sessionSub({ sessionId: 'x', title: null, branch: null, agentCount: 0 }, { key: 'unmeasured', word: null, tone: null });
    const noBranch = nav.sessionSub({ ...sn, branch: null }, running);
    check('a part that was not read is left out, not filled in',
      bare === '' && noBranch === 'Running · 3 agents' && !/null|undefined|—|unknown/.test(bare + noBranch),
      `${JSON.stringify(bare)} / ${JSON.stringify(noBranch)}`);

    /* -- 4. status: a word with every colour, and no colour for the unknown -- */

    const fleet = { measured: true, sessions: [
      { sessionId: 'a', status: 'busy' }, { sessionId: 'b', status: 'waiting', waitingFor: 'approve Bash' },
      { sessionId: 'c', status: 'idle' }, { sessionId: 'd', status: 'hibernating' },
      { sessionId: 'e', status: 'busy', local: false },
    ] };
    const st = (id, f = fleet) => nav.sessionStatus(id, f);
    check('every session state the machine reports has a word beside its colour',
      st('a').word === 'Running' && st('a').tone === 'busy'
      && st('b').word === 'Needs you' && st('b').tone === 'waiting' && st('b').waitingFor === 'approve Bash'
      && st('c').word === 'Idle' && st('c').tone === 'idle');
    check('a session the machine does not list has ended', st('zz').key === 'ended' && st('zz').word === 'Ended' && st('zz').tone === null);
    check('a state nobody recognises keeps its own word and gets no colour',
      st('d').word === 'hibernating' && st('d').tone === null && st('d').known === false);
    check('a fleet that was not read is "unmeasured", never "ended"',
      st('a', { measured: false, reason: 'no CLI' }).key === 'unmeasured' && st('a', null).key === 'unmeasured'
      && st('a', { measured: false }).word === null,
      'an unread list would otherwise draw every session as finished');
    check('a session on another machine does not lend its state to a local row', st('e').key === 'ended');

    const chips = nav.summaryChips({ done: 6, running: 3, failed: 1, zombie: 2, ended: 0, starting: 1 });
    check('the summary has one chip per status in play, and they add up',
      chips.map((c) => c.text).join(' | ') === '3 running | 1 starting | 6 done | 1 failed | 2 zombie'
      && chips.reduce((n, c) => n + c.count, 0) === 13, chips.map((c) => c.text).join(' | '));
    check('every chip carries a word, and an unknown status its own with no colour',
      chips.every((c) => /^\d+ \S+/.test(c.text))
      && chips.find((c) => c.status === 'zombie').tone === null && chips.find((c) => c.status === 'zombie').known === false
      && chips.find((c) => c.status === 'failed').tone === 'fail' && chips.find((c) => c.status === 'done').tone === 'good');
    check('no agents is no chips, not a row of zeros', nav.summaryChips({}).length === 0 && nav.summaryChips(null).length === 0
      && nav.summaryChips({ done: 0 }).length === 0);

    /* -- 5. search ------------------------------------------------------------ */

    const proj = { label: 'acme-payments-api' };
    check('search reaches the project name, the branch, the session id and the row\'s name',
      nav.matchesSession('PAYMENTS', proj, sn, {}) && nav.matchesSession('refund-round', proj, sn, {})
      && nav.matchesSession('7f3c', proj, sn, {}) && nav.matchesSession('rounding', proj, sn, {})
      && nav.matchesSession('mine', proj, sn, { '7f3c1d20-9a4e': 'mine' })
      && !nav.matchesSession('ledger', proj, sn, {}) && nav.matchesSession('  ', proj, sn, {}));
    const parts = nav.highlight('feat/Payment-retries · payments', 'payment');
    check('the match is marked where it is, in the case it was written in',
      parts.filter((p) => p.hit).map((p) => p.text).join('|') === 'Payment|payment'
      && parts.map((p) => p.text).join('') === 'feat/Payment-retries · payments'
      && nav.highlight('abc', '').length === 1 && nav.highlight('abc', 'zz')[0].hit === false);

    /* -- 6. live and machines ------------------------------------------------- */

    const liveRows = nav.liveSessions({ measured: true, sessions: [
      { sessionId: 'i', status: 'idle' }, { sessionId: 'r', status: 'busy', startedAt: 5 },
      { sessionId: 'w', status: 'waiting', startedAt: 1 }, { sessionId: 'r2', status: 'busy', startedAt: 9 },
    ] });
    check('Live is what is working or waiting, the waiting ones first',
      liveRows.map((s) => s.sessionId).join() === 'w,r2,r');
    check('an unread fleet has no live list to show', nav.liveSessions({ measured: false }).length === 0 && nav.liveSessions(null).length === 0);
    check('and the panel says so instead of "none running"',
      /Not measured/.test(appJs) && /not the same as "nothing is running"/.test(appJs) && /No sessions running/.test(appJs));

    const mach = nav.machines({
      origins: [{ name: 'here', local: true, ok: true }, { name: 'mini', ok: true, sessions: 2 }, { name: 'box', ok: false, reason: 'ECONNREFUSED' }],
      roster: { measured: true, seenAt: 1000, peers: [{ name: 'laptop', remote: true, status: 'idle' }, { name: 'self', remote: false }] },
    });
    check('a peer asked just now and a session recorded earlier are different kinds of row',
      mach.peers.map((p) => `${p.name}:${p.kind}:${p.ok}`).join() === 'mini:peer:true,box:peer:false'
      && mach.peers[1].reason === 'ECONNREFUSED'
      && mach.remote.length === 1 && mach.remote[0].kind === 'snapshot' && mach.remote[0].seenAt === 1000);
    check('a roster nobody recorded is not "no other machines"',
      nav.machines({ origins: [], roster: { measured: false, reason: 'never recorded' } }).rosterMeasured === false
      && nav.machines({ origins: [], roster: { measured: false, reason: 'never recorded' } }).rosterReason === 'never recorded'
      && nav.machines(null).rosterMeasured === false);
    check('a snapshot says how old it is', nav.seenAgo(0, 185000) === 'seen 3 min ago' && nav.seenAgo(0, 20000) === 'seen just now'
      && nav.seenAgo(null, 5) === 'seen at an unrecorded time' && nav.ago(0, 7200000) === '2h' && nav.ago(0, 30000) === 'now');

    /* -- 7. Live, Stale, Offline ---------------------------------------------- */

    const T = 1_000_000;
    check('heard from a moment ago is Live, with how long ago',
      live.liveness(T, T - 2000, false).state === 'live' && live.liveness(T, T - 2000, false).detail === '2s ago');
    check('the threshold is where Live becomes Stale, and not a millisecond before',
      live.liveness(T, T - live.STALE_AFTER_MS, false).state === 'live'
      && live.liveness(T, T - live.STALE_AFTER_MS - 1, false).state === 'stale');
    check('a failed request is Offline whatever the clock says, and keeps the time of the last answer',
      live.liveness(T, T - 500, true).state === 'offline' && /^last update \d\d:\d\d$/.test(live.liveness(T, T - 500, true).detail)
      && live.liveness(T, null, true).detail === 'the server has not answered');
    check('before the first answer it is Connecting, not Live', live.liveness(T, null, false).state === 'connecting');
    check('every state has a word, so none of them is told by colour alone',
      [[T - 1, false], [T - 99999, false], [T, true], [null, false]].every(([ok, failed]) => live.liveness(T, ok, failed).word.length > 3));

    // The threshold was chosen against the slowest healthy silence, which is one
    // project poll (the fleet poll can be slower than that, and then it is the
    // project poll that keeps the panel fed). Slowing that poll without moving
    // the threshold would make a healthy panel read Stale.
    const pollMs = (name) => Number(new RegExp(`const ${name} = (\\d+);`).exec(appJs)?.[1]);
    const roomFor = (staleMs, slowestPollMs) => staleMs >= 2 * slowestPollMs;
    check('the Stale threshold leaves room for two project polls',
      pollMs('SESSION_POLL_MS') > 0 && pollMs('FLEET_POLL_MS') > 0
      && roomFor(live.STALE_AFTER_MS, Math.max(pollMs('SESSION_POLL_MS'), 0)),
      `stale after ${live.STALE_AFTER_MS} ms; polls every ${pollMs('FLEET_POLL_MS')} and ${pollMs('SESSION_POLL_MS')} ms`);
    check('twin: a slower project poll with the same threshold is caught', !roomFor(live.STALE_AFTER_MS, 6000));
    check('any answer on any channel counts as heard from',
      (appJs.match(/heardNow\(\)|heardNow\)/g) ?? []).length >= 4
      && /addEventListener\('graph', \(e\) => \{\s*heardNow\(\);/.test(appJs)
      && /addEventListener\('idle', heardNow\)/.test(appJs),
      'the fleet poll alone waits on a CLI spawn; the project poll and the stream do not');
    check('only a request that did not complete is Offline; an error status is still an answer',
      /catch \(e\) \{\s*heard\.failed = true;\s*throw e;\s*\}\s*if \(!r\.ok\) throw/.test(appJs));

    /* -- 8. the summary chips filter the canvas ------------------------------- */

    const dom = installDom();
    try {
      const { Canvas } = await import(`../../kit/studio/web/canvas.js?filter=${Date.now()}`);
      const c = new Canvas(document.createElement('div'), {});
      c.setPalette({ map: { Explore: { hex: '#26c6e6', source: 'builtin' } }, unknown: '#94a3c8' });
      c.setSession('s-filter');
      const agent = (id, status) => ({ id, kind: 'agent', agentType: 'Explore', status, spawnDepth: 1, parentId: 'session', tools: {}, toolCount: 0 });
      c.render({
        nodes: [{ id: 'session', kind: 'session', status: 'session', turns: 1, cwd: '/x' }, agent('r', 'running'), agent('d', 'done'), agent('f', 'failed')],
        edges: [{ source: 'session', target: 'r' }, { source: 'session', target: 'd' }, { source: 'session', target: 'f' }],
      });
      const dim = (id) => c.els.get(id).classList.contains('cv-dim');
      check('with no filter nothing is stepped back', !dim('r') && !dim('d') && !dim('f') && !dim('session'));
      c.setFilter('running');
      check('a status filter steps back the agents in every other status and leaves the session lit',
        !dim('r') && dim('d') && dim('f') && !dim('session'));
      check('the cards stay where they were: a filter is not a new layout',
        c.els.size === 4 && c.nodes.size === 4);
      c.setFilter(null);
      check('taking the filter off brings everything back', !dim('r') && !dim('d') && !dim('f'));
    } finally {
      dom();
    }
    check('the chip that is filtering says so, and clicking it again undoes it',
      /setAttribute\('aria-pressed', String\(statusFilter === c\.status\)\)/.test(appJs)
      && /setStatusFilter\(statusFilter === c\.status \? null : c\.status\)/.test(appJs));
    check('a filter cannot outlive the status it filters on',
      /if \(statusFilter && !chips\.some\(\(c\) => c\.status === statusFilter\)\) setStatusFilter\(null, false\)/.test(appJs),
      'when the last running agent finishes, a "running" filter would hide every card with no chip left to undo it');

    /* -- 9. the page ----------------------------------------------------------- */

    check('the bar has the breadcrumb, the summary, the Live indicator and one primary button',
      /id="crumb"[^>]*aria-label="Breadcrumb"/.test(indexHtml) && /id="graph-summary"[^>]*aria-label="Session summary"/.test(indexHtml)
      && /id="pulse"[^>]*role="status"/.test(indexHtml) && (indexHtml.match(/class="btn primary"/g) ?? []).length === 1);
    check('the old three folding blocks are gone', !/data-fold/.test(indexHtml) && !/side-block/.test(indexHtml));
    check('the footer line is gone; its reasons moved into the toolbar',
      !/<footer/.test(indexHtml) && /<span id="foot-note" class="toolbar-note" role="status">/.test(indexHtml));
    check('the navigator answers to / [ and ]',
      /e\.key === '\/'/.test(appJs) && /e\.key === '\['/.test(appJs) && /e\.key === '\]'/.test(appJs)
      && /tagName === 'INPUT'/.test(appJs), 'and not while something is being typed into');
    check('a terminal is only opened after its command has been shown',
      /note: plan\.line/.test(appJs) && appJs.indexOf('note: plan.line') < appJs.indexOf("method: 'POST'"),
      'the command is in the menu before the button that runs it');
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

/* ------------------------------ §31 the approval dock and the inspector ---
   A request waiting on the viewer is drawn in one place, counts down on the server's
   clock, and is answered with one of three buttons. What the inspector says about a
   node is said the way the rest of the panel says things: a figure nobody read is
   "Not measured", never 0. */

process.stdout.write('\n== §31 the approval dock and the inspector ==\n');

{
  const ap = await import(`../../kit/studio/web/approvals.js?t=${Date.now()}`);
  const insp = await import(`../../kit/studio/web/inspect.js?t=${Date.now()}`);
  const web = (f) => read(path.join(WEB_ROOT, f)) ?? '';
  const appJs = web('app.js');
  const dockJs = web('dock.js');
  const chatJs = web('chat.js');
  const indexHtml = web('index.html');
  const cssSrc31 = web('style.css');
  const serverJs = read(path.join(STUDIO, 'server', 'index.js')) ?? '';
  const sessionJs = read(path.join(STUDIO, 'server', 'lib', 'session.js')) ?? '';

  /* -- 1. the queue ---------------------------------------------------------- */

  const T = 1_800_000_000_000;
  const req = (id, askedAt, extra = {}) => ({ toolUseId: id, toolName: 'Bash', detail: `echo ${id}`, askedAt, ...extra });
  const sessions = [
    { sessionId: 's-b', gated: true, gateWaitSeconds: 45, pendingPermissions: [req('late', T + 3000)] },
    { sessionId: 's-a', gated: true, gateWaitSeconds: 45, pendingPermissions: [req('early', T), req('mid', T + 1000, { agentId: 'ag1', agentType: 'Explore' })] },
    { sessionId: 's-open', gated: false, gateWaitSeconds: 45, pendingPermissions: [req('never', T - 5000)] },
  ];
  const q = ap.queue(sessions, (id) => (id === 's-a' ? 'Ledger index' : null));
  check('the queue is every gated session\'s requests, oldest first: the order they time out in',
    q.map((r) => r.toolUseId).join(',') === 'early,mid,late', q.map((r) => r.toolUseId).join(','));
  check('a session without the gate contributes nothing: there is no hook there to answer',
    !q.some((r) => r.toolUseId === 'never'));
  check('a request says who asked — the agent, or the session itself',
    ap.asker(q[1]) === 'Explore' && ap.asker(q[0]) === 'Session');
  {
    const { openCalls } = await import(`../../kit/studio/server/lib/graph.js?o=${Date.now()}`);
    const use = (id, name, input, at) => ({ type: 'assistant', timestamp: at, message: { content: [{ type: 'tool_use', id, name, input }] } });
    const res = (id) => ({ type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: id }] } });
    const recs = [
      use('t1', 'Bash', { command: 'ls' }, '2026-01-01T00:00:01Z'), res('t1'),
      use('t2', 'Agent', { description: 'hand it on' }, '2026-01-01T00:00:02Z'),
      use('t3', 'Bash', { command: 'npm run build', description: 'Build' }, '2026-01-01T00:00:03Z'),
    ];
    const openNow = openCalls(recs);
    check('the call a transcript has no result for is read from it: the tool and its command',
      openNow.length === 1 && openNow[0].toolName === 'Bash' && openNow[0].detail === 'npm run build' && openNow[0].toolUseId === 't3',
      JSON.stringify(openNow));
    check('a call that got its result is not open, and handing work to an agent is not a call anyone is asked about',
      openCalls([...recs, res('t3')]).length === 0 && openCalls([]).length === 0 && openCalls([{ type: 'user', message: { content: 'hi' } }]).length === 0);
    const waiting = { key: 'waiting', waitingFor: 'approve Bash' };
    const tw = ap.terminalWait(waiting, { openCall: { toolName: 'Bash', detail: 'npm run build', agentType: 'crew-test-expert' } }, false);
    check('a session waiting on its own terminal says so, with the tool and the command it asks about',
      tw.text === 'Waiting for an answer in the terminal' && tw.what === 'Test · Bash · npm run build'
      && ap.terminalWait(waiting, { openCall: { toolName: 'Read', detail: null } }, false).what === 'Read', JSON.stringify(tw));
    check('with no open call in the transcript it says what the CLI says, and with neither it says no more than that it waits',
      ap.terminalWait(waiting, { openCall: null }, false).what === 'approve Bash'
      && ap.terminalWait({ key: 'waiting' }, null, false).what === null);
    check('a session that is not waiting, and one started here, have no such line: the dock is where those are answered',
      ap.terminalWait({ key: 'busy' }, { openCall: { toolName: 'Bash', detail: 'x' } }, false) === null
      && ap.terminalWait(waiting, { openCall: { toolName: 'Bash', detail: 'x' } }, true) === null
      && ap.terminalWait(null, null, false) === null);
    const appSrc = web('app.js');
    check('the line is drawn under the view for the session on screen, and carries no answers',
      /terminalWait\(sessionStatus\(current, fleetData\), session, ownedIds\.has\(current\) \|\| owned\.has\(current\)\)/.test(appSrc)
      && /<div id="terminal-wait" class="terminal-wait" role="status" hidden><\/div>/.test(web('index.html'))
      && !/<button/.test(appSrc.slice(appSrc.indexOf('function paintTerminalWait'), appSrc.indexOf('function retryNow'))));
    check('the inspector has a handle on its left edge and a width that is remembered, like the other two panels',
      /inspector: \{ min: 280, max: 720, def: 344, varName: '--inspector-w', key: 'crewforth-studio-inspector-w' \}/.test(appSrc)
      && /for \(const which of Object\.keys\(PANEL\)\)/.test(appSrc)
      && /dragPanel\(inspectorSplit, 'inspector', 'right'\);/.test(appSrc)
      && /el\.inspector\.replaceChildren\(inspectorSplit, head,/.test(appSrc)
      && /--inspector-w: 344px;/.test(web('tokens.css') + web('style.css')));
  }

  /* -- 2. the countdown is the server's -------------------------------------- */

  const r38 = ap.remaining(q[0], T + 7200);
  check('the countdown is asked-at plus the server\'s wait, minus the server\'s now',
    r38.known && r38.left === 38 && Math.abs(r38.fraction - 37.8 / 45) < 1e-9, `${r38.left}s, ring ${r38.fraction?.toFixed(3)}`);
  const shorter = ap.remaining({ ...q[0], waitSeconds: 20 }, T + 7200);
  check('a different wait on the server is a different countdown on the page', shorter.left === 13, `${shorter.left}s`);
  const noWait = ap.queue([{ sessionId: 's-x', gated: true, pendingPermissions: [req('x', T)] }])[0];
  const unknown = ap.remaining(noWait, T + 1000);
  check('a wait the server did not send is not replaced by a number the page made up',
    noWait.waitSeconds === null && unknown.known === false && unknown.left === null,
    'the dock then shows no clock; a default here is exactly a hand-written 45');

  // The viewer's clock is not the hook's. A browser five minutes fast would show every request as expired.
  const clock = new ap.ServerClock();
  const localNow = T + 7200 + 300_000;
  clock.sync(T + 7200, localNow);
  check('a viewer whose clock is five minutes off still counts down to the hook\'s deadline',
    ap.remaining(q[0], clock.now(localNow)).left === 38);
  check('the same request on the viewer\'s own clock would read as already over — the control for the line above',
    ap.remaining(q[0], localNow).expired === true);
  const unsynced = new ap.ServerClock();
  unsynced.sync(undefined, localNow);
  check('a response with no server time in it does not move the clock', unsynced.synced === false && unsynced.offset === 0);

  // Nothing under web/ carries the wait as a literal.
  const waitLiterals = (src) => src.match(/(?<![\d.])\b45(?:_?000)?\b(?!\s*%|\.\d)/g) ?? [];
  const webFiles = fs.readdirSync(WEB_ROOT).filter((f) => /\.(js|html)$/.test(f));
  const carrying = webFiles.filter((f) => waitLiterals(web(f)).length);
  check('no file under web/ writes the gate\'s wait by hand', webFiles.length >= 10 && carrying.length === 0,
    `${webFiles.length} files scanned${carrying.length ? `; found in ${carrying.join(', ')}` : ''}`);
  check('the scan that says so does find one when it is there',
    waitLiterals('const WAIT = 45;').length === 1 && waitLiterals('setTimeout(deny, 45000)').length === 1
    && waitLiterals('opacity: 45%; x = 1.45; y = 145').length === 0,
    'calibrated on a planted literal and on three things that are not one');
  check('the server puts its wait and its clock in what it sends',
    /gateWaitSeconds: this\.gate\?\.waitSeconds \?\? null/.test(sessionJs) && /now: Date\.now\(\),\s*gateEvents/.test(sessionJs)
    && /sessions: listSessionsOwned\(\), now: Date\.now\(\)/.test(serverJs));

  /* -- 3. what became of a request ------------------------------------------- */

  const decided = new Map([['s-a/early', 'deny'], ['s-b/late', 'always']]);
  const gone = ap.settled(q, [], decided, T + 10_000);
  const how = Object.fromEntries(gone.map((g) => [g.toolUseId, g.outcome]));
  check('a request this page answered is recorded with the answer it gave',
    how.early === 'denied' && how.late === 'allowed-session', JSON.stringify(how));
  check('a request that vanished early with no answer from here was answered somewhere else, not timed out',
    how.mid === 'answered-elsewhere');
  const atDeadline = ap.settled([q[1]], [], new Map(), T + 1000 + 45_000);
  check('a request that vanished at the hook\'s deadline with no answer is a timeout', atDeadline[0]?.outcome === 'timed-out');
  check('a request still waiting has no outcome', ap.settled(q, q, decided, T + 99_000).length === 0);
  check('a timeout is said as a denial, because that is what the hook did',
    ap.OUTCOME_WORD['timed-out'] === 'Timed out — denied' && ap.OUTCOME_WORD.denied === 'Denied');

  /* -- 4. the dock ------------------------------------------------------------ */

  const dom31 = installDom();
  try {
    const { Dock } = await import(`../../kit/studio/web/dock.js?t=${Date.now()}`);
    const sent = [];
    let now = T + 7200;
    const root = document.createElement('div');
    root.hidden = true;
    const dock = new Dock(root, { now: () => now, onDecide: (item, verdict) => sent.push(`${item.toolUseId}:${verdict}`) });
    const p = dock.parts;
    dock.render([]);
    check('with nothing waiting the dock is not on the page', root.hidden === true);
    dock.render(q);
    const buttons = [p.deny, p.always, p.allow].map((b) => b.textContent);
    check('with a request waiting the dock shows who, which tool, the whole command and the time left',
      root.hidden === false && p.who.textContent === 'Session' && p.tool.textContent === 'Bash'
      && p.cmd.textContent === 'echo early' && p.secs.textContent === '38s' && /Auto-deny in 38s/.test(p.note.textContent),
      `${p.who.textContent} · ${p.tool.textContent} · ${p.cmd.textContent} · ${p.secs.textContent}`);
    check('three answers and no fourth: Deny, Allow <tool> this session, Allow once',
      buttons.join(' | ') === 'Deny | Allow Bash this session | Allow once' && !/undo/i.test(dockJs),
      `${buttons.join(' | ')} — a denial has reached the agent by the time it is shown; there is nothing to undo`);
    check('the clock is a timer to a screen reader, with the seconds in words',
      p.timer.getAttribute('role') === 'timer' && p.timer.getAttribute('aria-label') === 'Auto-deny in 38 seconds');
    check('several requests are counted, and the arrows walk them',
      p.nav.hidden === false && p.count.textContent === '1 of 3'
      && (dock.step(1), p.count.textContent === '2 of 3' && p.who.textContent === 'Explore')
      && (dock.step(-1), p.count.textContent === '1 of 3'));
    dock.render([q[0]]);
    check('one request has no counter', p.nav.hidden === true);
    dock.render(q);

    now += 1000;
    dock.tick();
    check('the clock moves without anything else changing', p.secs.textContent === '37s');

    dock.render([noWait]);
    check('a request whose wait the server did not send shows no seconds, and says it was not measured',
      p.secs.textContent === '?' && /not measured/i.test(p.note.textContent) && !/\d/.test(p.note.textContent),
      p.note.textContent);
    dock.render(q);

    root.emit('keydown', { key: 'a' });
    check('with the dock focused, a answers Allow once', sent.join() === 'early:allow', sent.join());
    root.emit('keydown', { key: 'd' });
    check('a request already answered cannot be answered twice',
      sent.length === 1 && p.deny.disabled && p.allow.disabled && p.always.disabled);
    dock.release('s-a/early');
    check('an answer that did not reach the server gives the buttons back', !p.deny.disabled && !p.allow.disabled);
    root.emit('keydown', { key: 's', ctrlKey: true });
    check('a shortcut with a modifier is the browser\'s, not an answer', sent.length === 1);
    check('the keys are the dock\'s own: nothing listens for them on the page',
      !/document\.addEventListener|window\.addEventListener/.test(dockJs)
      && !/e\.key === 'a'|e\.key === 'd'|e\.key === 's'/.test(appJs),
      'a letter typed anywhere else is a letter');

    dock.say('timed-out', false);
    check('a timeout is said in the dock, and the buttons are gone while it is',
      root.hidden === false && p.word.textContent === 'Timed out — denied' && p.acts.hidden && p.timer.hidden
      && root.dataset.state === 'timed-out');
    root.emit('keydown', { key: 'a' });
    check('a key pressed while the outcome is on screen answers nothing', sent.length === 1,
      'the next request is not on screen yet; nobody has read it');
    clearTimeout(dock.flashTimer);
    dock.flash = null;
    dock.render([]);
    check('when the last request is gone the dock goes with it', root.hidden === true);
  } finally {
    dom31();
  }

  check('the dock is not a dialog and takes no focus',
    !/showModal|role="dialog"|aria-modal|\.focus\(/.test(dockJs)
    && /<div id="canvas" class="canvas"><\/div>\s*<div id="timeline"[^>]*hidden><\/div>\s*<div id="list"[^>]*hidden><\/div>\s*<div id="first-run"[^>]*hidden><\/div>\s*<div id="terminal-wait"[^>]*hidden><\/div>\s*<div id="dock" role="region"[^>]*hidden><\/div>\s*<\/main>/.test(indexHtml),
    'a region under the canvas, inside the stage: the graph stays usable above it');
  check('the dock is the one place requests are drawn: the conversation pane no longer draws its own',
    !/perm-queue|paintPermissions/.test(chatJs) && !/\.perm-/.test(cssSrc31) && /this\.onPermissions\(this, rec\)/.test(chatJs));
  check('a pane\'s stream is a reason to ask the server, not the answer',
    /chat\.onPermissions = \(\) => pollOwned\(\)/.test(appJs),
    'the stream replays what it already said on reconnect; a replayed queue would announce outcomes that never happened');
  check('who is waiting reaches the canvas, so the card, its wire, the map and the strip all say it',
    /canvas\.setWaiting\(here\.filter\(\(r\) => r\.agentId\)\.map\(\(r\) => r\.agentId\)\)/.test(appJs));
  check('a floating inspector stops above the dock, and a hidden dock takes no room',
    /\.shell > \.inspector \{[^}]*bottom: var\(--dock-h, 0px\)/.test(cssSrc31)
    && /\.dock\[hidden\], \.dock \[hidden\] \{ display: none; \}/.test(cssSrc31));

  check('only the bar\'s primary button drops its words in a narrow window: Allow once keeps them',
    /\.bar \.btn\.primary \{ width: 36px; padding: 0; \}/.test(cssSrc31) && !/^\s*\.btn\.primary \{ width: 36px/m.test(cssSrc31),
    'the rule was written for New session and squeezed every primary button to an icon\'s width');

  /* -- 5. the inspector -------------------------------------------------------- */

  check('the inspector has four tabs, in the design\'s order',
    insp.TABS.join(',') === 'overview,conversation,gates,stats'
    && Object.values(insp.TAB_WORD).join(' · ') === 'Overview · Conversation · Gates · Stats');

  const agent = { id: 'a1', kind: 'agent', status: 'running', toolCount: 0, errors: 0, tokens: null, startedAt: T, durationMs: null, parentId: 'session' };
  const tl = Object.fromEntries(insp.tiles(agent, T + 500_000).map((t) => [t.label, t]));
  check('tokens nobody read are Not measured, with why — never 0',
    tl.Tokens.value === 'Not measured' && tl.Tokens.measured === false && Boolean(tl.Tokens.why));
  check('a count the transcript gave is a count, zero included',
    tl['Tool calls'].value === '0' && tl['Tool calls'].measured === true && tl.Errors.value === '0');
  check('a running agent\'s elapsed time is the clock since it started', tl.Elapsed.value === '8m 20s', tl.Elapsed.value);
  const noStart = Object.fromEntries(insp.tiles({ ...agent, startedAt: null }, T).map((t) => [t.label, t]));
  check('with no start recorded the elapsed time is Not measured, not 0s',
    noStart.Elapsed.value === 'Not measured' && noStart.Elapsed.measured === false);

  const detail = { timeline: [{ name: 'Skill', label: 'testing' }, { name: 'Read', label: 'src/a.ts' }, { name: 'Skill', label: 'testing' }, { name: 'Skill', label: 'db-migration' }, { name: 'Bash', label: 'npm test' }], report: null };
  check('what it is doing is "Right now" while it runs and "Last tool" once it has stopped',
    insp.rightNow(agent, detail).heading === 'Right now' && insp.rightNow(agent, detail).text === 'npm test'
    && insp.rightNow({ ...agent, status: 'done' }, detail).heading === 'Last tool');
  check('the skills an agent applied are listed once each, in the order it first used them',
    insp.skillsOf(detail).join(',') === 'testing,db-migration');
  check('an agent that has not finished has not reported, and the inspector says that rather than showing narration',
    insp.reportOf(agent, detail).present === false && /Not reported yet/.test(insp.reportOf(agent, detail).text)
    && insp.reportOf({ ...agent, status: 'done' }, { report: 'All green.' }).text === 'All green.');
  check('"Delegated by" is the node the agent hangs from',
    insp.delegatedBy(agent, [{ id: 'session', kind: 'session', gitBranch: 'main' }]).id === 'session'
    && insp.delegatedBy({ ...agent, parentId: 'p9' }, [{ id: 'p9', kind: 'agent', agentType: 'Plan' }]).text === 'Plan'
    && insp.delegatedBy({ ...agent, parentId: 'nobody' }, []) === null);

  check('a session Studio did not start says so, where the missing controls would be',
    /This session was not started here, so Studio can read it but not write to it\./.test(appJs)
    && /cont\.addEventListener\('click', \(\) => continueHere\(cont\)\)/.test(appJs)
    && /offerTerminal\(term, current\)/.test(appJs));
  check('Continue here lives on the session, not in the bar',
    !/continue-session/.test(indexHtml) && !/continueSession/.test(appJs));
  check('an allowance is listed in Gates with a way to take it back, and the take-back is a DELETE',
    /revokeAllowance\(tool, revoke\)/.test(appJs) && /method: 'DELETE', headers: writeHeaders/.test(appJs)
    && /alwaysAllowed: this\.gate \? alwaysList\(this\.id\) : \[\]/.test(sessionJs));
  const delAt = serverJs.indexOf("req.method === 'DELETE'");
  const gateAt = serverJs.lastIndexOf('writeAllowed(req)', delAt);
  check('the revoke endpoint is behind the same write guard as every other write',
    delAt > 0 && gateAt > 0 && delAt - gateAt < 1500 && /revoke\(s\.id, /.test(serverJs),
    `guard ${delAt - gateAt} characters before the DELETE branch`);
  check('the copy button copies a path the server handed over, and is disabled when there is none',
    /copy\.disabled = !file/.test(appJs) && /transcriptPath: file/.test(read(path.join(STUDIO, 'server', 'lib', 'graph.js')) ?? ''),
    'a path is not assembled from parts in the page');
  check('a skill chip copies the skill\'s name', /copyText\(s, `Copied \$\{s\}`\)/.test(appJs));
}

/** Every piece of text under a stub element, for claims about what a built panel says. */
function* walkText(node) {
  if (!node) return;
  if (typeof node.textContent === 'string' && node.textContent) yield node.textContent;
  for (const c of node.children ?? []) yield* walkText(c);
}

/* ------------------------- §32 the conversation panel and New session ---
   What a conversation is made of is decided without a page: a delegation is a card,
   a tool call is one line whose summary is the tool's own last line, and a result
   nobody read is not drawn as an empty one. Starting a session is a panel with the
   server's choices in it, and two clicks start one session. */

process.stdout.write('\n== §32 the conversation panel and New session ==\n');

{
  const cv = await import(`../../kit/studio/web/convo.js?t=${Date.now()}`);
  const ns = await import(`../../kit/studio/web/newsession.js?t=${Date.now()}`);
  const { conversation: readConversation } = await import(`../../kit/studio/server/lib/graph.js?c=${Date.now()}`);
  const { headBranch } = await import(`../../kit/studio/server/lib/projects.js?c=${Date.now()}`);
  const web = (f) => read(path.join(WEB_ROOT, f)) ?? '';
  const appJs = web('app.js');
  const chatJs = web('chat.js');
  const indexHtml = web('index.html');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-studio-convo-'));

  try {
    /* -- 1. tool rows ---------------------------------------------------------- */

    const call = cv.toolBlock({ type: 'tool_use', id: 'toolu_1', name: 'Bash', input: { command: 'npm test -- capture' } });
    check('a tool call that has not come back has no summary, and is not drawn as one that returned nothing',
      call.result === null && cv.summaryOf(call).state === 'pending' && cv.summaryOf(call).text === null && cv.outputOf(call) === null);
    call.result = cv.resultFrom({ content: 'running\n\n Tests  42 passed (42)\n\n' });
    check('the summary is the tool\'s own last line, and nothing made from it',
      cv.summaryOf(call).state === 'ok' && cv.summaryOf(call).text === 'Tests  42 passed (42)', cv.summaryOf(call).text);
    const failed = { ...call, result: cv.resultFrom({ is_error: true, content: [{ type: 'text', text: 'boom\nexit 1' }] }) };
    check('a call that ended in an error says so in its state, and keeps its last line',
      cv.summaryOf(failed).state === 'error' && cv.summaryOf(failed).text === 'exit 1');
    check('a call that returned nothing says "no output"', cv.summaryOf({ result: cv.resultFrom({ content: '' }) }).text === 'no output');
    const big = cv.resultFrom({ content: `${'x'.repeat(5000)}\nlast line` });
    check('a long output keeps its end, and what was left out is said when it is opened',
      big.truncated && big.text.endsWith('last line') && big.text.length === 4096 && big.length === 5010
      && /^… 914 earlier characters not shown\n/.test(cv.outputOf({ result: big })), `${big.text.length} of ${big.length}`);
    check('the results in a user record are matched to their calls by id',
      JSON.stringify(cv.resultsIn([{ type: 'text', text: 'hi' }, { type: 'tool_result', tool_use_id: 'toolu_1', content: 'ok' }]).map((r) => [r[0], r[1].text])) === '[["toolu_1","ok"]]'
      && cv.resultsIn('just text').length === 0);
    check('a tool result is put on its row and is not shown as something the viewer said',
      /for \(const \[id, result\] of resultsIn\(c\)\) this\.setResult\(id, result\)/.test(chatJs)
      && /c\.filter\(\(x\) => x\?\.type === 'text'\)/.test(chatJs));

    /* -- 2. delegation cards ---------------------------------------------------- */

    const deleg = cv.toolBlock({ type: 'tool_use', id: 'toolu_a', name: 'Agent', input: { subagent_type: 'crew-test-expert', description: 'Prove both keys verify' } });
    const nodes = [{ id: 'a1', kind: 'agent', agentType: 'crew-test-expert', toolUseId: 'toolu_a', status: 'running' }];
    check('handing work to an agent is a card, an ordinary tool call is a row',
      cv.isDelegation(deleg) && cv.isDelegation({ kind: 'tool', name: 'Task' }) && !cv.isDelegation(call));
    const card = cv.delegationCard(deleg, nodes);
    check('a card is tied to the agent that call became, by the call\'s id',
      card.agentId === 'a1' && card.status === 'running' && card.type === 'Test' && card.real === 'crew-test-expert'
      && card.task === 'Prove both keys verify');
    const loose = cv.delegationCard(deleg, []);
    check('a card whose agent the graph has not seen has no status and goes nowhere: none is guessed',
      loose.agentId === null && loose.status === null && loose.type === 'Test'
      && /node\.disabled = !card\.agentId/.test(chatJs));
    check('clicking a card selects that agent on the graph',
      /onAgent: \(pane, agentId\) => \{\s*if \(pane\.id !== current\) selectSession\(pane\.id\);\s*goTo\(agentId\);/.test(appJs)
      && /if \(view === 'graph'\) \{ canvas\.focus\(agentId\); return; \}/.test(appJs),
      'or on the Timeline or the List, when that is the view that is open');

    /* -- 3. the strip, the reminder, the refusals -------------------------------- */

    const head = cv.headerOf({ permissionMode: 'plan', turns: 14, gated: true }, { contextTokens: 102_000 });
    check('a session started here says so, with its mode, its turns and its context',
      head.badge === 'Started here' && head.parts.join(' | ') === 'mode: plan | 14 turns · 102k ctx' && head.ungated === false);
    check('context nobody read is left out of the strip, not written as 0',
      cv.headerOf({ permissionMode: 'plan', turns: 1, gated: true }).parts.join(' | ') === 'mode: plan | 1 turn');
    check('a session Studio only reads is "Read only" and claims nothing else',
      cv.headerOf({ permissionMode: 'read-only' }, { readOnly: true }).badge === 'Read only'
      && cv.headerOf({}, { readOnly: true }).parts.length === 0);
    check('a session started here without the gate says it has none', cv.headerOf({ gated: false }).ungated === true
      && /No approval gate/.test(chatJs));
    check('a waiting request is said in the conversation, and Review leads to the dock',
      cv.reminderOf([{ agentType: 'crew-frontend-expert' }]) === 'Frontend is waiting for approval'
      && cv.reminderOf([{ agentType: null }, {}, {}]) === 'This session is waiting for approval, and 2 more requests are'
      && cv.reminderOf([]) === null
      && /onReview: \(\) => el\.dock\.focus\(\)/.test(appJs) && /chat\.setWaiting\(next\)/.test(appJs));

    const denials = [
      { tool_name: 'Bash', tool_use_id: 'allowed-1', tool_input: { command: 'node write.js' } },
      { tool_name: 'Write', tool_use_id: 'denied-here', tool_input: { file_path: 'x.txt' } },
    ];
    const allowedHere = (id) => id === 'allowed-1';
    const said = cv.refusals(denials, allowedHere, () => ({ text: 'This command requires approval\nmore' }));
    check('a call allowed in the dock and refused by Claude Code is said, with the harness\'s own reason',
      said.length === 1 && said[0].id === 'allowed-1'
      && said[0].text === 'Allowed here, but Claude Code refused it: Bash · node write.js — This command requires approval', said[0]?.text);
    check('a call the viewer denied is not called a refusal by Claude Code', !said.some((r) => r.id === 'denied-here'));
    // Measured in a real session: Crewforth's own gate blocked a force push the viewer had allowed, and the
    // harness reported it as a hook error. Blaming Claude Code for that would name the wrong refuser.
    const byGate = cv.refusals([denials[0]], allowedHere, () => ({ text: 'PreToolUse:Bash hook error: [bash .claude/hooks/guard-bash.sh]: GUARD (§4.5): stopped' }));
    check('a call another gate blocked is said to have been blocked by a gate, not refused by Claude Code',
      /^Allowed here, but another gate blocked it: Bash · node write\.js — PreToolUse:Bash hook error/.test(byGate[0]?.text), byGate[0]?.text?.slice(0, 80));
    check('with no result on screen the line says only that it did not run',
      cv.refusals([denials[0]], allowedHere)[0]?.text === 'Allowed here, but it did not run: Bash · node write.js');
    check('a tool that ran and failed is not a refusal: only what the result record lists is',
      cv.refusals([], () => true).length === 0 && cv.refusals(undefined, () => true).length === 0);
    check('the page knows what it allowed from its own record of the answers',
      /wasAllowed: \(sessionId, toolUseId, toolName\) =>\s*\(outcomes\.get\(sessionId\) \?\? \[\]\)\.some\(\(o\) => o\.toolUseId === toolUseId && o\.outcome\.startsWith\('allowed'\)\)/.test(appJs)
      && /this\.noteRefusals\(rec\.permission_denials\)/.test(chatJs) && /this\.refused\.add\(r\.id\)/.test(chatJs));

    /* -- 4. the read-only foot --------------------------------------------------- */

    check('Continue here says both things it can turn out to be: the session itself, or a copy',
      /Continues it in Studio\. If it is still open somewhere else, Studio starts a copy instead/.test(chatJs)
      && /the original does not see this, and messages here never reach your terminal/.test(chatJs),
      'the design\'s sentence promised a copy every time; a session nothing else holds is continued itself');
    check('the terminal command at the foot is the server\'s, read before anything runs',
      /\/api\/session\/\$\{encodeURIComponent\(this\.id\)\}\/terminal/.test(chatJs) && /r\?\.plan\?\.line \?\? 'not measured/.test(chatJs));
    check('options are offered on the reply waiting for an answer, not on the history',
      /this\.renderMessage\(m, \{ quick: false \}\)/.test(chatJs) && /if \(quick && !this\.readOnly\)/.test(chatJs)
      && /Clicking an option sends it as your reply\./.test(chatJs));

    const css32 = web('style.css');
    check('a long line in a conversation cannot widen the panel',
      /\.panes \{[^}]*min-width: 0/.test(css32) && /\.pane \{[^}]*min-width: 0/.test(css32)
      && /\.chat-ro-cmd \{[^}]*overflow-wrap: anywhere/.test(css32),
      'measured: a 190-character terminal command made the pane 1236px wide in a 480px column');

    check('on a phone the conversation stops above the approval dock: Review leads somewhere that can be seen',
      /\.shell > \.chat,\s*\.shell > \.newpanel \{ grid-column: auto; position: absolute; z-index: 35; inset: 0 0 var\(--dock-h, 0px\) 0;/.test(css32),
      'it covered the whole stage, dock included, so a waiting request could not be answered from the conversation');

    /* -- 5. one right-hand panel -------------------------------------------------- */

    check('the right-hand panel is one thing at a time: inspector, conversation or New session',
      /el\.chat\.hidden = which !== 'conversation';\s*el\.newPanel\.hidden = which !== 'new';/.test(appJs)
      && /el\.inspector\.hidden = which !== 'inspector';/.test(appJs)
      && /shell\.classList\.toggle\('no-chat', !column\)/.test(appJs));
    check('selecting a node inspects it; the conversation is one click away and comes back when the inspector closes',
      /setRight\('inspector'\);/.test(appJs) && /if \(right === 'inspector'\) setRight\(restRight\(\)\);/.test(appJs)
      && !/kind === 'session' && current\) openConversation\(current\)/.test(appJs),
      'a session node used to open the conversation and the inspector at once');
    check('the conversation and New session share a column, and both are in the page',
      /<section id="chat" class="chat" hidden><\/section>\s*<section id="new-panel" class="newpanel" aria-label="New session" hidden><\/section>/.test(indexHtml));

    /* -- 6. New session: the server's choices -------------------------------------- */

    const modes = ns.modeChoices(['plan', 'acceptEdits', 'default']);
    check('the modes offered are exactly the server\'s, in its order, opening on plan',
      modes.map((m) => m.mode + (m.initial ? '*' : '')).join(' ') === 'plan* acceptEdits default'
      && modes.every((m) => typeof m.says === 'string' && m.says.length > 10));
    check('the panel cannot add a mode: one the server does not offer is not shown',
      ns.modeChoices(['plan']).length === 1 && ns.modeChoices([]).length === 0 && ns.modeChoices(undefined).length === 0
      && !Object.keys(ns.MODE_TEXT).some((m) => /bypass|dontAsk|auto/i.test(m)),
      'and the file has no words ready for a mode that skips the gates');
    const strange = ns.modeChoices(['review', 'plan']);
    check('a mode the server offers and this file has no words for is shown under its own name, not dropped',
      strange.map((m) => `${m.word}:${m.says === null}`).join(' ') === 'review:true Plan:false' && strange[1].initial);
    check('without plan on offer the panel opens on the server\'s first mode, not on one it prefers',
      ns.modeChoices(['acceptEdits', 'default'])[0].initial === true);

    const projects = [
      { key: 'a', cwd: '/w/a', label: 'a', exists: true, branch: 'feat/x', kit: { installed: true, version: '3.0.1' } },
      { key: 'gone', cwd: '/w/gone', label: 'gone', exists: false },
      { key: 'far', cwd: '/w/far', label: 'far', exists: true, local: false },
      { key: 'b', cwd: '/w/b', label: 'b', exists: true, current: true, branch: null },
    ];
    const pc = ns.projectChoices(projects, null);
    check('a session can be started only where its directory still is, on this machine',
      pc.map((p) => p.key + (p.initial ? '*' : '')).join(' ') === 'a b*');
    check('the panel opens on the project of the session being looked at',
      ns.projectChoices(projects, 'a').find((p) => p.initial).key === 'a');
    check('the branch is named only when the server read one',
      ns.runsIn(pc[0]).branch === 'feat/x' && ns.runsIn(pc[1]).branch === null && ns.runsIn(null) === null
      && /if \(r\.branch\) parts\.push\(' on branch '/.test(web('newsession.js')));

    /* -- 7. two clicks, one session ------------------------------------------------ */

    let starts = 0;
    const once = cv.oneShot(async () => { starts += 1; return { ok: true, id: starts }; });
    const [r1, r2] = await Promise.all([once(), once()]);
    check('two clicks while the first is in flight start one session', starts === 1 && r1.id === 1 && r2.id === 1);
    const r3 = await once();
    check('a click after the first start has finished still starts nothing: it gets the first one\'s answer',
      starts === 1 && r3.id === 1);
    // The control. A guard that only refuses while a request is in flight is what the bar's button had, and it
    // lets the same second click through: this is the case the line above has to tell apart.
    let naive = 0;
    let busy = false;
    const inFlightOnly = async () => { if (busy) return null; busy = true; naive += 1; await null; busy = false; return { ok: true }; };
    await inFlightOnly();
    await inFlightOnly();
    check('twin: a guard that only watches the request in flight starts two', naive === 2,
      'so the second click in the case above really did come after the first had finished');
    once.arm();
    await once();
    check('opening the panel again arms one more start', starts === 2);
    let refusals = 0;
    const picky = cv.oneShot(async () => { refusals += 1; return refusals === 1 ? { ok: false, reason: 'no such directory' } : { ok: true }; });
    const first = await picky();
    const second = await picky();
    check('a start that was refused can be tried again without reopening the panel',
      first.ok === false && second.ok === true && refusals === 2 && picky.spent());

    const dom32 = installDom();
    try {
      const { NewSession } = await import(`../../kit/studio/web/newsession.js?dom=${Date.now()}`);
      const posted = [];
      const root = document.createElement('section');
      root.hidden = true;
      let closed = 0;
      const panel = new NewSession(root, {
        onClose: () => { closed += 1; },
        onStart: async (a) => { posted.push(a); return { ok: true }; },
      });
      const opened = panel.open({ projects, modes: ['plan', 'acceptEdits', 'default'], preferKey: 'a' });
      check('the bar\'s button opens the panel once: a second click on it is not a second panel',
        opened === true && panel.open({ projects, modes: ['plan'] }) === false && root.hidden === false
        && /if \(opened\) setRight\('new'\);/.test(appJs));
      check('the bar\'s button starts nothing by itself',
        !/el\.newSession\.addEventListener\('click', async/.test(appJs) && !/newSessionLabel/.test(appJs));
      panel.firstEl.value = '  Rotate the key.  ';
      const a = panel.submit();
      const b = panel.submit();
      await Promise.all([a, b]);
      await panel.submit();
      check('three clicks on Start session start one session, with what the panel showed',
        posted.length === 1 && posted[0].cwd === '/w/a' && posted[0].permissionMode === 'plan' && posted[0].first === 'Rotate the key.',
        JSON.stringify(posted));
      check('a started session closes the panel', root.hidden === true && closed === 1);
      const note = [...walkText(root)].join(' ');
      check('the panel says what starting here means before the button',
        /Every tool call in this session waits for your approval here in Studio\. If Studio is closed, the request is denied\./.test(note)
        && /Modes that skip Crewforth\\?'s gates are not offered\./.test(web('newsession.js')));
    } finally {
      dom32();
    }

    /* -- 8. the server's two additions --------------------------------------------- */

    const repo = path.join(tmp, 'repo');
    fs.mkdirSync(path.join(repo, '.git'), { recursive: true });
    fs.writeFileSync(path.join(repo, '.git', 'HEAD'), 'ref: refs/heads/feat/payment-retries\n');
    check('a project\'s branch is read from its .git/HEAD', await headBranch(repo) === 'feat/payment-retries');
    const wt = path.join(tmp, 'worktree');
    const wtGit = path.join(tmp, 'repo', '.git', 'worktrees', 'wt');
    fs.mkdirSync(wt);
    fs.mkdirSync(wtGit, { recursive: true });
    fs.writeFileSync(path.join(wt, '.git'), `gitdir: ${wtGit}\n`);
    fs.writeFileSync(path.join(wtGit, 'HEAD'), 'ref: refs/heads/fix/flaky-test\n');
    check('a worktree\'s branch is read through the pointer its .git file holds', await headBranch(wt) === 'fix/flaky-test');
    fs.writeFileSync(path.join(repo, '.git', 'HEAD'), '4b825dc642cb6eb9a060e54bf8d69288fbee4904\n');
    const plain = path.join(tmp, 'plain');
    fs.mkdirSync(plain);
    check('a detached HEAD, a directory that is not a repository and no directory at all name no branch',
      await headBranch(repo) === null && await headBranch(plain) === null && await headBranch(null) === null
      && await headBranch(path.join(tmp, 'missing')) === null);
    check('reading the branch starts no process',
      !/spawn|execFile|exec\(/.test((read(path.join(STUDIO, 'server', 'lib', 'projects.js')) ?? '').split('export async function headBranch')[1].split('\n}\n')[0]));

    const transcript = path.join(tmp, 'session.jsonl');
    const rec = (o) => `${JSON.stringify({ timestamp: '2026-09-30T10:00:00.000Z', ...o })}\n`;
    fs.writeFileSync(transcript,
      rec({ type: 'user', message: { role: 'user', content: 'Add retries.' } })
      + rec({ type: 'assistant', message: { role: 'assistant', content: [
        { type: 'text', text: 'On it.' },
        { type: 'tool_use', id: 'toolu_run', name: 'Bash', input: { command: 'npm test' } },
        { type: 'tool_use', id: 'toolu_del', name: 'Agent', input: { subagent_type: 'Explore', description: 'Find callers', prompt: 'x' } },
        { type: 'tool_use', id: 'toolu_open', name: 'Read', input: { file_path: 'a.ts' } },
      ] } })
      + rec({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_run', content: `${'y'.repeat(6000)}\n42 passed` }] } })
      + rec({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_del', is_error: true, content: [{ type: 'text', text: 'agent failed' }] }] } }));
    const conv = await readConversation({ file: transcript });
    const blocks = conv.messages.find((m) => m.role === 'assistant')?.blocks ?? [];
    const by = Object.fromEntries(blocks.filter((b) => b.kind === 'tool').map((b) => [b.id, b]));
    check('history carries each tool call\'s result with it, cut to its tail with the cut said',
      by.toolu_run?.result?.truncated === true && by.toolu_run.result.text.endsWith('42 passed')
      && by.toolu_run.result.text.length === 4096 && by.toolu_run.result.length === 6010 && by.toolu_run.result.error === false);
    check('history says which call was a delegation and to whom, and that its result was an error',
      by.toolu_del?.subagentType === 'Explore' && by.toolu_del.result?.error === true && by.toolu_del.result.text === 'agent failed');
    check('a call with no result in the transcript has `result: null`, not an empty one',
      by.toolu_open && by.toolu_open.result === null && by.toolu_open.subagentType === null);
    check('a tool result is still not shown as something the viewer said',
      conv.messages.filter((m) => m.role === 'user').map((m) => m.text).join('|') === 'Add retries.');
    check('the page and the server cut a result the same way',
      cv.resultFrom({ content: `${'y'.repeat(6000)}\n42 passed` }).text === by.toolu_run.result.text);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

/* ------------------------------------------------------ §33 the Timeline ---
   The same session against time. A bar is where an agent was and what it was doing;
   what the data does not hold is not drawn — no start, no bar — and the one change of
   state a bar can show is a wait on the viewer, from the server's own record. */

process.stdout.write('\n== §33 the Timeline ==\n');

{
  const tp = await import(`../../kit/studio/web/timeline-plan.js?t=${Date.now()}`);
  const { logApprovals, APPROVAL_LOG_MAX } = await import(`../../kit/studio/server/lib/permissions.js?l=${Date.now()}`);
  const { agentDetail: readAgent } = await import(`../../kit/studio/server/lib/graph.js?d=${Date.now()}`);
  const web = (f) => read(path.join(WEB_ROOT, f)) ?? '';
  const appJs = web('app.js');
  const indexHtml = web('index.html');
  const css33 = web('style.css');
  const sessionJs = read(path.join(STUDIO, 'server', 'lib', 'session.js')) ?? '';
  const serverJs = read(path.join(STUDIO, 'server', 'index.js')) ?? '';
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-studio-tl-'));

  try {
    const T = 1_800_000_000_000;
    const M = 60_000;
    const agent = (id, status, startMin, endMin, extra = {}) => ({
      id, kind: 'agent', agentType: 'Explore', status, parentId: 'session', workflow: null,
      startedAt: startMin == null ? null : T + startMin * M, endedAt: endMin == null ? null : T + endMin * M, ...extra,
    });
    const now = T + 30 * M;

    /* -- 1. bars ------------------------------------------------------------------ */

    const tones = (n, approvals) => tp.segments(n, approvals, now).map((s) => `${s.tone}:${(s.from - T) / M}-${(s.to - T) / M}`).join(' ');
    check('an agent with no recorded start has no bar: there is nowhere to put one',
      tp.segments(agent('a', 'running', null, null), null, now).length === 0);
    check('a running agent\'s bar runs to now; a finished one ends where it ended',
      tones(agent('a', 'running', 10, null)) === 'busy:10-30' && tones(agent('b', 'done', 5, 12)) === 'done:5-12');
    const failed = tp.segments(agent('f', 'failed', 5, 14), null, now);
    check('a failed agent\'s bar is failed, and where it stopped is marked',
      failed.length === 1 && failed[0].tone === 'fail' && failed[0].failedAt === T + 14 * M
      && tp.segments(agent('k', 'killed', 5, 14), null, now)[0].tone === 'fail');
    check('a status the panel has no word for is drawn quiet, not as done',
      tp.segments(agent('z', 'zombie', 5, 14), null, now)[0].tone === 'quiet');
    const waits = [
      { agentId: 'w', askedAt: T + 12 * M, endedAt: T + 14 * M, outcome: 'allowed' },
      { agentId: 'someone-else', askedAt: T + 15 * M, endedAt: T + 16 * M, outcome: 'denied' },
      { agentId: 'w', askedAt: T + 26 * M, endedAt: null, outcome: null },
    ];
    check('a bar is split where the agent waited on the viewer, and a wait still open runs to now',
      tones(agent('w', 'running', 10, null), waits) === 'busy:10-12 wait:12-14 busy:14-26 wait:26-30');
    check('another agent\'s waits are not drawn on this one', tones(agent('x', 'running', 10, null), waits) === 'busy:10-30');
    check('with no record of approvals the bar is one piece: a wait is not guessed',
      tp.segments(agent('w', 'running', 10, null), null, now).length === 1);

    /* -- 2. rows ------------------------------------------------------------------ */

    const session = { id: 'session', kind: 'session', startedAt: T };
    const nodes = [
      session,
      agent('e1', 'done', 1, 3), agent('e2', 'done', 2, 4), agent('e3', 'running', 20, null),
      agent('b1', 'running', 2, null, { agentType: 'crew-backend-expert' }),
      ...[1, 2, 3, 4, 5, 6, 7, 8].map((i) => agent(`w${i}`, i === 2 ? 'failed' : 'done', 5 + i, 7 + i, { agentType: `kind-${i}`, workflow: 'wf-audit' })),
    ];
    const list = tp.rows(nodes, { group: 'run', now });
    const shape = list.map((r) => `${r.kind}:${r.label ?? r.count}`);
    check('what the session started itself comes first, then each workflow run',
      shape[0] === 'group:Session · direct' && shape.includes('group:wf-audit')
      && shape.indexOf('group:wf-audit') > shape.indexOf('group:Session · direct'), shape.join(' | '));
    check('several agents of one type in a group are one row, and a single one is its own',
      shape[1] === 'merged:Explore × 3' && shape[2] === 'agent:Backend' && list[2].real === 'crew-backend-expert');
    const merged = list[1];
    check('a merged row puts overlapping bars on two thin lanes, never more',
      merged.lanes.length === 2 && merged.lanes[0].length + merged.lanes[1].length === 3
      && tp.lanes([{ from: 0, to: 5 }, { from: 6, to: 9 }]).length === 1
      && tp.lanes([{ from: 0, to: 9 }, { from: 1, to: 9 }, { from: 2, to: 9 }, { from: 3, to: 9 }]).length === 2);
    check('a group longer than six rows shows four and a link to the rest',
      shape.filter((x) => x.startsWith('agent:Kind ')).length === 4 && shape[shape.length - 1] === 'more:4', shape.slice(-6).join(' | '));
    check('the link shows the rest',
      tp.rows(nodes, { group: 'run', now, expanded: new Set(['run:wf-audit']) }).filter((r) => r.group === 'run:wf-audit' && r.kind === 'agent').length === 8);
    const folded = tp.rows(nodes, { group: 'run', now, folded: new Set(['run:wf-audit']) });
    const head = folded.find((r) => r.id === 'run:wf-audit');
    check('a folded group keeps its members\' bars on its own row: out of sight is not out of time',
      head.folded && head.lanes.flat().length === 8 && !folded.some((r) => r.group === 'run:wf-audit'));
    check('a group\'s row counts its members by status, failures first',
      head.sub === '8 agents · 1 failed · 7 done', head.sub);
    check('under Agent type the group is the type, so its agents are not merged again; under None nothing is grouped',
      tp.rows(nodes, { group: 'type', now }).filter((r) => r.kind === 'merged').length === 0
      && tp.rows(nodes, { group: 'none', now }).every((r) => r.kind === 'agent')
      && tp.rows(nodes, { group: 'none', now }).length === 12);
    check('an agent waiting on the viewer says so on its row, ahead of what the transcript says',
      tp.agentSub(agent('q', 'running', 1, null), new Set(['q'])).text === 'needs you'
      && tp.agentSub(agent('q', 'zombie', 1, null), new Set()).text === 'zombie'
      && tp.countsSub([agent('q', 'running', 1, null), agent('r', 'done', 1, 2)], new Set(['q'])) === '1 need you · 1 done');

    /* -- 3. time ------------------------------------------------------------------- */

    const ext = tp.extent(nodes, now, true);
    check('the session\'s time runs from its first start to now while it is live', ext.from === T && ext.to === now);
    check('a session that has ended stops at its last activity, not at now',
      tp.extent([session, agent('a', 'done', 1, 9)], now, false).to === T + 9 * M);
    const following = tp.windowOf(ext, '15m', { follow: true });
    check('following, the view ends at now', following.to === now && following.span === 15 * M);
    const held = tp.windowOf(ext, '5m', { follow: false, end: T + 12 * M });
    check('not following, the view stays where the viewer left it', held.to === T + 12 * M && held.from === T + 7 * M);
    check('the view cannot be dragged past either end of the session',
      tp.windowOf(ext, '5m', { follow: false, end: T + 999 * M }).to === now
      && tp.windowOf(ext, '5m', { follow: false, end: T - 999 * M }).from === T);
    check('a range longer than the session shows the session, not empty time before it',
      tp.windowOf(ext, '1h', { follow: true }).from === T && tp.windowOf(ext, 'all').span === 30 * M);
    check('the four ranges are the spec\'s, and the steps stop at both ends',
      tp.RANGES.map((r) => r.key).join(' ') === '5m 15m 1h all' && tp.stepRange('5m', -1) === null
      && tp.stepRange('all', 1) === null && tp.stepRange('15m', 1) === '1h');
    const win = { from: T + 10 * M, to: T + 20 * M, span: 10 * M };
    const inside = tp.place({ from: T + 12 * M, to: T + 15 * M }, win, 1000);
    const cut = tp.place({ from: T + 5 * M, to: T + 25 * M }, win, 1000);
    check('a bar is placed by its times, and cut square where it runs off the view',
      inside.left === 200 && inside.width === 300 && !inside.cutLeft && cut.left === 0 && cut.width === 1000 && cut.cutLeft && cut.cutRight);
    check('a bar wholly outside the view is not drawn', tp.place({ from: T, to: T + 5 * M }, win, 1000) === null);
    check('a very short bar is still wide enough to see and to click', tp.place({ from: T + 12 * M, to: T + 12 * M + 50 }, win, 1000).width === 2);
    const marks = tp.ticks(win, 1000);
    check('the axis is marked at round moments, a handful of them',
      marks.length >= 2 && marks.length <= 11 && marks.every((m) => m.at % 60_000 === 0), `${marks.length} marks`);

    /* -- 4. what is said about the waits, and about the agent ----------------------- */

    check('a session Studio did not start says its waits are not measured, in the user\'s words',
      tp.waitNote(null).measured === false && tp.waitNote(null).text === 'Not measured: this session\'s approvals are not seen by Studio.');
    const noted = tp.waitNote({ gated: true, startedAt: T + 3 * M });
    check('a session started here says from when its waits are recorded',
      noted.measured === true && /^Waiting periods since Studio started this session at \d\d:\d\d\.$/.test(noted.text), noted.text);
    check('a session started here without the gate has no waits to record, and says that',
      tp.waitNote({ gated: false, startedAt: T }).measured === false);
    const fmt = { duration: (ms) => `${Math.round(ms / M)}m`, tokens: (t) => `${t / 1000}k` };
    check('the drawer\'s line carries only what was read: unread tokens are left out, not written as 0',
      /^\d\d:\d\d → \d\d:\d\d · 7m · 31 tool calls$/.test(tp.factsOf(agent('a', 'done', 5, 12, { toolCount: 31, tokens: null }), now, fmt))
      && / · 57k tokens$/.test(tp.factsOf(agent('a', 'done', 5, 12, { toolCount: 31, tokens: 57_000 }), now, fmt))
      && / → now · /.test(tp.factsOf(agent('a', 'running', 5, null, { toolCount: 1 }), now, fmt)));

    /* -- 5. the server's record of approvals --------------------------------------- */

    const log = [];
    const pend = (id, askedAt, extra = {}) => ({ toolUseId: id, toolName: 'Bash', askedAt, agentId: null, agentType: null, ...extra });
    const decisions = new Map();
    logApprovals(log, [pend('a', T, { agentId: 'ag1', agentType: 'Explore' }), pend('b', T + 1000)], decisions, T + 1500, 45);
    check('a request is recorded when it is first seen waiting, with who asked',
      log.length === 2 && log[0].endedAt === null && log[0].agentId === 'ag1' && log[0].askedAt === T);
    decisions.set('a', 'deny');
    logApprovals(log, [pend('b', T + 1000)], decisions, T + 4000, 45);
    check('a request that is gone is closed with the answer the panel recorded',
      log[0].endedAt === T + 4000 && log[0].outcome === 'denied' && log[1].endedAt === null && decisions.size === 0);
    logApprovals(log, [], decisions, T + 1000 + 45_000, 45);
    check('one that is gone at the hook\'s deadline with no answer timed out', log[1].outcome === 'timed-out');
    const early = [];
    logApprovals(early, [pend('c', T)], new Map(), T, 45);
    logApprovals(early, [], new Map(), T + 5000, 45);
    check('one that is gone early with no answer is "unanswered": no verdict is made up for it',
      early[0].outcome === 'unanswered');
    const many = [];
    logApprovals(many, [pend('open', T)], new Map(), T, 45);
    // The same entry, not one like it: a dropped request that is still pending would be written again on the
    // next change, and a check that only looked for its id would not see that it had been lost in between.
    const stillWaiting = many[0];
    for (let i = 0; i < APPROVAL_LOG_MAX + 20; i += 1) {
      logApprovals(many, [pend('open', T), pend(`r${i}`, T + i)], new Map(), T + i, 45);
      logApprovals(many, [pend('open', T)], new Map(), T + i + 1, 45);
    }
    check('the record keeps the last 200 and never drops a request that is still waiting',
      APPROVAL_LOG_MAX === 200 && many.length === 200 && many.includes(stillWaiting) && stillWaiting.endedAt === null
      && many.filter((e) => e.toolUseId === 'open').length === 1 && !many.some((e) => e.toolUseId === 'r0'));
    check('the record is the session\'s, travels in its summary, and learns each answer the panel records',
      /logApprovals\(this\.approvals, reqs, this\.decisions, Date\.now\(\), this\.gate\.waitSeconds\)/.test(sessionJs)
      && /approvals: this\.approvals,/.test(sessionJs) && /if \(out\.ok\) s\.noteDecision\(toolUseId, body\.verdict\)/.test(serverJs));

    /* -- 6. the last error ----------------------------------------------------------- */

    const sub = path.join(tmp, 'subagents');
    const nested = path.join(sub, 'workflows', 'wf-1');
    fs.mkdirSync(nested, { recursive: true });
    const rec = (at, o) => `${JSON.stringify({ timestamp: new Date(T + at * 1000).toISOString(), ...o })}\n`;
    const transcript = rec(0, { type: 'user', message: { role: 'user', content: 'Backfill the column.' } })
      + rec(1, { type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't1', name: 'Read', input: { file_path: 'a.sql' } }, { type: 'tool_use', id: 't2', name: 'Bash', input: { command: 'migrate' } }] } })
      + rec(2, { type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', is_error: true, content: 'no such file' }] } })
      + rec(3, { type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't2', is_error: true, content: `${'n'.repeat(5000)}\nmigration 0042 failed` }] } })
      + rec(4, { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'It failed.' }] } });
    fs.writeFileSync(path.join(sub, 'agent-top1.jsonl'), transcript);
    fs.writeFileSync(path.join(sub, 'agent-top1.meta.json'), '{"agentType":"crew-database-expert"}');
    fs.writeFileSync(path.join(nested, 'agent-deep1.jsonl'), rec(0, { type: 'user', message: { role: 'user', content: 'Check.' } }) + rec(1, { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'Fine.' }] } }));
    fs.writeFileSync(path.join(nested, 'agent-deep1.meta.json'), '{"agentType":"Explore"}');
    const top = await readAgent({ subagentsDir: sub }, 'top1');
    check('the agent\'s detail carries its last error: the tool, the moment, and the end of what it said',
      top.errors === 2 && top.lastError?.tool === 'Bash' && top.lastError.at === T + 3000
      && top.lastError.text.endsWith('migration 0042 failed') && top.lastError.truncated === true && top.lastError.length === 5022,
      `${top.errors} errors, last from ${top.lastError?.tool}`);
    const deep = await readAgent({ subagentsDir: sub }, 'deep1');
    check('an agent a workflow started is found one directory down, and one with no error has `lastError: null`',
      deep !== null && deep.report === 'Fine.' && deep.lastError === null && deep.errors === 0 && deep.agentType === 'Explore',
      'the detail used to answer "no such agent" for every agent in a workflow run');
    check('an agent that is in neither place is still "no such agent"', await readAgent({ subagentsDir: sub }, 'nobody') === null);

    /* -- 7. the view ------------------------------------------------------------------ */

    const dom33 = installDom();
    try {
      const { Timeline } = await import(`../../kit/studio/web/timeline.js?t=${Date.now()}`);
      const root = document.createElement('div');
      const changes = [];
      const chosen = [];
      const tl = new Timeline(root, { onChange: (s) => changes.push(s), onSelect: (n) => chosen.push(n?.id ?? null), fmt });
      tl.now = () => now;
      tl.trackWidth = () => 1000;
      tl.labelWidth = () => 280;
      tl.setSession('s1');
      tl.setLive(true);
      tl.setNodes(nodes);
      const agentRow = () => tl.rowsEl.children.find((r) => r.classList.contains('tl-agent'));
      const row = agentRow();
      check('a row answers one click once: the label inside it has no listener of its own',
        (row._on?.click ?? []).length === 1 && !row.children[0]._on?.click,
        'two listeners chose the agent and un-chose it in the same click');
      row.emit('click');
      check('clicking a row chooses its agent and opens the drawer', tl.selected === 'b1' && tl.drawer.hidden === false && chosen.join() === 'b1');
      agentRow().emit('click');
      check('clicking it again lets go', tl.selected === null && tl.drawer.hidden === true);
      tl.folded.add('run:wf-audit');
      tl.select('w7');
      check('choosing an agent from outside opens the group it is folded into and shows every row of it',
        !tl.folded.has('run:wf-audit') && tl.expanded.has('run:wf-audit') && tl.selected === 'w7');
      check('the Timeline opens following now, on fifteen minutes', changes.length > 0 && tl.state().follow === true && tl.state().range === '15m');
      tl.pan(-200);
      check('moving the view by hand stops following', tl.follow === false && tl.state().follow === false && tl.end !== null);
      tl.setFollow(true);
      check('Follow now takes the view back to now', tl.follow === true && tl.end === null && tl.win.to === now);
      tl.setLive(false);
      check('a session that has ended has no now to follow', tl.state().follow === false && tl.state().live === false);
    } finally {
      dom33();
    }

    check('the toolbar switches between the graph and the Timeline, and each view shows only its own controls',
      /id="view-graph"[^>]*role="tab"[^>]*aria-selected="true"/.test(indexHtml) && /id="view-timeline"[^>]*role="tab"/.test(indexHtml)
      && /for \(const c of document\.querySelectorAll\('\.toolbar \[data-view\]'\)\) c\.hidden = !c\.dataset\.view\.split\(' '\)\.includes\(view\);/.test(appJs)
      && ['tb-density', 'tb-expand', 'tb-fold', 'tb-zoom-out', 'tb-zoom', 'tb-zoom-in', 'tb-fit'].every((i) => new RegExp(`id="${i}" data-view="graph"`).test(indexHtml))
      && (indexHtml.match(/data-view="timeline"/g) ?? []).length === 4);
    check('what is selected stays selected across the switch, in both directions',
      /const carried = select \?\? \(was === 'timeline' \? timeline\.selected : was === 'list' \? list\.selected : canvas\.selected\) \?\? null;/.test(appJs)
      && /if \(carried && canvas\.nodes\.has\(carried\)\) canvas\.focus\(carried\);/.test(appJs)
      && /onShowOnGraph: \(n\) => \{ setView\('graph', n\.id\); \}/.test(appJs));
    check('Group and Show are one choice for both views',
      /timeline\.setGroup\(st\.group\);/.test(appJs) && (appJs.match(/timeline\.setFilter\(/g) ?? []).length >= 3);
    check('the attention strip, the dock and a conversation card go to the agent in whichever view is open',
      /function goTo\(agentId\) \{\s*if \(view === 'graph'\) \{ canvas\.focus\(agentId\); return; \}\s*if \(view === 'list'\) \{ list\.select\(agentId\); canvas\.select\(agentId\); return; \}\s*timeline\.select\(agentId\);/.test(appJs)
      && (appJs.match(/goTo\(/g) ?? []).length >= 5);
    check('the waits drawn are the server\'s record for this session, and none for a session Studio did not start',
      /timeline\.setOwned\(current \? owned\.get\(current\) \?\? null : null\);/.test(appJs));
    check('a bar\'s colour is its status and nothing else',
      /\.tl-bar\[data-tone="busy"\] \{ background: var\(--status-busy\); \}/.test(css33)
      && /\.tl-bar\[data-tone="fail"\] \{ background: var\(--status-fail\); \}/.test(css33)
      && /\.tl-bar\[data-tone="wait"\] \{ background: var\(--status-waiting\); \}/.test(css33)
      && /\.tl-bar\[data-tone="done"\] \{ background: color-mix\(in srgb, var\(--status-good\)/.test(css33));
    check('the page opens with no right-hand column reserved',
      /<div class="shell no-chat">/.test(indexHtml),
      'measured: the stage was 678px wide in a 1440px window until the first panel was opened');
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

/* ------------------------------- §34 the List, the phone, and the states ---
   The List is the session by what needs the reader, in an order that does not move.
   A phone opens on it. A server that has gone quiet leaves the last picture up and
   says it is old; a machine with no sessions says what Studio is waiting for. */

process.stdout.write('\n== §34 the List, the phone, and the states ==\n');

{
  const lp = await import(`../../kit/studio/web/list-plan.js?t=${Date.now()}`);
  const lv = await import(`../../kit/studio/web/liveness.js?o=${Date.now()}`);
  const nv = await import(`../../kit/studio/web/nav.js?f=${Date.now()}`);
  const web = (f) => read(path.join(WEB_ROOT, f)) ?? '';
  const appJs = web('app.js');
  const indexHtml = web('index.html');
  const css34 = web('style.css');

  const T = 1_800_000_000_000;
  const M = 60_000;
  const now = T + 30 * M;
  const agent = (id, status, extra = {}) => ({ id, kind: 'agent', agentType: `type-${id}`, status, startedAt: T, endedAt: T + 5 * M, description: `task ${id}`, ...extra });
  const nodes = [
    { id: 'session', kind: 'session' },
    agent('d1', 'done'), agent('r1', 'running', { startedAt: T + 22 * M, endedAt: null }), agent('f1', 'failed', { workflow: 'wf-audit', errors: 3 }),
    agent('s1', 'starting', { startedAt: null, endedAt: null }), agent('e1', 'ended'), agent('z1', 'zombie'), agent('k1', 'killed', { endedAt: T + 9 * M }),
    agent('d2', 'done', { endedAt: T + 8 * M }),
  ];
  const req = (key, sessionId, askedAt, extra = {}) => ({ key, sessionId, sessionName: `name-${sessionId}`, toolUseId: key, toolName: 'Bash', detail: 'npm run build', askedAt, waitSeconds: 45, agentId: null, agentType: null, ...extra });
  const queue = [req('other', 's-other', T), req('mine', 's-here', T + 1000, { agentId: 'r1', agentType: 'crew-frontend-expert' })];

  /* -- 1. the order ----------------------------------------------------------- */

  const list = lp.sections(nodes, { queue, current: 's-here', now });
  check('the List\'s order is fixed: Needs you, Failed, Running, Done, then what is left under its own name',
    list.map((s) => s.key).join(' ') === 'needs failed running done status:ended status:zombie', list.map((s) => `${s.title} · ${s.count}`).join(' | '));
  check('Needs you is every request waiting, this session\'s first',
    list[0].cards.map((c) => c.key).join() === 'mine,other' && list[0].foldable === false && list[0].rows.length === 0);
  check('killed and stopped are listed with the failures, newest first, and say which they were',
    list[1].rows.map((r) => r.id).join() === 'k1,f1' && list[1].rows[0].line === 'killed' && list[1].rows[1].line === 'in wf-audit · 3 errors');
  check('a running agent shows how long it has been going; one with no start recorded shows no time',
    list[2].rows.map((r) => `${r.id}:${r.aside}`).join() === 'r1:8m,s1:starting'
    && lp.sections([agent('q', 'running', { startedAt: null })], { now })[0].rows[0].aside === null,
    list[2].rows.map((r) => `${r.id}:${r.aside}`).join());
  check('Done is folded until asked for; Failed and Running are open',
    list[3].folded === true && list[1].folded === false && list[2].folded === false
    && lp.sections(nodes, { now, folded: new Map([['done', false]]) }).find((s) => s.key === 'done').folded === false);
  check('a status the panel has no word for gets a section under its own name, not a place in one of the four',
    list[5].title === 'zombie' && list[5].rows[0].id === 'z1' && list[4].title === 'Ended'
    && !['failed', 'running', 'done'].some((k) => list.find((s) => s.key === k).rows.some((r) => r.id === 'z1')));
  check('a section with nothing in it is left out, and a session with nothing at all has no sections',
    lp.sections([agent('a', 'done')], { now }).map((s) => s.key).join() === 'done' && lp.sections([], { now }).length === 0);
  check('a request card says who wants what', lp.wants(queue[1]) === 'wants to run Bash');

  /* -- 2. the phone ----------------------------------------------------------- */

  check('a window opens on the view the viewer chose; with no choice, the List on a phone and the graph elsewhere',
    lp.defaultView('timeline', true) === 'timeline' && lp.defaultView(null, true) === 'list' && lp.defaultView(null, false) === 'graph'
    && lp.defaultView('nonsense', false) === 'graph');
  check('a default is not remembered as a choice',
    /setView\(defaultView\(stored, phoneBand\.matches\), null, Boolean\(stored\)\);/.test(appJs)
    && /if \(remember\) store\.set\('crewforth-studio-view', view\);/.test(appJs),
    'otherwise a phone visit would open the List on the desktop forever after');
  check('the graph and the Timeline still open on a phone, and say they are meant for more room',
    lp.narrowWarning('graph', true) === 'Best on a wider screen' && lp.narrowWarning('timeline', true) !== null
    && lp.narrowWarning('list', true) === null && lp.narrowWarning('graph', false) === null);
  const phone = css34.slice(css34.indexOf('@media (max-width: 639px) {'));
  check('on a phone a request\'s three answers are 44px tall, one under the other',
    /\.ls-acts \{ flex-direction: column; \}/.test(phone) && /\.ls-acts \.btn \{ height: 44px; \}/.test(phone));
  check('on a phone the inspector is a page with a way back, and the navigator is a drawer the menu opens',
    /\.ihead-back \{ display: inline-flex; \}/.test(phone) && /\.ihead-close \{ display: none; \}/.test(phone)
    && /#menu-btn \{ display: inline-flex; \}/.test(phone) && /\.shell\.side-open > \.side \{/.test(phone)
    && /id="menu-btn"[^>]*aria-label="Open the navigator"[^>]*aria-expanded="false"/.test(indexHtml)
    && /setDrawer\(!shell\.classList\.contains\('side-open'\)\)/.test(appJs));
  check('the session\'s name and its summary move under the bar on a phone, and back when the window widens',
    /el\.phoneHead\.append\(el\.crumb, el\.summary\);/.test(appJs) && /el\.bar\.insertBefore\(el\.summary, afterSummary\);/.test(appJs)
    && /\.bar \.crumb, \.bar \.chips, \.bar #fullscreen \{ display: none; \}/.test(phone));

  check('full screen takes nothing of the panel away: no rule hides or resizes a panel because the page is full screen',
    !/:fullscreen/.test(css34.replace(/\/\*[\s\S]*?\*\//g, '')),
    'the navigator, the inspector and the conversation could not be opened there');

  /* -- 3. the view switch ----------------------------------------------------- */

  check('there are three views, and g, t and l go to them',
    /id="view-list"[^>]*role="tab"[^>]*aria-label="List view"/.test(indexHtml)
    && /e\.key === 'g'\) \{\s*setView\('graph'\);/.test(appJs) && /e\.key === 't'\) \{\s*setView\('timeline'\);/.test(appJs)
    && /e\.key === 'l'\) \{\s*setView\('list'\);/.test(appJs));
  check('in the List the requests are cards with their answers, so the dock stands down and the strip is not repeated',
    /dock\.setSuppressed\(view === 'list'\);/.test(appJs) && /list\.setQueue\(next\);/.test(appJs)
    && /\.stage\[data-view="list"\] \.attention \{ display: none; \}/.test(css34));
  check('a control belongs to the views it names, and Group is not offered where nothing is grouped',
    /id="tb-group" data-view="graph timeline"/.test(indexHtml)
    && /c\.hidden = !c\.dataset\.view\.split\(' '\)\.includes\(view\);/.test(appJs));
  const optBase = css34.indexOf('#tb-options { display: none; }');
  const optShown = css34.indexOf('#tb-options { display: inline-flex; }');
  check('a toolbar that gives up Group, Density, Show, Expand and Fold gives them up only together with a menu that holds them',
    optBase > 0 && optShown > optBase
    && /\.toolbar:is\(\[data-fit="2"\], \[data-fit="3"\]\) :is\(#tb-group, #tb-density, #tb-show, #tb-expand, #tb-fold\) \{ display: none; \}\s*\.toolbar:is\(\[data-fit="2"\], \[data-fit="3"\]\) #tb-options \{ display: inline-flex; \}/.test(css34)
    && /el\.tbOptions\.addEventListener\('click'/.test(appJs) && /\{ label: 'Expand all', run: \(\) => canvas\.expandAll\(\) \}/.test(appJs),
    'the rule that hides the menu comes before the one that shows it: the other way round it never appeared');

  // The steps were widths in the stylesheet (880, 760, 520 px), and the first was a guess that was 200 px low:
  // with its words on, the Graph's toolbar ran out of its box and over the panel beside it. No width is assumed now.
  const tf = await import(`../../kit/studio/web/toolbar-fit.js?t=${Date.now()}`);
  const tried = [];
  const upTo = (n) => (step) => { tried.push(step); return step < n; };
  const fits0 = tf.fitLevel(upTo(0));
  const fits2 = tf.fitLevel(upTo(2));
  const order = tried.join(',');
  const never = tf.fitLevel(() => true);
  check('the toolbar takes the first step at which it fits, trying each from the first, and stops at the last when nothing fits',
    fits0 === 0 && fits2 === 2 && order === '0,0,1,2' && never === tf.FIT_MAX && tf.FIT_MAX === 3,
    `fits at once ${fits0} · fits at the third ${fits2} · tried ${order} · never fits ${never}`);
  const box = { right: 1000, padRight: 12 };
  check('running over is asked of the boxes and counts the row\'s own end padding, which scrollWidth may leave out',
    tf.runsOver(box, [400, 988]) === false && tf.runsOver(box, [988.4]) === false
    && tf.runsOver(box, [989]) === true && tf.runsOver(box, [995]) === true && tf.runsOver(box, []) === false,
    'a button ending inside the padding is over: at 995 of 1000 scrollWidth would still call it a fit');
  check('the toolbar is measured where it is: no width in the stylesheet decides a step, and the page fits it on a resize and on a change of view',
    !/@container/.test(css34) && !/container-type/.test(css34)
    && /const step = fitLevel\(\(n\) => \{\s*bar\.dataset\.fit = String\(n\);/.test(appJs) && /return runsOver\(/.test(appJs)
    && /new ResizeObserver\(queueFit\)\.observe\(el\.toolbar\)/.test(appJs)
    && /c\.hidden = !c\.dataset\.view\.split\(' '\)\.includes\(view\);\s*queueFit\(\);/.test(appJs));
  check('a zoom frame rewrites the toolbar\'s words without changing them, and that is not a reason to measure again',
    /if \(now !== fitWords\) \{ fitWords = now; queueFit\(\); \}/.test(appJs),
    'the canvas reports on every frame of a zoom; four forced layouts a frame would be paid by the one thing that is already slow');
  check('the last step shortens "View options" to "View" on the button and keeps its name for a reader',
    /id="tb-options"[^>]*aria-label="View options"><span class="tb-name">View<span class="tb-more"> options<\/span><\/span>/.test(indexHtml)
    && /\.tb-menu > \.tb-name \{ color: inherit; \}/.test(css34)
    && /\.toolbar\[data-fit="3"\] \.tb-more \{ display: none; \}/.test(css34));

  check('the drawer\'s last error takes a line of its own before it is squeezed to a letter a line',
    /\.tl-drawer \{\s*flex: none; display: flex; flex-wrap: wrap;/.test(css34) && /\.tl-d-error \{ flex: 1 1 320px; min-width: 0; \}/.test(css34),
    'measured in a 720 px window: the error text was 26 px wide beside the agent, and under 240 px in every window from 640 to 1240');

  /* -- 3b. a press outlives a redraw --------------------------------------------- */

  // A redraw between a press and its release takes the pressed element out of the page, and the browser sends no
  // click. Measured in Chrome (click-probe.mjs): with the button held across a redraw, 0 of 20 presses chose an
  // agent in the Timeline and 0 of 20 in the List.
  const pr = await import(`../../kit/studio/web/press.js?t=${Date.now()}`);
  const fakeTimers = () => { const q = []; return { q, set: (fn, ms) => { q.push({ fn, ms }); return q.length; }, clear: (id) => { if (id) q[id - 1] = null; }, run: (ms) => { for (const [i, t] of q.entries()) if (t && t.ms === ms) { q[i] = null; t.fn(); } } }; };
  {
    const tm = fakeTimers(); let drawn = 0;
    const press = new pr.Press(() => { drawn += 1; }, tm);
    const free = press.defer();
    press.press();
    const held = [press.defer(), press.defer()];
    const during = drawn;
    press.release();
    const beforeTimer = drawn;
    tm.run(0);
    check('while a button is down a redraw waits, and it is drawn once when the press is over',
      free === false && held.join() === 'true,true' && during === 0 && beforeTimer === 0 && drawn === 1 && press.defer() === false,
      `free ${free} · held ${held} · drawn during ${during}, at the release ${beforeTimer}, after it ${drawn}`);
  }
  {
    const tm = fakeTimers(); let drawn = 0;
    const press = new pr.Press(() => { drawn += 1; }, tm);
    press.press(); press.release(); tm.run(0);
    const nothingOwed = drawn;
    // The click itself redraws (choosing an agent does): that draw settles what was put off.
    press.press(); press.defer(); press.release(); press.defer(); tm.run(0);
    check('a press that put nothing off draws nothing, and a redraw made by the click itself is not made again',
      nothingOwed === 0 && drawn === 0, `nothing owed ${nothingOwed} · after the click's own redraw ${drawn}`);
  }
  {
    const tm = fakeTimers(); let drawn = 0;
    const press = new pr.Press(() => { drawn += 1; }, tm);
    press.press(); press.defer(); press.release();
    press.press();                                  // a double click: the second press lands before the redraw
    tm.run(0);
    const underSecond = drawn;
    press.release(); tm.run(0);
    check('a second press that lands before the put-off redraw is not drawn under either',
      underSecond === 0 && drawn === 1, `drawn under the second press ${underSecond} · after it ${drawn}`);
  }
  {
    const tm = fakeTimers(); let drawn = 0;
    const press = new pr.Press(() => { drawn += 1; }, tm);
    press.press(); press.defer();
    tm.run(pr.HOLD_MS);
    const let_go = press.defer();
    tm.run(0);
    check('a button held and held is not a click: the view stops waiting for it',
      pr.HOLD_MS === 3000 && let_go === false && press.down === false, `after ${pr.HOLD_MS} ms: still waiting ${let_go}`);
  }
  {
    const seen = { root: [], win: [] };
    const fake = (list) => ({ addEventListener: (type, fn, capture) => list.push(`${type}${capture ? ':capture' : ''}`) });
    new pr.Press(() => {}).watch(fake(seen.root), fake(seen.win));
    const tlJs = web('timeline.js'); const lsJs = web('list.js');
    const wired = (src) => /this\.press = new Press\(\(\) => this\.render\(\)\);/.test(src) && /this\.press\.watch\(root, window\)/.test(src)
      && /render\(\) \{\s*if \(this\.root\.hidden\) return;\s*if \(this\.press\.defer\(\)\) return;/.test(src);
    check('the press is seen on the view and the release on the window, in the two views that redraw themselves',
      seen.root.join() === 'pointerdown:capture,keydown:capture' && seen.win.join() === 'pointerup:capture,pointercancel:capture,keyup:capture,blur'
      && wired(tlJs) && wired(lsJs), `view ${seen.root} · window ${seen.win} · Timeline ${wired(tlJs)} · List ${wired(lsJs)}`);
  }

  /* -- 4. the List on a page ---------------------------------------------------- */

  const dom34 = installDom();
  try {
    const { List } = await import(`../../kit/studio/web/list.js?t=${Date.now()}`);
    const { Dock } = await import(`../../kit/studio/web/dock.js?s=${Date.now()}`);
    const root = document.createElement('div');
    const sent = [];
    const picked = [];
    const view = new List(root, { onDecide: (item, verdict) => sent.push(`${item.key}:${verdict}`), onSelect: (n) => picked.push(n.id) });
    view.now = () => T + 8200;
    view.setSession('s-here');
    view.setNodes(nodes);
    view.setQueue(queue);
    const needs = root.children[0];
    const card = needs.children.find((c) => c.classList.contains('ls-card'));
    const buttons = card.children[card.children.length - 1].children;
    check('a request card carries the same three answers the dock does',
      buttons.map((b) => b.textContent).join(' | ') === 'Allow once | Allow Bash this session | Deny');
    {
      const before = root.children[0];
      view.press.press();
      view.setQueue(queue);                       // a redraw is asked for while a button is down
      const held = root.children[0] === before;
      view.press.release();
      await new Promise((r) => setTimeout(r, 5));
      check('the List under a press keeps its elements, and is drawn again when the press is over',
        held && root.children[0] !== before, `kept while down ${held} · drawn after ${root.children[0] !== before}`);
    }
    const clock = card.children[0].children[2];
    check('its countdown is the server\'s, and a timer to a screen reader',
      clock.textContent === '38s' && clock.getAttribute('role') === 'timer' && clock.getAttribute('aria-label') === 'Auto-deny in 38 seconds',
      clock.textContent);
    buttons[2].emit('click');
    const again = root.children[0].children.find((c) => c.classList.contains('ls-card'));
    again.children[again.children.length - 1].children[0].emit('click');
    check('a card answers once: its buttons are off until the request is gone',
      sent.join() === 'mine:deny' && again.children[again.children.length - 1].children.every((b) => b.disabled));
    view.release('mine');
    const back = root.children[0].children.find((c) => c.classList.contains('ls-card'));
    check('an answer that did not reach the server gives the buttons back', back.children[back.children.length - 1].children.every((b) => !b.disabled));
    const failedRow = root.children[1].children.find((c) => c.classList.contains('ls-row'));
    failedRow.emit('click');
    check('a row leads to its agent', picked.join() === 'k1');
    view.setQueue([req('nowait', 's-here', T, { waitSeconds: null })]);
    const unknown = root.children[0].children.find((c) => c.classList.contains('ls-card')).children[0].children[2];
    check('a card whose wait the server did not send shows no seconds', unknown.textContent === '?' && /not measured/.test(unknown.getAttribute('aria-label')));

    const dockRoot = document.createElement('div');
    const dock = new Dock(dockRoot, { now: () => T + 8200 });
    dock.render(queue.map((q) => ({ ...q })));
    const shownBefore = dockRoot.hidden;
    dock.setSuppressed(true);
    dock.tick();
    check('the dock stands down while another surface carries the answers, and its own clock does not bring it back',
      shownBefore === false && dockRoot.hidden === true);
    dock.setSuppressed(false);
    check('and comes back with the requests still in it', dockRoot.hidden === false && dock.items.length === 2);
  } finally {
    dom34();
  }

  /* -- 5. the states ------------------------------------------------------------ */

  const off = lv.offlineNote('offline', T, T + 30 * M + 1800, T + 30 * M);
  check('offline, the stage says which picture is on screen and when the next try is',
    /^Showing the last update from \d\d:\d\d\.$/.test(off.text) && off.retry === 'Reconnecting in 2s' && off.stale === true, `${off.text} ${off.retry}`);
  check('the countdown is to a request the page will really make, and ends in "now"',
    lv.offlineNote('offline', T, T, T + 5).retry === 'Reconnecting now' && lv.offlineNote('offline', T, null, T).retry === 'Reconnecting'
    && /setInterval\(\(\) => \{ nextPollAt = Date\.now\(\) \+ FLEET_POLL_MS; pollFleet\(\); \}, FLEET_POLL_MS\);/.test(appJs)
    && /function retryNow\(\) \{\s*nextPollAt = Date\.now\(\) \+ FLEET_POLL_MS;\s*pollFleet\(\); pollSessions\(\); pollOwned\(\);/.test(appJs));
  check('a server that never answered has no last picture, and the note does not claim one',
    lv.offlineNote('offline', null, null, T).stale === false && !/last update/.test(lv.offlineNote('offline', null, null, T).text));
  check('live and stale are not offline: the note is for a request that failed', lv.offlineNote('live', T, T, T) === null && lv.offlineNote('stale', T, T, T) === null);
  check('the last picture stays up while the server is away, and is drawn as old',
    /\.stage\[data-offline="true"\] \.canvas,\s*\.stage\[data-offline="true"\] \.tl,\s*\.stage\[data-offline="true"\] \.ls,\s*\.stage\[data-offline="true"\] \.attention \{ opacity: 0\.45; \}/.test(css34)
    && /el\.stage\.dataset\.offline = String\(Boolean\(off\)\);/.test(appJs));

  check('a first run is transcripts read and none found; an answer that could not be read is not one',
    nv.isFirstRun({ measured: true, projects: [] }) === true && nv.isFirstRun({ measured: false, projects: [] }) === false
    && nv.isFirstRun({ measured: true, projects: [{}] }) === false && nv.isFirstRun(null) === false);
  check('the first run says what Studio is waiting for, and offers no button that could start nothing',
    /No Claude Code sessions yet/.test(appJs) && /<div id="first-run" class="first-run" hidden><\/div>/.test(indexHtml)
    && !/el\.firstRun\.append\([^;]*button/s.test(appJs),
    'the design has "New session" there; with no project on the machine there is nowhere to start one');
  check('the navigator shows rows that are not there yet while the list is being read, and says it is busy',
    /id="sessions"[^>]*aria-busy="true"><div class="skel" aria-hidden="true">/.test(indexHtml)
    && /el\.sessions\.removeAttribute\('aria-busy'\);/.test(appJs));
  check('Stats that could not be read say so, say it is not a zero, and type no command of their own',
    /This is not a zero: there is nothing to read here\./.test(appJs) && /A full install of Crewforth in this project adds it\./.test(appJs)
    && !/npx crewforth init/.test(appJs));

  /* -- 6. the profiler tells a displayed view from one that is not ---------------- */

  const prof = read(path.join(HERE, 'paint-profile.mjs')) ?? '';
  check('the paint profiler refuses to quote a view that was not on screen for the whole run',
    /result\.onScreen = measured\?\.shown === true && result\.onScreenAfter\.shown === true;/.test(prof)
    && /result\.valid = result\.valid && result\.onScreen;/.test(prof) && /process\.exit\(result\.valid \? 0 : 1\)/.test(prof),
    'measured: with the view off screen it read 1.3 ms a redraw; on screen, 5.6 ms');
}

process.stdout.write(`${pass}/${pass + fail} assertions passed`
  + (skipped ? `, ${skipped} skipped` : '')
  + (na ? `, ${na} n/a on ${process.platform}` : '') + '\n');
process.exit(fail ? 1 : 0);
