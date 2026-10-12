// Where a Chrome or an Edge is, for the measurements that need a real browser. One list, so a tool that finds
// the browser on one platform does not miss it on another.
import fs from 'node:fs';

const USUAL = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
];

/** The browser to launch: the one given (`--chrome PATH` or CHROME_PATH), or the first of the usual places. */
export function findChrome(given = null) {
  return (given ? [given] : USUAL).find((c) => fs.existsSync(c)) ?? null;
}
