import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AppDeps } from '../app.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { documentRoute } from '../lib/openapi.ts';

const ENTITIES = ['item', 'party', 'invoice', 'purchase', 'project'] as const;
const option = z.string().trim().min(1).max(60);
const options = z.array(option).min(1, 'Add at least one option').max(50);

const createBody = z.object({
  entity: z.enum(ENTITIES),
  key: z.string().regex(/^[a-z][a-z0-9_]{1,29}$/, 'Use lowercase letters, digits and underscores (2–30)'),
  label: z.string().trim().min(1).max(60),
  type: z.enum(['text', 'number', 'date', 'boolean', 'select']),
  options: options.optional(),
  required: z.boolean().optional(),
  showOnPrint: z.boolean().optional(),
  sortOrder: z.number().int().min(0).max(10000).optional(),
});
const patchBody = z.object({
  label: z.string().trim().min(1).max(60).optional(),
  options: options.optional(),
  required: z.boolean().optional(),
  showOnPrint: z.boolean().optional(),
  sortOrder: z.number().int().min(0).max(10000).optional(),
  isActive: z.boolean().optional(),
});
const listQuery = z.object({ entity: z.enum(ENTITIES).optional(), includeInactive: z.enum(['true', 'false']).optional() });

type Row = {
  id: string; entity: string; key: string; label: string; type: string; options: string[]; required: boolean;
  show_on_print: boolean; sort_order: number; is_active: boolean; created_at: Date;
};
const json = (r: Row) => ({
  id: r.id, entity: r.entity, key: r.key, label: r.label, type: r.type, options: r.options, required: r.required,
  showOnPrint: r.show_on_print, sortOrder: r.sort_order, isActive: r.is_active, createdAt: r.created_at,
});

/** Custom field definitions (v1.7 §8). */
export async function customFieldRoutes(app: FastifyInstance, _deps?: AppDeps): Promise<void> {
  app.get('/custom-fields', async (req) => {
    const ctx = req.ctx;
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('custom_fields').selectAll().where('company_id', '=', ctx.companyId);
      if (q.entity) base = base.where('entity', '=', q.entity);
      if (q.includeInactive !== 'true') base = base.where('is_active', '=', true);
      const rows = await base.orderBy('sort_order').orderBy('label').execute();
      return { data: rows.map(json) };
    });
  });

  app.post('/custom-fields', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('company.manage');
    const body = parse(createBody, req.body);
    if (body.type === 'select' && !body.options) throw badRequest('Add the options to choose from.', { options: 'Required' });
    const row = await ctx.tx(async (tx) => {
      const dup = await tx.selectFrom('custom_fields').select('id')
        .where('company_id', '=', ctx.companyId).where('entity', '=', body.entity).where('key', '=', body.key).executeTakeFirst();
      if (dup) throw conflict('This key is already used for this record type.', 'CONFLICT', { key: 'Already used' });
      const active = await tx.selectFrom('custom_fields').select((eb) => eb.fn.countAll<number>().as('n'))
        .where('company_id', '=', ctx.companyId).where('entity', '=', body.entity).where('is_active', '=', true).executeTakeFirstOrThrow();
      if (Number(active.n) >= 25) throw badRequest('At most 25 active fields per record type.', { entity: 'Limit reached' });
      const r = await tx.insertInto('custom_fields').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, entity: body.entity, key: body.key, label: body.label, type: body.type,
        options: body.type === 'select' ? body.options! : [], required: body.required ?? false,
        show_on_print: body.showOnPrint ?? false, sort_order: body.sortOrder ?? 0,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'custom_field', r.id, 'create', null, { entity: r.entity, key: r.key, type: r.type });
      return r;
    });
    return reply.status(201).send(json(row));
  });

  app.patch<{ Params: { id: string } }>('/custom-fields/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('company.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const before = await tx.selectFrom('custom_fields').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!before) throw notFound('Custom field');
      if (body.options && before.type !== 'select') throw badRequest('Only select fields have options.', { options: 'Not a select field' });
      if (body.isActive === true && !before.is_active) {
        const active = await tx.selectFrom('custom_fields').select((eb) => eb.fn.countAll<number>().as('n'))
          .where('company_id', '=', ctx.companyId).where('entity', '=', before.entity).where('is_active', '=', true).executeTakeFirstOrThrow();
        if (Number(active.n) >= 25) throw badRequest('At most 25 active fields per record type.', { isActive: 'Limit reached' });
      }
      const set: Record<string, unknown> = { updated_at: new Date() };
      if (body.label !== undefined) set.label = body.label;
      if (body.options !== undefined) set.options = body.options;
      if (body.required !== undefined) set.required = body.required;
      if (body.showOnPrint !== undefined) set.show_on_print = body.showOnPrint;
      if (body.sortOrder !== undefined) set.sort_order = body.sortOrder;
      if (body.isActive !== undefined) set.is_active = body.isActive;
      const after = await tx.updateTable('custom_fields').set(set).where('id', '=', id).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'custom_field', id, 'update', json(before), json(after));
      return json(after);
    });
  });
}

documentRoute('POST', '/custom-fields', { body: createBody });
documentRoute('PATCH', '/custom-fields/:id', { body: patchBody });
