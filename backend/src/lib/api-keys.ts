import { randomBytes } from 'node:crypto';
import { sql } from 'kysely';
import { withTenant, type Db } from '../db/database.ts';
import { RequestContext, type Membership } from '../auth/context.ts';
import { sha256Hex } from './crypto.ts';
import { sessionRevoked, unauthorized } from './errors.ts';
import { assertTenantActive } from './tenant-status.ts';

export const API_KEY_PREFIX = 'pk_';
export const isApiKey = (token: string) => token.startsWith(API_KEY_PREFIX);

/** A new key: `pk_` plus 32 random bytes. Shown once; only the hash is stored. */
export function generateApiKey(): { key: string; prefix: string; hash: string } {
  const key = `${API_KEY_PREFIX}${randomBytes(32).toString('base64url')}`;
  return { key, prefix: key.slice(0, 11), hash: sha256Hex(key) };
}

/** Resolves a key to a request context that holds exactly the permissions of the key's role. */
export async function contextForApiKey(db: Db, token: string): Promise<RequestContext> {
  const found = await sql<{ id: string; tenant_id: string; company_id: string; role_id: string; created_by: string }>`
    select * from auth_find_api_key(${sha256Hex(token)})`.execute(db);
  const k = found.rows[0];
  if (!k) throw unauthorized('This API key is not valid.');
  return withTenant(db, k.tenant_id, async (tx) => {
    await assertTenantActive(tx, k.tenant_id);
    const user = await tx.selectFrom('users').select(['name', 'is_active']).where('id', '=', k.created_by).executeTakeFirst();
    if (!user?.is_active) throw sessionRevoked('The user who created this key is no longer active.');
    const role = await tx.selectFrom('roles').select(['id', 'name', 'permissions']).where('id', '=', k.role_id).executeTakeFirst();
    if (!role) throw unauthorized('This API key is not valid.');
    // At most one write a minute, so busy integrations do not contend on the row.
    await tx.updateTable('api_keys').set({ last_used_at: new Date() }).where('id', '=', k.id)
      .where((eb) => eb.or([eb('last_used_at', 'is', null), eb('last_used_at', '<', new Date(Date.now() - 60_000))])).execute();
    const m: Membership = { companyId: k.company_id, roles: [{ id: role.id, name: `API key: ${role.name}` }], permissions: new Set(role.permissions), locationIds: null };
    return new RequestContext(db, k.tenant_id, k.created_by, `${user.name} (API key)`, [m], m);
  });
}
