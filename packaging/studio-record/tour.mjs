// The tour take: what the panel does when it is used.
//
// The flow take answers "what is running"; this one answers "and then what". It is scripted rather than
// hand-driven so that it can be re-shot identically after a change to the panel, and so that the length of each
// beat is a number in one place.
//
// A beat that clicks nothing looks identical to a beat that worked, until the film is assembled and half of it
// is one still frame. So each beat states what must be true afterwards, and the take stops if it is not.
import os from 'node:os';
import path from 'node:path';
import { open, cursor, film, findByText, centreOf, leaks, sleep, arg } from './stage.mjs';

const OUT = arg('out', path.join(os.tmpdir(), 'crewforth-studio-record', 'tour'));
const URL_ = arg('url', 'http://127.0.0.1:7802/?token=studio-record');
const SESSION = arg('session', 'Duplicate settlements');
// The session a request is made in, while another one is on screen: a request reaches the viewer wherever they are.
const ASKING = arg('asking', '');
const ASKING_CWD = arg('asking-cwd', '');
const FPS = Number(arg('fps', 10));

// What must never be in a frame: this machine's home directory, its user and its name.
const MACHINE = [os.homedir(), os.userInfo().username, os.hostname().split('.')[0]];

const stage = await open({
  name: 'tour', port: Number(arg('cdp', 9355)), url: URL_,
  w: Number(arg('w', 1680)), h: Number(arg('h', 940)), scale: Number(arg('scale', 2)),
  profile: arg('profile', path.join(os.tmpdir(), 'crewforth-studio-record', 'chrome-tour')),
});
const { ev, die } = stage;
const { clickAt } = await cursor(stage);

const beat = async (label, act, expect, hold = 1500) => {
  process.stdout.write(`tour: ${label}\n`);
  await act();
  await sleep(hold);
  const got = await ev(expect.probe);
  const ok = expect.want(got);
  process.stdout.write(`      ${ok ? 'ok' : 'DID NOTHING'} — ${expect.name}: ${JSON.stringify(got).slice(0, 90)}\n`);
  if (!ok) die(`beat "${label}" changed nothing`);
  // Asked after every beat, not once at the end: a path that was on screen for one beat is in the film.
  const seen = await leaks(ev, MACHINE);
  if (seen.length) die(`beat "${label}" shows something of this machine: ${seen.join(', ')}`);
};
const click = async (found, what) => { if (!found) die(`${what} is not on the page`); await clickAt(found); };

const take = film(stage, OUT, FPS);
await sleep(900);

await beat('open the session from the navigator', async () => {
  await click(await findByText(ev, '.srow', SESSION), `the session "${SESSION}"`);
}, { name: 'cards on the graph', probe: `document.querySelectorAll('#canvas .cv-node').length`, want: (v) => v > 5 }, 2200);

await beat('open an agent: what it did, and what it reported', async () => {
  await click(await findByText(ev, '#canvas .cv-node', 'Add idempotency keys'), 'a finished agent');
}, { name: 'inspector on Overview', probe: `document.getElementById('inspector').hidden === false && !!document.querySelector('.itiles')`, want: (v) => v === true }, 2600);

await beat('the same session against time', async () => {
  await click(await centreOf(ev, '#view-timeline'), 'the Timeline tab');
}, { name: 'rows on the Timeline', probe: `document.querySelectorAll('#timeline .tl-row').length`, want: (v) => v > 5 }, 1400);

await beat('the whole session, and the agent that failed', async () => {
  await click(await centreOf(ev, '#tb-range-out'), 'the range control');
  await sleep(350);
  await click(await centreOf(ev, '#tb-range-out'), 'the range control');
  await sleep(700);
  await click(await findByText(ev, '#timeline .tl-agent .tl-lab', 'Claude Code Guide'), 'the failed agent\'s row');
}, { name: 'drawer with its last error', probe: `document.querySelector('.tl-drawer').hidden === false && document.querySelector('.tl-d-error').textContent.length > 20`, want: (v) => v === true }, 2800);

await beat('the list: what needs someone, first', async () => {
  await click(await centreOf(ev, '#view-list'), 'the List tab');
}, { name: 'sections in the List', probe: `[...document.querySelectorAll('#list .ls-title')].map((t) => t.textContent).join(' | ')`, want: (v) => /Failed/.test(v) && /Done/.test(v) }, 2400);

await beat('a critical agent: why the gate called it critical', async () => {
  // Done is folded until asked for: open it, then the security scan of the release audit.
  await click(await centreOf(ev, '#list .ls-head[data-key="sec:done"]'), 'the Done section');
  await sleep(700);
  await click(await findByText(ev, '#list .ls-row', 'secret handling'), 'the security scan');
}, { name: 'why critical in its task card', probe: `[...document.querySelectorAll('#inspector .icard dt')].some((d) => d.textContent === 'why critical' && /change: security/.test(d.nextElementSibling?.textContent ?? ''))`, want: (v) => v === true }, 2800);

await beat('the project, not the session: which model each kind of task has needed', async () => {
  await click(await centreOf(ev, '#view-models'), 'the Models tab');
}, { name: 'classes, the advisor tag and the work above the table', probe: `[document.querySelectorAll('#models tbody tr').length, document.querySelectorAll('#models .mv-tag[data-kind="advisor"]').length, document.querySelectorAll('#models .mv-above').length].join()`, want: (v) => { const [rows, adv, above] = String(v).split(',').map(Number); return rows > 3 && adv >= 1 && above === 1; } }, 3200);

await beat('the project as its crew map shows it', async () => {
  await click(await centreOf(ev, '#view-map'), 'the Map tab');
}, { name: 'modules on the Map', probe: `document.querySelectorAll('#map .mp-mod').length`, want: (v) => v > 3 }, 3200);

// A tool call in another session now waits on the viewer. It is started here, off screen, through the panel's
// own API; the stand-in CLI answers the message by playing a tool call through the real approval hook.
if (ASKING) {
  const made = await ev(`
    (async () => {
      const token = new URLSearchParams(location.search).get('token');
      const post = (p, body) => fetch(p + '?token=' + token, { method: 'POST', headers: { 'content-type': 'application/json', 'x-crew-studio': '1', authorization: 'Bearer ' + token }, body: JSON.stringify(body) }).then((r) => r.json());
      const s = await post('/api/owned', { cwd: ${JSON.stringify(ASKING_CWD)}, permissionMode: 'acceptEdits', resume: ${JSON.stringify(ASKING)} });
      if (!s.ok) return 'not started: ' + s.reason;
      const m = await post('/api/owned/' + s.session.sessionId + '/message', { text: 'Go on.' });
      return m.ok ? 'asked' : 'not sent: ' + m.reason;
    })()`);
  if (made !== 'asked') die(`the asking session: ${made}`);

  await beat('back to the graph; a request from another session arrives', async () => {
    await click(await centreOf(ev, '#view-graph'), 'the Graph tab');
  }, { name: 'the dock is up', probe: `document.getElementById('dock').hidden === false && /Needs you/.test(document.getElementById('dock').textContent)`, want: (v) => v === true }, 3200);

  await beat('answer it', async () => {
    await click(await findByText(ev, '#dock .dock-acts button', 'Allow once'), 'Allow once');
  }, { name: 'the dock is gone', probe: `document.getElementById('dock').hidden`, want: (v) => v === true }, 1800);
}

await beat('start a session: where, how much it may do, and what it is asked first', async () => {
  await click(await centreOf(ev, '#new-session'), 'New session');
}, { name: 'the New session panel', probe: `document.getElementById('new-panel').hidden === false && document.querySelectorAll('.np-mode').length`, want: (v) => v === 3 }, 3000);

await beat('and leave it', async () => {
  await click(await findByText(ev, '.np-foot button', 'Cancel'), 'Cancel');
}, { name: 'the panel is closed', probe: `document.getElementById('new-panel').hidden`, want: (v) => v === true }, 1200);

const frames = await take.stop();
const errs = await ev(`JSON.stringify(window.__errs)`);
const seen = await leaks(ev, MACHINE);
console.log(`tour: ${frames} frames -> ${OUT}`);
if (errs !== '[]') die(`the page reported errors during the take: ${errs}`);
if (seen.length) die(`the take shows something of this machine: ${seen.join(', ')}`);
stage.close();
