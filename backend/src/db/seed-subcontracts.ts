// Demo subcontract data (v1.3), created through the real API handlers by seed.ts.
import { addDays, todayIst } from '../lib/dates.ts';

type Call = (method: 'GET' | 'POST' | 'PUT' | 'PATCH', url: string, body?: unknown) => Promise<any>;

export interface SubcontractSeedDeps {
  api: Call;
  pm: Call;
  projectId: string;
  boqLine: (code: string) => string;
  acct: (code: string) => string;
}

/** One subcontractor, a work order with a mobilisation advance, RA bill 1 paid, RA bill 2 approved, RA bill 3 draft. */
export async function seedSubcontracts({ api, pm, projectId, boqLine, acct }: SubcontractSeedDeps): Promise<void> {
  const daysAgo = (n: number) => addDays(todayIst(), -n);
  const sections = (await api('GET', '/tds-sections')).data as { id: string; code: string }[];
  const subcon = await api('POST', '/parties', {
    type: 'vendor', name: 'Shree Constructions (Subcon)', stateCode: '24', phone: '9898000077', creditDays: 15, pan: 'AAKFS1234C',
    tdsSectionId: sections.find((x) => x.code === '194C')!.id,
  });
  const wo = await pm('POST', '/work-orders', {
    projectId, contractorPartyId: subcon.id, date: daysAgo(40), title: 'Structural and finishing labour — Tower 1',
    scope: 'Labour-and-shuttering contract for RCC, brickwork and plaster. Material by the company.',
    retentionPct: 5, advanceRecoveryPct: 10, tdsPct: 2, gstPct: 18, itcEligible: true, activate: true,
    lines: [
      { boqLineId: boqLine('3.1'), description: 'RCC labour with shuttering', unit: 'm3', qty: 100, rate: 2500 },
      { boqLineId: boqLine('4.1'), description: 'Brickwork 230 mm labour', unit: 'm3', qty: 80, rate: 900 },
      { boqLineId: boqLine('5.1'), description: 'Internal plaster labour', unit: 'm2', qty: 1000, rate: 85 },
    ],
  });
  const lineIds = (wo.lines as { id: string }[]).map((l) => l.id);
  await pm('POST', `/work-orders/${wo.id}/advances`, {
    date: daysAgo(35), amount: 50000, paidFromAccountId: acct('1010'), notes: 'Mobilisation advance',
  });
  const bill = (date: string, cum: number[], extra: Record<string, unknown> = {}) => pm('POST', '/ra-bills', {
    workOrderId: wo.id, date, lines: lineIds.map((id, i) => ({ workOrderLineId: id, cumQty: cum[i] })), ...extra,
  });

  const ra1 = await bill(daysAgo(25), [30, 20, 200], { periodFrom: daysAgo(40), periodTo: daysAgo(26), submit: true });
  await pm('POST', `/ra-bills/${ra1.id}/approve`);
  await api('POST', '/payments', {
    kind: 'payment', partyId: subcon.id, accountId: acct('1010'), mode: 'bank', reference: 'NEFT N2026101500456',
    amount: ra1.netPayable, notes: `Against ${ra1.number}`,
  });

  const ra2 = await bill(daysAgo(10), [60, 45, 500], { periodFrom: daysAgo(25), periodTo: daysAgo(11), submit: true });
  await pm('POST', `/ra-bills/${ra2.id}/approve`);

  await bill(todayIst(), [80, 60, 700], { periodFrom: daysAgo(10), periodTo: todayIst(), notes: 'Draft for the month end' });
}
