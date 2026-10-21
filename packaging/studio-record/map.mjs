// The Map still: the session's project as its crew map shows it.
//
// The fixture copies one of the scanner's test projects into the hero project and runs Crewforth's own scanner over
// it (fixture.mjs, "the crew map"), so the map on screen is the scanner's output. This opens the session, turns to
// the Map view and takes one picture. Like the other takes it states what must be on the page before it shoots, and
// fails if the page shows this machine's home directory, user or name.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { open, cursor, findByText, centreOf, leaks, sleep, arg } from './stage.mjs';

const OUT = arg('out', path.join(os.tmpdir(), 'crewforth-studio-record', 'studio-map.png'));
const SESSION = arg('session', 'Duplicate settlements');
const MACHINE = [os.homedir(), os.userInfo().username, os.hostname().split('.')[0]];

const stage = await open({
  name: 'map', port: Number(arg('cdp', 9367)), url: arg('url', 'http://127.0.0.1:7802/?token=studio-record'),
  w: Number(arg('w', 1600)), h: Number(arg('h', 900)), scale: Number(arg('scale', 2)),
  profile: arg('profile', path.join(os.tmpdir(), 'crewforth-studio-record', 'chrome-map')),
});
const { ev, die, cdp } = stage;
const { clickAt } = await cursor(stage);
const click = async (found, what) => { if (!found) die(`${what} is not on the page`); await clickAt(found); };

await sleep(900);
await click(await findByText(ev, '.srow', SESSION), `the session "${SESSION}"`);
await sleep(2200);
await click(await centreOf(ev, '#view-map'), 'the Map tab');
await sleep(3000);                                   // the map, then its layout

const seen = JSON.parse(await ev(`JSON.stringify({
  modules: document.querySelectorAll('#map .mp-mod').length,
  bands: document.querySelectorAll('#map .mp-band').length,
  errs: window.__errs ?? [],
})`));
if (seen.modules < 4) die(`the Map shows ${seen.modules} modules; the fixture's crew map was not read`);
if (seen.bands < 2) die(`the Map shows ${seen.bands} bands`);
if (seen.errs.length) die(`the page reported errors: ${JSON.stringify(seen.errs)}`);
const leaked = await leaks(ev, MACHINE);
if (leaked.length) die(`the picture shows something of this machine: ${leaked.join(', ')}`);

// A still has no pointer in it.
await ev(`(() => { for (const id of ['__cursor', '__ring']) document.getElementById(id)?.remove(); return 1; })()`);
await cdp.call('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 4, y: 4 });
await sleep(300);
const shot = await cdp.call('Page.captureScreenshot', { format: 'png' });
fs.writeFileSync(OUT, Buffer.from(shot.data, 'base64'));
console.log(`map: ${seen.modules} modules in ${seen.bands} bands -> ${OUT}`);
stage.close();
