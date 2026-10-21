import { listOrders } from './store.js';

export async function ordersRoute(req, res) {
  const orders = await listOrders(req.user.id);
  if (!orders) { console.error('orders lookup failed'); return res.status(502).json({ error: 'TODO list unavailable' }); }
  res.json({ orders });
}
