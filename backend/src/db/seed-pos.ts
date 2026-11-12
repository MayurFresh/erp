// Demo data for counter billing: a shop counter with everyday items and opening stock.
// Not called from seed.ts; the lead wires it into the demo accounts.
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal } from '../accounting/journal.ts';
import type { Tx } from './database.ts';
import { todayIst } from '../lib/dates.ts';

interface Who { tenantId: string; companyId: string; userId: string }

const ITEMS: { name: string; sku: string; barcode: string; hsn: string; unit: string; gst: number; price: number; cost: number; qty: number }[] = [
  { name: 'Basmati Rice 1 kg', sku: 'RICE1', barcode: '8901000100011', hsn: '1006', unit: 'pkt', gst: 5, price: 98, cost: 82, qty: 60 },
  { name: 'Toor Dal 1 kg', sku: 'DAL1', barcode: '8901000100028', hsn: '0713', unit: 'pkt', gst: 5, price: 142, cost: 124, qty: 40 },
  { name: 'Sugar 1 kg', sku: 'SUG1', barcode: '8901000100035', hsn: '1701', unit: 'pkt', gst: 5, price: 46, cost: 40, qty: 80 },
  { name: 'Sunflower Oil 1 L', sku: 'OIL1', barcode: '8901000100042', hsn: '1512', unit: 'pkt', gst: 5, price: 135, cost: 118, qty: 48 },
  { name: 'Tea Powder 250 g', sku: 'TEA250', barcode: '8901000100059', hsn: '0902', unit: 'pkt', gst: 5, price: 120, cost: 100, qty: 36 },
  { name: 'Glucose Biscuits', sku: 'GLUC', barcode: '8901000100066', hsn: '1905', unit: 'pkt', gst: 18, price: 10, cost: 8, qty: 200 },
  { name: 'Namkeen Mix 200 g', sku: 'NAM200', barcode: '8901000100073', hsn: '2106', unit: 'pkt', gst: 12, price: 55, cost: 44, qty: 50 },
  { name: 'Bath Soap', sku: 'BSOAP', barcode: '8901000100080', hsn: '3401', unit: 'pcs', gst: 18, price: 38, cost: 30, qty: 90 },
  { name: 'Detergent Powder 1 kg', sku: 'DET1', barcode: '8901000100097', hsn: '3402', unit: 'pkt', gst: 18, price: 110, cost: 92, qty: 45 },
  { name: 'Toothpaste 150 g', sku: 'TPASTE', barcode: '8901000100103', hsn: '3306', unit: 'pcs', gst: 18, price: 95, cost: 78, qty: 55 },
  { name: 'Mineral Water 1 L', sku: 'WATER1', barcode: '8901000100110', hsn: '2201', unit: 'btl', gst: 18, price: 20, cost: 14, qty: 120 },
  { name: 'Notebook 172 pages', sku: 'NOTE172', barcode: '8901000100127', hsn: '4820', unit: 'pcs', gst: 12, price: 60, cost: 46, qty: 70 },
];

export async function seedPosDemo(tx: Tx, who: Who): Promise<{ locationId: string; itemIds: string[] }> {
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', who.companyId).executeTakeFirstOrThrow();
  const loc = await tx.insertInto('locations').values({
    tenant_id: who.tenantId, company_id: who.companyId, parent_id: null, type: 'store', name: 'Main Counter', code: 'POS1',
    state_code: company.state_code, address: null, pincode: null,
  }).returning('id').executeTakeFirstOrThrow();

  const acc = await systemAccounts(tx, { tenantId: who.tenantId, companyId: who.companyId } as never);
  const itemIds: string[] = [];
  let openingValue = 0;
  for (const it of ITEMS) {
    const row = await tx.insertInto('items').values({
      tenant_id: who.tenantId, company_id: who.companyId, name: it.name, sku: it.sku, barcode: it.barcode, hsn_code: it.hsn,
      unit: it.unit, gst_rate: it.gst, sale_price: it.price, purchase_price: it.cost, track_stock: true, reorder_level: 10,
    }).returning('id').executeTakeFirstOrThrow();
    itemIds.push(row.id);
    const value = Math.round(it.qty * it.cost * 100) / 100;
    openingValue += value;
    await tx.insertInto('stock_moves').values({
      tenant_id: who.tenantId, company_id: who.companyId, location_id: loc.id, item_id: row.id, qty: it.qty, rate: it.cost,
      cost_rate: it.cost, value, ref_type: 'opening', ref_id: null, note: 'Demo opening stock', created_by: who.userId,
    }).execute();
  }
  await postJournal(tx, { tenantId: who.tenantId, companyId: who.companyId, userId: who.userId }, {
    date: todayIst(), voucherType: 'stock', voucherId: null, number: null, narration: 'Opening stock: Main Counter demo items',
    lines: [
      { accountId: acc.inventory, amount: openingValue, locationId: loc.id },
      { accountId: acc.opening_balances, amount: -openingValue, locationId: loc.id },
    ],
  });
  return { locationId: loc.id, itemIds };
}
