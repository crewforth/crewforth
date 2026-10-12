// The flow take: one session's delegation assembling itself on the graph, filmed.
//
// grow.mjs lays the session down step by step while this films the canvas. The view is left to the panel: it
// fits the graph as it grows for as long as nobody has moved it, and nobody does. The navigator is collapsed to
// its rail so the canvas has the width.
import os from 'node:os';
import path from 'node:path';
import { open, film, leaks, sleep, arg } from './stage.mjs';

const OUT = arg('out', path.join(os.tmpdir(), 'crewforth-studio-record', 'film'));
const SESSION = arg('session', '');
const SECS = Number(arg('secs', 28));
const FPS = Number(arg('fps', 10));

const stage = await open({
  name: 'shoot', port: Number(arg('cdp', 9333)), url: arg('url', 'http://127.0.0.1:7802/?token=studio-record'),
  w: Number(arg('w', 1920)), h: Number(arg('h', 1000)), scale: Number(arg('scale', 2)),
  profile: arg('profile', path.join(os.tmpdir(), 'crewforth-studio-record', 'chrome-flow')),
});
const { ev, die } = stage;

// The session by hand: the one being filmed starts empty on purpose, so left alone the panel is on another.
const picked = await ev(`
  (() => {
    const row = [...document.querySelectorAll('.srow[data-id]')].find((r) => r.dataset.id.startsWith(${JSON.stringify(SESSION.slice(0, 8))}));
    if (!row) return 'not found';
    row.click();
    return row.dataset.id;
  })()`);
if (picked === 'not found') die(`session ${SESSION} is not in the navigator`);
await sleep(900);
await ev(`document.getElementById('view-graph').click(); document.getElementById('side-hide').click(); 1`);
await sleep(700);
if (!await ev(`document.querySelector('.shell').classList.contains('no-side')`)) die('the navigator did not collapse');

const take = film(stage, OUT, FPS);
await sleep(SECS * 1000);
const frames = await take.stop();

const end = await ev(`JSON.stringify({ cards: document.querySelectorAll('#canvas .cv-node').length, zoom: document.getElementById('tb-zoom').textContent, view: document.querySelector('.stage').dataset.view, errs: window.__errs })`);
const seen = await leaks(ev, [os.homedir(), os.userInfo().username, os.hostname().split('.')[0]]);
console.log(`shoot: ${frames} frames -> ${OUT} · ended ${end}`);
if (JSON.parse(end).errs.length) die(`the page reported errors during the take: ${end}`);
if (seen.length) die(`the take shows something of this machine: ${seen.join(', ')}`);
stage.close();
