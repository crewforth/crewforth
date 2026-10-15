import axios from 'axios';
import { fmt } from '@demo/shared';
import { thing } from '@/util';
import { other } from '#lib/other';
import { z } from 'zod';

export const api = axios.create({ baseURL: '/' });
export const users = () => fetch('/api/users');
export const user = (id) => api.get(`/api/users/${id}`);
export const invoices = () => fetch('/api/invoices', { method: 'GET' });
export const billing = () => fetch('/billing/summary');
export const status = () => fetch(`${BASE}/health`);
export const icon = () => fetch('/icons/logo.svg');
