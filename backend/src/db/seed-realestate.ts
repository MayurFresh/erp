// Demo real-estate and e-invoice data (v1.3), created through the real API handlers by seed.ts.
import { addDays, todayIst } from '../lib/dates.ts';

type Call = (method: 'GET' | 'POST' | 'PUT' | 'PATCH', url: string, body?: unknown) => Promise<any>;

export interface RealEstateSeedDeps {
  api: Call;
  acct: (code: string) => string;
  /** Existing demo parties and invoice that get PAN, pincode and the sandbox IRN. */
  patelId: string;
  mumbaiId: string;
  invoiceId: string;
}

export async function seedRealEstate({ api, acct, patelId, mumbaiId, invoiceId }: RealEstateSeedDeps): Promise<void> {
  const daysAgo = (n: number) => addDays(todayIst(), -n);

  // E-invoice prerequisites: company and party pincodes and PAN.
  await api('PATCH', '/company', { pincode: '380054', einvoiceEnabled: true, einvoiceMode: 'sandbox' });
  await api('PATCH', `/parties/${patelId}`, { pan: 'AABCP1234C', pincode: '380015' });
  await api('PATCH', `/parties/${mumbaiId}`, { pan: 'AAPFU0939F', pincode: '400069' });

  const site = await api('POST', '/locations', { type: 'site', name: 'Site R1 — Progen Heights', code: 'SR1', address: 'Bopal, Ahmedabad' });
  // The sales executive sells flats at this site, so the project's units and bookings must be in their scope.
  const sales = (await api('GET', '/users?q=sales@demo.in')).data[0];
  const salesLocations: string[] = sales.assignments[0].locationIds ?? [];
  await api('PATCH', `/users/${sales.id}`, { locationIds: [...salesLocations, site.id] });
  const reraAccount = await api('POST', '/accounts', { name: 'RERA Collection A/c — Progen Heights', type: 'asset', subtype: 'bank' });
  const project = await api('POST', '/projects', {
    code: 'PRJ-R1', name: 'Progen Heights', status: 'active', startDate: daysAgo(90), endDate: addDays(todayIst(), 700),
    address: 'Bopal, Ahmedabad', siteIds: [site.id], reraRegNo: 'PR/GJ/AHMEDABAD/AHMEDABAD CITY/AUDA/RAA00000/010000', reraAccountId: reraAccount.id,
  });

  const specs: { code: string; wing: string; floor: number; unitType: string; carpetArea: number; listPrice: number }[] = [];
  for (const wing of ['A', 'B']) {
    for (let floor = 1; floor <= 3; floor++) {
      for (let n = 1; n <= 2; n++) {
        const threeBhk = n === 2;
        specs.push({
          code: `${wing}-${floor}0${n}`, wing, floor, unitType: threeBhk ? '3 BHK' : '2 BHK',
          carpetArea: threeBhk ? 1180 : 860, listPrice: (threeBhk ? 8200000 : 5800000) + floor * 50000,
        });
      }
    }
  }
  const units = (await api('POST', '/units', { projectId: project.id, units: specs })).data as { id: string; code: string }[];
  const unit = (code: string) => units.find((u) => u.code === code)!.id;

  const plan = await api('POST', '/payment-plans', { projectId: project.id, name: 'Construction-linked', stages: [
    { name: 'Booking amount', pct: 10 }, { name: 'On agreement', pct: 20 }, { name: 'Plinth completed', pct: 15 },
    { name: 'Slab 3 completed', pct: 15 }, { name: 'Brickwork completed', pct: 15 }, { name: 'Plastering completed', pct: 15 },
    { name: 'On possession', pct: 10 },
  ] });

  const buyer = (name: string, pan: string, pincode: string, phone: string) =>
    api('POST', '/parties', { type: 'customer', name, pan, pincode, stateCode: '24', phone });
  const mehta = await buyer('Rohan Mehta', 'AKJPM4521L', '380054', '9825010001');
  const shah = await buyer('Kavita Shah', 'BQRPS7788K', '380015', '9825010002');
  const desai = await buyer('Nilesh Desai', 'CTMPD1290R', '380059', '9825010003');

  // Booking 1: at agreement, 3 demands, part receipt.
  const b1 = await api('POST', '/bookings', { unitId: unit('A-201'), customerPartyId: mehta.id, date: daysAgo(60), paymentPlanId: plan.id, notes: 'Corner unit, east facing' });
  const d1 = await api('POST', `/bookings/${b1.id}/demands`, { stageIds: [b1.stages[0].id], date: daysAgo(60), dueDate: daysAgo(53) });
  await api('POST', `/bookings/${b1.id}/agreement`, { agreementNo: 'AFS/PH/A-201/2026', agreementDate: daysAgo(45) });
  await api('POST', `/bookings/${b1.id}/demands`, { stageIds: [b1.stages[1].id], date: daysAgo(45), dueDate: daysAgo(38) });
  await api('POST', `/bookings/${b1.id}/demands`, { stageIds: [b1.stages[2].id], date: daysAgo(10), dueDate: addDays(todayIst(), 5) });
  void d1;
  await api('POST', '/payments', { kind: 'receipt', partyId: mehta.id, accountId: acct('1010'), mode: 'bank', date: daysAgo(40),
    reference: 'RTGS R2026091200456', amount: 2500000, notes: 'Booking and agreement instalments' });

  // Booking 2: booked, with the booking-amount demand only.
  const b2 = await api('POST', '/bookings', { unitId: unit('B-102'), customerPartyId: shah.id, date: daysAgo(12), paymentPlanId: plan.id });
  await api('POST', `/bookings/${b2.id}/demands`, { stageIds: [b2.stages[0].id], date: daysAgo(12), dueDate: addDays(todayIst(), 3) });

  // Booking 3: cancelled; the unit is available again.
  const b3 = await api('POST', '/bookings', { unitId: unit('B-301'), customerPartyId: desai.id, date: daysAgo(30), paymentPlanId: plan.id });
  await api('POST', `/bookings/${b3.id}/cancel`, { reason: 'Home loan not sanctioned' });

  // One transfer into the RERA account (70% rule is shown on GET /projects/:id/rera).
  await api('POST', '/journals', { date: daysAgo(35), narration: 'Transfer to RERA collection account — Progen Heights', lines: [
    { accountId: reraAccount.id, debit: 1500000 }, { accountId: acct('1010'), credit: 1500000 }] });

  // A B2B invoice with a sandbox IRN.
  await api('POST', `/invoices/${invoiceId}/einvoice`, {});
}
