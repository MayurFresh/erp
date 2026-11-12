import type { FastifyInstance } from 'fastify';
import { clampModules, defaultModules } from './business-types.ts';
import { AppError } from './errors.ts';

/**
 * Route prefix (first path segment after /api/v1) to the module that owns it. A company that has not enabled
 * the module gets 403 MODULE_DISABLED. Prefixes not listed here are always open: auth, me, company and the
 * business profile, platform admin, users and roles, files, jobs, and the core books (sales, purchases,
 * stock, accounting, reports), which are menu choices only.
 */
export const MODULE_ROUTES: Record<string, string> = {
  pos: 'pos',
  restaurant: 'restaurant',
  clinic: 'clinic',
  legal: 'legal',
  education: 'education',
  hotel: 'hotel',
  funds: 'funds',
  donations: 'donations',
  donors: 'donations',
  memberships: 'memberships',
  'job-cards': 'job_cards',
  channels: 'channels',
  warehouse: 'warehouse',
  payroll: 'payroll',
  employees: 'payroll',
  holidays: 'payroll',
  hr: 'payroll',
  'leave-types': 'payroll',
  'leave-applications': 'payroll',
  'attendance-summaries': 'payroll',
  'attendance-days': 'payroll',
  manufacturing: 'manufacturing',
  gst: 'gst',
  tds: 'tds',
  'fixed-assets': 'fixed_assets',
  'pick-lists': 'fulfilment',
  shipments: 'fulfilment',
  'sales-returns': 'fulfilment',
  projects: 'construction',
  boq: 'construction',
  dprs: 'construction',
  'ra-bills': 'construction',
  'work-orders': 'construction',
  'wage-sheets': 'construction',
  workers: 'construction',
  attendance: 'construction',
  'labour-advances': 'construction',
  'contractor-advances': 'construction',
  indents: 'construction',
  issues: 'construction',
  units: 'real_estate',
  bookings: 'real_estate',
  demands: 'real_estate',
  'payment-plans': 'real_estate',
  'intercompany-entries': 'multi_company',
};

/** Module key for a route pattern such as /api/v1/clinic/patients/:id, or null when the route is open. */
export function moduleForRoute(pattern: string): string | null {
  const m = /^\/api\/v1\/([^/?]+)/.exec(pattern);
  return m ? (MODULE_ROUTES[m[1]!] ?? null) : null;
}

/** The modules a company has: its own list, or the defaults for its business type. */
export function effectiveModules(c: { enabled_modules: string[] | null; business_type: string; country: string; plan: string }): string[] {
  return c.enabled_modules ?? clampModules(defaultModules(c.business_type, c.country), c.plan, c.country);
}

/** Adds the module check to a secured scope. Register it after the hook that sets req.ctx. */
export function registerEntitlements(app: FastifyInstance): void {
  app.addHook('onRequest', async (req) => {
    const module = moduleForRoute(req.routeOptions.url ?? '');
    if (!module || !req.ctx?.companyId) return;
    const company = await req.ctx.tx((tx) => tx.selectFrom('companies').select(['enabled_modules', 'business_type', 'country', 'plan'])
      .where('id', '=', req.ctx.companyId).executeTakeFirst());
    if (company && !effectiveModules(company).includes(module)) {
      throw new AppError(403, 'MODULE_DISABLED', `The ${module.replace('_', ' ')} module is not enabled for this company.`, { module });
    }
  });
}
