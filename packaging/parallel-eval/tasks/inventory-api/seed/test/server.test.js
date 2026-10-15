import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from '../server.js';

const server = createServer().listen(0);
const base = `http://127.0.0.1:${server.address().port}`;
after(() => server.close());

test('POST then GET returns the item', async () => {
  const r = await fetch(`${base}/items`, { method: 'POST', body: JSON.stringify({ name: 'bolt', qty: 3 }) });
  assert.equal(r.status, 201);
  const all = await (await fetch(`${base}/items`)).json();
  assert.deepEqual(all.map((i) => i.name), ['bolt']);
});
