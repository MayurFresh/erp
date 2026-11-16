import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/app.ts';
import { loadConfig } from '../src/config.ts';
import { createDb, type Db } from '../src/db/database.ts';
import { migrate, withDatabase } from '../src/db/migrate.ts';

export interface TestEnv { app: FastifyInstance; db: Db }

/** Uploads made by tests go to the OS temp folder, not backend/uploads. */
export const TEST_UPLOAD_DIR = join(tmpdir(), 'progen-erp-test-uploads');

/** Fresh app on the test database, which is migrated and emptied first. */
export async function setupTestApp(): Promise<TestEnv> {
  const testUrl = process.env.TEST_DATABASE_URL;
  const adminUrl = process.env.DATABASE_ADMIN_URL;
  if (!testUrl || !adminUrl) throw new Error('Set TEST_DATABASE_URL and DATABASE_ADMIN_URL in backend/.env (run npm run db:setup)');
  const dbName = new URL(testUrl).pathname.slice(1);
  const role = decodeURIComponent(new URL(testUrl).username);
  const ownerUrl = withDatabase(adminUrl, dbName);
  await migrate(ownerUrl, role, () => {});
  const owner = new pg.Client({ connectionString: ownerUrl });
  await owner.connect();
  // truncate ... cascade also empties the shared masters (their tenant_id references tenants), so put the system rows back.
  // One transaction, so a run that stops halfway can't lose the system rows for every later run.
  const system: Record<string, unknown[]> = {};
  try {
    await owner.query('begin');
    for (const t of ['gst_rates', 'tds_sections', 'tds_section_map']) system[t] = (await owner.query(`select * from ${t} where tenant_id is null`)).rows;
    if (!system.gst_rates!.length) throw new Error(`${dbName} has no system GST rates left. Drop and recreate this test database.`);
    await owner.query('truncate tenants cascade');
    for (const [t, rows] of Object.entries(system)) {
      if (rows.length) await owner.query(`insert into ${t} select * from json_populate_recordset(null::${t}, $1::json)`, [JSON.stringify(rows)]);
    }
    await owner.query('commit');
  } catch (err) {
    await owner.query('rollback').catch(() => {});
    throw err;
  } finally {
    await owner.end();
  }

  const config = loadConfig({ ...process.env, DATABASE_URL: testUrl, LOG_LEVEL: 'silent', UPLOAD_DIR: TEST_UPLOAD_DIR });
  const db = createDb(testUrl, 5);
  const app = await buildApp({ config, db, logger: false, authRateLimit: false });
  return { app, db };
}

export async function teardown(env: TestEnv) {
  await env.app.close();
  await env.db.destroy();
}

type Method = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

/** Small JSON client over fastify.inject. */
export function client(app: FastifyInstance, token?: string, companyId?: string) {
  return async (method: Method, url: string, body?: unknown, extra?: Record<string, string>) => {
    const headers: Record<string, string> = { ...extra };
    if (token) headers.authorization = `Bearer ${token}`;
    if (companyId) headers['x-company-id'] = companyId;
    const res = await app.inject({ method, url: `/api/v1${url}`, headers, payload: body as object | undefined });
    return { status: res.statusCode, body: res.body ? res.json() : null };
  };
}

let counter = 0;
export const uniqueEmail = (prefix: string) => `${prefix}.${Date.now()}.${counter++}@test.in`;
