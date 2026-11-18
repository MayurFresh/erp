// Gratuity provision: what the company owes each employee as at a date, and a journal that brings the books to that figure.
// Liability = 15/26 x monthly wages x counted years (a part year over six months counts as one), capped per person at the
// company's gratuity cap (payroll_statutory_settings.gratuity_cap, Rs 20,00,000 by default). Everyone is shown and provided for;
// staff below the payment eligibility years are flagged, not left out. NEEDS A CA CHECK for the accounting treatment.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { postJournal } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { isValidDate, todayIst } from '../lib/dates.ts';
import { conflict } from '../lib/errors.ts';
import { basicFlags, loadStatSettings } from '../lib/payroll/load.ts';
import { round2 } from '../lib/payroll/money.ts';
import { gratuityEligible, gratuityFormula, serviceYears } from '../lib/payroll/statutory.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { ensureAccount } from './claims-common.ts';
import { wagesOf } from './payroll-statutory.ts';

export const GRATUITY_ACC = { expense: 'Gratuity Expense', payable: 'Gratuity Payable' } as const;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

async function provisionTable(tx: Tx, ctx: RequestContext, asOf: string) {
  const stat = await loadStatSettings(tx, ctx.companyId);
  const basics = await basicFlags(tx, ctx.companyId);
  const emps = await tx.selectFrom('employees').selectAll().where('company_id', '=', ctx.companyId).where('joining_date', '<=', asOf).where('status', '=', 'active')
    .where((eb) => eb.or([eb('leaving_date', 'is', null), eb('leaving_date', '>', asOf)])).orderBy('code').execute();
  const flags = new Map((await tx.selectFrom('employee_statutory').select(['employee_id', 'fixed_term']).execute()).map((f) => [f.employee_id, f.fixed_term]));
  const rows = [];
  const skipped: { employeeId: string; name: string; reason: string }[] = [];
  for (const e of emps) {
    const w = await wagesOf(tx, ctx, e.id, asOf, stat, basics);
    if (!w) { skipped.push({ employeeId: e.id, name: e.name, reason: 'No salary structure' }); continue; }
    const fixedTerm = flags.get(e.id) ?? false;
    const { completed, counted } = serviceYears(e.joining_date, asOf);
    const formula = gratuityFormula(w.wages, counted);
    const provision = Math.min(formula, stat.gratuityCap);
    rows.push({
      employeeId: e.id, code: e.code, name: e.name, joiningDate: e.joining_date, fixedTerm, wages: w.wages, completedYears: completed, countedYears: counted,
      eligible: gratuityEligible(completed, fixedTerm, { years: stat.gratuityYears, fixedTermYears: stat.gratuityFixedTermYears }),
      underYears: !gratuityEligible(completed, fixedTerm, { years: stat.gratuityYears, fixedTermYears: stat.gratuityFixedTermYears }),
      formula, capped: formula > stat.gratuityCap, provision,
    });
  }
  return { rows, skipped, cap: stat.gratuityCap, eligibleYears: stat.gratuityYears, total: round2(rows.reduce((s, r) => s + r.provision, 0)) };
}

/** Credit balance of Gratuity Payable (0 when the account does not exist yet). */
async function payableBalance(tx: Tx, ctx: RequestContext) {
  const acc = await tx.selectFrom('accounts').select('id').where('company_id', '=', ctx.companyId).where('name', '=', GRATUITY_ACC.payable).executeTakeFirst();
  if (!acc) return 0;
  const r = await tx.selectFrom('journal_lines as l').innerJoin('journal_entries as j', 'j.id', 'l.entry_id')
    .select((eb) => [eb.fn.coalesce(eb.fn.sum<number>('l.credit'), eb.val(0)).as('c'), eb.fn.coalesce(eb.fn.sum<number>('l.debit'), eb.val(0)).as('d')])
    .where('l.account_id', '=', acc.id).where('j.company_id', '=', ctx.companyId).executeTakeFirstOrThrow();
  return round2(Number(r.c) - Number(r.d));
}

async function summary(tx: Tx, ctx: RequestContext, asOf: string) {
  const t = await provisionTable(tx, ctx, asOf);
  const balance = await payableBalance(tx, ctx);
  const last = await tx.selectFrom('gratuity_provisions').selectAll().where('company_id', '=', ctx.companyId).where('as_of', '<=', asOf).orderBy('as_of', 'desc').limit(1).executeTakeFirst();
  const posted = await tx.selectFrom('gratuity_provisions').select(['id', 'posted_amount', 'entry_id']).where('company_id', '=', ctx.companyId).where('as_of', '=', asOf).executeTakeFirst();
  return {
    asOf, cap: t.cap, eligibleYears: t.eligibleYears, data: t.rows, skipped: t.skipped,
    totals: {
      provision: t.total, underYears: round2(t.rows.filter((r) => r.underYears).reduce((s, r) => s + r.provision, 0)), balance,
      toPost: round2(t.total - balance), lastPostedOn: last?.as_of ?? null, lastPostedTotal: last?.total ?? null,
      changeSinceLast: last ? round2(t.total - last.total) : t.total,
    },
    posted: posted ? { id: posted.id, amount: posted.posted_amount, entryId: posted.entry_id } : null,
  };
}

export async function gratuityProvisionRoutes(app: FastifyInstance) {
  app.get('/payroll/gratuity/provision', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view');
    const q = parse(z.object({ asOf: dateField.optional() }), req.query);
    return ctx.tx((tx) => summary(tx, ctx, q.asOf ?? todayIst()));
  });

  app.post('/payroll/gratuity/provision', async (req, reply) => {
    const ctx = req.ctx; ctx.require('payroll.approve');
    const b = parse(z.object({ asOf: dateField.optional() }), req.body ?? {});
    const asOf = b.asOf ?? todayIst();
    const out = await ctx.tx(async (tx) => {
      // One post per company per date: take the lock row first so two clicks cannot both pass the check.
      await tx.selectFrom('companies').select('id').where('id', '=', ctx.companyId).forUpdate().execute();
      const dup = await tx.selectFrom('gratuity_provisions').select('id').where('company_id', '=', ctx.companyId).where('as_of', '=', asOf).executeTakeFirst();
      if (dup) throw conflict(`The gratuity provision for ${asOf} is already posted.`, 'PROVISION_POSTED');
      const t = await provisionTable(tx, ctx, asOf);
      const balance = await payableBalance(tx, ctx);
      const diff = round2(t.total - balance);
      const who = { tenantId: ctx.tenantId, companyId: ctx.companyId, userId: ctx.userId };
      let entry: string | null = null;
      if (diff !== 0) {
        const exp = await ensureAccount(tx, ctx, GRATUITY_ACC.expense, 'expense', 6540);
        const pay = await ensureAccount(tx, ctx, GRATUITY_ACC.payable, 'liability', 2470);
        entry = await postJournal(tx, who, {
          date: asOf, voucherType: 'journal', voucherId: null, number: null,
          narration: `Gratuity provision as at ${asOf} for ${t.rows.length} employees`,
          lines: [{ accountId: exp, amount: diff }, { accountId: pay, amount: -diff }],
        });
      }
      const row = await tx.insertInto('gratuity_provisions').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, as_of: asOf, total: t.total, prior_balance: balance, posted_amount: diff,
        employee_count: t.rows.length, entry_id: entry, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'gratuity_provision', row.id, 'post', null, { asOf, total: t.total, posted: diff });
      return { id: row.id, asOf, total: t.total, priorBalance: balance, posted: diff, entryId: entry, employees: t.rows.length };
    });
    return reply.status(201).send(out);
  });
}
