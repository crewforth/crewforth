#!/usr/bin/env node
// Writes the crew-map documents Studio's Map view is built against, with Crewforth's own scanner.
//
// The document Studio reads is .crewforth/crew-map.json, written by kit/eval/lib/crew-map/scan.mjs. This script
// copies three of the scanner's own fixtures into a scratch directory the way its selfcheck does (`_env` becomes
// `.env`, the `{{PW}}` and `{{TOKEN}}` placeholders are filled), scans each, and writes <scratch>/out/<fixture>.json
// in the bytes the scanner writes to a project (findings.mjs `serialize`), printing each path. The values filled in
// are fixed, so the same scanner gives the same bytes: the document cites lines, and a line's hash would change with
// a random value.
//
// crew-map/<fixture>.json beside this file is its output, kept so the selfcheck reads what the scanner really
// writes. The selfcheck also runs this script and compares, byte for byte.
//
//   make-crew-map.mjs <repo root> <empty scratch directory>        rc 3: the scanner or its fixtures are not there
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// The three shapes the view has to draw: a workspace with findings shown and hidden (node-ws), a solution with
// what could not be measured (dotnet-sln), and containers with no finding at all (compose).
const SAMPLES = ['node-ws', 'dotnet-sln', 'compose'];
const FILL = { '{{PW}}': 'PwSample0000Z9', '{{TOKEN}}': `ghp_${'0'.repeat(36)}` };

const [repo, work] = process.argv.slice(2);
if (!repo || !work) { console.error('usage: make-crew-map.mjs <repo root> <empty scratch directory>'); process.exit(2); }
const scanJs = path.join(repo, 'kit', 'eval', 'lib', 'crew-map', 'scan.mjs');
const findingsJs = path.join(repo, 'kit', 'eval', 'lib', 'findings', 'findings.mjs');
const fixtures = path.join(repo, 'packaging', 'crew-map-test', 'fixtures');
if (!fs.existsSync(scanJs) || !fs.existsSync(findingsJs) || !SAMPLES.every((s) => fs.existsSync(path.join(fixtures, s)))) {
  console.error(`no crew-map scanner or fixtures under ${repo}`);
  process.exit(3);
}
const { scan } = await import(pathToFileURL(scanJs).href);
const { serialize } = await import(pathToFileURL(findingsJs).href);

function stage(name) {
  const root = path.join(work, 'in', name);
  fs.cpSync(path.join(fixtures, name), root, { recursive: true });
  fs.rmSync(path.join(root, 'expected.json'), { force: true });
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { walk(p); continue; }
      let t = fs.readFileSync(p, 'utf8');
      for (const [k, v] of Object.entries(FILL)) t = t.replaceAll(k, v);
      fs.writeFileSync(p, t);
      if (e.name.startsWith('_env')) fs.renameSync(p, path.join(d, `.env${e.name.slice(4)}`));
    }
  };
  walk(root);
  return root;
}

const outDir = path.join(work, 'out');
fs.mkdirSync(outDir, { recursive: true });
for (const name of SAMPLES) {
  const { doc, report } = scan(stage(name));
  if (!report.ok) { console.error(`${name}: the scanner's document does not verify`); process.exit(1); }
  const file = path.join(outDir, `${name}.json`);
  fs.writeFileSync(file, serialize(doc));
  console.log(file);
}
