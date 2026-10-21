import type { FastifyInstance } from 'fastify';
import { systemAccounts } from '../accounting/accounts.ts';
import { todayIst } from '../lib/dates.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { invoiceJson, invoiceSelect } from './invoices.ts';

export async function dashboardRoutes(app: FastifyInstance) {
  app.get('/dashboard', async (req) => {
    const ctx = req.ctx;
    ctx.require('dashboard.view');
    const today = todayIst();
    const monthStart = `${today.slice(0, 8)}01`;
    const scope = scopedLocationIds(ctx);

    return ctx.tx(async (tx) => {
      let posted = tx.selectFrom('invoices').where('company_id', '=', ctx.companyId).where('status', '=', 'posted');
      if (scope) posted = posted.where('location_id', 'in', scope);

      const sales = await posted
        .select((eb) => [
          eb.fn.coalesce(eb.fn.sum<number>(eb.case().when('invoice_date', '=', today).then(eb.ref('total')).else(0).end()), eb.lit(0)).as('today'),
          eb.fn.coalesce(eb.fn.sum<number>(eb.case().when('invoice_date', '>=', monthStart).then(eb.ref('total')).else(0).end()), eb.lit(0)).as('month'),
          eb.fn.count<number>(eb.case().when('invoice_date', '>=', monthStart).then(1).end()).as('count'),
        ])
        .executeTakeFirstOrThrow();

      let balances = tx.selectFrom('stock_moves as m')
        .innerJoin('items as i', 'i.id', 'm.item_id')
        .where('m.company_id', '=', ctx.companyId)
        .where('i.track_stock', '=', true)
        .where('i.reorder_level', '>', 0);
      if (scope) balances = balances.where('m.location_id', 'in', scope);
      const low = balances
        .groupBy(['m.item_id', 'm.location_id', 'i.reorder_level'])
        .having((eb) => eb(eb.fn.sum('m.qty'), '<=', eb.ref('i.reorder_level')))
        .select('m.item_id');
      const { lowCount } = await tx.selectFrom(low.as('x')).select((eb) => eb.fn.countAll<number>().as('lowCount')).executeTakeFirstOrThrow();

      let recent = invoiceSelect(tx).where('v.company_id', '=', ctx.companyId);
      if (scope) recent = recent.where('v.location_id', 'in', scope);
      const recentRows = await recent.orderBy('v.invoice_date', 'desc').orderBy('v.created_at', 'desc').limit(5).execute();

      let top = tx.selectFrom('invoice_lines as il')
        .innerJoin('invoices as v', 'v.id', 'il.invoice_id')
        .innerJoin('items as i', 'i.id', 'il.item_id')
        .where('v.company_id', '=', ctx.companyId)
        .where('v.status', '=', 'posted')
        .where('v.invoice_date', '>=', monthStart);
      if (scope) top = top.where('v.location_id', 'in', scope);
      const topRows = await top
        .groupBy(['il.item_id', 'i.name'])
        .select((eb) => ['il.item_id', 'i.name', eb.fn.sum<number>('il.qty').as('qty'), eb.fn.sum<number>('il.line_total').as('amount')])
        .orderBy('amount', 'desc')
        .limit(5)
        .execute();

      // Money figures are company-wide, so only roles that handle money see them.
      const finance: Record<string, number> = {};
      if (ctx.can('accounts.view') || ctx.can('payments.view')) {
        const acc = await systemAccounts(tx, ctx);
        const rows = await tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
          .innerJoin('accounts as a', 'a.id', 'jl.account_id')
          .select((eb) => ['a.id', 'a.subtype', eb.fn.sum<number>('jl.debit').as('d'), eb.fn.sum<number>('jl.credit').as('c')])
          .where('je.company_id', '=', ctx.companyId).where('a.company_id', '=', ctx.companyId)
          .where((eb) => eb.or([eb('a.id', 'in', [acc.receivables, acc.payables]), eb('a.subtype', 'in', ['cash', 'bank'])]))
          .groupBy(['a.id', 'a.subtype']).execute();
        const bal = (f: (r: (typeof rows)[number]) => boolean) =>
          Math.round(rows.filter(f).reduce((s, r) => s + Number(r.d) - Number(r.c), 0) * 100) / 100;
        finance.receivables = bal((r) => r.id === acc.receivables);
        finance.payables = -bal((r) => r.id === acc.payables);
        finance.cashAndBank = bal((r) => r.subtype === 'cash' || r.subtype === 'bank');
      }
      if (ctx.can('purchases.view')) {
        let pq = tx.selectFrom('purchases').where('company_id', '=', ctx.companyId).where('status', '=', 'posted')
          .where('bill_date', '>=', monthStart);
        if (scope) pq = pq.where('location_id', 'in', scope);
        const p = await pq.select((eb) => eb.fn.coalesce(eb.fn.sum<number>('total'), eb.lit(0)).as('t')).executeTakeFirstOrThrow();
        finance.purchasesThisMonth = Number(p.t);
      }

      return {
        ...finance,
        salesToday: Number(sales.today),
        salesThisMonth: Number(sales.month),
        invoicesThisMonth: Number(sales.count),
        lowStockCount: Number(lowCount),
        recentInvoices: recentRows.map(invoiceJson),
        topItems: topRows.map((r) => ({ itemId: r.item_id, name: r.name, qty: Number(r.qty), amount: Number(r.amount) })),
      };
    });
  });
}
