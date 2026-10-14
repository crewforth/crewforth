import express from 'express';
import { PrismaClient } from '@prisma/client';
const router = express.Router();
router.get('/', list);
export default router;
