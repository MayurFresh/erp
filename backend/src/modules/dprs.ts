import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { nullableText, optionalText } from '../lib/india.ts';
import { qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { parse, docDate } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { fileUrl, requireFiles } from './files.ts';
import { getLocation } from './locations.ts';
import { boqLinesAt } from './projects.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const STATUSES = ['draft', 'submitted', 'approved', 'rejected'] as const;
const reasonBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });

const workItem = z.object({
  boqLineId: z.uuid().nullable().optional(),
  description: z.string().trim().min(1, 'Required').max(500),
  qty: qtyField.refine((v) => v > 0, 'Must be more than zero').nullable().optional(),
  unit: z.preprocess((v) => (v === '' ? null : v), z.string().trim().max(20).nullable().optional()),
});
const labourItem = z.object({
  trade: z.string().trim().min(1, 'Required').max(60),
  count: z.number().int().min(0).max(10_000),
});
const equipmentItem = z.object({
  name: z.string().trim().min(1, 'Required').max(120),
  hours: z.number().min(0).max(10_000).refine((v) => Math.abs(v * 100 - Math.round(v * 100)) < 1e-6, 'At most 2 decimals'),
});
const photoItem = z.object({ fileId: z.uuid(), caption: optionalText(300) });

const arrays = {
  workDone: z.array(workItem).max(200).optional(),
  labour: z.array(labourItem).max(100).optional(),
  equipment: z.array(equipmentItem).max(100).optional(),
  photos: z.array(photoItem).max(50).optional(),
};
const createBody = z.object({
  locationId: z.uuid(),
  date: docDate.optional(),
  weather: optionalText(100),
  summary: optionalText(4000),
  hindrances: optionalText(4000),
  submit: z.boolean().optional(),
  ...arrays,
});
const patchBody = z.object({
  locationId: z.uuid().optional(),
  date: docDate.optional(),
  weather: nullableText(100),
  summary: nullableText(4000),
  hindrances: nullableText(4000),
  submit: z.boolean().optional(),
  ...arrays,
});
const listQuery = pagingQuery.extend({
  locationId: z.uuid().optional(),
  projectId: z.uuid().optional(),
  from: dateField.optional(),
  to: dateField.optional(),
  status: z.enum(STATUSES).optional(),
});
const previousQuery = z.object({ locationId: z.uuid() });

type WorkInput = z.infer<typeof workItem>;
type PhotoInput = z.infer<typeof photoItem>;

/** DPRs as JSON, in the order of `ids`. */
async function loadDprs(tx: Tx, ids: string[]) {
  if (!ids.length) return [];
  const rows = await tx.selectFrom('dprs as d')
    .innerJoin('locations as l', 'l.id', 'd.location_id')
    .innerJoin('users as u', 'u.id', 'd.created_by')
    .leftJoin('users as a', 'a.id', 'd.approved_by')
    .leftJoin('users as r', 'r.id', 'd.rejected_by')
    .selectAll('d')
    .select(['l.name as location_name', 'l.project_id', 'u.name as created_by_name', 'a.name as approved_by_name', 'r.name as rejected_by_name'])
    .where('d.id', 'in', ids).execute();
  const work = await tx.selectFrom('dpr_work as w').leftJoin('boq_lines as b', 'b.id', 'w.boq_line_id')
    .select(['w.id', 'w.dpr_id', 'w.boq_line_id', 'b.code as boq_code', 'w.description', 'w.qty', 'w.unit'])
    .where('w.dpr_id', 'in', ids).orderBy('w.line_no').execute();
  const photos = await tx.selectFrom('dpr_photos').select(['dpr_id', 'file_id', 'caption'])
    .where('dpr_id', 'in', ids).orderBy('line_no').execute();
  return ids.map((id) => {
    const d = rows.find((r) => r.id === id)!;
    return {
      id: d.id, locationId: d.location_id, locationName: d.location_name, projectId: d.project_id, date: d.report_date,
      weather: d.weather, status: d.status, summary: d.summary, hindrances: d.hindrances,
      workDone: work.filter((w) => w.dpr_id === id).map((w) => ({
        id: w.id, boqLineId: w.boq_line_id, boqCode: w.boq_code, description: w.description, qty: w.qty, unit: w.unit,
      })),
      labour: (d.labour ?? []) as { trade: string; count: number }[],
      equipment: (d.equipment ?? []) as { name: string; hours: number }[],
      photos: photos.filter((p) => p.dpr_id === id).map((p) => ({ fileId: p.file_id, url: fileUrl(p.file_id), caption: p.caption })),
      createdAt: d.created_at, createdBy: { id: d.created_by, name: d.created_by_name },
      submittedAt: d.submitted_at, approvedAt: d.approved_at,
      approvedBy: d.approved_by ? { id: d.approved_by, name: d.approved_by_name! } : null,
      rejectedAt: d.rejected_at, rejectReason: d.reject_reason,
      rejectedBy: d.rejected_by ? { id: d.rejected_by, name: d.rejected_by_name! } : null,
    };
  });
}

/** Locks a DPR of the active company that the caller may see. */
async function getDpr(tx: Tx, ctx: RequestContext, id: string) {
  const d = await tx.selectFrom('dprs').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId)
    .forUpdate().executeTakeFirst();
  if (!d || !ctx.canAccessLocation(d.location_id)) throw notFound('DPR');
  return d;
}

/** A site in scope that can take a DPR. */
async function dprSite(tx: Tx, ctx: RequestContext, locationId: string) {
  const location = await getLocation(tx, ctx, locationId);
  if (location.type !== 'site') throw badRequest('DPRs are written for sites.', { locationId: 'Not a site' });
  if (!location.is_active) throw badRequest('This site is inactive.', { locationId: 'Inactive' });
  return location;
}

async function requireFreeDate(tx: Tx, locationId: string, date: string, exceptId?: string) {
  let q = tx.selectFrom('dprs').select('id').where('location_id', '=', locationId).where('report_date', '=', date);
  if (exceptId) q = q.where('id', '!=', exceptId);
  if (await q.executeTakeFirst()) throw conflict(`A DPR for this site on ${date} already exists.`, 'CONFLICT', { date: 'Already reported' });
}

/** Validates work entries against the site's project and fills a missing unit from the BOQ line. */
async function prepareWork(tx: Tx, location: { project_id: string | null; name: string }, work: WorkInput[]) {
  const boq = await boqLinesAt(tx, location, work.flatMap((w, i) => (w.boqLineId ? [{ id: w.boqLineId, field: `workDone.${i}.boqLineId` }] : [])));
  return work.map((w) => ({
    boqLineId: w.boqLineId ?? null, description: w.description, qty: w.qty ?? null,
    unit: w.unit ?? (w.boqLineId ? boq.get(w.boqLineId)!.unit : null),
  }));
}

async function writeChildren(
  tx: Tx, ctx: RequestContext, dprId: string, work: Awaited<ReturnType<typeof prepareWork>> | null, photos: PhotoInput[] | null,
) {
  if (work) {
    await tx.deleteFrom('dpr_work').where('dpr_id', '=', dprId).execute();
    if (work.length) {
      await tx.insertInto('dpr_work').values(work.map((w, i) => ({
        tenant_id: ctx.tenantId, dpr_id: dprId, line_no: i + 1, boq_line_id: w.boqLineId, description: w.description, qty: w.qty, unit: w.unit,
      }))).execute();
    }
  }
  if (photos) {
    await tx.deleteFrom('dpr_photos').where('dpr_id', '=', dprId).execute();
    if (photos.length) {
      await tx.insertInto('dpr_photos').values(photos.map((p, i) => ({
        tenant_id: ctx.tenantId, dpr_id: dprId, line_no: i + 1, file_id: p.fileId, caption: p.caption ?? null,
      }))).execute();
    }
  }
}

const photoRefs = (photos: PhotoInput[]) => photos.map((p, i) => ({ id: p.fileId, field: `photos.${i}.fileId` }));

export async function dprRoutes(app: FastifyInstance) {
  app.get('/dprs', async (req) => {
    const ctx = req.ctx;
    ctx.require('dpr.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('dprs as d').innerJoin('locations as l', 'l.id', 'd.location_id')
        .where('d.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('d.location_id', 'in', scope);
      if (q.locationId) base = base.where('d.location_id', '=', q.locationId);
      if (q.projectId) base = base.where('l.project_id', '=', q.projectId);
      if (q.from) base = base.where('d.report_date', '>=', q.from);
      if (q.to) base = base.where('d.report_date', '<=', q.to);
      if (q.status) base = base.where('d.status', '=', q.status);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('d.summary', 'ilike', t), eb('d.hindrances', 'ilike', t), eb('l.name', 'ilike', t)]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('d.id').orderBy('d.report_date', 'desc').orderBy('d.created_at', 'desc')
        .limit(q.limit).offset(q.offset).execute();
      return { data: await loadDprs(tx, ids.map((r) => r.id)), total };
    });
  });

  app.get('/dprs/previous', async (req) => {
    const ctx = req.ctx;
    ctx.require('dpr.view');
    const q = parse(previousQuery, req.query);
    return ctx.tx(async (tx) => {
      await getLocation(tx, ctx, q.locationId);
      const last = await tx.selectFrom('dprs').select('id').where('company_id', '=', ctx.companyId)
        .where('location_id', '=', q.locationId).orderBy('report_date', 'desc').orderBy('created_at', 'desc')
        .limit(1).executeTakeFirst();
      if (!last) throw notFound('DPR');
      return (await loadDprs(tx, [last.id]))[0];
    });
  });

  app.get<{ Params: { id: string } }>('/dprs/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('dpr.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const d = await tx.selectFrom('dprs').select('location_id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!d || !ctx.canAccessLocation(d.location_id)) throw notFound('DPR');
      return (await loadDprs(tx, [id]))[0];
    });
  });

  app.post('/dprs', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('dpr.create');
    const body = parse(createBody, req.body);
    const saved = await ctx.tx(async (tx) => {
      const location = await dprSite(tx, ctx, body.locationId);
      const date = body.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });
      await requireFreeDate(tx, location.id, date);
      const work = await prepareWork(tx, location, body.workDone ?? []);
      await requireFiles(tx, photoRefs(body.photos ?? []), true);

      const row = await tx.insertInto('dprs').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: location.id, report_date: date,
        weather: body.weather ?? null, status: body.submit ? 'submitted' : 'draft', summary: body.summary ?? null,
        hindrances: body.hindrances ?? null, labour: JSON.stringify(body.labour ?? []),
        equipment: JSON.stringify(body.equipment ?? []), created_by: ctx.userId,
        submitted_at: body.submit ? new Date() : null, approved_by: null, approved_at: null,
      }).returning('id').executeTakeFirstOrThrow();
      await writeChildren(tx, ctx, row.id, work, body.photos ?? []);
      const dpr = (await loadDprs(tx, [row.id]))[0]!;
      await writeAudit(tx, auditOf(ctx), 'dpr', row.id, 'create', null, dpr);
      return dpr;
    });
    return reply.status(201).send(saved);
  });

  app.patch<{ Params: { id: string } }>('/dprs/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('dpr.create', 'dpr.approve');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    if (body.submit) ctx.require('dpr.create');
    return ctx.tx(async (tx) => {
      const before = await getDpr(tx, ctx, id);
      if (!ctx.can('dpr.approve') && before.created_by !== ctx.userId) {
        throw forbidden('Only the person who wrote this DPR or an approver can edit it.');
      }
      // A rejected DPR stays rejected while it is corrected, until it is resubmitted.
      if (!['draft', 'rejected'].includes(before.status)) {
        throw conflict(`This DPR is ${before.status}; only draft or rejected DPRs can be edited.`, 'CONFLICT');
      }

      const location = body.locationId && body.locationId !== before.location_id
        ? await dprSite(tx, ctx, body.locationId)
        : await getLocation(tx, ctx, before.location_id);
      const date = body.date ?? before.report_date;
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });
      if (location.id !== before.location_id || date !== before.report_date) await requireFreeDate(tx, location.id, date, id);

      // Work entries are re-checked when the site changes, since BOQ lines belong to its project.
      let workInput: WorkInput[] | undefined = body.workDone;
      if (!workInput && location.id !== before.location_id) {
        workInput = (await tx.selectFrom('dpr_work').selectAll().where('dpr_id', '=', id).orderBy('line_no').execute())
          .map((w) => ({ boqLineId: w.boq_line_id, description: w.description, qty: w.qty, unit: w.unit }));
      }
      const work = workInput ? await prepareWork(tx, location, workInput) : null;
      if (body.photos) await requireFiles(tx, photoRefs(body.photos), true);

      const old = (await loadDprs(tx, [id]))[0]!;
      const changes = Object.fromEntries(Object.entries({
        location_id: location.id !== before.location_id ? location.id : undefined,
        report_date: body.date, weather: body.weather, summary: body.summary, hindrances: body.hindrances,
        labour: body.labour ? JSON.stringify(body.labour) : undefined,
        equipment: body.equipment ? JSON.stringify(body.equipment) : undefined,
      }).filter(([, v]) => v !== undefined));
      // Submitting from here works exactly like POST /dprs/:id/submit.
      const submit = body.submit
        ? { status: 'submitted', submitted_at: new Date(), rejected_by: null, rejected_at: null, reject_reason: null }
        : {};
      await tx.updateTable('dprs').set({ ...changes, ...submit, updated_at: new Date() }).where('id', '=', id).execute();
      await writeChildren(tx, ctx, id, work, body.photos ?? null);
      const after = (await loadDprs(tx, [id]))[0]!;
      await writeAudit(tx, auditOf(ctx), 'dpr', id, 'update', old, after);
      return after;
    });
  });

  app.post<{ Params: { id: string } }>('/dprs/:id/submit', async (req) => {
    const ctx = req.ctx;
    ctx.require('dpr.create');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const d = await getDpr(tx, ctx, id);
      if (!['draft', 'rejected'].includes(d.status)) {
        throw conflict(`This DPR is ${d.status}; only draft or rejected DPRs can be submitted.`, 'CONFLICT');
      }
      await tx.updateTable('dprs').set({
        status: 'submitted', submitted_at: new Date(), updated_at: new Date(),
        rejected_by: null, rejected_at: null, reject_reason: null,
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'dpr', id, 'submit', { status: d.status }, { status: 'submitted' });
      return (await loadDprs(tx, [id]))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/dprs/:id/reject', async (req) => {
    const ctx = req.ctx;
    ctx.require('dpr.approve');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(reasonBody, req.body);
    return ctx.tx(async (tx) => {
      const d = await getDpr(tx, ctx, id);
      if (d.status !== 'submitted') {
        throw conflict(`This DPR is ${d.status}; only submitted DPRs can be rejected.`, 'CONFLICT');
      }
      await tx.updateTable('dprs').set({
        status: 'rejected', rejected_by: ctx.userId, rejected_at: new Date(), reject_reason: reason, updated_at: new Date(),
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'dpr', id, 'reject', { status: 'submitted' }, { status: 'rejected', reason });
      return (await loadDprs(tx, [id]))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/dprs/:id/approve', async (req) => {
    const ctx = req.ctx;
    ctx.require('dpr.approve');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const d = await getDpr(tx, ctx, id);
      if (d.status !== 'submitted') throw conflict(`This DPR is ${d.status}; only submitted DPRs can be approved.`, 'CONFLICT');
      await tx.updateTable('dprs').set({ status: 'approved', approved_by: ctx.userId, approved_at: new Date(), updated_at: new Date() })
        .where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'dpr', id, 'approve', { status: 'submitted' }, { status: 'approved' });
      return (await loadDprs(tx, [id]))[0];
    });
  });
}
