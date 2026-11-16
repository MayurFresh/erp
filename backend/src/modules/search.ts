import type { FastifyInstance } from 'fastify';
import { sql, type RawBuilder } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import { effectiveModules } from '../lib/entitlements.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { parse } from '../lib/validate.ts';

const query = z.object({
  q: z.string().trim().max(80).default(''),
  limit: z.coerce.number().int().min(1).max(20).default(5),
});

export interface SearchItem { id: string; title: string; subtitle: string; route: string }
export interface SearchGroup { kind: string; label: string; items: SearchItem[] }

const esc = (s: string) => s.replace(/[\\%_]/g, (c) => `\\${c}`);
const money = (n: unknown) => `₹${Number(n ?? 0).toLocaleString('en-IN', { maximumFractionDigits: 2 })}`;

/** Rank 0 when any field starts with the term, 1 when it only contains it. */
function match(fields: string[], q: string) {
  const starts = `${esc(q.toLowerCase())}%`;
  const has = `%${esc(q.toLowerCase())}%`;
  const parts = (pat: string) => fields.map((f) => sql`lower(coalesce(${sql.raw(f)}::text, '')) like ${pat}`);
  const or = (xs: RawBuilder<unknown>[]) => sql.join(xs, sql` or `);
  return {
    where: sql`(${or(parts(has))})`,
    rank: sql<number>`case when ${or(parts(starts))} then 0 else 1 end`,
  };
}

type Def = {
  kind: string; label: string; perm: string; module?: string; fields: string[]; table: string; from?: string;
  cols: string; scope?: boolean; extra?: (ctx: RequestContext) => RawBuilder<unknown> | null; order: string;
  shape: (r: any) => SearchItem;
};

const DEFS: Def[] = [
  { kind: 'party', label: 'Parties', perm: 'parties.view', table: 'parties p', fields: ['p.name', 'p.phone', 'p.gstin'], order: 'p.name',
    cols: 'p.id, p.name, p.phone, p.gstin, p.type',
    shape: (r) => ({ id: r.id, title: r.name, subtitle: [r.type, r.phone, r.gstin].filter(Boolean).join(' · '), route: `/parties/${r.id}` }) },
  { kind: 'item', label: 'Items', perm: 'items.view', table: 'items i', fields: ['i.name', 'i.sku', 'i.barcode'], order: 'i.name',
    cols: 'i.id, i.name, i.sku, i.barcode',
    shape: (r) => ({ id: r.id, title: r.name, subtitle: [r.sku, r.barcode].filter(Boolean).join(' · '), route: `/items/${r.id}` }) },
  { kind: 'invoice', label: 'Invoices', perm: 'invoices.view', table: 'invoices v join parties p on p.id = v.party_id', scope: true,
    fields: ['v.number'], order: 'v.invoice_date desc', cols: 'v.id, v.number, v.total, v.invoice_date, v.status, p.name as party',
    shape: (r) => ({ id: r.id, title: r.number, subtitle: `${r.party} · ${money(r.total)} · ${r.status}`, route: `/invoices/${r.id}` }) },
  { kind: 'purchase', label: 'Purchase bills', perm: 'purchases.view', table: 'purchases v join parties p on p.id = v.party_id', scope: true,
    fields: ['v.number', 'v.supplier_invoice_no'], order: 'v.bill_date desc',
    cols: 'v.id, v.number, v.supplier_invoice_no, v.net_payable, v.status, p.name as party',
    shape: (r) => ({ id: r.id, title: r.number, subtitle: `${r.party} · ${money(r.net_payable)}${r.supplier_invoice_no ? ` · ${r.supplier_invoice_no}` : ''}`, route: `/purchases/${r.id}` }) },
  { kind: 'sales_order', label: 'Sales orders', perm: 'sales_orders.view', table: 'sales_orders v join parties p on p.id = v.party_id', scope: true,
    fields: ['v.number', 'v.external_ref'], order: 'v.order_date desc', cols: 'v.id, v.number, v.status, p.name as party',
    shape: (r) => ({ id: r.id, title: r.number, subtitle: `${r.party} · ${r.status}`, route: `/sales-orders/${r.id}` }) },
  { kind: 'quotation', label: 'Quotations', perm: 'quotations.view', table: 'quotations v join parties p on p.id = v.party_id', scope: true,
    fields: ['v.number'], order: 'v.quote_date desc', cols: 'v.id, v.number, v.total, v.status, p.name as party',
    shape: (r) => ({ id: r.id, title: r.number, subtitle: `${r.party} · ${money(r.total)} · ${r.status}`, route: `/quotations/${r.id}` }) },
  { kind: 'payment', label: 'Receipts and payments', perm: 'payments.view', table: 'payments v join parties p on p.id = v.party_id',
    fields: ['v.number', 'v.reference'], order: 'v.payment_date desc', cols: 'v.id, v.number, v.kind, v.amount, v.reference, p.name as party',
    shape: (r) => ({ id: r.id, title: r.number, subtitle: `${r.party} · ${money(r.amount)}${r.reference ? ` · ${r.reference}` : ''}`,
      route: `/${r.kind === 'receipt' ? 'receipts' : 'payments'}/${r.id}` }) },
  { kind: 'employee', label: 'Employees', perm: 'payroll.view', module: 'payroll', table: 'employees e', fields: ['e.name', 'e.code', 'e.phone'], order: 'e.name',
    cols: 'e.id, e.name, e.code, e.designation',
    shape: (r) => ({ id: r.id, title: r.name, subtitle: [r.code, r.designation].filter(Boolean).join(' · '), route: '/hr/employees' }) },
  { kind: 'lead', label: 'Leads', perm: 'crm.view', module: 'crm', table: 'crm_leads l', fields: ['l.name', 'l.phone', 'l.company_name', 'l.email'], order: 'l.created_at desc',
    cols: 'l.id, l.name, l.company_name, l.phone, l.status',
    extra: (ctx) => (ctx.can('crm.all') ? null : sql`l.owner_id = ${ctx.userId}`),
    shape: (r) => ({ id: r.id, title: r.name, subtitle: [r.company_name, r.phone, r.status].filter(Boolean).join(' · '), route: `/crm/leads/${r.id}` }) },
  { kind: 'deal', label: 'Deals', perm: 'crm.view', module: 'crm', table: 'crm_deals d', fields: ['d.title'], order: 'd.created_at desc',
    cols: 'd.id, d.title, d.value, d.status',
    extra: (ctx) => (ctx.can('crm.all') ? null : sql`d.owner_id = ${ctx.userId}`),
    shape: (r) => ({ id: r.id, title: r.title, subtitle: `${money(r.value)} · ${r.status}`, route: `/crm/deals/${r.id}` }) },
];

export async function searchRoutes(app: FastifyInstance) {
  app.get('/search', async (req) => {
    const ctx = req.ctx;
    const q = parse(query, req.query);
    if (q.q.length < 2) return { q: q.q, groups: [] as SearchGroup[] };
    return ctx.tx(async (tx) => {
      const company = await tx.selectFrom('companies').select(['enabled_modules', 'business_type', 'country', 'plan'])
        .where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const modules = effectiveModules(company);
      const scope = scopedLocationIds(ctx);
      const groups: SearchGroup[] = [];
      for (const d of DEFS) {
        if (!ctx.can(d.perm) || (d.module && !modules.includes(d.module))) continue;
        const alias = d.table.split(' ')[1]!;
        const m = match(d.fields, q.q);
        const conds = [sql`${sql.raw(alias)}.company_id = ${ctx.companyId}`, m.where];
        if (d.scope && scope) conds.push(sql`v.location_id in (${sql.join(scope)})`);
        const extra = d.extra?.(ctx);
        if (extra) conds.push(extra);
        const rows = await sql<any>`select ${sql.raw(d.cols)} from ${sql.raw(d.table)} where ${sql.join(conds, sql` and `)}
          order by ${m.rank}, ${sql.raw(d.order)} limit ${q.limit}`.execute(tx);
        if (rows.rows.length) groups.push({ kind: d.kind, label: d.label, items: rows.rows.map(d.shape) });
      }
      return { q: q.q, groups };
    });
  });
}
