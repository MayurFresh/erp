import type { FastifyInstance } from 'fastify';
import type { Selectable } from 'kysely';
import { z } from 'zod';
import type { CompanyTable } from '../db/schema.ts';
import { isValidDate } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { definedOnly, gstin, nullableText, stateCode } from '../lib/india.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

export const companyJson = (c: Selectable<CompanyTable>) => ({
  id: c.id, name: c.name, legalName: c.legal_name, gstin: c.gstin, stateCode: c.state_code, pan: c.pan,
  address: c.address, phone: c.phone, email: c.email, website: c.website, bankName: c.bank_name,
  bankAccountNo: c.bank_account_no, bankIfsc: c.bank_ifsc, upiId: c.upi_id, invoiceTerms: c.invoice_terms,
  invoiceFooter: c.invoice_footer, pincode: c.pincode, einvoiceEnabled: c.einvoice_enabled, einvoiceMode: c.einvoice_mode,
  tan: c.tan, booksLockedUntil: c.books_locked_until, msmeBankRate: c.msme_bank_rate === null ? null : Number(c.msme_bank_rate),
  gstFiling: c.gst_filing,
  constitution: c.constitution, responsiblePerson: c.responsible_person ?? null, itrForm: c.itr_form,
});

const blankToNull = (v: unknown) => (v === '' ? null : v);
const patchBody = z.object({
  name: z.string().trim().min(2).max(120).optional(),
  legalName: nullableText(160),
  gstin: z.preprocess(blankToNull, gstin.nullable().optional()),
  stateCode: stateCode.optional(),
  pan: z.preprocess(blankToNull, z.string().trim().toUpperCase().regex(/^[A-Z]{5}[0-9]{4}[A-Z]$/, 'Invalid PAN').nullable().optional()),
  address: nullableText(500),
  phone: nullableText(20),
  email: z.preprocess(blankToNull, z.email().nullable().optional()),
  website: nullableText(120),
  bankName: nullableText(80),
  bankAccountNo: z.preprocess(blankToNull, z.string().trim().regex(/^\d{6,20}$/, 'Account number must be 6–20 digits').nullable().optional()),
  bankIfsc: z.preprocess(blankToNull, z.string().trim().toUpperCase().regex(/^[A-Z]{4}0[A-Z0-9]{6}$/, 'Invalid IFSC').nullable().optional()),
  upiId: z.preprocess(blankToNull, z.string().trim().regex(/^[\w.-]{2,}@[a-zA-Z]{2,}$/, 'Invalid UPI ID').nullable().optional()),
  invoiceTerms: nullableText(2000),
  invoiceFooter: nullableText(300),
  pincode: z.preprocess(blankToNull, z.string().trim().regex(/^[1-9][0-9]{5}$/, 'Pincode must be 6 digits').nullable().optional()),
  einvoiceEnabled: z.boolean().optional(),
  einvoiceMode: z.enum(['manual', 'sandbox']).optional(),
  tan: z.preprocess(blankToNull, z.string().trim().toUpperCase().regex(/^[A-Z]{4}[0-9]{5}[A-Z]$/, 'Invalid TAN').nullable().optional()),
  booksLockedUntil: z.string().refine(isValidDate, 'Use YYYY-MM-DD').nullable().optional(),
  msmeBankRate: z.coerce.number().min(0).max(100).nullable().optional(),
  gstFiling: z.enum(['monthly', 'quarterly']).optional(),
  constitution: z.enum(['proprietorship', 'partnership', 'llp', 'private_company', 'public_company', 'huf', 'trust', 'other']).nullable().optional(),
  responsiblePerson: z.object({
    name: z.string().trim().min(2).max(100),
    designation: z.string().trim().min(2).max(60),
    pan: z.string().trim().toUpperCase().regex(/^[A-Z]{5}[0-9]{4}[A-Z]$/, 'Invalid PAN'),
    mobile: z.string().trim().regex(/^\d{10}$/, 'Mobile must be 10 digits'),
    email: z.email(),
  }).nullable().optional(),
  itrForm: z.enum(['itr3', 'itr4', 'itr5', 'itr6']).nullable().optional(),
});

export async function companyRoutes(app: FastifyInstance) {
  app.get('/company', async (req) => {
    const ctx = req.ctx;
    if (!ctx.companyId) throw notFound('Company');
    const c = await ctx.tx((tx) => tx.selectFrom('companies').selectAll().where('id', '=', ctx.companyId).executeTakeFirstOrThrow());
    return companyJson(c);
  });

  app.patch('/company', async (req) => {
    const ctx = req.ctx;
    const body = parse(patchBody, req.body);
    const { booksLockedUntil, ...rest } = body;
    if (Object.values(rest).some((v) => v !== undefined) || booksLockedUntil === undefined) ctx.require('company.manage');
    if (booksLockedUntil !== undefined) ctx.require('books.lock');
    return ctx.tx(async (tx) => {
      const before = await tx.selectFrom('companies').selectAll().where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const state = body.stateCode ?? before.state_code;
      const g = body.gstin !== undefined ? body.gstin : before.gstin;
      if (g && g.slice(0, 2) !== state) throw badRequest('GSTIN does not match the state.', { gstin: 'Does not match the state' });
      if (body.stateCode && body.stateCode !== before.state_code) {
        const invoice = await tx.selectFrom('invoices').select('id').where('company_id', '=', ctx.companyId).limit(1).executeTakeFirst();
        const bill = await tx.selectFrom('purchases').select('id').where('company_id', '=', ctx.companyId).limit(1).executeTakeFirst();
        if (invoice || bill) throw conflict('The state cannot change after invoices or bills exist.', 'CONFLICT', { stateCode: 'Locked' });
      }
      const changes = definedOnly({
        name: body.name, legal_name: body.legalName, gstin: body.gstin, state_code: body.stateCode,
        pan: body.pan !== undefined ? body.pan : body.gstin ? body.gstin.slice(2, 12) : undefined,
        address: body.address, phone: body.phone, email: body.email, website: body.website, bank_name: body.bankName,
        bank_account_no: body.bankAccountNo, bank_ifsc: body.bankIfsc, upi_id: body.upiId,
        invoice_terms: body.invoiceTerms, invoice_footer: body.invoiceFooter,
        tan: body.tan, msme_bank_rate: body.msmeBankRate, gst_filing: body.gstFiling,
        constitution: body.constitution, responsible_person: body.responsiblePerson, itr_form: body.itrForm,
        books_locked_until: body.booksLockedUntil,
        pincode: body.pincode, einvoice_enabled: body.einvoiceEnabled, einvoice_mode: body.einvoiceMode,
      });
      if (!Object.keys(changes).length) return companyJson(before);
      const after = await tx.updateTable('companies').set(changes).where('id', '=', ctx.companyId).returningAll().executeTakeFirstOrThrow();
      if (after.books_locked_until !== before.books_locked_until) {
        await writeAudit(tx, auditOf(ctx), 'company', ctx.companyId, after.books_locked_until ? 'lock' : 'unlock',
          { booksLockedUntil: before.books_locked_until }, { booksLockedUntil: after.books_locked_until });
      }
      if (Object.keys(changes).some((k) => k !== 'books_locked_until')) {
        await writeAudit(tx, auditOf(ctx), 'company', ctx.companyId, 'update', companyJson(before), companyJson(after));
      }
      return companyJson(after);
    });
  });
}
