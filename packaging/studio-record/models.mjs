// The Models still: which model each kind of task has needed, with one agent's task card beside it.
//
// The fixture gives the session's project a record of outcomes (fixture.mjs, writeOutcomes) and its crew agents a
// task card. This opens the session, selects the agent whose card failed once and ran again one model up, turns to
// the Models view, and takes one picture. Like the other takes it states what must be on the page before it
// shoots, and fails if the page shows this machine's home directory, user or name.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { open, cursor, findByText, centreOf, leaks, sleep, arg } from './stage.mjs';

const OUT = arg('out', path.join(os.tmpdir(), 'crewforth-studio-record', 'studio-models.png'));
const SESSION = arg('session', 'Duplicate settlements');
const AGENT = arg('agent', 'Add idempotency keys');
const MACHINE = [os.homedir(), os.userInfo().username, os.hostname().split('.')[0]];

const stage = await open({
  name: 'models', port: Number(arg('cdp', 9366)), url: arg('url', 'http://127.0.0.1:7802/?token=studio-record'),
  w: Number(arg('w', 1600)), h: Number(arg('h', 900)), scale: Number(arg('scale', 2)),
  profile: arg('profile', path.join(os.tmpdir(), 'crewforth-studio-record', 'chrome-models')),
});
const { ev, die, cdp } = stage;
const { clickAt } = await cursor(stage);
const click = async (found, what) => { if (!found) die(`${what} is not on the page`); await clickAt(found); };

await sleep(900);
await click(await findByText(ev, '.srow', SESSION), `the session "${SESSION}"`);
await sleep(2200);
await click(await findByText(ev, '#canvas .cv-node', AGENT), `the agent "${AGENT}"`);
await sleep(1600);
await click(await centreOf(ev, '#view-models'), 'the Models tab');
await sleep(2600);                                   // the record, then what its classes cost

const seen = JSON.parse(await ev(`JSON.stringify({
  rows: document.querySelectorAll('#models tbody tr').length,
  suggestion: document.querySelector('#models .mv-suggest button')?.textContent ?? null,
  tags: [...new Set([...document.querySelectorAll('#models .mv-tag[data-kind]')].map((t) => t.dataset.kind))].sort().join(','),
  priced: [...document.querySelectorAll('#models td.mv-num')].some((c) => /\\$/.test(c.textContent)),
  card: [...document.querySelectorAll('#inspector .isec')].some((x) => /Task card/i.test(x.children[0]?.textContent ?? '')),
  steps: document.querySelectorAll('#inspector .isteps li').length,
  errs: window.__errs ?? [],
})`));
if (seen.rows < 4) die(`the Models view has ${seen.rows} classes; the fixture's record was not read`);
if (seen.suggestion !== 'Copy command') die('the suggestion and its Copy command button are not on the page');
if (seen.tags !== 'lowered,raised') die(`expected one raised and one lowered class, saw "${seen.tags}"`);
if (!seen.priced) die('no class has a cost: what the classes cost was not read');
if (!seen.card || seen.steps < 2) die(`the inspector shows no task card with its steps (card ${seen.card}, steps ${seen.steps})`);
if (seen.errs.length) die(`the page reported errors: ${JSON.stringify(seen.errs)}`);
const leaked = await leaks(ev, MACHINE);
if (leaked.length) die(`the picture shows something of this machine: ${leaked.join(', ')}`);

// A still has no pointer in it: the one the takes draw for a film is taken off the page before the shot.
await ev(`(() => { for (const id of ['__cursor', '__ring']) document.getElementById(id)?.remove(); return 1; })()`);
await cdp.call('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 4, y: 4 });
await sleep(300);
const shot = await cdp.call('Page.captureScreenshot', { format: 'png' });
fs.writeFileSync(OUT, Buffer.from(shot.data, 'base64'));
console.log(`models: ${seen.rows} classes, tags ${seen.tags}, ${seen.steps} steps in the inspector -> ${OUT}`);
stage.close();
