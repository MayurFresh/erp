// Demo data for manufacturing: a steel almirah maker with a two-level bill of materials, work centres,
// opening raw material stock, a job worker and one released production order.
// Not called from seed.ts; the lead wires it into the demo accounts.
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal } from '../accounting/journal.ts';
import { financialYear, todayIst } from '../lib/dates.ts';
import { nextNumber } from '../lib/series.ts';
import type { Tx } from './database.ts';

interface Who { tenantId: string; companyId: string; userId: string }

const RAW = [
  { name: 'MS Sheet 18 gauge', sku: 'MFG-SHEET', unit: 'kg', hsn: '7208', gst: 18, cost: 62, qty: 2000 },
  { name: 'Welding Rod', sku: 'MFG-ROD', unit: 'kg', hsn: '8311', gst: 18, cost: 140, qty: 60 },
  { name: 'Powder Coat Paint', sku: 'MFG-PAINT', unit: 'kg', hsn: '3208', gst: 18, cost: 320, qty: 80 },
  { name: 'Lock Set', sku: 'MFG-LOCK', unit: 'nos', hsn: '8301', gst: 18, cost: 85, qty: 150 },
  { name: 'Packing Carton', sku: 'MFG-CARTON', unit: 'nos', hsn: '4819', gst: 12, cost: 55, qty: 120 },
];

export async function seedManufacturingDemo(tx: Tx, who: Who): Promise<{ locationId: string; finishedItemId: string; orderId: string }> {
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', who.companyId).executeTakeFirstOrThrow();
  const base = { tenant_id: who.tenantId, company_id: who.companyId };
  const loc = await tx.insertInto('locations').values({
    ...base, parent_id: null, type: 'warehouse', name: 'Plant 1 Store', code: 'PLANT1', state_code: company.state_code, address: null, pincode: null,
  }).returning('id').executeTakeFirstOrThrow();

  const acc = await systemAccounts(tx, who);
  const ids: Record<string, string> = {};
  let opening = 0;
  for (const r of RAW) {
    const row = await tx.insertInto('items').values({
      ...base, name: r.name, sku: r.sku, hsn_code: r.hsn, unit: r.unit, gst_rate: r.gst, sale_price: 0, purchase_price: r.cost,
      track_stock: true, reorder_level: 0,
    }).returning('id').executeTakeFirstOrThrow();
    ids[r.sku] = row.id;
    const value = Math.round(r.qty * r.cost * 100) / 100;
    opening += value;
    await tx.insertInto('stock_moves').values({
      ...base, location_id: loc.id, item_id: row.id, qty: r.qty, rate: r.cost, cost_rate: r.cost, value,
      ref_type: 'opening', ref_id: null, note: 'Demo opening stock', created_by: who.userId,
    }).execute();
  }
  await postJournal(tx, who, {
    date: todayIst(), voucherType: 'stock', voucherId: null, number: null, narration: 'Opening stock: Plant 1 demo raw material',
    lines: [{ accountId: acc.inventory, amount: opening, locationId: loc.id }, { accountId: acc.opening_balances, amount: -opening, locationId: loc.id }],
  });

  const mk = async (name: string, sku: string, price: number, cost: number) => (await tx.insertInto('items').values({
    ...base, name, sku, hsn_code: '9403', unit: 'nos', gst_rate: 18, sale_price: price, purchase_price: cost, track_stock: true, reorder_level: 0,
  }).returning('id').executeTakeFirstOrThrow()).id;
  const frame = await mk('Steel Almirah Frame', 'MFG-FRAME', 0, 600);
  const almirah = await mk('Steel Almirah 2 Door', 'MFG-ALMIRAH', 9500, 1200);
  await tx.insertInto('parties').values({
    ...base, type: 'vendor', name: 'Shree Powder Coating Works', gstin: null, state_code: company.state_code, phone: null, email: null, address: 'GIDC, Vatva', credit_limit: 0,
  }).execute();

  const wc = async (name: string, rate: number) => (await tx.insertInto('mfg_work_centres').values({ ...base, name, hourly_cost: rate })
    .returning('id').executeTakeFirstOrThrow()).id;
  const cutting = await wc('Cutting and welding', 300);
  const assembly = await wc('Assembly', 180);
  await tx.insertInto('mfg_settings').values({ company_id: who.companyId, tenant_id: who.tenantId, overhead_pct: 10 }).execute();

  const bom = async (itemId: string, lines: [string, number, number][], steps: [string, string, number][]) => {
    const b = await tx.insertInto('mfg_boms').values({
      ...base, item_id: itemId, version: 1, output_qty: 1, status: 'active', note: null, activated_at: new Date(), created_by: who.userId,
    }).returning('id').executeTakeFirstOrThrow();
    await tx.insertInto('mfg_bom_lines').values(lines.map(([item, qty, scrap], i) => ({
      tenant_id: who.tenantId, bom_id: b.id, line_no: i + 1, kind: 'component', item_id: item, qty, scrap_pct: scrap,
    }))).execute();
    await tx.insertInto('mfg_bom_steps').values(steps.map(([op, centre, mins], i) => ({
      tenant_id: who.tenantId, bom_id: b.id, step_no: i + 1, operation: op, work_centre_id: centre, minutes_per_unit: mins,
    }))).execute();
    return b.id;
  };
  await bom(frame, [[ids['MFG-SHEET']!, 18, 5], [ids['MFG-ROD']!, 0.2, 0]], [['Cut and weld', cutting, 90]]);
  const almBom = await bom(almirah, [[frame, 1, 0], [ids['MFG-PAINT']!, 0.8, 0], [ids['MFG-LOCK']!, 1, 0], [ids['MFG-CARTON']!, 1, 0]], [['Assemble and fit', assembly, 45]]);

  const number = await nextNumber(tx, who, 'production_order', financialYear(todayIst()));
  const order = await tx.insertInto('mfg_orders').values({
    ...base, number, fy: financialYear(todayIst()), item_id: almirah, bom_id: almBom, location_id: loc.id, qty: 10, planned_start: todayIst(),
    planned_end: null, status: 'released', overhead_pct: 10, sales_order_id: null, notes: 'Demo order', created_by: who.userId,
    released_at: new Date(), closed_at: null, close_note: null, cancel_reason: null,
  }).returning('id').executeTakeFirstOrThrow();
  await tx.insertInto('mfg_order_materials').values([
    [frame, 10], [ids['MFG-PAINT']!, 8], [ids['MFG-LOCK']!, 10], [ids['MFG-CARTON']!, 10],
  ].map(([item, qty]) => ({ tenant_id: who.tenantId, order_id: order.id, item_id: item as string, planned_qty: qty as number }))).execute();
  await tx.insertInto('mfg_order_steps').values([{
    tenant_id: who.tenantId, order_id: order.id, step_no: 1, operation: 'Assemble and fit', work_centre_id: assembly, minutes_per_unit: 45, hourly_cost: 180,
  }]).execute();
  return { locationId: loc.id, finishedItemId: almirah, orderId: order.id };
}
