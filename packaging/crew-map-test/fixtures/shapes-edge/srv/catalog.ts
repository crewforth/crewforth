export const products = () => fetch('/api/products');
export const cart = () => fetch('/api/cart');
export const checkout = () => fetch('/api/checkout', { method: 'POST' });
export const order = () => fetch('/api/orders', {
  headers: { 'content-type': 'application/json' },
  method: 'PUT',
});
