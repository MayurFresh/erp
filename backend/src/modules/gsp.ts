import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AppDeps } from '../app.ts';
import type { Tx } from '../db/database.ts';
import { seal } from '../lib/crypto.ts';
import { AppError, badRequest, conflict } from '../lib/errors.ts';
import { gspAdapter, callGsp, listGspAdapters, resolveGsp } from '../lib/gsp/registry.ts';
import type { GspAdapter } from '../lib/gsp/types.ts';
import { canFile } from '../lib/prefile.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { gstPrefileCheck } from './gst-filing.ts';
import { buildGstr1, gstnJson } from './gst-returns.ts';
import { documentRoute } from '../lib/openapi.ts';

const period = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM');
const patchBody = z.object({
  mode: z.enum(['manual', 'sandbox', 'gsp']).optional(),
  provider: z.string().trim().max(60).nullable().optional(),
  credentials: z.record(z.string().max(60), z.string().max(2000).nullable()).optional(),
});

const providerInfo = (a: GspAdapter) => ({
  id: a.id, name: a.name, capabilities: [...a.capabilities], credentialFields: a.credentialFields,
});

async function settings(tx: Tx, companyId: string) {
  const c = await tx.selectFrom('companies').select(['einvoice_mode', 'gsp_provider']).where('id', '=', companyId).executeTakeFirstOrThrow();
  const adapter = c.gsp_provider ? gspAdapter(c.gsp_provider) : undefined;
  const row = adapter
    ? await tx.selectFrom('gsp_credentials').select(['values', 'updated_at']).where('company_id', '=', companyId).where('provider', '=', adapter.id).executeTakeFirst()
    : undefined;
  const saved = (row?.values ?? {}) as Record<string, string>;
  const credentials: Record<string, string | null> = {};
  const savedSecrets: string[] = [];
  for (const f of adapter?.credentialFields ?? []) {
    if (f.secret) {
      credentials[f.key] = null;
      if (saved[f.key]) savedSecrets.push(f.key);
    } else credentials[f.key] = saved[f.key] ?? null;
  }
  return {
    mode: c.einvoice_mode, provider: c.gsp_provider,
    providers: listGspAdapters().filter((a) => a.id !== 'sandbox').map(providerInfo),
    credentials, savedSecrets, updatedAt: row?.updated_at ?? null,
  };
}

const submissionJson = (r: { id: string; kind: string; period: string; provider: string; reference: string; status: string; created_at: Date; created_by: string }, who: string) => ({
  id: r.id, kind: r.kind, period: r.period, provider: r.provider, reference: r.reference, status: r.status,
  createdAt: r.created_at, createdBy: { id: r.created_by, name: who },
});

/** GSP settings, connection test and GSTR-1 upload (v1.7 section 12). */
export async function gspRoutes(app: FastifyInstance, _deps: AppDeps): Promise<void> {
  app.get('/company/gsp', async (req) => {
    const ctx = req.ctx;
    ctx.require('einvoice.manage');
    return ctx.tx((tx) => settings(tx, ctx.companyId));
  });

  app.patch('/company/gsp', async (req) => {
    const ctx = req.ctx;
    ctx.require('company.manage');
    const b = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const before = await settings(tx, ctx.companyId);
      let provider = before.provider;
      if (b.provider !== undefined) {
        if (b.provider !== null) {
          const a = gspAdapter(b.provider);
          if (!a || a.id === 'sandbox') throw badRequest('Unknown GST provider.', { provider: 'Not available' });
        }
        provider = b.provider;
      }
      if (b.credentials && Object.keys(b.credentials).length) {
        const adapter = provider ? gspAdapter(provider) : undefined;
        if (!adapter) throw badRequest('Choose a provider before saving credentials.', { provider: 'Required' });
        const fields = new Map(adapter.credentialFields.map((f) => [f.key, f]));
        const existing = await tx.selectFrom('gsp_credentials').select('values')
          .where('company_id', '=', ctx.companyId).where('provider', '=', adapter.id).forUpdate().executeTakeFirst();
        const values = { ...((existing?.values ?? {}) as Record<string, string>) };
        for (const [key, v] of Object.entries(b.credentials)) {
          const f = fields.get(key);
          if (!f) throw badRequest(`Unknown credential "${key}".`, { [`credentials.${key}`]: 'Unknown' });
          if (v === null || v === '') delete values[key];
          else values[key] = f.secret ? seal(v) : v;
        }
        await tx.insertInto('gsp_credentials').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, provider: adapter.id, values: JSON.stringify(values) as never, updated_by: ctx.userId,
        }).onConflict((oc) => oc.columns(['company_id', 'provider']).doUpdateSet({
          values: JSON.stringify(values) as never, updated_by: ctx.userId, updated_at: new Date(),
        })).execute();
      }
      const changes = {
        ...(b.mode !== undefined ? { einvoice_mode: b.mode } : {}),
        ...(b.provider !== undefined ? { gsp_provider: provider } : {}),
      };
      if (Object.keys(changes).length) await tx.updateTable('companies').set(changes).where('id', '=', ctx.companyId).execute();
      const after = await settings(tx, ctx.companyId);
      await writeAudit(tx, auditOf(ctx), 'company', ctx.companyId, 'gsp_update',
        { mode: before.mode, provider: before.provider, savedSecrets: before.savedSecrets },
        { mode: after.mode, provider: after.provider, savedSecrets: after.savedSecrets });
      return after;
    });
  });

  app.post('/company/gsp/test', async (req) => {
    const ctx = req.ctx;
    ctx.require('einvoice.manage');
    const g = await ctx.tx(async (tx) => {
      const co = await tx.selectFrom('companies').select(['id', 'gstin', 'einvoice_mode', 'gsp_provider']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      if (co.einvoice_mode === 'manual') throw new AppError(409, 'GSP_NOT_CONFIGURED', 'Manual mode does not use a GST provider.');
      return resolveGsp(tx, co);
    });
    return callGsp(g.provider, () => g.adapter.ping(g.call));
  });

  app.post('/gst/gstr1/upload', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('gst.manage');
    const b = parse(z.object({ period, acknowledgeFailures: z.boolean().optional() }), req.body);
    const prepared = await ctx.tx(async (tx) => {
      const co = await tx.selectFrom('companies').select(['id', 'gstin', 'einvoice_mode', 'gsp_provider']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      if (co.einvoice_mode === 'manual') throw new AppError(501, 'NOT_SUPPORTED', 'Choose sandbox or a GST provider to upload returns.');
      const g = await resolveGsp(tx, co, 'gstr1_save');
      if (!g.adapter.saveGstr1) throw new AppError(501, 'NOT_SUPPORTED', `${g.adapter.name} cannot save GSTR-1.`);
      const checks = await gstPrefileCheck(tx, ctx, b.period, 'gstr1');
      if (!canFile(checks) && !b.acknowledgeFailures) {
        throw conflict('A pre-filing check failed.', 'PREFILE_FAILED', { checks: checks.filter((c) => c.status === 'fail') });
      }
      return { g, json: gstnJson(await buildGstr1(tx, ctx, b.period)) };
    });
    const save = prepared.g.adapter.saveGstr1!.bind(prepared.g.adapter);
    const res = await callGsp(prepared.g.provider, () => save(prepared.g.call, b.period, prepared.json));
    const row = await ctx.tx(async (tx) => {
      const r = await tx.insertInto('gsp_submissions').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, kind: 'gstr1', period: b.period, provider: prepared.g.provider,
        reference: res.reference, status: res.status, response: JSON.stringify(res) as never, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'gsp_submission', r.id, 'gstr1_upload', null, { period: b.period, reference: res.reference });
      return r;
    });
    return reply.status(201).send(submissionJson(row, ctx.userName));
  });

  app.get('/gst/submissions', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ period: period.optional() }), req.query);
    return ctx.tx(async (tx) => {
      let qb = tx.selectFrom('gsp_submissions as s').innerJoin('users as u', 'u.id', 's.created_by')
        .select(['s.id', 's.kind', 's.period', 's.provider', 's.reference', 's.status', 's.created_at', 's.created_by', 'u.name as who'])
        .where('s.company_id', '=', ctx.companyId);
      if (q.period) qb = qb.where('s.period', '=', q.period);
      const rows = await qb.orderBy('s.created_at', 'desc').limit(200).execute();
      return { data: rows.map((r) => submissionJson(r, r.who)) };
    });
  });
}

documentRoute('PATCH', '/company/gsp', { body: patchBody });
