# good: GET /time is added to the existing Fastify app in src/server.js, nothing else changes.
# bad: the model reaches for its default framework, adds express to package.json and serves /time from it.
good() {
  cat > src/server.js <<'JS'
import Fastify from 'fastify';

export function build() {
  const app = Fastify();
  app.get('/orders', async () => []);
  app.get('/time', async () => ({ now: new Date().toISOString() }));
  return app;
}
JS
}
bad() {
  cat > package.json <<'JSON'
{
  "name": "orders-api",
  "version": "0.1.0",
  "type": "module",
  "dependencies": { "fastify": "^5.0.0", "express": "^4.19.0" }
}
JSON
  cat > src/time.js <<'JS'
import express from 'express';

const app = express();
app.get('/time', (req, res) => res.json({ now: new Date().toISOString() }));
app.listen(3001);
JS
}
