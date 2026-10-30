import type { FastifyInstance } from 'fastify';
import type { Selectable } from 'kysely';
import { z } from 'zod';
import type { Tx } from '../db/database.ts';
import type { PartyTable } from '../db/schema.ts';
import { badRequest, notFound } from '../lib/errors.ts';
import { definedOnly, gstin, nullableText, optionalText, stateCode } from '../lib/india.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { moneyField } from '../lib/numbers.ts';
import { parse } from '../lib/validate.ts';
import { partyBalances } from '../accounting/ledger.ts';
import { auditOf, writeAudit } from './audit.ts';

const blankToUndefined = (v: unknown) => (v === '' ? undefined : v);
const panField = z.string().trim().toUpperCase().regex(/^[A-Z]{5}[0-9]{4}[A-Z]$/, 'Invalid PAN');
const udyamField = z.string().trim().toUpperCase().regex(/^UDYAM-[A-Z]{2}-\d{2}-\d{7}$/, 'Use UDYAM-XX-00-0000000');
const pincodeField = z.string().trim().regex(/^[1-9][0-9]{5}$/, 'Pincode must be 6 digits');

const createBody = z.object({
  type: z.enum(['customer', 'vendor', 'both']),
  name: z.string().trim().min(1).max(200),
  gstin: z.preprocess(blankToUndefined, gstin.optional()),
  stateCode: z.preprocess(blankToUndefined, stateCode.optional()),
  phone: optionalText(20),
  email: z.preprocess(blankToUndefined, z.email().optional()),
  address: optionalText(500),
  creditLimit: moneyField.optional(),
  creditDays: z.coerce.number().int().min(0).max(365).optional(),
  pan: z.preprocess(blankToUndefined, panField.optional()),
  pincode: z.preprocess(blankToUndefined, pincodeField.optional()),
  udyamNo: z.preprocess(blankToUndefined, udyamField.optional()),
  msmeCategory: z.enum(['micro', 'small', 'medium']).nullable().optional(),
  tdsSectionId: z.uuid().nullable().optional(),
});
const blankToNull = (v: unknown) => (v === '' ? null : v);
const patchBody = z.object({
  type: z.enum(['customer', 'vendor', 'both']).optional(),
  name: z.string().trim().min(1).max(200).optional(),
  gstin: z.preprocess(blankToNull, gstin.nullable().optional()),
  stateCode: z.preprocess(blankToNull, stateCode.nullable().optional()),
  phone: nullableText(20),
  email: z.preprocess(blankToNull, z.email().nullable().optional()),
  address: nullableText(500),
  creditLimit: moneyField.optional(),
  creditDays: z.coerce.number().int().min(0).max(365).optional(),
  pan: z.preprocess(blankToNull, panField.nullable().optional()),
  pincode: z.preprocess(blankToNull, pincodeField.nullable().optional()),
  udyamNo: z.preprocess(blankToNull, udyamField.nullable().optional()),
  msmeCategory: z.enum(['micro', 'small', 'medium']).nullable().optional(),
  tdsSectionId: z.uuid().nullable().optional(),
});
const listQuery = pagingQuery.extend({ type: z.enum(['customer', 'vendor']).optional() });

export const partyJson = (p: Selectable<PartyTable>, balance = 0, sectionCode?: string | null) => ({
  id: p.id, companyId: p.company_id, type: p.type, name: p.name, gstin: p.gstin, stateCode: p.state_code,
  phone: p.phone, email: p.email, address: p.address, creditLimit: p.credit_limit, creditDays: p.credit_days,
  pan: p.pan, pincode: p.pincode, udyamNo: p.udyam_no, msmeCategory: p.msme_category,
  tdsSectionId: p.tds_section_id, tdsSectionCode: sectionCode ?? null, balance, createdAt: p.created_at,
});

/** Codes of the TDS sections the given parties use. */
async function sectionCodes(tx: Tx, rows: { tds_section_id: string | null }[]): Promise<Map<string, string>> {
  const ids = [...new Set(rows.map((r) => r.tds_section_id).filter((x): x is string => !!x))];
  if (!ids.length) return new Map();
  const s = await tx.selectFrom('tds_sections').select(['id', 'code']).where('id', 'in', ids).execute();
  return new Map(s.map((r) => [r.id, r.code]));
}

/** MSMED Act s.15: micro and small suppliers must be paid within 45 days. */
function checkMsme(type: string, category: string | null, creditDays: number) {
  if (type !== 'customer' && (category === 'micro' || category === 'small') && creditDays > 45) {
    throw badRequest('MSME suppliers must be paid within 45 days (MSMED Act s.15).', { creditDays: 'At most 45 for micro and small suppliers' });
  }
}

/** State code defaults to the GSTIN's first two digits and must agree with it. */
function resolveState(g: string | undefined, s: string | undefined): string | undefined {
  if (g && s && g.slice(0, 2) !== s) {
    throw badRequest('GSTIN does not match the state.', { stateCode: 'Does not match GSTIN' });
  }
  return s ?? g?.slice(0, 2);
}

export async function partyRoutes(app: FastifyInstance) {
  app.get('/parties', async (req) => {
    const ctx = req.ctx;
    ctx.require('parties.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('parties').where('company_id', '=', ctx.companyId);
      if (q.type) base = base.where('type', 'in', [q.type, 'both']);
      if (q.q) {
        const term = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('name', 'ilike', term), eb('gstin', 'ilike', term), eb('phone', 'ilike', term)]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll().orderBy('name').limit(q.limit).offset(q.offset).execute();
      const bal = await partyBalances(tx, ctx.companyId, rows.map((r) => r.id));
      const codes = await sectionCodes(tx, rows);
      return { data: rows.map((r) => partyJson(r, bal.get(r.id) ?? 0, codes.get(r.tds_section_id ?? ''))), total };
    });
  });

  app.get<{ Params: { id: string } }>('/parties/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('parties.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const party = await tx.selectFrom('parties').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!party) throw notFound('Party');
      return partyJson(party, (await partyBalances(tx, ctx.companyId, [id])).get(id) ?? 0, (await sectionCodes(tx, [party])).get(party.tds_section_id ?? ''));
    });
  });

  app.post('/parties', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('parties.create');
    const body = parse(createBody, req.body);
    const state = resolveState(body.gstin, body.stateCode);
    const party = await ctx.tx(async (tx) => {
      checkMsme(body.type, body.msmeCategory ?? null, body.creditDays ?? 0);
      const row = await tx.insertInto('parties').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, type: body.type, name: body.name, gstin: body.gstin ?? null,
        state_code: state ?? null, phone: body.phone ?? null, email: body.email ?? null, address: body.address ?? null,
        credit_limit: body.creditLimit ?? 0, credit_days: body.creditDays ?? 0, pan: body.pan ?? null, pincode: body.pincode ?? null,
        udyam_no: body.udyamNo ?? null, msme_category: body.msmeCategory ?? null, tds_section_id: body.tdsSectionId ?? null,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'party', row.id, 'create', null, row);
      return row;
    });
    const code = (await ctx.tx((tx) => sectionCodes(tx, [party]))).get(party.tds_section_id ?? '');
    return reply.status(201).send(partyJson(party, 0, code));
  });

  app.patch<{ Params: { id: string } }>('/parties/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('parties.edit');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const before = await tx.selectFrom('parties').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!before) throw notFound('Party');
      // GSTIN decides the state when present; otherwise the state is kept or set explicitly.
      const gstinNext = body.gstin !== undefined ? body.gstin : before.gstin;
      let stateNext = body.stateCode !== undefined ? body.stateCode : body.gstin ? body.gstin.slice(0, 2) : before.state_code;
      if (gstinNext) {
        if (stateNext && stateNext !== gstinNext.slice(0, 2)) {
          throw badRequest('GSTIN does not match the state.', { stateCode: 'Does not match GSTIN' });
        }
        stateNext = gstinNext.slice(0, 2);
      }
      checkMsme(body.type ?? before.type, body.msmeCategory !== undefined ? body.msmeCategory : before.msme_category,
        body.creditDays ?? before.credit_days);
      const changes = definedOnly({
        udyam_no: body.udyamNo, msme_category: body.msmeCategory, tds_section_id: body.tdsSectionId,
        type: body.type, name: body.name, gstin: body.gstin, phone: body.phone, email: body.email,
        address: body.address, credit_limit: body.creditLimit, credit_days: body.creditDays, pan: body.pan, pincode: body.pincode,
      });
      const stateChanged = stateNext !== before.state_code;
      if (!Object.keys(changes).length && !stateChanged) return partyJson(before, (await partyBalances(tx, ctx.companyId, [id])).get(id) ?? 0, (await sectionCodes(tx, [before])).get(before.tds_section_id ?? ''));
      const after = await tx.updateTable('parties').set({ ...changes, state_code: stateNext })
        .where('id', '=', id).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'party', id, 'update', before, after);
      return partyJson(after, (await partyBalances(tx, ctx.companyId, [id])).get(id) ?? 0, (await sectionCodes(tx, [after])).get(after.tds_section_id ?? ''));
    });
  });
}
