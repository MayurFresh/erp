import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { docDate, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';
import { activeBoms, explode, post, putStock, round2, round3, round4, showCost, takeStock } from './mfg-common.ts';
import { createPo } from './purchase-orders.ts';
import { documentRoute } from '../lib/openapi.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const qtyPositive = qtyField.refine((v) => v > 0, 'Must be more than zero');

// Material planning ----------------------------------------------------------------------------------

export interface Shortage { itemId: string; name: string; unit: string; required: number; onHand: number; onOrder: number; shortage: number }

/**
 * Light MRP. Demand: open sales orders for items that have a bill of materials (less finished stock and open production),
 * exploded to raw material, plus material still to be issued on open production orders. Supply: stock and open purchase orders.
 */
export async function computeShortages(tx: Tx, ctx: RequestContext, locationId: string | undefined): Promise<Shortage[]> {
  const defs = await activeBoms(tx, ctx.companyId);
  const need = new Map<string, number>();
  const add = (id: string, q: number) => need.set(id, (need.get(id) ?? 0) + q);

  const demand = await tx.selectFrom('sales_order_lines as l').innerJoin('sales_orders as s', 's.id', 'l.order_id')
    .select((eb) => ['l.item_id', eb.fn.sum<number>(eb.ref('l.qty_ordered')).as('ordered'),
      eb.fn.sum<number>(eb.ref('l.qty_dispatched')).as('dispatched'), eb.fn.sum<number>(eb.ref('l.qty_cancelled')).as('cancelled')])
    .where('s.company_id', '=', ctx.companyId)
    .where('s.status', 'in', ['confirmed', 'picking', 'packed', 'partially_dispatched'])
    .where('l.item_id', 'in', [...defs.keys(), '00000000-0000-0000-0000-000000000000']).groupBy('l.item_id').execute();
  const open = await tx.selectFrom('mfg_orders').select(['id', 'item_id', 'qty', 'good_qty'])
    .where('company_id', '=', ctx.companyId).where('status', 'in', ['released', 'in_progress']).execute();
  const finishedIds = demand.map((d) => d.item_id);
  const finStock = finishedIds.length ? await tx.selectFrom('stock_moves').select((eb) => ['item_id', eb.fn.sum<number>('qty').as('qty')])
    .where('company_id', '=', ctx.companyId).where('item_id', 'in', finishedIds)
    .$if(!!locationId, (qb) => qb.where('location_id', '=', locationId!)).groupBy('item_id').execute() : [];
  for (const d of demand) {
    const open1 = Number(d.ordered) - Number(d.dispatched) - Number(d.cancelled);
    const making = open.filter((x) => x.item_id === d.item_id).reduce((s, x) => s + Math.max(0, x.qty - x.good_qty), 0);
    const net = open1 - Number(finStock.find((s) => s.item_id === d.item_id)?.qty ?? 0) - making;
    if (net > 0.0005) for (const [id, q] of explode(defs, defs.get(d.item_id)!, net).raw) add(id, q);
  }
  if (open.length) {
    const mats = await tx.selectFrom('mfg_order_materials').select(['item_id', 'planned_qty', 'issued_qty', 'returned_qty'])
      .where('order_id', 'in', open.map((x) => x.id)).execute();
    for (const m of mats) {
      const left = m.planned_qty - (m.issued_qty - m.returned_qty);
      if (left > 0.0005) add(m.item_id, left);
    }
  }
  const ids = [...need.keys()];
  if (!ids.length) return [];
  const items = await tx.selectFrom('items').select(['id', 'name', 'unit']).where('id', 'in', ids).execute();
  const stock = await tx.selectFrom('stock_moves').select((eb) => ['item_id', eb.fn.sum<number>('qty').as('qty')])
    .where('company_id', '=', ctx.companyId).where('item_id', 'in', ids)
    .$if(!!locationId, (qb) => qb.where('location_id', '=', locationId!)).groupBy('item_id').execute();
  const po = await tx.selectFrom('purchase_order_lines as l').innerJoin('purchase_orders as p', 'p.id', 'l.purchase_order_id')
    .select((eb) => ['l.item_id', eb.fn.sum<number>(eb.ref('l.qty')).as('qty'), eb.fn.sum<number>(eb.ref('l.received_qty')).as('got'),
      eb.fn.sum<number>(eb.ref('l.cancelled_qty')).as('cancelled')])
    .where('p.company_id', '=', ctx.companyId).where('p.status', 'in', ['approved', 'sent', 'partially_received'])
    .where('l.item_id', 'in', ids).groupBy('l.item_id').execute();
  return ids.map((id): Shortage => {
    const it = items.find((x) => x.id === id);
    const required = round3(need.get(id)!);
    const onHand = round3(Number(stock.find((s) => s.item_id === id)?.qty ?? 0));
    const p = po.find((x) => x.item_id === id);
    const onOrder = p ? round3(Math.max(0, Number(p.qty) - Number(p.got) - Number(p.cancelled))) : 0;
    return { itemId: id, name: it?.name ?? '', unit: it?.unit ?? '', required, onHand, onOrder, shortage: round3(Math.max(0, required - onHand - onOrder)) };
  }).filter((r) => r.shortage > 0.0005).sort((a, b) => a.name.localeCompare(b.name));
}

// Job work -------------------------------------------------------------------------------------------

const challanBody = z.object({
  partyId: z.uuid(), locationId: z.uuid(), challanDate: docDate.optional(),
  process: z.string().trim().min(1, 'Describe the process').max(150),
  expectedReturn: dateField.nullable().optional(), vehicleNo: optionalText(20), notes: optionalText(500),
  lines: z.array(z.object({ itemId: z.uuid(), returnItemId: z.uuid().optional(), qty: qtyPositive })).min(1, 'Add at least one item').max(100),
});
const receiveBody = z.object({
  date: docDate.optional(), note: optionalText(300),
  lines: z.array(z.object({ lineId: z.uuid(), qtyReceived: qtyField.refine((v) => v >= 0, 'Cannot be negative'), qtyScrap: qtyField.refine((v) => v >= 0, 'Cannot be negative').optional() })).min(1).max(100),
});
const jwList = pagingQuery.extend({ status: z.enum(['open', 'partially_returned', 'returned', 'cancelled']).optional(), partyId: z.uuid().optional() });
const itcQuery = z.object({ from: dateField.optional(), to: dateField.optional() });

async function loadChallan(tx: Tx, ctx: RequestContext, id: string) {
  const c = await tx.selectFrom('mfg_jobwork_challans as c').innerJoin('parties as p', 'p.id', 'c.party_id').innerJoin('locations as l', 'l.id', 'c.location_id')
    .selectAll('c').select(['p.name as party_name', 'p.gstin', 'p.address', 'p.state_code', 'l.name as location_name'])
    .where('c.id', '=', id).where('c.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!c || !ctx.canAccessLocation(c.location_id)) throw notFound('Job work challan');
  const lines = await tx.selectFrom('mfg_jobwork_lines as l').innerJoin('items as i', 'i.id', 'l.item_id').innerJoin('items as r', 'r.id', 'l.return_item_id')
    .select(['l.id', 'l.item_id', 'i.name', 'i.unit', 'i.hsn_code', 'l.return_item_id', 'r.name as return_name', 'l.qty_sent', 'l.qty_received', 'l.qty_scrap', 'l.cost_rate', 'l.value'])
    .where('l.challan_id', '=', id).orderBy('l.line_no').execute();
  const receipts = await tx.selectFrom('mfg_jobwork_receipts as r').innerJoin('users as u', 'u.id', 'r.created_by')
    .select(['r.id', 'r.receipt_date', 'r.note', 'r.created_at', 'u.name as by']).where('r.challan_id', '=', id).orderBy('r.created_at').execute();
  const rlines = receipts.length ? await tx.selectFrom('mfg_jobwork_receipt_lines').selectAll().where('receipt_id', 'in', receipts.map((r) => r.id)).execute() : [];
  const cost = showCost(ctx);
  const ageDays = Math.max(0, Math.round((Date.parse(todayIst()) - Date.parse(c.challan_date)) / 86_400_000));
  const company = await tx.selectFrom('companies').select(['name', 'gstin']).where('id', '=', ctx.companyId).executeTakeFirst();
  return {
    id: c.id, number: c.number, status: c.status, partyId: c.party_id, partyName: c.party_name, partyGstin: c.gstin, partyAddress: c.address,
    partyStateCode: c.state_code, locationId: c.location_id, locationName: c.location_name, challanDate: c.challan_date, process: c.process,
    expectedReturn: c.expected_return, vehicleNo: c.vehicle_no, notes: c.notes, cancelReason: c.cancel_reason, ageDays,
    companyName: company?.name ?? null, companyGstin: company?.gstin ?? null, createdAt: c.created_at, updatedAt: c.updated_at,
    lines: lines.map((l) => ({
      id: l.id, itemId: l.item_id, name: l.name, unit: l.unit, hsnCode: l.hsn_code, returnItemId: l.return_item_id, returnName: l.return_name,
      qtySent: l.qty_sent, qtyReceived: l.qty_received, qtyScrap: l.qty_scrap, qtyPending: round3(l.qty_sent - l.qty_received - l.qty_scrap),
      ...(cost ? { costRate: l.cost_rate, value: l.value } : {}),
    })),
    receipts: receipts.map((r) => ({
      id: r.id, date: r.receipt_date, note: r.note, by: r.by, createdAt: r.created_at,
      lines: rlines.filter((x) => x.receipt_id === r.id).map((x) => ({ lineId: x.line_id, qtyReceived: x.qty_received, qtyScrap: x.qty_scrap })),
    })),
  };
}

export async function manufacturingPlanningRoutes(app: FastifyInstance) {
  app.get('/manufacturing/mrp', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.view');
    const q = parse(z.object({ locationId: z.uuid().optional() }), req.query);
    return ctx.tx(async (tx) => {
      if (q.locationId) await getLocation(tx, ctx, q.locationId);
      const shortages = await computeShortages(tx, ctx, q.locationId);
      return { shortages, shortagesCount: shortages.length };
    });
  });

  app.post('/manufacturing/mrp/purchase-order', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.manage');
    ctx.require('purchase_orders.manage');
    const body = parse(z.object({
      partyId: z.uuid(), locationId: z.uuid(), expectedDate: docDate.nullable().optional(),
      lines: z.array(z.object({ itemId: z.uuid(), qty: qtyPositive })).min(1).max(200),
    }), req.body);
    const po = await ctx.tx(async (tx) => {
      const made = await createPo(ctx, tx, { ...body, notes: 'Raised from material planning' });
      await writeAudit(tx, auditOf(ctx), 'mfg_mrp', ctx.companyId, 'purchase_order', null, { lines: body.lines.length });
      return made;
    });
    return reply.status(201).send(po);
  });

  // Job work outward ---------------------------------------------------------------------------------
  app.get('/manufacturing/jobwork', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.view');
    const q = parse(jwList, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('mfg_jobwork_challans as c').innerJoin('parties as p', 'p.id', 'c.party_id').where('c.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('c.location_id', 'in', scope);
      if (q.status) base = base.where('c.status', '=', q.status);
      if (q.partyId) base = base.where('c.party_id', '=', q.partyId);
      if (q.q) base = base.where((eb) => eb.or([eb('c.number', 'ilike', likeTerm(q.q!)), eb('p.name', 'ilike', likeTerm(q.q!)), eb('c.process', 'ilike', likeTerm(q.q!))]));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.select(['c.id', 'c.number', 'c.status', 'c.challan_date', 'c.process', 'c.expected_return', 'p.name as party_name', 'c.updated_at'])
        .orderBy('c.challan_date', 'desc').orderBy('c.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return {
        data: rows.map((r) => ({
          id: r.id, number: r.number, status: r.status, challanDate: r.challan_date, process: r.process, expectedReturn: r.expected_return,
          partyName: r.party_name, updatedAt: r.updated_at,
        })),
        total,
      };
    });
  });

  // Registered before /jobwork/:id so the word is not read as an id.
  app.get('/manufacturing/jobwork/itc04', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.view');
    const q = parse(itcQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('mfg_jobwork_lines as l').innerJoin('mfg_jobwork_challans as c', 'c.id', 'l.challan_id')
        .innerJoin('parties as p', 'p.id', 'c.party_id').innerJoin('items as i', 'i.id', 'l.item_id')
        .where('c.company_id', '=', ctx.companyId).where('c.status', '!=', 'cancelled');
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('c.location_id', 'in', scope);
      if (q.from) base = base.where('c.challan_date', '>=', q.from);
      if (q.to) base = base.where('c.challan_date', '<=', q.to);
      const rows = await base.select(['p.id as party_id', 'p.name as party_name', 'p.gstin', 'p.state_code', 'i.id as item_id', 'i.name as item_name',
        'i.unit', 'i.hsn_code', 'c.number', 'c.challan_date', 'l.qty_sent', 'l.qty_received', 'l.qty_scrap', 'l.value'])
        .orderBy('p.name').orderBy('i.name').orderBy('c.challan_date').execute();
      const today = Date.parse(todayIst());
      const cost = showCost(ctx);
      const groups = new Map<string, {
        partyId: string; partyName: string; gstin: string | null; stateCode: string | null; itemId: string; itemName: string; unit: string;
        hsnCode: string | null; challans: string[]; sent: number; received: number; scrap: number; pending: number; value: number; oldestAgeDays: number;
      }>();
      for (const r of rows) {
        const key = `${r.party_id}:${r.item_id}`;
        const g = groups.get(key) ?? {
          partyId: r.party_id, partyName: r.party_name, gstin: r.gstin, stateCode: r.state_code, itemId: r.item_id, itemName: r.item_name,
          unit: r.unit, hsnCode: r.hsn_code, challans: [], sent: 0, received: 0, scrap: 0, pending: 0, value: 0, oldestAgeDays: 0,
        };
        const pending = r.qty_sent - r.qty_received - r.qty_scrap;
        g.sent = round3(g.sent + r.qty_sent); g.received = round3(g.received + r.qty_received); g.scrap = round3(g.scrap + r.qty_scrap);
        g.pending = round3(g.pending + pending); g.value = round2(g.value + r.value);
        if (!g.challans.includes(r.number)) g.challans.push(r.number);
        if (pending > 0.0005) g.oldestAgeDays = Math.max(g.oldestAgeDays, Math.round((today - Date.parse(r.challan_date)) / 86_400_000));
        groups.set(key, g);
      }
      return {
        note: 'Check before filing. This is a working summary of goods sent to and received from job workers, not a return.',
        from: q.from ?? null, to: q.to ?? null,
        rows: [...groups.values()].map((g) => ({
          partyId: g.partyId, jobWorker: g.partyName, gstin: g.gstin, stateCode: g.stateCode, itemId: g.itemId, item: g.itemName, unit: g.unit,
          hsnCode: g.hsnCode, challans: g.challans, qtySent: g.sent, qtyReceived: g.received, qtyScrap: g.scrap, qtyPending: g.pending,
          oldestPendingDays: g.oldestAgeDays, overdue: g.pending > 0.0005 && g.oldestAgeDays > 365, ...(cost ? { valueSent: g.value } : {}),
        })),
      };
    });
  });

  app.get<{ Params: { id: string } }>('/manufacturing/jobwork/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadChallan(tx, ctx, id));
  });

  app.post('/manufacturing/jobwork', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.issue');
    const body = parse(challanBody, req.body);
    const saved = await ctx.tx(async (tx) => {
      const location = await getLocation(tx, ctx, body.locationId);
      const party = await tx.selectFrom('parties').select(['id', 'type']).where('id', '=', body.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!party) throw badRequest('Job worker not found.', { partyId: 'Not found' });
      const date = body.challanDate ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { challanDate: 'In the future' });
      if (body.expectedReturn && body.expectedReturn < date) throw badRequest('Expected return is before the challan date.', { expectedReturn: 'Before challan date' });
      const retIds = body.lines.map((l) => l.returnItemId).filter((x): x is string => !!x);
      if (retIds.length) {
        const found = await tx.selectFrom('items').select('id').where('company_id', '=', ctx.companyId).where('id', 'in', retIds).execute();
        if (new Set(retIds).size !== found.length) throw badRequest('Processed item not found.', { returnItemId: 'Not found' });
      }
      const number = await nextNumber(tx, ctx, 'jobwork_challan', financialYear(date));
      const row = await tx.insertInto('mfg_jobwork_challans').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, fy: financialYear(date), party_id: party.id, location_id: location.id,
        challan_date: date, process: body.process, expected_return: body.expectedReturn ?? null, vehicle_no: body.vehicleNo ?? null,
        notes: body.notes ?? null, cancel_reason: null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      const costed = await takeStock(tx, ctx, location, body.lines.map((l) => ({ itemId: l.itemId, qty: l.qty })), 'jobwork_out', row.id, `${number} sent for job work`);
      await tx.insertInto('mfg_jobwork_lines').values(body.lines.map((l, i) => ({
        tenant_id: ctx.tenantId, challan_id: row.id, line_no: i + 1, item_id: l.itemId, return_item_id: l.returnItemId ?? l.itemId,
        qty_sent: l.qty, cost_rate: costed[i]!.costRate, value: costed[i]!.value,
      }))).execute();
      const value = round2(costed.reduce((s, c) => s + c.value, 0));
      await post(tx, ctx, {
        date, type: 'stock', voucherId: row.id, number, locationId: location.id, narration: `Material sent for job work, ${number}`,
        lines: [['stock_in_transit', value], ['inventory', -value]],
      });
      await writeAudit(tx, auditOf(ctx), 'mfg_jobwork', row.id, 'create', null, { number, partyId: party.id, lines: body.lines.length, value });
      return loadChallan(tx, ctx, row.id);
    });
    return reply.status(201).send(saved);
  });

  app.post<{ Params: { id: string } }>('/manufacturing/jobwork/:id/receive', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.issue');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(receiveBody, req.body);
    return ctx.tx(async (tx) => {
      const c = await tx.selectFrom('mfg_jobwork_challans').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!c || !ctx.canAccessLocation(c.location_id)) throw notFound('Job work challan');
      if (c.status === 'cancelled' || c.status === 'returned') throw conflict(`This challan is ${c.status}.`, 'BAD_TRANSITION');
      const date = body.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });
      const lines = await tx.selectFrom('mfg_jobwork_lines').selectAll().where('challan_id', '=', id).execute();
      const prior = await tx.selectFrom('mfg_jobwork_receipt_lines as r').innerJoin('mfg_jobwork_receipts as h', 'h.id', 'r.receipt_id')
        .select((eb) => ['r.line_id', eb.fn.sum<number>('r.value').as('v')]).where('h.challan_id', '=', id).groupBy('r.line_id').execute();
      const receipt = await tx.insertInto('mfg_jobwork_receipts').values({
        tenant_id: ctx.tenantId, challan_id: id, receipt_date: date, note: body.note ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      const stockIn: { itemId: string; qty: number; value: number }[] = [];
      let recvTotal = 0;
      let lossTotal = 0;
      const rows: { line_id: string; qty_received: number; qty_scrap: number; value: number }[] = [];
      for (const r of body.lines) {
        const l = lines.find((x) => x.id === r.lineId);
        if (!l) throw badRequest('Line not found on this challan.', { lineId: 'Not found' });
        const scrap = r.qtyScrap ?? 0;
        if (r.qtyReceived + scrap <= 0) continue;
        const pending = round3(l.qty_sent - l.qty_received - l.qty_scrap);
        if (round3(r.qtyReceived + scrap) > pending + 0.0005) {
          throw conflict(`Only ${pending} is pending on this line.`, 'OVER_RECEIPT', { lineId: l.id, pending });
        }
        const done = Math.abs(r.qtyReceived + scrap - pending) < 0.0005;
        const scrapValue = round2(scrap * l.cost_rate);
        const taken = Number(prior.find((p) => p.line_id === l.id)?.v ?? 0);
        const recvValue = done ? round2(Math.max(0, l.value - taken - scrapValue)) : round2(r.qtyReceived * l.cost_rate);
        const scrapFinal = done ? round2(l.value - taken - recvValue) : scrapValue;
        if (r.qtyReceived > 0) stockIn.push({ itemId: l.return_item_id, qty: r.qtyReceived, value: recvValue });
        recvTotal += recvValue;
        lossTotal += scrapFinal;
        rows.push({ line_id: l.id, qty_received: r.qtyReceived, qty_scrap: scrap, value: round2(recvValue + scrapFinal) });
        await tx.updateTable('mfg_jobwork_lines').set({
          qty_received: round3(l.qty_received + r.qtyReceived), qty_scrap: round3(l.qty_scrap + scrap),
        }).where('id', '=', l.id).execute();
      }
      if (!rows.length) throw badRequest('Enter a quantity received or scrapped.', { lines: 'Nothing entered' });
      await tx.insertInto('mfg_jobwork_receipt_lines').values(rows.map((r) => ({ tenant_id: ctx.tenantId, receipt_id: receipt.id, ...r }))).execute();
      await putStock(tx, ctx, c.location_id, stockIn, 'jobwork_in', id, `${c.number} received from job work`);
      recvTotal = round2(recvTotal);
      lossTotal = round2(lossTotal);
      await post(tx, ctx, {
        date, type: 'stock', voucherId: receipt.id, number: c.number, locationId: c.location_id, narration: `Received from job work, ${c.number}`,
        lines: [['inventory', recvTotal], ['stock_loss', lossTotal], ['stock_in_transit', -round2(recvTotal + lossTotal)]],
      });
      const after = await tx.selectFrom('mfg_jobwork_lines').select(['qty_sent', 'qty_received', 'qty_scrap']).where('challan_id', '=', id).execute();
      const allDone = after.every((l) => l.qty_sent - l.qty_received - l.qty_scrap < 0.0005);
      await tx.updateTable('mfg_jobwork_challans').set({ status: allDone ? 'returned' : 'partially_returned', updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_jobwork', id, 'receive', null, { receiptId: receipt.id, received: recvTotal, scrap: lossTotal });
      return loadChallan(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/manufacturing/jobwork/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.issue');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) }), req.body);
    return ctx.tx(async (tx) => {
      const c = await tx.selectFrom('mfg_jobwork_challans').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!c || !ctx.canAccessLocation(c.location_id)) throw notFound('Job work challan');
      if (c.status !== 'open') throw conflict('Only a challan with nothing received can be cancelled.', 'BAD_TRANSITION');
      const lines = await tx.selectFrom('mfg_jobwork_lines').selectAll().where('challan_id', '=', id).execute();
      await putStock(tx, ctx, c.location_id, lines.map((l) => ({ itemId: l.item_id, qty: l.qty_sent, value: l.value })), 'jobwork_cancel', id, `Cancelled ${c.number}`);
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${c.number}: ${reason}`);
      await tx.updateTable('mfg_jobwork_challans').set({ status: 'cancelled', cancel_reason: reason, updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_jobwork', id, 'cancel', { status: 'open' }, { status: 'cancelled', reason });
      return loadChallan(tx, ctx, id);
    });
  });
}

documentRoute('POST', '/manufacturing/jobwork', { body: challanBody });
documentRoute('POST', '/manufacturing/jobwork/:id/receive', { body: receiveBody });
