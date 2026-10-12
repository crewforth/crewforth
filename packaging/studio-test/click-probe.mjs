#!/usr/bin/env node
// Does a click on an agent select it while the view is being redrawn? Measured in a real browser.
//
//   node packaging/studio-test/click-probe.mjs                  this checkout's panel, a synthetic session
//   node packaging/studio-test/click-probe.mjs --hold 1100      the button held longer than a redraw period
//   node packaging/studio-test/click-probe.mjs --real URL       a panel that is already running, as it is
//   ... --clicks 20 --view timeline,bars,list,graph --chrome PATH --json FILE
//
// Not a gate, and not wired into verify.sh: it needs a Chrome. The selfcheck pins the rule; this is where the
// rule is seen to hold, on each platform the panel is used on.
//
// What is measured, for each view (and, in the Timeline, for an agent's row and for its bar): N presses of the
// mouse on an agent that is not selected, each held for
// --hold ms and released, while the view is redrawn about once a second. After each: is that agent selected?
// And for the ones that are not: was the element that took the press still in the page at the release, and
// where did the browser send the click?
//
// The redraw. A view redraws itself once a second while it shows something that moves: the Timeline while its
// session is live, the List while an agent is running. This script's panel has no CLI, so its session is not
// live; the Timeline is made to redraw through the panel's own resize path instead (its height is changed by
// a pixel once a second, and the panel's ResizeObserver calls the same render()). The List's own tick runs,
// because the script keeps the fixture's running agents running. With --real nothing is forced: the panel is
// measured as it is, and the redraws counted are its own.
//
// Exit: 0 every press selected · 1 some did not · 2 not measured.
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
const HOLD = Number(arg('hold', 90));
const CLICKS = Number(arg('clicks', 20));
const REAL = arg('real', null);
const VIEWS = arg('view', 'all') === 'all' ? ['timeline', 'bars', 'list', 'graph'] : arg('view').split(',');
const JSON_OUT = arg('json', null);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const notMeasured = (m) => { console.error(`click-probe: NOT MEASURED — ${m}`); process.exit(2); };

// The fixture's hero session and the three agents it leaves running (packaging/studio-record/fixture.mjs).
const HERO = '7f3c1d20-9a4e-4b6f-8c21-5d0e2a41b9c7';
const RUNNING = ['f20a7c63', '5d93be08', 'c7e58f14'];

const kids = [];
let keepRunning = null;
process.on('exit', () => { clearInterval(keepRunning); for (const k of kids) { try { k.kill(); } catch { /* gone */ } } });

async function startPanel() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-click-'));
  const root = path.join(tmp, 'projects');
  const made = spawnSync(process.execPath, [path.join(REPO, 'packaging', 'studio-record', 'fixture.mjs'), root, '0.0.0', path.join(tmp, 'work')], { encoding: 'utf8' });
  if (made.status !== 0) notMeasured(`the fixture was not written: ${made.stderr.trim().split('\n').pop()}`);
  // An agent is running while its transcript was written in the last two minutes; keep those three written.
  const touch = () => {
    const now = new Date();
    for (const dir of fs.readdirSync(root)) {
      for (const a of RUNNING) { try { fs.utimesSync(path.join(root, dir, HERO, 'subagents', `agent-${a}.jsonl`), now, now); } catch { /* not this project */ } }
    }
  };
  touch();
  keepRunning = setInterval(touch, 20000);
  const port = 7900 + Math.floor(Math.random() * 90);
  const token = 'click-probe';
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
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-click-chrome-'));
const port = 9600 + Math.floor(Math.random() * 90);
const chrome = spawn(chromePath, [
  `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--headless=new', '--window-size=1500,900',
  '--no-first-run', '--no-default-browser-check', '--disable-extensions',
  '--disable-backgrounding-occluded-windows', '--disable-renderer-backgrounding', '--disable-background-timer-throttling',
  'about:blank',
], { stdio: 'ignore' });
kids.push(chrome);
let targets = null;
for (let i = 0; i < 60 && !targets; i += 1) { await sleep(250); try { targets = await httpJson(port, '/json/list'); } catch { /* not up */ } }
if (!targets) notMeasured('the browser never opened its debugging port');
const cdp = await new CDP(targets.find((t) => t.type === 'page').webSocketDebuggerUrl).connect();
await cdp.call('Page.enable');
await cdp.call('Runtime.enable');
await cdp.call('Emulation.setDeviceMetricsOverride', { width: 1500, height: 900, deviceScaleFactor: 1, mobile: false });
await cdp.call('Page.navigate', { url });
await sleep(3000);
const ev = (code) => cdp.eval(`(async () => JSON.stringify(await (${code})))()`).then((s) => JSON.parse(s));

const opened = await ev(`(() => { const rows = [...document.querySelectorAll('.srow[data-id]')]; const row = rows.find((r) => r.dataset.id.startsWith('7f3c1d20')) ?? rows[0]; if (!row) return null; row.click(); return row.dataset.id; })()`);
if (!opened) notMeasured('the panel shows no session to open');
await sleep(1500);

// In the page: what the mouse met. The element that took the press is kept, so that at the release it can be
// asked whether it is still in the page.
await ev(`(() => {
  window.__probe = { down: null, events: [], redraws: [] };
  const key = (el) => el?.closest?.('[data-key], .cv-node[data-id]')?.dataset?.key ?? el?.closest?.('.cv-node[data-id]')?.dataset?.id ?? null;
  addEventListener('mousedown', (e) => { window.__probe.down = e.target; window.__probe.events.push({ type: 'down', at: performance.now(), key: key(e.target) }); }, true);
  addEventListener('mouseup', (e) => { const d = window.__probe.down; window.__probe.events.push({ type: 'up', at: performance.now(), key: key(e.target), sameElement: e.target === d, pressedStillInPage: Boolean(d?.isConnected) }); }, true);
  addEventListener('click', (e) => { window.__probe.events.push({ type: 'click', at: performance.now(), key: key(e.target), on: (e.target.className || e.target.tagName || '').toString().slice(0, 40) }); }, true);
  return 1;
})()`);

const VIEW = {
  timeline: {
    host: '#timeline .tl-rows', targets: '#timeline .tl-agent .tl-lab[data-key]',
    selected: `document.querySelector('#timeline .tl-row.on .tl-lab')?.dataset.key ?? null`,
  },
  // The Timeline's bars are buttons too: a press on an agent's bar chooses that agent.
  bars: {
    tab: 'timeline', host: '#timeline .tl-rows', targets: '#timeline .tl-agent .tl-bar[data-key]:not(.on)',
    selected: `(document.querySelector('#timeline .tl-row.on .tl-bar')?.dataset.key ?? null)`,
    same: (aimed, selected) => Boolean(selected) && aimed.split(':')[1] === selected.split(':')[1],
  },
  list: {
    host: '#list', targets: '#list .ls-row[data-key]',
    selected: `document.querySelector('#list .ls-row.on')?.dataset.key ?? null`,
  },
  graph: {
    host: '#canvas', targets: '#canvas .cv-node[data-id]',
    selected: `document.querySelector('#canvas .cv-node.cv-selected')?.dataset.id ?? null`,
  },
};

const results = {};
for (const view of VIEWS) {
  const v = VIEW[view];
  const tab = v.tab ?? view;
  await ev(`(document.getElementById('view-${tab}').click(), 1)`);
  await sleep(900);
  if (tab === 'timeline') await ev(`([...document.querySelectorAll('#timeline button')].find((b) => /whole session/.test(b.textContent))?.click(), 1)`);
  if (view === 'list') await ev(`([...document.querySelectorAll('#list .ls-head[data-key]')].filter((h) => /show/.test(h.textContent)).forEach((h) => h.click()), 1)`);
  await sleep(600);
  // Count the view's own redraws: a redraw is its rows being put in again.
  await ev(`(() => { window.__probe.redraws = []; window.__probe.observer?.disconnect();
    const host = document.querySelector(${JSON.stringify(v.host)}); if (!host) return 0;
    window.__probe.observer = new MutationObserver((ms) => { if (ms.some((m) => m.addedNodes.length)) window.__probe.redraws.push(performance.now()); });
    window.__probe.observer.observe(host, { childList: true }); return 1; })()`);
  // The forced redraw, for the Timeline of a session that is not live (see the head of this file).
  if (tab === 'timeline' && !REAL) {
    await ev(`(() => { const t = document.getElementById('timeline'); let n = 0; clearInterval(window.__probe.drive);
      window.__probe.drive = setInterval(() => { n += 1; t.style.paddingBottom = (n % 2) + 'px'; }, 1000); return 1; })()`);
  } else {
    await ev(`(clearInterval(window.__probe.drive), 1)`);
  }
  // How often the view redraws when nobody touches it: counted before the first press, because a selection redraws too.
  await sleep(4200);
  const quiet = await ev(`(() => { const r = window.__probe.redraws.filter((t) => t > performance.now() - 4000); return +(r.length / 4).toFixed(2); })()`);

  const rows = [];
  for (let i = 0; i < CLICKS; i += 1) {
    const aim = await ev(`(() => {
      const now = ${v.selected};
      const all = [...document.querySelectorAll(${JSON.stringify(v.targets)})].map((el) => ({ el, key: el.dataset.key ?? el.dataset.id, r: el.getBoundingClientRect() }))
        .filter((t) => t.key !== now && t.r.width > 0 && !/^session$|^wf:|^g:/.test(t.key));
      for (const t of all.slice(${i} % Math.max(1, all.length)).concat(all)) {
        const x = Math.round(t.r.left + Math.min(60, t.r.width / 2)), y = Math.round(t.r.top + t.r.height / 2);
        const hit = document.elementFromPoint(x, y);
        if (hit && t.el.contains(hit) && y > 0 && y < innerHeight) return { key: t.key, x, y };
      }
      return null;
    })()`);
    if (!aim) notMeasured(`the ${view} view has no agent to press on`);
    await ev(`(window.__probe.events = [], 1)`);
    const before = await ev(`window.__probe.redraws.length`);
    await cdp.call('Input.dispatchMouseEvent', { type: 'mouseMoved', x: aim.x, y: aim.y });
    await cdp.call('Input.dispatchMouseEvent', { type: 'mousePressed', x: aim.x, y: aim.y, button: 'left', buttons: 1, clickCount: 1 });
    await sleep(HOLD);
    await cdp.call('Input.dispatchMouseEvent', { type: 'mouseReleased', x: aim.x, y: aim.y, button: 'left', buttons: 0, clickCount: 1 });
    await sleep(260);
    const seen = await ev(`({ selected: ${v.selected}, events: window.__probe.events, redraws: window.__probe.redraws.length })`);
    const down = seen.events.find((e) => e.type === 'down'); const up = seen.events.find((e) => e.type === 'up'); const click = seen.events.find((e) => e.type === 'click');
    const during = down && up ? await ev(`window.__probe.redraws.filter((t) => t >= ${down.at} && t <= ${up.at}).length`) : null;
    rows.push({
      aimed: aim.key, selected: v.same ? v.same(aim.key, seen.selected) : seen.selected === aim.key, redrawnDuringPress: during,
      pressedStillInPage: up?.pressedStillInPage ?? null, sameElement: up?.sameElement ?? null,
      click: click ? (click.key === aim.key ? 'on what was pressed' : `elsewhere (${click.on})`) : 'none',
    });
    // Not a multiple of the redraw period, so the presses fall at different moments of it.
    await sleep(470);
  }
  results[view] = { rows, redrawRate: quiet };
}

let missed = 0;
console.log(`click-probe: ${REAL ? 'a running panel' : 'this checkout'} · ${CLICKS} presses a view, each held ${HOLD} ms · ${os.platform()} · ${path.basename(chromePath)}`);
for (const view of VIEWS) {
  const { rows, redrawRate } = results[view];
  const ok = rows.filter((r) => r.selected).length;
  const miss = rows.filter((r) => !r.selected);
  missed += miss.length;
  const straddled = rows.filter((r) => r.redrawnDuringPress > 0);
  console.log(`${miss.length ? 'FAIL' : 'ok  '} ${view.padEnd(8)} selected ${String(ok).padStart(2)} of ${rows.length} · redrawn ${redrawRate} times a second when left alone · a redraw fell inside the press at ${straddled.length} (selected ${straddled.filter((r) => r.selected).length} of those)`
    + (miss.length ? ` · of the ${miss.length} that did not select: the pressed element was gone at the release in ${miss.filter((r) => r.pressedStillInPage === false).length}, the click went ${[...new Set(miss.map((r) => r.click))].join(' / ')}` : ''));
}
if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify(results, null, 1));
console.log(missed ? `click-probe: FAIL — ${missed} presses did not select` : `click-probe: ok — every press selected`);
cdp.close();
process.exit(missed ? 1 : 0);
