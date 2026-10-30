import { createHash } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { AppError, badRequest } from './errors.ts';

const KEY_RE = /^[A-Za-z0-9_-]{8,100}$/;

declare module 'fastify' {
  interface FastifyRequest {
    idemKey?: string;
  }
}

/** Idempotency-Key support for POST requests inside the authenticated scope (after req.ctx is set). */
export function registerIdempotency(app: FastifyInstance) {
  app.addHook('preHandler', async (req, reply) => {
    if (req.method !== 'POST') return;
    const raw = req.headers['idempotency-key'];
    if (raw === undefined) return;
    const ctype = String(req.headers['content-type'] ?? '');
    if (ctype.startsWith('multipart/')) return;
    if (typeof raw !== 'string' || !KEY_RE.test(raw)) {
      throw badRequest('Idempotency-Key must be 8 to 100 characters: letters, digits, "_" or "-".');
    }
    const path = req.url.split('?')[0] ?? req.url;
    const hash = createHash('sha256').update(JSON.stringify(req.body ?? null)).digest('hex');
    const ctx = req.ctx;
    const existing = await ctx.tx(async (tx) => {
      await sql`delete from idempotency_keys where created_at < now() - interval '24 hours'
                or (state = 'running' and created_at < now() - interval '5 minutes')`.execute(tx);
      const ins = await tx
        .insertInto('idempotency_keys')
        .values({ tenant_id: ctx.tenantId, user_id: ctx.userId, key: raw, method: req.method, path, body_hash: hash })
        .onConflict((oc) => oc.columns(['tenant_id', 'user_id', 'key']).doNothing())
        .returning('id')
        .executeTakeFirst();
      if (ins) return null;
      return tx
        .selectFrom('idempotency_keys')
        .selectAll()
        .where('user_id', '=', ctx.userId)
        .where('key', '=', raw)
        .executeTakeFirst();
    });
    if (!existing) {
      req.idemKey = raw;
      return;
    }
    if (existing.method !== req.method || existing.path !== path || existing.body_hash !== hash) {
      throw new AppError(422, 'IDEMPOTENCY_MISMATCH', 'This Idempotency-Key was already used for a different request.');
    }
    if (existing.state !== 'done') {
      throw new AppError(409, 'REQUEST_IN_PROGRESS', 'This request is still being processed.');
    }
    return reply
      .status(existing.status ?? 200)
      .header('Idempotent-Replayed', 'true')
      .type('application/json; charset=utf-8')
      .send(JSON.stringify(existing.response));
  });

  app.addHook('onSend', async (req, reply, payload) => {
    const key = req.idemKey;
    if (!key) return payload;
    req.idemKey = undefined;
    const ctx = req.ctx;
    try {
      let parsed: unknown;
      let ok = reply.statusCode >= 200 && reply.statusCode < 300 && typeof payload === 'string';
      if (ok) {
        try {
          parsed = JSON.parse(payload as string);
        } catch {
          ok = false;
        }
      }
      await ctx.tx(async (tx) => {
        if (ok) {
          await tx
            .updateTable('idempotency_keys')
            .set({ state: 'done', status: reply.statusCode, response: JSON.stringify(parsed) })
            .where('user_id', '=', ctx.userId)
            .where('key', '=', key)
            .execute();
        } else {
          await tx.deleteFrom('idempotency_keys').where('user_id', '=', ctx.userId).where('key', '=', key).execute();
        }
      });
    } catch (err) {
      req.log.error(err);
    }
    return payload;
  });
}
