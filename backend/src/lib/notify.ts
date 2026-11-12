import type { Config } from '../config.ts';
import type { Tx } from '../db/database.ts';
import { enqueue, registerJobHandler, type JobDeps } from './jobs.ts';
import { TEMPLATES, type TemplateId } from './templates.ts';

export interface NotifyInput {
  /** Users get an in-app row (if the template has one) and email/WhatsApp per their prefs. */
  userIds?: string[];
  /** Someone who isn't a user, e.g. a customer. */
  to?: { email?: string | null; phone?: string | null; partyId?: string | null; channels?: ('email' | 'whatsapp')[] };
  template: TemplateId;
  data: Record<string, unknown>;
  /** Client route opened from the in-app notification, e.g. `/approvals/<id>`. */
  link?: string | null;
}

/** Writes in-app rows and outbox rows in the caller's transaction and queues delivery. Returns the outbox ids. */
export async function notify(
  tx: Tx, who: { tenantId: string; companyId: string | null }, n: NotifyInput,
): Promise<string[]> {
  const def = TEMPLATES[n.template];
  const msg = def.render(n.data);
  const outbox: { channel: 'email' | 'whatsapp'; to: string | null; userId: string | null; partyId: string | null }[] = [];

  const userIds = [...new Set(n.userIds ?? [])];
  if (userIds.length) {
    const users = await tx.selectFrom('users').select(['id', 'email', 'phone']).where('id', 'in', userIds)
      .where('is_active', '=', true).execute();
    const prefs = await tx.selectFrom('notification_prefs').select(['user_id', 'email', 'whatsapp'])
      .where('user_id', 'in', userIds).where('template', '=', n.template).execute();
    if (def.inApp && users.length) {
      await tx.insertInto('notifications').values(users.map((u) => ({
        tenant_id: who.tenantId, company_id: who.companyId, user_id: u.id, template: n.template,
        title: msg.title, body: msg.body, link: n.link ?? null,
      }))).execute();
    }
    for (const u of users) {
      const p = prefs.find((x) => x.user_id === u.id);
      if (def.email && (def.mandatory || (p?.email ?? def.defaultEmail))) {
        outbox.push({ channel: 'email', to: u.email, userId: u.id, partyId: null });
      }
      if (def.whatsapp && p?.whatsapp === true) outbox.push({ channel: 'whatsapp', to: u.phone, userId: u.id, partyId: null });
    }
  }
  if (n.to) {
    const channels = n.to.channels ?? ['email', 'whatsapp'];
    if (def.email && channels.includes('email')) outbox.push({ channel: 'email', to: n.to.email ?? null, userId: null, partyId: n.to.partyId ?? null });
    if (def.whatsapp && channels.includes('whatsapp')) {
      outbox.push({ channel: 'whatsapp', to: n.to.phone ?? null, userId: null, partyId: n.to.partyId ?? null });
    }
  }
  if (!outbox.length) return [];

  const rows = await tx.insertInto('notification_outbox').values(outbox.map((o) => ({
    tenant_id: who.tenantId, company_id: who.companyId, channel: o.channel, to_address: o.to?.trim() || null,
    user_id: o.userId, party_id: o.partyId, template: n.template, subject: msg.subject, body: msg.body,
    data: JSON.stringify(n.data), status: o.to?.trim() ? 'pending' : 'skipped',
    error: o.to?.trim() ? null : 'No address',
  }))).returning(['id', 'status']).execute();
  for (const r of rows) {
    if (r.status === 'pending') {
      await enqueue(tx, { ...who, userId: null }, 'notification.send', { outboxId: r.id }, { maxAttempts: 3 });
    }
  }
  return rows.map((r) => r.id);
}

// Delivery -----------------------------------------------------------------------------------

export interface OutboundMessage { channel: 'email' | 'whatsapp'; to: string; template: string; subject: string | null; body: string; data: Record<string, any> }

/** Sends one message; returns the provider's reference. Tests may replace it with `setSender`. */
export type Sender = (m: OutboundMessage, cfg: Config, log?: JobDeps['log']) => Promise<string>;

let mailer: { sendMail: (o: object) => Promise<{ messageId?: string }> } | null = null;

const defaultSender: Sender = async (m, cfg, log) => {
  if (m.channel === 'email') {
    if (cfg.EMAIL_DRIVER === 'log') {
      log?.info(`[email:log] to=${m.to} subject=${JSON.stringify(m.subject)}\n${m.body}`);
      return 'log';
    }
    if (!cfg.SMTP_URL) throw new Error('SMTP_URL is not set');
    if (!mailer) {
      const nodemailer = await import('nodemailer');
      mailer = nodemailer.createTransport(cfg.SMTP_URL);
    }
    const info = await mailer.sendMail({ from: cfg.EMAIL_FROM, to: m.to, subject: m.subject ?? '', text: m.body });
    return info.messageId ?? 'smtp';
  }
  if (cfg.WHATSAPP_DRIVER === 'log') {
    log?.info(`[whatsapp:log] to=${m.to} template=${m.template}\n${m.body}`);
    return 'log';
  }
  if (!cfg.WHATSAPP_TOKEN || !cfg.WHATSAPP_PHONE_ID) throw new Error('WHATSAPP_TOKEN and WHATSAPP_PHONE_ID are not set');
  const digits = m.to.replace(/\D/g, '');
  const to = digits.length === 10 ? `91${digits}` : digits;
  const params = m.template === 'payment_reminder'
    ? [m.data.partyName, String(m.data.amountDue), m.data.oldestDue, m.data.companyName, m.data.upiId || '—']
    : [m.body];
  const res = await fetch(`https://graph.facebook.com/${cfg.WHATSAPP_API_VERSION}/${cfg.WHATSAPP_PHONE_ID}/messages`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${cfg.WHATSAPP_TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      messaging_product: 'whatsapp', to, type: 'template',
      template: {
        name: m.template, language: { code: 'en' },
        components: [{ type: 'body', parameters: params.map((text) => ({ type: 'text', text: String(text ?? '') })) }],
      },
    }),
    signal: AbortSignal.timeout(15_000),
  });
  const json = await res.json().catch(() => ({})) as { messages?: { id: string }[]; error?: { message?: string } };
  if (!res.ok) throw new Error(`WhatsApp ${res.status}: ${json.error?.message ?? 'request failed'}`);
  return json.messages?.[0]?.id ?? 'cloud_api';
};

let sender: Sender = defaultSender;
/** Replaces the delivery function (tests); call with no argument to restore the default. */
export function setSender(s?: Sender): void {
  sender = s ?? defaultSender;
}

registerJobHandler('notification.send', async (tx, job, deps) => {
  const { outboxId } = job.payload as { outboxId: string };
  const row = await tx.selectFrom('notification_outbox').selectAll().where('id', '=', outboxId).forUpdate().executeTakeFirst();
  if (!row || row.status !== 'pending' || !row.to_address) return { skipped: true };
  const ref = await sender({
    channel: row.channel as 'email' | 'whatsapp', to: row.to_address, template: row.template, subject: row.subject,
    body: row.body, data: (row.data ?? {}) as Record<string, any>,
  }, deps.config, deps.log);
  await tx.updateTable('notification_outbox').set({
    status: 'sent', provider_ref: ref.slice(0, 200), sent_at: new Date(), attempts: row.attempts + 1, error: null,
  }).where('id', '=', row.id).execute();
  return { sent: true };
}, {
  onFailure: async (tx, job, error, final) => {
    const { outboxId } = job.payload as { outboxId: string };
    await tx.updateTable('notification_outbox')
      .set((eb) => ({ attempts: eb('attempts', '+', 1), error: error.message.slice(0, 1000), ...(final ? { status: 'failed' } : {}) }))
      .where('id', '=', outboxId).execute();
  },
});
