// Self-test for worker.js with an in-memory KV: what it counts, what it refuses, and that it reads no header but
// Authorization (and that only on /count). Run: node packaging/install-ping-worker/selftest.mjs  (exit 0 = all pass)
import worker from './worker.js';

const store = new Map();
const env = {
  READ_KEY: 'k-test',
  COUNTS: {
    get: async (k) => (store.has(k) ? store.get(k) : null),
    put: async (k, v) => { store.set(k, v); },
    list: async () => ({ keys: [...store.keys()].map((name) => ({ name })), list_complete: true }),
  },
};
const read = [];
function req(path, headers = {}) {
  const r = new Request(`https://example.test${path}`, { headers: { 'cf-connecting-ip': '203.0.113.7', 'x-forwarded-for': '203.0.113.7', ...headers } });
  const get = r.headers.get.bind(r.headers);
  r.headers.get = (n) => { read.push(n.toLowerCase()); return get(n); };
  return r;
}
const results = [];
const check = (name, ok, detail = '') => results.push({ name, ok, detail });
const day = new Date().toISOString().slice(0, 10);

let res = await worker.fetch(req('/install?v=3.3.0'), env);
check('an install is answered 204', res.status === 204, String(res.status));
await worker.fetch(req('/install?v=3.3.0'), env);
check('two installs count two, under the day and the version', store.get(`${day}|3.3.0`) === '2', JSON.stringify([...store]));
for (const bad of ['', 'abc', '3.3', '3.3.0;rm', '/etc/passwd', '1.2.3-' + 'x'.repeat(40)]) {
  res = await worker.fetch(req(`/install?v=${encodeURIComponent(bad)}`), env);
  check(`a version that is not one is refused (${bad.slice(0, 12) || 'empty'})`, res.status === 400, String(res.status));
}
check('nothing but the counted keys is stored', store.size === 1, JSON.stringify([...store]));
check('/install reads no header', read.length === 0, read.join(','));
res = await worker.fetch(req('/count'), env);
check('/count without the key is a 404', res.status === 404, String(res.status));
res = await worker.fetch(req('/count', { authorization: 'Bearer wrong' }), env);
check('/count with a wrong key is a 404', res.status === 404, String(res.status));
res = await worker.fetch(req('/count', { authorization: 'Bearer k-test' }), env);
const body = res.status === 200 ? await res.json() : null;
check('/count with the key returns the counts', body && body[`${day}|3.3.0`] === 2, JSON.stringify(body));
check('the only header ever read is authorization', read.every((n) => n === 'authorization'), read.join(','));
res = await worker.fetch(req('/anything'), env);
check('any other path is a 404', res.status === 404, String(res.status));

for (const r of results) console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.ok ? '' : ' — ' + r.detail}`);
const failed = results.filter((r) => !r.ok).length;
console.log(`install-ping worker selftest: ${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
