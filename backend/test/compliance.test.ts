import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { withTenant } from '../src/db/database.ts';
import { addDays, financialYear, todayIst } from '../src/lib/dates.ts';
import { msmeInterest } from '../src/lib/msme.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => {
  env = await setupTestApp();
});
afterAll(async () => {
  await teardown(env);
});

async function business() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Shah Constructions', name: 'Meera Shah', email: uniqueEmail('owner'), password: 'Secret@123', stateCode: '24',
  });
  expect(res.status).toBe(201);
  const token = res.body.accessToken as string;
  const claims = JSON.parse(Buffer.from(token.split('.')[1]!, 'base64url').toString());
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, token, companyId);
  const ho = (await api('GET', '/locations')).body.data[0];
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; code: string; balance: number }[];
  const account = (code: string) => accounts.find((a) => a.code === code)!;
  const csv = async (url: string) => {
    const r = await env.app.inject({ method: 'GET', url: `/api/v1${url}`, headers: { authorization: `Bearer ${token}`, 'x-company-id': companyId } });
    return { status: r.statusCode, text: r.body, headers: r.headers };
  };
  const db = <T>(fn: Parameters<typeof withTenant<T>>[2]) => withTenant(env.db, claims.tid as string, fn);
  return { api, ho, account, companyId, tenantId: claims.tid as string, userId: claims.sub as string, csv, db, token };
}

async function vendor(api: ReturnType<typeof client>, name: string, extra: object = {}) {
  const r = await api('POST', '/parties', { type: 'vendor', name, stateCode: '24', ...extra });
  expect(r.status).toBe(201);
  return r.body as { id: string };
}

describe('TDS challans', () => {
  it('deposits, journals, cancels and reports warnings', async () => {
    const b = await business();
    const v = await vendor(b.api, 'Raj Labour Contractor');
    const today = todayIst();
    const fy = financialYear(today);
    const ids: string[] = [];
    await b.db(async (tx) => {
      const sec = await tx.selectFrom('tds_sections').select(['id']).where('code', '=', '194C').executeTakeFirstOrThrow();
      for (const n of [1, 2]) {
        const r = await tx.insertInto('tds_deductions').values({
          tenant_id: b.tenantId, company_id: b.companyId, source_type: 'purchase', source_id: crypto.randomUUID(), number: `PUR/T/${n}`, party_id: v.id, pan: null,
          section_id: sec.id, section_code: '194C', fy,
          deduction_date: today, gross: 50000, base: 50000, rate: 1, amount: 500 * n,
        }).returning('id').executeTakeFirstOrThrow();
        ids.push(r.id);
      }
    });
    const list = await b.api('GET', '/tds/deductions?challan=none&sectionCode=194C');
    expect(list.body.data).toHaveLength(2);

    const bankBefore = b.account('1010');
    const created = await b.api('POST', '/tds/challans', {
      depositDate: today, bsrCode: '0510308', challanSerial: '00431', paidFromAccountId: bankBefore.id, taxAmount: 1500, interest: 20, lateFee: 0, deductionIds: ids,
    });
    expect(created.status).toBe(201);
    expect(created.body).toMatchObject({ total: 1520, status: 'posted' });
    expect(created.body.number).toMatch(/^TDC/);
    const bal = async (code: string) => ((await b.api('GET', '/accounts')).body.data as any[]).find((a) => a.code === code).balance;
    expect(await bal('1010')).toBe(-1520);
    expect((await b.api('GET', '/tds/deductions?challan=none')).body.data).toHaveLength(0);

    const stmt = await b.api('GET', `/tds/statement?fy=${fy}`);
    expect(stmt.status).toBe(200);
    expect(Array.isArray(stmt.body.warnings)).toBe(true);
    expect(stmt.body.warnings.length).toBeGreaterThan(0);

    const cancel = await b.api('POST', `/tds/challans/${created.body.id}/cancel`, { reason: 'wrong bank' });
    expect(cancel.status).toBe(200);
    expect(cancel.body.status).toBe('cancelled');
    expect(await bal('1010')).toBe(0);
    expect((await b.api('GET', '/tds/deductions?challan=none')).body.data).toHaveLength(2);
  });
});

describe('GST returns', () => {
  it('builds GSTR-1 and GSTR-3B from invoices', async () => {
    const b = await business();
    const wh = (await b.api('POST', '/locations', { type: 'warehouse', name: 'Warehouse' })).body;
    const item = (await b.api('POST', '/items', { name: 'Cement', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 50 })).body;
    const sup = await vendor(b.api, 'Cement Supplier');
    await b.api('POST', '/purchases', { locationId: wh.id, partyId: sup.id, lines: [{ itemId: item.id, qty: 100, rate: 50 }] });
    const reg = (await b.api('POST', '/parties', { type: 'customer', name: 'Registered Buyer', stateCode: '27', gstin: '27AAPFU0939F1ZV' }));
    const loc = (await b.api('POST', '/parties', { type: 'customer', name: 'Local Buyer', stateCode: '24' })).body;
    const i1 = await b.api('POST', '/invoices', { locationId: wh.id, partyId: loc.id, lines: [{ itemId: item.id, qty: 10 }] });
    expect(i1.status).toBe(201);
    if (reg.status === 201) {
      const i2 = await b.api('POST', '/invoices', { locationId: wh.id, partyId: reg.body.id, lines: [{ itemId: item.id, qty: 20 }] });
      expect(i2.status).toBe(201);
    }
    const period = todayIst().slice(0, 7);
    const g1 = (await b.api('GET', `/gst/gstr1?period=${period}`)).body;
    expect(g1.b2cs[0]).toMatchObject({ rate: 18, taxable: 1000, cgst: 90, sgst: 90 });
    expect(g1.hsn[0]).toMatchObject({ hsnCode: '2523' });
    if (reg.status === 201) {
      expect(g1.b2b).toHaveLength(1);
      expect(g1.b2b[0].gstin ?? g1.b2b[0].ctin).toBe('27AAPFU0939F1ZV');
    }
    const gstn = await b.api('GET', `/gst/gstr1?period=${period}&format=gstn`);
    expect(gstn.status).toBe(200);
    const g3 = (await b.api('GET', `/gst/gstr3b?period=${period}`)).body;
    expect(JSON.stringify(g3)).toContain('"taxable":3000');
  });

  it('imports 2B and reconciles matched, mismatch and missing both ways', async () => {
    const b = await business();
    const sup = await vendor(b.api, 'ITC Supplier', { gstin: '24AAACS1234A1ZK' });
    const period = todayIst().slice(0, 7);
    const today = todayIst();
    const bill = (no: string, taxable: number) => b.db(async (tx) => {
      await tx.insertInto('purchases').values({
        tenant_id: b.tenantId, company_id: b.companyId, location_id: b.ho.id, party_id: sup.id, number: `PUR/T/${no}`, supplier_invoice_no: no, supplier_invoice_date: today,
        fy: '2026-27', bill_date: today, due_date: addDays(today, 30), place_of_supply: '24', supply_type: 'intra', subtotal: taxable, cgst: taxable * 0.09, sgst: taxable * 0.09, igst: 0,
        round_off: 0, total: taxable * 1.18, created_by: b.userId,
      }).execute();
    });
    await bill('INV-001', 1000);
    await bill('INV-002', 2000);
    await bill('INV-003', 3000);
    const csv = ['gstin,docType,docNo,docDate,taxable,igst,cgst,sgst',
      `24AAACS1234A1ZK,invoice,INV-001,${today.split('-').reverse().join('/')},1000,0,90,90`,
      `24AAACS1234A1ZK,invoice,INV-002,${today.split('-').reverse().join('/')},2500,0,225,225`,
      `24AAACS1234A1ZK,invoice,INV-099,${today.split('-').reverse().join('/')},500,0,45,45`].join('\n');
    const imp = await b.api('POST', '/gst/2b-imports', { period, csv });
    expect(imp.status).toBe(201);
    expect(imp.body).toMatchObject({ lines: 3, matched: 1, mismatch: 1, missingInBooks: 1 });
    const recon = (await b.api('GET', `/gst/2b-recon?period=${period}`)).body;
    expect(recon.summary).toMatchObject({ matched: 1, mismatch: 1, missingInBooks: 1, missingIn2b: 1 });
    expect(recon.rows.map((r: any) => r.status).sort()).toEqual(['matched', 'mismatch', 'missing_in_2b', 'missing_in_books']);
    const only = (await b.api('GET', `/gst/2b-recon?period=${period}&status=missing_in_2b`)).body;
    expect(only.rows).toHaveLength(1);
  });
});

describe('bank reconciliation', () => {
  it('imports, auto-matches and creates an entry', async () => {
    const b = await business();
    const bank = b.account('1010');
    const charges = b.account('6070');
    const today = todayIst();
    const dmy = today.split('-').reverse().join('/');
    // Two journal lines on the bank account via a transfer-like direct receipt.
    const cust = (await b.api('POST', '/parties', { type: 'customer', name: 'Payer', stateCode: '24' })).body;
    const rc = await b.api('POST', '/payments', { kind: 'receipt', partyId: cust.id, accountId: bank.id, mode: 'bank', amount: 5000, reference: 'UTR123456789012' });
    expect(rc.status).toBe(201);
    const csv = ['Date,Narration,Chq/Ref No,Withdrawal Amt.,Deposit Amt.', `${dmy},NEFT from payer,UTR123456789012,,5000.00`, `${dmy},SMS charges,,59.00,`, `${dmy},Unknown,,,777.00`].join('\n');
    const imp = await b.api('POST', '/bank-statements', { accountId: bank.id, csv });
    expect(imp.status).toBe(201);
    expect(imp.body).toMatchObject({ lines: 3, matched: 1, unmatched: 2 });
    const dup = await b.api('POST', '/bank-statements', { accountId: bank.id, csv });
    expect(dup.status).toBe(201);
    expect(dup.body.lines).toBe(0);
    const det = (await b.api('GET', `/bank-statements/${imp.body.id}`)).body;
    const charge = det.lines.find((l: any) => l.withdrawal === 59);
    const made = await b.api('POST', `/bank-lines/${charge.id}/create-entry`, { accountId: charges.id });
    expect(made.status).toBe(200);
    const after = (await b.api('GET', `/bank-statements/${imp.body.id}`)).body;
    expect(after.lines.find((l: any) => l.id === charge.id).status).toBe('matched');
    expect(((await b.api('GET', '/accounts')).body.data as any[]).find((a) => a.code === '6070').balance).toBe(59);
    const unk = det.lines.find((l: any) => l.deposit === 777);
    expect((await b.api('POST', `/bank-lines/${unk.id}/ignore`)).status).toBe(200);
  });
});

describe('compliance docs, alerts, health, export', () => {
  it('derives status, raises alerts and reports setup health', async () => {
    const b = await business();
    const today = todayIst();
    const mk = (name: string, days: number) => b.api('POST', '/compliance-docs', { name, category: 'licence', expiryDate: addDays(today, days), remindDays: 30 });
    expect((await mk('Soon', 20)).body).toMatchObject({ status: 'expiring', daysLeft: 20 });
    expect((await mk('Gone', -5)).body.status).toBe('expired');
    expect((await mk('Fine', 200)).body.status).toBe('valid');
    expect((await b.api('GET', '/compliance-docs?status=expired')).body.data).toHaveLength(1);
    const alerts = (await b.api('GET', '/compliance/alerts')).body.data as any[];
    expect(alerts.filter((a) => a.kind === 'doc_expiry')).toHaveLength(2);
    const health = (await b.api('GET', '/setup/health')).body;
    expect(typeof health.score).toBe('number');
    expect(health.checks.find((c: any) => c.key === 'gstin')).toMatchObject({ ok: false });
    expect(health.checks.find((c: any) => c.key === 'expired_docs').ok).toBe(false);
  });

  it('exports CSV with a header row', async () => {
    const b = await business();
    await vendor(b.api, 'Export, Vendor');
    const r = await b.csv('/export/parties');
    expect(r.status).toBe(200);
    expect(String(r.headers['content-type'])).toContain('text/csv');
    expect(r.text.split('\r\n')[0]).toBe('type,name,gstin,pan,state_code,phone,email,address,pincode,credit_limit,credit_days,udyam_no,msme_category,tds_section');
    expect(r.text).toContain('"Export, Vendor"');
    expect((await b.csv('/export/nope')).status).toBe(404);
  });
});

describe('MSME interest', () => {
  it('lists overdue micro supplier bills on /reports/msme-dues', async () => {
    const b = await business();
    await b.api('PATCH', '/company', { msmeBankRate: 6.5 });
    const sup = await vendor(b.api, 'Micro Supplier', { udyamNo: 'UDYAM-GJ-01-0001234', msmeCategory: 'micro', creditDays: 30 });
    const bill = addDays(todayIst(), -60);
    await b.db(async (tx) => {
      await tx.insertInto('purchases').values({
        tenant_id: b.tenantId, company_id: b.companyId, location_id: b.ho.id, party_id: sup.id, number: 'PUR/T/MSME', supplier_invoice_no: 'M-1', supplier_invoice_date: bill,
        fy: financialYear(bill), bill_date: bill, due_date: addDays(bill, 30), msme_due_date: addDays(bill, 30), place_of_supply: '24', supply_type: 'intra',
        subtotal: 10000, cgst: 900, sgst: 900, igst: 0, round_off: 0, total: 11800, created_by: b.userId,
      }).execute();
    });
    const r = await b.api('GET', '/reports/msme-dues');
    expect(r.status).toBe(200);
    expect(r.body.bankRate).toBe(6.5);
    const row = r.body.rows.find((x: { number: string }) => x.number === 'PUR/T/MSME');
    expect(row).toMatchObject({ msmeDueDate: addDays(bill, 30), unpaid: 11800, daysOverdue: 30 });
    expect(row.interest).toBeGreaterThan(0);
  });

  it('is zero before the due date and compounds monthly after it', () => {
    expect(msmeInterest(100000, '2026-06-30', '2026-06-30', 6.5)).toBe(0);
    expect(msmeInterest(100000, '2026-06-30', '2026-07-30', null)).toBeNull();
    // one full month at 3 x 6.5% / 12 = 1.625%
    expect(msmeInterest(100000, '2026-06-30', '2026-07-30', 6.5)).toBeCloseTo(1625, 0);
    // two months compound on the grown balance
    expect(msmeInterest(100000, '2026-06-30', '2026-08-30', 6.5)).toBeCloseTo(100000 * (1.01625 ** 2 - 1), 0);
  });
});
