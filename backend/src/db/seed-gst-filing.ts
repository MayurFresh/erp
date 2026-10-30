import { addDays, todayIst } from '../lib/dates.ts';
import { addPeriodMonths } from '../lib/due-dates.ts';

type ApiFn = (method: 'GET' | 'POST' | 'PUT' | 'PATCH', url: string, body?: unknown) => Promise<any>;

/** Self-filing demo data: a credit-ledger snapshot, a PMT-06 payment, and GSTR-1 and GSTR-3B filed for the period before last. */
export async function seedGstFiling(o: { api: ApiFn }) {
  const { api } = o;
  const today = todayIst();
  const period = addPeriodMonths(today.slice(0, 7), -2);
  const filedOn = addDays(`${period}-01`, 40) > today ? today : addDays(`${period}-01`, 40);

  await api('POST', '/gst/ledger-balances', { ledger: 'credit', asOf: `${period}-01`, igst: 0, cgst: 5000, sgst: 5000, note: 'Opening balance from the GST portal' });

  const accounts = (await api('GET', '/accounts')).data as { id: string; code: string }[];
  const bank = accounts.find((a) => a.code === '1010');
  if (!bank) return;
  const so = await api('GET', `/gst/setoff?period=${period}`);
  const need = so.cash;
  if (need.total > 0) {
    await api('POST', '/gst/payments', {
      date: filedOn, period, cin: 'DEMO0001', paidFromAccountId: bank.id,
      igst: need.tax.igst, cgst: need.tax.cgst, sgst: need.tax.sgst, cess: need.tax.cess, interest: need.interest, lateFee: need.lateFee,
    });
  }
  await api('POST', '/filings', { returnType: 'gstr1', period, filedOn, arn: 'DEMO-GSTR1-0001', acknowledgeFailures: true });
  const body = { returnType: 'gstr3b', period, filedOn, arn: 'DEMO-GSTR3B-0001', acknowledgeFailures: true };
  // A cash shortfall (e.g. a changed demo invoice mix) still records the return, just without the set-off journal.
  await api('POST', '/filings', { ...body, postSetoff: true }).catch(() => api('POST', '/filings', body));
}
