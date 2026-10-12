#!/usr/bin/env node
// Does the toolbar hold what it shows, at every width, in every view? Measured in a real browser.
//
//   node packaging/studio-test/toolbar-fit.mjs               this checkout's panel, on a synthetic session
//   node packaging/studio-test/toolbar-fit.mjs --twin        the same with the fit taken away: must fail
//   node packaging/studio-test/toolbar-fit.mjs --real URL    a panel that is already running, as it is
//   ... --chrome PATH --from 1700 --to 320 --step 10 --json FILE
//
// Not a gate, and not wired into verify.sh: it needs a Chrome, and how wide words are belongs to the machine's
// fonts. The selfcheck pins the rule (the toolbar is measured, a step at a time); this is where the rule is seen
// to hold. Run it on each platform the panel is used on.
//
// What is measured: for each view (Graph, Timeline, List), with the menus showing their shortest words and then
// their longest, at each window width from --from down to --to, whether anything shown in the toolbar ends past
// the toolbar's own content edge. The window is the only thing changed: the navigator is open, as it is for a
// viewer, so the toolbar is narrower than the window.
//
// Exit: 0 nothing ran over · 1 something did · 2 not measured (no browser, or the panel did not come up).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { CDP, httpJson } from '../studio-record/cdp.mjs';
import { findChrome } from './chrome.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..');
const arg = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : fallback; };
const flag = (name) => process.argv.includes(`--${name}`);
const FROM = Number(arg('from', 1700));
const TO = Number(arg('to', 320));
const STEP = Number(arg('step', 10));
const REAL = arg('real', null);
const TWIN = flag('twin');
const JSON_OUT = arg('json', null);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const notMeasured = (m) => { console.error(`toolbar-fit: NOT MEASURED — ${m}`); process.exit(2); };

const kids = [];
process.on('exit', () => { for (const k of kids) { try { k.kill(); } catch { /* gone */ } } });

async function startPanel() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-toolbar-'));
  const root = path.join(tmp, 'projects');
  // The recorder's synthetic session: every name in it is invented, and its working directories go under tmp.
  const made = spawnSync(process.execPath, [path.join(REPO, 'packaging', 'studio-record', 'fixture.mjs'), root, '0.0.0', path.join(tmp, 'work')], { encoding: 'utf8' });
  if (made.status !== 0) notMeasured(`the fixture was not written: ${made.stderr.trim().split('\n').pop()}`);
  const port = 7900 + Math.floor(Math.random() * 90);
  const token = 'toolbar-fit';
  const server = spawn(process.execPath, [path.join(REPO, 'kit', 'studio', 'server', 'index.js'), '--port', String(port)], {
    env: { ...process.env, CREW_STUDIO_TOKEN: token, CREW_STUDIO_PROJECTS_ROOT: root, CREW_STUDIO_RUNTIME: path.join(tmp, 'runtime'), CREW_UPDATE_URL: 'data:application/json,{"latest":"0.0.0"}' },
    stdio: 'ignore',
  });
  kids.push(server);
  const url = `http://127.0.0.1:${port}/?token=${token}`;
  for (let i = 0; i < 40; i += 1) {
    await sleep(250);
    try { const r = await fetch(url); if (r.ok) return url; } catch { /* not up yet */ }
  }
  return notMeasured('the panel did not start');
}

const chromePath = findChrome(arg('chrome', process.env.CHROME_PATH ?? null));
if (!chromePath) notMeasured('no Chrome or Edge found — pass --chrome PATH');
const url = REAL ?? await startPanel();
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-toolbar-chrome-'));
const port = 9500 + Math.floor(Math.random() * 90);
const chrome = spawn(chromePath, [
  `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--headless=new', `--window-size=${FROM},900`,
  '--no-first-run', '--no-default-browser-check', '--disable-extensions', 'about:blank',
], { stdio: 'ignore' });
kids.push(chrome);
let targets = null;
for (let i = 0; i < 60 && !targets; i += 1) { await sleep(250); try { targets = await httpJson(port, '/json/list'); } catch { /* not up */ } }
if (!targets) notMeasured('the browser never opened its debugging port');
const cdp = await new CDP(targets.find((t) => t.type === 'page').webSocketDebuggerUrl).connect();
await cdp.call('Page.enable');
await cdp.call('Runtime.enable');
const width = (w) => cdp.call('Emulation.setDeviceMetricsOverride', { width: w, height: 900, deviceScaleFactor: 1, mobile: false });
await width(FROM);
await cdp.call('Page.navigate', { url });
await sleep(3000);
const ev = (code) => cdp.eval(`(async () => JSON.stringify(await (${code})))()`).then((s) => JSON.parse(s));

const opened = await ev(`(() => { const row = document.querySelector('.srow[data-id]'); if (!row) return null; row.click(); return row.dataset.id; })()`);
if (!opened) notMeasured('the panel shows no session to open');
await sleep(1200);

if (TWIN) {
  // The fit, taken away: every word and every menu stays whatever the step says. A measurement that cannot see
  // this run over cannot see anything.
  await ev(`(() => { const s = document.createElement('style'); s.textContent = '.toolbar .tb-words { display: inline !important; } .toolbar :is(#tb-group, #tb-density, #tb-show, #tb-expand, #tb-fold):not([hidden]) { display: inline-flex !important; } .toolbar #tb-zoom:not([hidden]), .toolbar .tb-range:not([hidden]) { display: inline-flex !important; }'; document.head.append(s); return 1; })()`);
}

// One reading: how far the furthest thing shown in the toolbar ends past the toolbar's content edge.
const READ = `(() => {
  const bar = document.querySelector('.toolbar');
  const box = bar.getBoundingClientRect();
  const limit = box.right - (parseFloat(getComputedStyle(bar).paddingRight) || 0);
  // A thing squeezed to no width (the note gives way first) shows nothing, wherever its edge is.
  const shown = [...bar.children].filter((c) => !c.classList.contains('toolbar-fill') && c.getBoundingClientRect().width > 0);
  const over = shown.length ? Math.max(...shown.map((c) => c.getBoundingClientRect().right)) - limit : 0;
  return { bar: Math.round(box.width), over: Math.round(over * 10) / 10, step: bar.dataset.fit ?? null, shown: shown.length, displayed: box.width > 0 };
})()`;
const pick = (button, word) => ev(`(async () => {
  document.getElementById(${JSON.stringify(button)}).click();
  await new Promise((r) => setTimeout(r, 150));
  const item = [...document.querySelectorAll('[role="menuitem"], [role="menuitemradio"], .menu button, .menu-item')].find((e) => e.textContent.trim() === ${JSON.stringify(word)});
  if (!item) { document.body.click(); return false; }
  item.click();
  return true;
})()`);

const WORDS = {
  shortest: [['tb-group', 'None'], ['tb-density', 'Auto'], ['tb-show', 'All']],
  longest: [['tb-group', 'Workflow run'], ['tb-density', 'Comfortable'], ['tb-show', 'Needs attention']],
};
const rows = [];
for (const [words, picks] of Object.entries(WORDS)) {
  // The menus are chosen from while the window is wide, on the Graph, where all three are on the toolbar.
  await width(FROM);
  await ev(`(document.getElementById('view-graph').click(), 1)`);
  await sleep(300);
  for (const [button, word] of picks) {
    if (!await pick(button, word)) notMeasured(`the ${button} menu has no "${word}"`);
    await sleep(200);
  }
  const said = await ev(`['tb-group', 'tb-density', 'tb-show'].map((id) => document.querySelector('#' + id + ' > span').textContent)`);
  if (said.join('|') !== picks.map((p) => p[1]).join('|')) notMeasured(`the menus say ${said.join(', ')}, not ${picks.map((p) => p[1]).join(', ')}`);
  for (const view of ['graph', 'timeline', 'list']) {
    await width(FROM);
    await ev(`(document.getElementById('view-${view}').click(), 1)`);
    await sleep(300);
    for (let w = FROM; w >= TO; w -= STEP) {
      await width(w);
      await sleep(140);
      rows.push({ words, view, window: w, ...await ev(READ) });
    }
  }
}

let failed = 0;
console.log(`toolbar-fit: ${REAL ? 'a running panel' : 'this checkout'}${TWIN ? ', the fit taken away (must fail)' : ''} · window ${FROM}→${TO} px by ${STEP} · ${os.platform()} · ${path.basename(chromePath)}`);
for (const words of Object.keys(WORDS)) {
  for (const view of ['graph', 'timeline', 'list']) {
    const mine = rows.filter((r) => r.words === words && r.view === view);
    const hidden = mine.filter((r) => !r.displayed || !r.shown);
    const over = mine.filter((r) => r.over > 0.5);
    failed += over.length + hidden.length;
    const steps = [...new Set(mine.map((r) => r.step))].map((s) => {
      const at = mine.filter((r) => r.step === s).map((r) => r.bar);
      return `${s ?? 'none'}: ${Math.min(...at)}–${Math.max(...at)}`;
    }).join(' · ');
    console.log(`${(over.length || hidden.length) ? 'FAIL' : 'ok  '} ${view.padEnd(8)} ${words.padEnd(8)} ${String(mine.length).padStart(3)} widths (toolbar ${Math.min(...mine.map((r) => r.bar))}–${Math.max(...mine.map((r) => r.bar))} px) · ran over at ${over.length}`
      + (over.length ? ` (toolbar ${Math.min(...over.map((r) => r.bar))}–${Math.max(...over.map((r) => r.bar))} px, worst +${Math.max(...over.map((r) => r.over))} px)` : '')
      + (hidden.length ? ` · NOT ON SCREEN at ${hidden.length}` : '')
      + ` · step by toolbar width — ${steps}`);
  }
}
if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify(rows, null, 1));
console.log(failed ? `toolbar-fit: FAIL — ${failed} readings ran over or were not on screen` : `toolbar-fit: ok — ${rows.length} readings, none ran over`);
cdp.close();
process.exit(failed ? 1 : 0);
