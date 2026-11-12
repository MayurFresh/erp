// Demo restaurant data: categories, menu items, floor and service charge. Not called from seed.ts; the lead wires it in.
import type { Tx } from './database.ts';

export interface RestaurantSeedDeps { tenantId: string; companyId: string; userId: string }

const MENU: { category: string; name: string; short?: string; price: number; gst: number; diet: 'veg' | 'non_veg' | 'egg'; station: string }[] = [
  { category: 'Starters', name: 'Paneer Tikka', short: 'PNR TIKKA', price: 240, gst: 5, diet: 'veg', station: 'Tandoor' },
  { category: 'Starters', name: 'Chicken Seekh Kebab', short: 'SEEKH', price: 280, gst: 5, diet: 'non_veg', station: 'Tandoor' },
  { category: 'Starters', name: 'Veg Manchow Soup', short: 'MANCHOW', price: 120, gst: 5, diet: 'veg', station: 'Main' },
  { category: 'Mains', name: 'Dal Tadka', price: 180, gst: 5, diet: 'veg', station: 'Main' },
  { category: 'Mains', name: 'Paneer Butter Masala', short: 'PBM', price: 260, gst: 5, diet: 'veg', station: 'Main' },
  { category: 'Mains', name: 'Butter Chicken', short: 'BTR CHKN', price: 320, gst: 5, diet: 'non_veg', station: 'Main' },
  { category: 'Mains', name: 'Egg Curry', price: 190, gst: 5, diet: 'egg', station: 'Main' },
  { category: 'Breads and rice', name: 'Butter Naan', short: 'B NAAN', price: 50, gst: 5, diet: 'veg', station: 'Tandoor' },
  { category: 'Breads and rice', name: 'Jeera Rice', price: 140, gst: 5, diet: 'veg', station: 'Main' },
  { category: 'Drinks', name: 'Masala Chaas', price: 60, gst: 5, diet: 'veg', station: 'Bar' },
  { category: 'Drinks', name: 'Cold Drink 300 ml', short: 'COLD DRINK', price: 50, gst: 18, diet: 'veg', station: 'Bar' },
  { category: 'Desserts', name: 'Gulab Jamun (2 pc)', short: 'G JAMUN', price: 90, gst: 5, diet: 'veg', station: 'Main' },
];

export async function seedRestaurantDemo(tx: Tx, { tenantId, companyId }: RestaurantSeedDeps): Promise<void> {
  const exists = await tx.selectFrom('restaurant_categories').select('id').where('company_id', '=', companyId).executeTakeFirst();
  if (exists) return;

  await tx.insertInto('restaurant_settings').values({ company_id: companyId, tenant_id: tenantId, service_charge_pct: 5, service_charge_gst: 5 })
    .onConflict((oc) => oc.column('company_id').doUpdateSet({ service_charge_pct: 5 })).execute();

  const categories = [...new Set(MENU.map((m) => m.category))];
  const catIds = new Map<string, string>();
  for (const [i, name] of categories.entries()) {
    const row = await tx.insertInto('restaurant_categories').values({ tenant_id: tenantId, company_id: companyId, name, sort_order: i + 1 })
      .returning('id').executeTakeFirstOrThrow();
    catIds.set(name, row.id);
  }
  for (const m of MENU) {
    const item = await tx.insertInto('items').values({
      tenant_id: tenantId, company_id: companyId, name: m.name, sku: null, barcode: null, hsn_code: '996331', unit: 'PLATE',
      gst_rate: m.gst, sale_price: m.price, purchase_price: 0, track_stock: false, reorder_level: 0,
    }).returning('id').executeTakeFirstOrThrow();
    await tx.insertInto('restaurant_menu').values({
      item_id: item.id, tenant_id: tenantId, company_id: companyId, category_id: catIds.get(m.category)!, diet: m.diet,
      available: true, station: m.station, short_name: m.short ?? null,
    }).execute();
  }

  const floor: { area: string; tables: [string, number][] }[] = [
    { area: 'Ground floor', tables: [['T1', 2], ['T2', 2], ['T3', 4], ['T4', 4], ['T5', 4], ['T6', 6]] },
    { area: 'Terrace', tables: [['R1', 4], ['R2', 4], ['R3', 6]] },
  ];
  for (const [i, f] of floor.entries()) {
    const area = await tx.insertInto('restaurant_areas').values({ tenant_id: tenantId, company_id: companyId, name: f.area, sort_order: i + 1 })
      .returning('id').executeTakeFirstOrThrow();
    for (const [j, [name, seats]] of f.tables.entries()) {
      await tx.insertInto('restaurant_tables').values({
        tenant_id: tenantId, company_id: companyId, area_id: area.id, name, seats, sort_order: j + 1,
      }).execute();
    }
  }
}
