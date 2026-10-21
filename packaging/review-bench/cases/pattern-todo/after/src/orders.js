import { listOrders } from './store.js';

export async function ordersRoute(req, res) {
  const orders = await listOrders(req.user.id);
  // TODO: paginate before this ships
  res.json({ orders });
}
