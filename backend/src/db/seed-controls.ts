import { todayIst } from '../lib/dates.ts';

type ApiFn = (method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE', url: string, body?: unknown) => Promise<any>;

/**
 * Demo data for the v1.7 controls: cost centres, custom fields, an approval rule with one pending request,
 * and one finished CSV import. `api` acts as owner@demo.in; `as` signs in another demo user.
 */
export async function seedControls(o: { api: ApiFn; as: (email: string) => Promise<ApiFn>; runJobs: () => Promise<void> }) {
  const { api } = o;
  const today = todayIst();

  // Cost centres.
  const cc: Record<string, string> = {};
  for (const [code, name] of [['RET', 'Retail'], ['PRJ', 'Projects'], ['HO', 'Head office']] as const) {
    cc[code] = (await api('POST', '/cost-centres', { code, name })).id;
  }

  // Custom fields.
  await api('POST', '/custom-fields', { entity: 'item', key: 'brand', label: 'Brand', type: 'text', showOnPrint: true });
  await api('POST', '/custom-fields', {
    entity: 'party', key: 'region', label: 'Region', type: 'select', options: ['North', 'South', 'East', 'West'],
  });
  await api('POST', '/custom-fields', { entity: 'invoice', key: 'po_number', label: 'PO number', type: 'text', showOnPrint: true });

  // A few tagged documents.
  const locations = (await api('GET', '/locations')).data as { id: string; code: string | null }[];
  const loc = (code: string) => locations.find((l) => l.code === code) ?? locations[0]!;
  const parties = (await api('GET', '/parties?limit=200')).data as { id: string; type: string; name: string }[];
  const customers = parties.filter((p) => p.type !== 'vendor');
  const vendor = parties.find((p) => p.type === 'vendor');
  const items = (await api('GET', '/items?limit=200')).data as { id: string; sku: string | null }[];
  const bricks = items.find((i) => i.sku === 'BRK-RED') ?? items[0]!;
  const accounts = (await api('GET', '/accounts')).data as { id: string; code: string }[];
  const acct = (code: string) => accounts.find((a) => a.code === code)!.id;

  if (customers[0]) {
    await api('POST', '/invoices', {
      locationId: loc('SA-T1').id, partyId: customers[0].id, costCentreId: cc.RET, custom: { po_number: 'PO-2291' },
      lines: [{ itemId: bricks.id, qty: 500 }],
    });
    await api('POST', '/invoices', {
      locationId: loc('SA-T1').id, partyId: customers[customers.length > 1 ? 1 : 0]!.id, costCentreId: cc.PRJ, custom: { po_number: 'PO-3310' },
      lines: [{ itemId: bricks.id, qty: 800 }],
    });
  }
  await api('POST', '/expenses', {
    locationId: loc('SA-T1').id, accountId: acct('6030'), description: 'Crane hire for slab work', amount: 12000,
    paidFromAccountId: acct('1000'), costCentreId: cc.PRJ,
  });
  await api('POST', '/expenses', {
    locationId: locations[0]!.id, accountId: acct('6000'), description: 'Head office housekeeping', amount: 6500,
    paidFromAccountId: acct('1010'), costCentreId: cc.HO,
  });

  // Approvals: payments of Rs 5,00,000 or more need an Owner.
  const roles = (await api('GET', '/roles')).data as { id: string; name: string }[];
  const owner = roles.find((r) => r.name === 'Owner');
  if (owner && vendor) {
    await api('POST', '/approval-rules', {
      docType: 'payment', name: 'Large payments need the Owner', minAmount: 500000, levels: [{ approverRoleId: owner.id }],
    });
    const accountant = await o.as('accountant@demo.in');
    await accountant('POST', '/payments', {
      kind: 'payment', partyId: vendor.id, accountId: acct('1010'), amount: 600000, mode: 'bank', reference: 'NEFT-ADV-0042',
      date: today, notes: 'Advance to supplier for the next consignment',
    });
  }

  // One finished CSV import.
  const csv = 'name,sku,hsn,unit,gstRate,salePrice,purchasePrice,trackStock,reorderLevel,custom.brand\n'
    + 'Binding wire 20 kg,BND-20,7217,roll,18,1650,1420,yes,10,Tata\n'
    + 'Plywood 19 mm,PLY-19,4412,sheet,18,2150,1880,yes,20,Greenply\n'
    + 'PVC pipe 4 inch,PVC-4,3917,nos,18,540,450,yes,30,Finolex\n';
  const imp = await api('POST', '/imports', { kind: 'items', csv, fileName: 'new-items.csv' });
  if (imp.status === 'validated') {
    await api('POST', `/imports/${imp.id}/commit`);
    await o.runJobs();
  }
}
