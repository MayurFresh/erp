import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { buildCashFlow, CF_CATEGORIES, defaultCategory, isCash, loadAccounts, loadCfMapping, type CfCategory } from '../accounting/cashflow.ts';
import { postJournal, reverseEntry } from '../accounting/journal.ts';
import { buildRatios } from '../accounting/ratios.ts';
import { accountTotals, profitLoss } from '../accounting/statements.ts';
import { financialYear, fyStart, isValidDate, todayIst } from '../lib/dates.ts';
import { conflict, badRequest, notFound } from '../lib/errors.ts';
import { documentRoute } from '../lib/openapi.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const periodQuery = z.object({ from: dateField.optional(), to: dateField.optional(), compare: z.enum(['true', 'false']).optional() });
const fyField = z.string().regex(/^\d{4}-\d{2}$/, 'Use a year such as 2026-27').refine((v) => (Number(v.slice(0, 4)) + 1) % 100 === Number(v.slice(5)), 'Not a financial year');

const yearBack = (d: string) => `${Number(d.slice(0, 4)) - 1}${d.slice(4)}`;
const fyEnd = (fy: string) => `${Number(fy.slice(0, 4)) + 1}-03-31`;

function period(q: z.infer<typeof periodQuery>) {
  const to = q.to ?? todayIst();
  const from = q.from ?? fyStart(to);
  if (from > to) throw badRequest('From date is after the to date.', { from: 'After to date' });
  return { from, to, compare: q.compare === 'true' };
}

const closeJson = (r: { id: string; fy: string; close_date: string; profit: number; equity_account_id: string; status: string; entry_id: string; previous_lock: string | null; closed_at: Date; reopened_at: Date | null }, name = '') => ({
  id: r.id, fy: r.fy, closeDate: r.close_date, profit: r.profit, equityAccountId: r.equity_account_id, equityAccountName: name,
  status: r.status, entryId: r.entry_id, previousLock: r.previous_lock, closedAt: r.closed_at, reopenedAt: r.reopened_at,
});

export async function financeReportRoutes(app: FastifyInstance) {
  app.get('/reports/cash-flow', async (req) => {
    const ctx = req.ctx;
    ctx.require('finreports.view');
    const p = period(parse(periodQuery, req.query));
    return ctx.tx(async (tx) => {
      await systemAccounts(tx, ctx);
      const mapping = await loadCfMapping(tx, ctx.companyId);
      const current = await buildCashFlow(tx, ctx.companyId, p.from, p.to, mapping);
      const previous = p.compare ? await buildCashFlow(tx, ctx.companyId, yearBack(p.from), yearBack(p.to), mapping) : null;
      return { from: p.from, to: p.to, current, previous };
    });
  });

  app.get('/reports/ratios', async (req) => {
    const ctx = req.ctx;
    ctx.require('finreports.view');
    const p = period(parse(periodQuery, req.query));
    return ctx.tx(async (tx) => {
      await systemAccounts(tx, ctx);
      const mapping = await loadCfMapping(tx, ctx.companyId);
      const current = await buildRatios(tx, ctx.companyId, p.from, p.to, mapping);
      const previous = p.compare ? await buildRatios(tx, ctx.companyId, yearBack(p.from), yearBack(p.to), mapping) : null;
      return { current, previous };
    });
  });

  app.get('/cash-flow/mapping', async (req) => {
    const ctx = req.ctx;
    ctx.require('finreports.view');
    return ctx.tx(async (tx) => {
      await systemAccounts(tx, ctx);
      const mapping = await loadCfMapping(tx, ctx.companyId);
      const rows = (await loadAccounts(tx, ctx.companyId)).filter((a) => a.type !== 'income' && a.type !== 'expense' && !isCash(a));
      return {
        data: rows.map((a) => {
          const d = defaultCategory(a);
          return { accountId: a.id, code: a.code, name: a.name, type: a.type, subtype: a.subtype, defaultCategory: d, category: mapping.get(a.id) ?? null, effective: mapping.get(a.id) ?? d };
        }),
      };
    });
  });

  const mapBody = z.object({ category: z.enum(CF_CATEGORIES as [CfCategory, ...CfCategory[]]).nullable() });
  const setMapping = async (req: { ctx: import('../auth/context.ts').RequestContext; params: unknown; body: unknown }) => {
    const ctx = req.ctx;
    ctx.require('finreports.manage');
    const accountId = parse(z.uuid(), (req.params as { accountId: string }).accountId);
    const { category } = parse(mapBody, req.body);
    return ctx.tx(async (tx) => {
      const a = await tx.selectFrom('accounts').select(['id', 'type', 'subtype']).where('id', '=', accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!a) throw notFound('Account');
      if (a.type === 'income' || a.type === 'expense' || a.subtype === 'cash' || a.subtype === 'bank') {
        throw badRequest('Only balance sheet accounts other than cash and bank can be mapped.', { accountId: 'Not mappable' });
      }
      if (category === null) {
        await tx.deleteFrom('cf_mappings').where('company_id', '=', ctx.companyId).where('account_id', '=', accountId).execute();
      } else {
        await tx.insertInto('cf_mappings').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, account_id: accountId, category })
          .onConflict((oc) => oc.columns(['company_id', 'account_id']).doUpdateSet({ category })).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'cash_flow_mapping', accountId, 'update', null, { category });
      return { accountId, category };
    });
  };
  app.put<{ Params: { accountId: string } }>('/cash-flow/mapping/:accountId', (req) => setMapping(req as never));
  app.patch<{ Params: { accountId: string } }>('/cash-flow/mapping/:accountId', (req) => setMapping(req as never));

  // ---- Year-end close ----
  async function plan(tx: import('../db/database.ts').Tx, ctx: import('../auth/context.ts').RequestContext, fy: string, equityAccountId?: string) {
    const from = `${fy.slice(0, 4)}-04-01`;
    const to = fyEnd(fy);
    const totals = (await accountTotals(tx, ctx.companyId, from, to)).filter((t) => (t.type === 'income' || t.type === 'expense') && Math.abs(t.d - t.c) >= 0.005);
    const pl = profitLoss(totals);
    const income = round2(pl.revenue.total + pl.otherIncome.total);
    const expenses = round2(pl.cogs.total + pl.expenses.total);
    const profit = round2(income - expenses);
    let equity = equityAccountId
      ? await tx.selectFrom('accounts').select(['id', 'name', 'type']).where('id', '=', equityAccountId).where('company_id', '=', ctx.companyId).executeTakeFirst()
      : await tx.selectFrom('accounts').select(['id', 'name', 'type']).where('company_id', '=', ctx.companyId).where('code', '=', '3200').where('type', '=', 'equity').executeTakeFirst();
    if (equityAccountId && (!equity || equity.type !== 'equity')) throw badRequest('Choose an equity account.', { equityAccountId: 'Not an equity account' });
    const company = await tx.selectFrom('companies').select('books_locked_until').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
    const closed = await tx.selectFrom('year_end_closes').select('id').where('company_id', '=', ctx.companyId).where('fy', '=', fy).where('status', '=', 'closed').executeTakeFirst();
    const blockers: string[] = [];
    if (to > todayIst()) blockers.push(`The year ends on ${to}. Close it after that date.`);
    if (closed) blockers.push('This year is already closed. Reopen it first if it needs changes.');
    if (company.books_locked_until && company.books_locked_until >= to && !closed) blockers.push(`Books are already locked up to ${company.books_locked_until}. Lower the lock below ${to} first.`);
    return {
      fy, from, to, totals, income, expenses, profit, equity, locked: company.books_locked_until, closed: !!closed, blockers,
      steps: [
        `Zero each income and expense account for ${from} to ${to} with one journal dated ${to}.`,
        `Move the ${profit >= 0 ? 'profit' : 'loss'} of Rs ${Math.abs(profit).toFixed(2)} to ${equity?.name ?? 'Retained Earnings'}.`,
        `Lock the books up to ${to}, so nothing can be posted in the year afterwards. An owner can reopen it while the next year has no lock.`,
        'Balance sheet accounts carry forward on their own. Reports for the year still show its profit.',
      ],
    };
  }

  app.get('/year-end/closes', async (req) => {
    const ctx = req.ctx;
    ctx.require('books.lock');
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('year_end_closes as c').innerJoin('accounts as a', 'a.id', 'c.equity_account_id')
        .selectAll('c').select('a.name as equity_name').where('c.company_id', '=', ctx.companyId).orderBy('c.close_date', 'desc').orderBy('c.closed_at', 'desc').execute();
      return { data: rows.map((r) => closeJson(r, r.equity_name)) };
    });
  });

  app.get('/year-end/preview', async (req) => {
    const ctx = req.ctx;
    ctx.require('books.lock');
    const q = parse(z.object({ fy: fyField.optional(), equityAccountId: z.uuid().optional() }), req.query);
    const fy = q.fy ?? financialYear(todayIst());
    return ctx.tx(async (tx) => {
      await systemAccounts(tx, ctx);
      const p = await plan(tx, ctx, fy, q.equityAccountId);
      return {
        fy, from: p.from, to: p.to, income: p.income, expenses: p.expenses, profit: p.profit,
        equityAccountId: p.equity?.id ?? null, equityAccountName: p.equity?.name ?? 'Retained Earnings',
        willCreateEquityAccount: !p.equity, closed: p.closed, canClose: p.blockers.length === 0, blockers: p.blockers, steps: p.steps,
      };
    });
  });

  app.post('/year-end/close', async (req) => {
    const ctx = req.ctx;
    ctx.require('books.lock');
    const body = parse(z.object({ fy: fyField, equityAccountId: z.uuid().optional() }), req.body);
    return ctx.tx(async (tx) => {
      await tx.selectFrom('companies').select('id').where('id', '=', ctx.companyId).forUpdate().execute();
      await systemAccounts(tx, ctx);
      const p = await plan(tx, ctx, body.fy, body.equityAccountId);
      if (p.blockers.length) throw conflict(p.blockers[0]!, 'YEAR_END_BLOCKED', { blockers: p.blockers });
      let equityId = p.equity?.id;
      if (!equityId) {
        const row = await tx.insertInto('accounts').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, code: '3200', name: 'Retained Earnings', type: 'equity', subtype: 'other', system_key: null, is_system: false,
        }).onConflict((oc) => oc.doNothing()).returning('id').executeTakeFirst();
        equityId = row?.id ?? (await tx.selectFrom('accounts').select('id').where('company_id', '=', ctx.companyId).where('code', '=', '3200').executeTakeFirstOrThrow()).id;
      }
      const lines = p.totals.map((t) => ({ accountId: t.id, amount: -round2(t.d - t.c) }));
      const sum = Math.round(lines.reduce((s, l) => s + l.amount * 100, 0));
      lines.push({ accountId: equityId, amount: -sum / 100 });
      const number = await nextNumber(tx, ctx, 'journal', financialYear(p.to));
      if (!p.totals.length) throw conflict('Nothing to close: the year has no income or expense entries.', 'YEAR_END_BLOCKED');
      const entryId = await postJournal(tx, auditOf(ctx), {
        date: p.to, voucherType: 'closing', voucherId: null, number,
        narration: `Year-end close ${body.fy}: profit and loss moved to equity`, lines,
      });
      const row = await tx.insertInto('year_end_closes').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, fy: body.fy, close_date: p.to, entry_id: entryId, profit: p.profit,
        equity_account_id: equityId, previous_lock: p.locked, closed_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await tx.updateTable('companies').set({ books_locked_until: p.to }).where('id', '=', ctx.companyId).execute();
      await writeAudit(tx, auditOf(ctx), 'year_end', row.id, 'create', null, { fy: body.fy, profit: p.profit });
      const name = (await tx.selectFrom('accounts').select('name').where('id', '=', equityId).executeTakeFirstOrThrow()).name;
      return closeJson(row, name);
    });
  });

  app.post<{ Params: { id: string } }>('/year-end/:id/reopen', async (req) => {
    const ctx = req.ctx;
    ctx.require('books.lock');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const company = await tx.selectFrom('companies').select('books_locked_until').where('id', '=', ctx.companyId).forUpdate().executeTakeFirstOrThrow();
      const c = await tx.selectFrom('year_end_closes').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!c) throw notFound('Year-end close');
      if (c.status !== 'closed') throw conflict('This close was already reopened.', 'YEAR_END_BLOCKED');
      if (company.books_locked_until && company.books_locked_until > c.close_date) {
        throw conflict(`The books are locked up to ${company.books_locked_until}, which is past this year. Unlock the later period first.`, 'YEAR_END_BLOCKED');
      }
      await tx.updateTable('companies').set({ books_locked_until: c.previous_lock }).where('id', '=', ctx.companyId).execute();
      await reverseEntry(tx, auditOf(ctx), c.entry_id, c.close_date, `Reopened year ${c.fy}`);
      const row = await tx.updateTable('year_end_closes').set({ status: 'reopened', reopened_at: new Date(), reopened_by: ctx.userId })
        .where('id', '=', id).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'year_end', id, 'update', { status: 'closed' }, { status: 'reopened' });
      const name = (await tx.selectFrom('accounts').select('name').where('id', '=', c.equity_account_id).executeTakeFirstOrThrow()).name;
      return closeJson(row, name);
    });
  });
}

documentRoute('POST', '/year-end/close', { summary: 'Close a financial year', body: z.object({ fy: z.string(), equityAccountId: z.uuid().optional() }) });
