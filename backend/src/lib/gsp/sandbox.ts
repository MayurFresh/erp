import { createHash, randomInt } from 'node:crypto';
import { financialYear } from '../dates.ts';
import { irnOf, sandboxQr } from '../einvoice-payload.ts';
import type { GspAdapter } from './types.ts';

/** The local fake IRP (v1.3) behind the adapter interface. IRNs it makes are marked `irnSandbox`. */
export const sandboxAdapter: GspAdapter = {
  id: 'sandbox',
  name: 'Sandbox (local test IRP)',
  capabilities: new Set(['einvoice', 'ewaybill', 'gstr1_save']),
  credentialFields: [],
  async ping() { return { ok: true, message: 'Sandbox is always available.' }; },
  async generateIrn(c, payload) {
    const p = payload as {
      DocDtls: { No: string; Dt: string }; SellerDtls: { Gstin: string }; BuyerDtls: { Gstin: string };
      ItemList: { HsnCd: string; AssAmt?: number; TotAmt?: number }[]; ValDtls: { TotInvVal: number };
    };
    const [dd, mm, yyyy] = p.DocDtls.Dt.split('/');
    const iso = `${yyyy}-${mm}-${dd}`;
    const irn = irnOf(c.gstin, financialYear(iso), p.DocDtls.No);
    const hsn = new Map<string, number>();
    for (const l of p.ItemList) hsn.set(l.HsnCd, (hsn.get(l.HsnCd) ?? 0) + (l.AssAmt ?? l.TotAmt ?? 0));
    const mainHsn = [...hsn.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] ?? '';
    return {
      irn, ackNo: String(randomInt(1, 10) * 10 ** 14 + randomInt(0, 10 ** 14)), ackDate: new Date(),
      signedQr: sandboxQr({
        sellerGstin: c.gstin, buyerGstin: p.BuyerDtls.Gstin, docNo: p.DocDtls.No, docDate: p.DocDtls.Dt,
        totalValue: p.ValDtls.TotInvVal, itemCount: p.ItemList.length, mainHsn, irn,
      }),
      signedInvoice: null,
    };
  },
  async cancelIrn() { return { cancelledAt: new Date() }; },
  async generateEwb(_c, input) {
    const days = Math.max(1, Math.ceil(input.distanceKm / 200));
    const ewbDate = new Date();
    return {
      ewbNo: String(randomInt(1, 10) * 10 ** 11 + randomInt(0, 10 ** 11)), ewbDate,
      validUntil: new Date(`${new Date(ewbDate.getTime() + days * 86_400_000).toLocaleDateString("en-CA", { timeZone: "Asia/Kolkata" })}T23:59:59+05:30`),
    };
  },
  async cancelEwb() { return { cancelledAt: new Date() }; },
  async saveGstr1(c, period, json) {
    const h = createHash('sha256').update(`${c.gstin}${period}${JSON.stringify(json)}`).digest('hex').slice(0, 12).toUpperCase();
    return { reference: `SBX-${h}`, status: 'saved' };
  },
};
