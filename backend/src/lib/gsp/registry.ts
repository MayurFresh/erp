import { unseal } from '../crypto.ts';
import { AppError, conflict } from '../errors.ts';
import type { Tx } from '../../db/database.ts';
import { sandboxAdapter } from './sandbox.ts';
import { GspError, type GspAdapter, type GspCall } from './types.ts';

const adapters = new Map<string, GspAdapter>();

export function registerGspAdapter(a: GspAdapter): void { adapters.set(a.id, a); }
export const gspAdapter = (id: string): GspAdapter | undefined => adapters.get(id);
export const listGspAdapters = (): GspAdapter[] => [...adapters.values()];

registerGspAdapter(sandboxAdapter);
// A live provider is one file in lib/gsp/ plus one registerGspAdapter() line here.

/** Retry waits after a transient failure (ms); tests shorten them. */
let backoff = [1000, 3000];
export function setGspBackoff(ms: number[]): void { backoff = ms; }
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const TIMEOUT_MS = 20_000;

export interface Resolved { adapter: GspAdapter; call: GspCall; provider: string }

/** The adapter and credentials for a company's e-invoice mode. 409 GSP_NOT_CONFIGURED when 'gsp' lacks setup. */
export async function resolveGsp(
  tx: Tx, company: { id: string; gstin: string | null; einvoice_mode: string; gsp_provider: string | null },
  need?: 'einvoice' | 'ewaybill' | 'gstr1_save',
): Promise<Resolved> {
  const gstin = company.gstin ?? '';
  if (company.einvoice_mode === 'sandbox') {
    return { adapter: sandboxAdapter, call: { gstin, credentials: {}, timeoutMs: TIMEOUT_MS }, provider: 'sandbox' };
  }
  if (company.einvoice_mode !== 'gsp') throw conflict('This company does not use a GST provider.', 'GSP_NOT_CONFIGURED');
  const adapter = company.gsp_provider ? adapters.get(company.gsp_provider) : undefined;
  if (!adapter || adapter.id === 'sandbox') throw conflict('Choose a GST provider and save its credentials first.', 'GSP_NOT_CONFIGURED');
  const row = await tx.selectFrom('gsp_credentials').select('values')
    .where('company_id', '=', company.id).where('provider', '=', adapter.id).executeTakeFirst();
  const saved = (row?.values ?? {}) as Record<string, string>;
  const credentials: Record<string, string> = {};
  for (const f of adapter.credentialFields) {
    const v = saved[f.key];
    if (!v) throw conflict(`Save the provider credential "${f.label}" first.`, 'GSP_NOT_CONFIGURED');
    credentials[f.key] = f.secret ? unseal(v) : v;
  }
  if (!gstin) throw conflict('Add the company GSTIN first.', 'GSP_NOT_CONFIGURED');
  if (need && !adapter.capabilities.has(need)) throw new AppError(501, 'NOT_SUPPORTED', `${adapter.name} does not support this.`);
  return { adapter, call: { gstin, credentials, timeoutMs: TIMEOUT_MS }, provider: adapter.id };
}

/** Runs a provider call: transient failures are retried (1 s, then 3 s) and become 503; the rest become 502. */
export async function callGsp<T>(provider: string, fn: () => Promise<T>): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (!(err instanceof GspError)) {
        if (err instanceof AppError) throw err;
        throw new AppError(502, 'GSP_ERROR', 'The GST provider returned an error.', { provider, providerCode: 'UNKNOWN', providerMessage: String((err as Error).message) });
      }
      if (!err.transient) {
        throw new AppError(502, 'GSP_ERROR', `The GST provider rejected the request: ${err.message}`,
          { provider, providerCode: err.code, providerMessage: err.message });
      }
      if (attempt >= backoff.length) {
        throw new AppError(503, 'GSP_UNAVAILABLE', 'The GST provider is not responding. Try again shortly.', { provider });
      }
      await sleep(backoff[attempt]!);
    }
  }
}
