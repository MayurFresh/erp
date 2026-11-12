import type { FastifyInstance } from 'fastify';
import { assertFresh } from '../lib/stale.ts';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { isValidDate, todayIst, fyStart } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { parse } from '../lib/validate.ts';
import type { AppDeps } from '../app.ts';
import { auditOf, writeAudit } from './audit.ts';
import { documentRoute } from '../lib/openapi.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

const createBody = z.object({
  code: z.string().trim().min(1, 'Required').max(20),
  name: z.string().trim().min(1, 'Required').max(80),
  parentId: z.uuid().nullable().optional(),
});
const patchBody = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  name: z.string().trim().min(1).max(80).optional(),
  parentId: z.uuid().nullable().optional(),
  isActive: z.boolean().optional(),
});
const reportQuery = z.object({ from: dateField.optional(), to: dateField.optional() });

const json = (r: { id: string; code: string; name: string; parent_id: string | null; is_active: boolean; created_at: Date; updated_at: Date }) => ({
  id: r.id, code: r.code, name: r.name, parentId: r.parent_id, isActive: r.is_active, createdAt: r.created_at, updatedAt: r.updated_at,
});

/**
 * Checks the header `costCentreId` of a document: unknown or inactive is 400, and with
 * `company.costCentreRequired` a missing one is 400 `{ costCentreId: 'Required' }`.
 * `needed` is false for documents without income or expense lines.
 */
export async function resolveCostCentre(
  tx: Tx, ctx: RequestContext, id: string | null | undefined, opts: { needed?: boolean } = {},
): Promise<string | null> {
  if (id) {
    const cc = await tx.selectFrom('cost_centres').select(['id', 'is_active'])
      .where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!cc) throw badRequest('Cost centre not found.', { costCentreId: 'Not found' });
    if (!cc.is_active) throw badRequest('This cost centre is inactive.', { costCentreId: 'Inactive' });
    return cc.id;
  }
  if (opts.needed !== false) {
    const c = await tx.selectFrom('companies').select('cost_centre_required').where('id', '=', ctx.companyId).executeTakeFirst();
    if (c?.cost_centre_required) throw badRequest('Choose a cost centre.', { costCentreId: 'Required' });
  }
  return null;
}

export async function costCentreRoutes(app: FastifyInstance, _deps?: AppDeps): Promise<void> {
  app.get('/cost-centres', async (req) => {
    const ctx = req.ctx;
    const q = parse(z.object({ includeInactive: z.enum(['true', 'false']).optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('cost_centres').selectAll().where('company_id', '=', ctx.companyId);
      if (q.includeInactive !== 'true') base = base.where('is_active', '=', true);
      const rows = await base.orderBy('code').execute();
      return { data: rows.map(json) };
    });
  });

  app.post('/cost-centres', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('accounts.manage');
    const body = parse(createBody, req.body);
    const row = await ctx.tx(async (tx) => {
      if (body.parentId) {
        const p = await tx.selectFrom('cost_centres').select('id').where('id', '=', body.parentId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!p) throw badRequest('Parent not found.', { parentId: 'Not found' });
      }
      const dup = await tx.selectFrom('cost_centres').select('id').where('company_id', '=', ctx.companyId)
        .where(sql<boolean>`lower(code) = ${body.code.toLowerCase()}`).executeTakeFirst();
      if (dup) throw conflict('This code is already used.', 'CONFLICT', { code: 'Already used' });
      const r = await tx.insertInto('cost_centres').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, code: body.code, name: body.name, parent_id: body.parentId ?? null,
      }).returning(['id', 'code', 'name', 'parent_id', 'is_active', 'created_at', 'updated_at']).executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'cost_centre', r.id, 'create', null, { code: r.code, name: r.name });
      return r;
    });
    return reply.status(201).send(json(row));
  });

  app.patch<{ Params: { id: string } }>('/cost-centres/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('accounts.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const before = await tx.selectFrom('cost_centres').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!before) throw notFound('Cost centre');
      assertFresh(before.updated_at, body.expectedUpdatedAt, 'cost centre');
      if (body.parentId) {
        // Walk up from the proposed parent; meeting this centre means a loop.
        let cur: string | null = body.parentId;
        const seen = new Set<string>();
        while (cur) {
          if (cur === id) throw badRequest('That parent would make a loop.', { parentId: 'Would make a loop' });
          if (seen.has(cur)) break;
          seen.add(cur);
          const p: { parent_id: string | null } | undefined = await tx.selectFrom('cost_centres').select('parent_id')
            .where('id', '=', cur).where('company_id', '=', ctx.companyId).executeTakeFirst();
          if (!p && cur === body.parentId) throw badRequest('Parent not found.', { parentId: 'Not found' });
          cur = p?.parent_id ?? null;
        }
      }
      const set: Record<string, unknown> = {};
      if (body.name !== undefined) set.name = body.name;
      if (body.parentId !== undefined) set.parent_id = body.parentId;
      if (body.isActive !== undefined) set.is_active = body.isActive;
      const after = Object.keys(set).length
        ? await tx.updateTable('cost_centres').set(set).where('id', '=', id).returningAll().executeTakeFirstOrThrow()
        : before;
      await writeAudit(tx, auditOf(ctx), 'cost_centre', id, 'update', json(before), json(after));
      return json(after);
    });
  });

  app.get('/reports/cost-centres', async (req) => {
    const ctx = req.ctx;
    ctx.require('accounts.view');
    const q = parse(reportQuery, req.query);
    const to = q.to ?? todayIst();
    const from = q.from ?? fyStart(to);
    return ctx.tx(async (tx) => {
      const sums = await tx.selectFrom('journal_lines as jl')
        .innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
        .innerJoin('accounts as a', 'a.id', 'jl.account_id')
        .select((eb) => ['jl.cost_centre_id', 'a.type', eb.fn.sum<number>('jl.debit').as('d'), eb.fn.sum<number>('jl.credit').as('c')])
        .where('je.company_id', '=', ctx.companyId).where('je.entry_date', '>=', from).where('je.entry_date', '<=', to)
        .where('a.type', 'in', ['income', 'expense'])
        .groupBy(['jl.cost_centre_id', 'a.type']).execute();
      const centres = await tx.selectFrom('cost_centres').selectAll().where('company_id', '=', ctx.companyId).orderBy('code').execute();
      const acc = new Map<string | null, { income: number; expense: number }>();
      for (const s of sums) {
        const e = acc.get(s.cost_centre_id) ?? { income: 0, expense: 0 };
        if (s.type === 'income') e.income += Number(s.c) - Number(s.d);
        else e.expense += Number(s.d) - Number(s.c);
        acc.set(s.cost_centre_id, e);
      }
      const row = (id: string | null, code: string | null, name: string, parentId: string | null) => {
        const e = acc.get(id) ?? { income: 0, expense: 0 };
        return { costCentreId: id, code, name, parentId, income: round2(e.income), expense: round2(e.expense), net: round2(e.income - e.expense) };
      };
      const rows = centres.filter((c) => c.is_active || acc.has(c.id)).map((c) => row(c.id, c.code, c.name, c.parent_id));
      const untagged = row(null, null, 'Untagged', null);
      if (untagged.income !== 0 || untagged.expense !== 0) rows.push(untagged);
      const income = round2(rows.reduce((s, r) => s + r.income, 0));
      const expense = round2(rows.reduce((s, r) => s + r.expense, 0));
      return { from, to, rows, totals: { income, expense, net: round2(income - expense) } };
    });
  });
}

documentRoute('POST', '/cost-centres', { body: createBody });
documentRoute('PATCH', '/cost-centres/:id', { body: patchBody });
