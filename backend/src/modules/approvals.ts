import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { AppDeps } from '../app.ts';
import { contextFor, type RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, todayIst } from '../lib/dates.ts';
import { AppError, badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { notify } from '../lib/notify.ts';
import { moneyField } from '../lib/numbers.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { documentRoute } from '../lib/openapi.ts';

export type ApprovalDocType = 'purchase' | 'payment' | 'expense' | 'journal' | 'credit_note' | 'purchase_order';
const DOC_TYPES = ['purchase', 'payment', 'expense', 'journal', 'credit_note', 'purchase_order'] as const;
const round2 = (n: number) => Math.round(n * 100) / 100;

let appUrl = '';

// ---- Covered creates ---------------------------------------------------------------------------------

/** What the rule match and the request summary need to know about a document. */
export interface DocInfo { amount: number; date: string; partyId: string | null; locationId: string | null; narration: string | null }

interface Executor {
  /** Permission the requester must still hold when the final approval creates the document. */
  permission: string;
  create: (ctx: RequestContext, tx: Tx, payload: unknown) => Promise<{ id: string; number: string | null }>;
  /** Called when the request is rejected or cancelled (a draft document returns to draft). */
  onDecline?: (ctx: RequestContext, tx: Tx, payload: unknown) => Promise<void>;
}
const executors = new Map<ApprovalDocType, Executor>();

/** Each covered module registers how to create its document from a stored payload. */
export function registerApprovalDoc(docType: ApprovalDocType, ex: Executor): void {
  executors.set(docType, ex);
}

interface LevelSnap { level: number; approverRoleId: string | null; approverUserId: string | null; label: string }

async function activeRules(tx: Tx, companyId: string, docType: ApprovalDocType) {
  const rules = await tx.selectFrom('approval_rules').selectAll()
    .where('company_id', '=', companyId).where('doc_type', '=', docType).where('is_active', '=', true).execute();
  return rules;
}

/**
 * Runs a covered create. With no matching rule the document is created at once. Otherwise the create runs as a
 * dry run inside a savepoint (so a request that would fail is rejected now), is rolled back, and the request is stored.
 */
export async function createOrSubmit<T>(
  ctx: RequestContext, tx: Tx, docType: ApprovalDocType, body: unknown,
  create: (tx: Tx) => Promise<T>, info: (doc: T) => DocInfo,
): Promise<{ doc: T; request?: undefined } | { doc?: undefined; request: Awaited<ReturnType<typeof loadRequest>> }> {
  const rules = await activeRules(tx, ctx.companyId, docType);
  if (!rules.length) return { doc: await create(tx) };

  await sql`savepoint approval_dry_run`.execute(tx);
  const dry = info(await create(tx));
  await sql`rollback to savepoint approval_dry_run`.execute(tx);
  await sql`release savepoint approval_dry_run`.execute(tx);

  const r = await storeRequest(ctx, tx, docType, body, dry, rules);
  if (!r) return { doc: await create(tx) };
  return { request: r };
}

/**
 * For documents that already exist (a draft purchase order): stores an approval request when a rule matches
 * `info` and returns it, or returns null when no rule applies.
 */
export async function requestApproval(
  ctx: RequestContext, tx: Tx, docType: ApprovalDocType, payload: unknown, info: DocInfo,
) {
  return storeRequest(ctx, tx, docType, payload, info, await activeRules(tx, ctx.companyId, docType));
}

async function storeRequest(
  ctx: RequestContext, tx: Tx, docType: ApprovalDocType, body: unknown, dry: DocInfo,
  rules: Awaited<ReturnType<typeof activeRules>>,
) {
  const matching = rules
    .filter((r) => r.min_amount <= dry.amount + 0.0001 && (r.location_id === null || r.location_id === dry.locationId))
    .sort((a, b) => b.min_amount - a.min_amount || (b.location_id ? 1 : 0) - (a.location_id ? 1 : 0));
  const rule = matching[0];
  if (!rule) return null;

  const levels = await tx.selectFrom('approval_rule_levels').selectAll().where('rule_id', '=', rule.id).orderBy('level').execute();
  const snap = await snapshotLevels(tx, levels);
  const number = await nextNumber(tx, ctx, 'approval_request', financialYear(dry.date));
  const row = await tx.insertInto('approval_requests').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, number, doc_type: docType, amount: dry.amount, doc_date: dry.date,
    party_id: dry.partyId, location_id: dry.locationId, narration: dry.narration, payload: JSON.stringify(body),
    rule_id: rule.id, rule_name: rule.name, levels: JSON.stringify(snap), total_levels: snap.length, requested_by: ctx.userId,
  }).returningAll().executeTakeFirstOrThrow();
  await tx.insertInto('approval_actions').values({
    tenant_id: ctx.tenantId, request_id: row.id, level: null, action: 'submitted', user_id: ctx.userId, comment: null,
  }).execute();
  await writeAudit(tx, auditOf(ctx), 'approval_request', row.id, 'submit', null, { number, docType, amount: dry.amount, rule: rule.name });
  await notifyLevel(tx, ctx, row, snap, 1);
  return loadRequest(tx, ctx, row.id, true);
}

async function snapshotLevels(
  tx: Tx, levels: { level: number; approver_role_id: string | null; approver_user_id: string | null }[],
): Promise<LevelSnap[]> {
  const roleIds = levels.map((l) => l.approver_role_id).filter((x): x is string => !!x);
  const userIds = levels.map((l) => l.approver_user_id).filter((x): x is string => !!x);
  const roles = roleIds.length ? await tx.selectFrom('roles').select(['id', 'name']).where('id', 'in', roleIds).execute() : [];
  const users = userIds.length ? await tx.selectFrom('users').select(['id', 'name']).where('id', 'in', userIds).execute() : [];
  return levels.map((l) => ({
    level: l.level, approverRoleId: l.approver_role_id, approverUserId: l.approver_user_id,
    label: (l.approver_role_id ? roles.find((r) => r.id === l.approver_role_id)?.name : users.find((u) => u.id === l.approver_user_id)?.name) ?? '',
  }));
}

/** Active users who may act at a level of a request. */
async function qualifiers(tx: Tx, companyId: string, lv: LevelSnap): Promise<string[]> {
  if (lv.approverUserId) {
    const m = await tx.selectFrom('user_roles as ur').innerJoin('users as u', 'u.id', 'ur.user_id')
      .select('ur.user_id').where('ur.company_id', '=', companyId).where('ur.user_id', '=', lv.approverUserId).where('u.is_active', '=', true).execute();
    return [...new Set(m.map((x) => x.user_id))];
  }
  const today = todayIst();
  const rows = await tx.selectFrom('user_roles as ur').innerJoin('users as u', 'u.id', 'ur.user_id')
    .select('ur.user_id').where('ur.company_id', '=', companyId).where('ur.role_id', '=', lv.approverRoleId!).where('u.is_active', '=', true)
    .where((eb) => eb.or([eb('ur.valid_from', 'is', null), eb('ur.valid_from', '<=', sql<string>`${today}::date`)]))
    .where((eb) => eb.or([eb('ur.valid_to', 'is', null), eb('ur.valid_to', '>=', sql<string>`${today}::date`)]))
    .execute();
  return [...new Set(rows.map((x) => x.user_id))];
}

type RequestRow = {
  id: string; number: string; doc_type: string; amount: number; party_id: string | null; requested_by: string; levels: unknown;
};

async function notifyLevel(tx: Tx, ctx: RequestContext, row: RequestRow, levels: LevelSnap[], level: number) {
  const lv = levels.find((l) => l.level === level);
  if (!lv) return;
  const users = (await qualifiers(tx, ctx.companyId, lv)).filter((u) => u !== row.requested_by);
  if (!users.length) return;
  const party = row.party_id ? await tx.selectFrom('parties').select('name').where('id', '=', row.party_id).executeTakeFirst() : undefined;
  const requester = await tx.selectFrom('users').select('name').where('id', '=', row.requested_by).executeTakeFirst();
  await notify(tx, { tenantId: ctx.tenantId, companyId: ctx.companyId }, {
    userIds: users, template: 'approval_requested', link: `/approvals/${row.id}`,
    data: {
      docType: row.doc_type, amount: row.amount, number: row.number, requestedBy: requester?.name ?? '', partyName: party?.name ?? null,
      level: levels.length > 1 ? level : null, url: appUrl ? `${appUrl}/approvals/${row.id}` : null,
    },
  });
}

// ---- JSON ------------------------------------------------------------------------------------------

const qualifies = (ctx: RequestContext, lv: LevelSnap | undefined) =>
  !!lv && ((lv.approverUserId !== null && lv.approverUserId === ctx.userId)
    || (lv.approverRoleId !== null && ctx.company.roles.some((r) => r.id === lv.approverRoleId)));

async function loadRequest(tx: Tx, ctx: RequestContext, id: string, detail: boolean) {
  const r = await tx.selectFrom('approval_requests as a')
    .innerJoin('users as u', 'u.id', 'a.requested_by')
    .leftJoin('parties as p', 'p.id', 'a.party_id')
    .leftJoin('locations as l', 'l.id', 'a.location_id')
    .selectAll('a').select(['u.name as requester_name', 'p.name as party_name', 'l.name as location_name'])
    .where('a.id', '=', id).where('a.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!r) throw notFound('Approval request');
  const levels = r.levels as LevelSnap[];
  const acts = await tx.selectFrom('approval_actions as x').innerJoin('users as u', 'u.id', 'x.user_id')
    .select(['x.level', 'x.action', 'x.user_id', 'u.name', 'x.comment', 'x.created_at'])
    .where('x.request_id', '=', id).orderBy('x.created_at').orderBy('x.id').execute();
  const acted = acts.some((a) => a.action === 'approved' && a.user_id === ctx.userId);
  const canAct = r.status === 'pending' && r.requested_by !== ctx.userId && !acted && qualifies(ctx, levels.find((l) => l.level === r.current_level));
  const base = {
    id: r.id, number: r.number, docType: r.doc_type, status: r.status, amount: r.amount,
    summary: { date: r.doc_date, partyName: r.party_name, locationName: r.location_name, narration: r.narration },
    ruleId: r.rule_id, ruleName: r.rule_name, levels, currentLevel: r.current_level, totalLevels: r.total_levels,
    requestedBy: { id: r.requested_by, name: r.requester_name }, requestedAt: r.requested_at, canAct,
    document: r.document_id ? { type: r.doc_type, id: r.document_id, number: r.document_number } : null,
    decidedAt: r.decided_at,
  };
  if (!detail) return { ...base, payload: undefined, actions: undefined } as unknown as typeof full;
  const full = {
    ...base, payload: r.payload as object,
    actions: acts.map((a) => ({ level: a.level, action: a.action, by: { id: a.user_id, name: a.name }, comment: a.comment, at: a.created_at })),
  };
  return full;
}

async function ruleJson(tx: Tx, ruleIds: string[]) {
  if (!ruleIds.length) return [];
  const rules = await tx.selectFrom('approval_rules as r').leftJoin('locations as l', 'l.id', 'r.location_id')
    .selectAll('r').select('l.name as location_name').where('r.id', 'in', ruleIds).execute();
  const lv = await tx.selectFrom('approval_rule_levels').selectAll().where('rule_id', 'in', ruleIds).orderBy('level').execute();
  const snaps = await snapshotLevels(tx, lv);
  return rules.map((r) => ({
    id: r.id, docType: r.doc_type, name: r.name, minAmount: r.min_amount, locationId: r.location_id, locationName: r.location_name,
    isActive: r.is_active, createdAt: r.created_at, updatedAt: r.updated_at,
    levels: lv.map((l, i) => ({ l, s: snaps[i]! })).filter((x) => x.l.rule_id === r.id).map((x) => x.s),
  }));
}

// ---- Routes ------------------------------------------------------------------------------------------

const levelInput = z.union([
  z.object({ approverRoleId: z.uuid() }).strict(),
  z.object({ approverUserId: z.uuid() }).strict(),
]);
const ruleFields = {
  docType: z.enum(DOC_TYPES),
  name: z.string().trim().min(1).max(80),
  minAmount: moneyField,
  locationId: z.uuid().nullable().optional(),
  levels: z.array(levelInput).min(1, 'Add at least one level').max(5, 'At most 5 levels'),
};
const createRule = z.object(ruleFields);
const patchRule = z.object({ ...ruleFields, isActive: z.boolean() }).partial();
const listQuery = z.object({
  scope: z.enum(['awaiting_me', 'mine', 'all']).optional(),
  status: z.enum(['pending', 'approved', 'rejected', 'cancelled']).optional(),
  docType: z.enum(DOC_TYPES).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});
const commentBody = z.object({ comment: z.string().trim().max(500).optional() });
const rejectBody = z.object({ comment: z.string().trim().min(3, 'Give a reason').max(500) });

async function checkRule(tx: Tx, ctx: RequestContext, b: { locationId?: string | null; levels?: z.infer<typeof levelInput>[] }) {
  if (b.locationId) {
    const l = await tx.selectFrom('locations').select('id').where('id', '=', b.locationId).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!l) throw badRequest('Location not found.', { locationId: 'Not found' });
  }
  for (const [i, lv] of (b.levels ?? []).entries()) {
    if ('approverRoleId' in lv) {
      const h = await tx.selectFrom('user_roles').select('id').where('company_id', '=', ctx.companyId).where('role_id', '=', lv.approverRoleId).limit(1).executeTakeFirst();
      if (!h) throw badRequest(`Level ${i + 1}: that role has no access to this company.`, { [`levels.${i}.approverRoleId`]: 'No access' });
    } else {
      const h = await tx.selectFrom('user_roles').select('id').where('company_id', '=', ctx.companyId).where('user_id', '=', lv.approverUserId).limit(1).executeTakeFirst();
      if (!h) throw badRequest(`Level ${i + 1}: that user has no access to this company.`, { [`levels.${i}.approverUserId`]: 'No access' });
    }
  }
}

async function setLevels(tx: Tx, ctx: RequestContext, ruleId: string, levels: z.infer<typeof levelInput>[]) {
  await tx.deleteFrom('approval_rule_levels').where('rule_id', '=', ruleId).execute();
  await tx.insertInto('approval_rule_levels').values(levels.map((lv, i) => ({
    tenant_id: ctx.tenantId, rule_id: ruleId, level: i + 1,
    approver_role_id: 'approverRoleId' in lv ? lv.approverRoleId : null, approver_user_id: 'approverUserId' in lv ? lv.approverUserId : null,
  }))).execute();
}

/** Approval rules and requests (v1.7 §7). */
export async function approvalRoutes(app: FastifyInstance, deps: AppDeps): Promise<void> {
  appUrl = deps.config.APP_URL;

  app.get('/approval-rules', async (req) => {
    const ctx = req.ctx;
    ctx.require('approvals.manage');
    const q = parse(z.object({ docType: z.enum(DOC_TYPES).optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('approval_rules').select('id').where('company_id', '=', ctx.companyId);
      if (q.docType) base = base.where('doc_type', '=', q.docType);
      const ids = (await base.orderBy('doc_type').orderBy('min_amount').execute()).map((r) => r.id);
      const rules = await ruleJson(tx, ids);
      return { data: ids.map((id) => rules.find((r) => r.id === id)!) };
    });
  });

  app.post('/approval-rules', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('approvals.manage');
    const body = parse(createRule, req.body);
    const rule = await ctx.tx(async (tx) => {
      await checkRule(tx, ctx, body);
      const row = await tx.insertInto('approval_rules').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, doc_type: body.docType, name: body.name, min_amount: body.minAmount,
        location_id: body.locationId ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await setLevels(tx, ctx, row.id, body.levels);
      const saved = (await ruleJson(tx, [row.id]))[0]!;
      await writeAudit(tx, auditOf(ctx), 'approval_rule', row.id, 'create', null, saved);
      return saved;
    });
    return reply.status(201).send(rule);
  });

  app.patch<{ Params: { id: string } }>('/approval-rules/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('approvals.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchRule, req.body);
    return ctx.tx(async (tx) => {
      const cur = await tx.selectFrom('approval_rules').select('id').where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!cur) throw notFound('Approval rule');
      await checkRule(tx, ctx, body);
      const before = (await ruleJson(tx, [id]))[0]!;
      const set: Record<string, unknown> = { updated_at: new Date() };
      if (body.docType !== undefined) set.doc_type = body.docType;
      if (body.name !== undefined) set.name = body.name;
      if (body.minAmount !== undefined) set.min_amount = body.minAmount;
      if (body.locationId !== undefined) set.location_id = body.locationId;
      if (body.isActive !== undefined) set.is_active = body.isActive;
      await tx.updateTable('approval_rules').set(set).where('id', '=', id).execute();
      if (body.levels) await setLevels(tx, ctx, id, body.levels);
      const after = (await ruleJson(tx, [id]))[0]!;
      await writeAudit(tx, auditOf(ctx), 'approval_rule', id, 'update', before, after);
      return after;
    });
  });

  app.delete<{ Params: { id: string } }>('/approval-rules/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('approvals.manage');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const r = await tx.updateTable('approval_rules').set({ is_active: false, updated_at: new Date() })
        .where('id', '=', id).where('company_id', '=', ctx.companyId).returning('id').executeTakeFirst();
      if (!r) throw notFound('Approval rule');
      await writeAudit(tx, auditOf(ctx), 'approval_rule', id, 'deactivate');
    });
    return reply.status(204).send();
  });

  app.get('/approvals', async (req) => {
    const ctx = req.ctx;
    const q = parse(listQuery, req.query);
    const scope = q.scope ?? 'awaiting_me';
    if (scope === 'all') ctx.require('approvals.view');
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('approval_requests as a').where('a.company_id', '=', ctx.companyId);
      if (scope === 'mine') base = base.where('a.requested_by', '=', ctx.userId);
      if (scope === 'awaiting_me') {
        const roleIds = ctx.company.roles.map((r) => r.id);
        const cur = sql`a.levels -> (a.current_level - 1)`;
        base = base.where('a.status', '=', 'pending').where('a.requested_by', '!=', ctx.userId)
          .where(sql<boolean>`(${cur} ->> 'approverUserId' = ${ctx.userId}
            ${roleIds.length ? sql`or ${cur} ->> 'approverRoleId' in (${sql.join(roleIds)})` : sql``})`)
          .where(sql<boolean>`not exists (select 1 from approval_actions x where x.request_id = a.id and x.action = 'approved' and x.user_id = ${ctx.userId})`);
      }
      if (q.status) base = base.where('a.status', '=', q.status);
      if (q.docType) base = base.where('a.doc_type', '=', q.docType);
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('a.id').orderBy('a.requested_at', 'desc').orderBy('a.id').limit(q.limit).offset(q.offset).execute();
      const data = [];
      for (const { id } of ids) {
        const j = await loadRequest(tx, ctx, id, false);
        delete (j as { payload?: unknown }).payload;
        delete (j as { actions?: unknown }).actions;
        data.push(j);
      }
      return { data, total: Number(total) };
    });
  });

  app.get('/approvals/count', async (req) => {
    const ctx = req.ctx;
    return ctx.tx(async (tx) => {
      const roleIds = ctx.company.roles.map((r) => r.id);
      const cur = sql`a.levels -> (a.current_level - 1)`;
      const awaiting = await tx.selectFrom('approval_requests as a').select((eb) => eb.fn.countAll<number>().as('n'))
        .where('a.company_id', '=', ctx.companyId).where('a.status', '=', 'pending').where('a.requested_by', '!=', ctx.userId)
        .where(sql<boolean>`(${cur} ->> 'approverUserId' = ${ctx.userId}
          ${roleIds.length ? sql`or ${cur} ->> 'approverRoleId' in (${sql.join(roleIds)})` : sql``})`)
        .where(sql<boolean>`not exists (select 1 from approval_actions x where x.request_id = a.id and x.action = 'approved' and x.user_id = ${ctx.userId})`)
        .executeTakeFirstOrThrow();
      const mine = await tx.selectFrom('approval_requests').select((eb) => eb.fn.countAll<number>().as('n'))
        .where('company_id', '=', ctx.companyId).where('status', '=', 'pending').where('requested_by', '=', ctx.userId).executeTakeFirstOrThrow();
      return { awaitingMe: Number(awaiting.n), mine: Number(mine.n) };
    });
  });

  app.get<{ Params: { id: string } }>('/approvals/:id', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const r = await loadRequest(tx, ctx, id, true);
      const anyLevel = (r.levels as LevelSnap[]).some((l) => qualifies(ctx, l));
      if (r.requestedBy.id !== ctx.userId && !anyLevel && !ctx.can('approvals.view')) throw notFound('Approval request');
      return r;
    });
  });

  /** Locks the request and checks it is pending and the caller may act now. */
  async function lockForAction(tx: Tx, ctx: RequestContext, id: string) {
    const row = await tx.selectFrom('approval_requests').selectAll()
      .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
    if (!row) throw notFound('Approval request');
    const levels = row.levels as LevelSnap[];
    const anyLevel = levels.some((l) => qualifies(ctx, l));
    if (row.requested_by !== ctx.userId && !anyLevel && !ctx.can('approvals.view')) throw notFound('Approval request');
    if (row.status !== 'pending') throw conflict(`This request is already ${row.status}.`, 'NOT_PENDING');
    if (row.requested_by === ctx.userId) throw new AppError(403, 'SELF_APPROVAL', 'You cannot approve or reject your own request.');
    if (!qualifies(ctx, levels.find((l) => l.level === row.current_level))) throw forbidden('This request is not waiting for you.');
    return { row, levels };
  }

  app.post<{ Params: { id: string } }>('/approvals/:id/approve', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const { comment } = parse(commentBody, req.body);
    return ctx.tx(async (tx) => {
      const { row, levels } = await lockForAction(tx, ctx, id);
      const done = await tx.selectFrom('approval_actions').select('id')
        .where('request_id', '=', id).where('action', '=', 'approved').where('user_id', '=', ctx.userId).executeTakeFirst();
      if (done) throw new AppError(403, 'ALREADY_ACTED', 'You already approved an earlier level of this request.');

      await tx.insertInto('approval_actions').values({
        tenant_id: ctx.tenantId, request_id: id, level: row.current_level, action: 'approved', user_id: ctx.userId, comment: comment || null,
      }).execute();

      if (row.current_level < row.total_levels) {
        await tx.updateTable('approval_requests').set({ current_level: row.current_level + 1 }).where('id', '=', id).execute();
        await writeAudit(tx, auditOf(ctx), 'approval_request', id, 'approve', { level: row.current_level }, { level: row.current_level + 1, comment });
        await notifyLevel(tx, ctx, row, levels, row.current_level + 1);
        return loadRequest(tx, ctx, id, true);
      }

      // Final approval: create the document as the requester, inside this transaction.
      const ex = executors.get(row.doc_type as ApprovalDocType);
      if (!ex) throw new Error(`No approval executor for ${row.doc_type}`);
      const rctx = await contextFor(tx, ctx.db, ctx.tenantId, row.requested_by, ctx.companyId);
      if (!rctx) throw forbidden('The requester no longer has access to this company.');
      if (!rctx.can(ex.permission)) throw forbidden('The requester no longer has permission to create this document.');
      const doc = await ex.create(rctx, tx, row.payload);
      await tx.updateTable('approval_requests').set({
        status: 'approved', decided_at: new Date(), document_id: doc.id, document_number: doc.number,
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'approval_request', id, 'approve', { level: row.current_level },
        { status: 'approved', documentId: doc.id, documentNumber: doc.number, comment });
      await notifyDecision(tx, ctx, row, 'approved', comment, doc.number);
      return loadRequest(tx, ctx, id, true);
    });
  });

  app.post<{ Params: { id: string } }>('/approvals/:id/reject', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const { comment } = parse(rejectBody, req.body);
    return ctx.tx(async (tx) => {
      const { row } = await lockForAction(tx, ctx, id);
      await tx.insertInto('approval_actions').values({
        tenant_id: ctx.tenantId, request_id: id, level: row.current_level, action: 'rejected', user_id: ctx.userId, comment,
      }).execute();
      await tx.updateTable('approval_requests').set({ status: 'rejected', decided_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'approval_request', id, 'reject', { status: 'pending' }, { status: 'rejected', comment });
      await executors.get(row.doc_type as ApprovalDocType)?.onDecline?.(ctx, tx, row.payload);
      await notifyDecision(tx, ctx, row, 'rejected', comment, null);
      return loadRequest(tx, ctx, id, true);
    });
  });

  app.post<{ Params: { id: string } }>('/approvals/:id/cancel', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const row = await tx.selectFrom('approval_requests').selectAll()
        .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!row || row.requested_by !== ctx.userId) throw notFound('Approval request');
      if (row.status !== 'pending') throw conflict(`This request is already ${row.status}.`, 'NOT_PENDING');
      await tx.insertInto('approval_actions').values({
        tenant_id: ctx.tenantId, request_id: id, level: null, action: 'cancelled', user_id: ctx.userId, comment: null,
      }).execute();
      await tx.updateTable('approval_requests').set({ status: 'cancelled', decided_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'approval_request', id, 'cancel', { status: 'pending' }, { status: 'cancelled' });
      await executors.get(row.doc_type as ApprovalDocType)?.onDecline?.(ctx, tx, row.payload);
      return loadRequest(tx, ctx, id, true);
    });
  });

  async function notifyDecision(tx: Tx, ctx: RequestContext, row: RequestRow, decision: 'approved' | 'rejected', comment: string | undefined, documentNumber: string | null) {
    await notify(tx, { tenantId: ctx.tenantId, companyId: ctx.companyId }, {
      userIds: [row.requested_by], template: 'approval_decided', link: `/approvals/${row.id}`,
      data: { docType: row.doc_type, number: row.number, decision, by: ctx.userName, amount: round2(row.amount), documentNumber, comment: comment || null },
    });
  }
}

documentRoute('POST', '/approval-rules', { body: createRule });
documentRoute('PATCH', '/approval-rules/:id', { body: patchRule });
documentRoute('POST', '/approvals/:id/approve', { body: commentBody });
documentRoute('POST', '/approvals/:id/reject', { body: rejectBody });
