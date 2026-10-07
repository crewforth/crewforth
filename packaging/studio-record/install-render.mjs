// The install scene's terminal lines, drawn the way the overview video's page draws them, twice: as the video has
// them, and as they should read. install_scene.py puts the difference between the two into the video.
//
//   node install-render.mjs --out DIR --was "3.0.0,39" --now "3.1.0,40"
//
// The page is the video's own layout (its source is not in the repository; the numbers below are that page's
// CSS). The font is the repository's JetBrains Mono subset, the face the video's terminal is set in. The two
// signs at the start of the lines are not in the subset; they are not redrawn, and a blank of one character's
// width stands where they are so that every other character keeps its place.
// Font smoothing is "antialiased": measured against the video's own digits, that drawing is 29 dB from them and
// the browser's default, which draws heavier strokes, 25 dB.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { CDP, httpJson } from './cdp.mjs';
import { findChrome } from '../studio-test/chrome.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : d; };
const OUT = arg('out');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const font = fs.readFileSync(path.join(HERE, '..', 'diagram-fonts', 'JetBrainsMono-Regular.subset.ttf')).toString('base64');

const page = (version, skills) => `<!doctype html><meta charset="utf-8"><style>
@font-face{font-family:"JB";src:url(data:font/ttf;base64,${font}) format("truetype");font-weight:400}
html,body{margin:0;background:#0B1020}
#stage{position:relative;width:1920px;height:1080px;overflow:hidden;background:#0B1020;color:#e6e9f0}
.term{position:absolute;left:380px;top:152px;width:1160px;height:600px;background:#11141b;border:1.5px solid #2a3040;border-radius:18px;overflow:hidden;font-family:JB,monospace;font-size:23px;line-height:1.45;-webkit-font-smoothing:antialiased}
.tbar{height:48px;background:#1a1e28;border-bottom:1.5px solid #2a3040}
.tb{padding:26px 34px}
.sign{display:inline-block;width:1ch}
</style><div id="stage"><div class="term"><div class="tbar"></div><div class="tb">
<div>&nbsp;</div>
<div style="margin-top:4px"><span class="sign"></span> Crewforth <span id="v">${version}</span></div>
<div style="margin-top:4px"><span class="sign"></span> 12 agents  <span class="sign"></span> <span id="s">${skills}</span> skills</div>
</div></div></div>`;

const chromePath = findChrome(arg('chrome', process.env.CHROME_PATH ?? null));
if (!chromePath) { console.error('install-render: no Chrome or Edge found — pass --chrome PATH'); process.exit(2); }
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-install-'));
const port = 9700 + Math.floor(Math.random() * 90);
const chrome = spawn(chromePath, [`--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--headless=new', '--window-size=1920,1080', '--hide-scrollbars', '--no-first-run', '--disable-extensions', 'about:blank'], { stdio: 'ignore' });
process.on('exit', () => { try { chrome.kill(); } catch { /* gone */ } });
let targets = null;
for (let i = 0; i < 60 && !targets; i += 1) { await sleep(250); try { targets = await httpJson(port, '/json/list'); } catch { /* not up */ } }
const cdp = await new CDP(targets.find((t) => t.type === 'page').webSocketDebuggerUrl).connect();
await cdp.call('Page.enable'); await cdp.call('Runtime.enable');
await cdp.call('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });

fs.mkdirSync(OUT, { recursive: true });
const rects = {};
for (const [name, text] of [['was', arg('was')], ['now', arg('now')]]) {
  const [version, skills] = text.split(',');
  const file = path.join(OUT, `${name}.html`);
  fs.writeFileSync(file, page(version, skills));
  await cdp.call('Page.navigate', { url: `file://${file}` });
  await sleep(700);
  await cdp.eval(`document.fonts.ready.then(() => 1)`);
  // Each number, and each of its characters: where the browser put it.
  rects[name] = JSON.parse(await cdp.eval(`JSON.stringify(Object.fromEntries(['v', 's'].map((id) => {
    const el = document.getElementById(id); const text = el.firstChild; const r = el.getBoundingClientRect();
    const cells = [...text.data].map((_, i) => { const range = document.createRange(); range.setStart(text, i); range.setEnd(text, i + 1); const c = range.getBoundingClientRect(); return [c.left, c.top, c.width, c.height]; });
    return [id, { text: text.data, box: [r.left, r.top, r.width, r.height], cells }];
  })))`));
  const shot = await cdp.call('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width: 1920, height: 1080, scale: 1 } });
  fs.writeFileSync(path.join(OUT, `${name}.png`), Buffer.from(shot.data, 'base64'));
}
fs.writeFileSync(path.join(OUT, 'rects.json'), JSON.stringify(rects));
console.log('install-render:', JSON.stringify(rects));
cdp.close(); chrome.kill();
