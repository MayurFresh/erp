type ApiFn = (method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE', url: string, body?: unknown) => Promise<any>;

/**
 * Demo data for v1.8 procure to pay and stock counts: an approval rule for large purchase orders, purchase orders in
 * several states, one bill matched to a receipt, a draft raised from reorder suggestions and one posted stock count.
 * `api` acts as owner@demo.in; `as` signs in another demo user.
 */
export async function seedP2p(o: { api: ApiFn; as: (email: string) => Promise<ApiFn>; runJobs: () => Promise<void> }) {
  const { api } = o;
  const locations = (await api('GET', '/locations')).data as { id: string; type: string; name: string }[];
  const warehouse = locations.find((l) => l.type === 'warehouse') ?? locations[0]!;
  const parties = (await api('GET', '/parties?limit=200')).data as { id: string; type: string }[];
  const vendor = parties.find((p) => p.type === 'vendor');
  const items = (await api('GET', '/items?limit=200')).data as { id: string; sku: string | null }[];
  const item = (sku: string) => items.find((i) => i.sku === sku);
  const tiles = item('TIL-VT22');
  const cement = item('CEM-OPC53');
  const sand = item('SAND-R');
  const wire = item('WIR-15');
  if (!vendor || !tiles || !cement || !sand || !wire) return;

  const roles = (await api('GET', '/roles')).data as { id: string; name: string }[];
  const owner = roles.find((r) => r.name === 'Owner');
  if (owner) {
    await api('POST', '/approval-rules', {
      docType: 'purchase_order', name: 'Large purchase orders need the Owner', minAmount: 200000, levels: [{ approverRoleId: owner.id }],
    });
  }
  const accountant = await o.as('accountant@demo.in');
  const po = (lines: { itemId: string; qty: number; rate?: number }[], notes: string) =>
    api('POST', '/purchase-orders', { locationId: warehouse.id, partyId: vendor.id, notes, lines });

  // One waiting for the Owner (above the approval limit), raised by the accountant.
  const big = await accountant('POST', '/purchase-orders', {
    locationId: warehouse.id, partyId: vendor.id, notes: 'Tiles for the Tower B finishing',
    lines: [{ itemId: tiles.id, qty: 500, rate: 540 }],
  });
  if (big?.id) await accountant('POST', `/purchase-orders/${big.id}/submit`);

  // One sent to the vendor, nothing received yet.
  const sent = await po([{ itemId: cement.id, qty: 200, rate: 335 }], 'Monthly cement order');
  await api('POST', `/purchase-orders/${sent.id}/submit`);
  await api('POST', `/purchase-orders/${sent.id}/send`);

  // One partly received.
  const partial = await po([{ itemId: sand.id, qty: 100, rate: 1200 }], 'River sand for plastering');
  await api('POST', `/purchase-orders/${partial.id}/submit`);
  await api('POST', `/purchase-orders/${partial.id}/send`);
  await api('POST', '/goods-receipts', {
    purchaseOrderId: partial.id, challanNo: 'CH-4471', vehicleNo: 'GJ05AB1234',
    lines: [{ poLineId: partial.lines[0].id, acceptedQty: 40 }],
  });

  // One received in full and billed against the receipt.
  const done = await po([{ itemId: wire.id, qty: 30, rate: 1180 }], 'Electrical wire for the site office');
  await api('POST', `/purchase-orders/${done.id}/submit`);
  const grn = await api('POST', '/goods-receipts', {
    purchaseOrderId: done.id, lines: [{ poLineId: done.lines[0].id, acceptedQty: 30 }],
  });
  await api('POST', '/purchases', {
    locationId: warehouse.id, partyId: vendor.id, supplierInvoiceNo: 'SI-9031',
    lines: [{ itemId: wire.id, qty: 30, grnLineId: grn.lines[0].id }],
  });

  // A draft raised from the reorder suggestions.
  const suggestions = (await api('GET', `/reorder-suggestions?locationId=${warehouse.id}`)).data as {
    itemId: string; suggestedQty: number; lastVendorId: string | null;
  }[];
  const picks = suggestions.slice(0, 2);
  if (picks.length) {
    await api('POST', '/reorder-suggestions/purchase-orders', {
      selections: picks.map((s) => ({ itemId: s.itemId, locationId: warehouse.id, qty: s.suggestedQty, partyId: s.lastVendorId ?? vendor.id })),
    });
  }

  // One posted stock count with a small variance.
  const count = await api('POST', '/stock-counts', { locationId: warehouse.id, itemIds: [cement.id, sand.id] });
  if (count?.id) {
    for (const l of count.lines as { itemId: string; expectedQty: number }[]) {
      const counted = l.itemId === cement.id ? Math.max(l.expectedQty - 2, 0) : l.expectedQty;
      await api('POST', `/stock-counts/${count.id}/scans`, { itemId: l.itemId, qty: counted, mode: 'set' });
    }
    await api('POST', `/stock-counts/${count.id}/post`, {});
  }
  await o.runJobs();
}
