import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal, reverseEntry } from '../accounting/journal.ts';
import { ledger } from '../accounting/ledger.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, fyStart, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { moneyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const TYPES = ['asset', 'liability', 'equity', 'income', 'expense'] as const;
const CODE_BASE: Record<(typeof TYPES)[number], number> = { asset: 1500, liability: 2500, equity: 3500, income: 4500, expense: 6500 };
// Expense accounts that are posted automatically and are not offered as expense heads.
const AUTO_EXPENSES = ['cogs', 'purchases_nonstock', 'stock_loss', 'round_off', 'material_consumed', 'site_labour'];

const listQuery = z.object({
  type: z.enum(TYPES).optional(),
  subtype: z.enum(['cash', 'bank', 'receivables', 'payables', 'inventory', 'tax', 'other']).optional(),
  activeOnly: z.enum(['true', 'false']).optional(),
});
const createBody = z.object({
  name: z.string().trim().min(2).max(120),
  code: z.string().trim().regex(/^\d{3,6}$/, 'Use 3–6 digits').optional(),
  type: z.enum(TYPES),
  subtype: z.enum(['cash', 'bank', 'other']).optional(),
});
const patchBody = z.object({
  name: z.string().trim().min(2).max(120).optional(),
  code: z.string().trim().regex(/^\d{3,6}$/, 'Use 3–6 digits').optional(),
  isActive: z.boolean().optional(),
});
const ledgerQuery = z.object({ from: dateField.optional(), to: dateField.optional(), partyId: z.uuid().optional() });
const journalQuery = pagingQuery.extend({
  from: dateField.optional(),
  to: dateField.optional(),
  voucherType: z.enum(['sales', 'purchase', 'receipt', 'payment', 'credit_note', 'expense', 'stock', 'transfer', 'journal',
    'issue', 'wages']).optional(),
});
const journalBody = z.object({
  date: dateField.optional(),
  narration: z.string().trim().min(3, 'Add a narration').max(500),
  lines: z.array(z.object({
    accountId: z.uuid(),
    partyId: z.uuid().nullable().optional(),
    debit: moneyField.optional(),
    credit: moneyField.optional(),
  })).min(2, 'At least two lines').max(50),
});
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });

async function balances(tx: Tx, companyId: string, asOf: string): Promise<Map<string, number>> {
  const rows = await tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .select((eb) => ['jl.account_id', eb.fn.sum<number>('jl.debit').as('d'), eb.fn.sum<number>('jl.credit').as('c')])
    .where('je.company_id', '=', companyId).where('je.entry_date', '<=', asOf)
    .groupBy('jl.account_id').execute();
  return new Map(rows.map((r) => [r.account_id, round2(Number(r.d) - Number(r.c))]));
}

type AccountRow = { id: string; code: string; name: string; type: string; subtype: string; system_key: string | null; is_system: boolean; is_active: boolean };

const accountJson = (a: AccountRow, balance: number) => ({
  id: a.id, code: a.code, name: a.name, type: a.type, subtype: a.subtype, systemKey: a.system_key,
  isSystem: a.is_system, isActive: a.is_active, balance,
});

/** Loads entries with their lines and names, in the order of `ids`. */
export async function loadEntries(tx: Tx, ids: string[]) {
  if (!ids.length) return [];
  const entries = await tx.selectFrom('journal_entries as e').leftJoin('users as u', 'u.id', 'e.created_by')
    .selectAll('e').select('u.name as created_by_name').where('e.id', 'in', ids).execute();
  const lines = await tx.selectFrom('journal_lines as jl')
    .innerJoin('accounts as a', 'a.id', 'jl.account_id')
    .leftJoin('parties as p', 'p.id', 'jl.party_id')
    .select(['jl.entry_id', 'jl.line_no', 'jl.account_id', 'a.code', 'a.name', 'jl.party_id', 'p.name as party_name', 'jl.debit', 'jl.credit'])
    .where('jl.entry_id', 'in', ids).orderBy('jl.line_no').execute();
  return ids.map((id) => {
    const e = entries.find((x) => x.id === id)!;
    return {
      id: e.id, date: e.entry_date, voucherType: e.voucher_type, voucherId: e.voucher_id, number: e.number,
      narration: e.narration, isReversal: e.is_reversal, createdAt: e.created_at,
      createdBy: e.created_by ? { id: e.created_by, name: e.created_by_name! } : null,
      lines: lines.filter((l) => l.entry_id === id).map((l) => ({
        accountId: l.account_id, accountCode: l.code, accountName: l.name, partyId: l.party_id, partyName: l.party_name,
        debit: l.debit, credit: l.credit,
      })),
    };
  });
}

function canPickAccounts(ctx: RequestContext) {
  return ctx.can('payments.create') || ctx.can('expenses.create');
}

export async function accountRoutes(app: FastifyInstance) {
  app.get('/accounts', async (req) => {
    const ctx = req.ctx;
    const full = ctx.can('accounts.view');
    if (!full && !canPickAccounts(ctx)) throw forbidden();
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      await systemAccounts(tx, ctx);
      let base = tx.selectFrom('accounts').select(['id', 'code', 'name', 'type', 'subtype', 'system_key', 'is_system', 'is_active'])
        .where('company_id', '=', ctx.companyId);
      if (!full) {
        // Pickers for receipts, payments and expenses: cash, bank and expense heads only.
        base = base.where((eb) => eb.or([
          eb('subtype', 'in', ['cash', 'bank']),
          eb.and([eb('type', '=', 'expense'), eb.or([eb('system_key', 'is', null), eb('system_key', 'not in', AUTO_EXPENSES)])]),
        ]));
      }
      if (q.type) base = base.where('type', '=', q.type);
      if (q.subtype) base = base.where('subtype', '=', q.subtype);
      if (q.activeOnly === 'true') base = base.where('is_active', '=', true);
      const rows = await base.orderBy('code').execute();
      const bal = full ? await balances(tx, ctx.companyId, todayIst()) : new Map<string, number>();
      return { data: rows.map((r) => accountJson(r, bal.get(r.id) ?? 0)), total: rows.length };
    });
  });

  app.post('/accounts', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('accounts.manage');
    const body = parse(createBody, req.body);
    const subtype = body.subtype ?? 'other';
    if (subtype !== 'other' && body.type !== 'asset') {
      throw badRequest('Cash and bank accounts must be assets.', { subtype: 'Only for assets' });
    }
    try {
      const account = await ctx.tx(async (tx) => {
        await systemAccounts(tx, ctx);
        let code = body.code;
        if (!code) {
          const base = CODE_BASE[body.type];
          const existing = await tx.selectFrom('accounts').select('code').where('company_id', '=', ctx.companyId).execute();
          const used = existing.map((r) => Number(r.code)).filter((n) => n >= base && n < base + 500);
          code = String(used.length ? Math.max(...used) + 1 : base);
        }
        const row = await tx.insertInto('accounts').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, code, name: body.name, type: body.type, subtype,
          system_key: null, is_system: false,
        }).returning(['id', 'code', 'name', 'type', 'subtype', 'system_key', 'is_system', 'is_active']).executeTakeFirstOrThrow();
        await writeAudit(tx, auditOf(ctx), 'account', row.id, 'create', null, row);
        return row;
      });
      return reply.status(201).send(accountJson(account, 0));
    } catch (err) {
      if ((err as { code?: string }).code === '23505') throw conflict('This account code is already used.', 'CONFLICT', { code: 'Already used' });
      throw err;
    }
  });

  app.patch<{ Params: { id: string } }>('/accounts/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('accounts.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    try {
      return await ctx.tx(async (tx) => {
        const before = await tx.selectFrom('accounts').select(['id', 'code', 'name', 'type', 'subtype', 'system_key', 'is_system', 'is_active'])
          .where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!before) throw notFound('Account');
        if (before.is_system && (body.code !== undefined || body.isActive !== undefined)) {
          throw forbidden('System accounts can only be renamed.');
        }
        const changes = Object.fromEntries(Object.entries({ name: body.name, code: body.code, is_active: body.isActive })
          .filter(([, v]) => v !== undefined));
        if (!Object.keys(changes).length) return accountJson(before, (await balances(tx, ctx.companyId, todayIst())).get(id) ?? 0);
        const after = await tx.updateTable('accounts').set(changes).where('id', '=', id)
          .returning(['id', 'code', 'name', 'type', 'subtype', 'system_key', 'is_system', 'is_active']).executeTakeFirstOrThrow();
        await writeAudit(tx, auditOf(ctx), 'account', id, 'update', before, after);
        return accountJson(after, (await balances(tx, ctx.companyId, todayIst())).get(id) ?? 0);
      });
    } catch (err) {
      if ((err as { code?: string }).code === '23505') throw conflict('This account code is already used.', 'CONFLICT', { code: 'Already used' });
      throw err;
    }
  });

  app.get<{ Params: { id: string } }>('/accounts/:id/ledger', async (req) => {
    const ctx = req.ctx;
    ctx.require('accounts.view');
    const id = parse(z.uuid(), req.params.id);
    const q = parse(ledgerQuery, req.query);
    const to = q.to ?? todayIst();
    const from = q.from ?? fyStart(to);
    return ctx.tx(async (tx) => {
      const account = await tx.selectFrom('accounts').select(['id', 'name']).where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!account) throw notFound('Account');
      const result = await ledger(tx, ctx.companyId, { accountIds: [id], partyId: q.partyId, from, to });
      return { accountId: account.id, accountName: account.name, ...result };
    });
  });

  app.get('/journals', async (req) => {
    const ctx = req.ctx;
    ctx.require('accounts.view');
    const q = parse(journalQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('journal_entries').where('company_id', '=', ctx.companyId);
      if (q.from) base = base.where('entry_date', '>=', q.from);
      if (q.to) base = base.where('entry_date', '<=', q.to);
      if (q.voucherType) base = base.where('voucher_type', '=', q.voucherType);
      if (q.q) base = base.where((eb) => eb.or([eb('number', 'ilike', likeTerm(q.q!)), eb('narration', 'ilike', likeTerm(q.q!))]));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('id').orderBy('entry_date', 'desc').orderBy('created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: await loadEntries(tx, ids.map((r) => r.id)), total };
    });
  });

  app.get<{ Params: { id: string } }>('/journals/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('accounts.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const e = await tx.selectFrom('journal_entries').select('id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!e) throw notFound('Journal entry');
      return (await loadEntries(tx, [id]))[0];
    });
  });

  app.post('/journals', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('accounts.journal');
    const body = parse(journalBody, req.body);
    const entry = await ctx.tx(async (tx) => {
      const date = body.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });
      const accountIds = [...new Set(body.lines.map((l) => l.accountId))];
      const accounts = await tx.selectFrom('accounts').select(['id', 'subtype', 'is_active'])
        .where('company_id', '=', ctx.companyId).where('id', 'in', accountIds).execute();
      const partyIds = [...new Set(body.lines.map((l) => l.partyId).filter((p): p is string => !!p))];
      const parties = partyIds.length
        ? await tx.selectFrom('parties').select('id').where('company_id', '=', ctx.companyId).where('id', 'in', partyIds).execute()
        : [];
      let debit = 0;
      let credit = 0;
      const lines = body.lines.map((l, i) => {
        const account = accounts.find((a) => a.id === l.accountId);
        if (!account || !account.is_active) throw badRequest(`Line ${i + 1}: account not found or inactive.`, { [`lines.${i}.accountId`]: 'Invalid' });
        const d = l.debit ?? 0;
        const c = l.credit ?? 0;
        if ((d > 0) === (c > 0)) throw badRequest(`Line ${i + 1}: enter either a debit or a credit.`, { [`lines.${i}.debit`]: 'One side only' });
        if (l.partyId) {
          if (!['receivables', 'payables'].includes(account.subtype)) {
            throw badRequest(`Line ${i + 1}: a party can only be set on receivable or payable accounts.`, { [`lines.${i}.partyId`]: 'Not allowed here' });
          }
          if (!parties.some((p) => p.id === l.partyId)) throw badRequest(`Line ${i + 1}: party not found.`, { [`lines.${i}.partyId`]: 'Not found' });
        }
        debit += Math.round(d * 100);
        credit += Math.round(c * 100);
        return { accountId: account.id, amount: d > 0 ? d : -c, partyId: l.partyId ?? null };
      });
      if (debit !== credit) {
        throw badRequest(`Debits (₹${debit / 100}) and credits (₹${credit / 100}) must be equal.`, { lines: 'Not balanced' });
      }
      const number = await nextNumber(tx, ctx, 'journal', financialYear(date));
      const id = await postJournal(tx, auditOf(ctx), { date, voucherType: 'journal', voucherId: null, number, narration: body.narration, lines });
      await writeAudit(tx, auditOf(ctx), 'journal', id, 'create', null, { number, narration: body.narration, total: debit / 100 });
      return (await loadEntries(tx, [id]))[0];
    });
    return reply.status(201).send(entry);
  });

  app.post<{ Params: { id: string } }>('/journals/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('accounts.journal');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const e = await tx.selectFrom('journal_entries').select(['id', 'voucher_type', 'is_reversal', 'number'])
        .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!e) throw notFound('Journal entry');
      if (e.voucher_type !== 'journal' || e.is_reversal) {
        throw forbidden('Only manual journals can be cancelled here; cancel the source document instead.');
      }
      const done = await tx.selectFrom('journal_entries').select('id').where('reverses_id', '=', id).executeTakeFirst();
      if (done) throw conflict('This journal is already cancelled.', 'ALREADY_CANCELLED');
      const reversal = await reverseEntry(tx, auditOf(ctx), id, todayIst(), `Cancelled ${e.number}: ${reason}`);
      await writeAudit(tx, auditOf(ctx), 'journal', id, 'cancel', null, { reason });
      return (await loadEntries(tx, [reversal]))[0];
    });
  });
}
