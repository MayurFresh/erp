import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { daysBetween, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { advanceTaxDates, form140Due, fyMonths, gstr1Due, gstr3bDue, gstr9Due, isPmt06Month, pmt06Due } from '../lib/due-dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { filedRecord, filingJson, filingSelect } from '../lib/filing-json.ts';
import { GSTR9_MANDATORY_ABOVE, gstLateFee } from '../lib/gst-penalties.ts';
import { moneyField } from '../lib/numbers.ts';
import { canFile, type PrefileCheck } from '../lib/prefile.ts';
import { notes, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { buildSetoff, gstPrefileCheck, postSetoffJournal, previousFy, turnoverOf } from './gst-filing.ts';
import { tdsPrefileCheck } from './tds.ts';

const RETURN_TYPES = ['gstr1', 'iff', 'gstr3b', 'pmt06', 'gstr9', 'gstr9c', 'tds_140', 'itr'] as const;
type ReturnType = (typeof RETURN_TYPES)[number];
const MONTHLY = /^\d{4}-(0[1-9]|1[0-2])$/;
const FY = /^\d{4}-\d{2}$/;
const QUARTER = /^\d{4}-\d{2}-Q[1-4]$/;
const fyValid = (v: string) => (Number(v.slice(0, 4)) + 1) % 100 === Number(v.slice(5, 7));
const fyField = z.string().regex(FY, 'Use a financial year such as 2026-27').refine(fyValid, 'Not a financial year');

const permissionOf = (t: ReturnType) => (t === 'tds_140' ? 'tds.manage' : t === 'itr' ? 'tax.manage' : 'gst.manage');
function periodOk(t: ReturnType, p: string): boolean {
  if (t === 'tds_140') return QUARTER.test(p) && fyValid(p.slice(0, 7));
  if (t === 'gstr9' || t === 'gstr9c' || t === 'itr') return FY.test(p) && fyValid(p);
  return MONTHLY.test(p);
}

const createBody = z.object({
  returnType: z.enum(RETURN_TYPES), period: z.string().max(10),
  filedOn: z.string().refine(isValidDate, 'Use YYYY-MM-DD').refine((v) => v <= todayIst(), 'Cannot be in the future'),
  arn: z.string().trim().min(1).max(60).optional(), amountPaid: moneyField.optional(), notes: notes.optional(),
  exportSha256: z.string().regex(/^[0-9a-f]{64}$/i, 'Use a 64-character hex SHA-256').optional(),
  acknowledgeFailures: z.boolean().optional(), postSetoff: z.boolean().optional(), igstSplit: z.enum(['cgst_first', 'sgst_first']).optional(),
});

const failedOnly = (c: PrefileCheck[]) => c.filter((x) => x.status === 'fail');

export async function filingRoutes(app: FastifyInstance) {
  app.get('/filings', async (req) => {
    const ctx = req.ctx;
    ctx.require('compliance.view');
    const q = parse(z.object({ returnType: z.enum(RETURN_TYPES).optional(), fy: fyField.optional(), status: z.enum(['filed', 'cancelled']).optional() }), req.query);
    return ctx.tx(async (tx) => {
      let b = filingSelect(tx, ctx.companyId);
      if (q.returnType) b = b.where('f.return_type', '=', q.returnType);
      if (q.status) b = b.where('f.status', '=', q.status);
      if (q.fy) {
        const months = fyMonths(q.fy);
        b = b.where((eb) => eb.or([eb('f.period', 'in', months), eb('f.period', '=', q.fy!), eb('f.period', 'like', `${q.fy}-Q%`)]));
      }
      const rows = await b.orderBy('f.period', 'desc').orderBy('f.created_at', 'desc').execute();
      return { data: rows.map(filingJson), total: rows.length };
    });
  });

  app.post('/filings', async (req, reply) => {
    const ctx = req.ctx;
    const b = parse(createBody, req.body);
    ctx.require(permissionOf(b.returnType));
    if (!periodOk(b.returnType, b.period)) throw badRequest('Invalid period for this return.', { period: 'Check the period format' });
    if (b.postSetoff && b.returnType !== 'gstr3b') throw badRequest('postSetoff applies to GSTR-3B only.', { postSetoff: 'Only for gstr3b' });
    const out = await ctx.tx(async (tx) => {
      if (await filedRecord(tx, ctx.companyId, b.returnType, b.period)) throw conflict('This return is already marked filed. Cancel that record first.', 'ALREADY_FILED');
      let checks: PrefileCheck[] = [];
      if (b.returnType === 'gstr1' || b.returnType === 'gstr3b') checks = await gstPrefileCheck(tx, ctx, b.period, b.returnType);
      else if (b.returnType === 'tds_140') checks = await tdsPrefileCheck(tx, ctx.companyId, b.period.slice(0, 7), Number(b.period.slice(-1)) as 1 | 2 | 3 | 4);
      const failed = failedOnly(checks);
      if (!canFile(checks) && !b.acknowledgeFailures) throw conflict('A pre-filing check failed.', 'PREFILE_FAILED', { checks: failed });
      const row = await tx.insertInto('statutory_filings').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, return_type: b.returnType, period: b.period, filed_on: b.filedOn, arn: b.arn ?? null,
        amount_paid: b.amountPaid ?? null, notes: b.notes ?? null, export_sha256: b.exportSha256?.toLowerCase() ?? null,
        acknowledged_failures: JSON.stringify(failed), created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      if (b.postSetoff) {
        const { entryId } = await postSetoffJournal(tx, ctx, row.id, b.period, b.filedOn, b.igstSplit ?? 'cgst_first');
        if (entryId) await tx.updateTable('statutory_filings').set({ setoff_entry_id: entryId }).where('id', '=', row.id).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'statutory_filing', row.id, 'create', null, { returnType: b.returnType, period: b.period, acknowledged: failed.length });
      return filingJson(await filingSelect(tx, ctx.companyId).where('f.id', '=', row.id).executeTakeFirstOrThrow());
    });
    return reply.status(201).send(out);
  });

  app.post<{ Params: { id: string } }>('/filings/:id/cancel', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) }), req.body);
    return ctx.tx(async (tx) => {
      const f = await tx.selectFrom('statutory_filings').select(['id', 'return_type', 'status', 'setoff_entry_id']).where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!f) throw notFound('Filing');
      ctx.require(permissionOf(f.return_type as ReturnType));
      if (f.status === 'cancelled') throw conflict('This filing is already cancelled.', 'ALREADY_CANCELLED');
      await tx.updateTable('statutory_filings').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      if (f.setoff_entry_id) await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Filing cancelled: ${reason}`);
      await writeAudit(tx, auditOf(ctx), 'statutory_filing', id, 'cancel', { status: 'filed' }, { status: 'cancelled', reason });
      return filingJson(await filingSelect(tx, ctx.companyId).where('f.id', '=', id).executeTakeFirstOrThrow());
    });
  });

  app.get('/filings/calendar', async (req) => {
    const ctx = req.ctx;
    ctx.require('compliance.view');
    const q = parse(z.object({ fy: fyField.optional() }), req.query);
    return ctx.tx((tx) => buildCalendar(tx, ctx, q.fy ?? financialYear(todayIst())));
  });
}

interface CalRow {
  returnType: string; period: string; label: string; dueDate: string; status: 'filed' | 'due' | 'overdue' | 'upcoming';
  filingId: string | null; daysLate: number | null; estimate: { lateFee: number; interest: number } | null;
}

async function buildCalendar(tx: Tx, ctx: RequestContext, fy: string) {
  const today = todayIst();
  const company = await tx.selectFrom('companies').select(['gst_filing', 'tan']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  const filing = company.gst_filing as 'monthly' | 'quarterly';
  const filed = await tx.selectFrom('statutory_filings').select(['id', 'return_type', 'period', 'filed_on']).where('company_id', '=', ctx.companyId).where('status', '=', 'filed').execute();
  const find = (t: string, p: string) => filed.find((f) => f.return_type === t && f.period === p);
  const turnover = await turnoverOf(tx, ctx.companyId, previousFy(fy));
  const rows: CalRow[] = [];

  const push = async (returnType: string, period: string, label: string, dueDate: string, estimator?: () => Promise<{ lateFee: number; interest: number } | null>) => {
    const f = find(returnType, period);
    let status: CalRow['status']; let daysLate: number | null = null; let estimate: CalRow['estimate'] = null;
    if (f) { status = 'filed'; daysLate = Math.max(0, daysBetween(dueDate, f.filed_on)); }
    else if (dueDate < today) { status = 'overdue'; daysLate = daysBetween(dueDate, today); if (estimator) estimate = await estimator(); }
    else status = daysBetween(today, dueDate) <= 15 ? 'due' : 'upcoming';
    rows.push({ returnType, period, label, dueDate, status, filingId: f?.id ?? null, daysLate, estimate });
  };

  for (const m of fyMonths(fy)) {
    if (filing === 'quarterly' && Number(m.slice(5)) % 3 !== 0) continue;
    const label = filing === 'quarterly' ? `quarter ending ${m}` : m;
    await push('gstr1', m, `GSTR-1 ${label}`, gstr1Due(m, filing), async () => ({ lateFee: gstLateFee(daysBetween(gstr1Due(m, filing), today), false, turnover), interest: 0 }));
    await push('gstr3b', m, `GSTR-3B ${label}`, gstr3bDue(m, filing), async () => {
      const s = await buildSetoff(tx, ctx, m, 'cgst_first', today);
      return { lateFee: s.late.lateFee, interest: s.late.interest };
    });
  }
  if (filing === 'quarterly') for (const m of fyMonths(fy)) if (isPmt06Month(m)) await push('pmt06', m, `PMT-06 ${m}`, pmt06Due(m));
  if (find('gstr9', fy) || turnover > GSTR9_MANDATORY_ABOVE || (await turnoverOf(tx, ctx.companyId, fy)) > GSTR9_MANDATORY_ABOVE) await push('gstr9', fy, `GSTR-9 ${fy}`, gstr9Due(fy));
  if (company.tan) for (const qn of [1, 2, 3, 4] as const) await push('tds_140', `${fy}-Q${qn}`, `Form 140 Q${qn} ${fy}`, form140Due(fy, qn));
  for (const [i, a] of advanceTaxDates(fy).entries()) {
    const due = a.dueDate;
    rows.push({ returnType: 'advance_tax', period: `${fy}-Q${i + 1}`, label: `Advance tax ${a.cumulativePct}% by ${due}`, dueDate: due,
      status: due < today || daysBetween(today, due) <= 15 ? 'due' : 'upcoming', filingId: null, daysLate: null, estimate: null });
  }
  rows.sort((a, b) => a.dueDate.localeCompare(b.dueDate) || a.returnType.localeCompare(b.returnType));
  return { fy, rows };
}
