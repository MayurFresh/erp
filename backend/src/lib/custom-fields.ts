import { z } from 'zod';
import type { Tx } from '../db/database.ts';
import type { CustomValues } from '../db/schema.ts';
import { isValidDate } from './dates.ts';
import { badRequest } from './errors.ts';

export type CustomEntity = 'item' | 'party' | 'invoice' | 'purchase' | 'project';

/** `custom` in a create or PATCH body. `null` clears a key on PATCH. */
export const customInput = z.record(z.string().max(30), z.union([z.string().max(500), z.number(), z.boolean(), z.null()]))
  .refine((r) => Object.keys(r).length <= 25, 'At most 25 fields').optional();

export interface FieldDef { key: string; label: string; type: string; options: string[]; required: boolean; showOnPrint: boolean; isActive: boolean }

export async function customFieldDefs(tx: Tx, companyId: string, entity: CustomEntity, activeOnly = true): Promise<FieldDef[]> {
  let q = tx.selectFrom('custom_fields')
    .select(['key', 'label', 'type', 'options', 'required', 'show_on_print', 'is_active'])
    .where('company_id', '=', companyId).where('entity', '=', entity);
  if (activeOnly) q = q.where('is_active', '=', true);
  const rows = await q.orderBy('sort_order').orderBy('label').execute();
  return rows.map((r) => ({ key: r.key, label: r.label, type: r.type, options: r.options, required: r.required, showOnPrint: r.show_on_print, isActive: r.is_active }));
}

function check(f: FieldDef, v: string | number | boolean): string | null {
  switch (f.type) {
    case 'text': return typeof v === 'string' && v.length <= 500 ? null : 'Use text of at most 500 characters';
    case 'number': return typeof v === 'number' && Number.isFinite(v) ? null : 'Use a number';
    case 'date': return typeof v === 'string' && isValidDate(v) ? null : 'Use YYYY-MM-DD';
    case 'boolean': return typeof v === 'boolean' ? null : 'Use true or false';
    case 'select': return typeof v === 'string' && f.options.includes(v) ? null : `Use one of: ${f.options.join(', ')}`;
    default: return 'Unknown field type';
  }
}

/**
 * Validates `input` against the entity's active fields and returns the values to store.
 * Create: pass no `existing`; required fields must be present. PATCH: `input` merges into `existing`.
 */
export async function validateCustom(
  tx: Tx, companyId: string, entity: CustomEntity, input: Record<string, string | number | boolean | null> | undefined,
  existing?: CustomValues,
): Promise<CustomValues> {
  const defs = await customFieldDefs(tx, companyId, entity);
  const out: CustomValues = { ...(existing ?? {}) };
  const errors: Record<string, string> = {};
  for (const [key, raw] of Object.entries(input ?? {})) {
    const f = defs.find((d) => d.key === key);
    if (!f) { errors[`custom.${key}`] = 'Unknown field'; continue; }
    const v = typeof raw === 'string' ? raw.trim() : raw;
    if (v === null || v === '') { delete out[key]; continue; }
    const problem = check(f, v);
    if (problem) errors[`custom.${key}`] = problem;
    else out[key] = v;
  }
  for (const f of defs) {
    if (!f.required || out[f.key] !== undefined) continue;
    // On PATCH only a field being cleared is an error; older records may predate the field.
    if (!existing || (input && key(input, f.key))) errors[`custom.${f.key}`] = 'Required';
  }
  const first = Object.entries(errors)[0];
  if (first) throw badRequest(`${first[0]}: ${first[1]}`, errors);
  return out;
}

const key = (o: object, k: string) => Object.prototype.hasOwnProperty.call(o, k);

/** Display text for a stored value, for CSV exports and PDFs. */
export function customText(v: string | number | boolean | undefined): string {
  if (v === undefined) return '';
  if (typeof v === 'boolean') return v ? 'Yes' : 'No';
  return String(v);
}
