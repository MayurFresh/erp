const round2 = (n: number) => Math.round(n * 100) / 100;

/** Paid / due / status for an invoice or bill. Cancelled documents owe nothing. */
export function paymentInfo(total: number, paid: number, status: string) {
  const amountDue = status === 'cancelled' ? 0 : round2(Math.max(total - paid, 0));
  const paymentStatus = status !== 'cancelled' && amountDue === 0 ? 'paid' : paid > 0 ? 'partial' : 'unpaid';
  return { amountPaid: round2(paid), amountDue, paymentStatus: amountDue === 0 && total === 0 ? 'paid' : paymentStatus };
}

export const sumBy = <T>(rows: T[], f: (r: T) => number) => round2(rows.reduce((s, r) => s + f(r), 0));
