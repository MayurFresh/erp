import bcrypt from 'bcryptjs';
import { randomUUID } from 'node:crypto';
import pg from 'pg';

export const SUPERADMIN_EMAIL = 'superadmin@demo.in';

/**
 * Creates the "Progen Platform" tenant (no company) with one platform admin. Safe to run twice.
 * Needs the owner connection because platform_admins is closed to the app role.
 */
export async function seedPlatformAdmin(ownerUrl: string, password = 'Demo@1234'): Promise<'created' | 'exists'> {
  const client = new pg.Client({ connectionString: ownerUrl });
  await client.connect();
  try {
    const found = await client.query('select id from users where lower(email) = $1', [SUPERADMIN_EMAIL]);
    if (found.rowCount) {
      await client.query('insert into platform_admins (user_id) values ($1) on conflict do nothing', [found.rows[0].id]);
      return 'exists';
    }
    await client.query('begin');
    const tenantId = randomUUID();
    await client.query('insert into tenants (id, name) values ($1, $2)', [tenantId, 'Progen Platform']);
    const u = await client.query(
      'insert into users (tenant_id, name, email, password_hash) values ($1, $2, $3, $4) returning id',
      [tenantId, 'Platform Admin', SUPERADMIN_EMAIL, await bcrypt.hash(password, 10)]);
    await client.query('insert into platform_admins (user_id) values ($1)', [u.rows[0].id]);
    await client.query('commit');
    return 'created';
  } catch (e) {
    await client.query('rollback').catch(() => {});
    throw e;
  } finally {
    await client.end();
  }
}
