// Demo data for local development: `npm run db:seed`.
// Goes through the real API handlers, so seeded data obeys every business rule.
import { buildApp } from '../app.ts';
import { loadConfig } from '../config.ts';
import { addDays, todayIst } from '../lib/dates.ts';
import { createDb } from './database.ts';
import { seedCompliance } from './seed-compliance.ts';
import { seedGstFiling } from './seed-gst-filing.ts';
import { seedTax } from './seed-tax.ts';
import { seedRealEstate } from './seed-realestate.ts';
import { seedSubcontracts } from './seed-subcontracts.ts';

const PASSWORD = 'Demo@1234';
const config = loadConfig();
const db = createDb(config.DATABASE_URL, 2);
const app = await buildApp({ config, db, logger: false, authRateLimit: false });

type Method = 'GET' | 'POST' | 'PUT' | 'PATCH';
const daysAgo = (n: number) => addDays(todayIst(), -n);

async function call(method: Method, url: string, body?: unknown, token?: string, companyId?: string) {
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
    const api = (method: Method, url: string, body?: unknown) => call(method, url, body, token, companyId);
    const as = async (email: string) => {
      const session = await call('POST', '/auth/login', { email, password: PASSWORD });
      return (method: Method, url: string, body?: unknown) => call(method, url, body, session.accessToken, companyId);
    };

    await api('PATCH', '/company', {
      legalName: 'Demo Builders & Traders Private Limited', address: '402, Shilp Square, SG Highway, Ahmedabad, Gujarat 380054',
      phone: '079-4000-1234', email: 'accounts@demobuilders.in', website: 'www.demobuilders.in',
      bankName: 'HDFC Bank, SG Highway', bankAccountNo: '50200012345678', bankIfsc: 'HDFC0001234', upiId: 'demobuilders@hdfcbank',
      invoiceTerms: '1. Goods once sold will not be taken back.\n2. Interest at 18% p.a. on payments after the due date.\n3. Subject to Ahmedabad jurisdiction.',
      invoiceFooter: 'Thank you for your business!',
      tan: 'MUMP12345E', msmeBankRate: 6.25,
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

    const roles = (await api('GET', '/roles')).data as { id: string; name: string }[];
    const role = (name: string) => roles.find((r) => r.name === name)!.id;
    await api('POST', '/users', { name: 'Suresh Supervisor', email: 'supervisor@demo.in', password: PASSWORD, roleId: role('Site Supervisor'), locationIds: [siteA.id] });
    await api('POST', '/users', { name: 'Anita Accountant', email: 'accountant@demo.in', password: PASSWORD, roleId: role('Accountant') });
    await api('POST', '/users', { name: 'Sameer Sales', email: 'sales@demo.in', password: PASSWORD, roleId: role('Sales Executive'), locationIds: [warehouse.id] });
    const pmUser = await api('POST', '/users', { name: 'Priya PM', email: 'pm@demo.in', password: PASSWORD, roleId: role('Project Manager') });
    const supervisor = await as('supervisor@demo.in');
    const pm = await as('pm@demo.in');

    // Construction: project, BOQ and an indent that the warehouse transfer below fulfils.
    const project = await api('POST', '/projects', {
      code: 'PRJ-T1', name: 'Tower 1 — Residential (G+12)', clientPartyId: patel.id, managerUserId: pmUser.id, status: 'active',
      startDate: daysAgo(45), endDate: addDays(todayIst(), 500), contractValue: 125000000,
      address: 'Plot 14, SG Highway, Ahmedabad', siteIds: [siteA.id],
    });
    const boq = (await api('POST', `/projects/${project.id}/boq`, { lines: [
      { code: '1.1', description: 'Earthwork excavation in foundations', unit: 'm3', qty: 850, rate: 280, labourBudget: 180000, otherBudget: 40000 },
      { code: '2.1', description: 'PCC M10 below footings', unit: 'm3', qty: 65, rate: 5200, materialBudget: 260000, labourBudget: 60000 },
      { code: '3.1', description: 'RCC M25 in footings and columns', unit: 'm3', qty: 420, rate: 9800, materialBudget: 3200000, labourBudget: 620000, otherBudget: 150000 },
      { code: '3.2', description: 'Reinforcement steel Fe500D', unit: 'kg', qty: 52000, rate: 78, materialBudget: 3500000, labourBudget: 420000 },
      { code: '4.1', description: 'Brickwork 230 mm in CM 1:6', unit: 'm3', qty: 380, rate: 6200, materialBudget: 1700000, labourBudget: 520000 },
      { code: '5.1', description: 'Internal plaster 12 mm in CM 1:4', unit: 'm2', qty: 6400, rate: 340, materialBudget: 1050000, labourBudget: 900000 },
      { code: '6.1', description: 'Vitrified tile flooring 600×600', unit: 'm2', qty: 3100, rate: 1450, materialBudget: 3600000, labourBudget: 650000 },
      { code: '7.1', description: 'Interior emulsion paint, two coats', unit: 'm2', qty: 9800, rate: 165, materialBudget: 980000, labourBudget: 620000 },
    ] })).data as { id: string; code: string }[];
    const boqLine = (code: string) => boq.find((l) => l.code === code)!.id;
    const indent = await supervisor('POST', '/indents', { locationId: siteA.id, requiredBy: todayIst(), submit: true,
      notes: 'Footing and column concreting, grid A–C', lines: [
        { itemId: cement.id, qty: 100, boqLineId: boqLine('3.1') }, { itemId: steel.id, qty: 1500, boqLineId: boqLine('3.2') }] });
    await pm('POST', `/indents/${indent.id}/approve`, {});

    const t1 = await api('POST', '/transfers', { fromLocationId: warehouse.id, toLocationId: siteA.id, notes: 'For Tower 1 slab work',
      indentId: indent.id, lines: [{ itemId: cement.id, qty: 100 }, { itemId: steel.id, qty: 1500 }] });
    await api('POST', `/transfers/${t1.id}/receive`);
    await api('POST', '/transfers', { fromLocationId: warehouse.id, toLocationId: siteA.id, notes: 'Finishing material',
      lines: [{ itemId: tiles.id, qty: 30 }, { itemId: paint.id, qty: 5 }] });

    await api('POST', '/expenses', { locationId: ho.id, accountId: acct('6000'), description: 'Office rent — October',
      amount: 45000, gstRate: 18, paidFromAccountId: acct('1010') });
    await api('POST', '/expenses', { locationId: siteA.id, accountId: acct('6030'), description: 'Tempo hire for material shifting',
      amount: 3500, paidFromAccountId: acct('1000') });
    await api('POST', '/expenses', { locationId: ho.id, accountId: acct('6020'), description: 'Electricity bill — September',
      amount: 8200, paidFromAccountId: acct('1010') });

    // Statutory demo data (v1.4): TDS on professional fees, an MSME vendor past its due date, an RCM freight expense.
    const sections = (await api('GET', '/tds-sections')).data as { id: string; code: string }[];
    const section = (code: string) => sections.find((x) => x.code === code)!.id;
    const mehta = await api('POST', '/parties', { type: 'vendor', name: 'Mehta & Associates (CA)', stateCode: '24', pan: 'AAAPM1234C',
      phone: '9898000066', tdsSectionId: section('194J(a)') });
    await api('POST', '/expenses', { locationId: ho.id, accountId: acct('6060'), partyId: mehta.id, description: 'Statutory audit and tax filing fees',
      amount: 60000, paidFromAccountId: acct('1010') });
    const microVendor = await api('POST', '/parties', { type: 'vendor', name: 'Bhavani Bricks (Micro)', stateCode: '24', gstin: '24AAGFB4321K1Z3',
      phone: '9898000088', creditDays: 30, udyamNo: 'UDYAM-GJ-01-0001234', msmeCategory: 'micro' });
    await api('POST', '/purchases', { locationId: siteA.id, partyId: microVendor.id, billDate: daysAgo(50), supplierInvoiceNo: 'BB/0412',
      lines: [{ itemId: bricks.id, qty: 10000, rate: 7 }] });
    const transporter = await api('POST', '/parties', { type: 'vendor', name: 'Kathiawad Roadways (GTA)', stateCode: '24', phone: '9898000099' });
    await api('POST', '/expenses', { locationId: warehouse.id, accountId: acct('6030'), partyId: transporter.id, description: 'GTA freight — cement from Kutch',
      amount: 20000, gstRate: 5, reverseCharge: true, paidFromAccountId: acct('1010') });
    await api('POST', '/payments', { kind: 'receipt', partyId: patel.id, accountId: acct('1010'), mode: 'bank', reference: 'NEFT N2026102200987',
      amount: 49000, tdsAmount: 1000, notes: 'TDS of ₹1,000 deducted by the customer' });

    // Material issued to work, DPRs, workers, a week of attendance and a paid wage sheet.
    await supervisor('POST', '/issues', { locationId: siteA.id, boqLineId: boqLine('3.1'), notes: 'Columns C1–C12, ground floor',
      lines: [{ itemId: cement.id, qty: 40 }, { itemId: steel.id, qty: 600 }] });

    const approvedDpr = await supervisor('POST', '/dprs', {
      locationId: siteA.id, date: daysAgo(2), weather: 'Sunny', submit: true,
      summary: 'Excavation for grid D–F completed; PCC laid below footings F1–F6.',
      workDone: [
        { boqLineId: boqLine('1.1'), description: 'Excavation, grid D–F', qty: 120 },
        { boqLineId: boqLine('2.1'), description: 'PCC below footings F1–F6', qty: 8 },
      ],
      labour: [{ trade: 'mason', count: 6 }, { trade: 'helper', count: 14 }], equipment: [{ name: 'JCB 3DX', hours: 7 }],
    });
    await pm('POST', `/dprs/${approvedDpr.id}/approve`);
    await supervisor('POST', '/dprs', {
      locationId: siteA.id, date: daysAgo(1), weather: 'Cloudy, light drizzle after 4 pm', submit: true,
      summary: 'Column reinforcement and concreting for C1–C12.', hindrances: 'Concrete pump arrived two hours late.',
      workDone: [
        { boqLineId: boqLine('3.1'), description: 'Column concreting C1–C12', qty: 14 },
        { boqLineId: boqLine('3.2'), description: 'Column reinforcement C1–C12', qty: 1800 },
      ],
      labour: [{ trade: 'mason', count: 8 }, { trade: 'bar_bender', count: 5 }, { trade: 'helper', count: 16 }],
      equipment: [{ name: 'Concrete pump', hours: 5 }, { name: 'Needle vibrator', hours: 6 }],
    });

    const ramesh = await api('POST', '/parties', { type: 'vendor', name: 'Ramesh Labour Contractors', stateCode: '24', phone: '9898000055' });
    const workerSpecs: [string, string, string, number, boolean][] = [
      ['Raju Parmar', 'mason', 'skilled', 900, true], ['Shankar Rathod', 'mason', 'skilled', 850, true],
      ['Kailash Meena', 'bar_bender', 'semi_skilled', 750, true], ['Imran Shaikh', 'carpenter', 'skilled', 850, false],
      ['Lakshmi Vasava', 'helper', 'unskilled', 550, true], ['Mohan Bhil', 'helper', 'unskilled', 550, false],
      ['Prakash Solanki', 'electrician', 'skilled', 900, false], ['Deepak Thakor', 'operator', 'semi_skilled', 800, false],
    ];
    const workers: { id: string }[] = [];
    for (const [i, [name, trade, skill, dailyRate, viaContractor]] of workerSpecs.entries()) {
      workers.push(await pm('POST', '/workers', {
        name, trade, skill, dailyRate, siteId: siteA.id, contractorPartyId: viaContractor ? ramesh.id : null,
        phone: `98250${String(10000 + i * 137).padStart(5, '0')}`, aadhaarLast4: String(4100 + i * 11), joinedOn: daysAgo(40),
      }));
    }
    for (let day = 7; day >= 1; day--) {
      await supervisor('PUT', '/attendance', { siteId: siteA.id, date: daysAgo(day), entries: workers.map((w, j) => {
        const status = (day + j) % 7 === 0 ? 'absent' : (day + 2 * j) % 5 === 0 ? 'half_day' : 'present';
        return { workerId: w.id, status, otHours: status === 'present' && j < 3 && day % 3 === 1 ? 2 : 0 };
      }) });
    }
    await api('POST', '/labour-advances', { workerId: workers[0]!.id, date: daysAgo(4), amount: 4000,
      paidFromAccountId: acct('1000'), notes: 'Advance to Raju Parmar (mason)' });
    const sheet = await pm('POST', '/wage-sheets', { siteId: siteA.id, from: daysAgo(7), to: daysAgo(1) });
    await pm('PATCH', `/wage-sheets/${sheet.id}`, { rows: [{ workerId: workers[0]!.id, advance: 2000 }] });
    await pm('POST', `/wage-sheets/${sheet.id}/approve`);
    await api('POST', `/wage-sheets/${sheet.id}/pay`, { paidFromAccountId: acct('1000') });
    // A second advance after the sheet was paid stays fully open; Raju's first one is partly recovered (2,000 of 4,000).
    await api('POST', '/labour-advances', { workerId: workers[1]!.id, amount: 1500,
      paidFromAccountId: acct('1000'), notes: 'Advance for family travel' });

    await seedSubcontracts({ api, pm, projectId: project.id, boqLine, acct });
    await seedRealEstate({ api, acct, patelId: patel.id, mumbaiId: mumbai.id, invoiceId: inv1.id });
    await seedCompliance({ api });
    await seedGstFiling({ api });
    await seedTax({ api });

    // Last of all: lock the books up to the last 31 March on or before (today - 1 year). Nothing seeded falls inside it.
    const lockBase = addDays(todayIst(), -365);
    const lockYear = lockBase >= `${lockBase.slice(0, 4)}-03-31` ? lockBase.slice(0, 4) : String(Number(lockBase.slice(0, 4)) - 1);
    await api('PATCH', '/company', { booksLockedUntil: `${lockYear}-03-31` });

    console.log(`Demo data created. Sign in with password ${PASSWORD} as:
  owner@demo.in       Owner (everything)
  accountant@demo.in  Accountant (all locations)
  sales@demo.in       Sales Executive (Central Warehouse and Site R1, no cost prices)
  supervisor@demo.in  Site Supervisor (Site A — Tower 1 only)
  pm@demo.in          Project Manager (all locations)`);
  }
} finally {
  await app.close();
  await db.destroy();
}
