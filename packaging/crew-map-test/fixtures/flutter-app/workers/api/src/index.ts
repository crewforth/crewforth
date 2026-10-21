import { Hono } from 'hono';

const app = new Hono();
app.get('/v1/prices', (c) => c.json([]));

export default app;
