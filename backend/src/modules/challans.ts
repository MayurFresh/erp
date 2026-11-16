import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { issue, lockItems, positions } from '../accounting/costing.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { challanAccount, db, round2 } from '../lib/export-currency.ts';
import { computeGst } from '../lib/gst.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { docDate, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { createInvoice } from './invoices.ts';
import { getLocation } from './locations.ts';
import { requireStock } from './stock.ts';

/** Delivery challans (CGST rule 55). See docs/API.md v1.20. */

const REASONS = ['job_work', 'supply_on_approval', 'exhibition', 'branch_transfer', 'liquid_gas', 'other'] as const;
const d10 = (v: unknown) => (v ? String(v).slice(0, 10) : null);

const createBody = z.object({
  locationId: z.uuid(),
  reason: z.enum(REASONS),
  reasonNote: optionalText(200),
  toLocationId: z.uuid().nullable().optional(),
  partyId: z.uuid().nullable().optional(),
  consignee: z.object({
    name: z.string().trim().min(1).max(200), address: optionalText(400), gstin: optionalText(15), stateCode: optionalText(2),
  }).optional(),
  challanDate: docDate.optional(),
  vehicleNo: optionalText(20), transporter: optionalText(120), ewbNo: optionalText(20), notes: optionalText(1000),
  lines: z.array(z.object({
    itemId: z.uuid(), qty: qtyField.refine((v) => v > 0, 'Must be more than zero'), rate: moneyField.optional(),
    description: optionalText(300), provisional: z.boolean().optional(),
  })).min(1, 'Add at least one line').max(200),
});
const returnBody = z.object({ date: docDate.optional(), lines: z.array(z.object({ lineId: z.uuid(), qty: qtyField.refine((v) => v > 0, 'Must be more than zero') })).min(1) });
const invoiceBody = z.object({ invoiceDate: docDate.optional(), lines: z.array(z.object({ lineId: z.uuid(), qty: qtyField.refine((v) => v > 0, 'Must be more than zero') })).optional() });
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({ status: z.enum(['open', 'partly_closed', 'closed', 'cancelled']).optional(), reason: z.enum(REASONS).optional() });

async function load(tx: Tx, ctx: RequestContext, id: string) {
  const c = await db(tx).selectFrom('dc_challans as c').innerJoin('locations as l', 'l.id', 'c.location_id')
    .leftJoin('locations as t', 't.id', 'c.to_location_id')
    .select(['c.id', 'c.number', 'c.challan_date', 'c.reason', 'c.reason_note', 'c.location_id', 'l.name as location_name', 'c.to_location_id', 't.name as to_location_name',
      'c.party_id', 'c.consignee_name', 'c.consignee_address', 'c.consignee_gstin', 'c.consignee_state', 'c.vehicle_no', 'c.transporter', 'c.ewb_no',
      'c.notes', 'c.status', 'c.cancel_reason', 'c.created_at', 'c.updated_at'])
    .where('c.id', '=', id).where('c.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!c || !ctx.canAccessLocation(c.location_id)) throw notFound('Delivery challan');
  const lines = await db(tx).selectFrom('dc_lines').selectAll().where('challan_id', '=', id).orderBy('line_no').execute();
  const events = await db(tx).selectFrom('dc_events').select(['kind', 'event_date', 'invoice_id', 'created_at']).where('challan_id', '=', id).orderBy('created_at').execute();
  const co = await tx.selectFrom('companies').select(['name', 'gstin', 'state_code']).where('id', '=', ctx.companyId).executeTakeFirst();
  const n = (v: unknown) => Number(v);
  const jl = lines.map((l) => ({
    id: l.id, lineNo: l.line_no, itemId: l.item_id, description: l.description, hsnCode: l.hsn_code, unit: l.unit, qty: n(l.qty), provisional: l.provisional,
    rate: n(l.rate), gstRate: n(l.gst_rate), taxableValue: n(l.taxable_value), cgst: n(l.cgst), sgst: n(l.sgst), igst: n(l.igst),
    returnedQty: n(l.returned_qty), invoicedQty: n(l.invoiced_qty), pendingQty: round3(n(l.qty) - n(l.returned_qty) - n(l.invoiced_qty)),
  }));
  return {
    id: c.id, number: c.number, date: d10(c.challan_date), reason: c.reason, reasonNote: c.reason_note, locationId: c.location_id, locationName: c.location_name,
    toLocationId: c.to_location_id, toLocationName: c.to_location_name, partyId: c.party_id,
    consignee: { name: c.consignee_name, address: c.consignee_address, gstin: c.consignee_gstin, stateCode: c.consignee_state },
    consignor: { name: co?.name ?? '', gstin: co?.gstin ?? null, stateCode: co?.state_code ?? null },
    vehicleNo: c.vehicle_no, transporter: c.transporter, ewbNo: c.ewb_no, notes: c.notes, status: c.status, cancelReason: c.cancel_reason,
    createdAt: c.created_at, taxableTotal: round2(jl.reduce((s, l) => s + l.taxableValue, 0)),
    taxTotal: round2(jl.reduce((s, l) => s + l.cgst + l.sgst + l.igst, 0)),
    lines: jl, events: events.map((e) => ({ kind: e.kind, date: d10(e.event_date), invoiceId: e.invoice_id })),
  };
}
const round3 = (n: number) => Math.round(n * 1000) / 1000;

/** Moves stock back for part of a challan and posts the matching journal. Returns the value moved. */
async function stockBack(tx: Tx, ctx: RequestContext, ch: any, picks: { line: any; qty: number }[], refType: 'challan_return', note: string, date: string) {
  const tracked = picks.filter((p) => p.line.tracked);
  if (!tracked.length) return 0;
  await lockItems(tx, ctx.companyId, tracked.map((p) => p.line.item_id));
  let total = 0;
  const moves: any[] = [];
  for (const p of tracked) {
    const l = p.line;
    const pendingAfter = round3(Number(l.qty) - Number(l.returned_qty) - Number(l.invoiced_qty) - p.qty);
    // The last units take the exact cost left, so no paise are stranded.
    const value = pendingAfter <= 0.0005 ? round2(Number(l.cost_value) - Number(l.cost_moved)) : round2(p.qty * Number(l.cost_value) / Number(l.qty));
    total = round2(total + value);
    await db(tx).updateTable('dc_lines').set({ cost_moved: round2(Number(l.cost_moved) + value) }).where('id', '=', l.id).execute();
    l.cost_moved = round2(Number(l.cost_moved) + value);
    moves.push({ tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: ch.location_id, item_id: l.item_id, qty: p.qty, rate: l.rate, cost_rate: l.cost_rate, value, ref_type: refType, ref_id: ch.id, note, created_by: ctx.userId });
    if (ch.reason === 'branch_transfer') {
      moves.push({ tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: ch.to_location_id, item_id: l.item_id, qty: -p.qty, rate: l.rate, cost_rate: l.cost_rate, value: -value, ref_type: refType, ref_id: ch.id, note, created_by: ctx.userId });
    }
  }
  await tx.insertInto('stock_moves').values(moves).execute();
  if (ch.reason !== 'branch_transfer' && total !== 0) {
    const acc = await systemAccounts(tx, ctx);
    const out = await challanAccount(tx, ctx);
    await postJournal(tx, auditOf(ctx), { date, voucherType: 'stock', voucherId: null, number: ch.number, narration: note,
      lines: [{ accountId: acc.inventory, amount: total, locationId: ch.location_id }, { accountId: out, amount: -total, locationId: ch.location_id }] });
  }
  return total;
}

async function lockChallan(tx: Tx, ctx: RequestContext, id: string) {
  const ch = await db(tx).selectFrom('dc_challans').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!ch || !ctx.canAccessLocation(ch.location_id)) throw notFound('Delivery challan');
  if (ch.status === 'cancelled') throw conflict('This challan is cancelled.', 'CANCELLED');
  const lines = await db(tx).selectFrom('dc_lines').selectAll().where('challan_id', '=', id).orderBy('line_no').execute();
  return { ch, lines };
}

function pickLines(lines: any[], wanted: { lineId: string; qty: number }[] | undefined) {
  const pend = (l: any) => round3(Number(l.qty) - Number(l.returned_qty) - Number(l.invoiced_qty));
  if (!wanted) return lines.filter((l) => pend(l) > 0).map((l) => ({ line: l, qty: pend(l) }));
  const seen = new Set<string>();
  return wanted.map((w, i) => {
    const line = lines.find((l) => l.id === w.lineId);
    if (!line) throw badRequest(`Row ${i + 1}: line not on this challan.`, { [`lines.${i}.lineId`]: 'Not found' });
    if (seen.has(w.lineId)) throw badRequest('Each line can appear once.', { [`lines.${i}.lineId`]: 'Duplicate' });
    seen.add(w.lineId);
    if (w.qty > pend(line) + 0.0005) throw badRequest(`Row ${i + 1}: only ${pend(line)} ${line.unit} is pending.`, { [`lines.${i}.qty`]: `At most ${pend(line)}` });
    return { line, qty: w.qty };
  });
}

async function setStatus(tx: Tx, id: string) {
  const lines = await db(tx).selectFrom('dc_lines').select(['qty', 'returned_qty', 'invoiced_qty']).where('challan_id', '=', id).execute();
  const pending = lines.reduce((s, l) => s + Number(l.qty) - Number(l.returned_qty) - Number(l.invoiced_qty), 0);
  const moved = lines.reduce((s, l) => s + Number(l.returned_qty) + Number(l.invoiced_qty), 0);
  const status = pending <= 0.0005 ? 'closed' : moved > 0 ? 'partly_closed' : 'open';
  await db(tx).updateTable('dc_challans').set({ status }).where('id', '=', id).execute();
}

export async function challanRoutes(app: FastifyInstance) {
  app.get('/delivery-challans', async (req) => {
    const ctx = req.ctx; ctx.require('challans.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = db(tx).selectFrom('dc_challans as c').leftJoin('parties as p', 'p.id', 'c.party_id').where('c.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('c.location_id', 'in', scope);
      if (q.status) base = base.where('c.status', '=', q.status);
      if (q.reason) base = base.where('c.reason', '=', q.reason);
      if (q.q) base = base.where((eb: any) => eb.or([eb('c.number', 'ilike', likeTerm(q.q!)), eb('c.consignee_name', 'ilike', likeTerm(q.q!))]));
      const total = Number(((await base.select((eb: any) => eb.fn.countAll().as('n')).executeTakeFirstOrThrow()) as any).n);
      const rows = await base.select(['c.id', 'c.number', 'c.challan_date', 'c.reason', 'c.consignee_name', 'c.status']).orderBy('c.challan_date', 'desc').orderBy('c.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { total, data: rows.map((r: any) => ({ id: r.id, number: r.number, date: d10(r.challan_date), reason: r.reason, consigneeName: r.consignee_name, status: r.status })) };
    });
  });

  app.get<{ Params: { id: string } }>('/delivery-challans/:id', async (req) => {
    const ctx = req.ctx; ctx.require('challans.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => load(tx, ctx, id));
  });

  app.post('/delivery-challans', async (req, reply) => {
    const ctx = req.ctx; ctx.require('challans.manage');
    const b = parse(createBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const location = await getLocation(tx, ctx, b.locationId);
      if (!location.is_active) throw badRequest('This location is inactive.', { locationId: 'Inactive' });
      const date = b.challanDate ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { challanDate: 'In the future' });
      let toLoc: any = null;
      if (b.reason === 'branch_transfer') {
        if (!b.toLocationId) throw badRequest('Choose the location the goods go to.', { toLocationId: 'Required' });
        if (b.toLocationId === b.locationId) throw badRequest('The two locations are the same.', { toLocationId: 'Same location' });
        toLoc = await getLocation(tx, ctx, b.toLocationId);
      }
      let consignee = b.consignee ? { name: b.consignee.name, address: b.consignee.address ?? null, gstin: b.consignee.gstin ?? null, state: b.consignee.stateCode ?? null } : null;
      let partyId: string | null = null;
      if (b.partyId) {
        const p = await tx.selectFrom('parties').select(['id', 'name', 'address', 'gstin', 'state_code']).where('id', '=', b.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!p) throw badRequest('Party not found.', { partyId: 'Not found' });
        partyId = p.id;
        consignee = consignee ?? { name: p.name, address: p.address ?? null, gstin: p.gstin ?? null, state: p.state_code ?? null };
      }
      if (!consignee && toLoc) consignee = { name: toLoc.name, address: null, gstin: null, state: toLoc.state_code ?? null };
      if (!consignee) throw badRequest('Give the consignee: choose a party or type a name.', { consignee: 'Required' });

      const ids = [...new Set(b.lines.map((l) => l.itemId))];
      const items = await tx.selectFrom('items').selectAll().where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
      const byId = new Map(items.map((i) => [i.id, i]));
      const lines = b.lines.map((l, i) => {
        const item = byId.get(l.itemId);
        if (!item) throw badRequest(`Line ${i + 1}: item not found.`, { [`lines.${i}.itemId`]: 'Not found' });
        if (!item.is_active) throw badRequest(`Line ${i + 1}: ${item.name} is inactive.`, { [`lines.${i}.itemId`]: 'Inactive' });
        return { item, qty: l.qty, rate: l.rate ?? item.sale_price, description: l.description ?? item.name, provisional: l.provisional === true };
      });
      const pos = consignee.state ?? location.state_code;
      const gst = computeGst(location.state_code, pos, lines.map((l) => ({ qty: l.qty, rate: l.rate, discountPct: 0, gstRate: l.item.gst_rate })));

      // Stock check and cost at average, holding the item locks until commit.
      const tracked = lines.filter((l) => l.item.track_stock);
      await lockItems(tx, ctx.companyId, tracked.map((l) => l.item.id));
      const need = new Map<string, number>();
      for (const l of tracked) need.set(l.item.id, round3((need.get(l.item.id) ?? 0) + l.qty));
      for (const [itemId, qty] of need) await requireStock(tx, ctx, location, tracked.find((l) => l.item.id === itemId)!.item, qty);
      const pp = await positions(tx, ctx.companyId, [...need.keys()]);
      const costs = new Map<number, { value: number; costRate: number }>();
      lines.forEach((l, i) => {
        if (!l.item.track_stock) return;
        const o = issue(pp.get(l.item.id)!, l.qty, l.item.purchase_price);
        pp.set(l.item.id, o.after);
        costs.set(i, { value: o.value, costRate: o.costRate });
      });

      const number = await nextNumber(tx, ctx, 'delivery_challan', financialYear(date));
      const ch = await db(tx).insertInto('dc_challans').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, challan_date: date, reason: b.reason, reason_note: b.reasonNote ?? null,
        location_id: location.id, to_location_id: toLoc?.id ?? null, party_id: partyId, consignee_name: consignee.name, consignee_address: consignee.address,
        consignee_gstin: consignee.gstin, consignee_state: consignee.state, vehicle_no: b.vehicleNo ?? null, transporter: b.transporter ?? null,
        ewb_no: b.ewbNo ?? null, notes: b.notes ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await db(tx).insertInto('dc_lines').values(lines.map((l, i) => {
        const g = gst.lines[i]!; const c = costs.get(i);
        return {
          tenant_id: ctx.tenantId, challan_id: ch.id, line_no: i + 1, item_id: l.item.id, description: l.description, hsn_code: l.item.hsn_code, unit: l.item.unit,
          qty: l.qty, provisional: l.provisional, rate: l.rate, gst_rate: l.item.gst_rate, taxable_value: g.taxableValue, cgst: g.cgst, sgst: g.sgst, igst: g.igst,
          cost_rate: c?.costRate ?? 0, cost_value: c?.value ?? 0, tracked: l.item.track_stock,
        };
      })).execute();

      const moves: any[] = [];
      let total = 0;
      lines.forEach((l, i) => {
        const c = costs.get(i); if (!c) return;
        total = round2(total + c.value);
        moves.push({ tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: location.id, item_id: l.item.id, qty: -l.qty, rate: l.rate, cost_rate: c.costRate, value: -c.value, ref_type: 'challan', ref_id: ch.id, note: number, created_by: ctx.userId });
        if (toLoc) moves.push({ tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: toLoc.id, item_id: l.item.id, qty: l.qty, rate: l.rate, cost_rate: c.costRate, value: c.value, ref_type: 'challan', ref_id: ch.id, note: number, created_by: ctx.userId });
      });
      if (moves.length) await tx.insertInto('stock_moves').values(moves).execute();
      if (!toLoc && total > 0) {
        const acc = await systemAccounts(tx, ctx);
        const outAcc = await challanAccount(tx, ctx);
        await postJournal(tx, auditOf(ctx), { date, voucherType: 'stock', voucherId: ch.id, number, narration: `Goods out on challan ${number}`,
          lines: [{ accountId: outAcc, amount: total, locationId: location.id }, { accountId: acc.inventory, amount: -total, locationId: location.id }] });
      }
      await writeAudit(tx, auditOf(ctx), 'delivery_challan', ch.id, 'create', null, { number, reason: b.reason });
      return load(tx, ctx, ch.id);
    });
    return reply.status(201).send(out);
  });

  app.post<{ Params: { id: string } }>('/delivery-challans/:id/return', async (req) => {
    const ctx = req.ctx; ctx.require('challans.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(returnBody, req.body);
    return ctx.tx(async (tx) => {
      const { ch, lines } = await lockChallan(tx, ctx, id);
      const date = b.date ?? todayIst();
      const picks = pickLines(lines, b.lines);
      await stockBack(tx, ctx, ch, picks, 'challan_return', `Returned on ${ch.number}`, date);
      for (const p of picks) await db(tx).updateTable('dc_lines').set({ returned_qty: round3(Number(p.line.returned_qty) + p.qty) }).where('id', '=', p.line.id).execute();
      await db(tx).insertInto('dc_events').values({ tenant_id: ctx.tenantId, challan_id: id, kind: 'return', event_date: date, detail: JSON.stringify(picks.map((p) => ({ lineId: p.line.id, qty: p.qty }))), created_by: ctx.userId }).execute();
      await setStatus(tx, id);
      await writeAudit(tx, auditOf(ctx), 'delivery_challan', id, 'return', null, { lines: picks.length });
      return load(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/delivery-challans/:id/invoice', async (req, reply) => {
    const ctx = req.ctx; ctx.require('challans.manage', 'invoices.create'); ctx.require('invoices.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(invoiceBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const { ch, lines } = await lockChallan(tx, ctx, id);
      if (ch.reason === 'job_work' || ch.reason === 'branch_transfer') throw badRequest('This challan is not a sale. Return the goods instead.', { reason: 'Not convertible' });
      if (!ch.party_id) throw badRequest('Add a customer to the challan before billing it.', { partyId: 'No customer' });
      const picks = pickLines(lines, b.lines);
      if (!picks.length) throw badRequest('Nothing is pending on this challan.', { lines: 'Nothing pending' });
      const date = b.invoiceDate ?? todayIst();
      // The goods come back into stock first, then the invoice issues them in the usual way.
      await stockBack(tx, ctx, ch, picks, 'challan_return', `Billed from ${ch.number}`, date);
      const invoice = await createInvoice(ctx, tx, {
        locationId: ch.location_id, partyId: ch.party_id, invoiceDate: date, notes: `Against delivery challan ${ch.number}`,
        lines: picks.map((p) => ({ itemId: p.line.item_id, qty: p.qty, rate: Number(p.line.rate), description: p.line.description })),
      } as never);
      for (const p of picks) await db(tx).updateTable('dc_lines').set({ invoiced_qty: round3(Number(p.line.invoiced_qty) + p.qty) }).where('id', '=', p.line.id).execute();
      await db(tx).insertInto('dc_events').values({ tenant_id: ctx.tenantId, challan_id: id, kind: 'invoice', event_date: date, invoice_id: invoice.id, detail: JSON.stringify(picks.map((p) => ({ lineId: p.line.id, qty: p.qty }))), created_by: ctx.userId }).execute();
      await setStatus(tx, id);
      await writeAudit(tx, auditOf(ctx), 'delivery_challan', id, 'invoice', null, { invoiceId: invoice.id });
      return { challan: await load(tx, ctx, id), invoice };
    });
    return reply.status(201).send(out);
  });

  app.post<{ Params: { id: string } }>('/delivery-challans/:id/cancel', async (req) => {
    const ctx = req.ctx; ctx.require('challans.manage');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const { ch, lines } = await lockChallan(tx, ctx, id);
      if (lines.some((l) => Number(l.returned_qty) > 0 || Number(l.invoiced_qty) > 0)) throw conflict('Goods were returned or billed against this challan.', 'HAS_ACTIVITY');
      const moves = await db(tx).selectFrom('stock_moves').selectAll().where('ref_type', '=', 'challan').where('ref_id', '=', id).execute();
      if (moves.length) {
        await lockItems(tx, ctx.companyId, moves.map((m) => m.item_id));
        await tx.insertInto('stock_moves').values(moves.map((m) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: m.location_id, item_id: m.item_id, qty: -m.qty, rate: m.rate, cost_rate: m.cost_rate,
          value: -m.value, ref_type: 'challan_cancel', ref_id: id, note: `Cancelled ${ch.number}`, created_by: ctx.userId,
        }))).execute();
      }
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${ch.number}: ${reason}`);
      await db(tx).updateTable('dc_challans').set({ status: 'cancelled', cancel_reason: reason }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'delivery_challan', id, 'cancel', { status: ch.status }, { status: 'cancelled', reason });
      return load(tx, ctx, id);
    });
  });
}
