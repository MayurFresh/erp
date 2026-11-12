import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import { systemAccounts } from '../accounting/accounts.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { nullableText, optionalText } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { nextNumber } from '../lib/series.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { documentRoute } from '../lib/openapi.ts';

/*
 * Fund and budget control. Spending is not posted here: purchase bills, expenses and vendor payments post as before and are
 * linked to a budget head and a fund (fund_links). Grants received post a journal (bank debit, grant income credit).
 */

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const fyField = z.string().regex(/^[0-9]{4}-[0-9]{2}$/, 'Use a year like 2026-27');
const nullDate = z.preprocess((v) => (v === '' ? null : v), dateField.nullable().optional());
const LEVELS = ['major', 'minor', 'object'] as const;
const KINDS = ['grant', 'csr', 'own', 'donation', 'other'] as const;

const viewFunds = (c: RequestContext) => c.require('funds.view', 'funds.entry', 'funds.manage');
const entryFunds = (c: RequestContext) => c.require('funds.entry', 'funds.manage');
const manageFunds = (c: RequestContext) => c.require('funds.manage');

// ---------------------------------------------------------------- settings and accounts (shared with donations)

export interface FundsSettings {
  overspendMode: 'block' | 'warn'; reg80gNo: string | null; reg80gFrom: string | null; reg80gTo: string | null;
  trustPan: string | null; receiptFooter: string | null;
}

export async function loadSettings(tx: Tx, ctx: RequestContext): Promise<FundsSettings> {
  const r = await tx.selectFrom('funds_settings').selectAll().where('company_id', '=', ctx.companyId).executeTakeFirst();
  return {
    overspendMode: (r?.overspend_mode as 'block' | 'warn') ?? 'warn', reg80gNo: r?.reg_80g_no ?? null, reg80gFrom: r?.reg_80g_from ?? null,
    reg80gTo: r?.reg_80g_to ?? null, trustPan: r?.trust_pan ?? null, receiptFooter: r?.receipt_footer ?? null,
  };
}

/** Finds a company account by name or creates it with the first free code from `startCode`. */
export async function ensureAccount(tx: Tx, ctx: RequestContext, name: string, type: 'income' | 'equity' | 'liability', startCode: number): Promise<string> {
  const ex = await tx.selectFrom('accounts').select('id').where('company_id', '=', ctx.companyId).where('name', '=', name).executeTakeFirst();
  if (ex) return ex.id;
  const used = new Set((await tx.selectFrom('accounts').select('code').where('company_id', '=', ctx.companyId).execute()).map((r) => r.code));
  let code = startCode;
  while (used.has(String(code))) code += 1;
  const row = await tx.insertInto('accounts').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, code: String(code), name, type, subtype: 'other', system_key: null, is_system: false,
  }).returning('id').executeTakeFirstOrThrow();
  return row.id;
}

export async function cashBankAccount(tx: Tx, ctx: RequestContext, accountId: string | undefined, mode: 'cash' | 'bank'): Promise<string> {
  if (!accountId) {
    const sys = await systemAccounts(tx, ctx);
    return mode === 'cash' ? sys.cash : sys.bank;
  }
  const a = await tx.selectFrom('accounts').select(['id', 'subtype', 'is_active']).where('id', '=', accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!a || !a.is_active || !['cash', 'bank'].includes(a.subtype)) throw badRequest('Choose an active cash or bank account.', { accountId: 'Not a cash or bank account' });
  return a.id;
}

const settingsBody = z.object({
  overspendMode: z.enum(['block', 'warn']).optional(),
  reg80gNo: nullableText(60), reg80gFrom: nullDate, reg80gTo: nullDate,
  trustPan: z.preprocess((v) => (v === '' ? null : typeof v === 'string' ? v.trim().toUpperCase() : v),
    z.string().regex(/^[A-Z]{5}[0-9]{4}[A-Z]$/, 'Enter a valid PAN').nullable().optional()),
  receiptFooter: nullableText(300),
}).refine((b) => !b.reg80gFrom || !b.reg80gTo || b.reg80gFrom <= b.reg80gTo, { message: 'Valid-to must not be before valid-from', path: ['reg80gTo'] });

// ---------------------------------------------------------------- budget position

interface LinkRow { id: string; source_type: string; source_id: string; head_id: string; fund_id: string; sanction_id: string | null; amount: number; note: string | null; number: string | null; date: string | null; status: string | null }

/** All fund links of the company with the date, number and status of the document behind each. */
async function loadLinks(tx: Tx, ctx: RequestContext): Promise<LinkRow[]> {
  const r = await sql<LinkRow>`
    select l.id, l.source_type, l.source_id, l.head_id, l.fund_id, l.sanction_id, l.amount::float8 as amount, l.note,
           coalesce(p.number, e.number, y.number) as number,
           coalesce(p.bill_date, e.expense_date, y.payment_date)::text as date,
           coalesce(p.status, e.status, y.status) as status
    from fund_links l
    left join purchases p on l.source_type = 'purchase' and p.id = l.source_id
    left join expenses e on l.source_type = 'expense' and e.id = l.source_id
    left join payments y on l.source_type = 'payment' and y.id = l.source_id
    where l.company_id = ${ctx.companyId}`.execute(tx);
  return r.rows.filter((l) => l.status === 'posted');
}

interface HeadOut {
  id: string; fy: string; parentId: string | null; level: string; code: string; name: string; accountId: string | null; accountName: string | null;
  isLeaf: boolean; isActive: boolean; estimate: number; revised: number | null; reappIn: number; reappOut: number; budget: number;
  actual: number; committed: number; available: number; percentUsed: number; percentCommitted: number; updatedAt: string;
}

/** Sanction commitment: what is approved and not yet spent against it. */
async function sanctionCommitments(tx: Tx, ctx: RequestContext, links: LinkRow[]) {
  const rows = await tx.selectFrom('fund_sanctions').select(['id', 'head_id', 'fund_id', 'amount']).where('company_id', '=', ctx.companyId).where('status', '=', 'approved').execute();
  const spent = new Map<string, number>();
  for (const l of links) if (l.sanction_id) spent.set(l.sanction_id, round2((spent.get(l.sanction_id) ?? 0) + l.amount));
  return rows.map((s) => ({ id: s.id, headId: s.head_id, fundId: s.fund_id, amount: Number(s.amount), spent: spent.get(s.id) ?? 0, remaining: Math.max(0, round2(Number(s.amount) - (spent.get(s.id) ?? 0))) }));
}

async function computeHeads(tx: Tx, ctx: RequestContext, fy: string, links?: LinkRow[]): Promise<HeadOut[]> {
  const heads = await tx.selectFrom('budget_heads as h').leftJoin('accounts as a', 'a.id', 'h.account_id')
    .select(['h.id', 'h.fy', 'h.parent_id', 'h.level', 'h.code', 'h.name', 'h.account_id', 'a.name as account_name', 'h.budget_estimate', 'h.revised_estimate', 'h.is_active', 'h.updated_at'])
    .where('h.company_id', '=', ctx.companyId).where('h.fy', '=', fy).orderBy('h.code').execute();
  if (!heads.length) return [];
  const all = links ?? await loadLinks(tx, ctx);
  const reapp = await tx.selectFrom('budget_reappropriations').select(['from_head_id', 'to_head_id', 'amount'])
    .where('company_id', '=', ctx.companyId).where('fy', '=', fy).where('status', '=', 'approved').execute();
  const commits = await sanctionCommitments(tx, ctx, all);
  const sumBy = <T>(rows: T[], key: (r: T) => string, val: (r: T) => number) => {
    const m = new Map<string, number>();
    for (const r of rows) m.set(key(r), round2((m.get(key(r)) ?? 0) + val(r)));
    return m;
  };
  const inM = sumBy(reapp, (r) => r.to_head_id, (r) => Number(r.amount));
  const outM = sumBy(reapp, (r) => r.from_head_id, (r) => Number(r.amount));
  const actM = sumBy(all, (l) => l.head_id, (l) => l.amount);
  const comM = sumBy(commits, (c) => c.headId, (c) => c.remaining);
  const kids = new Map<string, string[]>();
  for (const h of heads) if (h.parent_id) kids.set(h.parent_id, [...(kids.get(h.parent_id) ?? []), h.id]);
  const byId = new Map(heads.map((h) => [h.id, h]));
  const out = new Map<string, HeadOut>();
  const build = (id: string): HeadOut => {
    const done = out.get(id);
    if (done) return done;
    const h = byId.get(id)!;
    const ch = (kids.get(id) ?? []).map(build);
    const leaf = ch.length === 0;
    const sum = (f: (c: HeadOut) => number) => round2(ch.reduce((s, c) => s + f(c), 0));
    const estimate = leaf ? Number(h.budget_estimate) : sum((c) => c.estimate);
    const revised = leaf ? (h.revised_estimate === null ? null : Number(h.revised_estimate)) : (ch.some((c) => c.revised !== null) ? sum((c) => c.revised ?? c.estimate) : null);
    const reappIn = leaf ? inM.get(id) ?? 0 : sum((c) => c.reappIn);
    const reappOut = leaf ? outM.get(id) ?? 0 : sum((c) => c.reappOut);
    const budget = leaf ? round2((revised ?? estimate) + reappIn - reappOut) : sum((c) => c.budget);
    const actual = leaf ? actM.get(id) ?? 0 : sum((c) => c.actual);
    const committed = leaf ? comM.get(id) ?? 0 : sum((c) => c.committed);
    const pct = (n: number) => (budget > 0 ? Math.round((n / budget) * 1000) / 10 : n > 0 ? 100 : 0);
    const o: HeadOut = {
      id, fy: h.fy, parentId: h.parent_id, level: h.level, code: h.code, name: h.name, accountId: h.account_id, accountName: h.account_name,
      isLeaf: leaf, isActive: h.is_active, estimate, revised, reappIn, reappOut, budget, actual, committed,
      available: round2(budget - actual - committed), percentUsed: pct(actual), percentCommitted: pct(actual + committed), updatedAt: h.updated_at.toISOString(),
    };
    out.set(id, o);
    return o;
  };
  return heads.map((h) => build(h.id));
}

interface Exposure { available: number; requested: number }

/** Applies the company's overspend rule. Returns warnings, or throws 409 when the rule is `block`. */
function judge(settings: FundsSettings, over: { code: 'BUDGET_EXCEEDED' | 'FUND_EXCEEDED'; message: string; ex: Exposure }[]): string[] {
  const hit = over.filter((o) => o.ex.requested > o.ex.available + 0.001);
  if (!hit.length) return [];
  if (settings.overspendMode === 'block') {
    const h = hit[0]!;
    throw conflict(h.message, h.code, { available: h.ex.available, requested: h.ex.requested });
  }
  return hit.map((h) => h.message);
}

interface FundTotals { received: number; spent: number; committed: number }
async function fundTotals(tx: Tx, ctx: RequestContext, links: LinkRow[]): Promise<Map<string, FundTotals>> {
  const m = new Map<string, FundTotals>();
  const get = (id: string) => { let t = m.get(id); if (!t) { t = { received: 0, spent: 0, committed: 0 }; m.set(id, t); } return t; };
  const rec = await tx.selectFrom('fund_receipts').select(['fund_id', 'amount']).where('company_id', '=', ctx.companyId).where('status', '=', 'posted').execute();
  for (const r of rec) get(r.fund_id).received = round2(get(r.fund_id).received + Number(r.amount));
  const don = await tx.selectFrom('donations').select(['fund_id', 'amount']).where('company_id', '=', ctx.companyId).where('status', '=', 'posted').where('fund_id', 'is not', null).execute();
  for (const r of don) get(r.fund_id!).received = round2(get(r.fund_id!).received + Number(r.amount));
  for (const l of links) get(l.fund_id).spent = round2(get(l.fund_id).spent + l.amount);
  for (const c of await sanctionCommitments(tx, ctx, links)) get(c.fundId).committed = round2(get(c.fundId).committed + c.remaining);
  return m;
}

// ---------------------------------------------------------------- schemas

const fundFields = {
  name: z.string().trim().min(1, 'Required').max(150),
  kind: z.enum(KINDS),
  sponsor: nullableText(200), sanctionNo: nullableText(60), sanctionDate: nullDate,
  totalAmount: moneyField, periodFrom: nullDate, periodTo: nullDate,
  returnUnspent: z.boolean(), notes: nullableText(1000),
};
const periodOk = (b: { periodFrom?: string | null; periodTo?: string | null }) => !b.periodFrom || !b.periodTo || b.periodFrom <= b.periodTo;
const fundCreate = z.object({ ...fundFields, kind: fundFields.kind.default('grant'), totalAmount: fundFields.totalAmount.default(0), returnUnspent: fundFields.returnUnspent.default(false) })
  .refine(periodOk, { message: 'Period end must not be before its start', path: ['periodTo'] });
const fundPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  name: fundFields.name.optional(), kind: fundFields.kind.optional(), sponsor: fundFields.sponsor, sanctionNo: fundFields.sanctionNo,
  sanctionDate: fundFields.sanctionDate, totalAmount: fundFields.totalAmount.optional(), periodFrom: fundFields.periodFrom, periodTo: fundFields.periodTo,
  returnUnspent: fundFields.returnUnspent.optional(), notes: fundFields.notes, status: z.enum(['active', 'closed']).optional(),
}).refine(periodOk, { message: 'Period end must not be before its start', path: ['periodTo'] });

const headCreate = z.object({
  fy: fyField, parentId: z.uuid().nullable().optional(), level: z.enum(LEVELS),
  code: z.string().trim().min(1, 'Required').max(30), name: z.string().trim().min(1, 'Required').max(150),
  accountId: z.uuid().nullable().optional(), budgetEstimate: moneyField.default(0),
  revisedEstimate: z.preprocess((v) => (v === '' ? null : v), moneyField.nullable().optional()),
});
const headPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  code: z.string().trim().min(1).max(30).optional(), name: z.string().trim().min(1).max(150).optional(),
  accountId: z.uuid().nullable().optional(), budgetEstimate: moneyField.optional(),
  revisedEstimate: z.preprocess((v) => (v === '' ? null : v), moneyField.nullable().optional()), isActive: z.boolean().optional(),
});
const fyQuery = z.object({ fy: fyField.optional() });
const reappCreate = z.object({
  fromHeadId: z.uuid(), toHeadId: z.uuid(), amount: moneyField.refine((v) => v > 0, 'Must be more than zero'),
  orderNo: z.string().trim().min(1, 'Required').max(60), orderDate: dateField, reason: z.string().trim().min(1, 'Required').max(500),
});
const sanctionCreate = z.object({
  headId: z.uuid(), fundId: z.uuid(), purpose: z.string().trim().min(1, 'Required').max(500), amount: moneyField.refine((v) => v > 0, 'Must be more than zero'),
});
const sanctionApprove = z.object({
  adminOrderNo: z.string().trim().min(1, 'Administrative approval order number is required').max(60), adminOrderDate: dateField,
  financialOrderNo: z.string().trim().min(1, 'Financial approval order number is required').max(60), financialOrderDate: dateField,
  note: optionalText(300),
});
const noteBody = z.object({ note: optionalText(300) });
const sanctionList = z.object({
  status: z.enum(['pending', 'approved', 'rejected', 'cancelled']).optional(), headId: z.uuid().optional(), fundId: z.uuid().optional(),
  limit: z.coerce.number().int().min(1).max(200).default(100),
});
const linkCreate = z.object({
  sourceType: z.enum(['purchase', 'expense', 'payment']), sourceId: z.uuid(), headId: z.uuid(), fundId: z.uuid(), sanctionId: z.uuid().nullable().optional(),
  amount: moneyField.refine((v) => v > 0, 'Must be more than zero').optional(), note: optionalText(300),
});
const receiptCreate = z.object({
  amount: moneyField.refine((v) => v > 0, 'Must be more than zero'), date: dateField.optional(), accountId: z.uuid().optional(),
  reference: optionalText(100), narration: optionalText(300),
});
const rangeQuery = z.object({ from: dateField.optional(), to: dateField.optional() })
  .refine((b) => !b.from || !b.to || b.from <= b.to, { message: 'From must not be after to', path: ['to'] });

// ---------------------------------------------------------------- loaders

async function loadFund(tx: Tx, ctx: RequestContext, id: string) {
  const f = await tx.selectFrom('funds').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!f) throw notFound('Fund');
  return f;
}
async function loadHead(tx: Tx, ctx: RequestContext, id: string) {
  const h = await tx.selectFrom('budget_heads').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!h) throw notFound('Budget head');
  return h;
}
const fundJson = (f: Awaited<ReturnType<typeof loadFund>>, t?: FundTotals) => {
  const x = t ?? { received: 0, spent: 0, committed: 0 };
  return {
    id: f.id, name: f.name, kind: f.kind, sponsor: f.sponsor, sanctionNo: f.sanction_no, sanctionDate: f.sanction_date, totalAmount: Number(f.total_amount),
    periodFrom: f.period_from, periodTo: f.period_to, returnUnspent: f.return_unspent, status: f.status, notes: f.notes,
    received: x.received, spent: x.spent, committed: x.committed, balance: round2(x.received - x.spent), updatedAt: f.updated_at.toISOString(),
  };
};

async function assertLeaf(tx: Tx, ctx: RequestContext, headId: string) {
  const h = await loadHead(tx, ctx, headId);
  if (!h.is_active) throw badRequest('This budget head is not active.', { headId: 'Not active' });
  const kid = await tx.selectFrom('budget_heads').select('id').where('parent_id', '=', h.id).limit(1).executeTakeFirst();
  if (kid) throw badRequest('Use the lowest level head (object head). This one has heads under it.', { headId: 'Has sub-heads' });
  return h;
}

/** Budget and fund checks for spending `extra` more on a head and fund. `extra` is new exposure only. */
async function exposureWarnings(tx: Tx, ctx: RequestContext, head: { id: string; fy: string; code: string }, fundId: string, extraHead: number, extraFund: number, links?: LinkRow[]) {
  const settings = await loadSettings(tx, ctx);
  const all = links ?? await loadLinks(tx, ctx);
  const pos = (await computeHeads(tx, ctx, head.fy, all)).find((h) => h.id === head.id)!;
  const fund = await loadFund(tx, ctx, fundId);
  const ft = (await fundTotals(tx, ctx, all)).get(fundId) ?? { received: 0, spent: 0, committed: 0 };
  const checks: Parameters<typeof judge>[1] = [{
    code: 'BUDGET_EXCEEDED', message: `This would exceed the budget of ${head.code}. Available: ${pos.available.toFixed(2)}, needed: ${extraHead.toFixed(2)}.`,
    ex: { available: pos.available, requested: extraHead },
  }];
  if (Number(fund.total_amount) > 0) {
    const avail = round2(Number(fund.total_amount) - ft.spent - ft.committed);
    checks.push({ code: 'FUND_EXCEEDED', message: `This would exceed the sanctioned amount of ${fund.name}. Available: ${avail.toFixed(2)}, needed: ${extraFund.toFixed(2)}.`, ex: { available: avail, requested: extraFund } });
  }
  return judge(settings, checks);
}

// ---------------------------------------------------------------- routes

export async function fundRoutes(app: FastifyInstance) {
  // ---- settings
  app.get('/funds/settings', async (req) => {
    const ctx = req.ctx; ctx.require('funds.view', 'funds.entry', 'funds.manage', 'donations.view', 'donations.create', 'donations.manage');
    return ctx.tx((tx) => loadSettings(tx, ctx));
  });
  app.route({ method: ['PUT', 'PATCH'], url: '/funds/settings', handler: async (req) => {
    const ctx = req.ctx; ctx.require('funds.manage', 'donations.manage');
    const b = parse(settingsBody, req.body);
    return ctx.tx(async (tx) => {
      const cur = await loadSettings(tx, ctx);
      const next = {
        overspend_mode: b.overspendMode ?? cur.overspendMode,
        reg_80g_no: b.reg80gNo === undefined ? cur.reg80gNo : b.reg80gNo,
        reg_80g_from: b.reg80gFrom === undefined ? cur.reg80gFrom : b.reg80gFrom,
        reg_80g_to: b.reg80gTo === undefined ? cur.reg80gTo : b.reg80gTo,
        trust_pan: b.trustPan === undefined ? cur.trustPan : b.trustPan,
        receipt_footer: b.receiptFooter === undefined ? cur.receiptFooter : b.receiptFooter,
      };
      if (b.overspendMode && !ctx.can('funds.manage')) throw badRequest('Only fund managers change the overspend rule.', { overspendMode: 'Not allowed' });
      await tx.insertInto('funds_settings').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, ...next })
        .onConflict((oc) => oc.column('company_id').doUpdateSet({ ...next, updated_at: new Date() })).execute();
      await writeAudit(tx, auditOf(ctx), 'funds_settings', null, 'update', cur, next);
      return loadSettings(tx, ctx);
    });
  } });

  // ---- funds
  app.get('/funds/funds', async (req) => {
    const ctx = req.ctx; viewFunds(ctx);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('funds').selectAll().where('company_id', '=', ctx.companyId).orderBy('status').orderBy('name').execute();
      const t = await fundTotals(tx, ctx, await loadLinks(tx, ctx));
      return { data: rows.map((f) => fundJson(f, t.get(f.id))) };
    });
  });
  app.post('/funds/funds', async (req, reply) => {
    const ctx = req.ctx; manageFunds(ctx);
    const b = parse(fundCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      const dup = await tx.selectFrom('funds').select('id').where('company_id', '=', ctx.companyId).where('name', '=', b.name).executeTakeFirst();
      if (dup) throw conflict('A fund with this name already exists.', 'DUPLICATE_FUND');
      const row = await tx.insertInto('funds').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.name, kind: b.kind, sponsor: b.sponsor ?? null, sanction_no: b.sanctionNo ?? null,
        sanction_date: b.sanctionDate ?? null, total_amount: b.totalAmount, period_from: b.periodFrom ?? null, period_to: b.periodTo ?? null,
        return_unspent: b.returnUnspent, notes: b.notes ?? null, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'fund', row.id, 'create', null, fundJson(row));
      return fundJson(row);
    });
    return reply.status(201).send(out);
  });
  app.get<{ Params: { id: string } }>('/funds/funds/:id', async (req) => {
    const ctx = req.ctx; viewFunds(ctx);
    return ctx.tx(async (tx) => {
      const f = await loadFund(tx, ctx, req.params.id);
      const t = await fundTotals(tx, ctx, await loadLinks(tx, ctx));
      return fundJson(f, t.get(f.id));
    });
  });
  app.patch<{ Params: { id: string } }>('/funds/funds/:id', async (req) => {
    const ctx = req.ctx; manageFunds(ctx);
    const b = parse(fundPatch, req.body);
    return ctx.tx(async (tx) => {
      const cur = await loadFund(tx, ctx, req.params.id);
      assertFresh(cur.updated_at, b.expectedUpdatedAt, 'fund');
      const set: Record<string, unknown> = {};
      const map: [keyof typeof b, string][] = [['name', 'name'], ['kind', 'kind'], ['sponsor', 'sponsor'], ['sanctionNo', 'sanction_no'], ['sanctionDate', 'sanction_date'],
        ['totalAmount', 'total_amount'], ['periodFrom', 'period_from'], ['periodTo', 'period_to'], ['returnUnspent', 'return_unspent'], ['notes', 'notes'], ['status', 'status']];
      for (const [k, col] of map) if (b[k] !== undefined) set[col] = b[k];
      const from = (set.period_from ?? cur.period_from) as string | null, to = (set.period_to ?? cur.period_to) as string | null;
      if (from && to && from > to) throw badRequest('Period end must not be before its start.', { periodTo: 'Before start' });
      if (b.name && b.name !== cur.name) {
        const dup = await tx.selectFrom('funds').select('id').where('company_id', '=', ctx.companyId).where('name', '=', b.name).executeTakeFirst();
        if (dup) throw conflict('A fund with this name already exists.', 'DUPLICATE_FUND');
      }
      const row = await tx.updateTable('funds').set(set).where('id', '=', cur.id).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'fund', cur.id, 'update', fundJson(cur), fundJson(row));
      const t = await fundTotals(tx, ctx, await loadLinks(tx, ctx));
      return fundJson(row, t.get(row.id));
    });
  });

  // ---- grants received
  app.get<{ Params: { id: string } }>('/funds/funds/:id/receipts', async (req) => {
    const ctx = req.ctx; viewFunds(ctx);
    return ctx.tx(async (tx) => {
      await loadFund(tx, ctx, req.params.id);
      const rows = await tx.selectFrom('fund_receipts').selectAll().where('fund_id', '=', req.params.id).where('company_id', '=', ctx.companyId).orderBy('receipt_date', 'desc').orderBy('number', 'desc').execute();
      return { data: rows.map((r) => ({ id: r.id, number: r.number, date: r.receipt_date, amount: Number(r.amount), reference: r.reference, narration: r.narration, status: r.status })) };
    });
  });
  app.post<{ Params: { id: string } }>('/funds/funds/:id/receipts', async (req, reply) => {
    const ctx = req.ctx; entryFunds(ctx);
    const b = parse(receiptCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      const fund = await loadFund(tx, ctx, req.params.id);
      if (fund.status !== 'active') throw conflict('This fund is closed.', 'FUND_CLOSED');
      const date = b.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });
      const bank = await cashBankAccount(tx, ctx, b.accountId, 'bank');
      // Money that must be returned if unspent is a liability; it moves to income as spending is linked to the fund.
      const income = fund.return_unspent
        ? await ensureAccount(tx, ctx, 'Grants Refundable (Unspent)', 'liability', 2800)
        : fund.income_account_id ?? await ensureAccount(tx, ctx, 'Grants Received', 'income', 4800);
      const number = await nextNumber(tx, ctx, 'grant_receipt', financialYear(date));
      const row = await tx.insertInto('fund_receipts').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, fund_id: fund.id, receipt_date: date, amount: b.amount, account_id: bank,
        reference: b.reference ?? null, narration: b.narration ?? null, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await postJournal(tx, auditOf(ctx), {
        date, voucherType: 'journal', voucherId: row.id, number, narration: `Grant received for ${fund.name}${b.reference ? ` (${b.reference})` : ''}`,
        lines: [{ accountId: bank, amount: b.amount }, { accountId: income, amount: -b.amount }],
      });
      await writeAudit(tx, auditOf(ctx), 'fund_receipt', row.id, 'create', null, { number, fund: fund.name, amount: b.amount });
      return { id: row.id, number, date, amount: b.amount, reference: row.reference, narration: row.narration, status: row.status };
    });
    return reply.status(201).send(out);
  });

  // ---- budget heads
  app.get('/funds/heads', async (req) => {
    const ctx = req.ctx; viewFunds(ctx);
    const { fy = financialYear(todayIst()) } = parse(fyQuery, req.query);
    return ctx.tx(async (tx) => {
      const data = await computeHeads(tx, ctx, fy);
      const years = await tx.selectFrom('budget_heads').select('fy').distinct().where('company_id', '=', ctx.companyId).orderBy('fy', 'desc').execute();
      const top = data.filter((h) => !h.parentId);
      const sum = (f: (h: HeadOut) => number) => round2(top.reduce((s, h) => s + f(h), 0));
      return { fy, years: years.map((y) => y.fy), data, totals: { budget: sum((h) => h.budget), actual: sum((h) => h.actual), committed: sum((h) => h.committed), available: sum((h) => h.available) } };
    });
  });
  app.post('/funds/heads', async (req, reply) => {
    const ctx = req.ctx; manageFunds(ctx);
    const b = parse(headCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      const wantParent = b.level === 'major' ? null : b.level === 'minor' ? 'major' : 'minor';
      if (!wantParent && b.parentId) throw badRequest('A major head has no parent.', { parentId: 'Not allowed' });
      if (wantParent) {
        if (!b.parentId) throw badRequest(`A ${b.level} head needs a ${wantParent} head above it.`, { parentId: 'Required' });
        const p = await loadHead(tx, ctx, b.parentId);
        if (p.level !== wantParent || p.fy !== b.fy) throw badRequest(`The parent must be a ${wantParent} head of ${b.fy}.`, { parentId: 'Wrong level or year' });
        if (Number(p.budget_estimate) > 0 || p.revised_estimate !== null) throw conflict('Move the parent head\'s amount to its sub-heads first.', 'PARENT_HAS_BUDGET');
        const used = await tx.selectFrom('fund_links').select('id').where('head_id', '=', p.id).limit(1).executeTakeFirst()
          ?? await tx.selectFrom('fund_sanctions').select('id').where('head_id', '=', p.id).limit(1).executeTakeFirst();
        if (used) throw conflict('The parent head already has sanctions or spending. Use it as it is.', 'PARENT_IN_USE');
      }
      if (b.accountId) {
        const a = await tx.selectFrom('accounts').select(['id', 'type']).where('id', '=', b.accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!a || a.type !== 'expense') throw badRequest('Choose an expense account.', { accountId: 'Not an expense account' });
      }
      const dup = await tx.selectFrom('budget_heads').select('id').where('company_id', '=', ctx.companyId).where('fy', '=', b.fy).where('code', '=', b.code).executeTakeFirst();
      if (dup) throw conflict('This head code is already used in that year.', 'DUPLICATE_HEAD');
      const row = await tx.insertInto('budget_heads').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, fy: b.fy, parent_id: b.parentId ?? null, level: b.level, code: b.code, name: b.name,
        account_id: b.accountId ?? null, budget_estimate: b.budgetEstimate, revised_estimate: b.revisedEstimate ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'budget_head', row.id, 'create', null, { fy: b.fy, code: b.code, name: b.name, estimate: b.budgetEstimate });
      return (await computeHeads(tx, ctx, b.fy)).find((h) => h.id === row.id)!;
    });
    return reply.status(201).send(out);
  });
  app.patch<{ Params: { id: string } }>('/funds/heads/:id', async (req) => {
    const ctx = req.ctx; manageFunds(ctx);
    const b = parse(headPatch, req.body);
    return ctx.tx(async (tx) => {
      const cur = await loadHead(tx, ctx, req.params.id);
      assertFresh(cur.updated_at, b.expectedUpdatedAt, 'budget head');
      const kid = await tx.selectFrom('budget_heads').select('id').where('parent_id', '=', cur.id).limit(1).executeTakeFirst();
      if (kid && (b.budgetEstimate !== undefined || b.revisedEstimate !== undefined)) throw badRequest('Set amounts on the lowest level heads; this head adds them up.', { budgetEstimate: 'Has sub-heads' });
      if (b.code && b.code !== cur.code) {
        const dup = await tx.selectFrom('budget_heads').select('id').where('company_id', '=', ctx.companyId).where('fy', '=', cur.fy).where('code', '=', b.code).executeTakeFirst();
        if (dup) throw conflict('This head code is already used in that year.', 'DUPLICATE_HEAD');
      }
      if (b.accountId) {
        const a = await tx.selectFrom('accounts').select(['id', 'type']).where('id', '=', b.accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!a || a.type !== 'expense') throw badRequest('Choose an expense account.', { accountId: 'Not an expense account' });
      }
      const set: Record<string, unknown> = {};
      if (b.code !== undefined) set.code = b.code;
      if (b.name !== undefined) set.name = b.name;
      if (b.accountId !== undefined) set.account_id = b.accountId;
      if (b.budgetEstimate !== undefined) set.budget_estimate = b.budgetEstimate;
      if (b.revisedEstimate !== undefined) set.revised_estimate = b.revisedEstimate;
      if (b.isActive !== undefined) set.is_active = b.isActive;
      if (Object.keys(set).length) await tx.updateTable('budget_heads').set(set).where('id', '=', cur.id).execute();
      await writeAudit(tx, auditOf(ctx), 'budget_head', cur.id, 'update', { estimate: Number(cur.budget_estimate), revised: cur.revised_estimate, code: cur.code }, set);
      return (await computeHeads(tx, ctx, cur.fy)).find((h) => h.id === cur.id)!;
    });
  });

  // ---- re-appropriation
  const reappJson = async (tx: Tx, ctx: RequestContext, status?: string, fy?: string) => {
    let q = tx.selectFrom('budget_reappropriations as r').innerJoin('budget_heads as f', 'f.id', 'r.from_head_id').innerJoin('budget_heads as t', 't.id', 'r.to_head_id')
      .innerJoin('users as u', 'u.id', 'r.created_by')
      .select(['r.id', 'r.fy', 'r.amount', 'r.order_no', 'r.order_date', 'r.reason', 'r.status', 'r.created_at', 'r.decided_at', 'f.id as fid', 'f.code as fcode', 'f.name as fname',
        't.id as tid', 't.code as tcode', 't.name as tname', 'u.name as by']).where('r.company_id', '=', ctx.companyId);
    if (status) q = q.where('r.status', '=', status);
    if (fy) q = q.where('r.fy', '=', fy);
    const rows = await q.orderBy('r.created_at', 'desc').limit(200).execute();
    return rows.map((r) => ({
      id: r.id, fy: r.fy, amount: Number(r.amount), orderNo: r.order_no, orderDate: r.order_date, reason: r.reason, status: r.status,
      fromHead: { id: r.fid, code: r.fcode, name: r.fname }, toHead: { id: r.tid, code: r.tcode, name: r.tname }, createdBy: r.by,
      createdAt: r.created_at.toISOString(), decidedAt: r.decided_at?.toISOString() ?? null,
    }));
  };
  app.get('/funds/reappropriations', async (req) => {
    const ctx = req.ctx; viewFunds(ctx);
    const q = parse(z.object({ fy: fyField.optional(), status: z.enum(['pending', 'approved', 'rejected']).optional() }), req.query);
    return ctx.tx(async (tx) => ({ data: await reappJson(tx, ctx, q.status, q.fy) }));
  });
  const approveReapp = async (tx: Tx, ctx: RequestContext, r: { id: string; fy: string; from_head_id: string; amount: number }) => {
    const pos = (await computeHeads(tx, ctx, r.fy)).find((h) => h.id === r.from_head_id)!;
    if (Number(r.amount) > pos.available + 0.001) {
      throw conflict(`${pos.code} has only ${pos.available.toFixed(2)} available to move.`, 'INSUFFICIENT_BUDGET', { available: pos.available, requested: Number(r.amount) });
    }
  };
  app.post('/funds/reappropriations', async (req, reply) => {
    const ctx = req.ctx; entryFunds(ctx);
    const b = parse(reappCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      if (b.fromHeadId === b.toHeadId) throw badRequest('Choose two different heads.', { toHeadId: 'Same head' });
      const from = await assertLeaf(tx, ctx, b.fromHeadId), to = await assertLeaf(tx, ctx, b.toHeadId);
      if (from.fy !== to.fy) throw badRequest('Both heads must be in the same financial year.', { toHeadId: 'Different year' });
      const approved = ctx.can('funds.manage');
      if (approved) await approveReapp(tx, ctx, { id: '', fy: from.fy, from_head_id: from.id, amount: b.amount });
      const row = await tx.insertInto('budget_reappropriations').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, fy: from.fy, from_head_id: from.id, to_head_id: to.id, amount: b.amount, order_no: b.orderNo,
        order_date: b.orderDate, reason: b.reason, status: approved ? 'approved' : 'pending', created_by: ctx.userId,
        decided_by: approved ? ctx.userId : null, decided_at: approved ? new Date() : null,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'budget_reappropriation', row.id, approved ? 'create_approved' : 'create', null, { from: from.code, to: to.code, amount: b.amount, orderNo: b.orderNo, reason: b.reason });
      return (await reappJson(tx, ctx)).find((r) => r.id === row.id)!;
    });
    return reply.status(201).send(out);
  });
  for (const act of ['approve', 'reject'] as const) {
    app.post<{ Params: { id: string } }>(`/funds/reappropriations/:id/${act}`, async (req) => {
      const ctx = req.ctx; manageFunds(ctx);
      return ctx.tx(async (tx) => {
        const r = await tx.selectFrom('budget_reappropriations').selectAll().where('id', '=', req.params.id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
        if (!r) throw notFound('Re-appropriation');
        if (r.status !== 'pending') throw conflict(`This request is already ${r.status}.`, 'ALREADY_DECIDED');
        if (act === 'approve') await approveReapp(tx, ctx, { id: r.id, fy: r.fy, from_head_id: r.from_head_id, amount: Number(r.amount) });
        await tx.updateTable('budget_reappropriations').set({ status: act === 'approve' ? 'approved' : 'rejected', decided_by: ctx.userId, decided_at: new Date() }).where('id', '=', r.id).execute();
        await writeAudit(tx, auditOf(ctx), 'budget_reappropriation', r.id, act, { status: 'pending' }, { status: act === 'approve' ? 'approved' : 'rejected' });
        return (await reappJson(tx, ctx)).find((x) => x.id === r.id)!;
      });
    });
  }

  // ---- sanctions
  const sanctionRows = async (tx: Tx, ctx: RequestContext, filter: { id?: string; status?: string; headId?: string; fundId?: string; limit?: number }) => {
    let q = tx.selectFrom('fund_sanctions as s').innerJoin('budget_heads as h', 'h.id', 's.head_id').innerJoin('funds as f', 'f.id', 's.fund_id').innerJoin('users as u', 'u.id', 's.created_by')
      .select(['s.id', 's.number', 's.purpose', 's.amount', 's.status', 's.admin_order_no', 's.admin_order_date', 's.financial_order_no', 's.financial_order_date', 's.decision_note',
        's.created_at', 's.decided_at', 's.head_id', 's.fund_id', 'h.code as head_code', 'h.name as head_name', 'f.name as fund_name', 'u.name as by']).where('s.company_id', '=', ctx.companyId);
    if (filter.id) q = q.where('s.id', '=', filter.id);
    if (filter.status) q = q.where('s.status', '=', filter.status);
    if (filter.headId) q = q.where('s.head_id', '=', filter.headId);
    if (filter.fundId) q = q.where('s.fund_id', '=', filter.fundId);
    const rows = await q.orderBy('s.created_at', 'desc').limit(filter.limit ?? 100).execute();
    const commits = new Map((await sanctionCommitments(tx, ctx, await loadLinks(tx, ctx))).map((c) => [c.id, c]));
    return rows.map((s) => {
      const c = commits.get(s.id);
      return {
        id: s.id, number: s.number, purpose: s.purpose, amount: Number(s.amount), status: s.status,
        head: { id: s.head_id, code: s.head_code, name: s.head_name }, fund: { id: s.fund_id, name: s.fund_name },
        adminOrderNo: s.admin_order_no, adminOrderDate: s.admin_order_date, financialOrderNo: s.financial_order_no, financialOrderDate: s.financial_order_date,
        decisionNote: s.decision_note, spent: c?.spent ?? 0, committed: c?.remaining ?? 0, createdBy: s.by, createdAt: s.created_at.toISOString(), decidedAt: s.decided_at?.toISOString() ?? null,
      };
    });
  };
  app.get('/funds/sanctions', async (req) => {
    const ctx = req.ctx; viewFunds(ctx);
    const q = parse(sanctionList, req.query);
    return ctx.tx(async (tx) => ({ data: await sanctionRows(tx, ctx, q) }));
  });
  app.get<{ Params: { id: string } }>('/funds/sanctions/:id', async (req) => {
    const ctx = req.ctx; viewFunds(ctx);
    return ctx.tx(async (tx) => {
      const s = (await sanctionRows(tx, ctx, { id: req.params.id }))[0];
      if (!s) throw notFound('Sanction');
      return s;
    });
  });
  app.post('/funds/sanctions', async (req, reply) => {
    const ctx = req.ctx; entryFunds(ctx);
    const b = parse(sanctionCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      const head = await assertLeaf(tx, ctx, b.headId);
      const fund = await loadFund(tx, ctx, b.fundId);
      if (fund.status !== 'active') throw conflict('This fund is closed.', 'FUND_CLOSED');
      const number = await nextNumber(tx, ctx, 'sanction', financialYear(todayIst()));
      const row = await tx.insertInto('fund_sanctions').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, head_id: head.id, fund_id: fund.id, purpose: b.purpose, amount: b.amount, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'fund_sanction', row.id, 'create', null, { number, head: head.code, fund: fund.name, amount: b.amount });
      const s = (await sanctionRows(tx, ctx, { id: row.id }))[0]!;
      // Preview only: nothing is committed until approval.
      const warnings = await previewWarnings(tx, ctx, head, fund.id, b.amount);
      return { ...s, warnings };
    });
    return reply.status(201).send(out);
  });
  const previewWarnings = async (tx: Tx, ctx: RequestContext, head: { id: string; fy: string; code: string }, fundId: string, amount: number) => {
    try { return await exposureWarnings(tx, ctx, head, fundId, amount, amount); } catch (e) {
      if (e instanceof Error && 'code' in e && ['BUDGET_EXCEEDED', 'FUND_EXCEEDED'].includes((e as { code: string }).code)) return [e.message];
      throw e;
    }
  };
  app.post<{ Params: { id: string } }>('/funds/sanctions/:id/approve', async (req) => {
    const ctx = req.ctx; manageFunds(ctx);
    const b = parse(sanctionApprove, req.body);
    return ctx.tx(async (tx) => {
      const s = await tx.selectFrom('fund_sanctions').selectAll().where('id', '=', req.params.id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!s) throw notFound('Sanction');
      if (s.status !== 'pending') throw conflict(`This sanction is already ${s.status}.`, 'ALREADY_DECIDED');
      const head = await loadHead(tx, ctx, s.head_id);
      const warnings = await exposureWarnings(tx, ctx, head, s.fund_id, Number(s.amount), Number(s.amount));
      await tx.updateTable('fund_sanctions').set({
        status: 'approved', admin_order_no: b.adminOrderNo, admin_order_date: b.adminOrderDate, financial_order_no: b.financialOrderNo,
        financial_order_date: b.financialOrderDate, decision_note: b.note ?? null, decided_by: ctx.userId, decided_at: new Date(),
      }).where('id', '=', s.id).execute();
      await writeAudit(tx, auditOf(ctx), 'fund_sanction', s.id, 'approve', { status: 'pending' }, { status: 'approved', adminOrderNo: b.adminOrderNo, financialOrderNo: b.financialOrderNo, warnings });
      return { ...(await sanctionRows(tx, ctx, { id: s.id }))[0]!, warnings };
    });
  });
  app.post<{ Params: { id: string } }>('/funds/sanctions/:id/reject', async (req) => {
    const ctx = req.ctx; manageFunds(ctx);
    const b = parse(noteBody, req.body);
    return ctx.tx(async (tx) => {
      const s = await tx.selectFrom('fund_sanctions').selectAll().where('id', '=', req.params.id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!s) throw notFound('Sanction');
      if (s.status !== 'pending') throw conflict(`This sanction is already ${s.status}.`, 'ALREADY_DECIDED');
      await tx.updateTable('fund_sanctions').set({ status: 'rejected', decision_note: b.note ?? null, decided_by: ctx.userId, decided_at: new Date() }).where('id', '=', s.id).execute();
      await writeAudit(tx, auditOf(ctx), 'fund_sanction', s.id, 'reject', { status: 'pending' }, { status: 'rejected' });
      return (await sanctionRows(tx, ctx, { id: s.id }))[0]!;
    });
  });
  app.post<{ Params: { id: string } }>('/funds/sanctions/:id/cancel', async (req) => {
    const ctx = req.ctx; entryFunds(ctx);
    const b = parse(noteBody, req.body);
    return ctx.tx(async (tx) => {
      const s = await tx.selectFrom('fund_sanctions').selectAll().where('id', '=', req.params.id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!s) throw notFound('Sanction');
      if (!['pending', 'approved'].includes(s.status)) throw conflict(`This sanction is already ${s.status}.`, 'ALREADY_DECIDED');
      if (s.status === 'approved') {
        manageFunds(ctx);
        const used = await tx.selectFrom('fund_links').select('id').where('sanction_id', '=', s.id).limit(1).executeTakeFirst();
        if (used) throw conflict('Spending is linked to this sanction. Remove the links first.', 'HAS_SPENDING');
      }
      await tx.updateTable('fund_sanctions').set({ status: 'cancelled', decision_note: b.note ?? s.decision_note }).where('id', '=', s.id).execute();
      await writeAudit(tx, auditOf(ctx), 'fund_sanction', s.id, 'cancel', { status: s.status }, { status: 'cancelled' });
      return (await sanctionRows(tx, ctx, { id: s.id }))[0]!;
    });
  });

  // ---- spending links
  const SOURCE_TABLE = { purchase: 'purchases', expense: 'expenses', payment: 'payments' } as const;
  async function sourceDoc(tx: Tx, ctx: RequestContext, type: keyof typeof SOURCE_TABLE, id: string) {
    const r = await sql<{ id: string; number: string; date: string; total: number; status: string; kind: string | null }>`
      select id, number, ${sql.raw(type === 'purchase' ? 'bill_date' : type === 'expense' ? 'expense_date' : 'payment_date')}::text as date,
             ${sql.raw(type === 'payment' ? 'amount' : 'total')}::float8 as total, status, ${sql.raw(type === 'payment' ? 'kind' : 'null')} as kind
      from ${sql.table(SOURCE_TABLE[type])} where id = ${id} and company_id = ${ctx.companyId}`.execute(tx);
    return r.rows[0];
  }
  app.get('/funds/links', async (req) => {
    const ctx = req.ctx; viewFunds(ctx);
    const q = parse(z.object({ headId: z.uuid().optional(), fundId: z.uuid().optional(), sanctionId: z.uuid().optional() }), req.query);
    return ctx.tx(async (tx) => {
      const links = (await loadLinks(tx, ctx)).filter((l) => (!q.headId || l.head_id === q.headId) && (!q.fundId || l.fund_id === q.fundId) && (!q.sanctionId || l.sanction_id === q.sanctionId));
      const heads = new Map((await tx.selectFrom('budget_heads').select(['id', 'code', 'name']).where('company_id', '=', ctx.companyId).execute()).map((h) => [h.id, h]));
      const funds = new Map((await tx.selectFrom('funds').select(['id', 'name']).where('company_id', '=', ctx.companyId).execute()).map((f) => [f.id, f.name]));
      return {
        data: links.sort((a, b) => (b.date ?? '').localeCompare(a.date ?? '')).slice(0, 300).map((l) => ({
          id: l.id, sourceType: l.source_type, sourceId: l.source_id, number: l.number, date: l.date, amount: l.amount, note: l.note, sanctionId: l.sanction_id,
          head: { id: l.head_id, code: heads.get(l.head_id)?.code, name: heads.get(l.head_id)?.name }, fund: { id: l.fund_id, name: funds.get(l.fund_id) },
        })),
      };
    });
  });
  app.get('/funds/spendable', async (req) => {
    const ctx = req.ctx; entryFunds(ctx);
    const q = parse(z.object({ type: z.enum(['purchase', 'expense', 'payment']), q: z.string().trim().max(60).optional() }), req.query);
    return ctx.tx(async (tx) => {
      const term = q.q ? `%${q.q.replace(/[\\%_]/g, (c) => `\\${c}`)}%` : '%';
      const tbl = q.type === 'purchase'
        ? sql`select t.id, t.number, t.bill_date::text as date, t.total::float8 as total, p.name as who, coalesce(t.notes, '') as what from purchases t join parties p on p.id = t.party_id where t.status = 'posted'`
        : q.type === 'expense'
          ? sql`select t.id, t.number, t.expense_date::text as date, t.total::float8 as total, coalesce(p.name, '') as who, t.description as what from expenses t left join parties p on p.id = t.party_id where t.status = 'posted'`
          : sql`select t.id, t.number, t.payment_date::text as date, t.amount::float8 as total, p.name as who, coalesce(t.reference, '') as what from payments t join parties p on p.id = t.party_id where t.status = 'posted' and t.kind = 'payment'`;
      const rows = await sql<{ id: string; number: string; date: string; total: number; who: string; what: string }>`
        select * from (${tbl} and t.company_id = ${ctx.companyId}) x where x.number ilike ${term} or x.who ilike ${term} or x.what ilike ${term}
        order by x.date desc, x.number desc limit 100`.execute(tx);
      const linked = new Map<string, number>();
      for (const l of await loadLinks(tx, ctx)) if (l.source_type === q.type) linked.set(l.source_id, round2((linked.get(l.source_id) ?? 0) + l.amount));
      return {
        data: rows.rows.map((r) => ({ sourceType: q.type, sourceId: r.id, number: r.number, date: r.date, total: r.total, who: r.who, what: r.what, linked: linked.get(r.id) ?? 0, remaining: round2(r.total - (linked.get(r.id) ?? 0)) }))
          .filter((r) => r.remaining > 0.004).slice(0, 50),
      };
    });
  });
  app.post('/funds/links', async (req, reply) => {
    const ctx = req.ctx; entryFunds(ctx);
    const b = parse(linkCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      const head = await assertLeaf(tx, ctx, b.headId);
      const fund = await loadFund(tx, ctx, b.fundId);
      if (fund.status !== 'active') throw conflict('This fund is closed.', 'FUND_CLOSED');
      const doc = await sourceDoc(tx, ctx, b.sourceType, b.sourceId);
      if (!doc) throw notFound('Document');
      if (doc.status !== 'posted') throw badRequest('This document is cancelled.', { sourceId: 'Cancelled' });
      if (b.sourceType === 'payment' && doc.kind !== 'payment') throw badRequest('Link payments made to vendors, not receipts.', { sourceId: 'Not a payment' });
      // A bill and its own payment are the same spending: link one of them.
      if (b.sourceType === 'payment') {
        const hit = await sql`select 1 from payment_allocations a join fund_links l on l.source_type = 'purchase' and l.source_id = a.doc_id where a.payment_id = ${b.sourceId} and a.doc_type = 'purchase' limit 1`.execute(tx);
        if (hit.rows.length) throw conflict('The bill this payment settles is already linked. Link the bill or the payment, not both.', 'DOUBLE_COUNT');
      } else if (b.sourceType === 'purchase') {
        const hit = await sql`select 1 from payment_allocations a join fund_links l on l.source_type = 'payment' and l.source_id = a.payment_id where a.doc_id = ${b.sourceId} and a.doc_type = 'purchase' limit 1`.execute(tx);
        if (hit.rows.length) throw conflict('A payment for this bill is already linked. Link the bill or the payment, not both.', 'DOUBLE_COUNT');
      }
      const links = await loadLinks(tx, ctx);
      const already = round2(links.filter((l) => l.source_type === b.sourceType && l.source_id === b.sourceId).reduce((s, l) => s + l.amount, 0));
      const remaining = round2(doc.total - already);
      const amount = b.amount ?? remaining;
      if (amount <= 0 || amount > remaining + 0.001) throw badRequest(`Only ${remaining.toFixed(2)} of ${doc.number} is not linked yet.`, { amount: `At most ${remaining.toFixed(2)}` });
      let covered = 0;
      if (b.sanctionId) {
        const s = (await sanctionCommitments(tx, ctx, links)).find((c) => c.id === b.sanctionId);
        const row = await tx.selectFrom('fund_sanctions').select(['head_id', 'fund_id', 'status']).where('id', '=', b.sanctionId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!row || row.status !== 'approved' || !s) throw badRequest('Choose an approved sanction.', { sanctionId: 'Not approved' });
        if (row.head_id !== head.id || row.fund_id !== fund.id) throw badRequest('The sanction is for a different head or fund.', { sanctionId: 'Different head or fund' });
        if (amount > s.remaining + 0.001) throw badRequest(`The sanction has only ${s.remaining.toFixed(2)} left.`, { amount: `At most ${s.remaining.toFixed(2)}` });
        covered = amount;
      }
      const extra = round2(amount - covered);
      const warnings = extra > 0 ? await exposureWarnings(tx, ctx, head, fund.id, extra, extra, links) : [];
      const row = await tx.insertInto('fund_links').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, source_type: b.sourceType, source_id: b.sourceId, head_id: head.id, fund_id: fund.id,
        sanction_id: b.sanctionId ?? null, amount, note: b.note ?? null, created_by: ctx.userId,
      }).returning('id').onConflict((oc) => oc.doNothing()).executeTakeFirst();
      if (!row) throw conflict('This document is already linked to that head and fund.', 'ALREADY_LINKED');
      if (fund.return_unspent) {
        const liability = await ensureAccount(tx, ctx, 'Grants Refundable (Unspent)', 'liability', 2800);
        const income = fund.income_account_id ?? await ensureAccount(tx, ctx, 'Grants Received', 'income', 4800);
        await postJournal(tx, auditOf(ctx), {
          date: todayIst(), voucherType: 'journal', voucherId: row.id, number: doc.number,
          narration: `Grant used for ${fund.name}: ${doc.number}`,
          lines: [{ accountId: liability, amount }, { accountId: income, amount: -amount }],
        });
      }
      await writeAudit(tx, auditOf(ctx), 'fund_link', row.id, 'create', null, { type: b.sourceType, number: doc.number, head: head.code, fund: fund.name, amount, warnings });
      return { id: row.id, sourceType: b.sourceType, number: doc.number, amount, headId: head.id, fundId: fund.id, sanctionId: b.sanctionId ?? null, warnings };
    });
    return reply.status(201).send(out);
  });
  app.delete<{ Params: { id: string } }>('/funds/links/:id', async (req) => {
    const ctx = req.ctx; entryFunds(ctx);
    return ctx.tx(async (tx) => {
      const l = await tx.selectFrom('fund_links').selectAll().where('id', '=', req.params.id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!l) throw notFound('Link');
      await reverseVoucher(tx, auditOf(ctx), l.id, todayIst(), 'Fund link removed');
      await tx.deleteFrom('fund_links').where('id', '=', l.id).execute();
      await writeAudit(tx, auditOf(ctx), 'fund_link', l.id, 'delete', { type: l.source_type, amount: Number(l.amount) }, null);
      return { ok: true };
    });
  });

  // ---- home and reports
  app.get('/funds/home', async (req) => {
    const ctx = req.ctx; viewFunds(ctx);
    const { fy = financialYear(todayIst()) } = parse(fyQuery, req.query);
    return ctx.tx(async (tx) => {
      const links = await loadLinks(tx, ctx);
      const heads = await computeHeads(tx, ctx, fy, links);
      const majors = heads.filter((h) => !h.parentId);
      const sum = (f: (h: HeadOut) => number) => round2(majors.reduce((s, h) => s + f(h), 0));
      const totals = await fundTotals(tx, ctx, links);
      const funds = (await tx.selectFrom('funds').selectAll().where('company_id', '=', ctx.companyId).where('status', '=', 'active').orderBy('name').execute()).map((f) => fundJson(f, totals.get(f.id)));
      const pending = await sanctionRows(tx, ctx, { status: 'pending', limit: 10 });
      const pr = await tx.selectFrom('budget_reappropriations').select((eb) => eb.fn.countAll<number>().as('n')).where('company_id', '=', ctx.companyId).where('status', '=', 'pending').executeTakeFirstOrThrow();
      const settings = await loadSettings(tx, ctx);
      return {
        fy, heads: majors, funds, pendingSanctions: pending, pendingReappropriations: Number(pr.n), overspendMode: settings.overspendMode,
        totals: { budget: sum((h) => h.budget), actual: sum((h) => h.actual), committed: sum((h) => h.committed), available: sum((h) => h.available) },
      };
    });
  });
  app.get('/funds/reports/budget-vs-actual', async (req) => {
    const ctx = req.ctx; viewFunds(ctx);
    const { fy = financialYear(todayIst()) } = parse(fyQuery, req.query);
    return ctx.tx(async (tx) => {
      const data = await computeHeads(tx, ctx, fy);
      const top = data.filter((h) => !h.parentId);
      const sum = (f: (h: HeadOut) => number) => round2(top.reduce((s, h) => s + f(h), 0));
      const budget = sum((h) => h.budget), actual = sum((h) => h.actual);
      return { fy, data, totals: { budget, actual, committed: sum((h) => h.committed), available: sum((h) => h.available), percentUsed: budget > 0 ? Math.round((actual / budget) * 1000) / 10 : 0 } };
    });
  });
  async function periodFigures(tx: Tx, ctx: RequestContext, fundId: string | null, from: string, to: string) {
    const links = (await loadLinks(tx, ctx)).filter((l) => !fundId || l.fund_id === fundId);
    const rec = await tx.selectFrom('fund_receipts').select(['id', 'fund_id', 'number', 'receipt_date as date', 'amount']).where('company_id', '=', ctx.companyId).where('status', '=', 'posted')
      .$if(!!fundId, (q) => q.where('fund_id', '=', fundId!)).execute();
    const don = await tx.selectFrom('donations').select(['id', 'fund_id', 'receipt_no as number', 'donation_date as date', 'amount']).where('company_id', '=', ctx.companyId).where('status', '=', 'posted')
      .where('fund_id', 'is not', null).$if(!!fundId, (q) => q.where('fund_id', '=', fundId!)).execute();
    const received = [...rec.map((r) => ({ ...r, source: 'grant' })), ...don.map((r) => ({ ...r, source: 'donation' }))].map((r) => ({ id: r.id, fundId: r.fund_id!, number: r.number, date: r.date, amount: Number(r.amount), source: r.source }));
    const before = (d: string | null) => (d ?? '') < from, within = (d: string | null) => (d ?? '') >= from && (d ?? '') <= to;
    return {
      links, received,
      openingReceived: round2(received.filter((r) => before(r.date)).reduce((s, r) => s + r.amount, 0)),
      openingSpent: round2(links.filter((l) => before(l.date)).reduce((s, l) => s + l.amount, 0)),
      periodReceived: received.filter((r) => within(r.date)), periodLinks: links.filter((l) => within(l.date)),
    };
  }
  app.get('/funds/reports/fund-wise', async (req) => {
    const ctx = req.ctx; viewFunds(ctx);
    const q = parse(rangeQuery, req.query);
    const from = q.from ?? `${financialYear(todayIst()).slice(0, 4)}-04-01`, to = q.to ?? todayIst();
    return ctx.tx(async (tx) => {
      const fig = await periodFigures(tx, ctx, null, from, to);
      const funds = await tx.selectFrom('funds').selectAll().where('company_id', '=', ctx.companyId).orderBy('name').execute();
      const data = funds.map((f) => {
        const opening = round2(fig.received.filter((r) => r.fundId === f.id && r.date < from).reduce((s, r) => s + r.amount, 0) - fig.links.filter((l) => l.fund_id === f.id && (l.date ?? '') < from).reduce((s, l) => s + l.amount, 0));
        const received = round2(fig.periodReceived.filter((r) => r.fundId === f.id).reduce((s, r) => s + r.amount, 0));
        const spent = round2(fig.periodLinks.filter((l) => l.fund_id === f.id).reduce((s, l) => s + l.amount, 0));
        return { fundId: f.id, name: f.name, kind: f.kind, totalAmount: Number(f.total_amount), opening, received, spent, closing: round2(opening + received - spent) };
      });
      const sum = (k: 'opening' | 'received' | 'spent' | 'closing') => round2(data.reduce((s, r) => s + r[k], 0));
      return { from, to, data, totals: { opening: sum('opening'), received: sum('received'), spent: sum('spent'), closing: sum('closing') } };
    });
  });
  app.get<{ Params: { id: string } }>('/funds/funds/:id/utilisation', async (req) => {
    const ctx = req.ctx; viewFunds(ctx);
    const q = parse(rangeQuery, req.query);
    return ctx.tx(async (tx) => {
      const fund = await loadFund(tx, ctx, req.params.id);
      const from = q.from ?? fund.period_from ?? `${financialYear(todayIst()).slice(0, 4)}-04-01`, to = q.to ?? fund.period_to ?? todayIst();
      const fig = await periodFigures(tx, ctx, fund.id, from, to);
      const heads = await tx.selectFrom('budget_heads').select(['id', 'code', 'name']).where('company_id', '=', ctx.companyId).execute();
      const byHead = new Map<string, number>();
      for (const l of fig.periodLinks) byHead.set(l.head_id, round2((byHead.get(l.head_id) ?? 0) + l.amount));
      const spentByHead = [...byHead].map(([id, amount]) => ({ headId: id, code: heads.find((h) => h.id === id)?.code ?? '', name: heads.find((h) => h.id === id)?.name ?? '', amount }))
        .sort((a, b) => a.code.localeCompare(b.code));
      const opening = round2(fig.openingReceived - fig.openingSpent);
      const received = round2(fig.periodReceived.reduce((s, r) => s + r.amount, 0));
      const spent = round2(spentByHead.reduce((s, r) => s + r.amount, 0));
      const closing = round2(opening + received - spent);
      const company = await tx.selectFrom('companies').select(['name', 'legal_name', 'address', 'gstin']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      return {
        fund: fundJson(fund), company: { name: company.legal_name || company.name, address: company.address }, from, to,
        opening, received, receipts: fig.periodReceived.sort((a, b) => a.date.localeCompare(b.date)), spentByHead, spent, closing,
        returnUnspent: fund.return_unspent, refundDue: fund.return_unspent && closing > 0 ? closing : 0,
      };
    });
  });
}

documentRoute('PUT', '/funds/settings', { body: settingsBody });
documentRoute('PATCH', '/funds/settings', { body: settingsBody });
documentRoute('POST', '/funds/funds', { body: fundCreate });
documentRoute('PATCH', '/funds/funds/:id', { body: fundPatch });
documentRoute('POST', '/funds/funds/:id/receipts', { body: receiptCreate });
documentRoute('POST', '/funds/heads', { body: headCreate });
documentRoute('PATCH', '/funds/heads/:id', { body: headPatch });
documentRoute('POST', '/funds/reappropriations', { body: reappCreate });
documentRoute('POST', '/funds/sanctions', { body: sanctionCreate });
documentRoute('POST', '/funds/sanctions/:id/approve', { body: sanctionApprove });
documentRoute('POST', '/funds/sanctions/:id/reject', { body: noteBody });
documentRoute('POST', '/funds/sanctions/:id/cancel', { body: noteBody });
documentRoute('POST', '/funds/links', { body: linkCreate });
