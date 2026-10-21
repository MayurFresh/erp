import Fastify, { type FastifyError, type FastifyInstance } from 'fastify';
import cors from '@fastify/cors';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
import type { Config } from './config.ts';
import type { Db } from './db/database.ts';
import { withTenant } from './db/database.ts';
import { RequestContext, loadMemberships, type Membership } from './auth/context.ts';
import { createTokenService, type TokenService } from './auth/tokens.ts';
import { AppError, forbidden, unauthorized } from './lib/errors.ts';
import { authRoutes, meRoutes } from './modules/auth.ts';
import { locationRoutes } from './modules/locations.ts';
import { itemRoutes } from './modules/items.ts';
import { partyRoutes } from './modules/parties.ts';
import { stockRoutes } from './modules/stock.ts';
import { invoiceRoutes } from './modules/invoices.ts';
import { dashboardRoutes } from './modules/dashboard.ts';
import { userRoutes } from './modules/users.ts';
import { auditRoutes } from './modules/audit.ts';
import { companyRoutes } from './modules/company.ts';
import { purchaseRoutes } from './modules/purchases.ts';
import { paymentRoutes } from './modules/payments.ts';
import { creditNoteRoutes } from './modules/credit-notes.ts';
import { transferRoutes } from './modules/transfers.ts';
import { expenseRoutes } from './modules/expenses.ts';
import { accountRoutes } from './modules/accounts.ts';
import { reportRoutes } from './modules/reports.ts';
import { userAdminRoutes } from './modules/users-admin.ts';

declare module 'fastify' {
  interface FastifyRequest {
    ctx: RequestContext;
  }
}

export interface AppDeps {
  db: Db;
  tokens: TokenService;
}

export interface BuildOptions {
  config: Config;
  db: Db;
  logger?: boolean;
  /** Max auth requests per IP per minute; false disables (tests). */
  authRateLimit?: number | false;
}

const NO_COMPANY: Membership = { companyId: '', roles: [], permissions: new Set(), locationIds: [] };

export async function buildApp(opts: BuildOptions): Promise<FastifyInstance> {
  const { config, db } = opts;
  const app = Fastify({
    logger: opts.logger === false ? false : { level: config.LOG_LEVEL },
    trustProxy: true,
    bodyLimit: 1_048_576,
  });
  const tokens = createTokenService({
    secret: config.JWT_SECRET,
    accessTtlSeconds: config.ACCESS_TOKEN_TTL_SECONDS,
    refreshTtlDays: config.REFRESH_TOKEN_TTL_DAYS,
  });
  const deps: AppDeps = { db, tokens };

  await app.register(helmet, { contentSecurityPolicy: false });
  const origins = config.CORS_ORIGINS.trim();
  await app.register(cors, {
    origin: origins === '*' ? true : origins.split(',').map((o) => o.trim()),
    allowedHeaders: ['Authorization', 'Content-Type', 'X-Company-Id'],
    methods: ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS'],
  });
  await app.register(rateLimit, { global: false });

  app.setErrorHandler((err: FastifyError & { code?: string }, req, reply) => {
    if (err instanceof AppError) {
      return reply.status(err.statusCode).send({ error: { code: err.code, message: err.message, details: err.details } });
    }
    // PostgreSQL errors that reach here are mapped to friendly responses.
    if (err.code === '23505') {
      return reply.status(409).send({ error: { code: 'CONFLICT', message: 'A record with these details already exists.' } });
    }
    if (err.code === '22P02' || err.code === '23503') {
      return reply.status(400).send({ error: { code: 'VALIDATION_ERROR', message: 'A referenced record is invalid.' } });
    }
    if (err.statusCode === 429) {
      return reply.status(429).send({ error: { code: 'RATE_LIMITED', message: 'Too many attempts. Try again in a minute.' } });
    }
    if (err.statusCode && err.statusCode < 500) {
      return reply.status(err.statusCode).send({ error: { code: 'VALIDATION_ERROR', message: err.message } });
    }
    req.log.error(err);
    return reply.status(500).send({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong. Please try again.' } });
  });

  app.setNotFoundHandler((_req, reply) =>
    reply.status(404).send({ error: { code: 'NOT_FOUND', message: 'Endpoint not found.' } }),
  );

  app.get('/health', async () => ({ status: 'ok', time: new Date().toISOString() }));

  await app.register(
    async (api) => {
      await api.register(async (open) => authRoutes(open, deps, opts.authRateLimit ?? 20));

      await api.register(async (secured) => {
        secured.decorateRequest('ctx', null as unknown as RequestContext);
        secured.addHook('onRequest', async (req) => {
          const header = req.headers.authorization;
          if (!header?.startsWith('Bearer ')) throw unauthorized('Please sign in.');
          const claims = await tokens.verifyAccess(header.slice(7));
          const { name, memberships } = await withTenant(db, claims.tenantId, (tx) => loadMemberships(tx, claims.userId));
          const wanted = req.headers['x-company-id'];
          let company = memberships[0] ?? NO_COMPANY;
          if (typeof wanted === 'string' && wanted.length > 0) {
            const match = memberships.find((m) => m.companyId === wanted);
            if (!match) throw forbidden('You do not have access to this company.');
            company = match;
          }
          req.ctx = new RequestContext(db, claims.tenantId, claims.userId, name, memberships, company);
        });

        await meRoutes(secured);
        await locationRoutes(secured);
        await itemRoutes(secured);
        await partyRoutes(secured);
        await stockRoutes(secured);
        await invoiceRoutes(secured);
        await dashboardRoutes(secured);
        await userRoutes(secured);
        await auditRoutes(secured);
        await companyRoutes(secured);
        await purchaseRoutes(secured);
        await paymentRoutes(secured);
        await creditNoteRoutes(secured);
        await transferRoutes(secured);
        await expenseRoutes(secured);
        await accountRoutes(secured);
        await reportRoutes(secured);
        await userAdminRoutes(secured);
      });
    },
    { prefix: '/api/v1' },
  );

  return app;
}
