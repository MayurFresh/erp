import { addDays, todayIst } from '../lib/dates.ts';

type ApiFn = (method: 'GET' | 'POST' | 'PUT' | 'PATCH', url: string, body?: unknown) => Promise<any>;

const ddmmyyyy = (d: string) => `${d.slice(8, 10)}/${d.slice(5, 7)}/${d.slice(0, 4)}`;

/** Compliance demo data: a TDS challan, three documents and a bank statement with every kind of line. */
export async function seedCompliance(o: { api: ApiFn }) {
  const { api } = o;
  const today = todayIst();

  // 1. Deposit the pending 194C deductions.
  const pending = (await api('GET', '/tds/deductions?challan=none&sectionCode=194C')).data as { id: string; amount: number }[];
  if (pending.length) {
    const accounts = (await api('GET', '/accounts')).data as { id: string; code: string }[];
    const bank = accounts.find((a) => a.code === '1010');
    if (bank) {
      const tax = pending.reduce((s, d) => s + d.amount, 0);
      await api('POST', '/tds/challans', {
        depositDate: today, bsrCode: '0510308', challanSerial: '00431', paidFromAccountId: bank.id,
        taxAmount: Math.round(tax * 100) / 100, interest: 0, lateFee: 0, deductionIds: pending.map((d) => d.id),
      });
    }
  }

  // 2. Licences and registrations in each state.
  await api('POST', '/compliance-docs', { name: 'Shops and Establishment Licence', category: 'licence', docNo: 'SE/2024/118', issuedBy: 'Municipal Corporation', expiryDate: addDays(today, 20), remindDays: 30 });
  await api('POST', '/compliance-docs', { name: 'Fire NOC', category: 'certificate', docNo: 'FIRE/55/2023', issuedBy: 'Fire Department', expiryDate: addDays(today, -15), remindDays: 30 });
  await api('POST', '/compliance-docs', { name: 'Contractor Licence', category: 'licence', docNo: 'CL-7781', issuedBy: 'Labour Department', expiryDate: addDays(today, 400), remindDays: 30 });

  // 3. Bank statement built from the ledger so three lines auto-match.
  const accounts = (await api('GET', '/accounts')).data as { id: string; code: string }[];
  const bank = accounts.find((a) => a.code === '1010');
  const charges = accounts.find((a) => a.code === '6070');
  if (!bank || !charges) return;
  const led = (await api('GET', `/accounts/${bank.id}/ledger`)).lines as { date: string; debit: number; credit: number; number: string }[];
  const real = led.filter((l) => l.debit > 0 || l.credit > 0).slice(0, 3);
  if (real.length < 3) return;
  const rows = real.map((l) => `${ddmmyyyy(l.date)},${l.number},${l.credit || ''},${l.debit || ''}`);
  rows.push(`${ddmmyyyy(today)},Bank charges,177.00,`, `${ddmmyyyy(today)},Unknown NEFT,,4321.00`);
  const csv = ['Date,Narration,Withdrawal Amt.,Deposit Amt.', ...rows].join('\n');
  const imp = await api('POST', '/bank-statements', { accountId: bank.id, fileName: 'demo-statement.csv', csv });
  await api('POST', `/bank-statements/${imp.id}/auto-match`);
  const detail = await api('GET', `/bank-statements/${imp.id}`);
  const charge = (detail.lines as { id: string; status: string; withdrawal: number }[]).find((l) => l.status === 'unmatched' && l.withdrawal === 177);
  if (charge) await api('POST', `/bank-lines/${charge.id}/create-entry`, { accountId: charges.id, narration: 'Bank charges' });
}
