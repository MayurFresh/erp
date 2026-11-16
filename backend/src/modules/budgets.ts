import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, todayIst } from '../lib/dates.ts';
import { badRequest, conflict } from '../lib/errors.ts';
import { moneyField } from '../lib/numbers.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const fyField = z.string().regex(/^\d{4}-\d{2}$/, 'Use a year such as 2026-27').refine((v) => (Number(v.slice(0, 4)) + 1) % 100 === Number(v.slice(5)), 'Not a financial year');
const monthField = z.string().regex(/^\d{4}-\d{2}$/, 'Use YYYY-MM');

/** The twelve months of a financial year, April first, as YYYY-MM. */
export function fyMonths(fy: string): string[] {
  const y = Number(fy.slice(0, 4));
  return Array.from({ length: 12 }, (_, i) => { const m = ((i + 3) % 12) + 1; return `${m >= 4 ? y : y + 1}-${String(m).padStart(2, '0')}`; });
}
const lastDay = (ym: string) => new Date(Date.UTC(Number(ym.slice(0, 4)), Number(ym.slice(5)), 0)).toISOString().slice(0, 10);

const putBody = z.object({
  fy: fyField,
  rows: z.array(z.object({
    accountId: z.uuid(), costCentreId: z.uuid().nullable().optional(),
    months: z.record(monthField, moneyField),
  })).max(500),
});
const copyBody = z.object({
  fromFy: fyField, toFy: fyField, upliftPercent: z.coerce.number().min(-50).max(500).optional(), replace: z.boolean().optional(),
});

async function loadBudget(tx: Tx, companyId: string, fy: string, costCentreId?: string) {
  let q = tx.selectFrom('budgets as b').innerJoin('accounts as a', 'a.id', 'b.account_id')
    .leftJoin('cost_centres as c', 'c.id', 'b.cost_centre_id')
    .select(['b.account_id', 'b.cost_centre_id', 'b.month', 'b.amount', 'a.code', 'a.name', 'a.type', 'c.name as cc_name'])
    .where('b.company_id', '=', companyId).where('b.fy', '=', fy);
  if (costCentreId) q = q.where('b.cost_centre_id', '=', costCentreId);
  const rows = await q.orderBy('a.code').execute();
  const map = new Map<string, { accountId: string; code: string; name: string; type: string; costCentreId: string | null; costCentreName: string | null; months: Record<string, number>; total: number }>();
  for (const r of rows) {
    const key = `${r.account_id}|${r.cost_centre_id ?? ''}`;
    if (!map.has(key)) map.set(key, { accountId: r.account_id, code: r.code, name: r.name, type: r.type, costCentreId: r.cost_centre_id, costCentreName: r.cc_name, months: {}, total: 0 });
    const e = map.get(key)!;
    const ym = String(r.month).slice(0, 7);
    e.months[ym] = r.amount;
    e.total = round2(e.total + r.amount);
  }
  return [...map.values()];
}

/** Actual per account and cost centre per month across a year, leaving out closing entries. */
async function loadActuals(tx: Tx, companyId: string, fy: string, upTo: string) {
  const start = `${fy.slice(0, 4)}-04-01`;
  const rows = await tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .innerJoin('accounts as a', 'a.id', 'jl.account_id')
    .select((eb) => ['jl.account_id', 'jl.cost_centre_id', 'a.type', eb.fn.sum<number>('jl.debit').as('d'), eb.fn.sum<number>('jl.credit').as('c'),
      sql<string>`to_char(je.entry_date, 'YYYY-MM')`.as('ym')])
    .where('je.company_id', '=', companyId).where('je.entry_date', '>=', start).where('je.entry_date', '<=', upTo)
    .where('je.voucher_type', '<>', 'closing').where('a.type', 'in', ['income', 'expense'])
    .groupBy(['jl.account_id', 'jl.cost_centre_id', 'a.type', sql`to_char(je.entry_date, 'YYYY-MM')`]).execute();
  return rows.map((r) => ({ accountId: r.account_id, ccId: r.cost_centre_id, ym: String(r.ym), amount: Number(r.type === 'expense' ? Number(r.d) - Number(r.c) : Number(r.c) - Number(r.d)) }));
}

const level = (pct: number | null): 'ok' | 'warn' | 'over' => (pct === null ? 'ok' : pct > 100 ? 'over' : pct >= 90 ? 'warn' : 'ok');
const figures = (budget: number, actual: number) => ({
  budget: round2(budget), actual: round2(actual), variance: round2(actual - budget),
  percentUsed: budget > 0 ? round2((actual / budget) * 100) : null,
});

export async function budgetRoutes(app: FastifyInstance) {
  app.get('/budgets', async (req) => {
    const ctx = req.ctx;
    ctx.require('finreports.view');
    const q = parse(z.object({ fy: fyField.optional(), costCentreId: z.uuid().optional() }), req.query);
    const fy = q.fy ?? financialYear(todayIst());
    return ctx.tx(async (tx) => ({ fy, data: await loadBudget(tx, ctx.companyId, fy, q.costCentreId) }));
  });

  const saveBudgets = async (req: { ctx: RequestContext; body: unknown }) => {
    const ctx = req.ctx;
    ctx.require('finreports.manage');
    const body = parse(putBody, req.body);
    const valid = new Set(fyMonths(body.fy));
    return ctx.tx(async (tx) => {
      const ids = [...new Set(body.rows.map((r) => r.accountId))];
      const accounts = ids.length ? await tx.selectFrom('accounts').select(['id', 'type']).where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute() : [];
      const ccIds = [...new Set(body.rows.map((r) => r.costCentreId).filter((x): x is string => !!x))];
      const ccs = ccIds.length ? await tx.selectFrom('cost_centres').select('id').where('company_id', '=', ctx.companyId).where('id', 'in', ccIds).execute() : [];
      let written = 0;
      for (const [i, r] of body.rows.entries()) {
        const a = accounts.find((x) => x.id === r.accountId);
        if (!a || (a.type !== 'income' && a.type !== 'expense')) throw badRequest(`Row ${i + 1}: budgets are for income and expense accounts.`, { [`rows.${i}.accountId`]: 'Not allowed' });
        if (r.costCentreId && !ccs.some((c) => c.id === r.costCentreId)) throw badRequest(`Row ${i + 1}: cost centre not found.`, { [`rows.${i}.costCentreId`]: 'Not found' });
        for (const m of Object.keys(r.months)) if (!valid.has(m)) throw badRequest(`Row ${i + 1}: ${m} is not in ${body.fy}.`, { [`rows.${i}.months`]: 'Outside the year' });
        const cc = r.costCentreId ?? null;
        // Replace this row's months wholesale.
        let del = tx.deleteFrom('budgets').where('company_id', '=', ctx.companyId).where('fy', '=', body.fy).where('account_id', '=', r.accountId);
        del = cc ? del.where('cost_centre_id', '=', cc) : del.where('cost_centre_id', 'is', null);
        await del.execute();
        const vals = Object.entries(r.months).filter(([, v]) => v > 0).map(([m, v]) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, fy: body.fy, account_id: r.accountId, cost_centre_id: cc, month: `${m}-01`, amount: v,
        }));
        if (vals.length) await tx.insertInto('budgets').values(vals).execute();
        written += vals.length;
      }
      await writeAudit(tx, auditOf(ctx), 'budget', ctx.companyId, 'update', null, { fy: body.fy, rows: body.rows.length });
      return { fy: body.fy, written, data: await loadBudget(tx, ctx.companyId, body.fy) };
    });
  };
  app.put('/budgets', (req) => saveBudgets(req as never));
  app.patch('/budgets', (req) => saveBudgets(req as never));

  app.post('/budgets/copy', async (req) => {
    const ctx = req.ctx;
    ctx.require('finreports.manage');
    const body = parse(copyBody, req.body);
    if (body.fromFy === body.toFy) throw badRequest('Choose a different year to copy into.', { toFy: 'Same year' });
    const uplift = body.upliftPercent ?? 0;
    return ctx.tx(async (tx) => {
      const source = await tx.selectFrom('budgets').selectAll().where('company_id', '=', ctx.companyId).where('fy', '=', body.fromFy).execute();
      if (!source.length) throw badRequest(`There is no budget for ${body.fromFy}.`, { fromFy: 'No budget' });
      const existing = await tx.selectFrom('budgets').select('id').where('company_id', '=', ctx.companyId).where('fy', '=', body.toFy).limit(1).execute();
      if (existing.length && !body.replace) throw conflict(`${body.toFy} already has a budget. Choose replace to overwrite it.`, 'BUDGET_EXISTS');
      if (existing.length) await tx.deleteFrom('budgets').where('company_id', '=', ctx.companyId).where('fy', '=', body.toFy).execute();
      const shift = Number(body.toFy.slice(0, 4)) - Number(body.fromFy.slice(0, 4));
      const vals = source.map((s) => ({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, fy: body.toFy, account_id: s.account_id, cost_centre_id: s.cost_centre_id,
        month: `${Number(String(s.month).slice(0, 4)) + shift}${String(s.month).slice(4, 7)}-01`,
        amount: round2(s.amount * (1 + uplift / 100)),
      }));
      for (let i = 0; i < vals.length; i += 500) await tx.insertInto('budgets').values(vals.slice(i, i + 500)).execute();
      await writeAudit(tx, auditOf(ctx), 'budget', ctx.companyId, 'create', null, { fromFy: body.fromFy, toFy: body.toFy, uplift });
      return { copied: vals.length };
    });
  });

  app.get('/reports/budget-variance', async (req) => varianceHandler(req.ctx, req.query));
}

async function varianceHandler(ctx: RequestContext, query: unknown) {
  ctx.require('finreports.view');
  const q = parse(z.object({ fy: fyField.optional(), month: monthField.optional(), costCentreId: z.uuid().optional() }), query);
  const fy = q.fy ?? financialYear(todayIst());
  const months = fyMonths(fy);
  const wanted = q.month ?? todayIst().slice(0, 7);
  const month = wanted < months[0]! ? months[0]! : wanted > months[11]! ? months[11]! : wanted;
  return ctx.tx(async (tx) => {
    const budget = await loadBudget(tx, ctx.companyId, fy, q.costCentreId);
    const upTo = months.slice(0, months.indexOf(month) + 1);
    const actuals = await loadActuals(tx, ctx.companyId, fy, lastDay(month));
    const rows = budget.map((b) => {
      const mine = actuals.filter((a) => a.accountId === b.accountId && (b.costCentreId === null || a.ccId === b.costCentreId));
      const actualIn = (ms: string[]) => mine.filter((a) => ms.includes(a.ym)).reduce((s, a) => s + a.amount, 0);
      const budgetIn = (ms: string[]) => ms.reduce((s, m) => s + (b.months[m] ?? 0), 0);
      const m = figures(budgetIn([month]), actualIn([month]));
      const ytd = figures(budgetIn(upTo), actualIn(upTo));
      const worst = b.type === 'expense' ? [level(m.percentUsed), level(ytd.percentUsed)] : ['ok'];
      const status = worst.includes('over') ? 'over' : worst.includes('warn') ? 'warn' : b.total > 0 ? 'ok' : 'none';
      return { accountId: b.accountId, code: b.code, name: b.name, type: b.type, costCentreId: b.costCentreId, costCentreName: b.costCentreName, month: m, ytd, annualBudget: b.total, status };
    });
    const sum = (t: 'month' | 'ytd', type: string) => {
      const rs = rows.filter((r) => r.type === type);
      return figures(rs.reduce((s, r) => s + r[t].budget, 0), rs.reduce((s, r) => s + r[t].actual, 0));
    };
    const alerts = rows.filter((r) => r.type === 'expense').flatMap((r) => (['month', 'ytd'] as const).flatMap((scope) => {
      const l = level(r[scope].percentUsed);
      return l === 'ok' ? [] : [{ accountId: r.accountId, name: r.name, level: l, percentUsed: r[scope].percentUsed!, scope }];
    }));
    return {
      fy, month, rows,
      totals: { month: { expense: sum('month', 'expense'), income: sum('month', 'income') }, ytd: { expense: sum('ytd', 'expense'), income: sum('ytd', 'income') } },
      alerts,
    };
  });
}
