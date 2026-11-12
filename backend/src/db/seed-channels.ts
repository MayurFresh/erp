// Demo data for online channels: a warehouse with three items, a bundle and a channel set up for CSV import.
// Not called from seed.ts; the lead wires it into the demo accounts.
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal } from '../accounting/journal.ts';
import { todayIst } from '../lib/dates.ts';
import type { Tx } from './database.ts';

interface Who { tenantId: string; companyId: string; userId: string }

const ITEMS = [
  { name: 'Cotton Kurta Blue M', sku: 'KURTA-BLU-M', hsn: '6104', gst: 5, price: 799, cost: 420, qty: 40 },
  { name: 'Cotton Kurta Blue L', sku: 'KURTA-BLU-L', hsn: '6104', gst: 5, price: 799, cost: 420, qty: 30 },
  { name: 'Steel Water Bottle 750 ml', sku: 'BOTTLE-750', hsn: '7323', gst: 18, price: 449, cost: 250, qty: 60 },
  { name: 'Bamboo Toothbrush Pack of 4', sku: 'BRUSH-4', hsn: '9603', gst: 18, price: 299, cost: 140, qty: 80 },
];

export async function seedChannelsDemo(tx: Tx, who: Who): Promise<{ connectionId: string; locationId: string; itemIds: string[] }> {
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', who.companyId).executeTakeFirstOrThrow();
  const loc = await tx.insertInto('locations').values({
    tenant_id: who.tenantId, company_id: who.companyId, parent_id: null, type: 'warehouse', name: 'Online Fulfilment', code: 'ONL1',
    state_code: company.state_code, address: null, pincode: null,
  }).returning('id').executeTakeFirstOrThrow();
  const acc = await systemAccounts(tx, { tenantId: who.tenantId, companyId: who.companyId });
  const itemIds: string[] = [];
  let opening = 0;
  for (const it of ITEMS) {
    const row = await tx.insertInto('items').values({
      tenant_id: who.tenantId, company_id: who.companyId, name: it.name, sku: it.sku, hsn_code: it.hsn, unit: 'pcs', gst_rate: it.gst,
      sale_price: it.price, purchase_price: it.cost, track_stock: true, reorder_level: 10,
    }).returning('id').executeTakeFirstOrThrow();
    itemIds.push(row.id);
    const value = Math.round(it.qty * it.cost * 100) / 100;
    opening += value;
    await tx.insertInto('stock_moves').values({
      tenant_id: who.tenantId, company_id: who.companyId, location_id: loc.id, item_id: row.id, qty: it.qty, rate: it.cost,
      cost_rate: it.cost, value, ref_type: 'opening', ref_id: null, note: 'Demo opening stock', created_by: who.userId,
    }).execute();
  }
  await postJournal(tx, who, {
    date: todayIst(), voucherType: 'stock', voucherId: null, number: null, narration: 'Opening stock: Online Fulfilment demo items',
    lines: [{ accountId: acc.inventory, amount: opening, locationId: loc.id }, { accountId: acc.opening_balances, amount: -opening, locationId: loc.id }],
  });
  const party = await tx.insertInto('parties').values({
    tenant_id: who.tenantId, company_id: who.companyId, type: 'customer', name: 'Amazon Orders (channel)', state_code: company.state_code,
    gstin: null, phone: null, email: null, address: null, pan: null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null,
  }).returning('id').executeTakeFirstOrThrow();
  const conn = await tx.insertInto('channel_connections').values({
    tenant_id: who.tenantId, company_id: who.companyId, provider: 'amazon', name: 'Amazon (file import)', party_id: party.id, location_id: loc.id,
    status_reason: null, last_import_at: null, last_error: null, created_by: who.userId,
  }).returning('id').executeTakeFirstOrThrow();
  const listing = async (sku: string, title: string, comps: { i: number; qty: number }[]) => {
    const l = await tx.insertInto('channel_listings').values({
      tenant_id: who.tenantId, connection_id: conn.id, channel_sku: sku, title, external_id: null,
    }).returning('id').executeTakeFirstOrThrow();
    await tx.insertInto('channel_listing_components').values(comps.map((c) => ({
      tenant_id: who.tenantId, listing_id: l.id, item_id: itemIds[c.i]!, qty: c.qty,
    }))).execute();
  };
  await listing('AMZ-KURTA-M', 'Blue cotton kurta, medium', [{ i: 0, qty: 1 }]);
  await listing('AMZ-KURTA-L', 'Blue cotton kurta, large', [{ i: 1, qty: 1 }]);
  await listing('AMZ-BOTTLE', 'Steel water bottle 750 ml', [{ i: 2, qty: 1 }]);
  await listing('AMZ-ECO-COMBO', 'Bottle with two toothbrush packs', [{ i: 2, qty: 1 }, { i: 3, qty: 2 }]);
  return { connectionId: conn.id, locationId: loc.id, itemIds };
}
