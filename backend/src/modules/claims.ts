import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { AppError, badRequest, conflict, notFound } from '../lib/errors.ts';
import { gstinChangeOk, gstinFormat } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { documentRoute } from '../lib/openapi.ts';
import { pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { ensureAccount, payableAccount, round2 } from './claims-common.ts';
import { fileUrl, requireFiles } from './files.ts';
import { myEmployee } from './hr.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const blank = (v: unknown) => (v === '' || v === null ? undefined : v);
const SEE_ALL = ['claims.approve', 'claims.manage'] as const;
const seesAll = (ctx: RequestContext) => SEE_ALL.some((p) => ctx.can(p));

const DEFAULT_CATEGORIES = [
  { name: 'Travel', itc: false }, { name: 'Local conveyance', itc: false }, { name: 'Meals', itc: false },
  { name: 'Accommodation', itc: true }, { name: 'Phone and internet', itc: true }, { name: 'Stationery', itc: true }, { name: 'Other', itc: false },
];

async function ensureCategories(tx: Tx, ctx: RequestContext) {
  const n = await tx.selectFrom('claim_categories').select((eb) => eb.fn.countAll<number>().as('n')).where('company_id', '=', ctx.companyId).executeTakeFirstOrThrow();
  if (Number(n.n) > 0) return;
  for (const c of DEFAULT_CATEGORIES) {
    const acc = await ensureAccount(tx, ctx, `Claims - ${c.name}`, 'expense', 6700);
    await tx.insertInto('claim_categories').values({
      tenant_id: ctx.tenantId, company_id: ctx.companyId, name: c.name, expense_account_id: acc, gst_itc_allowed: c.itc,
    }).onConflict((oc) => oc.doNothing()).execute();
  }
}

const catJson = (c: { id: string; name: string; expense_account_id: string; acc_name: string; gst_itc_allowed: boolean; per_claim_limit: number | null; monthly_limit: number | null; requires_receipt: boolean; is_active: boolean }) => ({
  id: c.id, name: c.name, expenseAccountId: c.expense_account_id, expenseAccountName: c.acc_name, gstItcAllowed: c.gst_itc_allowed,
  perClaimLimit: c.per_claim_limit, monthlyLimit: c.monthly_limit, requiresReceipt: c.requires_receipt, isActive: c.is_active,
});
const catSelect = (tx: Tx) => tx.selectFrom('claim_categories as c').innerJoin('accounts as a', 'a.id', 'c.expense_account_id')
  .select(['c.id', 'c.name', 'c.expense_account_id', 'a.name as acc_name', 'c.gst_itc_allowed', 'c.per_claim_limit', 'c.monthly_limit', 'c.requires_receipt', 'c.is_active']);

const limit = z.preprocess((v) => (v === '' ? null : v), moneyField.refine((v) => v > 0, 'Must be more than zero').nullable().optional());
const catBody = z.object({
  name: z.string().trim().min(1).max(60), expenseAccountId: z.preprocess(blank, z.uuid().optional()),
  gstItcAllowed: z.boolean().optional(), perClaimLimit: limit, monthlyLimit: limit,
  requiresReceipt: z.boolean().optional(), isActive: z.boolean().optional(),
});

const lineBody = z.object({
  categoryId: z.uuid(), expenseDate: dateField, description: z.string().trim().min(1).max(300),
  amount: moneyField.refine((v) => v > 0, 'Must be more than zero'),
  vendorGstin: z.preprocess(blank, gstinFormat.optional()), gstAmount: moneyField.optional(),
  receiptFileId: z.preprocess(blank, z.uuid().optional()),
});
const claimBody = z.object({
  employeeId: z.preprocess(blank, z.uuid().optional()), purpose: z.string().trim().min(2).max(300), claimDate: dateField.optional(),
  lines: z.array(lineBody).min(1, 'Add at least one line').max(50), submit: z.boolean().optional(),
});
const settleBody = z.object({
  mode: z.enum(['pay_now', 'payroll']), accountId: z.preprocess(blank, z.uuid().optional()), payDate: z.preprocess(blank, dateField.optional()),
});
const approveBody = settleBody.partial({ mode: true }).extend({ note: z.string().trim().max(300).optional() });
const listQuery = pagingQuery.extend({
  status: z.enum(['draft', 'submitted', 'approved', 'rejected', 'paid']).optional(), employeeId: z.uuid().optional(),
  mine: z.enum(['true', 'false']).optional(), from: dateField.optional(), to: dateField.optional(),
});

function claimSelect(tx: Tx) {
  return tx.selectFrom('expense_claims as c').innerJoin('employees as e', 'e.id', 'c.employee_id')
    .selectAll('c').select(['e.code as emp_code', 'e.name as emp_name', 'e.user_id as emp_user_id', 'e.location_id as emp_location']);
}
type ClaimRow = Awaited<ReturnType<ReturnType<typeof claimSelect>['executeTakeFirstOrThrow']>>;

function claimJson(ctx: RequestContext, c: ClaimRow, lines: Record<string, unknown>[]) {
  const selfBlocked = c.emp_user_id === ctx.userId || c.created_by === ctx.userId || c.submitted_by === ctx.userId;
  return {
    id: c.id, number: c.number, employeeId: c.employee_id, employeeCode: c.emp_code, employeeName: c.emp_name, purpose: c.purpose,
    claimDate: c.claim_date, status: c.status, total: c.total, gstTotal: c.gst_total, itcTotal: c.itc_total, settlement: c.settlement,
    lines, submittedAt: c.submitted_at, decidedBy: c.decided_by, decidedAt: c.decided_at, decisionNote: c.decision_note,
    paidAt: c.paid_at, payDate: c.pay_date, payrollRunId: c.payroll_run_id,
    canApprove: c.status === 'submitted' && ctx.can('claims.approve') && !selfBlocked,
  };
}

async function linesOf(tx: Tx, claimIds: string[]) {
  if (!claimIds.length) return new Map<string, Record<string, unknown>[]>();
  const rows = await tx.selectFrom('expense_claim_lines as l').innerJoin('claim_categories as k', 'k.id', 'l.category_id')
    .select(['l.id', 'l.claim_id', 'l.line_no', 'l.category_id', 'k.name as category_name', 'l.expense_date', 'l.description', 'l.amount',
      'l.vendor_gstin', 'l.gst_amount', 'l.itc_eligible', 'l.receipt_file_id'])
    .where('l.claim_id', 'in', claimIds).orderBy('l.line_no').execute();
  const out = new Map<string, Record<string, unknown>[]>();
  for (const r of rows) {
    const a = out.get(r.claim_id) ?? [];
    a.push({
      id: r.id, lineNo: r.line_no, categoryId: r.category_id, categoryName: r.category_name, expenseDate: r.expense_date,
      description: r.description, amount: r.amount, vendorGstin: r.vendor_gstin, gstAmount: r.gst_amount, itcEligible: r.itc_eligible,
      receiptFileId: r.receipt_file_id, receiptUrl: r.receipt_file_id ? fileUrl(r.receipt_file_id) : null,
    });
    out.set(r.claim_id, a);
  }
  return out;
}

async function loadClaim(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = claimSelect(tx).where('c.id', '=', id).where('c.company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate('c');
  const row = await q.executeTakeFirst();
  if (!row || (!seesAll(ctx) && row.emp_user_id !== ctx.userId)) throw notFound('Claim');
  return { row, json: claimJson(ctx, row, (await linesOf(tx, [id])).get(id) ?? []) };
}

async function categoriesById(tx: Tx, ctx: RequestContext, ids: string[]) {
  const rows = await tx.selectFrom('claim_categories').selectAll().where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
  return new Map(rows.map((r) => [r.id, r]));
}

async function saveLines(tx: Tx, ctx: RequestContext, claimId: string, lines: z.infer<typeof lineBody>[]) {
  const cats = await categoriesById(tx, ctx, [...new Set(lines.map((l) => l.categoryId))]);
  await requireFiles(tx, lines.filter((l) => l.receiptFileId).map((l, i) => ({ id: l.receiptFileId!, field: `lines.${i}.receiptFileId` })), false);
  const today = todayIst();
  let total = 0, gst = 0, itc = 0;
  const rows = lines.map((l, i) => {
    const cat = cats.get(l.categoryId);
    if (!cat || !cat.is_active) throw badRequest('Choose an active category.', { [`lines.${i}.categoryId`]: 'Not found' });
    if (l.expenseDate > today) throw badRequest('Date cannot be in the future.', { [`lines.${i}.expenseDate`]: 'In the future' });
    const g = l.gstAmount ?? 0;
    if (g >= l.amount) throw badRequest('GST must be less than the bill amount.', { [`lines.${i}.gstAmount`]: 'Too high' });
    const eligible = cat.gst_itc_allowed && g > 0 && !!l.vendorGstin && gstinChangeOk(l.vendorGstin, null);
    total += l.amount; gst += g; if (eligible) itc += g;
    return {
      tenant_id: ctx.tenantId, claim_id: claimId, line_no: i + 1, category_id: l.categoryId, expense_date: l.expenseDate,
      description: l.description, amount: l.amount, vendor_gstin: l.vendorGstin ?? null, gst_amount: g, itc_eligible: eligible,
      receipt_file_id: l.receiptFileId ?? null,
    };
  });
  await tx.deleteFrom('expense_claim_lines').where('claim_id', '=', claimId).execute();
  await tx.insertInto('expense_claim_lines').values(rows).execute();
  await tx.updateTable('expense_claims').set({ total: round2(total), gst_total: round2(gst), itc_total: round2(itc) }).where('id', '=', claimId).execute();
}

async function checkSubmit(tx: Tx, ctx: RequestContext, claimId: string, employeeId: string) {
  const lines = await tx.selectFrom('expense_claim_lines').selectAll().where('claim_id', '=', claimId).execute();
  if (!lines.length) throw badRequest('Add at least one line.', { lines: 'Required' });
  const cats = await categoriesById(tx, ctx, [...new Set(lines.map((l) => l.category_id))]);
  const problems: Record<string, string> = {};
  lines.forEach((l, i) => {
    const c = cats.get(l.category_id)!;
    if (c.requires_receipt && !l.receipt_file_id) problems[`lines.${i}.receiptFileId`] = `${c.name} needs a receipt`;
  });
  const sums = new Map<string, number>();
  const perMonth = new Map<string, number>();
  for (const l of lines) {
    sums.set(l.category_id, (sums.get(l.category_id) ?? 0) + l.amount);
    const k = `${l.category_id}|${l.expense_date.slice(0, 7)}`;
    perMonth.set(k, (perMonth.get(k) ?? 0) + l.amount);
  }
  const prior = await tx.selectFrom('expense_claim_lines as l').innerJoin('expense_claims as c', 'c.id', 'l.claim_id')
    .select(['l.category_id', sql<string>`to_char(l.expense_date, 'YYYY-MM')`.as('m'), sql<string>`sum(l.amount)`.as('s')])
    .where('c.employee_id', '=', employeeId).where('c.status', 'in', ['submitted', 'approved', 'paid']).where('c.id', '<>', claimId)
    .where('l.category_id', 'in', [...sums.keys()]).groupBy(['l.category_id', sql`to_char(l.expense_date, 'YYYY-MM')`]).execute();
  for (const [cid, s] of sums) {
    const c = cats.get(cid)!;
    if (c.per_claim_limit != null && s > c.per_claim_limit) problems[`category.${c.name}`] = `${c.name} is limited to ${c.per_claim_limit} a claim (this claim has ${round2(s)})`;
  }
  for (const [k, s] of perMonth) {
    const [cid, m] = k.split('|') as [string, string];
    const c = cats.get(cid)!;
    if (c.monthly_limit == null) continue;
    const used = prior.filter((p) => p.category_id === cid && p.m === m).reduce((a, p) => a + Number(p.s), 0);
    if (used + s > c.monthly_limit) problems[`month.${c.name}.${m}`] = `${c.name} is limited to ${c.monthly_limit} a month (${m}: ${round2(used)} already claimed, this claim adds ${round2(s)})`;
  }
  if (Object.keys(problems).length) throw badRequest(Object.values(problems)[0]!, { lines: Object.values(problems).join('; '), ...problems });
}

async function resolveEmployee(tx: Tx, ctx: RequestContext, employeeId?: string) {
  if (employeeId) {
    const e = await tx.selectFrom('employees').select(['id', 'user_id', 'status']).where('id', '=', employeeId).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!e) throw notFound('Employee');
    if (e.user_id !== ctx.userId) ctx.require('claims.manage');
    return e.id;
  }
  const me = await myEmployee(tx, ctx);
  if (!me) throw badRequest('Your login is not linked to an employee record. Ask HR to link it.', { employeeId: 'No employee' });
  return me.id;
}

async function postApproval(tx: Tx, ctx: RequestContext, c: ClaimRow) {
  const lines = await tx.selectFrom('expense_claim_lines as l').innerJoin('claim_categories as k', 'k.id', 'l.category_id')
    .select(['l.amount', 'l.gst_amount', 'l.itc_eligible', 'l.vendor_gstin', 'k.expense_account_id']).where('l.claim_id', '=', c.id).execute();
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  const acc = await systemAccounts(tx, ctx);
  const heads = new Map<string, number>();
  let cgst = 0, sgst = 0, igst = 0;
  for (const l of lines) {
    const g = l.itc_eligible ? l.gst_amount : 0;
    heads.set(l.expense_account_id, round2((heads.get(l.expense_account_id) ?? 0) + l.amount - g));
    if (g > 0) {
      if (l.vendor_gstin!.slice(0, 2) === company.state_code) { const h = round2(g / 2); cgst += h; sgst += round2(g - h); } else igst += g;
    }
  }
  const loc = c.emp_location;
  return postJournal(tx, { tenantId: ctx.tenantId, companyId: ctx.companyId, userId: ctx.userId }, {
    date: todayIst(), voucherType: 'expense', voucherId: c.id, number: c.number, narration: `Expense claim ${c.number}: ${c.purpose}`,
    lines: [
      ...[...heads].map(([accountId, amount]) => ({ accountId, amount, locationId: loc })),
      { accountId: acc.input_cgst, amount: round2(cgst), locationId: loc },
      { accountId: acc.input_sgst, amount: round2(sgst), locationId: loc },
      { accountId: acc.input_igst, amount: round2(igst), locationId: loc },
      { accountId: await payableAccount(tx, ctx), amount: -c.total, locationId: loc },
    ],
  });
}

async function settleClaim(tx: Tx, ctx: RequestContext, id: string, b: z.infer<typeof settleBody>) {
  const { row } = await loadClaim(tx, ctx, id, true);
  if (row.status !== 'approved') throw conflict(`Only an approved claim can be settled. This one is ${row.status}.`, 'CLAIM_STATE', { status: row.status });
  if (row.payroll_run_id) throw conflict('This claim is already in a payroll run.', 'CLAIM_IN_RUN');
  if (b.mode === 'payroll') {
    await tx.updateTable('expense_claims').set({ settlement: 'payroll' }).where('id', '=', id).execute();
    await writeAudit(tx, auditOf(ctx), 'expense_claim', id, 'settle_payroll', { status: 'approved' }, { settlement: 'payroll' });
    return;
  }
  if (!b.accountId) throw badRequest('Choose the cash or bank account.', { accountId: 'Required' });
  const a = await tx.selectFrom('accounts').select(['id', 'subtype', 'is_active']).where('id', '=', b.accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!a || !['cash', 'bank'].includes(a.subtype) || !a.is_active) throw badRequest('Choose an active cash or bank account.', { accountId: 'Not a cash or bank account' });
  const date = b.payDate ?? todayIst();
  const entry = await postJournal(tx, { tenantId: ctx.tenantId, companyId: ctx.companyId, userId: ctx.userId }, {
    date, voucherType: 'payment', voucherId: id, number: row.number, narration: `Claim ${row.number} paid to ${row.emp_name}`,
    lines: [{ accountId: await payableAccount(tx, ctx), amount: row.total, locationId: row.emp_location }, { accountId: a.id, amount: -row.total, locationId: row.emp_location }],
  });
  await tx.updateTable('expense_claims').set({ status: 'paid', settlement: 'pay_now', paid_at: new Date(), pay_date: date, pay_account_id: a.id, pay_entry_id: entry }).where('id', '=', id).execute();
  await writeAudit(tx, auditOf(ctx), 'expense_claim', id, 'pay', { status: 'approved' }, { status: 'paid', date });
}

function blockSelf(ctx: RequestContext, c: ClaimRow) {
  if (c.emp_user_id === ctx.userId || c.created_by === ctx.userId || c.submitted_by === ctx.userId) {
    throw new AppError(403, 'SELF_APPROVAL', 'You cannot approve or reject your own claim.');
  }
}

export async function claimRoutes(app: FastifyInstance) {
  app.get('/claims/categories', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.self', 'claims.manage', 'claims.approve');
    return ctx.tx(async (tx) => {
      await ensureCategories(tx, ctx);
      const rows = await catSelect(tx).where('c.company_id', '=', ctx.companyId).orderBy('c.name').execute();
      return { data: rows.map(catJson) };
    });
  });

  async function saveCategory(tx: Tx, ctx: RequestContext, b: z.infer<typeof catBody>, id?: string) {
    let accountId = b.expenseAccountId;
    if (accountId) {
      const a = await tx.selectFrom('accounts').select(['type', 'is_active']).where('id', '=', accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!a || a.type !== 'expense' || !a.is_active) throw badRequest('Choose an active expense account.', { expenseAccountId: 'Not an expense account' });
    } else if (!id) accountId = await ensureAccount(tx, ctx, `Claims - ${b.name}`, 'expense', 6700);
    const dup = await tx.selectFrom('claim_categories').select('id').where('company_id', '=', ctx.companyId).where('name', '=', b.name).executeTakeFirst();
    if (dup && dup.id !== id) throw conflict('A category with this name exists.', 'CONFLICT', { name: 'Already used' });
    const vals = {
      name: b.name, ...(accountId ? { expense_account_id: accountId } : {}),
      ...(b.gstItcAllowed !== undefined ? { gst_itc_allowed: b.gstItcAllowed } : {}),
      ...(b.perClaimLimit !== undefined ? { per_claim_limit: b.perClaimLimit } : {}),
      ...(b.monthlyLimit !== undefined ? { monthly_limit: b.monthlyLimit } : {}),
      ...(b.requiresReceipt !== undefined ? { requires_receipt: b.requiresReceipt } : {}),
      ...(b.isActive !== undefined ? { is_active: b.isActive } : {}),
    };
    let rid = id;
    if (id) {
      const u = await tx.updateTable('claim_categories').set(vals).where('id', '=', id).where('company_id', '=', ctx.companyId).returning('id').executeTakeFirst();
      if (!u) throw notFound('Category');
    } else {
      const r = await tx.insertInto('claim_categories').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, ...vals, expense_account_id: accountId! }).returning('id').executeTakeFirstOrThrow();
      rid = r.id;
    }
    await writeAudit(tx, auditOf(ctx), 'claim_category', rid!, id ? 'update' : 'create', null, b);
    return catJson((await catSelect(tx).where('c.id', '=', rid!).executeTakeFirstOrThrow()));
  }
  app.post('/claims/categories', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('claims.manage');
    const b = parse(catBody, req.body);
    return reply.status(201).send(await ctx.tx(async (tx) => { await ensureCategories(tx, ctx); return saveCategory(tx, ctx, b); }));
  });
  app.patch<{ Params: { id: string } }>('/claims/categories/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('claims.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(catBody.partial({ name: true }), req.body);
    return ctx.tx(async (tx) => {
      const cur = await tx.selectFrom('claim_categories').select('name').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!cur) throw notFound('Category');
      return saveCategory(tx, ctx, { ...b, name: b.name ?? cur.name }, id);
    });
  });

  app.get('/claims/summary', async (req) => {
    const ctx = req.ctx;
    ctx.require(...SEE_ALL);
    const qs = z.object({ groupBy: z.enum(['employee', 'category', 'month']).default('employee'), from: dateField.optional(), to: dateField.optional(),
      status: z.enum(['submitted', 'approved', 'rejected', 'paid']).optional() });
    const q = parse(qs, req.query);
    return ctx.tx(async (tx) => {
      const key = q.groupBy === 'employee' ? sql`e.id::text` : q.groupBy === 'category' ? sql`k.id::text` : sql`to_char(l.expense_date, 'YYYY-MM')`;
      const label = q.groupBy === 'employee' ? sql`e.name` : q.groupBy === 'category' ? sql`k.name` : sql`to_char(l.expense_date, 'YYYY-MM')`;
      const statuses = q.status ? [q.status] : ['submitted', 'approved', 'paid'];
      const r = await sql<{ key: string; label: string; count: string; total: string; gst: string; itc: string }>`
        select ${key} as key, ${label} as label, count(distinct c.id) as count, sum(l.amount) as total, sum(l.gst_amount) as gst,
               sum(case when l.itc_eligible then l.gst_amount else 0 end) as itc
          from expense_claim_lines l join expense_claims c on c.id = l.claim_id
          join employees e on e.id = c.employee_id join claim_categories k on k.id = l.category_id
         where c.company_id = ${ctx.companyId} and c.status = any(${statuses})
           ${q.from ? sql`and l.expense_date >= ${q.from}` : sql``} ${q.to ? sql`and l.expense_date <= ${q.to}` : sql``}
         group by 1, 2 order by ${q.groupBy === 'month' ? sql`1 desc` : sql`sum(l.amount) desc`}`.execute(tx);
      const data = r.rows.map((x) => ({ key: x.key, label: x.label, count: Number(x.count), total: Number(x.total), gst: Number(x.gst), itc: Number(x.itc) }));
      return { data, total: round2(data.reduce((s, x) => s + x.total, 0)) };
    });
  });

  app.get('/claims', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.self', ...SEE_ALL);
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = claimSelect(tx).where('c.company_id', '=', ctx.companyId);
      if (!seesAll(ctx) || q.mine === 'true') base = base.where('e.user_id', '=', ctx.userId);
      if (q.status) base = base.where('c.status', '=', q.status);
      if (q.employeeId) base = base.where('c.employee_id', '=', q.employeeId);
      if (q.from) base = base.where('c.claim_date', '>=', q.from);
      if (q.to) base = base.where('c.claim_date', '<=', q.to);
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('c.claim_date', 'desc').orderBy('c.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      const lines = await linesOf(tx, rows.map((r) => r.id));
      return { data: rows.map((r) => claimJson(ctx, r, lines.get(r.id) ?? [])), total: Number(total) };
    });
  });

  app.post('/claims', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.self', 'claims.manage');
    const b = parse(claimBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const employeeId = await resolveEmployee(tx, ctx, b.employeeId);
      const date = b.claimDate ?? todayIst();
      const number = await nextNumber(tx, ctx, 'expense_claim', financialYear(date));
      const c = await tx.insertInto('expense_claims').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, employee_id: employeeId, purpose: b.purpose, claim_date: date, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await saveLines(tx, ctx, c.id, b.lines);
      if (b.submit) {
        await checkSubmit(tx, ctx, c.id, employeeId);
        await tx.updateTable('expense_claims').set({ status: 'submitted', submitted_at: new Date(), submitted_by: ctx.userId }).where('id', '=', c.id).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'expense_claim', c.id, b.submit ? 'submit' : 'create', null, { number });
      return (await loadClaim(tx, ctx, c.id)).json;
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/claims/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.self', ...SEE_ALL);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => (await loadClaim(tx, ctx, id)).json);
  });

  async function ownerOnly(ctx: RequestContext, c: ClaimRow) {
    if (c.emp_user_id !== ctx.userId && c.created_by !== ctx.userId) ctx.require('claims.manage');
  }

  app.patch<{ Params: { id: string } }>('/claims/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.self', 'claims.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(claimBody, req.body);
    return ctx.tx(async (tx) => {
      const { row } = await loadClaim(tx, ctx, id, true);
      await ownerOnly(ctx, row);
      if (!['draft', 'rejected'].includes(row.status)) throw conflict(`A ${row.status} claim cannot be edited.`, 'CLAIM_STATE', { status: row.status });
      await tx.updateTable('expense_claims').set({ purpose: b.purpose, ...(b.claimDate ? { claim_date: b.claimDate } : {}), status: 'draft', decided_by: null, decided_at: null, decision_note: null }).where('id', '=', id).execute();
      await saveLines(tx, ctx, id, b.lines);
      if (b.submit) {
        await checkSubmit(tx, ctx, id, row.employee_id);
        await tx.updateTable('expense_claims').set({ status: 'submitted', submitted_at: new Date(), submitted_by: ctx.userId }).where('id', '=', id).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'expense_claim', id, 'update', null, { submit: !!b.submit });
      return (await loadClaim(tx, ctx, id)).json;
    });
  });

  app.delete<{ Params: { id: string } }>('/claims/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.self', 'claims.manage');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const { row } = await loadClaim(tx, ctx, id, true);
      await ownerOnly(ctx, row);
      if (row.status !== 'draft') throw conflict('Only a draft claim can be deleted.', 'CLAIM_STATE', { status: row.status });
      await tx.deleteFrom('expense_claims').where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'expense_claim', id, 'delete', { number: row.number }, null);
    });
    return reply.status(204).send();
  });

  app.post<{ Params: { id: string } }>('/claims/:id/submit', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.self', 'claims.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const { row } = await loadClaim(tx, ctx, id, true);
      await ownerOnly(ctx, row);
      if (row.status !== 'draft') throw conflict(`Only a draft claim can be submitted. This one is ${row.status}.`, 'CLAIM_STATE', { status: row.status });
      await checkSubmit(tx, ctx, id, row.employee_id);
      await tx.updateTable('expense_claims').set({ status: 'submitted', submitted_at: new Date(), submitted_by: ctx.userId }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'expense_claim', id, 'submit', { status: 'draft' }, { status: 'submitted' });
      return (await loadClaim(tx, ctx, id)).json;
    });
  });

  app.post<{ Params: { id: string } }>('/claims/:id/approve', async (req) => {
    const ctx = req.ctx;
    ctx.require('claims.approve');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(approveBody, req.body);
    return ctx.tx(async (tx) => {
      const { row } = await loadClaim(tx, ctx, id, true);
      blockSelf(ctx, row);
      if (row.status !== 'submitted') throw conflict(`Only a submitted claim can be approved. This one is ${row.status}.`, 'CLAIM_STATE', { status: row.status });
      if (b.mode) ctx.require('claims.manage');
      const entry = await postApproval(tx, ctx, row);
      await tx.updateTable('expense_claims').set({ status: 'approved', decided_by: ctx.userId, decided_at: new Date(), decision_note: b.note ?? null, entry_id: entry }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'expense_claim', id, 'approve', { status: 'submitted' }, { status: 'approved', entryId: entry });
      if (b.mode) await settleClaim(tx, ctx, id, { mode: b.mode, accountId: b.accountId, payDate: b.payDate });
      return (await loadClaim(tx, ctx, id)).json;
    });
  });

  app.post<{ Params: { id: string } }>('/claims/:id/reject', async (req) => {
    const ctx = req.ctx;
    ctx.require('claims.approve');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(z.object({ note: z.string().trim().min(3, 'Give a reason').max(300) }), req.body);
    return ctx.tx(async (tx) => {
      const { row } = await loadClaim(tx, ctx, id, true);
      blockSelf(ctx, row);
      if (row.status !== 'submitted') throw conflict(`Only a submitted claim can be rejected. This one is ${row.status}.`, 'CLAIM_STATE', { status: row.status });
      await tx.updateTable('expense_claims').set({ status: 'rejected', decided_by: ctx.userId, decided_at: new Date(), decision_note: b.note }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'expense_claim', id, 'reject', { status: 'submitted' }, { status: 'rejected', note: b.note });
      return (await loadClaim(tx, ctx, id)).json;
    });
  });

  app.post<{ Params: { id: string } }>('/claims/:id/settle', async (req) => {
    const ctx = req.ctx;
    ctx.require('claims.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(settleBody, req.body);
    return ctx.tx(async (tx) => { await settleClaim(tx, ctx, id, b); return (await loadClaim(tx, ctx, id)).json; });
  });
}

documentRoute('POST', '/claims', { summary: 'Create or submit an expense claim', body: claimBody });
documentRoute('POST', '/claims/:id/settle', { summary: 'Pay an approved claim now or send it to payroll', body: settleBody });
