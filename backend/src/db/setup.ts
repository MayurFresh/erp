// One-time local setup: creates the app role and databases, then migrates them.
// Usage: npm run db:setup   (needs DATABASE_ADMIN_URL, DATABASE_URL, optional TEST_DATABASE_URL)
import pg from 'pg';
import { migrate, withDatabase } from './migrate.ts';

const adminUrl = process.env.DATABASE_ADMIN_URL;
const appUrlRaw = process.env.DATABASE_URL;
if (!adminUrl || !appUrlRaw) throw new Error('Set DATABASE_ADMIN_URL and DATABASE_URL in backend/.env');

const appUrl = new URL(appUrlRaw);
const role = decodeURIComponent(appUrl.username);
const password = decodeURIComponent(appUrl.password);
const databases = [appUrl.pathname.slice(1)];
if (process.env.TEST_DATABASE_URL) databases.push(new URL(process.env.TEST_DATABASE_URL).pathname.slice(1));

const admin = new pg.Client({ connectionString: adminUrl });
await admin.connect();
try {
  const exists = await admin.query('select 1 from pg_roles where rolname = $1', [role]);
  if (exists.rowCount === 0) {
    await admin.query(
      `create role ${pg.escapeIdentifier(role)} login password ${pg.escapeLiteral(password)} nosuperuser nobypassrls`,
    );
    console.log(`Created role ${role}`);
  }
  for (const name of databases) {
    const db = await admin.query('select 1 from pg_database where datname = $1', [name]);
    if (db.rowCount === 0) {
      await admin.query(`create database ${pg.escapeIdentifier(name)}`);
      console.log(`Created database ${name}`);
    }
  }
} finally {
  await admin.end();
}

for (const name of databases) {
  console.log(`Migrating ${name}`);
  await migrate(withDatabase(adminUrl, name), role);
}
console.log('Database setup complete.');
