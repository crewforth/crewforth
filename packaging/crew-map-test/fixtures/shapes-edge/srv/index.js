import express from 'express';
import users from './users.js';
const app = express();
app.use('/api/users', users);
app.get('/api/ping', ping);
const dev = import.meta.env.DEV;
