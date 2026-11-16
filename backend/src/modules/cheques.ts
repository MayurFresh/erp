import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { moneyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { bumpPaid, createPayment, type PayDocType } from './payments.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const point = z.object({ x: z.number().min(0).max(400), y: z.number().min(0).max(400) });

export const DEFAULT_LAYOUT = {
  widthMm: 202, heightMm: 92,
  date: { x: 160, y: 10 }, payee: { x: 30, y: 22 }, words: { x: 30, y: 31, maxWidth: 120 },
  amount: { x: 160, y: 40 }, acPayee: { x: 12, y: 8 }, dateGap: 5,
};
const layoutBody = z.object({
  widthMm: z.number().min(50).max(400), heightMm: z.number().min(40).max(200),
  date: point, payee: point, words: point.extend({ maxWidth: z.number().min(20).max(400) }),
  amount: point, acPayee: point, dateGap: z.number().min(0).max(15),
});

const bookBody = z.object({
  accountId: z.uuid(), name: z.string().trim().max(80).optional(), prefix: z.string().trim().max(10).optional(),
  fromNo: z.coerce.number().int().min(0), toNo: z.coerce.number().int().min(0),
});
const chequeBody = z.object({
  direction: z.enum(['received', 'issued']), bankAccountId: z.uuid(), chequeNo: z.string().trim().min(1).max(20),
  chequeDate: dateField, partyId: z.uuid(), amount: moneyField.refine((v) => v > 0, 'Must be more than zero'),
  bookId: z.uuid().optional(), drawnOn: z.string().trim().max(80).optional(), notes: z.string().trim().max(500).optional(),
});
const listQuery = pagingQuery.extend({
  direction: z.enum(['received', 'issued']).optional(), status: z.enum(['held', 'deposited', 'cleared', 'bounced', 'cancelled']).optional(),
  from: dateField.optional(), to: dateField.optional(), partyId: z.uuid().optional(),
});
const dateBody = z.object({ date: dateField.optional() });
const bounceBody = z.object({
  date: dateField.optional(), reason: z.string().trim().min(3, 'Give a reason').max(300),
  bankCharges: moneyField.optional(), chargesAccountId: z.uuid().optional(), recoverFromParty: z.boolean().optional(),
});
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const payChequeBody = z.object({ chequeNo: z.string().trim().min(1).max(20).optional(), bookId: z.uuid().optional(), chequeDate: dateField.optional() });

async function bankAccount(tx: Tx, ctx: RequestContext, id: string) {
  const a = await tx.selectFrom('accounts').select(['id', 'name', 'subtype', 'is_active']).where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!a || a.subtype !== 'bank') throw badRequest('Choose a bank account.', { bankAccountId: 'Not a bank account' });
  return a;
}

const padNo = (n: number, width: number) => String(n).padStart(width, '0');
const widthOf = (b: { to_no: number }) => Math.max(6, String(b.to_no).length);

type ChequeRow = Awaited<ReturnType<typeof loadRows>>[number];
async function loadRows(tx: Tx, ctx: RequestContext, ids: string[]) {
  if (!ids.length) return [];
  return tx.selectFrom('cheques as c').innerJoin('parties as p', 'p.id', 'c.party_id').innerJoin('accounts as a', 'a.id', 'c.bank_account_id')
    .selectAll('c').select(['p.name as party_name', 'a.name as bank_name']).where('c.company_id', '=', ctx.companyId).where('c.id', 'in', ids).execute();
}
const json = (r: ChequeRow) => ({
  id: r.id, direction: r.direction, bankAccountId: r.bank_account_id, bankAccountName: r.bank_name, bookId: r.book_id, chequeNo: r.cheque_no,
  chequeDate: r.cheque_date, partyId: r.party_id, partyName: r.party_name, amount: r.amount, drawnOn: r.drawn_on, status: r.status,
  paymentId: r.payment_id, depositedOn: r.deposited_on, clearedOn: r.cleared_on, bouncedOn: r.bounced_on, bounceReason: r.bounce_reason,
  bounceCharges: r.bounce_charges, notes: r.notes, postDated: r.cheque_date > String(r.created_at instanceof Date ? r.created_at.toISOString() : r.created_at).slice(0, 10),
  createdAt: r.created_at,
});
async function one(tx: Tx, ctx: RequestContext, id: string) {
  const r = (await loadRows(tx, ctx, [id]))[0];
  if (!r) throw notFound('Cheque');
  return r;
}

async function layoutFor(tx: Tx, ctx: RequestContext, accountId: string) {
  const row = await tx.selectFrom('cheque_layouts').select('layout').where('company_id', '=', ctx.companyId).where('account_id', '=', accountId).executeTakeFirst();
  return row ? { ...DEFAULT_LAYOUT, ...(row.layout as object), isDefault: false } : { ...DEFAULT_LAYOUT, isDefault: true };
}

async function cancelLinkedPayment(tx: Tx, ctx: RequestContext, paymentId: string, reason: string) {
  const p = await tx.selectFrom('payments').select(['id', 'status', 'number']).where('id', '=', paymentId).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!p || p.status === 'cancelled') return;
  await tx.updateTable('payments').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', paymentId).execute();
  const allocs = await tx.selectFrom('payment_allocations').select(['doc_type', 'doc_id', 'amount']).where('payment_id', '=', paymentId).execute();
  for (const a of allocs) await bumpPaid(tx, a.doc_type as PayDocType, a.doc_id, -a.amount);
  await reverseVoucher(tx, auditOf(ctx), paymentId, todayIst(), `Cancelled ${p.number}: ${reason}`);
}

export async function chequeRoutes(app: FastifyInstance) {
  // ---- Books and layout ----
  app.get('/cheque-books', async (req) => {
    const ctx = req.ctx;
    ctx.require('cheques.view');
    const q = parse(z.object({ accountId: z.uuid().optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('cheque_books as b').innerJoin('accounts as a', 'a.id', 'b.account_id').selectAll('b').select('a.name as account_name')
        .where('b.company_id', '=', ctx.companyId);
      if (q.accountId) base = base.where('b.account_id', '=', q.accountId);
      const rows = await base.orderBy('b.created_at', 'desc').execute();
      const used = await tx.selectFrom('cheques').select(['book_id']).select((eb) => eb.fn.countAll<number>().as('n'))
        .where('company_id', '=', ctx.companyId).where('book_id', 'is not', null).where('status', '<>', 'cancelled').groupBy('book_id').execute();
      return {
        data: rows.map((b) => ({
          id: b.id, accountId: b.account_id, accountName: b.account_name, name: b.name, prefix: b.prefix, fromNo: Number(b.from_no), toNo: Number(b.to_no),
          leaves: Number(b.to_no) - Number(b.from_no) + 1, used: Number(used.find((u) => u.book_id === b.id)?.n ?? 0), isActive: b.is_active,
        })),
      };
    });
  });

  app.post('/cheque-books', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('cheques.manage');
    const body = parse(bookBody, req.body);
    if (body.toNo < body.fromNo) throw badRequest('The last number is before the first.', { toNo: 'Before first' });
    if (body.toNo - body.fromNo >= 500) throw badRequest('A book can have at most 500 leaves.', { toNo: 'Too many leaves' });
    return reply.status(201).send(await ctx.tx(async (tx) => {
      await bankAccount(tx, ctx, body.accountId);
      const clash = await tx.selectFrom('cheque_books').select('id').where('company_id', '=', ctx.companyId).where('account_id', '=', body.accountId)
        .where('from_no', '<=', body.toNo).where('to_no', '>=', body.fromNo).executeTakeFirst();
      if (clash) throw conflict('These numbers overlap another cheque book of this account.', 'RANGE_OVERLAP');
      const row = await tx.insertInto('cheque_books').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, account_id: body.accountId, name: body.name ?? null, prefix: body.prefix ?? '',
        from_no: body.fromNo, to_no: body.toNo, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'cheque_book', row.id, 'create', null, body);
      return { id: row.id, accountId: row.account_id, name: row.name, prefix: row.prefix, fromNo: Number(row.from_no), toNo: Number(row.to_no), isActive: row.is_active };
    }));
  });

  app.post<{ Params: { id: string } }>('/cheque-books/:id/deactivate', async (req) => {
    const ctx = req.ctx;
    ctx.require('cheques.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const r = await tx.updateTable('cheque_books').set({ is_active: false }).where('id', '=', id).where('company_id', '=', ctx.companyId).returning('id').executeTakeFirst();
      if (!r) throw notFound('Cheque book');
      return { id, isActive: false };
    });
  });

  app.get<{ Params: { id: string } }>('/cheque-books/:id/register', async (req) => {
    const ctx = req.ctx;
    ctx.require('cheques.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const b = await tx.selectFrom('cheque_books').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!b) throw notFound('Cheque book');
      const rows = await tx.selectFrom('cheques as c').innerJoin('parties as p', 'p.id', 'c.party_id').select(['c.id', 'c.cheque_no_num', 'c.status', 'c.cheque_date', 'c.amount', 'p.name as party_name'])
        .where('c.book_id', '=', id).orderBy('c.created_at').execute();
      const byNo = new Map<number, (typeof rows)[number]>();
      for (const r of rows) if (r.cheque_no_num !== null && (r.status !== 'cancelled' || !byNo.has(Number(r.cheque_no_num)))) byNo.set(Number(r.cheque_no_num), r);
      const width = widthOf({ to_no: Number(b.to_no) });
      const leaves = [];
      for (let n = Number(b.from_no); n <= Number(b.to_no); n++) {
        const r = byNo.get(n);
        leaves.push({
          no: b.prefix + padNo(n, width),
          status: r ? (r.status === 'held' ? 'issued' : r.status) : 'unused',
          chequeId: r?.id ?? null, chequeDate: r?.cheque_date ?? null, payee: r?.party_name ?? null, amount: r?.amount ?? null,
        });
      }
      return { book: { id: b.id, accountId: b.account_id, name: b.name, prefix: b.prefix, fromNo: Number(b.from_no), toNo: Number(b.to_no), isActive: b.is_active }, leaves };
    });
  });

  app.get<{ Params: { accountId: string } }>('/bank-accounts/:accountId/cheque-layout', async (req) => {
    const ctx = req.ctx;
    ctx.require('cheques.view');
    const accountId = parse(z.uuid(), req.params.accountId);
    return ctx.tx(async (tx) => { await bankAccount(tx, ctx, accountId); return layoutFor(tx, ctx, accountId); });
  });
  const saveLayout = async (req: { ctx: RequestContext; params: unknown; body: unknown }) => {
    const ctx = req.ctx;
    ctx.require('cheques.manage');
    const accountId = parse(z.uuid(), (req.params as { accountId: string }).accountId);
    const layout = parse(layoutBody, req.body);
    return ctx.tx(async (tx) => {
      await bankAccount(tx, ctx, accountId);
      await tx.insertInto('cheque_layouts').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, account_id: accountId, layout: JSON.stringify(layout) })
        .onConflict((oc) => oc.columns(['company_id', 'account_id']).doUpdateSet({ layout: JSON.stringify(layout) })).execute();
      return { ...layout, isDefault: false };
    });
  };
  app.put<{ Params: { accountId: string } }>('/bank-accounts/:accountId/cheque-layout', (req) => saveLayout(req as never));
  app.patch<{ Params: { accountId: string } }>('/bank-accounts/:accountId/cheque-layout', (req) => saveLayout(req as never));

  // ---- Cheques ----
  app.get('/cheques', async (req) => {
    const ctx = req.ctx;
    ctx.require('cheques.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('cheques as c').innerJoin('parties as p', 'p.id', 'c.party_id').where('c.company_id', '=', ctx.companyId);
      if (q.direction) base = base.where('c.direction', '=', q.direction);
      if (q.status) base = base.where('c.status', '=', q.status);
      if (q.partyId) base = base.where('c.party_id', '=', q.partyId);
      if (q.from) base = base.where('c.cheque_date', '>=', q.from);
      if (q.to) base = base.where('c.cheque_date', '<=', q.to);
      if (q.q) base = base.where((eb) => eb.or([eb('c.cheque_no', 'ilike', likeTerm(q.q!)), eb('p.name', 'ilike', likeTerm(q.q!))]));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('c.id').orderBy('c.cheque_date').orderBy('c.created_at').limit(q.limit).offset(q.offset).execute();
      const rows = await loadRows(tx, ctx, ids.map((i) => i.id));
      return { data: ids.map((i) => json(rows.find((r) => r.id === i.id)!)), total: Number(total) };
    });
  });

  app.get('/cheques/due-today', async (req) => {
    const ctx = req.ctx;
    ctx.require('cheques.view');
    const asOf = todayIst();
    return ctx.tx(async (tx) => {
      const ids = await tx.selectFrom('cheques').select('id').where('company_id', '=', ctx.companyId).where('status', 'in', ['held', 'deposited'])
        .where('cheque_date', '<=', asOf).orderBy('cheque_date').execute();
      const rows = await loadRows(tx, ctx, ids.map((i) => i.id));
      return { asOf, data: ids.map((i) => json(rows.find((r) => r.id === i.id)!)) };
    });
  });

  app.get<{ Params: { id: string } }>('/cheques/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('cheques.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => json(await one(tx, ctx, id)));
  });

  app.post('/cheques', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('cheques.manage');
    const body = parse(chequeBody, req.body);
    return reply.status(201).send(await ctx.tx(async (tx) => {
      await bankAccount(tx, ctx, body.bankAccountId);
      const party = await tx.selectFrom('parties').select(['id', 'type']).where('id', '=', body.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!party) throw badRequest('Party not found.', { partyId: 'Not found' });
      if (body.direction === 'received' && party.type === 'vendor') throw badRequest('Cheques are received from customers.', { partyId: 'Not a customer' });
      if (body.direction === 'issued' && party.type === 'customer') throw badRequest('Cheques are issued to vendors.', { partyId: 'Not a vendor' });
      let num: number | null = /^\d+$/.test(body.chequeNo) ? Number(body.chequeNo) : null;
      if (body.bookId) {
        const book = await tx.selectFrom('cheque_books').selectAll().where('id', '=', body.bookId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!book || book.account_id !== body.bankAccountId) throw badRequest('Cheque book not found for this bank account.', { bookId: 'Not found' });
        if (num === null || num < Number(book.from_no) || num > Number(book.to_no)) throw badRequest('This number is outside the cheque book.', { chequeNo: 'Outside the book' });
      }
      try {
        const row = await tx.insertInto('cheques').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, direction: body.direction, bank_account_id: body.bankAccountId, book_id: body.bookId ?? null,
          cheque_no: body.chequeNo, cheque_no_num: body.bookId ? num : null, cheque_date: body.chequeDate, party_id: body.partyId, amount: body.amount,
          drawn_on: body.drawnOn ?? null, notes: body.notes ?? null, created_by: ctx.userId,
        }).returning('id').executeTakeFirstOrThrow();
        await writeAudit(tx, auditOf(ctx), 'cheque', row.id, 'create', null, { chequeNo: body.chequeNo, direction: body.direction, amount: body.amount });
        return json(await one(tx, ctx, row.id));
      } catch (err) {
        if ((err as { code?: string }).code === '23505') throw conflict('This cheque number is already recorded.', 'CONFLICT', { chequeNo: 'Already used' });
        throw err;
      }
    }));
  });

  async function lockOne(tx: Tx, ctx: RequestContext, id: string) {
    const c = await tx.selectFrom('cheques').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
    if (!c) throw notFound('Cheque');
    return c;
  }
  const actionDate = (d: string | undefined) => {
    const date = d ?? todayIst();
    if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });
    return date;
  };

  app.post<{ Params: { id: string } }>('/cheques/:id/deposit', async (req) => {
    const ctx = req.ctx;
    ctx.require('cheques.manage');
    const id = parse(z.uuid(), req.params.id);
    const date = actionDate(parse(dateBody, req.body ?? {}).date);
    return ctx.tx(async (tx) => {
      const c = await lockOne(tx, ctx, id);
      if (c.direction !== 'received') throw badRequest('Only received cheques are deposited.');
      if (c.status !== 'held') throw conflict(`A ${c.status} cheque cannot be deposited.`, 'INVALID_STATE');
      await tx.updateTable('cheques').set({ status: 'deposited', deposited_on: date }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'cheque', id, 'update', { status: 'held' }, { status: 'deposited' });
      return json(await one(tx, ctx, id));
    });
  });

  app.post<{ Params: { id: string } }>('/cheques/:id/clear', async (req) => {
    const ctx = req.ctx;
    ctx.require('cheques.manage');
    const id = parse(z.uuid(), req.params.id);
    const date = actionDate(parse(dateBody, req.body ?? {}).date);
    return ctx.tx(async (tx) => {
      const c = await lockOne(tx, ctx, id);
      if (!['held', 'deposited'].includes(c.status)) throw conflict(`A ${c.status} cheque cannot be cleared.`, 'INVALID_STATE');
      let paymentId = c.payment_id;
      if (!paymentId) {
        const pay = await createPayment(ctx, tx, {
          kind: c.direction === 'received' ? 'receipt' : 'payment', partyId: c.party_id, date, accountId: c.bank_account_id, mode: 'cheque',
          reference: `Cheque ${c.cheque_no}`, amount: c.amount,
        });
        paymentId = pay.id;
      }
      await tx.updateTable('cheques').set({ status: 'cleared', cleared_on: date, payment_id: paymentId }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'cheque', id, 'update', { status: c.status }, { status: 'cleared', paymentId });
      return json(await one(tx, ctx, id));
    });
  });

  app.post<{ Params: { id: string } }>('/cheques/:id/bounce', async (req) => {
    const ctx = req.ctx;
    ctx.require('cheques.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(bounceBody, req.body);
    const date = actionDate(body.date);
    return ctx.tx(async (tx) => {
      const c = await lockOne(tx, ctx, id);
      if (!['held', 'deposited', 'cleared'].includes(c.status)) throw conflict(`A ${c.status} cheque cannot be bounced.`, 'INVALID_STATE');
      if (c.payment_id) await cancelLinkedPayment(tx, ctx, c.payment_id, `Cheque ${c.cheque_no} bounced`);
      let entryId: string | null = null;
      const charges = body.bankCharges ?? 0;
      if (charges > 0) {
        const acc = await systemAccounts(tx, ctx);
        let chargesId = body.chargesAccountId;
        if (chargesId) {
          const a = await tx.selectFrom('accounts').select(['id', 'type']).where('id', '=', chargesId).where('company_id', '=', ctx.companyId).executeTakeFirst();
          if (!a || a.type !== 'expense') throw badRequest('Choose an expense account for the bank charges.', { chargesAccountId: 'Not an expense account' });
        } else {
          chargesId = (await tx.selectFrom('accounts').select('id').where('company_id', '=', ctx.companyId).where('code', '=', '6070').executeTakeFirstOrThrow()).id;
        }
        const narr = `Bank charges on bounced cheque ${c.cheque_no}`;
        entryId = await postJournal(tx, auditOf(ctx), {
          date, voucherType: 'bank_entry', voucherId: c.id, number: null, narration: narr,
          lines: [{ accountId: chargesId, amount: charges }, { accountId: c.bank_account_id, amount: -charges }],
        });
        if (body.recoverFromParty && c.direction === 'received') {
          const number = await nextNumber(tx, ctx, 'debit_note', financialYear(date));
          await postJournal(tx, auditOf(ctx), {
            date, voucherType: 'debit_note', voucherId: c.id, number, narration: `Bank charges recovered for bounced cheque ${c.cheque_no}`,
            lines: [{ accountId: acc.receivables, amount: charges, partyId: c.party_id }, { accountId: chargesId, amount: -charges }],
          });
        }
      }
      await tx.updateTable('cheques').set({ status: 'bounced', bounced_on: date, bounce_reason: body.reason, bounce_charges: charges, bounce_entry_id: entryId })
        .where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'cheque', id, 'update', { status: c.status }, { status: 'bounced', reason: body.reason, charges });
      return json(await one(tx, ctx, id));
    });
  });

  app.post<{ Params: { id: string } }>('/cheques/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('cheques.manage');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const c = await lockOne(tx, ctx, id);
      if (c.status !== 'held') throw conflict(`A ${c.status} cheque cannot be cancelled.`, 'INVALID_STATE');
      await tx.updateTable('cheques').set({ status: 'cancelled', notes: `${c.notes ? `${c.notes}. ` : ''}Cancelled: ${reason}`.slice(0, 500) }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'cheque', id, 'update', { status: 'held' }, { status: 'cancelled', reason });
      return json(await one(tx, ctx, id));
    });
  });

  app.get<{ Params: { id: string } }>('/cheques/:id/print', async (req) => {
    const ctx = req.ctx;
    ctx.require('cheques.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const c = await one(tx, ctx, id);
      return {
        layout: await layoutFor(tx, ctx, c.bank_account_id), chequeNo: c.cheque_no, dateText: c.cheque_date.replaceAll('-', '').replace(/^(\d{4})(\d{2})(\d{2})$/, '$3$2$1'),
        payee: c.party_name, amount: c.amount, amountText: c.amount.toFixed(2), acPayee: true,
      };
    });
  });

  app.post<{ Params: { id: string } }>('/payments/:id/cheque', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('cheques.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(payChequeBody, req.body ?? {});
    return reply.status(201).send(await ctx.tx(async (tx) => {
      const p = await tx.selectFrom('payments').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!p) throw notFound('Payment');
      if (p.kind !== 'payment' || p.status !== 'posted') throw badRequest('Cheques are printed for posted payments.');
      await bankAccount(tx, ctx, p.account_id);
      const dup = await tx.selectFrom('cheques').select('id').where('payment_id', '=', id).where('status', '<>', 'cancelled').executeTakeFirst();
      if (dup) throw conflict('A cheque is already linked to this payment.', 'CONFLICT');
      let book = body.bookId
        ? await tx.selectFrom('cheque_books').selectAll().where('id', '=', body.bookId).where('company_id', '=', ctx.companyId).where('account_id', '=', p.account_id).executeTakeFirst()
        : undefined;
      if (body.bookId && !book) throw badRequest('Cheque book not found for this bank account.', { bookId: 'Not found' });
      let num: number | null = body.chequeNo && /^\d+$/.test(body.chequeNo) ? Number(body.chequeNo) : null;
      let chequeNo = body.chequeNo ?? '';
      if (!body.chequeNo) {
        const books = book ? [book] : await tx.selectFrom('cheque_books').selectAll().where('company_id', '=', ctx.companyId).where('account_id', '=', p.account_id).where('is_active', '=', true).orderBy('from_no').execute();
        let found = false;
        for (const b of books) {
          const taken = new Set((await tx.selectFrom('cheques').select('cheque_no_num').where('book_id', '=', b.id).where('status', '<>', 'cancelled').execute()).map((r) => Number(r.cheque_no_num)));
          for (let n = Number(b.from_no); n <= Number(b.to_no); n++) if (!taken.has(n)) { num = n; book = b; chequeNo = b.prefix + padNo(n, widthOf(b)); found = true; break; }
          if (found) break;
        }
        if (!found) throw conflict('No unused cheque leaf. Add a cheque book or give a cheque number.', 'NO_LEAF');
      } else if (book && (num === null || num < Number(book.from_no) || num > Number(book.to_no))) {
        throw badRequest('This number is outside the cheque book.', { chequeNo: 'Outside the book' });
      }
      try {
        const row = await tx.insertInto('cheques').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, direction: 'issued', bank_account_id: p.account_id, book_id: book?.id ?? null,
          cheque_no: chequeNo, cheque_no_num: book ? num : null, cheque_date: body.chequeDate ?? p.payment_date, party_id: p.party_id, amount: p.amount,
          payment_id: p.id, notes: `Payment ${p.number}`, created_by: ctx.userId,
        }).returning('id').executeTakeFirstOrThrow();
        await writeAudit(tx, auditOf(ctx), 'cheque', row.id, 'create', null, { chequeNo, paymentId: id });
        return json(await one(tx, ctx, row.id));
      } catch (err) {
        if ((err as { code?: string }).code === '23505') throw conflict('This cheque number is already recorded.', 'CONFLICT', { chequeNo: 'Already used' });
        throw err;
      }
    }));
  });
}
