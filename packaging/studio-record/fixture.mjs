// Build a fully synthetic Claude Code transcript tree for a Studio recording.
// Nothing here is copied from any real transcript: every path, id, agent and
// sentence is invented. Re-runnable: it wipes and rebuilds the tree — but only a
// tree this script wrote, which it marks, so a wrong argument cannot delete anything else.

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = process.argv[2];
if (!ROOT) throw new Error('usage: node fixture.mjs <projects-root> [version] [work-dir]');

// The version every demo project runs and the feed reports, so the header reads "Crewforth in 3" and no card
// shows a number other than the one being released.
const LATEST = process.argv[3] ?? '3.0.0';
// The cwds the fixture claims. They must exist on disk (the panel reads each project's .claude/VERSION from its
// cwd), and a path under /Users/<name> is shown as ~/…, so /Users/Shared/dev reads as ~/dev and names nobody.
const WORK = process.argv[4] ?? '/Users/Shared/dev';
const MARK = '.crewforth-studio-fixture';

const NOW = Date.now();
const MIN = 60_000;
const iso = (ms) => new Date(ms).toISOString();
const enc = (cwd) => cwd.replace(/[:\\/._]/g, '-');

const FAILED = 'cat: plugin/.claude-plugin/plugin.json: No such file or directory';
let uidN = 0;
const uid = () => {
  uidN += 1;
  const h = (n) => n.toString(16).padStart(4, '0');
  return `${h(uidN)}f2a1-${h(uidN * 7 % 65536)}-4${h(uidN * 13 % 4096).slice(1)}-9${h(uidN * 29 % 4096).slice(1)}-${h(uidN * 31 % 65536)}${h(uidN * 17 % 65536)}${h(uidN * 3 % 65536)}`;
};

function rm(p) { fs.rmSync(p, { recursive: true, force: true }); }
// Delete only what this script wrote: a directory carrying its mark, or a demo project from an earlier take
// (its README says so). Anything else at that path is someone's, and the run stops instead.
function rmOwned(p) {
  if (!fs.existsSync(p)) return;
  const ours = fs.existsSync(path.join(p, MARK))
    || /Synthetic demo project\./.test((() => { try { return fs.readFileSync(path.join(p, 'README.md'), 'utf8'); } catch { return ''; } })())
    || fs.readdirSync(p).length === 0;
  if (!ours) throw new Error(`refusing to replace ${p}: it was not written by this script`);
  rm(p);
}
function mk(p) { fs.mkdirSync(p, { recursive: true }); }
function writeJsonl(file, records, mtimeMs) {
  mk(path.dirname(file));
  fs.writeFileSync(file, records.map((r) => JSON.stringify(r)).join('\n') + '\n');
  if (mtimeMs != null) { const s = mtimeMs / 1000; fs.utimesSync(file, s, s); }
}

/* ------------------------------------------------------------------ agents */

const MODEL_MAIN = 'claude-opus-5-5';
const MODEL_SUB = 'claude-sonnet-5-5';

// An agent that consulted the advisor: its usage lists the call as an `advisor_message` iteration with the advisor's
// own model, kept out of the top-level fields, as the API writes it (measured on a real advisor session).
function withAdvisor(u, advisor) {
  if (!advisor) return u;
  return { ...u, iterations: [
    { type: 'message', input_tokens: u.input_tokens, output_tokens: Math.round(u.output_tokens / 4), cache_read_input_tokens: u.cache_read_input_tokens, cache_creation_input_tokens: u.cache_creation_input_tokens },
    { type: 'advisor_message', model: advisor.model, input_tokens: advisor.input, output_tokens: advisor.output, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
    { type: 'message', input_tokens: 2, output_tokens: u.output_tokens - Math.round(u.output_tokens / 4), cache_read_input_tokens: u.cache_read_input_tokens, cache_creation_input_tokens: 0 },
  ] };
}

// One agent transcript: prompt, alternating assistant/tool_result turns, report.
function agentRecords({ cwd, sessionId, branch, prompt, calls, startMs, endMs, errorsAt = [], tokens, narration, report, advisor = null }) {
  const recs = [];
  const step = calls.length ? Math.max(1, Math.floor((endMs - startMs) / (calls.length + 2))) : MIN;
  let t = startMs;
  const base = { isSidechain: true, userType: 'external', cwd, sessionId, version: '2.1.280', gitBranch: branch };

  recs.push({ ...base, parentUuid: null, type: 'user', uuid: uid(), timestamp: iso(t),
    message: { role: 'user', content: [{ type: 'text', text: prompt }] } });

  const perTurn = 2;
  let i = 0;
  let turnIdx = 0;
  const usage = (final) => final
    ? { input_tokens: tokens.input, cache_creation_input_tokens: tokens.creation, cache_read_input_tokens: tokens.read, output_tokens: tokens.output }
    : { input_tokens: Math.max(3, Math.round(tokens.input / 3)), cache_creation_input_tokens: Math.round(tokens.creation / 2), cache_read_input_tokens: Math.round(tokens.read * 0.6), output_tokens: Math.round(tokens.output / 2) };

  while (i < calls.length) {
    const batch = calls.slice(i, i + perTurn);
    t += step;
    const content = [];
    if (narration[turnIdx]) content.push({ type: 'text', text: narration[turnIdx] });
    for (const c of batch) content.push({ type: 'tool_use', id: c.id, name: c.name, input: c.input });
    recs.push({ ...base, parentUuid: uid(), type: 'assistant', uuid: uid(), timestamp: iso(t),
      message: { id: `msg_${uidN}`, role: 'assistant', model: MODEL_SUB, content, usage: usage(false) } });

    t += Math.round(step / 2);
    recs.push({ ...base, parentUuid: uid(), type: 'user', uuid: uid(), timestamp: iso(t),
      message: { role: 'user', content: batch.map((c, k) => ({
        type: 'tool_result',
        tool_use_id: c.id,
        // A call that failed says what failed: "ok" under "Last error" reads as a mistake in the picture.
        content: errorsAt.includes(i + k) ? (c.error ?? FAILED) : (c.result ?? 'ok'),
        ...(errorsAt.includes(i + k) ? { is_error: true } : {}),
      })) } });

    i += perTurn;
    turnIdx += 1;
  }

  recs.push({ ...base, parentUuid: uid(), type: 'assistant', uuid: uid(), timestamp: iso(endMs),
    message: { id: `msg_${uidN}`, role: 'assistant', model: MODEL_SUB, content: [{ type: 'text', text: report }], usage: withAdvisor(usage(true), advisor) } });
  return recs;
}

// Expand a tool plan like [['Read', 12, p => `src/x/${p}.ts`], ...] into calls.
let toolN = 0;
function calls(plan) {
  const out = [];
  for (const [name, count, mk2] of plan) {
    for (let k = 0; k < count; k += 1) {
      toolN += 1;
      out.push({ id: `toolu_0${toolN.toString(36)}c${(toolN * 977 % 100000).toString(36)}`, name, input: mk2(k + 1), result: 'ok' });
    }
  }
  return out;
}

/* ---------------------------------------------------------------- projects */

const PROJECTS = [
  { name: 'acme-payments-api', kit: LATEST, stack: 'node', installer: 'npx' },
  { name: 'acme-web-client', kit: LATEST, stack: 'web', installer: 'plugin' },
  { name: 'acme-notifier', kit: null },
  { name: 'acme-data-platform', kit: LATEST, stack: 'python', installer: 'npx' },
];

rmOwned(ROOT); mk(ROOT); fs.writeFileSync(path.join(ROOT, MARK), '');
for (const p of PROJECTS) {
  const dir = path.join(WORK, p.name);
  rmOwned(dir); mk(dir); fs.writeFileSync(path.join(dir, MARK), '');
  if (p.kit) {
    mk(path.join(dir, '.claude'));
    fs.writeFileSync(path.join(dir, '.claude', 'VERSION'), `${p.kit}\n`);
    fs.writeFileSync(path.join(dir, '.claude', 'kit.conf'),
      `stack=${p.stack}\ninstaller=${p.installer}\ninstalled_at=2026-07-14\n`);
  }
  fs.writeFileSync(path.join(dir, 'README.md'), `# ${p.name}\n\nSynthetic demo project.\n`);
}

const cwdOf = (n) => path.join(WORK, n);
const projDir = (n) => path.join(ROOT, enc(cwdOf(n)));

/* -------------------------------------------------------------- hero scene */

const HERO = '7f3c1d20-9a4e-4b6f-8c21-5d0e2a41b9c7';
const HERO_CWD = cwdOf('acme-payments-api');

// The task card a crew agent's work starts with (model routing): three lines at the top of its task. The panel
// shows it in the inspector; an agent that is not a crew agent has none.
const CARDS = {
  '3e7b10d5': { files: 'src/capture/handler.ts, src/capture/idempotency.ts', change: 'feature', verify: 'npm test -- capture' },
  b48d29e1: { files: 'test/capture/**', change: 'test-run', verify: 'npm test -- capture' },
  f20a7c63: { files: 'web/checkout/RefundBanner.tsx', change: 'feature', verify: 'npm test -- checkout' },
  '5d93be08': { files: 'db/migrations/0042_ledger_index.sql', change: 'migration', verify: 'npm run migrate:dry' },
  c7e58f14: { files: 'jobs/settlement/**', change: 'audit', verify: 'none' },
  e6390d7b: { files: 'src/config/credentials.ts, src/http/log.ts', change: 'security', verify: 'none' },
};
const cardText = (id) => (CARDS[id] ? `files: ${CARDS[id].files}\nchange: ${CARDS[id].change}\nverify: ${CARDS[id].verify}\n\n` : '');

// The record of outcomes Crewforth's hooks keep for the project (.claude/state): which model did which kind of
// task and how it went. Written here in the hooks' own format and words, for the Models view. Two of the lines are
// agents of the session on screen; the rest stand for earlier sessions of the project.
function writeOutcomes(dir) {
  const stamp = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const t0 = NOW - 6 * 60 * MIN;
  let n = 0;
  const rows = ['ts\tagent_id\tagent\tchange\trisk\tcard\tmodel\tverify\tfixes\tescalated_from\tran_on\tconfidence\trisk_why'];
  // Critical work carries the gate's reason (risk_why), in the words guard-agent-model.sh writes; normal work "-".
  const why = (change, risk) => (risk === 'critical' ? `change: ${change}` : '-');
  const add = (agent, change, risk, model, verify, fixes = 0, from = '-', id = null, card = null) => {
    n += 1;
    rows.push([stamp(t0 + n * 4 * MIN), id ?? `e${String(n).padStart(4, '0')}a1`, agent, change, risk, card ?? `c${n}`, model, verify, fixes, from, '-', 'high', why(change, risk)].join('\t'));
    return stamp(t0 + n * 4 * MIN);
  };
  // Backend features on haiku: two of five did not pass first time, so the class was raised to sonnet...
  for (const v of ['pass', 'fail', 'pass', 'fail', 'pass']) add('crew-backend-expert', 'feature', 'normal', 'haiku', v, v === 'fail' ? 1 : 0, '-', null, v === 'fail' && n === 3 ? 'idem' : null);
  const raisedBackend = stamp(t0 + n * 4 * MIN + 1000);
  // ...and has passed ten times on sonnet since: the lowering is offered.
  for (let k = 0; k < 9; k += 1) add('crew-backend-expert', 'feature', 'normal', 'sonnet', 'pass');
  // Reviews were raised the same way, and the user lowered them again.
  for (const v of ['pass', 'fail', 'fail', 'pass', 'pass', 'pass']) add('crew-review-agent', 'audit', 'normal', 'haiku', v, v === 'fail' ? 1 : 0);
  const raisedReview = stamp(t0 + n * 4 * MIN + 1000);
  for (let k = 0; k < 3; k += 1) add('crew-review-agent', 'audit', 'normal', 'sonnet', 'pass');
  const loweredReview = stamp(t0 + n * 4 * MIN + 2000);
  for (let k = 0; k < 2; k += 1) add('crew-review-agent', 'audit', 'normal', 'haiku', 'pass');
  for (let k = 0; k < 18; k += 1) add('crew-test-expert', 'test-run', 'normal', 'haiku', 'pass');
  for (const v of ['pass', 'pass', 'pass', 'blocked']) add('crew-database-expert', 'migration', 'critical', 'opus', v);
  for (const v of ['pass', 'pass', 'none']) add('crew-security-expert', 'security', 'critical', 'opus', v);
  for (const [v, f] of [['pass', 0], ['pass', 1], ['pass', 0], ['fail', 1], ['pass', 0], ['pass', 0], ['timeout', 0]]) add('crew-frontend-expert', 'feature', 'normal', 'sonnet', v, f);
  // The session on screen: the capture feature (its card failed once on haiku, above, and ran again on sonnet),
  // and the test run under it.
  add('crew-backend-expert', 'feature', 'normal', 'sonnet', 'pass', 0, 'haiku', '3e7b10d5', 'idem');
  add('crew-test-expert', 'test-run', 'normal', 'haiku', 'pass', 0, '-', 'b48d29e1');
  // The release audit's security scan: critical by its kind of change, which the inspector says.
  add('crew-security-expert', 'security', 'critical', 'opus', 'none', 0, '-', 'e6390d7b', 'sec-scan');
  // Normal work a caller chose to run above Sonnet: shown under the table, nothing blocked.
  for (const v of ['pass', 'pass', 'pass']) add('crew-docs-agent', 'text', 'normal', 'opus', v);
  const state = path.join(dir, '.claude', 'state');
  mk(state);
  fs.writeFileSync(path.join(state, 'model-outcomes.tsv'), `${rows.join('\n')}\n`);
  fs.writeFileSync(path.join(state, 'crew-model-floors.auto'),
    `crew-backend-expert\tfeature\tnormal\tsonnet\t5\t2\t${raisedBackend}\ncrew-review-agent\taudit\tnormal\tsonnet\t6\t2\t${raisedReview}\n`);
  fs.writeFileSync(path.join(state, 'crew-model-loosened.tsv'),
    `ts\tagent\tchange\trisk\tfrom\tto\n${loweredReview}\tcrew-review-agent\taudit\tnormal\tsonnet\thaiku\n`);
}
writeOutcomes(HERO_CWD);
const HERO_DIR = projDir('acme-payments-api');
const BRANCH = 'feat/payment-retries';
const T0 = NOW - 52 * MIN;

const AG = [
  // top level ------------------------------------------------------------
  { id: '9c1f4a72', type: 'Explore', tu: 'toolu_agent_9c1f4a72',
    desc: 'Map every retry path through the capture and refund handlers',
    want: 'done', notice: 'completed', mtime: NOW - 44 * MIN,
    start: T0 + 2 * MIN, end: T0 + 5 * MIN + 41_000,
    tokens: { input: 1843, creation: 6120, read: 40250, output: 3714 }, errorsAt: [],
    plan: [['Grep', 9, (k) => ({ pattern: `retry|backoff|attempt_${k}` })],
      ['Read', 11, (k) => ({ file_path: `${HERO_CWD}/src/capture/handler-${k}.ts` })],
      ['Bash', 3, (k) => ({ command: `rg -n "maxAttempts" src | head -${20 + k}`, description: 'List retry ceilings' })]],
    narration: ['Starting from the capture entry point and following the call graph outward.',
      'Two of the handlers retry without a ceiling; reading those closely.',
      'Cross-checking the refund path for the same shape.'],
    report: 'Four retry paths, three of them independent. `capture/handler-3.ts` retries on any 5xx with no ceiling and no jitter, which is what produced the duplicate settlement rows. The refund path already caps at five attempts but shares no code with capture, so a fix in one will not reach the other. Recommend extracting a single retry policy module and having both call it.' },

  { id: '3e7b10d5', type: 'crew-backend-expert', tu: 'toolu_agent_3e7b10d5',
    // It consulted the advisor once: its class in the Models view carries the advisor tag.
    advisor: { model: 'claude-opus-5-5', input: 30210, output: 380 },
    desc: 'Add idempotency keys to the capture endpoint',
    want: 'done-via-link', notice: null, mtime: NOW - 31 * MIN,
    start: T0 + 6 * MIN, end: T0 + 14 * MIN + 12_000,
    tokens: { input: 2410, creation: 9330, read: 59666, output: 6188 }, errorsAt: [7],
    plan: [['Read', 8, (k) => ({ file_path: `${HERO_CWD}/src/capture/route-${k}.ts` })],
      ['Edit', 9, (k) => ({ file_path: `${HERO_CWD}/src/capture/route-${k}.ts` })],
      ['Bash', 6, (k) => ({ command: `npm run build -- --filter capture-${k}`, description: 'Type-check the capture package' })]],
    narration: ['Reading the route layer before touching it.',
      'Adding the key column to the request contract first, then the handler.',
      'One build failed on a missing type export; adding it.',
      'Green now. Handing the suite to a runner.'],
    spawn: { id: 'toolu_agent_child_b48d', name: 'Agent', input: { subagent_type: 'crew-test-expert', description: 'Run the payments integration suite and triage failures' } },
    report: 'Capture now takes an `Idempotency-Key` header, stores it with the intent row under a unique index, and replays the stored response on a repeat. Two call sites needed updating. The store write and the ledger write are still separate transactions, which leaves a small window; that is written up as a follow-up rather than fixed here.' },

  { id: 'b48d29e1', type: 'crew-test-expert', tu: 'toolu_agent_child_b48d', nested: true,
    desc: 'Run the payments integration suite and triage failures',
    want: 'done', notice: 'completed', mtime: NOW - 28 * MIN,
    start: T0 + 15 * MIN, end: T0 + 19 * MIN + 3_000,
    tokens: { input: 1204, creation: 4470, read: 21311, output: 2903 }, errorsAt: [2, 5],
    plan: [['Bash', 7, (k) => ({ command: `npm test -- --shard ${k}/7`, description: `Run integration shard ${k}` })],
      ['Read', 6, (k) => ({ file_path: `${HERO_CWD}/test/capture/idempotency-${k}.spec.ts` })]],
    narration: ['Running the suite sharded so a hang is easy to localise.',
      'Two shards red; reading the specs they point at.',
      'Both failures were fixture-order, not the change.'],
    report: '61 of 63 specs green on the first pass. The two failures were a shared fixture the shards mutate in place, reproducible on the unchanged branch as well. Filed separately; the idempotency change itself is covered by nine new specs, all passing.' },

  { id: 'f20a7c63', type: 'crew-frontend-expert', tu: 'toolu_agent_f20a7c63',
    desc: 'Wire the refund status banner into the checkout view',
    want: 'running', notice: null, mtime: NOW,
    start: NOW - 6 * MIN, end: NOW - 12_000,
    tokens: { input: 1512, creation: 5240, read: 26260, output: 2411 }, errorsAt: [],
    plan: [['Read', 9, (k) => ({ file_path: `${HERO_CWD}/web/checkout/panel-${k}.tsx` })],
      ['Edit', 7, (k) => ({ file_path: `${HERO_CWD}/web/checkout/panel-${k}.tsx` })],
      ['Bash', 5, (k) => ({ command: `npm run lint -- web/checkout/panel-${k}.tsx`, description: 'Lint the touched view' })]],
    narration: ['Reading the checkout tree to find where status already renders.',
      'Adding the banner as a sibling of the existing notice, not a new region.',
      'Linting as I go.'],
    report: 'Banner renders on pending and failed refunds; still wiring the retry affordance.' },

  { id: '5d93be08', type: 'crew-database-expert', tu: 'toolu_agent_5d93be08',
    desc: 'Draft the ledger index migration and dry-run it',
    want: 'running', notice: null, mtime: NOW,
    start: NOW - 9 * MIN, end: NOW - 40_000,
    tokens: { input: 1188, creation: 4802, read: 22754, output: 1907 }, errorsAt: [],
    plan: [['Read', 5, (k) => ({ file_path: `${HERO_CWD}/db/migrations/0${k}_ledger.sql` })],
      ['Bash', 7, (k) => ({ command: `psql -d ledger_shadow -f db/migrations/dry-${k}.sql`, description: 'Dry-run against the shadow database' })]],
    narration: ['Reading the existing migrations so the new one follows the same shape.',
      'Dry-running against the shadow copy before writing anything final.'],
    report: 'Index builds in 41s on the shadow copy at production row counts. Writing the concurrent form now.' },

  { id: 'c7e58f14', type: 'crew-performance-expert', tu: 'toolu_agent_c7e58f14',
    desc: 'Profile the settlement batch job under load',
    want: 'running', notice: null, mtime: NOW,
    start: NOW - 11 * MIN, end: NOW - 20_000,
    tokens: { input: 2077, creation: 7150, read: 30291, output: 3355 }, errorsAt: [1],
    plan: [['Bash', 11, (k) => ({ command: `node --prof scripts/settle.js --batch ${k * 500}`, description: `Profile batch of ${k * 500}` })],
      ['Read', 6, (k) => ({ file_path: `${HERO_CWD}/scripts/settle-${k}.js` })]],
    narration: ['Profiling at four batch sizes so the curve is visible, not a single point.',
      'One run aborted on a stale lock file; rerunning that size.',
      'Reading the hot frames.'],
    report: 'Throughput is flat to 1500 rows and falls off after; 63% of samples are in the per-row currency lookup. Confirming it is the lookup and not the surrounding transaction.' },

  { id: '1a6c3d95', type: 'general-purpose', tu: 'toolu_agent_1a6c3d95',
    desc: 'Update the webhook retry runbook',
    want: 'ended', notice: null, mtime: NOW - 41 * MIN,
    start: T0 + 8 * MIN, end: T0 + 10 * MIN + 47_000,
    tokens: { input: 903, creation: 2860, read: 11467, output: 1544 }, errorsAt: [],
    plan: [['Read', 4, (k) => ({ file_path: `${HERO_CWD}/docs/runbook-${k}.md` })],
      ['Edit', 4, (k) => ({ file_path: `${HERO_CWD}/docs/runbook-${k}.md` })]],
    narration: ['Reading the runbook before editing it.', 'Rewriting the escalation table.'],
    report: 'Runbook now states the real ceilings and names the dashboard panel to check first.' },

  { id: '7b2e94af', type: 'Explore', tu: 'toolu_agent_7b2e94af',
    desc: 'Cluster the 502s from the gateway access log',
    want: 'starting', notice: null, mtime: null },

  // workflow run ----------------------------------------------------------
  { id: '4f81ca20', type: 'general-purpose', wf: true, tu: 'toolu_wf_4f81ca20',
    desc: 'Check direct dependencies for open advisories',
    want: 'done', notice: 'completed', mtime: NOW - 24 * MIN,
    start: T0 + 22 * MIN, end: T0 + 25 * MIN + 18_000,
    tokens: { input: 1092, creation: 3980, read: 17836, output: 1622 }, errorsAt: [],
    plan: [['Bash', 6, (k) => ({ command: `npm audit --omit=dev --json | head -${40 + k}`, description: 'Read the advisory feed' })],
      ['Read', 4, (k) => ({ file_path: `${HERO_CWD}/package-lock-${k}.json` })]],
    narration: ['Reading direct dependencies only; transitive ones are the platform team\'s gate.',
      'Two advisories, one of them not reachable from our call paths.'],
    report: 'Two advisories on direct dependencies. One is reachable and has a patch release; the other is in a code path this service never enters, recorded rather than upgraded.' },

  { id: 'e6390d7b', type: 'crew-security-expert', wf: true, tu: 'toolu_wf_e6390d7b',
    desc: 'Scan the diff for secret handling regressions',
    want: 'done', notice: 'completed', mtime: NOW - 23 * MIN,
    start: T0 + 22 * MIN, end: T0 + 26 * MIN + 5_000,
    tokens: { input: 1338, creation: 4410, read: 20903, output: 2088 }, errorsAt: [],
    plan: [['Grep', 8, (k) => ({ pattern: `token|secret|key_${k}` })],
      ['Read', 5, (k) => ({ file_path: `${HERO_CWD}/src/config/credentials-${k}.ts` })],
      ['Bash', 2, (k) => ({ command: `git diff --stat HEAD~${k}`, description: 'Scope the diff' })]],
    narration: ['Scanning the diff rather than the whole tree.',
      'One log line prints a request header map; reading its call site.'],
    report: 'No credential reaches a log sink. One debug line printed the whole header map, which would have included the idempotency key and, on an internal route, the service token; narrowed to an allowlist of three headers.' },

  { id: '2c74a9f6', type: 'crew-review-agent', wf: true, tu: 'toolu_wf_2c74a9f6',
    desc: 'Diff the public API surface against the last release',
    want: 'done', notice: 'completed', mtime: NOW - 23 * MIN,
    start: T0 + 22 * MIN, end: T0 + 24 * MIN + 51_000,
    tokens: { input: 967, creation: 3140, read: 15220, output: 1401 }, errorsAt: [],
    plan: [['Bash', 5, (k) => ({ command: `npx openapi-diff spec/v${k}.yaml spec/head.yaml`, description: 'Diff the OpenAPI surface' })],
      ['Read', 3, (k) => ({ file_path: `${HERO_CWD}/spec/paths-${k}.yaml` })]],
    narration: ['Diffing the committed spec, not a generated one.',
      'One addition, no removals.'],
    report: 'One additive change: the `Idempotency-Key` header is now accepted and documented as optional. No field was removed or narrowed, so this stays a minor.' },

  { id: 'af5b1e38', type: 'claude-code-guide', wf: true, tu: 'toolu_wf_af5b1e38',
    desc: 'Verify the changelog and version carriers agree',
    want: 'failed', notice: 'failed', mtime: NOW - 22 * MIN,
    start: T0 + 22 * MIN, end: T0 + 27 * MIN + 9_000,
    tokens: { input: 1450, creation: 5010, read: 23744, output: 1876 }, errorsAt: [1, 4, 6],
    plan: [['Read', 4, (k) => ({ file_path: `${HERO_CWD}/CHANGELOG-${k}.md` })],
      ['Bash', 5, (k) => ({ command: `grep -n version package-${k}.json`, description: 'Read a version carrier' })]],
    narration: ['Reading every carrier that has to move together.',
      'Two carriers disagree, and one of the reads failed outright.',
      'Stopping rather than guessing which one is authoritative.'],
    report: 'Stopped: the manifest says 4.2.0, the changelog heading says 4.1.3, and the plugin manifest could not be read at all. Three of my reads errored on a path that does not exist in this checkout, so I cannot say which carrier is correct. This needs a human decision before the tag.' },
];

// Agent transcripts + metas
for (const a of AG) {
  const wfDir = a.wf ? path.join(HERO_DIR, HERO, 'subagents', 'workflows', 'wf-release-audit-2f9c')
    : path.join(HERO_DIR, HERO, 'subagents');
  mk(wfDir);
  fs.writeFileSync(path.join(wfDir, `agent-${a.id}.meta.json`), JSON.stringify({
    agentType: a.type,
    description: a.desc,
    toolUseId: a.tu,
    spawnDepth: a.nested ? 2 : 1,
    startedAt: iso(a.start ?? NOW),
  }, null, 2) + '\n');

  if (a.mtime === null) continue;                       // "starting": meta, no transcript yet

  const cs = calls(a.plan);
  if (a.spawn) cs.push({ ...a.spawn, result: 'agent finished' });
  writeJsonl(path.join(wfDir, `agent-${a.id}.jsonl`), agentRecords({
    cwd: HERO_CWD, sessionId: HERO, branch: BRANCH,
    prompt: `${cardText(a.id)}${a.desc}. Report what you changed and what you deliberately left alone.`,
    calls: cs, startMs: a.start, endMs: a.end, errorsAt: a.errorsAt,
    tokens: a.tokens, narration: a.narration, report: a.report, advisor: a.advisor ?? null,
  }), a.mtime);
}

/* --------------------------------------------------- hero main transcript */

const M = [];
let mt = T0;
const base = { parentUuid: null, isSidechain: false, userType: 'external', cwd: HERO_CWD, sessionId: HERO, version: '2.1.280', gitBranch: BRANCH };
const push = (r, dt = 40_000) => { mt += dt; M.push({ ...base, uuid: uid(), timestamp: iso(mt), ...r }); };

const user = (text, dt) => push({ type: 'user', message: { role: 'user', content: [{ type: 'text', text }] } }, dt);
const mUsage = (read) => ({ input_tokens: 1200 + (read % 900), cache_creation_input_tokens: 4200, cache_read_input_tokens: read, output_tokens: 900 });
const asst = (content, read, dt) => push({ type: 'assistant', message: { id: `msg_m${M.length}`, role: 'assistant', model: MODEL_MAIN, content, usage: mUsage(read) } }, dt);
const result = (toolUseId, agentId, status) => push({
  type: 'user',
  message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: toolUseId, content: 'Agent finished.' }] },
  toolUseResult: { agentId, status, resolvedModel: MODEL_SUB, totalDurationMs: 214_337, totalTokens: 48_213 },
}, 15_000);
const notify = (ids, status) => push({
  type: 'user',
  message: { role: 'user', content: [{ type: 'text', text: `<task-notification>${ids.map((i) => `<task-id>${i}</task-id>`).join('')}<status>${status}</status></task-notification>` }] },
}, 8_000);

user('We are seeing duplicate settlement rows on the payments service after a gateway timeout. Start by working out how many independent retry paths we actually have — do not change anything yet.');

asst([
  { type: 'text', text: 'Before touching the handlers I want the retry paths mapped, because a fix applied to one of three copies is worse than no fix — it hides the symptom on the path we tested. Sending an explorer over the capture and refund code.' },
  { type: 'tool_use', id: 'toolu_agent_9c1f4a72', name: 'Agent', input: { subagent_type: 'Explore', description: 'Map every retry path through the capture and refund handlers', prompt: 'Trace retries from the capture entry point.' } },
], 22_800);
result('toolu_agent_9c1f4a72', '9c1f4a72', 'completed');
notify(['9c1f4a72'], 'completed');

asst([
  { type: 'text', text: 'Four retry paths, three of them independent, and one of them retries any 5xx forever. That matches the duplicate rows exactly: the gateway times out, we retry, and the second capture succeeds against a ledger that already recorded the first.' },
  { type: 'tool_use', id: 'toolu_read_ledger', name: 'Read', input: { file_path: `${HERO_CWD}/src/ledger/write.ts` } },
  { type: 'tool_use', id: 'toolu_grep_unique', name: 'Grep', input: { pattern: 'unique index|ON CONFLICT' } },
], 31_450);
push({ type: 'user', message: { role: 'user', content: [
  { type: 'tool_result', tool_use_id: 'toolu_read_ledger', content: 'read 214 lines' },
  { type: 'tool_result', tool_use_id: 'toolu_grep_unique', content: '3 matches' },
] } }, 12_000);

user('Right. Add idempotency keys then — request header, stored with the intent, replay the stored response on a repeat. And run the suite afterwards.');

asst([
  { type: 'text', text: 'Taking that in two parts. A backend agent owns the endpoint change and the storage shape; it will hand the suite to a test runner of its own when the build is green, so a red suite is triaged by something that still has the change in context rather than by me reading a log after the fact.\n\nOne thing I am not doing without you: the store write and the ledger write are separate transactions today. Idempotency keys close the duplicate-capture window but not that one. Collapsing them is a bigger change than you asked for, so I will write it up as a follow-up unless you say otherwise.' },
  { type: 'tool_use', id: 'toolu_agent_3e7b10d5', name: 'Agent', input: { subagent_type: 'crew-backend-expert', description: 'Add idempotency keys to the capture endpoint', prompt: 'Add the header, the unique index and the replay path.' } },
], 44_120);
result('toolu_agent_3e7b10d5', '3e7b10d5', 'completed');
notify(['b48d29e1'], 'completed');

user('Follow-up is fine, do not collapse the transactions today. While that runs, get the refund banner into checkout and have someone look at the settlement job — it has been slow since Tuesday.');

asst([
  { type: 'text', text: 'Three in parallel, then: the checkout banner, a migration draft for the ledger index the explorer asked for, and a profile of the settlement batch. The profiler will run at several batch sizes rather than one, because "slow since Tuesday" is usually a curve that bends, not a constant.' },
  { type: 'tool_use', id: 'toolu_agent_f20a7c63', name: 'Agent', input: { subagent_type: 'crew-frontend-expert', description: 'Wire the refund status banner into the checkout view', prompt: 'Add the banner beside the existing notice.' } },
  { type: 'tool_use', id: 'toolu_agent_5d93be08', name: 'Agent', input: { subagent_type: 'crew-database-expert', description: 'Draft the ledger index migration and dry-run it', prompt: 'Dry-run against the shadow database first.' } },
  { type: 'tool_use', id: 'toolu_agent_c7e58f14', name: 'Agent', input: { subagent_type: 'crew-performance-expert', description: 'Profile the settlement batch job under load', prompt: 'Profile at four batch sizes.' } },
], 52_900);

user('Also the runbook is out of date — it still claims we cap at three attempts.');

asst([
  { type: 'text', text: 'Sending a docs agent at the runbook with the numbers the explorer measured, so the table states the real ceilings rather than the intended ones.' },
  { type: 'tool_use', id: 'toolu_agent_1a6c3d95', name: 'Agent', input: { subagent_type: 'general-purpose', description: 'Update the webhook retry runbook', prompt: 'Correct the escalation table.' } },
], 58_300);

user('One more thing before we cut the release: run the pre-release audit workflow over this branch.');

asst([
  { type: 'text', text: 'Running it. Four checks go out together — dependency advisories, a secret-handling scan of the diff, an API surface diff against the last release, and the version-carrier check.' },
  { type: 'tool_use', id: 'toolu_wf_start', name: 'Bash', input: { command: 'claude workflow run release-audit --branch feat/payment-retries', description: 'Start the pre-release audit workflow' } },
], 66_400);
push({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_wf_start', content: 'workflow wf-release-audit-2f9c started with 4 agents' }] } }, 10_000);
notify(['4f81ca20', 'e6390d7b', '2c74a9f6'], 'completed');
notify(['af5b1e38'], 'failed');

asst([
  { type: 'text', text: 'Audit is back, and it is not clean.\n\nThe dependency, secret-handling and API-surface checks all passed, with one real catch: a debug line was printing the whole request header map, which on an internal route would have put the service token in the log. That is narrowed to an allowlist of three headers.\n\nThe release verifier stopped rather than reporting. Three of its reads errored on a path that does not exist in this checkout, and of the carriers it could read, the manifest says 4.2.0 while the changelog heading says 4.1.3. It refused to guess which is authoritative, which is the right call — a verifier that picks one and moves on is a verifier that will one day tag the wrong commit and tell you it was fine. That needs your decision before anything is tagged.' },
], 78_650);

user('Good catch on the header map. Leave the version disagreement to me. Where are the other three?');

asst([
  { type: 'text', text: 'Still running. The banner is rendering on pending and failed refunds and is on the retry affordance now; the migration dry-ran in 41 seconds against the shadow copy at production row counts and is being rewritten in the concurrent form; the profiler has the curve — flat to about 1500 rows, then falling off, with 63% of samples in the per-row currency lookup.\n\nOne agent has not started yet: the log triager for the gateway 502s. It is queued behind the profiler so the two are not competing for the same box.' },
  { type: 'tool_use', id: 'toolu_agent_7b2e94af', name: 'Agent', input: { subagent_type: 'Explore', description: 'Cluster the 502s from the gateway access log', prompt: 'Cluster by upstream and status.' } },
], 96_428);

push({ type: 'ai-title', aiTitle: 'Duplicate settlements: retry paths and idempotency' }, 5_000);

// Spread the hero turns across the whole session window so the last record sits
// a few seconds ago: "ended" is decided against the session's own last
// timestamp, not against the wall clock.
{
  const first = Date.parse(M[0].timestamp);
  const last = Date.parse(M[M.length - 1].timestamp);
  const target = NOW - 25_000;
  const scale = (target - T0) / (last - first);
  for (const r of M) r.timestamp = iso(Math.round(T0 + (Date.parse(r.timestamp) - first) * scale));
}

writeJsonl(path.join(HERO_DIR, `${HERO}.jsonl`), M, NOW);

/* ------------------------------------------------- smaller second session */

function smallSession({ project, sid, title, titleType, branch, startAgo, msgs, agents }) {
  const cwd = cwdOf(project);
  const dir = projDir(project);
  const recs = [];
  let t = NOW - startAgo;
  const b = { parentUuid: null, isSidechain: false, userType: 'external', cwd, sessionId: sid, version: '2.1.280', gitBranch: branch };
  const p = (r, dt = 45_000) => { t += dt; recs.push({ ...b, uuid: uid(), timestamp: iso(t), ...r }); };

  for (const m of msgs) {
    if (m.role === 'user') p({ type: 'user', message: { role: 'user', content: [{ type: 'text', text: m.text }] } });
    else p({ type: 'assistant', message: { id: `msg_s${recs.length}`, role: 'assistant', model: MODEL_MAIN, content: m.content, usage: { input_tokens: 1140, cache_creation_input_tokens: 3300, cache_read_input_tokens: m.read ?? 18_400, output_tokens: 640 } } });
  }

  for (const a of agents) {
    const sub = path.join(dir, sid, 'subagents');
    mk(sub);
    fs.writeFileSync(path.join(sub, `agent-${a.id}.meta.json`), JSON.stringify({
      agentType: a.type, description: a.desc, toolUseId: `toolu_agent_${a.id}`, spawnDepth: 1,
    }, null, 2) + '\n');
    const cs = calls(a.plan);
    writeJsonl(path.join(sub, `agent-${a.id}.jsonl`), agentRecords({
      cwd, sessionId: sid, branch, prompt: `${a.desc}.`, calls: cs,
      startMs: t - 9 * MIN, endMs: t - 3 * MIN, errorsAt: [],
      tokens: a.tokens, narration: a.narration, report: a.report,
    }), t - 3 * MIN);
    recs.push({ ...b, uuid: uid(), timestamp: iso(t), type: 'user',
      message: { role: 'user', content: [{ type: 'text', text: `<task-notification><task-id>${a.id}</task-id><status>completed</status></task-notification>` }] } });
  }

  if (title) p({ type: titleType === 'custom' ? 'custom-title' : 'ai-title', ...(titleType === 'custom' ? { customTitle: title } : { aiTitle: title }) }, 3_000);
  writeJsonl(path.join(dir, `${sid}.jsonl`), recs, t);
  return sid;
}

const SECOND = '2b8e64f1-70c3-4a19-9e55-1c8d3f0b7a24';
smallSession({
  project: 'acme-payments-api', sid: SECOND, title: 'Webhook signature rotation', titleType: 'custom',
  branch: 'chore/webhook-keys', startAgo: 5 * 60 * MIN,
  msgs: [
    { role: 'user', text: 'We need to rotate the webhook signing key without breaking merchants who are still verifying with the old one.' },
    { role: 'assistant', read: 14_220, content: [
      { type: 'text', text: 'The usual shape is a dual-accept window: sign with the new key, accept either signature for a fixed period, then drop the old one. What I want to establish first is how long merchants actually have to move, because the window length is a product decision and everything else follows from it.' },
      { type: 'tool_use', id: 'toolu_s1', name: 'Read', input: { file_path: `${cwdOf('acme-payments-api')}/src/webhooks/sign.ts` } },
    ] },
    { role: 'user', text: 'Thirty days. Support already told the top twenty merchants.' },
    { role: 'assistant', read: 21_905, content: [
      { type: 'text', text: 'Thirty days it is. I will add the second verifier behind a dated flag so the drop happens by configuration rather than by someone remembering to open a PR, and have a reviewer check the key never reaches a log line.' },
      { type: 'tool_use', id: 'toolu_s2', name: 'Edit', input: { file_path: `${cwdOf('acme-payments-api')}/src/webhooks/verify.ts` } },
    ] },
    { role: 'user', text: 'Do that, and make sure the old key is gone from the repo entirely.' },
    { role: 'assistant', read: 27_460, content: [
      { type: 'text', text: 'Dual verification is in and dated to expire in thirty days. The old key was never committed — it comes from the environment — but the sample env file carried a real-looking value that had been copied into two READMEs; those are now obvious placeholders.' },
    ] },
  ],
  agents: [
    { id: 'd6f01b93', type: 'crew-security-expert', desc: 'Check the rotation for key material in logs',
      tokens: { input: 880, creation: 2600, read: 12_940, output: 1180 },
      plan: [['Grep', 6, (k) => ({ pattern: `signing_key_${k}` })], ['Read', 4, (k) => ({ file_path: `${cwdOf('acme-payments-api')}/src/webhooks/verify-${k}.ts` })]],
      narration: ['Scanning for the key name across the tree.', 'Reading the two files that mention it.'],
      report: 'No key material reaches a log sink. Two READMEs carried a real-looking sample value; replaced with obvious placeholders.' },
    { id: 'a95c2708', type: 'crew-test-expert', desc: 'Prove old and new signatures both verify during the window',
      tokens: { input: 760, creation: 2100, read: 10_330, output: 940 },
      plan: [['Bash', 5, (k) => ({ command: `npm test -- webhooks --grep rotation-${k}`, description: 'Run the rotation specs' })]],
      narration: ['Running the rotation specs on both key generations.'],
      report: 'Both signatures verify inside the window and the old one is rejected one second after it. Twelve specs, all green.' },
    { id: 'ff3418c2', type: 'general-purpose', desc: 'Write the merchant-facing rotation note',
      tokens: { input: 640, creation: 1800, read: 8_115, output: 820 },
      plan: [['Edit', 3, (k) => ({ file_path: `${cwdOf('acme-payments-api')}/docs/webhooks-${k}.md` })]],
      narration: ['Writing the note in merchant language, not ours.'],
      report: 'One page: what changes, the exact cut-off date, and the two lines a merchant has to change.' },
  ],
});

smallSession({
  project: 'acme-web-client', sid: '5c9d7e02-4b31-48af-a7c6-0d21e9f4a831', title: 'Checkout bundle size', titleType: 'ai',
  branch: 'perf/bundle', startAgo: 26 * 60 * MIN,
  msgs: [
    { role: 'user', text: 'The checkout bundle went over budget again. Find out what landed in it.' },
    { role: 'assistant', read: 19_880, content: [
      { type: 'text', text: 'Comparing the current build against the last one under budget, by module rather than by total — a total tells you that it grew, not what to remove.' },
      { type: 'tool_use', id: 'toolu_w1', name: 'Bash', input: { command: 'npm run build -- --analyze', description: 'Build with the analyzer on' } },
    ] },
    { role: 'user', text: 'And say what we can drop without touching the design.' },
    { role: 'assistant', read: 24_610, content: [
      { type: 'text', text: 'Two thirds of the growth is one date library pulled in by a single helper that formats a receipt timestamp. Replacing that helper with the platform formatter takes the bundle back under budget on its own; nothing visual changes.' },
    ] },
  ],
  agents: [
    { id: '0e73b4d1', type: 'Explore', desc: 'Find what pulls the date library into checkout',
      tokens: { input: 1010, creation: 3400, read: 16_720, output: 1320 },
      plan: [['Grep', 7, (k) => ({ pattern: `import .*date-lib-${k}` })], ['Read', 5, (k) => ({ file_path: `${cwdOf('acme-web-client')}/src/checkout/format-${k}.ts` })]],
      narration: ['Following the import graph inward from the entry point.', 'One helper is the only importer.'],
      report: 'A single helper imports it, for one call. Everything else in checkout uses the platform formatter already.' },
    { id: '8d20fa64', type: 'crew-frontend-expert', desc: 'Replace the receipt formatter and re-measure',
      tokens: { input: 1230, creation: 4100, read: 20_150, output: 1610 },
      plan: [['Edit', 4, (k) => ({ file_path: `${cwdOf('acme-web-client')}/src/checkout/format-${k}.ts` })], ['Bash', 3, (k) => ({ command: `npm run build -- --budget checkout-${k}`, description: 'Re-measure against the budget' })]],
      narration: ['Swapping the helper.', 'Re-measuring rather than assuming.'],
      report: 'Bundle is 38 KB under budget after the swap. Receipt output is byte-identical in the twelve locales the tests cover.' },
  ],
});

smallSession({
  project: 'acme-notifier', sid: 'd1408b6a-3fe5-4c72-b0d9-6a7e51c93b8f', title: 'Retry queue draining', titleType: 'ai',
  branch: 'main', startAgo: 3 * 24 * 60 * MIN,
  msgs: [
    { role: 'user', text: 'The notification retry queue is not draining overnight. Where does it stall?' },
    { role: 'assistant', read: 12_440, content: [
      { type: 'text', text: 'Reading the consumer loop first. A queue that drains during the day and not at night is usually a lease that outlives the worker rather than a throughput problem.' },
      { type: 'tool_use', id: 'toolu_n1', name: 'Read', input: { file_path: `${cwdOf('acme-notifier')}/src/queue/consumer.ts` } },
    ] },
    { role: 'user', text: 'Makes sense — the nightly deploy restarts the workers.' },
    { role: 'assistant', read: 16_300, content: [
      { type: 'text', text: 'Then that is it: the lease is thirty minutes and nothing releases it on shutdown, so every restart parks its in-flight messages for half an hour. A shutdown hook that releases the lease turns the overnight stall into a few seconds.' },
    ] },
  ],
  agents: [],
});

smallSession({
  project: 'acme-data-platform', sid: '3a6f92c4-8e07-4d15-93b2-7c40ab1d5e69', title: 'Nightly rollup backfill', titleType: 'ai',
  branch: 'feat/rollups', startAgo: 9 * 60 * MIN,
  msgs: [
    { role: 'user', text: 'The nightly rollup missed two days. Backfill them without double counting.' },
    { role: 'assistant', read: 20_770, content: [
      { type: 'text', text: 'Backfilling into a rollup that is not idempotent is how you turn two missing days into two wrong days. Checking whether the writer upserts on the partition key before running anything.' },
      { type: 'tool_use', id: 'toolu_d1', name: 'Read', input: { file_path: `${cwdOf('acme-data-platform')}/jobs/rollup.py` } },
    ] },
    { role: 'user', text: 'Assume it does not.' },
    { role: 'assistant', read: 25_180, content: [
      { type: 'text', text: 'Then the safe order is: write the two days into a staging table, compare row counts and sums against the source, and swap the partitions only if both match. That way a wrong backfill is visible before it is authoritative.' },
    ] },
  ],
  agents: [
    { id: 'b3719ce5', type: 'crew-database-expert', desc: 'Stage the backfill and compare before swapping',
      tokens: { input: 1340, creation: 4600, read: 21_430, output: 1720 },
      plan: [['Bash', 6, (k) => ({ command: `python jobs/rollup.py --stage --day 2026-08-0${k}`, description: 'Stage one day' })], ['Read', 3, (k) => ({ file_path: `${cwdOf('acme-data-platform')}/jobs/verify-${k}.sql` })]],
      narration: ['Staging both days first.', 'Comparing counts and sums against the source.'],
      report: 'Both days staged. Counts match to the row and the revenue sums match to the cent, so the partition swap is safe to run.' },
  ],
});

/* -------------------------------------------------------- the crew map */
// The Map view draws .crewforth/crew-map.json, which Crewforth's own scanner writes. The hero project gets the files
// of one of the scanner's test projects (packaging/crew-map-test/fixtures/node-ws: invented @demo packages) and the
// real scanner runs over them, so the picture is the scanner's output, not a drawing of one.
{
  const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
  const src = path.join(repo, 'packaging', 'crew-map-test', 'fixtures', 'node-ws');
  const copy = (from, to) => {
    for (const e of fs.readdirSync(from, { withFileTypes: true })) {
      if (e.name === 'expected.json') continue;
      const name = e.name.startsWith('_env') ? `.env${e.name.slice(4)}` : e.name;
      if (e.isDirectory()) { mk(path.join(to, name)); copy(path.join(from, e.name), path.join(to, name)); }
      else fs.copyFileSync(path.join(from, e.name), path.join(to, name));
    }
  };
  copy(src, HERO_CWD);
  const scan = spawnSync(process.execPath, [path.join(repo, 'kit', 'eval', 'lib', 'crew-map', 'scan.mjs'), '--root', HERO_CWD], { encoding: 'utf8' });
  if (scan.status !== 0) throw new Error(`the crew map scanner failed (rc ${scan.status}): ${scan.stderr}`);
}

console.log(JSON.stringify({ root: ROOT, hero: HERO, second: SECOND, work: WORK, latest: LATEST }, null, 2));
