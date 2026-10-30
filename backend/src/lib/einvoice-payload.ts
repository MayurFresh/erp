// Builds the IRP e-invoice JSON (schema Version 1.1) from an invoice and its parties.
import { createHash } from 'node:crypto';

const round2 = (n: number) => Math.round(n * 100) / 100;

export interface PayloadInput {
  invoice: {
    number: string; fy: string; invoice_date: string; place_of_supply: string; subtotal: number; cgst: number; sgst: number;
    igst: number; round_off: number; total: number;
  };
  company: { gstin: string | null; name: string; legal_name: string | null; address: string | null; state_code: string; pincode: string | null };
  location: { name: string; address: string | null; pincode: string | null };
  party: { gstin: string | null; name: string; address: string | null; state_code: string | null; pincode: string | null };
  lines: {
    line_no: number; description: string; hsn_code: string | null; qty: number; unit: string; rate: number;
    taxable_value: number; gst_rate: number; cgst: number; sgst: number; igst: number; line_total: number;
  }[];
}

const UQC: Record<string, string> = {
  bag: 'BAG', bags: 'BAG', kg: 'KGS', kgs: 'KGS', ton: 'TON', tons: 'TON', tonne: 'TON', mt: 'MTS', nos: 'NOS', no: 'NOS',
  pcs: 'PCS', pc: 'PCS', box: 'BOX', roll: 'ROL', ltr: 'LTR', l: 'LTR', litre: 'LTR', m: 'MTR', mtr: 'MTR', m2: 'SQM',
  sqm: 'SQM', sqft: 'SQF', m3: 'CBM', cum: 'CBM', cbm: 'CBM', set: 'SET', bundle: 'BDL', pack: 'PAC', can: 'CAN',
  drum: 'DRM', bucket: 'OTH', day: 'OTH',
};
export const uqc = (unit: string) => UQC[unit.trim().toLowerCase()] ?? 'OTH';

export const irpDate = (isoDate: string) => `${isoDate.slice(8, 10)}/${isoDate.slice(5, 7)}/${isoDate.slice(0, 4)}`;
const clip = (s: string, max: number) => (s.length > max ? s.slice(0, max) : s);
const padMin = (s: string, min: number) => (s.length >= min ? s : s.padEnd(min, '.'));

/** Returns the payload, or the data problems that stop it from being built (field → message). */
export function buildEinvoicePayload(input: PayloadInput): { payload: Record<string, unknown> | null; errors: Record<string, string> } {
  const { invoice: inv, company, location, party, lines } = input;
  const errors: Record<string, string> = {};
  const pin = company.pincode ?? location.pincode;
  if (!company.gstin) errors['company.gstin'] = 'Add the company GSTIN';
  if (!pin) errors['company.pincode'] = 'Add the company pincode';
  if (!party.gstin) errors['party.gstin'] = 'The customer has no GSTIN (B2C invoices are not e-invoiced)';
  if (!party.pincode) errors['party.pincode'] = 'Add the customer pincode';
  if (!party.state_code) errors['party.stateCode'] = 'Add the customer state';
  lines.forEach((l, i) => {
    if (!l.hsn_code || !/^(?!0+$)([0-9]{4}|[0-9]{6}|[0-9]{8})$/.test(l.hsn_code)) {
      errors[`lines.${i}.hsnCode`] = `Line ${i + 1} (${l.description}): add a 4, 6 or 8 digit HSN/SAC code`;
    }
  });
  if (Object.keys(errors).length) return { payload: null, errors };

  const sellerAddr = company.address ?? location.address ?? company.name;
  const payload = {
    Version: '1.1',
    TranDtls: { TaxSch: 'GST', SupTyp: 'B2B', RegRev: 'N', EcmGstin: null, IgstOnIntra: 'N' },
    DocDtls: { Typ: 'INV', No: inv.number, Dt: irpDate(inv.invoice_date) },
    SellerDtls: {
      Gstin: company.gstin, LglNm: padMin(clip(company.legal_name ?? company.name, 100), 3),
      Addr1: clip(sellerAddr, 100), Loc: padMin(clip(location.name, 50), 3), Pin: Number(pin), Stcd: company.state_code,
    },
    BuyerDtls: {
      Gstin: party.gstin, LglNm: padMin(clip(party.name, 100), 3), Pos: inv.place_of_supply,
      Addr1: clip(party.address ?? party.name, 100), Loc: padMin(clip(party.address ?? party.name, 50), 3),
      Pin: Number(party.pincode), Stcd: party.state_code,
    },
    ItemList: lines.map((l) => {
      const totAmt = round2(l.qty * l.rate);
      return {
        SlNo: String(l.line_no), PrdDesc: padMin(clip(l.description, 300), 3), IsServc: l.hsn_code!.startsWith('99') ? 'Y' : 'N',
        HsnCd: l.hsn_code, Qty: l.qty, Unit: uqc(l.unit), UnitPrice: l.rate, TotAmt: totAmt,
        Discount: round2(Math.max(totAmt - l.taxable_value, 0)), AssAmt: l.taxable_value, GstRt: l.gst_rate,
        IgstAmt: l.igst, CgstAmt: l.cgst, SgstAmt: l.sgst, CesRt: 0, CesAmt: 0, CesNonAdvlAmt: 0, StateCesRt: 0, StateCesAmt: 0,
        StateCesNonAdvlAmt: 0, OthChrg: 0, TotItemVal: l.line_total,
      };
    }),
    ValDtls: {
      AssVal: inv.subtotal, CgstVal: inv.cgst, SgstVal: inv.sgst, IgstVal: inv.igst, CesVal: 0, StCesVal: 0, Discount: 0,
      OthChrg: 0, RndOffAmt: inv.round_off, TotInvVal: inv.total,
    },
  };
  return { payload, errors };
}

/** Lowercase SHA-256 hex of supplier GSTIN + financial year + "INV" + invoice number. */
export const irnOf = (supplierGstin: string, fy: string, invoiceNo: string) =>
  createHash('sha256').update(`${supplierGstin}${fy}INV${invoiceNo}`).digest('hex');

/** base64url JSON summary used as the sandbox signed QR code. */
export function sandboxQr(p: {
  sellerGstin: string; buyerGstin: string; docNo: string; docDate: string; totalValue: number; itemCount: number; mainHsn: string; irn: string;
}): string {
  return Buffer.from(JSON.stringify({
    SellerGstin: p.sellerGstin, BuyerGstin: p.buyerGstin, DocNo: p.docNo, DocTyp: 'INV', DocDt: p.docDate,
    TotInvVal: p.totalValue, ItemCnt: p.itemCount, MainHsnCode: p.mainHsn, Irn: p.irn, sandbox: true,
  })).toString('base64url');
}
