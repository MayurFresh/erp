type ApiFn = (method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE', url: string, body?: unknown) => Promise<any>;

/**
 * Demo data for v1.8 order to cash: barcodes on a few items and orders in each stage (confirmed with a reservation,
 * picked, dispatched in transit, delivered, and an RTO that was returned and inspected). Red Clay Bricks are stocked
 * at SA-T1, so every order is placed there. `api` acts as owner@demo.in.
 */
export async function seedO2c(o: { api: ApiFn; as: (email: string) => Promise<ApiFn>; runJobs: () => Promise<void> }) {
  const { api } = o;
  const locations = (await api('GET', '/locations')).data as { id: string; code: string | null }[];
  const loc = locations.find((l) => l.code === 'SA-T1') ?? locations[0]!;
  const parties = (await api('GET', '/parties?limit=200')).data as { id: string; type: string }[];
  const customers = parties.filter((p) => p.type !== 'vendor');
  if (!customers.length) return;
  const customer = (i: number) => customers[i % customers.length]!.id;
  const items = (await api('GET', '/items?limit=200')).data as { id: string; sku: string | null }[];
  const bySku = (sku: string) => items.find((i) => i.sku === sku);

  const barcodes: Record<string, string> = { 'BRK-RED': '8901000000011', 'CEM-OPC53': '8901000000028', 'TIL-VT22': '8901000000035' };
  for (const [sku, barcode] of Object.entries(barcodes)) {
    const it = bySku(sku);
    if (it) await api('PATCH', `/items/${it.id}`, { barcode });
  }
  const bricks = bySku('BRK-RED');
  if (!bricks) return;

  let scan = 0;
  const scanId = () => `seed-scan-${Date.now()}-${scan++}`;
  const make = async (ci: number, qty: number, ref: string) => {
    const created = await api('POST', '/sales-orders', {
      locationId: loc.id, partyId: customer(ci), externalRef: ref, lines: [{ itemId: bricks.id, qty, rate: 9 }],
    });
    if (!created?.id) return null;
    const confirmed = await api('POST', `/sales-orders/${created.id}/confirm`);
    return confirmed?.id ? (confirmed as { id: string; lines: { id: string }[] }) : null;
  };
  const pickAndPack = async (order: { id: string }, qty: number) => {
    const list = await api('POST', '/pick-lists', { locationId: loc.id, orderIds: [order.id] });
    await api('POST', `/pick-lists/${list.id}/scan`, { scanId: scanId(), code: barcodes['BRK-RED'], qty });
    await api('POST', `/pick-lists/${list.id}/complete`);
    await api('POST', `/sales-orders/${order.id}/pack`, {});
  };
  const dispatch = async (order: { id: string }, awb: string, mode: 'prepaid' | 'cod' = 'prepaid') =>
    api('POST', `/sales-orders/${order.id}/dispatch`, { courier: 'Delhivery', awb, mode });

  // A draft, and a confirmed order that holds stock.
  await api('POST', '/sales-orders', { locationId: loc.id, partyId: customer(0), lines: [{ itemId: bricks.id, qty: 120, rate: 9 }] });
  await make(1, 200, 'SEED-CONFIRMED');

  // Picked, waiting to be packed.
  const picked = await make(2, 150, 'SEED-PICKED');
  if (picked) {
    const list = await api('POST', '/pick-lists', { locationId: loc.id, orderIds: [picked.id] });
    await api('POST', `/pick-lists/${list.id}/scan`, { scanId: scanId(), code: 'BRK-RED', qty: 150 });
  }

  // Dispatched, in transit.
  const transit = await make(0, 100, 'SEED-TRANSIT');
  if (transit) {
    await pickAndPack(transit, 100);
    const s = await dispatch(transit, 'DLV100200301');
    if (s?.id) await api('POST', `/shipments/${s.id}/status`, { status: 'in_transit' });
  }

  // Delivered.
  const delivered = await make(1, 80, 'SEED-DELIVERED');
  if (delivered) {
    await pickAndPack(delivered, 80);
    const s = await dispatch(delivered, 'DLV100200302', 'cod');
    if (s?.id) {
      await api('POST', `/shipments/${s.id}/status`, { status: 'in_transit' });
      await api('POST', `/shipments/${s.id}/status`, { status: 'delivered' });
    }
  }

  // Returned to origin, received and inspected.
  const rto = await make(2, 60, 'SEED-RTO');
  if (rto) {
    await pickAndPack(rto, 60);
    const s = await dispatch(rto, 'DLV100200303');
    if (s?.id) {
      for (const status of ['in_transit', 'rto_initiated', 'rto_delivered']) await api('POST', `/shipments/${s.id}/status`, { status });
      const ret = (await api('GET', `/sales-returns?orderId=${rto.id}`)).data?.[0];
      if (ret) {
        const received = await api('POST', `/sales-returns/${ret.id}/receive`, {});
        await api('POST', `/sales-returns/${ret.id}/inspect`, {
          lines: received.lines.map((l: { id: string }, i: number) => ({ lineId: l.id, disposition: i === 0 ? 'restock' : 'damaged' })),
        });
      }
    }
  }
  await o.runJobs();
}
