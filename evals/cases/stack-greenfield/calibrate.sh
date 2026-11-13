# good: the stack is decided and written to docs/STACK.md first, then a Node/Fastify endpoint is built after it.
# bad: the model picks a stack silently and writes package.json and server code with no record of the decision.
good() {
  mkdir -p docs src
  printf '# Stack\n\nRuntime: Node.js 22\nWeb framework: Fastify\nStorage: SQLite\n' > docs/STACK.md
  touch -t 202001010000 docs/STACK.md
  printf '{ "name": "orders", "type": "module", "dependencies": { "fastify": "^5.0.0" } }\n' > package.json
  cat > src/server.js <<'JS'
import Fastify from 'fastify';

const orders = [];
export function build() {
  const app = Fastify();
  app.post('/orders', async (req) => { orders.push(req.body); return { id: orders.length }; });
  return app;
}
JS
}
bad() {
  mkdir -p src
  printf '{ "name": "orders", "type": "module", "dependencies": { "express": "^4.19.0" } }\n' > package.json
  cat > src/server.js <<'JS'
import express from 'express';

const app = express();
const orders = [];
app.use(express.json());
app.post('/orders', (req, res) => { orders.push(req.body); res.json({ id: orders.length }); });
app.listen(3000);
JS
}
