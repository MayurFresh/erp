// GST invoice arithmetic in integer paise (BigInt) so totals never drift by a paisa.

export interface GstLineInput {
  qty: number;          // up to 3 decimals
  rate: number;         // rupees, up to 2 decimals
  discountPct: number;  // up to 2 decimals
  gstRate: number;      // percent, up to 2 decimals (e.g. 18, 0.25)
}

export interface GstLine {
  taxableValue: number; cgst: number; sgst: number; igst: number; lineTotal: number;
}

export interface GstTotals {
  supplyType: 'intra' | 'inter';
  lines: GstLine[];
  subtotal: number; cgst: number; sgst: number; igst: number; taxTotal: number;
  roundOff: number; total: number;
}

const scaled = (value: number, factor: number) => BigInt(Math.round(value * factor));

/** a × b ÷ d, rounded half-up; all non-negative. */
function mulDivRound(a: bigint, b: bigint, d: bigint): bigint {
  return (a * b * 2n + d) / (2n * d);
}

const rupees = (paise: bigint) => Number(paise) / 100;

export function computeGst(sellerState: string, placeOfSupply: string, inputs: GstLineInput[]): GstTotals {
  const intra = sellerState === placeOfSupply;
  let subtotal = 0n, cgst = 0n, sgst = 0n, igst = 0n;

  const lines = inputs.map((l) => {
    const gross = mulDivRound(scaled(l.qty, 1000), scaled(l.rate, 100), 1000n);
    const discount = mulDivRound(gross, scaled(l.discountPct, 100), 10_000n);
    const taxable = gross - discount;
    const rateBps = scaled(l.gstRate, 100);
    let c = 0n, s = 0n, i = 0n;
    if (intra) {
      c = mulDivRound(taxable, rateBps, 20_000n);
      s = c;
    } else {
      i = mulDivRound(taxable, rateBps, 10_000n);
    }
    subtotal += taxable; cgst += c; sgst += s; igst += i;
    return {
      taxableValue: rupees(taxable), cgst: rupees(c), sgst: rupees(s), igst: rupees(i),
      lineTotal: rupees(taxable + c + s + i),
    };
  });

  const gross = subtotal + cgst + sgst + igst;
  const total = ((gross + 50n) / 100n) * 100n; // nearest rupee, half-up
  return {
    supplyType: intra ? 'intra' : 'inter',
    lines,
    subtotal: rupees(subtotal), cgst: rupees(cgst), sgst: rupees(sgst), igst: rupees(igst),
    taxTotal: rupees(cgst + sgst + igst),
    roundOff: rupees(total - gross),
    total: rupees(total),
  };
}
