import type { Tx } from '../db/database.ts';
import { AppError } from './errors.ts';

export const suspended = () => new AppError(403, 'ACCOUNT_SUSPENDED', 'This account is suspended. Contact support.');

/** One small query inside the caller's tenant transaction; tenants is row-level secured to the current tenant. */
export async function assertTenantActive(tx: Tx, tenantId: string): Promise<void> {
  const t = await tx.selectFrom('tenants').select('status').where('id', '=', tenantId).executeTakeFirst();
  if (t && t.status !== 'active') throw suspended();
}
