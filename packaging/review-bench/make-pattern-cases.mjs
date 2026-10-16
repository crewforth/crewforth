#!/usr/bin/env node
// make-pattern-cases.mjs — the cases a pattern can see, written here rather than taken from history: a secret
// pasted into config, a console call left in a handler, a lock file regenerated alone, a TODO left in code, and a
// change that only looks like them. They are what the deterministic pre-pass is for, so its gate is measured on
// them; the review agent meets them too. A secret is never stored: {{TOKEN}} is filled when the case is built.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const handler = (extra) => `import { listOrders } from './store.js';

export async function ordersRoute(req, res) {
  const orders = await listOrders(req.user.id);
${extra}  res.json({ orders });
}
`;
const cases = [
  { id: 'pattern-secret', kind: 'defect', intent: 'Configure the deploy client for the release job.',
    before: { 'src/deploy.ts': "export const deployTarget = 'production';\n" },
    after: { 'src/deploy.ts': "export const deployTarget = 'production';\nexport const deployToken = '{{TOKEN}}';\n" },
    expect: [{ file: 'src/deploy.ts', from: 2, to: 2 }] },
  { id: 'pattern-debug-call', kind: 'defect', intent: 'Return the orders list from the orders route.',
    before: { 'src/orders.js': handler('') },
    after: { 'src/orders.js': handler('  console.log(orders);\n') },
    expect: [{ file: 'src/orders.js', from: 5, to: 5 }] },
  { id: 'pattern-lockfile', kind: 'defect', intent: 'Refresh the dependency lock.',
    before: { 'package.json': '{\n  "name": "shop",\n  "dependencies": { "left-pad": "^1.3.0" }\n}\n', 'package-lock.json': '{\n  "name": "shop",\n  "lockfileVersion": 3,\n  "packages": { "node_modules/left-pad": { "version": "1.3.0" } }\n}\n' },
    after: { 'package.json': '{\n  "name": "shop",\n  "dependencies": { "left-pad": "^1.3.0" }\n}\n', 'package-lock.json': '{\n  "name": "shop",\n  "lockfileVersion": 3,\n  "packages": { "node_modules/left-pad": { "version": "2.0.0" } }\n}\n' },
    expect: [{ file: 'package-lock.json', from: 4, to: 4 }] },
  { id: 'pattern-todo', kind: 'defect', intent: 'Paginate the orders route.',
    before: { 'src/orders.js': handler('') },
    after: { 'src/orders.js': handler('  // TODO: paginate before this ships\n') },
    expect: [{ file: 'src/orders.js', from: 5, to: 5 }] },
  { id: 'pattern-clean', kind: 'clean', intent: 'Report a failed orders lookup.', holdout: true,
    before: { 'src/orders.js': handler('') },
    after: { 'src/orders.js': handler("  if (!orders) { console.error('orders lookup failed'); return res.status(502).json({ error: 'TODO list unavailable' }); }\n") },
    expect: [] },
];
for (const c of cases) {
  const dir = path.join(HERE, 'cases', c.id);
  fs.rmSync(dir, { recursive: true, force: true });
  const modes = { before: {}, after: {} };
  for (const side of ['before', 'after']) for (const [f, t] of Object.entries(c[side])) {
    const out = path.join(dir, side, f); fs.mkdirSync(path.dirname(out), { recursive: true }); fs.writeFileSync(out, t); modes[side][f] = '100644';
  }
  fs.writeFileSync(path.join(dir, 'case.json'), JSON.stringify({ id: c.id, kind: c.kind, stratum: 'pattern', holdout: !!c.holdout, source: 'synthetic', intent: c.intent, modes, expect: c.expect }, null, 2) + '\n');
  console.log(`${c.id}: ${c.kind} · pattern`);
}
