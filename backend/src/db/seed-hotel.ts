// Demo hotel data: three room types, twelve rooms, rate plans and a few bookings. Not called from seed.ts; the lead wires it in.
import type { Tx } from './database.ts';
import { addDays, financialYear, todayIst } from '../lib/dates.ts';
import { nextNumber } from '../lib/series.ts';

export interface HotelSeedWho { tenantId: string; companyId: string; userId: string }

const TYPES = [
  { name: 'Standard', base: 1200, extra: 300, occ: [2, 3], rooms: ['101', '102', '103', '104'], floor: '1' },
  { name: 'Deluxe', base: 2800, extra: 500, occ: [2, 3], rooms: ['201', '202', '203', '204', '205'], floor: '2' },
  { name: 'Suite', base: 8200, extra: 900, occ: [2, 4], rooms: ['301', '302', '303'], floor: '3' },
];
const GUESTS = [
  { name: 'Ravi Shah', phone: '9825012345' }, { name: 'Meena Patel', phone: '9825099999' },
  { name: 'Kiran Desai', phone: '9898012345' }, { name: 'Suresh Joshi', phone: '9427011223' },
];

export async function seedHotelDemo(tx: Tx, { tenantId, companyId, userId }: HotelSeedWho) {
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', companyId).executeTakeFirstOrThrow();
  const types: { id: string; name: string; rooms: { id: string; number: string }[] }[] = [];
  for (const t of TYPES) {
    const row = await tx.insertInto('hotel_room_types').values({
      tenant_id: tenantId, company_id: companyId, name: t.name, base_occupancy: t.occ[0]!, max_occupancy: t.occ[1]!,
      base_tariff: t.base, extra_person_charge: t.extra,
    }).returning('id').executeTakeFirstOrThrow();
    const rooms = await tx.insertInto('hotel_rooms').values(t.rooms.map((number) => ({
      tenant_id: tenantId, company_id: companyId, room_type_id: row.id, number, floor: t.floor,
    }))).returning(['id', 'number']).execute();
    await tx.insertInto('hotel_rate_plans').values([
      { tenant_id: tenantId, company_id: companyId, room_type_id: row.id, name: `${t.name} room only`, meal: 'room_only', weekday_tariff: t.base, weekend_tariff: Math.round(t.base * 1.25) },
      { tenant_id: tenantId, company_id: companyId, room_type_id: row.id, name: `${t.name} with breakfast`, meal: 'breakfast', weekday_tariff: t.base + 250, weekend_tariff: Math.round(t.base * 1.25) + 250 },
    ]).execute();
    types.push({ id: row.id, name: t.name, rooms });
  }
  const today = todayIst();
  const fy = financialYear(today);
  const plans: [number, number, number, string][] = [[0, 0, 2, 'phone'], [1, 1, 1, 'walk_in'], [2, 1, 3, 'ota'], [3, 2, 2, 'agent']];
  for (const [g, ti, nights, source] of plans) {
    const guest = GUESTS[g]!;
    const party = await tx.insertInto('parties').values({
      tenant_id: tenantId, company_id: companyId, type: 'customer', name: guest.name, phone: guest.phone, state_code: company.state_code,
      address: null, gstin: null, email: null, pan: null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null,
    }).returning('id').executeTakeFirstOrThrow();
    const arrival = addDays(today, g === 0 ? 0 : g);
    const res = await tx.insertInto('hotel_reservations').values({
      tenant_id: tenantId, company_id: companyId, number: await nextNumber(tx, { tenantId, companyId }, 'reservation', fy), party_id: party.id,
      arrival, departure: addDays(arrival, nights), source, source_name: source === 'ota' ? 'MakeMyTrip' : null, status: 'confirmed', created_by: userId,
    }).returning('id').executeTakeFirstOrThrow();
    await tx.insertInto('hotel_reservation_rooms').values({
      tenant_id: tenantId, company_id: companyId, reservation_id: res.id, room_type_id: types[ti]!.id,
      room_id: g === 0 ? null : types[ti]!.rooms[g % types[ti]!.rooms.length]!.id, arrival, departure: addDays(arrival, nights), adults: 2, children: 0,
    }).execute();
  }
  return { roomTypes: types.length, rooms: types.reduce((s, t) => s + t.rooms.length, 0) };
}
