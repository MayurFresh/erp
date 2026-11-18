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
  /** Export, SEZ and currency facts of the invoice (migration 056), when it has any. */
  ext?: {
    category: string | null; shippingBillNo: string | null; shippingBillDate: string | null; portCode: string | null;
    country: string | null; currencyCode: string | null;
  } | null;
}

/** NIC supply types: with or without payment of tax. LUT categories are without payment. */
export function supplyTypeOf(category: string | null | undefined): string {
  switch (category) {
    case 'export_igst': return 'EXPWP';
    case 'export_lut': return 'EXPWOP';
    case 'sez_igst': return 'SEZWP';
    case 'sez_lut': return 'SEZWOP';
    case 'deemed': return 'DEXP';
    default: return 'B2B';
  }
}

const ISO_ALPHA2 = new Set(
  'AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW'.split(' '),
);
const COUNTRY_NAMES: Record<string, string> = {"united states": "US", "united states of america": "US", "usa": "US", "united kingdom": "GB", "uk": "GB", "great britain": "GB", "england": "GB", "united arab emirates": "AE", "uae": "AE", "russia": "RU", "russian federation": "RU", "south korea": "KR", "korea": "KR", "north korea": "KP", "vietnam": "VN", "viet nam": "VN", "iran": "IR", "syria": "SY", "laos": "LA", "tanzania": "TZ", "bolivia": "BO", "venezuela": "VE", "moldova": "MD", "taiwan": "TW", "czech republic": "CZ", "czechia": "CZ", "turkey": "TR", "turkiye": "TR", "ivory coast": "CI", "cote d'ivoire": "CI", "hong kong": "HK", "macau": "MO", "brunei": "BN", "myanmar": "MM", "burma": "MM", "congo": "CG", "democratic republic of the congo": "CD", "dr congo": "CD", "palestine": "PS", "eswatini": "SZ", "swaziland": "SZ", "cape verde": "CV", "east timor": "TL", "timor-leste": "TL", "north macedonia": "MK", "macedonia": "MK", "vatican": "VA", "holy see": "VA", "netherlands": "NL", "holland": "NL", "germany": "DE", "france": "FR", "italy": "IT", "spain": "ES", "portugal": "PT", "china": "CN", "japan": "JP", "australia": "AU", "canada": "CA", "singapore": "SG", "malaysia": "MY", "indonesia": "ID", "thailand": "TH", "bangladesh": "BD", "nepal": "NP", "sri lanka": "LK", "bhutan": "BT", "pakistan": "PK", "afghanistan": "AF", "maldives": "MV", "saudi arabia": "SA", "qatar": "QA", "oman": "OM", "kuwait": "KW", "bahrain": "BH", "kenya": "KE", "nigeria": "NG", "south africa": "ZA", "egypt": "EG", "ethiopia": "ET", "ghana": "GH", "new zealand": "NZ", "brazil": "BR", "mexico": "MX", "argentina": "AR", "switzerland": "CH", "sweden": "SE", "norway": "NO", "denmark": "DK", "finland": "FI", "ireland": "IE", "belgium": "BE", "austria": "AT", "poland": "PL", "greece": "GR", "israel": "IL", "jordan": "JO", "iraq": "IQ", "philippines": "PH", "mauritius": "MU", "tanzania, united republic of": "TZ"};
/** ISO 3166 alpha-2 code from the stored country text, or null when it cannot be told. */
export function countryCode(text: string | null | undefined): string | null {
  const t = (text ?? '').trim();
  if (/^[A-Za-z]{2}$/.test(t) && ISO_ALPHA2.has(t.toUpperCase())) return t.toUpperCase();
  return COUNTRY_NAMES[t.toLowerCase()] ?? null;
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
  const supTyp = supplyTypeOf(input.ext?.category);
  const isExport = supTyp.startsWith('EXP');
  if (!isExport) {
    if (!party.gstin) errors['party.gstin'] = 'The customer has no GSTIN (B2C invoices are not e-invoiced)';
    if (!party.pincode) errors['party.pincode'] = 'Add the customer pincode';
    if (!party.state_code) errors['party.stateCode'] = 'Add the customer state';
  }
  lines.forEach((l, i) => {
    if (!l.hsn_code || !/^(?!0+$)([0-9]{4}|[0-9]{6}|[0-9]{8})$/.test(l.hsn_code)) {
      errors[`lines.${i}.hsnCode`] = `Line ${i + 1} (${l.description}): add a 4, 6 or 8 digit HSN/SAC code`;
    }
  });
  if (Object.keys(errors).length) return { payload: null, errors };

  const sellerAddr = company.address ?? location.address ?? company.name;
  const payload = {
    Version: '1.1',
    TranDtls: { TaxSch: 'GST', SupTyp: supTyp, RegRev: 'N', EcmGstin: null, IgstOnIntra: 'N' },
    DocDtls: { Typ: 'INV', No: inv.number, Dt: irpDate(inv.invoice_date) },
    SellerDtls: {
      Gstin: company.gstin, LglNm: padMin(clip(company.legal_name ?? company.name, 100), 3),
      Addr1: clip(sellerAddr, 100), Loc: padMin(clip(location.name, 50), 3), Pin: Number(pin), Stcd: company.state_code,
    },
    BuyerDtls: isExport ? {
      // Overseas buyer: URP, place of supply and state 96 (other countries), pin 999999.
      Gstin: 'URP', LglNm: padMin(clip(party.name, 100), 3), Pos: '96',
      Addr1: clip(party.address ?? party.name, 100), Loc: padMin(clip(party.address ?? party.name, 50), 3),
      Pin: 999999, Stcd: '96',
    } : {
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
  const e = input.ext;
  if (e && (isExport || supTyp.startsWith('SEZ')) && (e.shippingBillNo || e.portCode || e.currencyCode || e.country)) {
    const cnt = countryCode(e.country);
    (payload as Record<string, unknown>).ExpDtls = {
      ...(e.shippingBillNo ? { ShipBNo: clip(e.shippingBillNo, 16) } : {}),
      ...(e.shippingBillDate ? { ShipBDt: irpDate(e.shippingBillDate) } : {}),
      ...(e.portCode ? { Port: clip(e.portCode, 6) } : {}),
      RefClm: supTyp.endsWith('WP') ? 'Y' : 'N',
      ...(e.currencyCode ? { ForCur: e.currencyCode } : {}),
      ...(cnt ? { CntCode: cnt } : {}),
    };
  }
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
