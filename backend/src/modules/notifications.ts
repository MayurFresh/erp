import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AppDeps } from '../app.ts';
import type { Tx } from '../db/database.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { notify } from '../lib/notify.ts';
import { TEMPLATES, TEMPLATE_IDS, type TemplateId } from '../lib/templates.ts';
import { parse } from '../lib/validate.ts';
import { todayIst } from '../lib/dates.ts';
import { documentRoute } from '../lib/openapi.ts';

const page = z.object({ limit: z.coerce.number().int().min(1).max(200).default(50), offset: z.coerce.number().int().min(0).default(0) });
const listQuery = page.extend({ unread: z.enum(['true', 'false']).optional() });
const outboxQuery = page.extend({
  status: z.enum(['pending', 'sent', 'failed', 'skipped']).optional(), channel: z.enum(['email', 'whatsapp']).optional(),
});
const prefsBody = z.object({
  prefs: z.array(z.object({
    template: z.string().max(60), email: z.boolean().optional(), whatsapp: z.boolean().nullable().optional(),
  })).min(1).max(20),
});
const round2 = (n: number) => Math.round(n * 100) / 100;
/** Templates a user can tune: payment reminders go to customers, not users. */
const USER_TEMPLATES = TEMPLATE_IDS.filter((t) => t !== 'payment_reminder');

/** In-app notifications, preferences, the outbox and payment reminders (v1.7 section 6). */
export async function notificationRoutes(app: FastifyInstance, _deps: AppDeps): Promise<void> {
  app.get('/notifications', async (req) => {
    const ctx = req.ctx;
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      const mine = () => tx.selectFrom('notifications').where('user_id', '=', ctx.userId)
        .where((eb) => eb.or([eb('company_id', '=', ctx.companyId), eb('company_id', 'is', null)]));
      let base = mine();
      if (q.unread === 'true') base = base.where('read_at', 'is', null);
      const total = await base.select((eb) => eb.fn.countAll<number>().as('n')).executeTakeFirstOrThrow();
      const unread = await mine().where('read_at', 'is', null).select((eb) => eb.fn.countAll<number>().as('n')).executeTakeFirstOrThrow();
      const rows = await base.select(['id', 'template', 'title', 'body', 'link', 'read_at', 'created_at'])
        .orderBy('created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return {
        data: rows.map((r) => ({ id: r.id, template: r.template, title: r.title, body: r.body, link: r.link, readAt: r.read_at, createdAt: r.created_at })),
        total: Number(total.n), unread: Number(unread.n),
      };
    });
  });

  app.get('/notifications/unread-count', async (req) => {
    const ctx = req.ctx;
    return ctx.tx(async (tx) => {
      const r = await tx.selectFrom('notifications').where('user_id', '=', ctx.userId).where('read_at', 'is', null)
        .where((eb) => eb.or([eb('company_id', '=', ctx.companyId), eb('company_id', 'is', null)]))
        .select((eb) => eb.fn.countAll<number>().as('n')).executeTakeFirstOrThrow();
      return { unread: Number(r.n) };
    });
  });

  app.post<{ Params: { id: string } }>('/notifications/:id/read', async (req, reply) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const r = await tx.updateTable('notifications').set({ read_at: new Date() })
        .where('id', '=', id).where('user_id', '=', ctx.userId).where('read_at', 'is', null).returning('id').executeTakeFirst();
      if (!r) {
        const exists = await tx.selectFrom('notifications').select('id').where('id', '=', id).where('user_id', '=', ctx.userId).executeTakeFirst();
        if (!exists) throw notFound('Notification');
      }
    });
    return reply.status(204).send();
  });

  app.post('/notifications/read-all', async (req, reply) => {
    const ctx = req.ctx;
    await ctx.tx((tx) => tx.updateTable('notifications').set({ read_at: new Date() })
      .where('user_id', '=', ctx.userId).where('read_at', 'is', null)
      .where((eb) => eb.or([eb('company_id', '=', ctx.companyId), eb('company_id', 'is', null)])).execute());
    return reply.status(204).send();
  });

  const prefsOf = async (tx: Tx, userId: string) => {
    const rows = await tx.selectFrom('notification_prefs').select(['template', 'email', 'whatsapp']).where('user_id', '=', userId).execute();
    return USER_TEMPLATES.map((id) => {
      const def = TEMPLATES[id];
      const p = rows.find((r) => r.template === id);
      return {
        template: id, label: def.label, email: def.email ? (def.mandatory ? true : (p?.email ?? def.defaultEmail)) : false,
        whatsapp: def.whatsapp ? (p?.whatsapp ?? false) : null, mandatory: def.mandatory,
      };
    });
  };

  app.get('/me/notification-prefs', async (req) => {
    const ctx = req.ctx;
    return ctx.tx(async (tx) => ({ data: await prefsOf(tx, ctx.userId) }));
  });

  app.patch('/me/notification-prefs', async (req) => {
    const ctx = req.ctx;
    const { prefs } = parse(prefsBody, req.body);
    return ctx.tx(async (tx) => {
      const current = await prefsOf(tx, ctx.userId);
      for (const p of prefs) {
        const def = TEMPLATES[p.template as TemplateId];
        if (!def || p.template === 'payment_reminder') throw badRequest('Unknown notification.', { template: 'Unknown' });
        if (def.mandatory && p.email === false) throw badRequest(`${def.label} cannot be turned off.`, { [p.template]: 'Mandatory' });
        if (p.whatsapp === true && !def.whatsapp) throw badRequest(`${def.label} is not sent on WhatsApp.`, { [p.template]: 'No WhatsApp' });
        const cur = current.find((c) => c.template === p.template)!;
        const email = p.email ?? cur.email;
        const whatsapp = def.whatsapp ? (p.whatsapp ?? cur.whatsapp) : null;
        await tx.insertInto('notification_prefs').values({ tenant_id: ctx.tenantId, user_id: ctx.userId, template: p.template, email, whatsapp })
          .onConflict((oc) => oc.columns(['user_id', 'template']).doUpdateSet({ email, whatsapp, updated_at: new Date() })).execute();
      }
      return { data: await prefsOf(tx, ctx.userId) };
    });
  });

  app.get('/notifications/outbox', async (req) => {
    const ctx = req.ctx;
    ctx.require('company.manage');
    const q = parse(outboxQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('notification_outbox').where((eb) => eb.or([eb('company_id', '=', ctx.companyId), eb('company_id', 'is', null)]));
      if (q.status) base = base.where('status', '=', q.status);
      if (q.channel) base = base.where('channel', '=', q.channel);
      const total = await base.select((eb) => eb.fn.countAll<number>().as('n')).executeTakeFirstOrThrow();
      const rows = await base.selectAll().orderBy('created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return {
        data: rows.map((r) => ({
          id: r.id, channel: r.channel, to: r.to_address, template: r.template, subject: r.subject, status: r.status,
          attempts: r.attempts, error: r.error, providerRef: r.provider_ref, sentAt: r.sent_at, createdAt: r.created_at,
        })),
        total: Number(total.n),
      };
    });
  });

  app.post<{ Params: { id: string } }>('/parties/:id/remind', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('invoices.view');
    const id = parse(z.uuid(), req.params.id);
    const { channel } = parse(z.object({ channel: z.enum(['email', 'whatsapp']) }), req.body);
    const outboxId = await ctx.tx(async (tx) => {
      const party = await tx.selectFrom('parties').select(['id', 'name', 'email', 'phone'])
        .where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!party) throw notFound('Party');
      const address = channel === 'email' ? party.email : party.phone;
      if (!address?.trim()) throw badRequest(`This party has no ${channel === 'email' ? 'email address' : 'phone number'}.`, { channel: 'No address' });
      const due = await tx.selectFrom('invoices').select(['total', 'amount_paid', 'due_date'])
        .where('company_id', '=', ctx.companyId).where('party_id', '=', id).where('status', '=', 'posted').execute();
      const open = due.filter((i) => Number(i.total) - Number(i.amount_paid) > 0.004);
      if (!open.length) throw badRequest('Nothing is due from this party.', { partyId: 'Nothing due' });
      const since = new Date(Date.now() - 24 * 3600_000);
      const recent = await tx.selectFrom('notification_outbox').select('id').where('party_id', '=', id).where('company_id', '=', ctx.companyId)
        .where('template', '=', 'payment_reminder').where('channel', '=', channel).where('created_at', '>', since).limit(1).executeTakeFirst();
      if (recent) throw conflict('A reminder was already sent to this party in the last 24 hours.', 'TOO_SOON');
      const co = await tx.selectFrom('companies').select(['name', 'upi_id']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const amountDue = round2(open.reduce((s, i) => s + Number(i.total) - Number(i.amount_paid), 0));
      const oldestDue = open.map((i) => i.due_date).sort()[0] ?? todayIst();
      const ids = await notify(tx, { tenantId: ctx.tenantId, companyId: ctx.companyId }, {
        to: { email: party.email, phone: party.phone, partyId: party.id, channels: [channel] }, template: 'payment_reminder',
        data: { partyName: party.name, companyName: co.name, count: open.length, amountDue, oldestDue, upiId: co.upi_id },
      });
      return ids[0]!;
    });
    return reply.status(202).send({ outboxId });
  });
}

documentRoute('PATCH', '/me/notification-prefs', { body: prefsBody });
