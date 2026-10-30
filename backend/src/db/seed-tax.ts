import { addDays, financialYear, todayIst } from '../lib/dates.ts';

type ApiFn = (method: 'GET' | 'POST' | 'PUT' | 'PATCH', url: string, body?: unknown) => Promise<any>;

/** Self-filing demo data: constitution, fixed assets, a depreciation run, an advance-tax payment, IT block openings. */
export async function seedTax(o: { api: ApiFn }) {
  const { api } = o;
  const today = todayIst();
  const fy = financialYear(today);

  await api('PATCH', '/company', {
    constitution: 'private_company', itrForm: 'itr6',
    responsiblePerson: { name: 'Rajesh Kumar', designation: 'Director', pan: 'ABCPK1234D', mobile: '9876543210', email: 'rajesh@example.com' },
  });

  const accounts = (await api('GET', '/accounts')).data as { id: string; code: string; name: string }[];
  const bank = accounts.find((a) => a.code === '1010');
  const opening = accounts.find((a) => a.name === 'Opening Balances');
  if (!bank || !opening) return;

  const asset = (body: Record<string, unknown>) => api('POST', '/fixed-assets', body);
  const at = (days: number) => addDays(today, -days);
  await asset({
    name: 'Office building', blockCode: 'building', bookMethod: 'slm', usefulLifeYears: 30, cost: 6000000, purchaseDate: at(1000),
    putToUseDate: at(1000), sourceAccountId: opening.id, openingAccDep: 400000, supplierName: 'Prestige Estates', tagNo: 'AST-B-01',
  });
  await asset({
    name: 'Toyota Innova (MH12 AB 1234)', blockCode: 'vehicle', bookMethod: 'wdv', usefulLifeYears: 8, cost: 1850000, gstItc: 0, purchaseDate: at(400),
    putToUseDate: at(400), sourceAccountId: bank.id, supplierName: 'Toyota Dealer', serialNo: 'MBJ1234567', tagNo: 'AST-V-01', custodian: 'Director',
  });
  await asset({
    name: 'Dell laptop (accounts)', blockCode: 'computer', bookMethod: 'wdv', usefulLifeYears: 3, cost: 72000, purchaseDate: at(200),
    putToUseDate: at(200), sourceAccountId: bank.id, supplierName: 'Dell India', serialNo: 'DL-77821', tagNo: 'AST-C-01',
  });
  await asset({
    name: 'Workstation (site office)', blockCode: 'computer', bookMethod: 'wdv', usefulLifeYears: 3, cost: 95000, purchaseDate: at(20),
    putToUseDate: at(20), sourceAccountId: bank.id, supplierName: 'Dell India', serialNo: 'DL-90412', tagNo: 'AST-C-02',
  });
  await asset({
    name: 'Office furniture', blockCode: 'furniture', bookMethod: 'slm', usefulLifeYears: 10, cost: 240000, purchaseDate: at(150),
    putToUseDate: at(150), sourceAccountId: bank.id, supplierName: 'Godrej Interio', tagNo: 'AST-F-01',
  });

  // Depreciation to the end of last month.
  const toDate = addDays(`${today.slice(0, 7)}-01`, -1);
  await api('POST', '/fixed-assets/depreciation-runs', { toDate });

  // IT block openings for the first (current) year: assets bought earlier come in through these.
  await api('POST', '/fixed-assets/it-openings', { fy, blockCode: 'building', openingWdv: 5400000 });
  await api('POST', '/fixed-assets/it-openings', { fy, blockCode: 'vehicle', openingWdv: 1500000 });

  // One advance-tax instalment.
  await api('POST', '/tax/payments', {
    kind: 'advance_tax', taxYear: fy, date: addDays(today, -45), amount: 50000, bsrCode: '0510308', challanSerial: '00912', paidFromAccountId: bank.id,
  });
}
