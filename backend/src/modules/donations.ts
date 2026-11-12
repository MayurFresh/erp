import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { toCsv } from '../lib/csv.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { nullableText, optionalText } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { cashBankAccount, ensureAccount, loadSettings } from './funds.ts';
import { documentRoute } from '../lib/openapi.ts';

/*
 * Donors and donation receipts. Each donation posts a journal: bank or cash debit, donation income (or corpus fund) credit.
 * Cash above CASH_80G_LIMIT is recorded, but no 80G deduction can be given for it.
 */

const CASH_80G_LIMIT = 2000;
const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const fyField = z.string().regex(/^[0-9]{4}-[0-9]{2}$/, 'Use a year like 2026-27');
const blank = (v: unknown) => (typeof v === 'string' && v.trim() === '' ? undefined : v);
const nullBlank = (v: unknown) => (typeof v === 'string' && v.trim() === '' ? null : v);
const upper = (v: unknown) => (typeof v === 'string' ? v.trim().toUpperCase().replace(/\s+/g, '') : v);

const viewDon = (c: RequestContext) => c.require('donations.view', 'donations.create', 'donations.manage');
const createDon = (c: RequestContext) => c.require('donations.create', 'donations.manage');
const manageDon = (c: RequestContext) => c.require('donations.manage');

const panField = z.string().regex(/^[A-Z]{5}[0-9]{4}[A-Z]$/, 'Enter a valid PAN, like ABCDE1234F');
const aadhaarField = z.string().regex(/^[0-9]{12}$/, 'Aadhaar is 12 digits');
const phoneField = z.string().trim().min(5, 'Enter a phone number').max(20).regex(/^[0-9+() -]+$/, 'Digits only');
const donorCreate = z.object({
  name: z.string().trim().min(1, 'Required').max(200),
  phone: z.preprocess(blank, phoneField.optional()),
  email: z.preprocess(blank, z.string().trim().email('Enter a valid email').max(200).optional()),
  pan: z.preprocess((v) => blank(upper(v)), panField.optional()),
  aadhaar: z.preprocess((v) => blank(typeof v === 'string' ? v.replace(/\s+/g, '') : v), aadhaarField.optional()),
  address: optionalText(500),
  force: z.boolean().optional(),
});
const donorPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  name: z.string().trim().min(1).max(200).optional(),
  phone: z.preprocess(nullBlank, phoneField.nullable().optional()),
  email: z.preprocess(nullBlank, z.string().trim().email().max(200).nullable().optional()),
  pan: z.preprocess((v) => nullBlank(upper(v)), panField.nullable().optional()),
  aadhaar: z.preprocess((v) => nullBlank(typeof v === 'string' ? v.replace(/\s+/g, '') : v), aadhaarField.nullable().optional()),
  address: nullableText(500), isActive: z.boolean().optional(),
});
const donationCreate = z.object({
  donorId: z.uuid(), amount: moneyField.refine((v) => v > 0, 'Must be more than zero'),
  mode: z.enum(['cash', 'upi', 'cheque', 'bank']), date: dateField.optional(), reference: optionalText(100),
  fundId: z.uuid().nullable().optional(), purpose: optionalText(200), isCorpus: z.boolean().default(false), tax80g: z.boolean().default(false),
  accountId: z.uuid().optional(),
});
const donationList = pagingQuery.extend({
  from: dateField.optional(), to: dateField.optional(), donorId: z.uuid().optional(), fundId: z.uuid().optional(),
  status: z.enum(['posted', 'cancelled']).optional(),
});
const fyQuery = z.object({ fy: fyField.optional() });
const fyBounds = (fy: string) => ({ from: `${fy.slice(0, 4)}-04-01`, to: `${Number(fy.slice(0, 4)) + 1}-03-31` });

const mask = (a: string | null) => (a ? `XXXX XXXX ${a.slice(-4)}` : null);
type DonorRow = Awaited<ReturnType<typeof loadDonor>>;
const donorJson = (d: DonorRow) => ({
  id: d.id, name: d.name, phone: d.phone, email: d.email, pan: d.pan, aadhaarMasked: mask(d.aadhaar), hasAadhaar: !!d.aadhaar, address: d.address,
  isActive: d.is_active, partyId: d.party_id, updatedAt: d.updated_at.toISOString(),
});
async function loadDonor(tx: Tx, ctx: RequestContext, id: string) {
  const d = await tx.selectFrom('donors').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!d) throw notFound('Donor');
  return d;
}

type DonationRow = Awaited<ReturnType<typeof loadDonationRows>>[number];
async function loadDonationRows(tx: Tx, ctx: RequestContext, f: { id?: string; from?: string; to?: string; donorId?: string; fundId?: string; status?: string; q?: string; fy?: string; limit?: number; offset?: number }) {
  let q = tx.selectFrom('donations as n').innerJoin('donors as d', 'd.id', 'n.donor_id').leftJoin('funds as f', 'f.id', 'n.fund_id')
    .select(['n.id', 'n.receipt_no', 'n.donor_id', 'n.donation_date', 'n.amount', 'n.mode', 'n.reference', 'n.fund_id', 'n.purpose', 'n.is_corpus', 'n.tax_80g',
      'n.deduction_eligible', 'n.warning', 'n.fy', 'n.status', 'n.cancel_reason', 'n.created_at', 'd.name as donor_name', 'd.phone as donor_phone', 'd.pan as donor_pan',
      'd.aadhaar as donor_aadhaar', 'd.address as donor_address', 'f.name as fund_name']).where('n.company_id', '=', ctx.companyId);
  if (f.id) q = q.where('n.id', '=', f.id);
  if (f.from) q = q.where('n.donation_date', '>=', f.from);
  if (f.to) q = q.where('n.donation_date', '<=', f.to);
  if (f.fy) q = q.where('n.fy', '=', f.fy);
  if (f.donorId) q = q.where('n.donor_id', '=', f.donorId);
  if (f.fundId) q = q.where('n.fund_id', '=', f.fundId);
  if (f.status) q = q.where('n.status', '=', f.status);
  if (f.q) { const t = likeTerm(f.q); q = q.where((eb) => eb.or([eb('n.receipt_no', 'ilike', t), eb('d.name', 'ilike', t), eb('d.phone', 'ilike', t)])); }
  return q.orderBy('n.donation_date', 'desc').orderBy('n.receipt_no', 'desc').limit(f.limit ?? 200).offset(f.offset ?? 0).execute();
}
const donationJson = (r: DonationRow) => ({
  id: r.id, receiptNo: r.receipt_no, donorId: r.donor_id, donorName: r.donor_name, donorPhone: r.donor_phone, date: r.donation_date, amount: Number(r.amount),
  mode: r.mode, reference: r.reference, fundId: r.fund_id, fundName: r.fund_name, purpose: r.purpose, isCorpus: r.is_corpus, tax80g: r.tax_80g,
  deductionEligible: r.deduction_eligible, warning: r.warning, fy: r.fy, status: r.status, cancelReason: r.cancel_reason, createdAt: r.created_at.toISOString(),
});

export async function donationRoutes(app: FastifyInstance) {
  // ---- donors
  app.get('/donors', async (req) => {
    const ctx = req.ctx; viewDon(ctx);
    const q = parse(pagingQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('donors').where('company_id', '=', ctx.companyId);
      if (q.q) { const t = likeTerm(q.q); base = base.where((eb) => eb.or([eb('name', 'ilike', t), eb('phone', 'ilike', t), eb('pan', 'ilike', t)])); }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll().orderBy('name').limit(q.limit).offset(q.offset).execute();
      const sums = rows.length ? await tx.selectFrom('donations').select(['donor_id']).select((eb) => eb.fn.sum<number>('amount').as('total')).select((eb) => eb.fn.countAll<number>().as('n'))
        .where('company_id', '=', ctx.companyId).where('status', '=', 'posted').where('donor_id', 'in', rows.map((r) => r.id)).groupBy('donor_id').execute() : [];
      return { total: Number(total), data: rows.map((d) => { const s = sums.find((x) => x.donor_id === d.id); return { ...donorJson(d), donated: Number(s?.total ?? 0), donations: Number(s?.n ?? 0) }; }) };
    });
  });
  app.post('/donors', async (req, reply) => {
    const ctx = req.ctx; createDon(ctx);
    const b = parse(donorCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      if (b.pan) {
        const dup = await tx.selectFrom('donors').select(['id', 'name']).where('company_id', '=', ctx.companyId).where('pan', '=', b.pan).executeTakeFirst();
        if (dup) throw conflict('A donor with this PAN is already added.', 'DUPLICATE_DONOR', { matches: [dup] });
      }
      if (!b.force && b.phone) {
        const dup = await tx.selectFrom('donors').select(['id', 'name', 'phone']).where('company_id', '=', ctx.companyId).where('phone', '=', b.phone)
          .where((eb) => eb(eb.fn('lower', ['name']), '=', b.name.toLowerCase())).limit(5).execute();
        if (dup.length) throw conflict('A donor with this name and phone is already added.', 'DUPLICATE_DONOR', { matches: dup });
      }
      const company = await tx.selectFrom('companies').select('state_code').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const party = await tx.insertInto('parties').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, type: 'customer', name: b.name, phone: b.phone ?? null, address: b.address ?? null,
        state_code: company.state_code, gstin: null, email: b.email ?? null, pan: b.pan ?? null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null,
      }).returning('id').executeTakeFirstOrThrow();
      const row = await tx.insertInto('donors').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, party_id: party.id, name: b.name, phone: b.phone ?? null, email: b.email ?? null, pan: b.pan ?? null,
        aadhaar: b.aadhaar ?? null, address: b.address ?? null, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'donor', row.id, 'create', null, { name: row.name, hasPan: !!row.pan, hasAadhaar: !!row.aadhaar });
      return donorJson(row);
    });
    return reply.status(201).send(out);
  });
  app.get<{ Params: { id: string } }>('/donors/:id', async (req) => {
    const ctx = req.ctx; viewDon(ctx);
    return ctx.tx(async (tx) => donorJson(await loadDonor(tx, ctx, req.params.id)));
  });
  app.patch<{ Params: { id: string } }>('/donors/:id', async (req) => {
    const ctx = req.ctx; createDon(ctx);
    const b = parse(donorPatch, req.body);
    return ctx.tx(async (tx) => {
      const cur = await loadDonor(tx, ctx, req.params.id);
      assertFresh(cur.updated_at, b.expectedUpdatedAt, 'donor');
      if (b.pan && b.pan !== cur.pan) {
        const dup = await tx.selectFrom('donors').select(['id', 'name']).where('company_id', '=', ctx.companyId).where('pan', '=', b.pan).executeTakeFirst();
        if (dup) throw conflict('A donor with this PAN is already added.', 'DUPLICATE_DONOR', { matches: [dup] });
      }
      const set: Record<string, unknown> = {};
      for (const [k, col] of [['name', 'name'], ['phone', 'phone'], ['email', 'email'], ['pan', 'pan'], ['aadhaar', 'aadhaar'], ['address', 'address'], ['isActive', 'is_active']] as const) {
        if (b[k] !== undefined) set[col] = b[k];
      }
      const row = await tx.updateTable('donors').set(set).where('id', '=', cur.id).returningAll().executeTakeFirstOrThrow();
      const pset: Record<string, unknown> = {};
      for (const col of ['name', 'phone', 'email', 'pan', 'address']) if (col in set) pset[col] = set[col];
      if (Object.keys(pset).length) await tx.updateTable('parties').set(pset).where('id', '=', cur.party_id).execute();
      await writeAudit(tx, auditOf(ctx), 'donor', cur.id, 'update', null, { fields: Object.keys(set) });
      return donorJson(row);
    });
  });
  app.get<{ Params: { id: string } }>('/donors/:id/statement', async (req) => {
    const ctx = req.ctx; viewDon(ctx);
    const { fy = financialYear(todayIst()) } = parse(fyQuery, req.query);
    return ctx.tx(async (tx) => {
      const donor = await loadDonor(tx, ctx, req.params.id);
      const rows = (await loadDonationRows(tx, ctx, { donorId: donor.id, fy, status: 'posted' })).sort((a, b) => a.donation_date.localeCompare(b.donation_date) || a.receipt_no.localeCompare(b.receipt_no));
      const data = rows.map(donationJson);
      const settings = await loadSettings(tx, ctx);
      const company = await tx.selectFrom('companies').select(['name', 'legal_name', 'address']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      return {
        fy, donor: donorJson(donor), data, total: round2(data.reduce((s, r) => s + r.amount, 0)),
        eligibleFor80g: round2(data.filter((r) => r.tax80g && r.deductionEligible).reduce((s, r) => s + r.amount, 0)),
        company: { name: company.legal_name || company.name, address: company.address },
        reg80g: { no: settings.reg80gNo, from: settings.reg80gFrom, to: settings.reg80gTo },
      };
    });
  });

  // ---- donations
  app.get('/donations/home', async (req) => {
    const ctx = req.ctx; viewDon(ctx);
    return ctx.tx(async (tx) => {
      const today = todayIst(), fy = financialYear(today);
      const posted = await tx.selectFrom('donations').select(['donation_date', 'amount', 'mode', 'is_corpus', 'deduction_eligible', 'tax_80g'])
        .where('company_id', '=', ctx.companyId).where('status', '=', 'posted').where('fy', '=', fy).execute();
      const sum = (rows: typeof posted) => round2(rows.reduce((s, r) => s + Number(r.amount), 0));
      const todayRows = posted.filter((r) => r.donation_date === today);
      const byMode: Record<string, number> = { cash: 0, upi: 0, cheque: 0, bank: 0 };
      for (const r of todayRows) byMode[r.mode] = round2((byMode[r.mode] ?? 0) + Number(r.amount));
      const settings = await loadSettings(tx, ctx);
      const recent = (await loadDonationRows(tx, ctx, { limit: 8 })).map(donationJson);
      return {
        today: { date: today, count: todayRows.length, total: sum(todayRows), byMode },
        year: { fy, count: posted.length, total: sum(posted), corpus: sum(posted.filter((r) => r.is_corpus)), eligible80g: sum(posted.filter((r) => r.tax_80g && r.deduction_eligible)) },
        recent, reg80g: { no: settings.reg80gNo, from: settings.reg80gFrom, to: settings.reg80gTo, set: !!settings.reg80gNo },
      };
    });
  });
  app.get('/donations/form-10bd', async (req, reply) => {
    const ctx = req.ctx; manageDon(ctx);
    const q = parse(fyQuery.extend({ format: z.enum(['csv', 'json']).default('json') }), req.query);
    const fy = q.fy ?? financialYear(todayIst());
    const { rows, skipped } = await ctx.tx(async (tx) => {
      const all = (await loadDonationRows(tx, ctx, { fy, status: 'posted', limit: 5000 })).filter((r) => r.tax_80g && r.deduction_eligible)
        .sort((a, b) => a.donation_date.localeCompare(b.donation_date) || a.receipt_no.localeCompare(b.receipt_no));
      const ok = all.filter((r) => r.donor_pan || r.donor_aadhaar);
      return { rows: ok, skipped: all.filter((r) => !r.donor_pan && !r.donor_aadhaar).map((r) => ({ receiptNo: r.receipt_no, donorName: r.donor_name })) };
    });
    const header = ['Sr No', 'Section Code', 'Donor ID Type', 'Donor ID', 'Donor Name', 'Donor Address', 'Donation Type', 'Mode of Receipt', 'Amount of Donation'];
    const line = (r: DonationRow, i: number) => [i + 1, '80G', r.donor_pan ? 'PAN' : 'Aadhaar', r.donor_pan ?? r.donor_aadhaar, r.donor_name, r.donor_address ?? '',
      r.is_corpus ? 'Corpus' : r.fund_id ? 'Specific grant' : 'Others', r.mode === 'cash' ? 'Cash' : 'Other modes', Number(r.amount).toFixed(2)];
    const note = 'Check before filing. Match the columns and codes with the current Form 10BD utility on the income tax portal.';
    if (q.format === 'csv') {
      return reply.type('text/csv; charset=utf-8').header('X-Note', note).header('Content-Disposition', `attachment; filename="form-10bd-${fy}.csv"`).send(toCsv(header, rows.map(line)));
    }
    return { fy, note, header, rows: rows.map(line), skipped, total: round2(rows.reduce((s, r) => s + Number(r.amount), 0)) };
  });
  app.get('/donations', async (req) => {
    const ctx = req.ctx; viewDon(ctx);
    const q = parse(donationList, req.query);
    return ctx.tx(async (tx) => ({ data: (await loadDonationRows(tx, ctx, q)).map(donationJson) }));
  });
  app.post('/donations', async (req, reply) => {
    const ctx = req.ctx; createDon(ctx);
    const b = parse(donationCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      const donor = await loadDonor(tx, ctx, b.donorId);
      if (!donor.is_active) throw badRequest('This donor is not active.', { donorId: 'Not active' });
      const date = b.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });
      if (b.fundId) {
        const f = await tx.selectFrom('funds').select(['id', 'status']).where('id', '=', b.fundId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!f) throw badRequest('Fund not found.', { fundId: 'Not found' });
        if (f.status !== 'active') throw conflict('This fund is closed.', 'FUND_CLOSED');
      }
      const warnings: string[] = [];
      let eligible = b.tax80g;
      let warning: string | null = null;
      if (b.tax80g) {
        if (!donor.pan && !donor.aadhaar) throw badRequest('Add the donor\'s PAN or Aadhaar before giving an 80G receipt.', { donorId: 'PAN or Aadhaar needed for 80G' });
        if (b.mode === 'cash' && b.amount > CASH_80G_LIMIT) {
          eligible = false;
          warning = `Cash donations above Rs ${CASH_80G_LIMIT} do not qualify for an 80G deduction. This receipt will say so.`;
          warnings.push(warning);
        }
        const s = await loadSettings(tx, ctx);
        if (!s.reg80gNo) warnings.push('The 80G registration number is not set. Add it in donation settings.');
        else if ((s.reg80gFrom && date < s.reg80gFrom) || (s.reg80gTo && date > s.reg80gTo)) warnings.push('The donation date is outside the 80G validity period.');
      }
      const account = await cashBankAccount(tx, ctx, b.accountId, b.mode === 'cash' ? 'cash' : 'bank');
      const credit = b.isCorpus ? await ensureAccount(tx, ctx, 'Corpus Fund', 'equity', 3500) : await ensureAccount(tx, ctx, 'Donations Received', 'income', 4850);
      const fy = financialYear(date);
      const receiptNo = await nextNumber(tx, ctx, 'donation_receipt', fy);
      const row = await tx.insertInto('donations').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, receipt_no: receiptNo, donor_id: donor.id, donation_date: date, amount: b.amount, mode: b.mode,
        reference: b.reference ?? null, fund_id: b.fundId ?? null, purpose: b.purpose ?? null, is_corpus: b.isCorpus, tax_80g: b.tax80g,
        deduction_eligible: eligible, warning, account_id: account, fy, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await postJournal(tx, auditOf(ctx), {
        date, voucherType: 'journal', voucherId: row.id, number: receiptNo,
        narration: `Donation from ${donor.name} by ${b.mode}${b.isCorpus ? ' (corpus)' : ''}`,
        lines: [{ accountId: account, amount: b.amount }, { accountId: credit, amount: -b.amount }],
      });
      await writeAudit(tx, auditOf(ctx), 'donation', row.id, 'create', null, { receiptNo, donor: donor.name, amount: b.amount, mode: b.mode, tax80g: b.tax80g, eligible });
      const made = (await loadDonationRows(tx, ctx, { id: row.id }))[0]!;
      return { ...donationJson(made), warnings };
    });
    return reply.status(201).send(out);
  });
  app.get<{ Params: { id: string } }>('/donations/:id', async (req) => {
    const ctx = req.ctx; viewDon(ctx);
    return ctx.tx(async (tx) => {
      const r = (await loadDonationRows(tx, ctx, { id: req.params.id }))[0];
      if (!r) throw notFound('Donation');
      const settings = await loadSettings(tx, ctx);
      const company = await tx.selectFrom('companies').select(['name', 'legal_name', 'address', 'phone', 'pincode']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      return {
        ...donationJson(r),
        donor: { id: r.donor_id, name: r.donor_name, phone: r.donor_phone, pan: r.donor_pan, aadhaarMasked: mask(r.donor_aadhaar), address: r.donor_address },
        trust: { name: company.legal_name || company.name, address: company.address, phone: company.phone, pan: settings.trustPan },
        reg80g: { no: settings.reg80gNo, from: settings.reg80gFrom, to: settings.reg80gTo }, footer: settings.receiptFooter,
      };
    });
  });
  app.post<{ Params: { id: string } }>('/donations/:id/cancel', async (req) => {
    const ctx = req.ctx; manageDon(ctx);
    const b = parse(z.object({ reason: z.string().trim().min(1, 'Give a reason').max(300) }), req.body);
    return ctx.tx(async (tx) => {
      const d = await tx.selectFrom('donations').selectAll().where('id', '=', req.params.id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!d) throw notFound('Donation');
      if (d.status === 'cancelled') throw conflict('This receipt is already cancelled.', 'ALREADY_CANCELLED');
      await reverseVoucher(tx, auditOf(ctx), d.id, todayIst(), `Cancelled donation receipt ${d.receipt_no}: ${b.reason}`);
      await tx.updateTable('donations').set({ status: 'cancelled', cancel_reason: b.reason }).where('id', '=', d.id).execute();
      await writeAudit(tx, auditOf(ctx), 'donation', d.id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason: b.reason });
      return donationJson((await loadDonationRows(tx, ctx, { id: d.id }))[0]!);
    });
  });
}

documentRoute('POST', '/donors', { body: donorCreate });
documentRoute('PATCH', '/donors/:id', { body: donorPatch });
documentRoute('POST', '/donations', { body: donationCreate });
