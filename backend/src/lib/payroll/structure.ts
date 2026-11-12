// Salary structure maths: component amounts from percentages, and a CTC split.
import { roundRupee } from './money.ts';

export interface ComponentDef {
  id: string; code: string; name: string; kind: 'earning' | 'deduction';
  calc: 'fixed' | 'pct_basic' | 'pct_gross'; percent: number | null; isBasic: boolean;
}

/**
 * Monthly amounts for each component. `given` holds fixed amounts the user typed. Percent-of-basic components use the basic;
 * percent-of-gross components use the earnings that are not themselves percent-of-gross.
 */
export function resolveAmounts(components: ComponentDef[], given: Record<string, number | undefined>): Record<string, number> {
  const out: Record<string, number> = {};
  const basic = components.find((c) => c.isBasic);
  const basicAmount = basic ? (given[basic.id] ?? 0) : 0;
  for (const c of components) {
    if (c.calc === 'fixed' || c.isBasic) out[c.id] = given[c.id] ?? 0;
    else if (c.calc === 'pct_basic' && given[c.id] === undefined) out[c.id] = roundRupee((basicAmount * (c.percent ?? 0)) / 100);
    else if (c.calc === 'pct_basic') out[c.id] = given[c.id]!;
  }
  const base = components.filter((c) => c.kind === 'earning' && c.calc !== 'pct_gross').reduce((s, c) => s + (out[c.id] ?? 0), 0);
  for (const c of components) {
    if (c.calc === 'pct_gross') out[c.id] = given[c.id] ?? roundRupee((base * (c.percent ?? 0)) / 100);
  }
  return out;
}

/**
 * Splits a yearly CTC into monthly components: basic is `basicPct` of the monthly CTC, percent components follow,
 * and the balance goes to the component coded SPECIAL (or the last fixed earning).
 */
export function splitCtc(components: ComponentDef[], ctcAnnual: number, basicPct = 50): Record<string, number> {
  const monthly = roundRupee(ctcAnnual / 12);
  const basic = components.find((c) => c.isBasic);
  if (!basic) return {};
  const given: Record<string, number> = { [basic.id]: roundRupee((monthly * basicPct) / 100) };
  const resolved = resolveAmounts(components.filter((c) => c.kind === 'earning'), given);
  const used = Object.values(resolved).reduce((s, v) => s + v, 0);
  const balanceTo = components.find((c) => c.code === 'SPECIAL') ?? [...components].reverse().find((c) => c.kind === 'earning' && c.calc === 'fixed' && !c.isBasic);
  if (balanceTo) resolved[balanceTo.id] = Math.max(0, (resolved[balanceTo.id] ?? 0) + monthly - used);
  return resolved;
}
