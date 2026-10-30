// GST set-off of the credit ledger against liability (CGST Rules, Rule 88A). Pure; every amount is integer paise.

export type Head = 'igst' | 'cgst' | 'sgst' | 'cess';
export type Heads = Record<Head, number>;
export interface SetoffMove { from: Head; to: Head; amount: number }

export interface SetoffInput {
  liability: Heads;                   // outward tax, excluding reverse charge
  rcm: Heads;                         // reverse-charge tax: cash only
  credit: Heads;                      // credit ledger available
  interest: number;
  lateFee: number;
  igstSplit?: 'cgst_first' | 'sgst_first';
}

export interface SetoffResult {
  matrix: SetoffMove[];
  creditUsed: Heads;
  creditCarryForward: Heads;
  cash: { tax: Heads; interest: number; lateFee: number; total: number };
}

export const zeroHeads = (): Heads => ({ igst: 0, cgst: 0, sgst: 0, cess: 0 });
export const sumHeads = (h: Heads) => h.igst + h.cgst + h.sgst + h.cess;

export function setoff(input: SetoffInput): SetoffResult {
  const due = { ...input.liability };
  const cr = { ...input.credit };
  const used = zeroHeads();
  const matrix: SetoffMove[] = [];
  const pay = (from: Head, to: Head) => {
    const a = Math.min(cr[from], due[to]);
    if (a <= 0) return;
    cr[from] -= a; due[to] -= a; used[from] += a;
    matrix.push({ from, to, amount: a });
  };
  const second = input.igstSplit === 'sgst_first' ? (['sgst', 'cgst'] as const) : (['cgst', 'sgst'] as const);
  pay('igst', 'igst');
  pay('igst', second[0]);
  pay('igst', second[1]);
  pay('cgst', 'cgst');
  pay('cgst', 'igst');
  pay('sgst', 'sgst');
  pay('sgst', 'igst');
  pay('cess', 'cess');
  const tax: Heads = { igst: due.igst + input.rcm.igst, cgst: due.cgst + input.rcm.cgst, sgst: due.sgst + input.rcm.sgst, cess: due.cess + input.rcm.cess };
  return {
    matrix, creditUsed: used, creditCarryForward: cr,
    cash: { tax, interest: input.interest, lateFee: input.lateFee, total: sumHeads(tax) + input.interest + input.lateFee },
  };
}
