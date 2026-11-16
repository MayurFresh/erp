import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { AppDeps } from '../app.ts';
import { badRequest } from '../lib/errors.ts';
import { documentRoute } from '../lib/openapi.ts';
import { sendSms } from '../lib/sms.ts';
import { TEMPLATES, type TemplateId } from '../lib/templates.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

const smsTemplates = () => (Object.keys(TEMPLATES) as TemplateId[]).filter((k) => TEMPLATES[k].sms);

const body = z.object({
  enabled: z.boolean().optional(),
  dltEntityId: z.string().trim().regex(/^[0-9A-Za-z]{8,40}$/, 'Use the entity id from your DLT portal').nullish(),
  senderId: z.string().trim().regex(/^[A-Za-z0-9]{3,11}$/, '3 to 11 letters or digits').nullish(),
  templates: z.record(z.string(), z.object({
    dltTemplateId: z.string().trim().regex(/^[0-9A-Za-z]{8,40}$/, 'Use the template id from your DLT portal').nullish(),
    text: z.string().trim().max(600).nullish(),
  })).optional(),
});

type S = { enabled: boolean; dlt_entity_id: string | null; sender_id: string | null; templates: Record<string, { dltTemplateId?: string | null; text?: string | null }> };

async function current(tx: any, companyId: string): Promise<S> {
  const r = (await sql<S>`select enabled, dlt_entity_id, sender_id, templates from sms_settings where company_id = ${companyId}`.execute(tx)).rows[0];
  return r ?? { enabled: false, dlt_entity_id: null, sender_id: null, templates: {} };
}

const view = (s: S, driver: string) => ({
  driver, enabled: s.enabled, dltEntityId: s.dlt_entity_id, senderId: s.sender_id,
  templates: smsTemplates().map((t) => ({ template: t, label: TEMPLATES[t].label, dltTemplateId: s.templates[t]?.dltTemplateId ?? null, text: s.templates[t]?.text ?? null })),
});

export async function smsRoutes(app: FastifyInstance, deps: AppDeps) {
  app.get('/sms/settings', async (req) => {
    const ctx = req.ctx;
    ctx.require('integrations.manage');
    return ctx.tx(async (tx) => view(await current(tx, ctx.companyId), deps.config.SMS_DRIVER));
  });

  app.route({ method: ['PUT', 'PATCH'], url: '/sms/settings', handler: async (req) => {
    const ctx = req.ctx;
    ctx.require('integrations.manage');
    const b = parse(body, req.body);
    return ctx.tx(async (tx) => {
      const cur = await current(tx, ctx.companyId);
      const templates = { ...cur.templates };
      for (const [k, v] of Object.entries(b.templates ?? {})) {
        if (!smsTemplates().includes(k as TemplateId)) throw badRequest(`${k} cannot be sent by SMS.`, { templates: 'Unknown template' });
        templates[k] = { dltTemplateId: v.dltTemplateId ?? null, text: v.text ?? null };
      }
      const next = {
        enabled: b.enabled ?? cur.enabled,
        entity: b.dltEntityId !== undefined ? b.dltEntityId : cur.dlt_entity_id,
        sender: b.senderId !== undefined ? b.senderId : cur.sender_id,
      };
      if (next.enabled && deps.config.SMS_DRIVER === 'msg91' && !next.entity) {
        throw badRequest('Add the DLT entity id before turning SMS on.', { dltEntityId: 'Required in India' });
      }
      await sql`insert into sms_settings (company_id, tenant_id, enabled, dlt_entity_id, sender_id, templates)
        values (${ctx.companyId}, ${ctx.tenantId}, ${next.enabled}, ${next.entity ?? null}, ${next.sender ?? null}, ${JSON.stringify(templates)}::jsonb)
        on conflict (company_id) do update set enabled = excluded.enabled, dlt_entity_id = excluded.dlt_entity_id,
          sender_id = excluded.sender_id, templates = excluded.templates`.execute(tx);
      await writeAudit(tx, auditOf(ctx), 'sms_settings', ctx.companyId, 'update', null, { enabled: next.enabled });
      return view(await current(tx, ctx.companyId), deps.config.SMS_DRIVER);
    });
  } });

  app.post('/sms/test', async (req) => {
    const ctx = req.ctx;
    ctx.require('integrations.manage');
    const b = parse(z.object({ phone: z.string().trim().regex(/^[+0-9 ()-]{8,20}$/, 'Enter a phone number'), template: z.string().optional() }), req.body);
    const s = await ctx.tx((tx) => current(tx, ctx.companyId));
    const t = s.templates[b.template ?? 'payment_link'] ?? s.templates.payment_link;
    const ref = await sendSms({
      to: b.phone, text: t?.text ?? 'Test message from Progen.',
      dlt: { entityId: s.dlt_entity_id, senderId: s.sender_id, templateId: t?.dltTemplateId ?? null },
    }, deps.config, req.log).catch((e: Error) => { throw badRequest(e.message); });
    return { ok: true, driver: deps.config.SMS_DRIVER, reference: ref };
  });
}

documentRoute('PATCH', '/sms/settings', { body });
