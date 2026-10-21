// Demo data for local development: `npm run db:seed`.
// Goes through the real API handlers, so seeded data obeys every business rule.
import { buildApp } from '../app.ts';
import { loadConfig } from '../config.ts';
import { createDb } from './database.ts';

const PASSWORD = 'Demo@1234';
const config = loadConfig();
const db = createDb(config.DATABASE_URL, 2);
const app = await buildApp({ config, db, logger: false, authRateLimit: false });

async function call(method: 'GET' | 'POST' | 'PATCH', url: string, body?: unknown, token?: string, companyId?: string) {
  const headers: Record<string, string> = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (companyId) headers['x-company-id'] = companyId;
  const res = await app.inject({ method, url: `/api/v1${url}`, headers, payload: body as object | undefined });
  const json = res.body ? res.json() : null;
  if (res.statusCode >= 400) throw new Error(`${method} ${url} → ${res.statusCode}: ${JSON.stringify(json)}`);
  return json;
}

try {
  const existing = await app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email: 'owner@demo.in', password: PASSWORD } });
  if (existing.statusCode === 200) {
    console.log('Demo data already exists. Sign in as owner@demo.in / Demo@1234');
  } else {
    const auth = await call('POST', '/auth/signup', {
      businessName: 'Demo Builders & Traders', name: 'Demo Owner', email: 'owner@demo.in', password: PASSWORD,
      phone: '9800000001', stateCode: '24', gstin: '24AAACD1234F1Z5',
    });
    const token: string = auth.accessToken;
    const me = await call('GET', '/me', undefined, token);
    const companyId: string = me.companies[0].id;
    const api = (method: 'GET' | 'POST' | 'PATCH', url: string, body?: unknown) => call(method, url, body, token, companyId);

    await api('PATCH', '/company', {
      legalName: 'Demo Builders & Traders Private Limited', address: '402, Shilp Square, SG Highway, Ahmedabad, Gujarat 380054',
      phone: '079-4000-1234', email: 'accounts@demobuilders.in', website: 'www.demobuilders.in',
      bankName: 'HDFC Bank, SG Highway', bankAccountNo: '50200012345678', bankIfsc: 'HDFC0001234', upiId: 'demobuilders@hdfcbank',
      invoiceTerms: '1. Goods once sold will not be taken back.\n2. Interest at 18% p.a. on payments after the due date.\n3. Subject to Ahmedabad jurisdiction.',
      invoiceFooter: 'Thank you for your business!',
    });
    const ho = (await api('GET', '/locations')).data[0];
    const siteA = await api('POST', '/locations', { type: 'site', name: 'Site A — Tower 1', code: 'SA-T1', address: 'SG Highway, Ahmedabad' });
    const warehouse = await api('POST', '/locations', { type: 'warehouse', name: 'Central Warehouse', code: 'WH1', address: 'Changodar, Ahmedabad' });
    await api('POST', '/locations', { type: 'branch', name: 'Mumbai Branch', code: 'MUM', stateCode: '27', address: 'Andheri East, Mumbai' });
    await api('POST', '/locations', { type: 'department', name: 'Accounts Department', code: 'ACC', parentId: ho.id });

    const item = (body: Record<string, unknown>) => api('POST', '/items', body);
    const cement = await item({ name: 'Cement OPC 53 Grade (50 kg)', sku: 'CEM-OPC53', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 380, purchasePrice: 335, reorderLevel: 100 });
    const steel = await item({ name: 'Steel TMT Bar 12 mm', sku: 'TMT-12', hsnCode: '7214', unit: 'kg', gstRate: 18, salePrice: 68, purchasePrice: 61.5, reorderLevel: 2000 });
    const sand = await item({ name: 'River Sand', sku: 'SAND-R', hsnCode: '2505', unit: 'ton', gstRate: 5, salePrice: 1450, purchasePrice: 1200, reorderLevel: 10 });
    const bricks = await item({ name: 'Red Clay Bricks', sku: 'BRK-RED', hsnCode: '6901', unit: 'nos', gstRate: 5, salePrice: 9, purchasePrice: 7.2, reorderLevel: 5000 });
    const tiles = await item({ name: 'Vitrified Tiles 2x2 ft', sku: 'TIL-VT22', hsnCode: '6907', unit: 'box', gstRate: 18, salePrice: 620, purchasePrice: 540, reorderLevel: 40 });
    const paint = await item({ name: 'Interior Emulsion 20 L', sku: 'PNT-INT20', hsnCode: '3209', unit: 'bucket', gstRate: 18, salePrice: 4200, purchasePrice: 3650, reorderLevel: 10 });
    const wire = await item({ name: 'Copper Wire 1.5 sq mm (90 m)', sku: 'WIR-15', hsnCode: '8544', unit: 'roll', gstRate: 18, salePrice: 1350, purchasePrice: 1180, reorderLevel: 15 });
    await item({ name: 'Labour Charges — Masonry', sku: 'SRV-MASON', hsnCode: '9954', unit: 'day', gstRate: 18, salePrice: 900, trackStock: false });

    const stock = (locationId: string, itemId: string, qty: number, rate: number) =>
      api('POST', '/stock/adjustments', { locationId, itemId, qty, rate, note: 'Opening stock', isOpening: true });
    await stock(warehouse.id, cement.id, 800, 335);
    await stock(warehouse.id, steel.id, 12000, 61.5);
    await stock(warehouse.id, tiles.id, 150, 540);
    await stock(warehouse.id, paint.id, 25, 3650);
    await stock(warehouse.id, wire.id, 12, 1180); // below reorder level on purpose
    await stock(siteA.id, cement.id, 120, 335);
    await stock(siteA.id, steel.id, 1800, 61.5); // below reorder level on purpose
    await stock(siteA.id, sand.id, 30, 1200);
    await stock(siteA.id, bricks.id, 20000, 7.2);

    const patel = await api('POST', '/parties', { type: 'customer', name: 'Patel Constructions', gstin: '24AABCP1234C1Z9', phone: '9825000011', creditLimit: 500000, creditDays: 30 });
    const mumbai = await api('POST', '/parties', { type: 'customer', name: 'Mumbai Infra Projects', gstin: '27AAPFU0939F1ZV', phone: '9820000022', creditLimit: 1000000, creditDays: 45 });
    const walkIn = await api('POST', '/parties', { type: 'customer', name: 'Walk-in Customer', stateCode: '24' });
    const shree = await api('POST', '/parties', { type: 'vendor', name: 'Shree Cement Dealers', gstin: '24AAKFS5678D1ZQ', phone: '9879000033', creditDays: 15 });
    const tata = await api('POST', '/parties', { type: 'vendor', name: 'Mumbai Steel Suppliers', gstin: '27AABCT3518Q1ZW', phone: '9821000044', creditDays: 30 });

    const accounts = (await api('GET', '/accounts')).data as { id: string; code: string }[];
    const acct = (code: string) => accounts.find((a) => a.code === code)!.id;
    await api('POST', '/journals', { narration: 'Capital introduced by the promoters', lines: [
      { accountId: acct('1010'), debit: 2500000 }, { accountId: acct('3000'), credit: 2500000 }] });
    await api('POST', '/journals', { narration: 'Cash withdrawn from bank for site expenses', lines: [
      { accountId: acct('1000'), debit: 50000 }, { accountId: acct('1010'), credit: 50000 }] });

    const billCement = await api('POST', '/purchases', { locationId: warehouse.id, partyId: shree.id, supplierInvoiceNo: 'SCD/2026/1187',
      lines: [{ itemId: cement.id, qty: 300, rate: 330 }] });
    await api('POST', '/purchases', { locationId: warehouse.id, partyId: tata.id, supplierInvoiceNo: 'MSS-44521',
      lines: [{ itemId: steel.id, qty: 5000, rate: 60.75 }, { itemId: wire.id, qty: 10, rate: 1150 }] });
    await api('POST', '/payments', { kind: 'payment', partyId: shree.id, accountId: acct('1010'), mode: 'bank',
      reference: 'NEFT N2026102100123', amount: billCement.total });

    const inv1 = await api('POST', '/invoices', { locationId: warehouse.id, partyId: patel.id, notes: 'Delivered to Bopal site',
      lines: [{ itemId: cement.id, qty: 150 }, { itemId: steel.id, qty: 2500, rate: 67 }] });
    const inv2 = await api('POST', '/invoices', { locationId: warehouse.id, partyId: mumbai.id,
      lines: [{ itemId: tiles.id, qty: 60, discountPct: 5 }, { itemId: paint.id, qty: 4 }] });
    await api('POST', '/invoices', { locationId: siteA.id, partyId: walkIn.id, lines: [{ itemId: bricks.id, qty: 2000 }] });
    await api('POST', '/payments', { kind: 'receipt', partyId: walkIn.id, accountId: acct('1000'), mode: 'cash', amount: 18900 });
    await api('POST', '/payments', { kind: 'receipt', partyId: patel.id, accountId: acct('1010'), mode: 'upi',
      reference: 'UPI 6021 4455 7788', amount: 150000 });

    const inv2Detail = await api('GET', `/invoices/${inv2.id}`);
    await api('POST', '/credit-notes', { invoiceId: inv2.id, reason: '3 boxes of tiles broken in transit',
      lines: [{ invoiceLineId: inv2Detail.lines[0].id, qty: 3 }] });
    void inv1;

    const t1 = await api('POST', '/transfers', { fromLocationId: warehouse.id, toLocationId: siteA.id, notes: 'For Tower 1 slab work',
      lines: [{ itemId: cement.id, qty: 100 }, { itemId: steel.id, qty: 1500 }] });
    await api('POST', `/transfers/${t1.id}/receive`);
    await api('POST', '/transfers', { fromLocationId: warehouse.id, toLocationId: siteA.id, notes: 'Finishing material',
      lines: [{ itemId: tiles.id, qty: 30 }, { itemId: paint.id, qty: 5 }] });

    await api('POST', '/expenses', { locationId: ho.id, accountId: acct('6000'), description: 'Office rent — October',
      amount: 45000, gstRate: 18, paidFromAccountId: acct('1010') });
    await api('POST', '/expenses', { locationId: siteA.id, accountId: acct('6030'), description: 'Tempo hire for material shifting',
      amount: 3500, paidFromAccountId: acct('1000') });
    await api('POST', '/expenses', { locationId: ho.id, accountId: acct('6020'), description: 'Electricity bill — September',
      amount: 8200, paidFromAccountId: acct('1010') });

    const roles = (await api('GET', '/roles')).data as { id: string; name: string }[];
    const role = (name: string) => roles.find((r) => r.name === name)!.id;
    await api('POST', '/users', { name: 'Suresh Supervisor', email: 'supervisor@demo.in', password: PASSWORD, roleId: role('Site Supervisor'), locationIds: [siteA.id] });
    await api('POST', '/users', { name: 'Anita Accountant', email: 'accountant@demo.in', password: PASSWORD, roleId: role('Accountant') });
    await api('POST', '/users', { name: 'Sameer Sales', email: 'sales@demo.in', password: PASSWORD, roleId: role('Sales Executive'), locationIds: [warehouse.id] });

    console.log(`Demo data created. Sign in with password ${PASSWORD} as:
  owner@demo.in       Owner (everything)
  accountant@demo.in  Accountant (all locations)
  sales@demo.in       Sales Executive (Central Warehouse only, no cost prices)
  supervisor@demo.in  Site Supervisor (Site A — Tower 1 only)`);
  }
} finally {
  await app.close();
  await db.destroy();
}
