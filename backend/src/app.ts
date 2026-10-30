import Fastify, { type FastifyError, type FastifyInstance } from 'fastify';
import cors from '@fastify/cors';
import helmet from '@fastify/helmet';
import multipart from '@fastify/multipart';
import rateLimit from '@fastify/rate-limit';
import type { Config } from './config.ts';
import type { Db } from './db/database.ts';
import { withTenant } from './db/database.ts';
import { RequestContext, loadMemberships, type Membership } from './auth/context.ts';
import { createTokenService, type TokenService } from './auth/tokens.ts';
import { AppError, notFound, sessionRevoked, unauthorized } from './lib/errors.ts';
import { registerIdempotency } from './lib/idempotency.ts';
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
import { projectRoutes } from './modules/projects.ts';
import { indentRoutes } from './modules/indents.ts';
import { issueRoutes } from './modules/issues.ts';
import { dprRoutes } from './modules/dprs.ts';
import { fileRoutes } from './modules/files.ts';
import { labourRoutes } from './modules/labour.ts';
import { labourAdvanceRoutes } from './modules/labour-advances.ts';
import { workOrderRoutes } from './modules/work-orders.ts';
import { raBillRoutes } from './modules/ra-bills.ts';
import { unitRoutes } from './modules/units.ts';
import { bookingRoutes } from './modules/bookings.ts';
import { einvoiceRoutes } from './modules/einvoice.ts';
import { taxMasterRoutes } from './modules/tax-masters.ts';
import { gstReturnRoutes } from './modules/gst-returns.ts';
import { tdsRoutes } from './modules/tds.ts';
import { bankRoutes } from './modules/bank.ts';
import { complianceRoutes } from './modules/compliance.ts';
import { filingRoutes } from './modules/filings.ts';
import { gstFilingRoutes } from './modules/gst-filing.ts';
import { incomeTaxRoutes } from './modules/income-tax.ts';
import { fixedAssetRoutes } from './modules/fixed-assets.ts';
import { exportRoutes } from './modules/export.ts';

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
  /** Called for every registered route (used by the route fuzz test). */
  onRoute?: (route: { method: string; url: string }) => void;
}

const NO_COMPANY: Membership = { companyId: '', roles: [], permissions: new Set(), locationIds: [] };

export async function buildApp(opts: BuildOptions): Promise<FastifyInstance> {
  const { config, db } = opts;
  const app = Fastify({
    logger: opts.logger === false ? false : { level: config.LOG_LEVEL },
    trustProxy: true,
    bodyLimit: 1_048_576,
  });
  if (opts.onRoute) {
    const report = opts.onRoute;
    app.addHook('onRoute', (r) => {
      for (const m of Array.isArray(r.method) ? r.method : [r.method]) if (m !== 'HEAD' && m !== 'OPTIONS') report({ method: m, url: r.url });
    });
  }
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
    allowedHeaders: ['Authorization', 'Content-Type', 'X-Company-Id', 'Idempotency-Key'],
    exposedHeaders: ['Idempotent-Replayed'],
    methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
  });
  await app.register(rateLimit, { global: false });
  await app.register(multipart, { limits: { fileSize: 10 * 1024 * 1024, files: 1 } });

  app.setErrorHandler((err: FastifyError & { code?: string }, req, reply) => {
    if (err instanceof AppError) {
      return reply.status(err.statusCode).send({ error: { code: err.code, message: err.message, details: err.details } });
    }
    // PostgreSQL errors that reach here are mapped to friendly responses.
    const send = (status: number, code: string, message: string) =>
      reply.status(status).send({ error: { code, message } });
    const pg = err.code ?? '';
    if (pg === '23505') return send(409, 'CONFLICT', 'A record with these details already exists.');
    if (pg === '23503') {
      const changing = ['DELETE', 'PATCH', 'PUT'].includes(req.method) ||
        (req.method === 'POST' && /\/(cancel|void|deactivate|reverse|delete|remove|unlink|unapply|archive|reject)/.test(req.url));
      if (changing) {
        return send(409, 'IN_USE', "This record is used by other documents, so it can't be deleted. Deactivate it instead.");
      }
      return send(400, 'VALIDATION_ERROR', 'A referenced record is invalid.');
    }
    if (pg === '40001' || pg === '40P01') return send(409, 'TRY_AGAIN', 'The system is busy. Please try again.');
    if (/^22/.test(pg) || pg === '23502' || pg === '23514') {
      const msg: Record<string, string> = {
        '22001': 'A value is too long.', '22003': 'A number is out of range.',
        '22007': 'A date is invalid.', '22008': 'A date is invalid.', '23502': 'A required value is missing.',
        '23514': 'A value is not allowed.',
      };
      return send(400, 'VALIDATION_ERROR', msg[pg] ?? 'A value is invalid.');
    }
    if (err.statusCode === 413 || pg === 'FST_ERR_CTP_BODY_TOO_LARGE' || pg === 'FST_REQ_FILE_TOO_LARGE') {
      return send(413, 'PAYLOAD_TOO_LARGE', 'The request is too large.');
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

  // A path id that is not a UUID can never exist.
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  app.addHook('preValidation', async (req) => {
    const params = req.params as Record<string, string> | undefined;
    if (!params) return;
    for (const [k, v] of Object.entries(params)) {
      if ((k === 'id' || k.endsWith('Id')) && !UUID.test(String(v))) throw notFound();
    }
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
            if (!match) throw sessionRevoked('You no longer have access to this company.');
            company = match;
          }
          req.ctx = new RequestContext(db, claims.tenantId, claims.userId, name, memberships, company);
        });

        registerIdempotency(secured);
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
        await projectRoutes(secured);
        await indentRoutes(secured);
        await issueRoutes(secured);
        await dprRoutes(secured);
        await fileRoutes(secured, config.UPLOAD_DIR);
        await labourRoutes(secured);
        await labourAdvanceRoutes(secured);
        await workOrderRoutes(secured);
        await raBillRoutes(secured);
        await unitRoutes(secured);
        await bookingRoutes(secured);
        await einvoiceRoutes(secured);
        await taxMasterRoutes(secured);
        await gstReturnRoutes(secured);
        await tdsRoutes(secured);
        await bankRoutes(secured);
        await complianceRoutes(secured);
        await filingRoutes(secured);
        await gstFilingRoutes(secured);
        await incomeTaxRoutes(secured);
        await fixedAssetRoutes(secured);
        await exportRoutes(secured);
      });
    },
    { prefix: '/api/v1' },
  );

  return app;
}
