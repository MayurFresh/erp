import type { FastifyInstance } from 'fastify';
import type { Selectable } from 'kysely';
import { z } from 'zod';
import type { GstRateTable, TdsSectionTable } from '../db/schema.ts';
import { isValidDate, todayIst } from '../lib/dates.ts';
import { forbidden, notFound } from '../lib/errors.ts';
import { moneyField, percentField } from '../lib/numbers.ts';
import { calcTds } from '../lib/tds.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const bool = z.enum(['true', 'false']).transform((v) => v === 'true');

const gstRateJson = (r: Selectable<GstRateTable>) => ({
  id: r.id, rate: Number(r.rate), kind: r.kind, label: r.label, effectiveFrom: r.effective_from, effectiveTo: r.effective_to,
  isLegacy: r.is_legacy, isSystem: r.tenant_id === null,
});

export const tdsSectionJson = (s: Selectable<TdsSectionTable>) => ({
  id: s.id, code: s.code, newRef: s.new_ref, name: s.name, rateIndividual: Number(s.rate_individual), rateOther: Number(s.rate_other),
  rateNoPan: Number(s.rate_no_pan), thresholdSingle: s.threshold_single === null ? null : Number(s.threshold_single),
  thresholdAggregate: s.threshold_aggregate === null ? null : Number(s.threshold_aggregate), aggregateMode: s.aggregate_mode,
  effectiveFrom: s.effective_from, effectiveTo: s.effective_to, verified: s.verified, isActive: s.is_active,
  isSystem: s.tenant_id === null,
});

const gstListQuery = z.object({
  date: dateField.optional(), kind: z.enum(['goods', 'services']).optional(), includeLegacy: bool.optional(),
});
const gstCreate = z.object({
  rate: percentField, kind: z.enum(['any', 'goods', 'services']), label: z.string().trim().min(1).max(120),
  effectiveFrom: dateField, effectiveTo: dateField.nullable().optional(),
});
const gstPatch = z.object({ effectiveTo: dateField.nullable(), label: z.string().trim().min(1).max(120).optional() });

const tdsListQuery = z.object({ date: dateField.optional(), activeOnly: bool.optional() });
const rate = z.coerce.number().min(0).max(100);
const tdsCreate = z.object({
  code: z.string().trim().min(2).max(20), newRef: z.string().trim().max(60).nullable().optional(),
  name: z.string().trim().min(2).max(160), rateIndividual: rate, rateOther: rate, rateNoPan: rate,
  thresholdSingle: moneyField.nullable().optional(), thresholdAggregate: moneyField.nullable().optional(),
  aggregateMode: z.enum(['whole', 'excess']), effectiveFrom: dateField, effectiveTo: dateField.nullable().optional(),
  verified: z.boolean().optional(), isActive: z.boolean().optional(),
});
const tdsPatch = z.object({
  effectiveTo: dateField.nullable().optional(), isActive: z.boolean().optional(), name: z.string().trim().min(2).max(160).optional(),
});
const previewBody = z.object({
  partyId: z.uuid(), sectionId: z.uuid(), date: dateField, gross: moneyField, excludeSourceId: z.uuid().nullable().optional(),
});

export async function taxMasterRoutes(app: FastifyInstance) {
  app.get('/gst-rates', async (req) => {
    const ctx = req.ctx;
    const q = parse(gstListQuery, req.query);
    const date = q.date ?? todayIst();
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('gst_rates').selectAll()
        .where('effective_from', '<=', date)
        .where((eb) => eb.or([eb('effective_to', 'is', null), eb('effective_to', '>=', date)]));
      if (!q.includeLegacy) base = base.where('is_legacy', '=', false);
      if (q.kind) base = base.where('kind', 'in', ['any', q.kind]);
      const rows = await base.orderBy('rate').orderBy('kind').execute();
      return { data: rows.map(gstRateJson) };
    });
  });

  app.post('/gst-rates', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('gst.manage');
    const b = parse(gstCreate, req.body);
    const row = await ctx.tx(async (tx) => {
      const r = await tx.insertInto('gst_rates').values({
        tenant_id: ctx.tenantId, rate: b.rate, kind: b.kind, label: b.label, effective_from: b.effectiveFrom,
        effective_to: b.effectiveTo ?? null, is_legacy: false,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'gst_rate', r.id, 'create', null, r);
      return r;
    });
    return reply.status(201).send(gstRateJson(row));
  });

  app.patch<{ Params: { id: string } }>('/gst-rates/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(gstPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await tx.selectFrom('gst_rates').selectAll().where('id', '=', id).executeTakeFirst();
      if (!before) throw notFound('GST rate');
      if (before.tenant_id === null) throw forbidden('System GST rates cannot be changed.');
      const after = await tx.updateTable('gst_rates').set({ effective_to: b.effectiveTo, ...(b.label ? { label: b.label } : {}) })
        .where('id', '=', id).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'gst_rate', id, 'update', before, after);
      return gstRateJson(after);
    });
  });

  app.get('/tds-sections', async (req) => {
    const ctx = req.ctx;
    const q = parse(tdsListQuery, req.query);
    const date = q.date ?? todayIst();
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('tds_sections').selectAll()
        .where('effective_from', '<=', date)
        .where((eb) => eb.or([eb('effective_to', 'is', null), eb('effective_to', '>=', date)]));
      if (q.activeOnly) base = base.where('is_active', '=', true);
      return { data: (await base.orderBy('code').execute()).map(tdsSectionJson) };
    });
  });

  app.post('/tds-sections', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('tds.manage');
    const b = parse(tdsCreate, req.body);
    const row = await ctx.tx(async (tx) => {
      const r = await tx.insertInto('tds_sections').values({
        tenant_id: ctx.tenantId, code: b.code, new_ref: b.newRef ?? null, name: b.name, rate_individual: b.rateIndividual,
        rate_other: b.rateOther, rate_no_pan: b.rateNoPan, threshold_single: b.thresholdSingle ?? null,
        threshold_aggregate: b.thresholdAggregate ?? null, aggregate_mode: b.aggregateMode, effective_from: b.effectiveFrom,
        effective_to: b.effectiveTo ?? null, verified: b.verified ?? false, is_active: b.isActive ?? true,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'tds_section', r.id, 'create', null, r);
      return r;
    });
    return reply.status(201).send(tdsSectionJson(row));
  });

  app.patch<{ Params: { id: string } }>('/tds-sections/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(tdsPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await tx.selectFrom('tds_sections').selectAll().where('id', '=', id).executeTakeFirst();
      if (!before) throw notFound('TDS section');
      if (before.tenant_id === null) throw forbidden('System TDS sections cannot be changed.');
      const set: Record<string, unknown> = {};
      if (b.effectiveTo !== undefined) set.effective_to = b.effectiveTo;
      if (b.isActive !== undefined) set.is_active = b.isActive;
      if (b.name !== undefined) set.name = b.name;
      const after = Object.keys(set).length
        ? await tx.updateTable('tds_sections').set(set).where('id', '=', id).returningAll().executeTakeFirstOrThrow()
        : before;
      await writeAudit(tx, auditOf(ctx), 'tds_section', id, 'update', before, after);
      return tdsSectionJson(after);
    });
  });

  app.post('/tds/preview', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchases.create', 'expenses.create', 'tds.view');
    const b = parse(previewBody, req.body);
    return ctx.tx((tx) => calcTds(tx, ctx.companyId, b));
  });
}
