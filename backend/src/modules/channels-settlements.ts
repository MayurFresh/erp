import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { assertPeriodOpen, postJournal, type JLine } from '../accounting/journal.ts';
import { systemAccounts, type SystemKey } from '../accounting/accounts.ts';
import { parseSettlementFile } from '../lib/channels/files.ts';
import type { SettlementKind } from '../lib/channels/types.ts';
import { conflict, notFound } from '../lib/errors.ts';
import { pagingQuery } from '../lib/paging.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { loadConnection } from './channels.ts';
import { documentRoute } from '../lib/openapi.ts';

const importBody = z.object({
  csv: z.string().min(1, 'Choose a file').max(5_000_000),
  dryRun: z.boolean().default(false),
  bankAccountId: z.uuid().optional(),
});
const postBody = z.object({ bankAccountId: z.uuid().optional() }).default({});
const listQuery = pagingQuery.extend({
  connectionId: z.uuid().optional(),
  status: z.enum(['imported', 'matched', 'posted', 'unbalanced']).optional(),
});

const cents = (n: number) => Math.round(n * 100);
const rupees = (c: number) => c / 100;

/*
 * Where each settlement line goes. Amounts are signed from the seller's side: positive is money to the seller.
 * Statutory lines (gst_on_fees, tcs, tds) need a CA check before filing:
 *  - TCS under GST section 52 is held by the operator, claimed by the seller through the GST return (rate: check before filing).
 *  - TDS under income tax section 194-O is claimed in the seller's return (rate: check before filing).
 *  - GST on marketplace fees is input tax credit for the seller; shown as Input IGST here (CGST/SGST split not done).
 */
const ACCOUNT_FOR: Record<SettlementKind, SystemKey> = {
  sale: 'receivables', refund: 'receivables', commission: 'marketplace_fees', fee: 'marketplace_fees', shipping: 'marketplace_fees',
  gst_on_fees: 'input_igst', tcs: 'tcs_receivable', tds: 'tds_receivable', reserve: 'marketplace_reserve',
  reserve_release: 'marketplace_reserve', adjustment: 'marketplace_fees',
};

async function loadSettlement(tx: Parameters<typeof loadConnection>[0], companyId: string, id: string, lock = false) {
  let q = tx.selectFrom('channel_settlements as s').innerJoin('channel_connections as c', 'c.id', 's.connection_id')
    .selectAll('s').select(['c.name as connection_name', 'c.party_id', 'c.tcs_rate', 'c.tds_rate']).where('s.id', '=', id).where('s.company_id', '=', companyId);
  if (lock) q = q.forUpdate('s' as never);
  const s = await q.executeTakeFirst();
  if (!s) throw notFound('Settlement');
  return s;
}

const listJson = (s: Awaited<ReturnType<typeof loadSettlement>>) => ({
  id: s.id, connectionId: s.connection_id, connectionName: s.connection_name, settlementRef: s.settlement_ref, payoutDate: s.payout_date,
  payout: s.payout, linesTotal: s.lines_total, difference: rupees(cents(s.payout) - cents(s.lines_total)), status: s.status,
  bankAccountId: s.bank_account_id, journalEntryId: s.journal_entry_id, postedAt: s.posted_at, createdAt: s.created_at, updatedAt: s.updated_at,
});

/** Expected against received, order by order, and the statutory lines against their expected size. */
async function reconcile(tx: Parameters<typeof loadConnection>[0], s: Awaited<ReturnType<typeof loadSettlement>>) {
  const lines = await tx.selectFrom('channel_settlement_lines as l').leftJoin('sales_orders as o', 'o.id', 'l.sales_order_id')
    .select(['l.line_no', 'l.order_ref', 'l.sales_order_id', 'l.kind', 'l.label', 'l.amount', 'o.number as order_number', 'o.status as order_status',
      'o.total as order_total', 'o.subtotal as order_subtotal'])
    .where('l.settlement_id', '=', s.id).orderBy('l.line_no').execute();
  type Row = { orderRef: string; salesOrderId: string | null; orderNumber: string | null; orderStatus: string | null; expected: number | null;
    received: number; difference: number | null; fees: number; matched: boolean; taxableShare: number };
  const byOrder = new Map<string, Row>();
  const totals: Record<string, number> = {};
  for (const l of lines) {
    totals[l.kind] = rupees(cents(totals[l.kind] ?? 0) + cents(l.amount));
    if (!l.order_ref) continue;
    let r = byOrder.get(l.order_ref);
    if (!r) {
      r = { orderRef: l.order_ref, salesOrderId: l.sales_order_id, orderNumber: l.order_number, orderStatus: l.order_status,
        expected: l.order_total ?? null, received: 0, difference: null, fees: 0, matched: Boolean(l.sales_order_id), taxableShare: 0 };
      byOrder.set(l.order_ref, r);
    }
    if (l.kind === 'sale' || l.kind === 'refund') {
      r.received = rupees(cents(r.received) + cents(l.amount));
      if (l.order_total && l.order_subtotal) r.taxableShare = rupees(cents(r.taxableShare) + cents(l.amount * l.order_subtotal / l.order_total));
      else r.taxableShare = rupees(cents(r.taxableShare) + cents(l.amount));
    } else r.fees = rupees(cents(r.fees) + cents(l.amount));
  }
  const orders = [...byOrder.values()].map((r) => ({
    ...r, difference: r.expected === null ? null : rupees(cents(r.received) - cents(r.expected)),
  }));
  const taxable = orders.reduce((a, r) => a + r.taxableShare, 0);
  const expectedTcs = -Math.round(taxable * s.tcs_rate) / 100;
  const expectedTds = -Math.round(taxable * s.tds_rate) / 100;
  return {
    orders: orders.map(({ taxableShare: _t, ...r }) => r),
    lines: lines.map((l) => ({ lineNo: l.line_no, orderRef: l.order_ref, salesOrderId: l.sales_order_id, kind: l.kind, label: l.label, amount: l.amount })),
    totals,
    statutory: {
      taxableValue: Math.round(taxable * 100) / 100,
      tcs: { rate: s.tcs_rate, expected: expectedTcs, received: totals.tcs ?? 0, difference: rupees(cents(totals.tcs ?? 0) - cents(expectedTcs)) },
      tds: { rate: s.tds_rate, expected: expectedTds, received: totals.tds ?? 0, difference: rupees(cents(totals.tds ?? 0) - cents(expectedTds)) },
      note: 'Rates are the channel\'s settings. Check TCS (GST section 52) and TDS (section 194-O) rates and treatment before filing.',
    },
    unmatchedOrders: orders.filter((r) => !r.matched).length,
  };
}

export async function channelSettlementRoutes(app: FastifyInstance) {
  app.get('/channels/settlements', async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('channel_settlements as s').innerJoin('channel_connections as c', 'c.id', 's.connection_id')
        .where('s.company_id', '=', ctx.companyId);
      if (q.connectionId) base = base.where('s.connection_id', '=', q.connectionId);
      if (q.status) base = base.where('s.status', '=', q.status);
      const total = await base.select((eb) => eb.fn.countAll<number>().as('n')).executeTakeFirstOrThrow();
      const rows = await base.selectAll('s').select(['c.name as connection_name', 'c.party_id', 'c.tcs_rate', 'c.tds_rate'])
        .orderBy('s.payout_date', 'desc').orderBy('s.settlement_ref').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(listJson), total: Number(total.n) };
    });
  });

  app.get<{ Params: { id: string } }>('/channels/settlements/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const s = await loadSettlement(tx, ctx.companyId, id);
      return { ...listJson(s), ...(await reconcile(tx, s)) };
    });
  });

  app.post<{ Params: { id: string } }>('/channels/:id/settlements/import', async (req) => {
    const ctx = req.ctx;
    ctx.require('settlements.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(importBody, req.body);
    return ctx.tx(async (tx) => {
      const conn = await loadConnection(tx, ctx, id, true);
      const { settlements, issues } = parseSettlementFile(b.csv, conn.settlement_aliases);
      if (b.bankAccountId) {
        const a = await tx.selectFrom('accounts').select('id').where('id', '=', b.bankAccountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!a) throw notFound('Bank account');
      }
      const out = [];
      for (const st of settlements) {
        const sum = st.lines.reduce((a, l) => a + cents(l.amount), 0);
        const payout = st.declaredPayout ?? rupees(sum);
        const exists = await tx.selectFrom('channel_settlements').select(['id', 'status']).where('connection_id', '=', id).where('settlement_ref', '=', st.ref).executeTakeFirst();
        const refs = [...new Set(st.lines.map((l) => l.orderRef).filter((r): r is string => Boolean(r)))];
        const known = refs.length
          ? await tx.selectFrom('sales_orders').select(['id', 'external_ref']).where('channel_id', '=', id).where('external_ref', 'in', refs).execute()
          : [];
        const unmatched = refs.filter((r) => !known.some((k) => k.external_ref === r));
        const status = cents(payout) !== sum ? 'unbalanced' : unmatched.length ? 'imported' : 'matched';
        const item = {
          settlementRef: st.ref, payoutDate: st.payoutDate, payout, linesTotal: rupees(sum), difference: rupees(cents(payout) - sum), status,
          lineCount: st.lines.length, unmatchedOrderRefs: unmatched, duplicate: Boolean(exists), settlementId: exists?.id ?? null,
        };
        if (!b.dryRun && !exists) {
          const row = await tx.insertInto('channel_settlements').values({
            tenant_id: ctx.tenantId, company_id: ctx.companyId, connection_id: id, settlement_ref: st.ref, payout_date: st.payoutDate, payout,
            lines_total: rupees(sum), status, bank_account_id: b.bankAccountId ?? null, journal_entry_id: null, posted_at: null, created_by: ctx.userId,
          }).returning('id').executeTakeFirstOrThrow();
          if (st.lines.length) {
            await tx.insertInto('channel_settlement_lines').values(st.lines.map((l) => ({
              tenant_id: ctx.tenantId, settlement_id: row.id, line_no: l.lineNo, order_ref: l.orderRef,
              sales_order_id: known.find((k) => k.external_ref === l.orderRef)?.id ?? null, kind: l.kind, label: l.label, amount: l.amount,
            }))).execute();
          }
          item.settlementId = row.id;
          await writeAudit(tx, auditOf(ctx), 'channel_settlement', row.id, 'import', null, { ref: st.ref, payout, lines: st.lines.length });
        }
        out.push(item);
      }
      return {
        dryRun: b.dryRun, issues, settlements: out,
        summary: { total: out.length, created: out.filter((o) => !o.duplicate).length, duplicates: out.filter((o) => o.duplicate).length,
          unbalanced: out.filter((o) => o.status === 'unbalanced').length },
      };
    });
  });

  app.post<{ Params: { id: string } }>('/channels/settlements/:id/post', async (req) => {
    const ctx = req.ctx;
    ctx.require('settlements.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(postBody, req.body ?? {});
    return ctx.tx(async (tx) => {
      const s = await loadSettlement(tx, ctx.companyId, id, true);
      if (s.status === 'posted') throw conflict('This settlement is already posted.', 'ILLEGAL_TRANSITION', { status: s.status });
      if (s.status === 'unbalanced' || cents(s.payout) !== cents(s.lines_total)) {
        throw conflict(`The payout (${s.payout}) does not match the lines (${s.lines_total}). Fix the report and import it again before posting.`, 'UNBALANCED_SETTLEMENT');
      }
      await assertPeriodOpen(tx, ctx.companyId, s.payout_date);
      const lines = await tx.selectFrom('channel_settlement_lines').selectAll().where('settlement_id', '=', id).orderBy('line_no').execute();
      const sys = await systemAccounts(tx, ctx);
      const bankId = b.bankAccountId ?? s.bank_account_id ?? sys.bank;
      if (b.bankAccountId) {
        const a = await tx.selectFrom('accounts').select('id').where('id', '=', b.bankAccountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!a) throw notFound('Bank account');
      }
      // Bank takes the payout; each line goes to its account on the other side, so the entry balances when payout = sum of lines.
      const j: JLine[] = [{ accountId: bankId, amount: s.payout }];
      const acc = new Map<string, JLine>();
      for (const l of lines) {
        const key = ACCOUNT_FOR[l.kind as SettlementKind];
        const party = key === 'receivables' ? s.party_id : null;
        const k = `${key}|${party ?? ''}`;
        const e = acc.get(k) ?? { accountId: sys[key], amount: 0, partyId: party };
        e.amount = rupees(cents(e.amount) - cents(l.amount));
        acc.set(k, e);
      }
      j.push(...acc.values());
      const entryId = await postJournal(tx, ctx, {
        date: s.payout_date, voucherType: 'settlement', voucherId: id, number: `STL-${s.settlement_ref}`.slice(0, 40),
        narration: `${s.connection_name} settlement ${s.settlement_ref}`, lines: j,
      });
      await tx.updateTable('channel_settlements').set({ status: 'posted', journal_entry_id: entryId, bank_account_id: bankId, posted_at: new Date(), updated_at: new Date() })
        .where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'channel_settlement', id, 'post', { status: s.status }, { status: 'posted', journalEntryId: entryId });
      const after = await loadSettlement(tx, ctx.companyId, id);
      return { ...listJson(after), ...(await reconcile(tx, after)) };
    });
  });
}

documentRoute('POST', '/channels/:id/settlements/import', { body: importBody });
