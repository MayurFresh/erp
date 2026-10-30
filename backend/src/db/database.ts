import { Kysely, PostgresDialect, sql, type Transaction } from 'kysely';
import pg from 'pg';
import type { Database } from './schema.ts';
import { AppError } from '../lib/errors.ts';

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
export async function withTenant<T>(db: Db, tenantId: string, fn: (tx: Tx) => Promise<T>): Promise<T> {
  const run = () =>
    db.transaction().execute(async (tx) => {
      await sql`select set_config('app.tenant_id', ${tenantId}, true)`.execute(tx);
      return fn(tx);
    });
  try {
    return await run();
  } catch (err) {
    if (!isRetryable(err)) throw err;
  }
  // Serialization failure or deadlock: the whole transaction is retried once.
  try {
    return await run();
  } catch (err) {
    if (isRetryable(err)) throw new AppError(409, 'TRY_AGAIN', 'The system is busy. Please try again.');
    throw err;
  }
}

const isRetryable = (err: unknown) => {
  const code = (err as { code?: string } | null)?.code;
  return code === '40001' || code === '40P01';
};
