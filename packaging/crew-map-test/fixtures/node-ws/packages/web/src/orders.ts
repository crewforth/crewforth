import Link from 'next/link';
import { api } from './client';

// The client is made in client.ts and called here: these are calls, not routes.
export const orders = () => api.get<Order[]>(
  '/api/orders',
);
export const touch = () => api.patch('/api/orders/7', {});
