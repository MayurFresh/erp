import { Kysely, PostgresDialect, sql, type Transaction } from 'kysely';
import pg from 'pg';
import type { Database } from './schema.ts';

// numeric → number, bigint (count) → number, date → 'YYYY-MM-DD' string.
pg.types.setTypeParser(1700, (v) => Number.parseFloat(v));
pg.types.setTypeParser(20, (v) => Number.parseInt(v, 10));
pg.types.setTypeParser(1082, (v) => v);

export type Db = Kysely<Database>;
export type Tx = Transaction<Database>;

export function createDb(connectionString: string, max = 10): Db {
  return new Kysely<Database>({
    dialect: new PostgresDialect({ pool: new pg.Pool({ connectionString, max }) }),
  });
}

/**
 * Runs `fn` in a transaction whose row-level security is bound to one tenant.
 * Every query for business data must go through here.
 */
export function withTenant<T>(db: Db, tenantId: string, fn: (tx: Tx) => Promise<T>): Promise<T> {
  return db.transaction().execute(async (tx) => {
    await sql`select set_config('app.tenant_id', ${tenantId}, true)`.execute(tx);
    return fn(tx);
  });
}
