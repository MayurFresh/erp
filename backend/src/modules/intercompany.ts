import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal, reverseEntry } from '../accounting/journal.ts';
import {
  accountTotals, balanceSheet, profitLoss, trialBalance, type AccountTotal,
} from '../accounting/statements.ts';
import type { AppDeps } from '../app.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { fyStart, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { documentRoute } from '../lib/openapi.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const side = z.object({ companyId: z.uuid(), accountId: z.uuid() });
const createBody = z.object({
  date: dateField,
  amount: z.coerce.number().positive().max(9_999_999_999.99).transform(round2),
  narration: z.string().trim().min(3).max(300),
  from: side,
  to: side,
});
const listQuery = z.object({
  counterpartyId: z.uuid().optional(), from: dateField.optional(), to: dateField.optional(),
  status: z.enum(['posted', 'cancelled']).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50), offset: z.coerce.number().int().min(0).default(0),
});
const asOfQuery = z.object({ asOf: dateField.optional() });
const companyIdsQuery = z.object({
  companyIds: z.string().transform((s) => s.split(',').map((x) => x.trim()).filter(Boolean))
    .pipe(z.array(z.uuid()).min(2).max(20)).refine((a) => new Set(a).size === a.length, 'Duplicate company'),
});
const BLOCKED_SUBTYPES = ['receivables', 'payables', 'inventory'];

const canIn = (ctx: RequestContext, companyId: string, perm: string) =>
  ctx.memberships.find((m) => m.companyId === companyId)?.permissions.has(perm) ?? false;

async function loadEntry(tx: Tx, id: string) {
  const e = await tx.selectFrom('intercompany_entries').selectAll().where('id', '=', id).executeTakeFirst();
  if (!e) throw notFound('Inter-company entry');
  return e;
}

type EntryRow = Awaited<ReturnType<typeof loadEntry>>;

async function entryJson(tx: Tx, rows: EntryRow[]) {
  if (!rows.length) return [];
  const cos = await tx.selectFrom('companies').select(['id', 'name'])
    .where('id', 'in', [...new Set(rows.flatMap((r) => [r.from_company_id, r.to_company_id]))]).execute();
  const accs = await tx.selectFrom('accounts').select(['id', 'name'])
    .where('id', 'in', [...new Set(rows.flatMap((r) => [r.from_account_id, r.to_account_id]))]).execute();
  const users = await tx.selectFrom('users').select(['id', 'name']).where('id', 'in', [...new Set(rows.map((r) => r.created_by))]).execute();
  const nm = (list: { id: string; name: string }[], id: string) => list.find((x) => x.id === id)?.name ?? '';
  return rows.map((r) => ({
    id: r.id, number: r.number, date: r.entry_date, amount: Number(r.amount), narration: r.narration, status: r.status,
    from: { companyId: r.from_company_id, companyName: nm(cos, r.from_company_id), accountId: r.from_account_id, accountName: nm(accs, r.from_account_id), entryId: r.from_entry_id },
    to: { companyId: r.to_company_id, companyName: nm(cos, r.to_company_id), accountId: r.to_account_id, accountName: nm(accs, r.to_account_id), entryId: r.to_entry_id },
    createdBy: { id: r.created_by, name: nm(users, r.created_by) }, createdAt: r.created_at,
    cancelledAt: r.cancelled_at, cancelReason: r.cancel_reason,
  }));
}

async function checkAccount(tx: Tx, companyId: string, accountId: string, field: string) {
  const a = await tx.selectFrom('accounts').select(['company_id', 'is_active', 'subtype', 'system_key'])
    .where('id', '=', accountId).executeTakeFirst();
  if (!a || a.company_id !== companyId) throw badRequest('Account not found in that company.', { [field]: 'Not found' });
  if (!a.is_active) throw badRequest('Account is inactive.', { [field]: 'Inactive' });
  if (a.system_key === 'intercompany' || BLOCKED_SUBTYPES.includes(a.subtype)) {
    throw badRequest('Choose an account other than receivables, payables, inventory or inter-company.', { [field]: 'Not allowed' });
  }
}

/** Signed inter-company balance of `companyId` per counterparty: positive means they owe it. */
async function counterpartyBalances(tx: Tx, companyId: string, asOf: string) {
  const rows = await tx.selectFrom('intercompany_entries').selectAll()
    .where('status', '=', 'posted').where('entry_date', '<=', asOf)
    .where((eb) => eb.or([eb('from_company_id', '=', companyId), eb('to_company_id', '=', companyId)])).execute();
  const out = new Map<string, number>();
  for (const r of rows) {
    const mine = r.from_company_id === companyId;
    const other = mine ? r.to_company_id : r.from_company_id;
    out.set(other, round2((out.get(other) ?? 0) + (mine ? Number(r.amount) : -Number(r.amount))));
  }
  return out;
}

const merge = (lists: AccountTotal[][]): AccountTotal[] => {
  const by = new Map<string, AccountTotal>();
  for (const list of lists) {
    for (const a of list) {
      const cur = by.get(a.code);
      if (cur) { cur.d += a.d; cur.c += a.c; cur.system_key ??= a.system_key; } else by.set(a.code, { ...a });
    }
  }
  return [...by.values()].sort((a, b) => a.code.localeCompare(b.code));
};

type AnyRow = { code?: string | null; name: string; amount?: number; debit?: number; credit?: number; byCompany?: Record<string, number> };
const amountOf = (r: AnyRow) => (r.amount !== undefined ? r.amount : round2((r.debit ?? 0) - (r.credit ?? 0)));
const keyOf = (r: AnyRow) => r.code ?? r.name;
const rowLists = (rep: Record<string, unknown>): AnyRow[][] => {
  const lists: AnyRow[][] = [];
  if (Array.isArray(rep.rows)) lists.push(rep.rows as AnyRow[]);
  for (const v of Object.values(rep)) {
    if (v && typeof v === 'object' && !Array.isArray(v) && Array.isArray((v as { rows?: unknown }).rows)) lists.push((v as { rows: AnyRow[] }).rows);
  }
  return lists;
};

type Kind = 'trial-balance' | 'profit-loss' | 'balance-sheet';
const build = (kind: Kind, totals: AccountTotal[]): Record<string, unknown> =>
  kind === 'trial-balance' ? trialBalance(totals) : kind === 'profit-loss' ? profitLoss(totals) : balanceSheet(totals);

async function consolidated(
  ctx: RequestContext, kind: Kind, companyIds: string[], from: string | null, to: string, head: Record<string, unknown>,
) {
  for (const id of companyIds) {
    if (!ctx.memberships.some((m) => m.companyId === id)) throw forbidden('You are not a member of one of these companies.');
    if (!canIn(ctx, id, 'accounts.view')) throw forbidden();
  }
  return ctx.tx(async (tx) => {
    const cos = await tx.selectFrom('companies').select(['id', 'name', 'gstin']).where('id', 'in', companyIds).execute();
    if (cos.length !== companyIds.length) throw notFound('Company');
    const companies = companyIds.map((id) => ({ id, name: cos.find((c) => c.id === id)!.name }));
    const warnings: string[] = [];

    // Inter-company entries between listed companies are eliminated from each side.
    const entries = await tx.selectFrom('intercompany_entries').selectAll()
      .where('status', '=', 'posted').where('entry_date', '<=', to)
      .where('from_company_id', 'in', companyIds).where('to_company_id', 'in', companyIds).execute();
    let eliminated = 0;
    const adj = new Map<string, number>();
    for (const e of entries) {
      const amt = Number(e.amount);
      adj.set(e.from_company_id, round2((adj.get(e.from_company_id) ?? 0) + amt));
      adj.set(e.to_company_id, round2((adj.get(e.to_company_id) ?? 0) - amt));
      eliminated = round2(eliminated + amt);
    }

    const per: { id: string; totals: AccountTotal[] }[] = [];
    for (const id of companyIds) {
      await systemAccounts(tx, { tenantId: ctx.tenantId, companyId: id });
      const totals = await accountTotals(tx, id, from, to);
      const a = adj.get(id) ?? 0;
      const ic = totals.find((t) => t.system_key === 'intercompany');
      if (a !== 0 && ic) { if (a > 0) ic.c += a; else ic.d -= a; }
      if (ic && Math.abs(ic.d - ic.c) >= 0.005) {
        warnings.push(`${companies.find((c) => c.id === id)!.name} has an inter-company balance of ${round2(ic.d - ic.c)} with companies outside this list or unexplained, left on the Inter-company Account row.`);
      }
      per.push({ id, totals });
    }

    // Same code, different name.
    const firstName = new Map<string, string>();
    for (const p of per) {
      for (const a of p.totals) {
        const f = firstName.get(a.code);
        if (f === undefined) firstName.set(a.code, a.name);
        else if (f !== a.name) warnings.push(`Account ${a.code} is called "${f}" in one company and "${a.name}" in another; merged under the first name.`);
      }
    }

    // Invoices between group companies are not eliminated.
    const gstins = cos.filter((c) => c.gstin).map((c) => c.gstin!);
    if (gstins.length) {
      const hit = await tx.selectFrom('parties').select(['company_id', 'name', 'gstin']).where('gstin', 'in', gstins)
        .where('company_id', 'in', companyIds).execute();
      for (const p of hit) {
        const other = cos.find((c) => c.gstin === p.gstin);
        if (other && other.id !== p.company_id) {
          warnings.push(`Party "${p.name}" is ${other.name}; invoices between group companies are not eliminated.`);
        }
      }
    }

    const report = build(kind, merge(per.map((p) => p.totals)));
    const perReports = per.map((p) => ({ id: p.id, rep: build(kind, p.totals) }));
    const lists = rowLists(report);
    for (const rows of lists) {
      for (const row of rows) {
        const key = keyOf(row);
        row.byCompany = {};
        for (const pr of perReports) {
          const found = rowLists(pr.rep).flat().find((r) => keyOf(r) === key);
          row.byCompany[pr.id] = found ? amountOf(found) : 0;
        }
      }
    }
    return { ...head, ...report, companies, eliminations: { intercompany: eliminated }, warnings: [...new Set(warnings)] };
  });
}

/** Inter-company entries and consolidated reports (v1.7 section 11). */
export async function intercompanyRoutes(app: FastifyInstance, _deps: AppDeps): Promise<void> {
  app.post('/intercompany-entries', async (req, reply) => {
    const ctx = req.ctx;
    const b = parse(createBody, req.body);
    if (b.from.companyId === b.to.companyId) throw badRequest('Choose two different companies.', { 'to.companyId': 'Must differ' });
    for (const id of [b.from.companyId, b.to.companyId]) {
      if (!canIn(ctx, id, 'accounts.journal')) throw forbidden();
    }
    const entry = await ctx.tx(async (tx) => {
      await checkAccount(tx, b.from.companyId, b.from.accountId, 'from.accountId');
      await checkAccount(tx, b.to.companyId, b.to.accountId, 'to.accountId');
      const fromWho = { tenantId: ctx.tenantId, companyId: b.from.companyId, userId: ctx.userId };
      const toWho = { tenantId: ctx.tenantId, companyId: b.to.companyId, userId: ctx.userId };
      const number = await nextNumber(tx, fromWho, 'intercompany', financialYear(b.date));
      const fromIc = (await systemAccounts(tx, fromWho)).intercompany;
      const toIc = (await systemAccounts(tx, toWho)).intercompany;
      const fromEntry = await postJournal(tx, fromWho, {
        date: b.date, voucherType: 'intercompany', voucherId: null, number, narration: b.narration,
        lines: [{ accountId: fromIc, amount: b.amount }, { accountId: b.from.accountId, amount: -b.amount }],
      });
      const toEntry = await postJournal(tx, toWho, {
        date: b.date, voucherType: 'intercompany', voucherId: null, number, narration: b.narration,
        lines: [{ accountId: b.to.accountId, amount: b.amount }, { accountId: toIc, amount: -b.amount }],
      });
      const row = await tx.insertInto('intercompany_entries').values({
        tenant_id: ctx.tenantId, number, entry_date: b.date, amount: b.amount, narration: b.narration,
        from_company_id: b.from.companyId, from_account_id: b.from.accountId, from_entry_id: fromEntry,
        to_company_id: b.to.companyId, to_account_id: b.to.accountId, to_entry_id: toEntry, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      for (const companyId of [b.from.companyId, b.to.companyId]) {
        await writeAudit(tx, { ...auditOf(ctx), companyId }, 'intercompany_entry', row.id, 'create', null,
          { number, amount: b.amount, from: b.from.companyId, to: b.to.companyId });
      }
      return (await entryJson(tx, [row]))[0];
    });
    return reply.status(201).send(entry);
  });

  app.get('/intercompany-entries', async (req) => {
    const ctx = req.ctx;
    ctx.require('accounts.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      const mine = (eb: any) => eb.or([eb('from_company_id', '=', ctx.companyId), eb('to_company_id', '=', ctx.companyId)]);
      let base = tx.selectFrom('intercompany_entries').where(mine);
      if (q.counterpartyId) {
        const cp = q.counterpartyId;
        base = base.where((eb) => eb.or([
          eb.and([eb('from_company_id', '=', ctx.companyId), eb('to_company_id', '=', cp)]),
          eb.and([eb('to_company_id', '=', ctx.companyId), eb('from_company_id', '=', cp)]),
        ]));
      }
      if (q.from) base = base.where('entry_date', '>=', q.from);
      if (q.to) base = base.where('entry_date', '<=', q.to);
      if (q.status) base = base.where('status', '=', q.status);
      const total = await base.select((eb) => eb.fn.countAll<number>().as('n')).executeTakeFirstOrThrow();
      const rows = await base.selectAll().orderBy('entry_date', 'desc').orderBy('created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: await entryJson(tx, rows), total: Number(total.n) };
    });
  });

  app.post<{ Params: { id: string } }>('/intercompany-entries/:id/cancel', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(z.object({ reason: z.string().trim().min(3).max(300) }), req.body);
    return ctx.tx(async (tx) => {
      const e = await loadEntry(tx, id);
      if (e.from_company_id !== ctx.companyId && e.to_company_id !== ctx.companyId) throw notFound('Inter-company entry');
      for (const c of [e.from_company_id, e.to_company_id]) {
        if (!canIn(ctx, c, 'accounts.journal')) throw forbidden();
      }
      if (e.status === 'cancelled') throw conflict('This entry is already cancelled.');
      const today = todayIst();
      const narration = `Cancelled: ${reason}`;
      await reverseEntry(tx, { tenantId: ctx.tenantId, companyId: e.from_company_id, userId: ctx.userId }, e.from_entry_id, today, narration);
      await reverseEntry(tx, { tenantId: ctx.tenantId, companyId: e.to_company_id, userId: ctx.userId }, e.to_entry_id, today, narration);
      const row = await tx.updateTable('intercompany_entries').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason })
        .where('id', '=', id).returningAll().executeTakeFirstOrThrow();
      for (const companyId of [e.from_company_id, e.to_company_id]) {
        await writeAudit(tx, { ...auditOf(ctx), companyId }, 'intercompany_entry', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      }
      return (await entryJson(tx, [row]))[0];
    });
  });

  app.get('/reports/intercompany', async (req) => {
    const ctx = req.ctx;
    ctx.require('accounts.view');
    const asOf = parse(asOfQuery, req.query).asOf ?? todayIst();
    return ctx.tx(async (tx) => {
      await systemAccounts(tx, ctx);
      const bal = await counterpartyBalances(tx, ctx.companyId, asOf);
      const ids = [...bal.keys()];
      const cos = ids.length ? await tx.selectFrom('companies').select(['id', 'name']).where('id', 'in', ids).execute() : [];
      const rows = ids.map((id) => ({ companyId: id, companyName: cos.find((c) => c.id === id)?.name ?? '', balance: bal.get(id)! }))
        .sort((a, b) => a.companyName.localeCompare(b.companyName));
      const ic = (await accountTotals(tx, ctx.companyId, null, asOf)).find((t) => t.system_key === 'intercompany');
      const accountBalance = ic ? round2(ic.d - ic.c) : 0;
      const explained = round2(rows.reduce((s, r) => s + r.balance, 0));
      return { asOf, rows, accountBalance, unexplained: round2(accountBalance - explained) };
    });
  });

  app.get('/reports/consolidated/trial-balance', async (req) => {
    const ctx = req.ctx;
    const { companyIds } = parse(companyIdsQuery, req.query);
    const asOf = parse(asOfQuery, req.query).asOf ?? todayIst();
    return consolidated(ctx, 'trial-balance', companyIds, null, asOf, { asOf });
  });

  app.get('/reports/consolidated/balance-sheet', async (req) => {
    const ctx = req.ctx;
    const { companyIds } = parse(companyIdsQuery, req.query);
    const asOf = parse(asOfQuery, req.query).asOf ?? todayIst();
    return consolidated(ctx, 'balance-sheet', companyIds, null, asOf, { asOf });
  });

  app.get('/reports/consolidated/profit-loss', async (req) => {
    const ctx = req.ctx;
    const { companyIds } = parse(companyIdsQuery, req.query);
    const q = parse(z.object({ from: dateField.optional(), to: dateField.optional() }), req.query);
    const to = q.to ?? todayIst();
    const from = q.from ?? fyStart(to);
    return consolidated(ctx, 'profit-loss', companyIds, from, to, { from, to });
  });
}

documentRoute('POST', '/intercompany-entries', { body: createBody });
