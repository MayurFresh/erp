import { describe, expect, it } from 'vitest';
import { computeGst } from '../src/lib/gst.ts';
import { financialYear, invoiceNumber, isValidDate } from '../src/lib/dates.ts';

describe('computeGst', () => {
  it('splits CGST and SGST within a state', () => {
    const r = computeGst('24', '24', [{ qty: 2, rate: 100, discountPct: 0, gstRate: 18 }]);
    expect(r).toMatchObject({ supplyType: 'intra', subtotal: 200, cgst: 18, sgst: 18, igst: 0, taxTotal: 36, total: 236, roundOff: 0 });
  });

  it('charges IGST across states', () => {
    const r = computeGst('24', '27', [{ qty: 2, rate: 100, discountPct: 0, gstRate: 18 }]);
    expect(r).toMatchObject({ supplyType: 'inter', cgst: 0, sgst: 0, igst: 36, total: 236 });
  });

  it('applies discount before tax and rounds the total to the rupee', () => {
    const r = computeGst('24', '24', [{ qty: 3, rate: 99.99, discountPct: 10, gstRate: 12 }]);
    // gross 299.97, discount 30.00 (29.997), taxable 269.97, CGST = SGST = 16.20 (16.1982)
    expect(r.lines[0]).toEqual({ taxableValue: 269.97, cgst: 16.2, sgst: 16.2, igst: 0, lineTotal: 302.37 });
    expect(r.total).toBe(302);
    expect(r.roundOff).toBe(-0.37);
  });

  it('handles fractional quantities and rates exactly', () => {
    const r = computeGst('09', '09', [
      { qty: 1.005, rate: 100, discountPct: 0, gstRate: 0.25 },
      { qty: 0.333, rate: 33.33, discountPct: 0, gstRate: 5 },
    ]);
    expect(r.lines[0]!.taxableValue).toBe(100.5);
    expect(r.lines[0]!.cgst).toBe(0.13); // 100.50 × 0.125% = 0.1256
    expect(r.lines[1]!.taxableValue).toBe(11.1); // 0.333 × 33.33 = 11.0989
    expect(r.subtotal).toBe(111.6);
  });

  it('sums many lines without floating-point drift', () => {
    const lines = Array.from({ length: 100 }, () => ({ qty: 1, rate: 0.1, discountPct: 0, gstRate: 18 }));
    const r = computeGst('24', '24', lines);
    expect(r.subtotal).toBe(10);
    expect(r.cgst).toBe(1); // 0.009 rounds to 0.01 per line
    expect(r.total).toBe(12);
  });
});

describe('dates', () => {
  it('labels Indian financial years', () => {
    expect(financialYear('2026-04-01')).toBe('2026-27');
    expect(financialYear('2027-03-31')).toBe('2026-27');
    expect(financialYear('2099-12-31')).toBe('2099-00');
  });

  it('builds invoice numbers within the 16-character GST limit', () => {
    const n = invoiceNumber('2026-27', 1);
    expect(n).toBe('INV/26-27/00001');
    expect(n.length).toBeLessThanOrEqual(16);
  });

  it('validates calendar dates', () => {
    expect(isValidDate('2026-02-28')).toBe(true);
    expect(isValidDate('2026-02-30')).toBe(false);
    expect(isValidDate('26-02-01')).toBe(false);
  });
});
