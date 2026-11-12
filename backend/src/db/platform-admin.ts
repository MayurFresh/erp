// Grants or revokes platform admin: npm run platform:admin -- grant|revoke|list [email]
// Uses the owner connection (DATABASE_ADMIN_URL): the app role cannot touch platform_admins.
import pg from 'pg';
import { withDatabase } from './migrate.ts';

const [cmd, emailArg] = process.argv.slice(2);
const admin = process.env.DATABASE_ADMIN_URL;
const app = process.env.DATABASE_URL;
if (!admin || !app) throw new Error('Set DATABASE_ADMIN_URL and DATABASE_URL in backend/.env');
if (!['grant', 'revoke', 'list'].includes(cmd ?? '') || (cmd !== 'list' && !emailArg)) {
  console.error('Usage: npm run platform:admin -- grant|revoke <email>   or   list');
  process.exit(2);
}
const client = new pg.Client({ connectionString: withDatabase(admin, new URL(app).pathname.slice(1)) });
await client.connect();
try {
  if (cmd === 'list') {
    const r = await client.query(`select u.email, u.name, a.created_at from platform_admins a join users u on u.id = a.user_id order by a.created_at`);
    if (!r.rowCount) console.log('No platform admins.');
    for (const row of r.rows) console.log(`${row.email}  ${row.name}  since ${row.created_at.toISOString()}`);
  } else {
    const email = emailArg!.trim().toLowerCase();
    const u = await client.query('select id, tenant_id from users where lower(email) = $1', [email]);
    if (!u.rowCount) { console.error(`No user with email ${email}.`); process.exitCode = 1; }
    else if (cmd === 'grant') {
      const t = await client.query('select status from tenants where id = $1', [u.rows[0].tenant_id]);
      if (t.rows[0]?.status !== 'active') { console.error('That user belongs to a suspended account.'); process.exitCode = 1; }
      else {
        await client.query('insert into platform_admins (user_id) values ($1) on conflict do nothing', [u.rows[0].id]);
        console.log(`Granted platform admin to ${email}.`);
      }
    } else {
      const r = await client.query('delete from platform_admins where user_id = $1', [u.rows[0].id]);
      console.log(r.rowCount ? `Revoked platform admin from ${email}.` : `${email} was not a platform admin.`);
    }
  }
} finally {
  await client.end();
}
