// What every take needs: a Chrome of our own, a way to act in the page, and a way to film it.
//
// Chrome is launched headless from a throwaway profile, at an exact viewport, so no banner, no other tab and no
// window chrome can reach a frame, and frames come back at the device scale that was asked for.
import fs from 'node:fs';
import { spawn } from 'node:child_process';
import { CDP, httpJson } from './cdp.mjs';
import { findChrome } from '../studio-test/chrome.mjs';

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const arg = (n, d) => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : d; };

/**
 * @returns { cdp, chrome, ev, die, close } — `ev(code)` evaluates in the page.
 */
export async function open({ name, port, profile, w, h, scale = 2, url, theme = 'dark' }) {
  const browser = findChrome(process.env.CHROME_PATH ?? null);
  if (!browser) { console.error(`${name}: no Chrome or Edge found — set CHROME_PATH`); process.exit(1); }
  fs.rmSync(profile, { recursive: true, force: true });
  const chrome = spawn(browser, [
    `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--headless=new',
    `--window-size=${w},${h}`, `--force-device-scale-factor=${scale}`, '--hide-scrollbars',
    '--no-first-run', '--no-default-browser-check', '--disable-extensions', 'about:blank',
  ], { stdio: 'ignore' });
  process.on('exit', () => { try { chrome.kill(); } catch { /* already exited */ } });
  const die = (m) => { console.error(`${name}:`, m); try { chrome.kill(); } catch { /* already exited */ } process.exit(1); };

  let targets = null;
  for (let i = 0; i < 60 && !targets; i += 1) { await sleep(250); try { targets = await httpJson(port, '/json/list'); } catch { /* not listening yet */ } }
  if (!targets) die('chrome never opened its debugging port');
  const cdp = await new CDP(targets.find((t) => t.type === 'page').webSocketDebuggerUrl).connect();
  await cdp.call('Page.enable');
  await cdp.call('Runtime.enable');
  await cdp.call('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: scale, mobile: false });
  await cdp.call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  // A page error during a take is a take that filmed something broken. They are collected and asked for at the end.
  await cdp.call('Page.addScriptToEvaluateOnNewDocument', {
    source: `window.__errs = []; addEventListener('error', (e) => __errs.push(String(e.message))); addEventListener('unhandledrejection', (e) => __errs.push('rejection: ' + String(e.reason)));`,
  });
  await cdp.call('Page.navigate', { url });
  await sleep(3200);
  const ev = (code) => cdp.eval(code);
  if (!await ev(`!!document.getElementById('canvas') && !!document.querySelector('.toolbar')`)) die(`the panel did not render — is the server up at ${url}?`);
  return { cdp, chrome, ev, die, close: () => { cdp.close(); chrome.kill(); } };
}

/** The first element matching `sel` whose text contains `needle`: its centre, or null. */
export const findByText = (ev, sel, needle) => ev(`
  (() => {
    const e = [...document.querySelectorAll(${JSON.stringify(sel)})]
      .find((x) => x.offsetParent !== null && (x.textContent || '').toLowerCase().includes(${JSON.stringify(String(needle).toLowerCase())}));
    if (!e) return null;
    const r = e.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`);

export const centreOf = (ev, sel) => ev(`
  (() => {
    const e = [...document.querySelectorAll(${JSON.stringify(sel)})].find((x) => x.offsetParent !== null);
    if (!e) return null;
    const r = e.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`);

/**
 * A cursor and a click ring. Headless has no cursor, and a film of things opening by themselves reads as a glitch
 * rather than as someone using the panel.
 */
export async function cursor({ cdp, ev }) {
  await ev(`
    (() => {
      const c = document.createElement('div');
      c.id = '__cursor';
      c.style.cssText = 'position:fixed;z-index:2147483647;width:22px;height:22px;pointer-events:none;'
        + 'transition:left .28s cubic-bezier(.4,0,.2,1),top .28s cubic-bezier(.4,0,.2,1);left:-40px;top:-40px;';
      c.innerHTML = '<svg viewBox="0 0 22 22" width="22" height="22">'
        + '<path d="M3 2 L3 17 L7.2 13.2 L9.8 19 L12.6 17.7 L10 12 L15.5 12 Z" fill="#fff" stroke="rgba(0,0,0,.55)" stroke-width="1.2"/></svg>';
      document.body.appendChild(c);
      const ring = document.createElement('div');
      ring.id = '__ring';
      ring.style.cssText = 'position:fixed;z-index:2147483646;width:34px;height:34px;border-radius:50%;'
        + 'pointer-events:none;border:2px solid rgba(120,180,255,.9);opacity:0;left:-60px;top:-60px;';
      document.body.appendChild(ring);
      window.__ping = (x, y) => {
        ring.style.left = (x - 17) + 'px'; ring.style.top = (y - 17) + 'px';
        ring.style.transition = 'none'; ring.style.opacity = '1'; ring.style.transform = 'scale(.5)';
        requestAnimationFrame(() => { ring.style.transition = 'opacity .5s, transform .5s'; ring.style.opacity = '0'; ring.style.transform = 'scale(1.6)'; });
      };
      return 1;
    })()`);
  const moveTo = async (x, y) => {
    await ev(`(() => { const c = document.getElementById('__cursor'); c.style.left = (${x} - 3) + 'px'; c.style.top = (${y} - 2) + 'px'; return 1; })()`);
    await cdp.call('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
  };
  const clickAt = async ({ x, y }) => {
    await moveTo(x, y);
    await sleep(340);
    await ev(`window.__ping(${x}, ${y}); 1`);
    await cdp.call('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 });
    await sleep(60);
    await cdp.call('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 });
  };
  return { moveTo, clickAt };
}

/** Film the page into `out` at `fps` until `stop()` is called. Returns { stop, count }. */
export function film({ cdp }, out, fps) {
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(out, { recursive: true });
  let frame = 0;
  let on = true;
  const done = (async () => {
    while (on) {
      const t = Date.now();
      const shot = await cdp.call('Page.captureScreenshot', { format: 'png', fromSurface: true, captureBeyondViewport: false });
      fs.writeFileSync(`${out}/f${String(frame).padStart(4, '0')}.png`, Buffer.from(shot.data, 'base64'));
      frame += 1;
      const wait = 1000 / fps - (Date.now() - t);
      if (wait > 0) await sleep(wait);
    }
  })();
  return { stop: async () => { on = false; await done; return frame; }, count: () => frame };
}

/**
 * What must not be in a frame: anything that names the machine the take was made on, or a person. Asked of the
 * page's text at the end of a take, so a recording that leaked is a recording that failed.
 * @param forbidden strings (the home directory, the user name, the host name)
 */
export async function leaks(ev, forbidden) {
  const text = await ev(`document.body.innerText + ' ' + [...document.querySelectorAll('[title]')].map((e) => e.title).join(' ')`);
  return wordsIn(text, forbidden);
}

/** Which of `words` are in `text` as words of their own: a host called "Mac" is not found in "Machines". */
export function wordsIn(text, words) {
  const escape = (w) => String(w).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return words.filter((w) => w && new RegExp(`(^|[^A-Za-z0-9])${escape(w)}([^A-Za-z0-9]|$)`, 'i').test(text));
}
