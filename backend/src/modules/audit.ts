import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { pagingQuery } from '../lib/paging.ts';
import { parse } from '../lib/validate.ts';

/** Appends an entry to the immutable audit log inside the caller's transaction. */
export async function writeAudit(
  tx: Tx,
  who: { tenantId: string; userId: string | null; companyId: string | null },
  entity: string,
  entityId: string | null,
  action: string,
  before: unknown = null,
  after: unknown = null,
): Promise<void> {
  await tx
    .insertInto('audit_log')
    .values({
      tenant_id: who.tenantId,
      company_id: who.companyId,
      user_id: who.userId,
      entity,
      entity_id: entityId,
      action,
      before: before === null ? null : JSON.stringify(before),
      after: after === null ? null : JSON.stringify(after),
    })
    .execute();
}

export const auditOf = (ctx: RequestContext) => ({ tenantId: ctx.tenantId, userId: ctx.userId, companyId: ctx.companyId });

const listQuery = pagingQuery.extend({ entity: z.string().max(50).optional(), entityId: z.uuid().optional() });

export async function auditRoutes(app: FastifyInstance) {
  app.get('/audit', async (req) => {
    const ctx = req.ctx;
    ctx.require('audit.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('audit_log as a').where('a.company_id', '=', ctx.companyId);
      if (q.entity) base = base.where('a.entity', '=', q.entity);
      if (q.entityId) base = base.where('a.entity_id', '=', q.entityId);
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base
        .leftJoin('users as u', 'u.id', 'a.user_id')
        .select(['a.id', 'a.entity', 'a.entity_id', 'a.action', 'a.user_id', 'u.name as user_name', 'a.before', 'a.after', 'a.created_at'])
        .orderBy('a.id', 'desc')
        .limit(q.limit)
        .offset(q.offset)
        .execute();
      return {
        data: rows.map((r) => ({
          id: String(r.id), entity: r.entity, entityId: r.entity_id, action: r.action, userId: r.user_id,
          userName: r.user_name, before: r.before, after: r.after, createdAt: r.created_at,
        })),
        total,
      };
    });
  });
}
