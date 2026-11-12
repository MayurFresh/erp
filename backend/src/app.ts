import Fastify, { type FastifyError, type FastifyInstance, type FastifyRequest as Request } from 'fastify';
import cors from '@fastify/cors';
import helmet from '@fastify/helmet';
import multipart from '@fastify/multipart';
import rateLimit from '@fastify/rate-limit';
import { sql } from 'kysely';
import { webhookAllowPrivate, type Config } from './config.ts';
import type { Db } from './db/database.ts';
import { withTenant } from './db/database.ts';
import { RequestContext, loadMemberships, type Membership } from './auth/context.ts';
import { createTokenService, type TokenService } from './auth/tokens.ts';
import { AppError, notFound, sessionRevoked, unauthorized } from './lib/errors.ts';
import { registerIdempotency } from './lib/idempotency.ts';
import { authRoutes, meRoutes } from './modules/auth.ts';
import { platformAdminRoutes } from './modules/platform-admin.ts';
import { assertTenantActive } from './lib/tenant-status.ts';
import { locationRoutes } from './modules/locations.ts';
import { itemRoutes } from './modules/items.ts';
import { partyRoutes } from './modules/parties.ts';
import { stockRoutes } from './modules/stock.ts';
import { invoiceRoutes } from './modules/invoices.ts';
import { analyticsRoutes } from './modules/analytics.ts';
import { dashboardRoutes } from './modules/dashboard.ts';
import { userRoutes } from './modules/users.ts';
import { auditRoutes } from './modules/audit.ts';
import { companyRoutes } from './modules/company.ts';
import { goodsReceiptRoutes } from './modules/goods-receipts.ts';
import { purchaseOrderRoutes } from './modules/purchase-orders.ts';
import { purchaseRoutes } from './modules/purchases.ts';
import { reorderRoutes } from './modules/reorder.ts';
import { stockCountRoutes } from './modules/stock-counts.ts';
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
import { posRoutes } from './modules/pos.ts';
import { bookingRoutes } from './modules/bookings.ts';
import { clinicRoutes } from './modules/clinic.ts';
import { clinicIpdRoutes } from './modules/clinic-ipd.ts';
import { fundRoutes } from './modules/funds.ts';
import { hrRoutes } from './modules/hr.ts';
import { payrollRoutes } from './modules/payroll.ts';
import { donationRoutes } from './modules/donations.ts';
import { hotelRoutes } from './modules/hotel.ts';
import { educationRoutes } from './modules/education.ts';
import { legalRoutes } from './modules/legal.ts';
import { membershipRoutes } from './modules/memberships.ts';
import { jobCardRoutes } from './modules/job-cards.ts';
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
import { warehouseRoutes } from './modules/warehouse.ts';
import { channelRoutes } from './modules/channels.ts';
import { channelWebhookRoutes } from './modules/channels-live.ts';
import { setChannelHostPolicy } from './lib/channels/http.ts';
import { tallyRoutes } from './modules/tally.ts';
import { securityRoutes } from './modules/security.ts';
import { jobRoutes } from './modules/jobs.ts';
import { notificationRoutes } from './modules/notifications.ts';
import { companiesRoutes } from './modules/companies.ts';
import { intercompanyRoutes } from './modules/intercompany.ts';
import { gspRoutes } from './modules/gsp.ts';
import { approvalRoutes } from './modules/approvals.ts';
import { customFieldRoutes } from './modules/custom-fields.ts';
import { costCentreRoutes } from './modules/cost-centres.ts';
import { importRoutes } from './modules/imports.ts';
import { o2cRoutes } from './modules/o2c.ts';
import { manufacturingRoutes } from './modules/manufacturing.ts';
import { restaurantRoutes } from './modules/restaurant.ts';
import { businessCatalogueRoutes, businessRoutes } from './modules/business.ts';
import { configureDataKey } from './lib/crypto.ts';
import { integrationRoutes } from './modules/integrations.ts';
import { collectRoutes, registerOpenApi } from './lib/openapi.ts';
import { setupTelemetry } from './lib/telemetry.ts';
import { registerEntitlements } from './lib/entitlements.ts';
import { contextForApiKey, isApiKey } from './lib/api-keys.ts';

declare module 'fastify' {
  interface FastifyRequest {
    ctx: RequestContext;
    /** Session id and sign-in method from the access token; mustEnrol2fa when a company requires 2FA and the user has none. */
    authInfo: { sid?: string; amr?: 'pwd' | 'mfa' | 'sso' | 'key'; mustEnrol2fa: boolean };
  }
}

// Endpoints a user who must still set up 2FA may call (v1.7 §1).
const ENROL_EXEMPT = [/^\/me$/, /^\/me\/security$/, /^\/me\/2fa(\/|$)/, /^\/me\/password$/, /^\/me\/sessions(\/|$)/, /^\/notifications\/unread-count$/];

export interface AppDeps {
  db: Db;
  tokens: TokenService;
  config: Config;
}

export interface BuildOptions {
  config: Config;
  db: Db;
  logger?: boolean;
  /** Max auth requests per IP per minute; false turns off every rate limit (tests). */
  authRateLimit?: number | false;
  /** Called for every registered route (used by the route fuzz test). */
  onRoute?: (route: { method: string; url: string }) => void;
}

const NO_COMPANY: Membership = { companyId: '', roles: [], permissions: new Set(), locationIds: [] };

export async function buildApp(opts: BuildOptions): Promise<FastifyInstance> {
  const { config, db } = opts;
  const hops = config.TRUST_PROXY;
  const app = Fastify({
    logger: opts.logger === false ? false : { level: config.LOG_LEVEL },
    // A hop count trusts that many proxies nearest the server.
    trustProxy: typeof hops === 'number' ? (_addr: string, hop: number) => hop < hops : hops,
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
  const deps: AppDeps = { db, tokens, config };
  const routeLog = collectRoutes(app);
  await setupTelemetry(app, config);
  setChannelHostPolicy(webhookAllowPrivate(config));
  if (configureDataKey(config)) app.log.warn('DATA_KEY is not set; secrets are sealed with a key derived from JWT_SECRET.');

  await app.register(helmet, { contentSecurityPolicy: false });
  const origins = config.CORS_ORIGINS.trim();
  await app.register(cors, {
    origin: origins === '*' ? true : origins.split(',').map((o) => o.trim()),
    allowedHeaders: ['Authorization', 'Content-Type', 'X-Company-Id', 'Idempotency-Key'],
    exposedHeaders: ['Idempotent-Replayed'],
    methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
  });
  await app.register(rateLimit, { global: false });
  if (opts.authRateLimit !== false) {
    // A root hook, so it counts before the sign-in check rejects a request. Routes with their own limit
    // (sign-in) or rateLimit: false (/health) skip it. The store is per process.
    const general = app.rateLimit({ max: config.RATE_LIMIT_PER_MINUTE, timeWindow: '1 minute' });
    app.addHook('onRequest', async (req, reply) => {
      if (req.routeOptions.config?.rateLimit === undefined) await general.call(app, req, reply);
    });
  }
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
      return reply.status(429).send({ error: { code: 'RATE_LIMITED', message: 'Too many requests. Try again in a minute.' } });
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

  // Liveness and readiness in one: 503 when the database does not answer within 2 seconds.
  app.get('/health', { config: { rateLimit: false } }, async (_req, reply) => {
    const time = new Date().toISOString();
    try {
      await Promise.race([
        sql`select 1`.execute(db),
        new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 2000).unref()),
      ]);
      return { status: 'ok', db: 'ok', time };
    } catch {
      return reply.status(503).send({ status: 'unavailable', db: 'down', time });
    }
  });

  await app.register(
    async (api) => {
      await api.register(async (open) => authRoutes(open, deps, opts.authRateLimit ?? 20));
      await api.register(async (open) => businessCatalogueRoutes(open));
      await api.register(async (open) => channelWebhookRoutes(open, db));
      registerOpenApi(api, routeLog);

      await api.register(async (secured) => {
        secured.decorateRequest('ctx', null as unknown as RequestContext);
        secured.decorateRequest('authInfo', null as unknown as Request['authInfo']);
        secured.addHook('onRequest', async (req) => {
          const header = req.headers.authorization;
          if (!header?.startsWith('Bearer ')) throw unauthorized('Please sign in.');
          if (isApiKey(header.slice(7))) {
            // Company API key: acts with the permissions of one role in one company.
            const keyCtx = await contextForApiKey(db, header.slice(7));
            const asked = req.headers['x-company-id'];
            if (typeof asked === 'string' && asked && asked !== keyCtx.companyId) throw sessionRevoked('This API key belongs to another company.');
            req.authInfo = { amr: 'key', mustEnrol2fa: false };
            req.ctx = keyCtx;
            return;
          }
          const claims = await tokens.verifyAccess(header.slice(7));
          const { name, memberships, mustEnrol2fa } = await withTenant(db, claims.tenantId, async (tx) => {
            await assertTenantActive(tx, claims.tenantId);
            if (claims.sid) {
              const live = await tx.selectFrom('refresh_tokens').select('id').where('session_id', '=', claims.sid)
                .where('user_id', '=', claims.userId).where('revoked_at', 'is', null).where('expires_at', '>', new Date()).limit(1).executeTakeFirst();
              if (!live) throw sessionRevoked('This session was ended. Please sign in again.');
            }
            const loaded = await loadMemberships(tx, claims.userId);
            let must = false;
            if (claims.amr !== 'sso' && loaded.memberships.length) {
              const u = await tx.selectFrom('users').select('two_factor_enabled_at').where('id', '=', claims.userId).executeTakeFirst();
              if (u && !u.two_factor_enabled_at) {
                const req2 = await tx.selectFrom('companies').select('id').where('id', 'in', loaded.memberships.map((m) => m.companyId))
                  .where('require_2fa', '=', true).limit(1).executeTakeFirst();
                must = !!req2;
              }
            }
            return { ...loaded, mustEnrol2fa: must };
          });
          req.authInfo = { sid: claims.sid, amr: claims.amr, mustEnrol2fa };
          if (mustEnrol2fa) {
            const path = req.url.split('?')[0]!.replace(/^\/api\/v1/, '').replace(/\/+$/, '') || '/';
            const exempt = ENROL_EXEMPT.some((re) => re.test(path)) && !(path === '/notifications/unread-count' && req.method !== 'GET')
              && !(path === '/me' && req.method !== 'GET') && !(path === '/me/security' && req.method !== 'GET')
              && !(path === '/me/password' && req.method !== 'POST');
            if (!exempt) throw new AppError(403, 'MFA_ENROLMENT_REQUIRED', 'Set up two-factor sign-in to continue.');
          }
          const wanted = req.headers['x-company-id'];
          let company = memberships[0] ?? NO_COMPANY;
          if (typeof wanted === 'string' && wanted.length > 0) {
            const match = memberships.find((m) => m.companyId === wanted);
            if (!match) throw sessionRevoked('You no longer have access to this company.');
            company = match;
          }
          req.ctx = new RequestContext(db, claims.tenantId, claims.userId, name, memberships, company);
        });

        registerEntitlements(secured);
        registerIdempotency(secured);
        await meRoutes(secured);
        await platformAdminRoutes(secured, deps);
        await locationRoutes(secured);
        await itemRoutes(secured);
        await partyRoutes(secured);
        await stockRoutes(secured);
        await invoiceRoutes(secured);
        await dashboardRoutes(secured);
        await analyticsRoutes(secured);
        await userRoutes(secured);
        await auditRoutes(secured);
        await companyRoutes(secured);
        await purchaseRoutes(secured);
        await purchaseOrderRoutes(secured);
        await goodsReceiptRoutes(secured);
        await reorderRoutes(secured);
        await stockCountRoutes(secured);
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
        await posRoutes(secured);
        await bookingRoutes(secured);
        await clinicRoutes(secured);
        await clinicIpdRoutes(secured);
        await fundRoutes(secured);
        await hrRoutes(secured);
        await payrollRoutes(secured);
        await donationRoutes(secured);
        await hotelRoutes(secured);
        await educationRoutes(secured);
        await legalRoutes(secured);
        await membershipRoutes(secured);
        await jobCardRoutes(secured);
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
        await warehouseRoutes(secured);
        await channelRoutes(secured);
        await tallyRoutes(secured);
        await securityRoutes(secured, deps);
        await jobRoutes(secured, deps);
        await notificationRoutes(secured, deps);
        await companiesRoutes(secured, deps);
        await intercompanyRoutes(secured, deps);
        await gspRoutes(secured, deps);
        await approvalRoutes(secured, deps);
        await customFieldRoutes(secured, deps);
        await costCentreRoutes(secured, deps);
        await importRoutes(secured, deps);
        await o2cRoutes(secured, deps);
        await restaurantRoutes(secured);
        await manufacturingRoutes(secured);
        await businessRoutes(secured, deps);
        await integrationRoutes(secured, deps);
      });
    },
    { prefix: '/api/v1' },
  );

  return app;
}
