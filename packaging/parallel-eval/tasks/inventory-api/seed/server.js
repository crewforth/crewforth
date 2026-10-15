// A small inventory HTTP API, in memory. createServer() returns a node:http server; start it with .listen().
import http from 'node:http';

export function createServer() {
  const items = new Map();
  let next = 1;
  const send = (res, code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
  const readBody = (req) => new Promise((resolve) => { let b = ''; req.on('data', (c) => { b += c; }); req.on('end', () => resolve(b)); });

  return http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x');
    if (req.method === 'GET' && url.pathname === '/items') return send(res, 200, [...items.values()]);
    if (req.method === 'POST' && url.pathname === '/items') {
      const body = JSON.parse(await readBody(req) || '{}');
      const item = { id: next++, name: body.name, qty: body.qty };
      items.set(item.id, item);
      return send(res, 201, item);
    }
    return send(res, 404, { error: 'not found' });
  });
}
