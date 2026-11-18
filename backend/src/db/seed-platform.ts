import { addDays, todayIst } from '../lib/dates.ts';

type ApiFn = (method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE', url: string, body?: unknown) => Promise<any>;

/** Enterprise platform demo data: a second company with one inter-company entry. 2FA stays off for every demo user. */
export async function seedPlatform(o: { api: ApiFn; as: (email: string) => Promise<ApiFn>; apiFor?: (companyId: string) => ApiFn }) {
  const { api, apiFor } = o;
  if (!apiFor) return;
  const existing = (await api('GET', '/companies')).data as { id: string; name: string }[];
  const name = 'OneMatrix Infra Projects LLP';
  const second = existing.find((c) => c.name === name)
    ?? await api('POST', '/companies', { name, legalName: name, stateCode: '24' });

  const mine = (await api('GET', '/accounts')).data as { id: string; code: string; name: string; type: string }[];
  const theirs = (await apiFor(second.id)('GET', '/accounts')).data as { id: string; code: string; name: string; type: string }[];
  const bank = mine.find((a) => a.code === '1010');
  const rent = theirs.find((a) => a.type === 'expense' && /rent/i.test(a.name)) ?? theirs.find((a) => a.type === 'expense');
  if (!bank || !rent) return;

  const have = (await api('GET', '/intercompany-entries')) as { total: number };
  if (have.total > 0) return;
  await api('POST', '/intercompany-entries', {
    date: addDays(todayIst(), -10), amount: 25000, narration: 'Office rent paid on behalf of OneMatrix Infra Projects LLP',
    from: { companyId: (await api('GET', '/company')).id, accountId: bank.id },
    to: { companyId: second.id, accountId: rent.id },
  });
}
