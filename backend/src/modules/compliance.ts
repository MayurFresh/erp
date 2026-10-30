import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, daysBetween, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { addPeriodMonths, advanceTaxDates, form140Due, gstReturnPeriod, gstr1Due, gstr3bDue, gstr9Due, isPmt06Month, pmt06Due } from '../lib/due-dates.ts';
import { filedRecord } from '../lib/filing-json.ts';
import { GSTR9_MANDATORY_ABOVE } from '../lib/gst-penalties.ts';
import { turnoverOf } from './gst-filing.ts';
import { badRequest, notFound } from '../lib/errors.ts';
import { validRates, rateKind } from '../lib/rates.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { itcAgeing } from './gst-returns.ts';
import { tdsMonths } from './tds.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const CATEGORIES = ['licence', 'registration', 'insurance', 'certificate', 'agreement', 'other'] as const;

const docFields = {
  name: z.string().trim().min(2).max(200),
  category: z.enum(CATEGORIES),
  docNo: z.string().trim().max(100).nullable().optional(),
  issuedBy: z.string().trim().max(200).nullable().optional(),
  issueDate: dateField.nullable().optional(),
  expiryDate: dateField.nullable().optional(),
  remindDays: z.coerce.number().int().min(0).max(365).optional(),
  locationId: z.uuid().nullable().optional(),
  fileId: z.uuid().nullable().optional(),
  notes: z.string().trim().max(1000).nullable().optional(),
};
const createBody = z.object(docFields);
const patchBody = z.object({ ...docFields, isActive: z.boolean().optional() }).partial();
const listQuery = pagingQuery.extend({
  status: z.enum(['valid', 'expiring', 'expired', 'no_expiry']).optional(),
  category: z.enum(CATEGORIES).optional(),
  locationId: z.uuid().optional(),
  page: z.coerce.number().int().min(1).optional(),
  pageSize: z.coerce.number().int().min(1).max(200).optional(),
});

export function docStatus(expiry: string | null, remindDays: number, today: string) {
  if (!expiry) return { status: 'no_expiry' as const, daysLeft: null };
  const daysLeft = daysBetween(today, expiry);
  return { status: (daysLeft < 0 ? 'expired' : daysLeft <= remindDays ? 'expiring' : 'valid') as 'valid' | 'expiring' | 'expired', daysLeft };
}

function docSelect(tx: Tx, companyId: string) {
  return tx.selectFrom('compliance_docs as d').leftJoin('locations as l', 'l.id', 'd.location_id')
    .selectAll('d').select('l.name as location_name').where('d.company_id', '=', companyId);
}
type DocRow = Awaited<ReturnType<ReturnType<typeof docSelect>['executeTakeFirstOrThrow']>>;
const docJson = (r: DocRow, today: string) => ({
  id: r.id, name: r.name, category: r.category, docNo: r.doc_no, issuedBy: r.issued_by, issueDate: r.issue_date, expiryDate: r.expiry_date,
  remindDays: r.remind_days, locationId: r.location_id, locationName: r.location_name, fileId: r.file_id, notes: r.notes, isActive: r.is_active,
  ...docStatus(r.expiry_date, r.remind_days, today), createdAt: r.created_at, updatedAt: r.updated_at,
});

async function checkRefs(tx: Tx, ctx: RequestContext, b: { locationId?: string | null; fileId?: string | null }) {
  if (b.locationId) {
    const l = await tx.selectFrom('locations').select('id').where('id', '=', b.locationId).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!l) throw badRequest('Location not found.', { locationId: 'Not found' });
    ctx.requireLocation(b.locationId);
  }
  if (b.fileId) {
    const f = await tx.selectFrom('files').select('id').where('id', '=', b.fileId).executeTakeFirst();
    if (!f) throw badRequest('File not found.', { fileId: 'Not found' });
  }
}

async function loadDoc(tx: Tx, ctx: RequestContext, id: string) {
  const r = await docSelect(tx, ctx.companyId).where('d.id', '=', id).executeTakeFirst();
  if (!r || (r.location_id && !ctx.canAccessLocation(r.location_id))) throw notFound('Compliance document');
  return docJson(r, todayIst());
}

interface Alert { kind: string; severity: 'info' | 'warn' | 'overdue'; title: string; detail: string; dueDate: string | null; link: string }
const sev = (due: string, today: string): Alert['severity'] => (due < today ? 'overdue' : daysBetween(today, due) <= 7 ? 'warn' : 'info');

async function buildAlerts(tx: Tx, ctx: RequestContext, days: number): Promise<Alert[]> {
  const today = todayIst();
  const horizon = addDays(today, days);
  const alerts: Alert[] = [];

  if (ctx.can('compliance.view')) {
    let q = docSelect(tx, ctx.companyId).where('d.is_active', '=', true).where('d.expiry_date', 'is not', null).where('d.expiry_date', '<=', horizon);
    const scope = scopedLocationIds(ctx);
    if (scope) q = q.where((eb) => eb.or([eb('d.location_id', 'is', null), eb('d.location_id', 'in', scope)]));
    for (const d of await q.execute()) {
      const s = docStatus(d.expiry_date, d.remind_days, today);
      alerts.push({
        kind: 'doc_expiry', severity: s.status === 'expired' ? 'overdue' : s.daysLeft! <= 7 ? 'warn' : 'info',
        title: `${d.name} ${s.status === 'expired' ? 'has expired' : 'expires soon'}`,
        detail: s.status === 'expired' ? `Expired ${-s.daysLeft!} day${s.daysLeft === -1 ? '' : 's'} ago` : `${s.daysLeft} day${s.daysLeft === 1 ? '' : 's'} left`,
        dueDate: d.expiry_date, link: '/compliance-docs',
      });
    }
  }

  if (ctx.can('gst.view')) {
    const filing = (await tx.selectFrom('companies').select('gst_filing').where('id', '=', ctx.companyId).executeTakeFirstOrThrow()).gst_filing as 'monthly' | 'quarterly';
    const cur = today.slice(0, 7);
    const seen = new Set<string>();
    // Return periods from two months back to the current month; filing is not tracked, so dues more than 30 days old are not repeated.
    for (let i = -2; i <= 0; i++) {
      const period = addPeriodMonths(cur, i);
      for (const [kind, due, name] of [['gstr1_due', gstr1Due(period, filing), 'GSTR-1'], ['gstr3b_due', gstr3bDue(period, filing), 'GSTR-3B']] as const) {
        if (due > horizon || daysBetween(due, today) > 30 || seen.has(`${kind}${due}`)) continue;
        seen.add(`${kind}${due}`);
        if (await filedRecord(tx, ctx.companyId, kind === 'gstr1_due' ? 'gstr1' : 'gstr3b', gstReturnPeriod(period, filing))) continue;
        alerts.push({ kind, severity: sev(due, today), title: `${name} for ${period} is due`, detail: `Due ${due}`, dueDate: due, link: '/gst-returns' });
      }
    }
    if (filing === 'quarterly') {
      for (let i = -2; i <= 0; i++) {
        const period = addPeriodMonths(cur, i);
        const due = pmt06Due(period);
        if (!isPmt06Month(period) || due > horizon || daysBetween(due, today) > 30) continue;
        if (await filedRecord(tx, ctx.companyId, 'pmt06', period)) continue;
        alerts.push({ kind: 'pmt06_due', severity: sev(due, today), title: `PMT-06 for ${period} is due`, detail: `Pay the month's GST by challan, due ${due}`, dueDate: due, link: '/gst-returns' });
      }
    }
    for (const fy of new Set([financialYear(addDays(today, -365)), financialYear(today)])) {
      const due = gstr9Due(fy);
      if (due > horizon || daysBetween(due, today) > 30 || today < `${Number(fy.slice(0, 4)) + 1}-04-01`) continue;
      if (await filedRecord(tx, ctx.companyId, 'gstr9', fy)) continue;
      if ((await turnoverOf(tx, ctx.companyId, fy)) <= GSTR9_MANDATORY_ABOVE) continue;
      alerts.push({ kind: 'gstr9_due', severity: sev(due, today), title: `GSTR-9 for ${fy} is due`, detail: `Annual return, due ${due}`, dueDate: due, link: '/gst-returns' });
    }
    const itc = await itcAgeing(tx, ctx.companyId, today);
    const risky = itc.rows.filter((r) => r.status !== 'ok');
    if (risky.length) {
      const due = risky.some((r) => r.status === 'due');
      alerts.push({
        kind: 'itc_180', severity: due ? 'overdue' : 'warn', title: `ITC at risk on ${risky.length} unpaid purchase${risky.length > 1 ? 's' : ''}`,
        detail: `Unpaid beyond 180 days reverses ITC of Rs ${risky.reduce((s, r) => s + r.reversal, 0).toFixed(2)}`, dueDate: risky[0]!.day180, link: '/itc-ageing',
      });
    }
  }

  if (ctx.can('tds.view')) {
    const fys = [financialYear(today), financialYear(addDays(today, -365))];
    const [thisFy, lastFy] = [...new Set(fys)];
    for (const fy of [lastFy, thisFy].filter((x): x is string => !!x)) {
      for (const m of await tdsMonths(tx, ctx.companyId, fy, today)) {
        if (m.pending > 0 && m.dueDate <= horizon) {
          alerts.push({ kind: 'tds_deposit', severity: sev(m.dueDate, today), title: `TDS for ${m.month} to deposit`, detail: `Rs ${m.pending.toFixed(2)} pending`, dueDate: m.dueDate, link: '/tds' });
        }
      }
      for (const quarter of [1, 2, 3, 4] as const) {
        const due = form140Due(fy, quarter);
        if (due > horizon || daysBetween(due, today) > 30) continue;
        if (await filedRecord(tx, ctx.companyId, 'tds_140', `${fy}-Q${quarter}`)) continue;
        const start = addPeriodMonths(`${fy.slice(0, 4)}-04`, (quarter - 1) * 3);
        const n = await tx.selectFrom('tds_deductions').select((eb) => eb.fn.countAll<number>().as('n'))
          .where('company_id', '=', ctx.companyId).where('status', '=', 'active').where('amount', '>', 0).where('fy', '=', fy)
          .where('deduction_date', '>=', `${start}-01`).where('deduction_date', '<', `${addPeriodMonths(start, 3)}-01`).executeTakeFirstOrThrow();
        if (Number(n.n) > 0) alerts.push({ kind: 'tds_statement', severity: sev(due, today), title: `Form 140 for Q${quarter} ${fy}`, detail: `${n.n} deduction${Number(n.n) > 1 ? 's' : ''} to report`, dueDate: due, link: '/tds' });
      }
    }
  }

  if (ctx.can('tax.view')) {
    for (const fy of new Set([financialYear(addDays(today, -365)), financialYear(today)])) {
      for (const [i, a] of advanceTaxDates(fy).entries()) {
        if (a.dueDate < today || a.dueDate > horizon) continue;
        alerts.push({ kind: 'advance_tax_due', severity: sev(a.dueDate, today), title: `Advance tax instalment ${i + 1} for ${fy}`, detail: `Cumulative ${a.cumulativePct}% of the year's tax by ${a.dueDate}`, dueDate: a.dueDate, link: '/income-tax' });
      }
    }
  }

  if (ctx.can('reports.view') || ctx.can('purchases.view')) {
    const rows = await tx.selectFrom('purchases').select(['net_payable', 'amount_paid', 'msme_due_date'])
      .where('company_id', '=', ctx.companyId).where('status', '=', 'posted').where('msme_due_date', 'is not', null).where('msme_due_date', '<', today)
      .whereRef('amount_paid', '<', 'net_payable').execute();
    if (rows.length) {
      const unpaid = rows.reduce((s, r) => s + r.net_payable - r.amount_paid, 0);
      alerts.push({
        kind: 'msme_overdue', severity: 'overdue', title: `${rows.length} MSME supplier bill${rows.length > 1 ? 's' : ''} overdue`,
        detail: `Rs ${unpaid.toFixed(2)} unpaid past the 45-day limit; interest accrues`, dueDate: rows.map((r) => r.msme_due_date!).sort()[0]!, link: '/msme-dues',
      });
    }
  }

  if (ctx.can('books.lock')) {
    const c = await tx.selectFrom('companies').select('books_locked_until').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
    const y = Number(today.slice(0, 4));
    const lastFyEnd = `${today.slice(5, 7) >= '04' ? y : y - 1}-03-31`;
    const lock = c.books_locked_until;
    if (!lock) alerts.push({ kind: 'books_unlocked', severity: 'info', title: 'Books are not locked', detail: 'Lock closed periods so old entries cannot change.', dueDate: null, link: '/company' });
    else if (lock < lastFyEnd && today > addDays(lastFyEnd, 183)) {
      alerts.push({ kind: 'books_unlocked', severity: 'info', title: 'Books for last year are still open', detail: `Locked only until ${lock}.`, dueDate: null, link: '/company' });
    }
  }

  return alerts.sort((a, b) => (a.dueDate ?? '9999').localeCompare(b.dueDate ?? '9999'));
}

interface Check { key: string; ok: boolean; severity: 'required' | 'recommended'; title: string; detail: string; link: string }

async function buildHealth(tx: Tx, ctx: RequestContext): Promise<{ score: number; checks: Check[] }> {
  const today = todayIst();
  const c = await tx.selectFrom('companies').selectAll().where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  const one = async (q: { select: (e: any) => any }) => Number((await (q as any).executeTakeFirstOrThrow()).n);
  const count = (table: any) => tx.selectFrom(table).select((eb: any) => eb.fn.countAll().as('n')).where('company_id', '=', ctx.companyId);
  const hasTdsParty = (await one(count('parties').where('tds_section_id', 'is not', null))) > 0;
  const hasDeduction = (await one(count('tds_deductions'))) > 0;
  const activeLocations = await one(count('locations').where('is_active', '=', true));
  const items = await tx.selectFrom('items').select(['hsn_code', 'gst_rate']).where('company_id', '=', ctx.companyId).where('is_active', '=', true).execute();
  const noHsn = items.filter((i) => !i.hsn_code?.trim()).length;
  const rateSets = { goods: await validRates(tx, today, 'goods'), services: await validRates(tx, today, 'services') };
  const badRate = items.filter((i) => !rateSets[rateKind(i.hsn_code)].has(Number(i.gst_rate))).length;
  const vendorNoPan = await one(count('parties').where('type', 'in', ['vendor', 'both']).where('tds_section_id', 'is not', null).where((eb: any) => eb.or([eb('pan', 'is', null), eb('pan', '=', '')])));
  const custNoState = await one(count('parties').where('type', 'in', ['customer', 'both']).where('gstin', 'is not', null).where('state_code', 'is', null));
  const msmeVendors = await one(count('parties').where('msme_category', 'in', ['micro', 'small', 'medium']));
  const expired = await one(count('compliance_docs').where('is_active', '=', true).where('expiry_date', '<', today));
  const lockOk = !!c.books_locked_until && c.books_locked_until >= addDays(today, -548);
  const filled = (v: string | null) => !!v?.trim();

  const checks: Check[] = [
    { key: 'gstin', ok: filled(c.gstin), severity: 'required', title: 'Company GSTIN', detail: filled(c.gstin) ? c.gstin! : 'Add your GSTIN in company settings.', link: '/company' },
    { key: 'pan', ok: filled(c.pan), severity: 'required', title: 'Company PAN', detail: filled(c.pan) ? c.pan! : 'Add your PAN in company settings.', link: '/company' },
    { key: 'address', ok: filled(c.address) && filled(c.pincode), severity: 'required', title: 'Address and pincode', detail: filled(c.address) && filled(c.pincode) ? 'Set' : 'Both are needed on invoices and e-invoices.', link: '/company' },
    {
      key: 'tan', ok: !(hasTdsParty || hasDeduction) || filled(c.tan), severity: 'required', title: 'TAN for TDS',
      detail: !(hasTdsParty || hasDeduction) ? 'Not needed until you deduct TDS.' : filled(c.tan) ? c.tan! : 'You deduct TDS, so add your TAN.', link: '/company',
    },
    { key: 'location', ok: activeLocations > 0, severity: 'required', title: 'An active location', detail: `${activeLocations} active`, link: '/locations' },
    {
      key: 'bank_upi', ok: filled(c.bank_name) && filled(c.bank_account_no) && filled(c.bank_ifsc) && filled(c.upi_id), severity: 'recommended',
      title: 'Bank account and UPI ID', detail: 'Shown on invoices and used for the payment QR code.', link: '/company',
    },
    { key: 'invoice_terms', ok: filled(c.invoice_terms), severity: 'recommended', title: 'Invoice terms', detail: filled(c.invoice_terms) ? 'Set' : 'Add payment and return terms for invoices.', link: '/company' },
    { key: 'item_hsn', ok: noHsn === 0, severity: 'recommended', title: 'HSN code on every item', detail: noHsn ? `${noHsn} item${noHsn > 1 ? 's' : ''} missing` : 'All items have one', link: '/items' },
    { key: 'item_gst_rates', ok: badRate === 0, severity: 'recommended', title: 'Valid GST rate on every item', detail: badRate ? `${badRate} item${badRate > 1 ? 's' : ''} with a rate that is not valid today` : 'All rates are valid', link: '/items' },
    { key: 'vendor_pan', ok: vendorNoPan === 0, severity: 'recommended', title: 'PAN for vendors with TDS', detail: vendorNoPan ? `${vendorNoPan} vendor${vendorNoPan > 1 ? 's' : ''} missing PAN (higher TDS rate applies)` : 'All set', link: '/parties' },
    { key: 'customer_state', ok: custNoState === 0, severity: 'recommended', title: 'State code for customers with GSTIN', detail: custNoState ? `${custNoState} customer${custNoState > 1 ? 's' : ''} missing` : 'All set', link: '/parties' },
    { key: 'books_lock', ok: lockOk, severity: 'recommended', title: 'Books lock set in the last 18 months', detail: c.books_locked_until ? `Locked until ${c.books_locked_until}` : 'Not locked', link: '/company' },
    {
      key: 'msme_bank_rate', ok: msmeVendors === 0 || c.msme_bank_rate !== null, severity: 'recommended', title: 'RBI bank rate for MSME interest',
      detail: msmeVendors === 0 ? 'No MSME vendors yet' : c.msme_bank_rate !== null ? `${c.msme_bank_rate}%` : 'Set it to compute interest on late MSME payments.', link: '/company',
    },
    { key: 'expired_docs', ok: expired === 0, severity: 'recommended', title: 'No expired licences or registrations', detail: expired ? `${expired} expired` : 'None expired', link: '/compliance-docs' },
  ];
  return { score: Math.round((100 * checks.filter((x) => x.ok).length) / checks.length), checks };
}

export async function complianceRoutes(app: FastifyInstance) {
  app.get('/compliance-docs', async (req) => {
    const ctx = req.ctx;
    ctx.require('compliance.view');
    const q = parse(listQuery, req.query);
    const today = todayIst();
    return ctx.tx(async (tx) => {
      let base = docSelect(tx, ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where((eb) => eb.or([eb('d.location_id', 'is', null), eb('d.location_id', 'in', scope)]));
      if (q.category) base = base.where('d.category', '=', q.category);
      if (q.locationId) base = base.where('d.location_id', '=', q.locationId);
      if (q.status === 'no_expiry') base = base.where('d.expiry_date', 'is', null);
      if (q.status === 'expired') base = base.where('d.expiry_date', '<', today);
      if (q.status === 'expiring') base = base.where('d.expiry_date', '>=', today).where(sql<boolean>`d.expiry_date - d.remind_days <= ${today}::date`);
      if (q.status === 'valid') base = base.where(sql<boolean>`d.expiry_date - d.remind_days > ${today}::date`);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('d.name', 'ilike', t), eb('d.doc_no', 'ilike', t), eb('d.issued_by', 'ilike', t)]));
      }
      const limit = q.pageSize ?? q.limit;
      const offset = q.page ? (q.page - 1) * limit : q.offset;
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy(sql`d.expiry_date asc nulls last`).orderBy('d.name').limit(limit).offset(offset).execute();
      return { data: rows.map((r) => docJson(r, today)), total };
    });
  });

  app.post('/compliance-docs', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('compliance.manage');
    const b = parse(createBody, req.body);
    if (b.issueDate && b.expiryDate && b.expiryDate < b.issueDate) throw badRequest('Expiry cannot be before the issue date.', { expiryDate: 'Before issue date' });
    const doc = await ctx.tx(async (tx) => {
      await checkRefs(tx, ctx, b);
      const row = await tx.insertInto('compliance_docs').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.name, category: b.category, doc_no: b.docNo ?? null, issued_by: b.issuedBy ?? null,
        issue_date: b.issueDate ?? null, expiry_date: b.expiryDate ?? null, remind_days: b.remindDays ?? 30, location_id: b.locationId ?? null,
        file_id: b.fileId ?? null, notes: b.notes ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'compliance_doc', row.id, 'create', null, { name: b.name, expiryDate: b.expiryDate ?? null });
      return loadDoc(tx, ctx, row.id);
    });
    return reply.status(201).send(doc);
  });

  app.get<{ Params: { id: string } }>('/compliance-docs/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('compliance.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadDoc(tx, ctx, id));
  });

  app.patch<{ Params: { id: string } }>('/compliance-docs/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('compliance.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const cur = await loadDoc(tx, ctx, id);
      await checkRefs(tx, ctx, b);
      const issue = b.issueDate === undefined ? cur.issueDate : b.issueDate;
      const expiry = b.expiryDate === undefined ? cur.expiryDate : b.expiryDate;
      if (issue && expiry && expiry < issue) throw badRequest('Expiry cannot be before the issue date.', { expiryDate: 'Before issue date' });
      const set: Record<string, unknown> = { updated_at: new Date() };
      const map: [keyof typeof b, string][] = [['name', 'name'], ['category', 'category'], ['docNo', 'doc_no'], ['issuedBy', 'issued_by'], ['issueDate', 'issue_date'],
        ['expiryDate', 'expiry_date'], ['remindDays', 'remind_days'], ['locationId', 'location_id'], ['fileId', 'file_id'], ['notes', 'notes'], ['isActive', 'is_active']];
      for (const [k, col] of map) if (b[k] !== undefined) set[col] = b[k];
      await tx.updateTable('compliance_docs').set(set).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'compliance_doc', id, 'update', { expiryDate: cur.expiryDate }, { expiryDate: expiry });
      return loadDoc(tx, ctx, id);
    });
  });

  app.get('/compliance/alerts', async (req) => {
    const ctx = req.ctx;
    ctx.require('dashboard.view', 'compliance.view', 'gst.view', 'tds.view');
    const q = parse(z.object({ days: z.coerce.number().int().min(0).max(365).default(30) }), req.query);
    return ctx.tx(async (tx) => ({ data: await buildAlerts(tx, ctx, q.days) }));
  });

  app.get('/setup/health', async (req) => {
    const ctx = req.ctx;
    ctx.require('company.manage', 'compliance.view');
    return ctx.tx((tx) => buildHealth(tx, ctx));
  });
}
