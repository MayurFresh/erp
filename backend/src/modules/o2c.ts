import type { FastifyInstance } from 'fastify';
import type { AppDeps } from '../app.ts';
import { fulfilmentRoutes } from './fulfilment.ts';
import { salesOrderRoutes } from './sales-orders.ts';
import { salesReturnRoutes } from './sales-returns.ts';
import { shipmentRoutes } from './shipments.ts';

/** Order to cash: sales orders, pick/pack/dispatch, shipments and returns. */
export async function o2cRoutes(app: FastifyInstance, _deps?: AppDeps) {
  await salesOrderRoutes(app);
  await fulfilmentRoutes(app);
  await shipmentRoutes(app);
  await salesReturnRoutes(app);
}
