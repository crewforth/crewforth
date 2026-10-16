import { listOrders } from './store.js';

export async function ordersRoute(req, res) {
  const orders = await listOrders(req.user.id);
  res.json({ orders });
}
