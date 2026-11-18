import type { Config } from '../config.ts';

export interface SmsMessage {
  to: string;
  text: string;
  /** India DLT: the sender's registered entity, the approved template and the registered header. */
  dlt?: { entityId?: string | null; templateId?: string | null; senderId?: string | null };
  /** Values for the variables of the approved template, in order. */
  variables?: string[];
}

type FetchFn = typeof fetch;
let httpFetch: FetchFn | null = null;
/** Tests replace the network call; call with no argument to restore it. */
export function setSmsFetch(f?: FetchFn): void {
  httpFetch = f ?? null;
}

/** Digits only; a 10 digit Indian number gets 91 in front. */
export function smsNumber(raw: string): string {
  const d = raw.replace(/\D/g, '');
  return d.length === 10 ? `91${d}` : d;
}

const fill = (tpl: string, v: Record<string, string>) => tpl.replace(/\{(\w+)\}/g, (_, k) => JSON.stringify(v[k] ?? '').slice(1, -1));

/** Sends one SMS through the configured driver; returns the provider reference. */
export async function sendSms(m: SmsMessage, cfg: Config, log?: { info: (msg: string) => void }): Promise<string> {
  if (cfg.SMS_DRIVER === 'log') {
    log?.info(`[sms:log] to=${m.to} template=${m.dlt?.templateId ?? '-'}\n${m.text}`);
    return 'log';
  }
  const f = httpFetch ?? fetch;
  const to = smsNumber(m.to);
  const sender = m.dlt?.senderId || cfg.SMS_SENDER_ID || '';
  if (cfg.SMS_DRIVER === 'msg91') {
    if (!cfg.SMS_AUTH_KEY) throw new Error('SMS_AUTH_KEY is not set');
    if (!m.dlt?.templateId) throw new Error('No DLT template id for this message');
    // MSG91 flow API (https://control.msg91.com/apidoc/textsms/send-sms-flow.php): the approved flow is filled from
    // VAR1, VAR2, ... of each recipient; the names must match the variables of the flow. `template_id` is what
    // MSG91's newer v5 requests use for the same id, so both keys carry it.
    const recipient: Record<string, string> = { mobiles: to };
    (m.variables ?? [m.text]).forEach((v, i) => { recipient[`VAR${i + 1}`] = v; });
    const res = await f('https://control.msg91.com/api/v5/flow/', {
      method: 'POST',
      headers: { authkey: cfg.SMS_AUTH_KEY, 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({
        flow_id: m.dlt.templateId, template_id: m.dlt.templateId, ...(sender ? { sender } : {}), short_url: '0', recipients: [recipient],
      }),
      signal: AbortSignal.timeout(15_000),
    });
    const json = await res.json().catch(() => ({})) as { type?: string; message?: string };
    if (!res.ok || json.type === 'error') throw new Error(`SMS ${res.status}: ${json.message ?? 'request failed'}`);
    return (json.message ?? 'msg91').slice(0, 100);
  }
  if (!cfg.SMS_HTTP_URL || !cfg.SMS_HTTP_BODY) throw new Error('SMS_HTTP_URL and SMS_HTTP_BODY are not set');
  let headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (cfg.SMS_HTTP_HEADERS) {
    try { headers = { ...headers, ...(JSON.parse(cfg.SMS_HTTP_HEADERS) as Record<string, string>) }; } catch { throw new Error('SMS_HTTP_HEADERS is not valid JSON'); }
  }
  const body = fill(cfg.SMS_HTTP_BODY, {
    to, message: m.text, sender, entityId: m.dlt?.entityId ?? '', templateId: m.dlt?.templateId ?? '',
  });
  const res = await f(cfg.SMS_HTTP_URL, { method: 'POST', headers, body, signal: AbortSignal.timeout(15_000) });
  if (!res.ok) throw new Error(`SMS ${res.status}: request failed`);
  return 'http';
}
