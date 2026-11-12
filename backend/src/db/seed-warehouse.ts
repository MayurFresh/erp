// Demo data for the warehouse module: bins in the company's main (first) location, batch-tracked sample items (one batch near expiry).
// Names suit any trade. Not called from seed.ts; the lead wires it into the demo accounts.
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal } from '../accounting/journal.ts';
import { addDays, todayIst } from '../lib/dates.ts';
import type { Tx } from './database.ts';

interface Who { tenantId: string; companyId: string; userId: string }

const ITEMS = [
  { name: 'Sample item A (batch tracked)', sku: 'WH-A', hsn: '9999', cost: 12, price: 18, batches: [['A-2601', 40, 2], ['A-2602', 120, 14]] },
  { name: 'Sample item B (batch tracked)', sku: 'WH-B', hsn: '9999', cost: 46, price: 68, batches: [['B-2601', 60, 5], ['B-2602', 90, 20]] },
  { name: 'Sample item C (batch tracked)', sku: 'WH-C', hsn: '9999', cost: 14, price: 22, batches: [['C-2601', 150, 9]] },
] as const;

export async function seedWarehouseDemo(tx: Tx, who: Who): Promise<{ locationId: string; binIds: string[]; itemIds: string[] }> {
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', who.companyId).executeTakeFirstOrThrow();
  // Bins go in the main location: the first one the company created.
  const first = await tx.selectFrom('locations').select('id').where('company_id', '=', who.companyId).orderBy('created_at').orderBy('id').executeTakeFirst();
  const loc = first ?? await tx.insertInto('locations').values({
    tenant_id: who.tenantId, company_id: who.companyId, parent_id: null, type: 'warehouse', name: 'Main Store', code: 'MAIN',
    state_code: company.state_code, address: null, pincode: null,
  }).returning('id').executeTakeFirstOrThrow();
  await tx.insertInto('wh_settings').values({ company_id: who.companyId, tenant_id: who.tenantId, fefo: true, block_expired: true, expiry_warn_days: 90 })
    .onConflict((oc) => oc.column('company_id').doNothing()).execute();

  const binIds: string[] = [];
  for (const [code, zone, kind] of [['A-01', 'Rack A', 'storage'], ['A-02', 'Rack A', 'storage'], ['B-01', 'Rack B', 'storage'], ['QRN', 'Hold', 'quarantine']] as const) {
    const r = await tx.insertInto('wh_bins').values({
      tenant_id: who.tenantId, company_id: who.companyId, location_id: loc.id, code, name: `${zone} ${code}`, zone, kind,
    }).returning('id').executeTakeFirstOrThrow();
    binIds.push(r.id);
  }

  const acc = await systemAccounts(tx, { tenantId: who.tenantId, companyId: who.companyId } as never);
  const itemIds: string[] = [];
  let openingValue = 0;
  const today = todayIst();
  let n = 0;
  for (const m of ITEMS) {
    const item = await tx.insertInto('items').values({
      tenant_id: who.tenantId, company_id: who.companyId, name: m.name, sku: m.sku, hsn_code: m.hsn, unit: 'nos', gst_rate: 5,
      sale_price: m.price, purchase_price: m.cost, track_stock: true, reorder_level: 20,
    }).returning('id').executeTakeFirstOrThrow();
    itemIds.push(item.id);
    await tx.insertInto('wh_item_rules').values({ item_id: item.id, tenant_id: who.tenantId, company_id: who.companyId, tracking: 'batch', shelf_life_days: 730, default_bin_id: binIds[0]! }).execute();
    for (const [batchNo, qty, months] of m.batches) {
      const value = Math.round(qty * m.cost * 100) / 100;
      openingValue += value;
      await tx.insertInto('stock_moves').values({
        tenant_id: who.tenantId, company_id: who.companyId, location_id: loc.id, item_id: item.id, qty, rate: m.cost,
        cost_rate: m.cost, value, ref_type: 'opening', ref_id: null, note: 'Demo opening stock', created_by: who.userId,
      }).execute();
      const batch = await tx.insertInto('wh_batches').values({
        tenant_id: who.tenantId, company_id: who.companyId, item_id: item.id, batch_no: batchNo, mfg_date: addDays(today, -300),
        // The first batch of the first item is close to expiry so the report has something to show.
        expiry_date: addDays(today, n === 0 ? 20 : months * 30), mrp: m.price,
      }).returning('id').executeTakeFirstOrThrow();
      await tx.insertInto('wh_moves').values({
        tenant_id: who.tenantId, company_id: who.companyId, location_id: loc.id, item_id: item.id, bin_id: binIds[n % 3]!, batch_id: batch.id,
        qty, kind: 'receipt', ref_type: 'opening', ref_id: null, note: 'Demo placement', created_by: who.userId,
      }).execute();
      n += 1;
    }
  }
  await postJournal(tx, { tenantId: who.tenantId, companyId: who.companyId, userId: who.userId }, {
    date: today, voucherType: 'stock', voucherId: null, number: null, narration: 'Opening stock: warehouse demo items',
    lines: [
      { accountId: acc.inventory, amount: openingValue, locationId: loc.id },
      { accountId: acc.opening_balances, amount: -openingValue, locationId: loc.id },
    ],
  });
  return { locationId: loc.id, binIds, itemIds };
}
