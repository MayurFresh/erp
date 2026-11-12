// Demo accounts: one company for every business type, with a login for each of its roles,
// sample customers, items and bills, and the sector module's own sample data.
// Usage: npm run db:seed:accounts   (after npm run db:seed). Safe to re-run: existing accounts are skipped.
// Writes the login list to docs/demo-accounts.md.
import { writeFileSync } from 'node:fs';
import { sql } from 'kysely';
import { buildApp } from '../app.ts';
import { loadConfig } from '../config.ts';
import { BUSINESS_TYPES, GROUPS, planOf, type BusinessType } from '../lib/business-types.ts';
import { createDb, withTenant, type Tx } from './database.ts';

const PASSWORD = 'Demo@1234';
const config = loadConfig();
const db = createDb(config.DATABASE_URL, 2);
const app = await buildApp({ config, db, logger: false, authRateLimit: false });

type Method = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
type Who = { tenantId: string; companyId: string; userId: string };
type ModuleSeed = (tx: Tx, who: Who, options?: Record<string, unknown>) => Promise<unknown>;

async function call(method: Method, url: string, body?: unknown, token?: string, companyId?: string) {
  const headers: Record<string, string> = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (companyId) headers['x-company-id'] = companyId;
  const res = await app.inject({ method, url: `/api/v1${url}`, headers, payload: body as object | undefined });
  const json = res.body ? res.json() : null;
  if (res.statusCode >= 400) throw new Error(`${method} ${url} → ${res.statusCode}: ${JSON.stringify(json)}`);
  return json;
}
const rows = (r: unknown): Record<string, unknown>[] => (Array.isArray(r) ? r : ((r as { data?: unknown[] })?.data ?? [])) as never;

// Sector sample data, by module key. A seed file that is missing or has no such export is skipped.
const MODULE_SEEDS: [module: string, file: string, fn: string][] = [
  ['pos', './seed-pos.ts', 'seedPosDemo'],
  ['restaurant', './seed-restaurant.ts', 'seedRestaurantDemo'],
  ['clinic', './seed-clinic.ts', 'seedClinicDemo'],
  ['legal', './seed-legal.ts', 'seedLegalDemo'],
  ['education', './seed-education.ts', 'seedEducationDemo'],
  ['hotel', './seed-hotel.ts', 'seedHotelDemo'],
  ['funds', './seed-funds.ts', 'seedFundsDemo'],
  ['donations', './seed-funds.ts', 'seedFundsDemo'], // funds sample includes donors and donations
  ['memberships', './seed-services.ts', 'seedMembershipsDemo'],
  ['job_cards', './seed-services.ts', 'seedJobCardsDemo'],
  ['payroll', './seed-payroll.ts', 'seedPayrollDemo'],
  ['manufacturing', './seed-manufacturing.ts', 'seedManufacturingDemo'],
  ['channels', './seed-channels.ts', 'seedChannelsDemo'],
  ['warehouse', './seed-warehouse.ts', 'seedWarehouseDemo'],
];
async function loadSeed(file: string, fn: string): Promise<ModuleSeed | null> {
  const mod = (await import(file).catch(() => null)) as Record<string, unknown> | null;
  return typeof mod?.[fn] === 'function' ? (mod[fn] as ModuleSeed) : null;
}

const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const ownerEmail = (id: string) => `${slug(id)}@demo.in`;
const roleEmail = (id: string, role: string) => `${slug(id)}.${slug(role)}@demo.in`;

// Plans chosen to show each one somewhere.
const PLAN_FOR: Record<string, string> = { freelancer: 'solo', proprietorship: 'team', enterprise_group: 'enterprise', public_ltd: 'enterprise', psu: 'enterprise' };

interface Account { type: BusinessType; name: string; email: string; plan: string; country: string; roles: { role: string; email: string }[]; status: string }
const accounts: Account[] = [];
const extra = { id: 'global', name: 'Demo Global Trading', type: BUSINESS_TYPES.find((t) => t.id === 'general')!, country: 'AE' };

async function sample(api: (m: Method, u: string, b?: unknown) => Promise<any>) {
  const location = rows(await api('GET', '/locations'))[0]!;
  const a = await api('POST', '/parties', { type: 'customer', name: 'Sharma Enterprises', phone: '9810000101', creditDays: 15 });
  const b = await api('POST', '/parties', { type: 'customer', name: 'Anita Desai', phone: '9810000102' });
  await api('POST', '/parties', { type: 'vendor', name: 'City Suppliers', phone: '9810000103', creditDays: 30 });
  const s1 = await api('POST', '/items', { name: 'Service charge', unit: 'nos', gstRate: 18, salePrice: 1500, trackStock: false });
  const s2 = await api('POST', '/items', { name: 'Annual maintenance', unit: 'nos', gstRate: 18, salePrice: 12000, trackStock: false });
  await api('POST', '/invoices', { locationId: location.id, partyId: a.id, lines: [{ itemId: s1.id, qty: 4 }, { itemId: s2.id, qty: 1 }] });
  await api('POST', '/invoices', { locationId: location.id, partyId: b.id, lines: [{ itemId: s1.id, qty: 2 }] });
  const cash = rows(await api('GET', '/accounts')).find((x) => x.code === '1000');
  if (cash) await api('POST', '/payments', { kind: 'receipt', partyId: b.id, accountId: cash.id, mode: 'cash', amount: 3540 });
}

async function create(t: BusinessType, name: string, email: string, plan: string, country: string): Promise<Account> {
  const roles = planOf(plan).maxUsers === 1 ? [] : t.roles.map((r) => ({ role: r.name, email: roleEmail(email.split('@')[0]!, r.name) }));
  const account: Account = { type: t, name, email, plan, country, roles, status: 'exists' };
  const login = await app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email, password: PASSWORD } });
  if (login.statusCode === 200) return account;
  const auth = await call('POST', '/auth/signup', {
    businessName: name, name: `${t.name} Owner`.slice(0, 80), email, password: PASSWORD, phone: '9800000100',
    businessType: t.id, plan, country, ...(country === 'IN' ? { stateCode: '27' } : {}),
  });
  const token: string = auth.accessToken;
  const me = await call('GET', '/me', undefined, token);
  const companyId: string = me.companies[0].id;
  const api = (m: Method, u: string, b?: unknown) => call(m, u, b, token, companyId);
  const roleIds = new Map(rows(await api('GET', '/roles')).map((r) => [r.name as string, r.id as string]));
  for (const r of roles) {
    const roleId = roleIds.get(r.role);
    if (!roleId) { r.email += ' (role missing)'; continue; }
    await api('POST', '/users', { name: `${r.role} (${t.name})`.slice(0, 80), email: r.email, password: PASSWORD, roleId });
  }
  const notes: string[] = [];
  try { await sample(api); } catch (e) { notes.push(`sample data failed: ${(e as Error).message.slice(0, 160)}`); }
  const user = (await sql<{ id: string; tenant_id: string }>`select id, tenant_id from auth_find_user_by_email(${email})`.execute(db)).rows[0]!;
  const enabled: string[] = me.companies[0].enabledModules ?? t.modules;
  const ran = new Set<string>();
  for (const [module, file, fn] of MODULE_SEEDS) {
    if (!enabled.includes(module) && !t.modules.includes(module)) continue;
    if (ran.has(file + fn)) continue;
    ran.add(file + fn);
    const seed = await loadSeed(file, fn);
    if (!seed) { notes.push(`${module}: no sample data yet`); continue; }
    try {
      const options = module === 'memberships' && t.id === 'housing_society' ? { society: true } : undefined;
      await withTenant(db, user.tenant_id, (tx) => seed(tx, { tenantId: user.tenant_id, companyId, userId: user.id }, options));
    } catch (e) { notes.push(`${module} sample failed: ${(e as Error).message.slice(0, 160)}`); }
  }
  // The Doctor role login opens on its own day, so link it to the first doctor of the clinic sample.
  const doctor = roles.find((r) => r.role === 'Doctor');
  if (doctor && (enabled.includes('clinic') || t.modules.includes('clinic'))) {
    await withTenant(db, user.tenant_id, async (tx) => {
      const du = await tx.selectFrom('users').select('id').where('email', '=', doctor.email).executeTakeFirst();
      const first = await tx.selectFrom('clinic_doctors').select('id').where('user_id', 'is', null).orderBy('created_at').executeTakeFirst();
      if (du && first) await tx.updateTable('clinic_doctors').set({ user_id: du.id }).where('id', '=', first.id).execute();
    }).catch((e) => notes.push(`doctor link failed: ${(e as Error).message.slice(0, 120)}`));
  }
  account.status = notes.length ? `created; ${notes.join('; ')}` : 'created';
  return account;
}

try {
  for (const t of BUSINESS_TYPES) {
    const a = await create(t, `Demo ${t.name}`.slice(0, 120), ownerEmail(t.id), PLAN_FOR[t.id] ?? 'business', 'IN');
    accounts.push(a);
    console.log(`${a.status === 'exists' ? 'exists ' : 'created'} ${a.email}${a.status.includes(';') ? `  (${a.status})` : ''}`);
  }
  accounts.push(await create(extra.type, extra.name, ownerEmail(extra.id), 'business', extra.country));

  const group = (id: string) => GROUPS.find((g) => g.id === id)?.name ?? id;
  const lines = [
    '# Demo accounts',
    '',
    `Local demo data only. Every password is \`${PASSWORD}\`. Created by \`npm run db:seed:accounts\` in \`backend/\`.`,
    '',
    '- Super admin over every account: `superadmin@demo.in` (opens on Platform, Overview).',
    '- The original demo company, Demo Builders & Traders: `owner@demo.in`, `accountant@demo.in`, `sales@demo.in`, `supervisor@demo.in`, `pm@demo.in`.',
    '- One company per business type below. The owner login has every permission; each role login sees only what that role allows.',
    '- Plans: `freelancer` is Solo (one user, so no role logins), `proprietorship` is Team, the large companies are Enterprise, the rest Business. `global@demo.in` is a company in the UAE.',
    '',
    '| Business type | Group | Plan | Owner login | Role logins |',
    '|---|---|---|---|---|',
    ...accounts.map((a) => `| ${a.type.id === 'general' && a.country !== 'IN' ? `${a.name} (${a.country})` : a.type.name} | ${group(a.type.group)} | ${planOf(a.plan).name} | \`${a.email}\` | ${a.roles.map((r) => `${r.role}: \`${r.email}\``).join('<br>') || '-'} |`),
    '',
  ];
  writeFileSync(new URL('../../../docs/demo-accounts.md', import.meta.url), lines.join('\n'));
  console.log(`Wrote docs/demo-accounts.md with ${accounts.length} accounts.`);
} finally {
  await app.close();
  await db.destroy();
}
