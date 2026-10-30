import { randomInt } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { buildEinvoicePayload, irnOf, sandboxQr } from '../lib/einvoice-payload.ts';
import { GSTIN_PATTERN } from '../lib/india.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { loadInvoice } from './invoices.ts';

const DAY_MS = 24 * 3600 * 1000;
const REASONS = { '1': 'Duplicate', '2': 'Data entry mistake', '3': 'Order cancelled', '4': 'Other' } as const;

const timestamp = z.string().refine((v) => !Number.isNaN(Date.parse(v)), 'Use an ISO date or timestamp').transform((v) => new Date(v));
const irnBody = z.object({
  irn: z.string().trim().toLowerCase().regex(/^[0-9a-f]{64}$/, 'Must be 64 hex characters').optional(),
  ackNo: z.string().trim().min(1).max(30).optional(),
  ackDate: timestamp.optional(),
  signedQrCode: z.string().trim().min(1).max(20000).optional(),
});
const cancelBody = z.object({
  reasonCode: z.enum(['1', '2', '3', '4']),
  remark: z.string().trim().min(1, 'Give a remark').max(100),
});
const ewbBody = z.object({
  transportMode: z.enum(['road', 'rail', 'air', 'ship']),
  distanceKm: z.coerce.number().int().min(0).max(4000),
  vehicleNo: z.preprocess((v) => (typeof v === 'string' && v.trim() === '' ? undefined : v),
    z.string().trim().toUpperCase().regex(/^[A-Z0-9-]{6,15}$/, 'Invalid vehicle number').optional()),
  transporterGstin: z.preprocess((v) => (typeof v === 'string' && v.trim() === '' ? undefined : v),
    z.string().trim().toUpperCase().regex(GSTIN_PATTERN, 'Invalid GSTIN').optional()),
  ewbNo: z.string().trim().regex(/^[0-9]{12}$/, 'Must be 12 digits').optional(),
  ewbDate: timestamp.optional(),
  validUntil: timestamp.optional(),
});

async function company(tx: Tx, ctx: RequestContext) {
  return tx.selectFrom('companies').selectAll().where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
}

/** Locks the invoice row and returns it with its company, location, party and lines. */
async function loadForUpdate(tx: Tx, ctx: RequestContext, id: string, lock: boolean) {
  let q = tx.selectFrom('invoices').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const invoice = await q.executeTakeFirst();
  if (!invoice || !ctx.canAccessLocation(invoice.location_id)) throw notFound('Invoice');
  const [co, location, party, lines] = await Promise.all([
    company(tx, ctx),
    tx.selectFrom('locations').selectAll().where('id', '=', invoice.location_id).executeTakeFirstOrThrow(),
    tx.selectFrom('parties').selectAll().where('id', '=', invoice.party_id).executeTakeFirstOrThrow(),
    tx.selectFrom('invoice_lines').selectAll().where('invoice_id', '=', id).orderBy('line_no').execute(),
  ]);
  return { invoice, company: co, location, party, lines };
}

function validated(d: Awaited<ReturnType<typeof loadForUpdate>>) {
  const built = buildEinvoicePayload(d);
  if (!built.payload) {
    throw badRequest(`Cannot build the e-invoice: ${Object.values(built.errors)[0]}`, built.errors);
  }
  return built.payload;
}

const within24h = (since: Date | null) => since !== null && Date.now() - since.getTime() <= DAY_MS;

export async function einvoiceRoutes(app: FastifyInstance) {
  app.get<{ Params: { id: string } }>('/invoices/:id/einvoice/payload', async (req) => {
    const ctx = req.ctx;
    ctx.require('einvoice.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => validated(await loadForUpdate(tx, ctx, id, false)));
  });

  app.post<{ Params: { id: string } }>('/invoices/:id/einvoice', async (req) => {
    const ctx = req.ctx;
    ctx.require('einvoice.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(irnBody, req.body);
    return ctx.tx(async (tx) => {
      const d = await loadForUpdate(tx, ctx, id, true);
      if (!d.company.einvoice_enabled) throw conflict('E-invoicing is not turned on for this company.', 'EINVOICE_DISABLED');
      if (d.invoice.status === 'cancelled') throw conflict('This invoice is cancelled.', 'CONFLICT');
      if (d.invoice.irn_status === 'active') throw conflict('This invoice already has an active IRN.', 'IRN_ACTIVE');
      if (!d.party.gstin) throw badRequest('The customer has no GSTIN; B2C invoices are not e-invoiced.', { 'party.gstin': 'Missing' });
      validated(d);

      const sandbox = d.company.einvoice_mode === 'sandbox';
      let irn: string, ackNo: string, ackDate: Date, qr: string;
      if (sandbox) {
        irn = irnOf(d.company.gstin!, d.invoice.fy, d.invoice.number);
        ackNo = String(randomInt(1, 10) * 10 ** 14 + randomInt(0, 10 ** 14));
        ackDate = new Date();
        const hsnTotals = new Map<string, number>();
        for (const l of d.lines) hsnTotals.set(l.hsn_code!, (hsnTotals.get(l.hsn_code!) ?? 0) + l.taxable_value);
        const mainHsn = [...hsnTotals.entries()].sort((a, b) => b[1] - a[1])[0]![0];
        qr = sandboxQr({
          sellerGstin: d.company.gstin!, buyerGstin: d.party.gstin, docNo: d.invoice.number, docDate: d.invoice.invoice_date,
          totalValue: d.invoice.total, itemCount: d.lines.length, mainHsn, irn,
        });
      } else {
        const missing: Record<string, string> = {};
        for (const k of ['irn', 'ackNo', 'ackDate', 'signedQrCode'] as const) if (body[k] === undefined) missing[k] = 'Required';
        if (Object.keys(missing).length) throw badRequest('Record the IRN details returned by the IRP.', missing);
        irn = body.irn!; ackNo = body.ackNo!; ackDate = body.ackDate!; qr = body.signedQrCode!;
        if (ackDate.getTime() > Date.now() + 5 * 60_000) throw badRequest('Ack date is in the future.', { ackDate: 'In the future' });
        const used = await tx.selectFrom('invoices').select('id').where('company_id', '=', ctx.companyId)
          .where('irn', '=', irn).where('irn_status', '=', 'active').where('id', '<>', id).executeTakeFirst();
        if (used) throw conflict('This IRN is already recorded on another invoice.', 'CONFLICT', { irn: 'Already used' });
      }
      await tx.updateTable('invoices').set({
        irn, irn_ack_no: ackNo, irn_ack_date: ackDate, irn_status: 'active', irn_signed_qr: qr, irn_sandbox: sandbox,
        irn_cancelled_at: null, irn_cancel_reason: null,
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'einvoice', id, 'generate', null, { number: d.invoice.number, irn, sandbox });
      return loadInvoice(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/invoices/:id/einvoice/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('einvoice.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const { invoice } = await loadForUpdate(tx, ctx, id, true);
      if (invoice.irn_status !== 'active') throw conflict('This invoice has no active IRN.', 'CONFLICT');
      if (!within24h(invoice.irn_ack_date)) {
        throw conflict('An IRN can be cancelled only within 24 hours of generation. Issue a credit note instead.', 'IRN_CANCEL_WINDOW');
      }
      if (invoice.ewb_status === 'active') throw conflict('Cancel the e-way bill first.', 'EWB_ACTIVE');
      const reason = `${REASONS[body.reasonCode]}: ${body.remark}`;
      await tx.updateTable('invoices').set({ irn_status: 'cancelled', irn_cancelled_at: new Date(), irn_cancel_reason: reason })
        .where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'einvoice', id, 'cancel', { irn: invoice.irn, status: 'active' }, { status: 'cancelled', reason });
      return loadInvoice(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/invoices/:id/ewaybill', async (req) => {
    const ctx = req.ctx;
    ctx.require('einvoice.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(ewbBody, req.body);
    return ctx.tx(async (tx) => {
      const d = await loadForUpdate(tx, ctx, id, true);
      const { invoice } = d;
      if (invoice.status === 'cancelled') throw conflict('This invoice is cancelled.', 'CONFLICT');
      if (invoice.irn_status !== 'active') throw conflict('Generate the e-invoice (IRN) before the e-way bill.', 'IRN_REQUIRED');
      if (invoice.ewb_status === 'active') throw conflict('This invoice already has an active e-way bill.', 'CONFLICT');
      if (body.transportMode === 'road' && !body.vehicleNo) throw badRequest('Enter the vehicle number for road transport.', { vehicleNo: 'Required for road' });

      const sandbox = d.company.einvoice_mode === 'sandbox';
      let ewbNo: string, ewbDate: Date, validUntil: Date;
      if (sandbox) {
        ewbNo = String(randomInt(1, 10) * 10 ** 11 + randomInt(0, 10 ** 11));
        ewbDate = new Date();
        const days = Math.max(1, Math.ceil(body.distanceKm / 200));
        validUntil = new Date(`${addDays(todayIst(), days)}T23:59:59+05:30`);
      } else {
        const missing: Record<string, string> = {};
        for (const k of ['ewbNo', 'ewbDate', 'validUntil'] as const) if (body[k] === undefined) missing[k] = 'Required';
        if (Object.keys(missing).length) throw badRequest('Record the e-way bill details from the portal.', missing);
        ewbNo = body.ewbNo!; ewbDate = body.ewbDate!; validUntil = body.validUntil!;
        if (validUntil.getTime() < ewbDate.getTime()) throw badRequest('Validity ends before the e-way bill date.', { validUntil: 'Before the date' });
      }
      await tx.updateTable('invoices').set({
        ewb_no: ewbNo, ewb_date: ewbDate, ewb_valid_until: validUntil, ewb_status: 'active', ewb_transport_mode: body.transportMode,
        ewb_vehicle_no: body.vehicleNo ?? null, ewb_distance_km: body.distanceKm, ewb_transporter_gstin: body.transporterGstin ?? null,
        ewb_cancelled_at: null,
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'einvoice', id, 'ewaybill', null, { number: invoice.number, ewbNo, sandbox });
      return loadInvoice(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/invoices/:id/ewaybill/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('einvoice.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const { invoice } = await loadForUpdate(tx, ctx, id, true);
      if (invoice.ewb_status !== 'active') throw conflict('This invoice has no active e-way bill.', 'CONFLICT');
      if (!within24h(invoice.ewb_date)) throw conflict('An e-way bill can be cancelled only within 24 hours of generation.', 'EWB_CANCEL_WINDOW');
      await tx.updateTable('invoices').set({ ewb_status: 'cancelled', ewb_cancelled_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'einvoice', id, 'ewaybill_cancel', { ewbNo: invoice.ewb_no, status: 'active' },
        { status: 'cancelled', reason: `${REASONS[body.reasonCode]}: ${body.remark}` });
      return loadInvoice(tx, ctx, id);
    });
  });
}
