import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { AppDeps } from '../app.ts';
import { contextFor } from '../auth/context.ts';
import { postJournal } from '../accounting/journal.ts';
import { withTenant, type Db, type Tx } from '../db/database.ts';
import { seal, unseal } from '../lib/crypto.ts';
import { AppError, badRequest, conflict, notFound } from '../lib/errors.ts';
import {
  cancelPaymentLink, createPaymentLink, GatewayError, isTestMode, parseEvent, verifySignature, type GatewayCreds,
} from '../lib/gateways/razorpay.ts';
import { documentRoute } from '../lib/openapi.ts';
import { notify } from '../lib/notify.ts';
import { todayIst } from '../lib/dates.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { createPayment } from './payments.ts';

const r2 = (n: number) => Math.round(n * 100) / 100;
const FIELDS = [
  { key: 'keyId', label: 'Key id', secret: false },
  { key: 'keySecret', label: 'Key secret', secret: true },
  { key: 'webhookSecret', label: 'Webhook secret', secret: true },
] as const;

type Gw = { id: string; tenant_id: string; company_id: string; provider: string; credentials: string | null; account_id: string | null; is_active: boolean; last_error: string | null };

function openCreds(g: { credentials: string | null }): GatewayCreds | null {
  if (!g.credentials) return null;
  try { return JSON.parse(unseal(g.credentials)) as GatewayCreds; } catch { return null; }
}

const gatewayJson = (g: Gw | undefined, cfg: AppDeps['config']) => {
  const have = (g && openCreds(g)) || ({} as Partial<GatewayCreds>);
  return {
    id: g?.id ?? null, provider: 'razorpay', isActive: g?.is_active ?? false, accountId: g?.account_id ?? null,
    mode: have.keyId ? (isTestMode({ keyId: have.keyId }) ? 'test' : 'live') : null,
    credentials: FIELDS.map((f) => ({ key: f.key, label: f.label, secret: f.secret, set: Boolean((have as any)[f.key]) })),
    webhookUrl: g ? `${cfg.PUBLIC_API_URL}/api/v1/webhooks/payment-gateways/${g.id}` : null, lastError: g?.last_error ?? null,
  };
};

const settingsBody = z.object({
  keyId: z.string().trim().min(8).max(100).optional(),
  keySecret: z.string().trim().min(8).max(200).optional(),
  webhookSecret: z.string().trim().min(6).max(200).optional(),
  accountId: z.uuid().nullish(),
  isActive: z.boolean().optional(),
});
const createBody = z.object({ expiresInDays: z.number().int().min(1).max(180).default(7), notify: z.boolean().optional() }).default({ expiresInDays: 7 });
const listQuery = z.object({
  status: z.enum(['created', 'paid', 'expired', 'cancelled', 'failed']).optional(), invoiceId: z.uuid().optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50), offset: z.coerce.number().int().min(0).default(0),
});
const sendBody = z.object({ channels: z.array(z.enum(['email', 'whatsapp', 'sms'])).min(1) });

type Link = {
  id: string; invoice_id: string; invoice_number: string; party_name: string; amount: number; status: string; short_url: string | null;
  expires_at: Date | null; paid_at: Date | null; payment_id: string | null; fee: number; created_at: Date; customer_phone: string | null; error: string | null;
};
const LINK_SQL = sql`select l.id, l.invoice_id, v.number as invoice_number, p.name as party_name, l.amount::float8 as amount, l.status, l.short_url,
  l.expires_at, l.paid_at, l.payment_id, l.fee::float8 as fee, l.created_at, l.customer_phone, l.error
  from payment_links l join invoices v on v.id = l.invoice_id join parties p on p.id = l.party_id`;

const waUrl = (phone: string | null, text: string) => {
  const d = (phone ?? '').replace(/\D/g, '');
  const to = d.length === 10 ? `91${d}` : d;
  return `https://wa.me/${to}?text=${encodeURIComponent(text)}`;
};
const linkJson = (l: Link) => ({
  id: l.id, invoiceId: l.invoice_id, invoiceNumber: l.invoice_number, partyName: l.party_name, amount: Number(l.amount), status: l.status,
  shortUrl: l.short_url, expiresAt: l.expires_at, paidAt: l.paid_at, paymentId: l.payment_id, fee: Number(l.fee), createdAt: l.created_at, error: l.error,
  whatsappUrl: l.short_url ? waUrl(l.customer_phone, `Hello ${l.party_name}, you can pay ${Number(l.amount).toFixed(2)} rupees for invoice ${l.invoice_number} here: ${l.short_url}`) : null,
});

async function oneLink(tx: Tx, companyId: string, id: string): Promise<Link> {
  const r = (await sql<Link>`${LINK_SQL} where l.id = ${id} and l.company_id = ${companyId}`.execute(tx)).rows[0];
  if (!r) throw notFound('Payment link');
  return r;
}

async function gatewayOf(tx: Tx, companyId: string): Promise<Gw | undefined> {
  return (await sql<Gw>`select * from payment_gateways where company_id = ${companyId} and provider = 'razorpay'`.execute(tx)).rows[0];
}

export async function paymentLinkRoutes(app: FastifyInstance, deps: AppDeps) {
  app.get('/payment-gateways', async (req) => {
    const ctx = req.ctx;
    ctx.require('integrations.manage');
    return ctx.tx(async (tx) => ({ data: [gatewayJson(await gatewayOf(tx, ctx.companyId), deps.config)] }));
  });

  app.route({ method: ['PUT', 'PATCH'], url: '/payment-gateways/razorpay', handler: async (req) => {
    const ctx = req.ctx;
    ctx.require('integrations.manage');
    const b = parse(settingsBody, req.body);
    return ctx.tx(async (tx) => {
      const cur = await gatewayOf(tx, ctx.companyId);
      const have = (cur && openCreds(cur)) || ({} as Partial<GatewayCreds>);
      const merged = { ...have, ...Object.fromEntries(Object.entries({ keyId: b.keyId, keySecret: b.keySecret, webhookSecret: b.webhookSecret }).filter(([, v]) => v)) } as Partial<GatewayCreds>;
      const complete = Boolean(merged.keyId && merged.keySecret && merged.webhookSecret);
      const accountId = b.accountId !== undefined ? b.accountId : cur?.account_id ?? null;
      if (accountId) {
        const a = await tx.selectFrom('accounts').select('subtype').where('id', '=', accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!a || a.subtype !== 'bank') throw badRequest('Choose a bank account.', { accountId: 'Not a bank account' });
      }
      const active = b.isActive ?? cur?.is_active ?? false;
      if (active && (!complete || !accountId)) throw badRequest('Add the keys, the webhook secret and the bank account before turning this on.', { isActive: 'Setup is not complete' });
      const sealed = Object.keys(merged).length ? seal(JSON.stringify(merged)) : null;
      await sql`insert into payment_gateways (tenant_id, company_id, provider, credentials, account_id, is_active, created_by)
        values (${ctx.tenantId}, ${ctx.companyId}, 'razorpay', ${sealed}, ${accountId}, ${active}, ${ctx.userId})
        on conflict (company_id, provider) do update set credentials = excluded.credentials, account_id = excluded.account_id, is_active = excluded.is_active`.execute(tx);
      await writeAudit(tx, auditOf(ctx), 'payment_gateway', ctx.companyId, 'update', null, { fields: Object.keys(b), isActive: active });
      return gatewayJson(await gatewayOf(tx, ctx.companyId), deps.config);
    });
  } });

  app.delete('/payment-gateways/razorpay', async (req) => {
    const ctx = req.ctx;
    ctx.require('integrations.manage');
    return ctx.tx(async (tx) => {
      await sql`update payment_gateways set credentials = null, is_active = false where company_id = ${ctx.companyId} and provider = 'razorpay'`.execute(tx);
      await writeAudit(tx, auditOf(ctx), 'payment_gateway', ctx.companyId, 'revoke_credentials', null, null);
      return gatewayJson(await gatewayOf(tx, ctx.companyId), deps.config);
    });
  });

  app.post<{ Params: { id: string } }>('/invoices/:id/payment-links', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payments.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(createBody, req.body ?? {});
    return ctx.tx(async (tx) => {
      const gw = await gatewayOf(tx, ctx.companyId);
      const creds = gw?.is_active && gw.account_id ? openCreds(gw) : null;
      if (!gw || !creds) throw conflict('Set up online payments in settings first.', 'NO_GATEWAY');
      const inv = (await sql<any>`select v.id, v.number, v.status, v.party_id, v.location_id, (v.total - v.amount_paid)::float8 as due, p.name, p.phone, p.email
        from invoices v join parties p on p.id = v.party_id where v.id = ${id} and v.company_id = ${ctx.companyId} for update of v`.execute(tx)).rows[0];
      if (!inv) throw notFound('Invoice');
      ctx.requireLocation(inv.location_id);
      const due = r2(Number(inv.due));
      if (inv.status !== 'posted' || due <= 0) throw conflict('Nothing is due on this invoice.', 'NOTHING_DUE');
      const open = (await sql<{ id: string }>`select id from payment_links where invoice_id = ${id} and status = 'created' and amount = ${due}
        and (expires_at is null or expires_at > now()) order by created_at desc limit 1`.execute(tx)).rows[0];
      if (open) return reply.status(200).send(linkJson(await oneLink(tx, ctx.companyId, open.id)));
      const expiresAt = new Date(Date.now() + b.expiresInDays * 86_400_000);
      const row = (await sql<{ id: string }>`insert into payment_links (tenant_id, company_id, gateway_id, invoice_id, party_id, provider, reference_id, amount,
        expires_at, customer_phone, customer_email, created_by) values (${ctx.tenantId}, ${ctx.companyId}, ${gw.id}, ${id}, ${inv.party_id}, 'razorpay', 'pending',
        ${due}, ${expiresAt}, ${inv.phone}, ${inv.email}, ${ctx.userId}) returning id`.execute(tx)).rows[0]!;
      const reference = row.id.replaceAll('-', '').slice(0, 32);
      try {
        const made = await createPaymentLink(creds, {
          amountPaise: Math.round(due * 100), referenceId: reference, description: `Invoice ${inv.number}`,
          expireBy: Math.floor(expiresAt.getTime() / 1000), customer: { name: inv.name, contact: inv.phone, email: inv.email },
        });
        await sql`update payment_links set provider_link_id = ${made.id}, short_url = ${made.shortUrl}, reference_id = ${reference} where id = ${row.id}`.execute(tx);
      } catch (e) {
        if (e instanceof GatewayError) throw new AppError(502, 'GATEWAY_ERROR', `The payment provider refused the link: ${e.message}`);
        throw new AppError(502, 'GATEWAY_ERROR', 'The payment provider could not be reached. Try again.');
      }
      await writeAudit(tx, auditOf(ctx), 'payment_link', row.id, 'create', null, { invoice: inv.number, amount: due });
      return reply.status(201).send(linkJson(await oneLink(tx, ctx.companyId, row.id)));
    });
  });

  app.get('/payment-links', async (req) => {
    const ctx = req.ctx;
    ctx.require('payments.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      const where = sql.join([sql`l.company_id = ${ctx.companyId}`, ...(q.status ? [sql`l.status = ${q.status}`] : []), ...(q.invoiceId ? [sql`l.invoice_id = ${q.invoiceId}`] : [])], sql` and `);
      // A link past its expiry that was never paid reads as expired.
      await sql`update payment_links set status = 'expired' where company_id = ${ctx.companyId} and status = 'created' and expires_at < now()`.execute(tx);
      const rows = (await sql<Link>`${LINK_SQL} where ${where} order by l.created_at desc limit ${q.limit} offset ${q.offset}`.execute(tx)).rows;
      const total = (await sql<{ n: string }>`select count(*) as n from payment_links l where ${where}`.execute(tx)).rows[0]!;
      return { data: rows.map(linkJson), total: Number(total.n) };
    });
  });

  app.get<{ Params: { id: string } }>('/payment-links/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('payments.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => linkJson(await oneLink(tx, ctx.companyId, id)));
  });

  app.post<{ Params: { id: string } }>('/payment-links/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('payments.create');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const l = await oneLink(tx, ctx.companyId, id);
      if (l.status !== 'created') throw conflict('Only an open link can be cancelled.');
      const row = (await sql<any>`select provider_link_id, gateway_id from payment_links where id = ${id}`.execute(tx)).rows[0];
      const gw = await gatewayOf(tx, ctx.companyId);
      const creds = gw ? openCreds(gw) : null;
      if (creds && row.provider_link_id) {
        try { await cancelPaymentLink(creds, row.provider_link_id); } catch (e) {
          if (!(e instanceof GatewayError)) throw new AppError(502, 'GATEWAY_ERROR', 'The payment provider could not be reached. Try again.');
          // A link the provider already closed is closed here too.
        }
      }
      await sql`update payment_links set status = 'cancelled' where id = ${id}`.execute(tx);
      await writeAudit(tx, auditOf(ctx), 'payment_link', id, 'cancel', null, null);
      return linkJson(await oneLink(tx, ctx.companyId, id));
    });
  });

  app.post<{ Params: { id: string } }>('/payment-links/:id/send', async (req) => {
    const ctx = req.ctx;
    ctx.require('payments.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(sendBody, req.body);
    return ctx.tx(async (tx) => {
      const l = await oneLink(tx, ctx.companyId, id);
      if (l.status !== 'created' || !l.short_url) throw conflict('Only an open link can be sent.');
      const row = (await sql<any>`select l.party_id, l.customer_phone, l.customer_email, c.name as company from payment_links l join companies c on c.id = l.company_id where l.id = ${id}`.execute(tx)).rows[0];
      const expiresOn = l.expires_at ? new Date(l.expires_at).toISOString().slice(0, 10) : '';
      const data = {
        partyName: l.party_name, invoiceNumber: l.invoice_number, companyName: row.company, amount: l.amount, url: l.short_url, expiresOn,
        smsVars: [l.party_name, l.invoice_number, l.short_url],
      };
      const ids = await notify(tx, { tenantId: ctx.tenantId, companyId: ctx.companyId }, {
        to: { email: row.customer_email, phone: row.customer_phone, partyId: row.party_id, channels: b.channels }, template: 'payment_link', data,
      });
      return { queued: ids.length };
    });
  });
}

/** Records the money of one provider payment, once. Returns what happened. */
export async function applyGatewayPayment(
  tx: Tx, db: Db, gw: { id: string; tenant_id: string; company_id: string; account_id: string | null },
  ev: { linkId: string | null; referenceId: string | null; paymentId: string; amount: number; fee: number },
): Promise<string> {
  const link = (await sql<any>`select l.*, (v.total - v.amount_paid)::float8 as due, v.number as invoice_number from payment_links l join invoices v on v.id = l.invoice_id
    where l.gateway_id = ${gw.id} and (l.provider_link_id = ${ev.linkId} or l.reference_id = ${ev.referenceId}) for update of l`.execute(tx)).rows[0];
  if (!link) return 'unknown_link';
  const seen = (await sql<{ id: string }>`insert into gateway_payments (tenant_id, gateway_id, link_id, provider_payment_id, amount, fee)
    values (${gw.tenant_id}, ${gw.id}, ${link.id}, ${ev.paymentId}, ${ev.amount}, ${ev.fee}) on conflict (gateway_id, provider_payment_id) do nothing returning id`.execute(tx)).rows[0];
  if (!seen) return 'duplicate';
  if (!gw.account_id) throw new Error('The gateway has no bank account.');
  const ctx = await contextFor(tx, db, gw.tenant_id, link.created_by, gw.company_id);
  if (!ctx) throw new Error('The person who made this link no longer has access to the company.');
  const due = r2(Math.max(0, Number(link.due)));
  const allocate = Math.min(ev.amount, due);
  const pay = await createPayment(ctx, tx, {
    kind: 'receipt', partyId: link.party_id, accountId: gw.account_id, mode: 'upi', reference: ev.paymentId.slice(0, 60), amount: ev.amount,
    notes: `Online payment for ${link.invoice_number}`, ...(allocate > 0 ? { allocations: [{ docId: link.invoice_id, amount: allocate }] } : { allocations: [] }),
  } as any);
  if (ev.fee > 0) {
    const charges = (await sql<{ id: string }>`select id from accounts where company_id = ${gw.company_id} and code = '6070' and is_active`.execute(tx)).rows[0];
    if (charges) {
      await postJournal(tx, { tenantId: gw.tenant_id, companyId: gw.company_id, userId: link.created_by }, {
        date: todayIst(), voucherType: 'journal', voucherId: link.id, number: null,
        narration: `Gateway fee on ${ev.paymentId}`, lines: [{ accountId: charges.id, amount: ev.fee }, { accountId: gw.account_id, amount: -ev.fee }],
      } as any);
    }
  }
  await sql`update payment_links set status = 'paid', paid_at = now(), provider_payment_id = ${ev.paymentId}, payment_id = ${pay.id}, fee = ${ev.fee} where id = ${link.id}`.execute(tx);
  await sql`update gateway_payments set payment_id = ${pay.id} where id = ${seen.id}`.execute(tx);
  return 'recorded';
}

/** Public: Razorpay calls this. Signature first, then the money. */
export async function paymentWebhookRoutes(app: FastifyInstance, db: Db) {
  app.addContentTypeParser('application/json', { parseAs: 'buffer' }, (_req, body, done) => done(null, body));
  app.post<{ Params: { gatewayId: string } }>('/webhooks/payment-gateways/:gatewayId',
    { bodyLimit: 1024 * 1024, config: { rateLimit: { max: 120, timeWindow: '1 minute' } } },
    async (req, reply) => {
      const id = z.uuid().safeParse(req.params.gatewayId);
      if (!id.success) throw notFound('Gateway');
      const t = (await sql<{ tenant_id: string; company_id: string; is_active: boolean; credentials: string | null }>
        `select * from gateway_webhook_target(${id.data}::uuid)`.execute(db)).rows[0];
      if (!t || !t.credentials) throw notFound('Gateway');
      const creds = openCreds(t);
      const raw = Buffer.isBuffer(req.body) ? req.body : Buffer.from('');
      const sig = req.headers['x-razorpay-signature'];
      if (!creds || !verifySignature(raw, Array.isArray(sig) ? sig[0] : sig, creds.webhookSecret)) {
        await sql`select gateway_webhook_reject(${id.data}::uuid)`.execute(db);
        return reply.status(401).send({ error: { code: 'BAD_SIGNATURE', message: 'The signature did not match.' } });
      }
      let payload: unknown;
      try { payload = JSON.parse(raw.toString('utf8')); } catch { throw badRequest('The body is not JSON.'); }
      const ev = parseEvent(payload);
      const result = await withTenant(db, t.tenant_id, async (tx) => {
        const gw = (await sql<any>`select id, tenant_id, company_id, account_id from payment_gateways where id = ${id.data}`.execute(tx)).rows[0];
        if (!gw) return 'unknown_gateway';
        if (ev.event === 'payment_link.paid') {
          if (!ev.paymentId || ev.amount == null || (!ev.linkId && !ev.referenceId)) return 'ignored';
          return applyGatewayPayment(tx, db, gw, { linkId: ev.linkId, referenceId: ev.referenceId, paymentId: ev.paymentId, amount: ev.amount, fee: ev.fee ?? 0 });
        }
        if (ev.event === 'payment_link.expired' || ev.event === 'payment_link.cancelled') {
          await sql`update payment_links set status = ${ev.event === 'payment_link.expired' ? 'expired' : 'cancelled'}
            where gateway_id = ${gw.id} and provider_link_id = ${ev.linkId} and status = 'created'`.execute(tx);
          return 'status';
        }
        return 'ignored';
      });
      return reply.send({ ok: true, result });
    });
}

documentRoute('PATCH', '/payment-gateways/razorpay', { body: settingsBody });
documentRoute('POST', '/payment-links/:id/send', { body: sendBody });
