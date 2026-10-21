import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const migrationsDir = fileURLToPath(new URL('./migrations/', import.meta.url));

/** Points an admin connection string at another database. */
export function withDatabase(adminUrl: string, database: string): string {
  const url = new URL(adminUrl);
  url.pathname = `/${database}`;
  return url.toString();
}

/** Applies pending SQL migrations as the owner, then grants the app role access. */
export async function migrate(ownerUrl: string, appRole: string, log = console.log): Promise<void> {
  const client = new pg.Client({ connectionString: ownerUrl });
  await client.connect();
  try {
    await client.query(`create table if not exists schema_migrations (
      name text primary key, applied_at timestamptz not null default now())`);
    const done = new Set((await client.query('select name from schema_migrations')).rows.map((r) => r.name));
    const files = (await readdir(migrationsDir)).filter((f) => f.endsWith('.sql')).sort();
    for (const file of files) {
      if (done.has(file)) continue;
      const body = await readFile(new URL(file, `file://${migrationsDir}`), 'utf8');
      await client.query('begin');
      try {
        await client.query(body);
        await client.query('insert into schema_migrations (name) values ($1)', [file]);
        await client.query('commit');
        log(`  applied ${file}`);
      } catch (err) {
        await client.query('rollback');
        throw new Error(`Migration ${file} failed: ${(err as Error).message}`);
      }
    }
    const role = pg.escapeIdentifier(appRole);
    await client.query(`grant usage on schema public to ${role}`);
    await client.query(`grant select, insert, update, delete on all tables in schema public to ${role}`);
    await client.query(`grant usage, select on all sequences in schema public to ${role}`);
    await client.query(`grant execute on function auth_find_user_by_email(text) to ${role}`);
    await client.query(`revoke insert, update, delete on schema_migrations from ${role}`);
  } finally {
    await client.end();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const admin = process.env.DATABASE_ADMIN_URL;
  const app = process.env.DATABASE_URL;
  if (!admin || !app) throw new Error('Set DATABASE_ADMIN_URL and DATABASE_URL in backend/.env');
  const appUrl = new URL(app);
  await migrate(withDatabase(admin, appUrl.pathname.slice(1)), decodeURIComponent(appUrl.username));
  console.log('Migrations complete.');
}
