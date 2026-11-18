// Loan recovery never takes net pay below zero. The cut falls on the loan deductions, last one first;
// what is not recovered stays due on the loan (see onPayrollApproved).
import type { AdjustmentInput } from './compute.ts';
import { round2 } from './money.ts';

export interface LoanCut { adjustmentId: string; label: string; cut: number; kept: number }

/** `net` is the net pay with the full loan deductions in. Returns the adjustments to use and what was cut. */
export function capLoanDeductions(adjustments: AdjustmentInput[], loanAdjIds: Set<string>, net: number): { adjustments: AdjustmentInput[]; cuts: LoanCut[] } {
  if (net >= 0) return { adjustments, cuts: [] };
  let short = round2(-net);
  const out = adjustments.map((a) => ({ ...a }));
  const cuts: LoanCut[] = [];
  for (let i = out.length - 1; i >= 0 && short > 0; i -= 1) {
    const a = out[i]!;
    if (!a.id || !loanAdjIds.has(a.id)) continue;
    const cut = round2(Math.min(a.amount, short));
    a.amount = round2(a.amount - cut);
    short = round2(short - cut);
    cuts.push({ adjustmentId: a.id, label: a.label, cut, kept: a.amount });
  }
  return { adjustments: out.filter((a) => !(a.id && loanAdjIds.has(a.id) && a.amount <= 0)), cuts };
}
