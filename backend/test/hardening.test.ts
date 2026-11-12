// v1.8.1 fixes for defects D-01 to D-10 (docs/qa/defect-register.md).
import { sql } from 'kysely';
import { decodeJwt } from 'jose';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.ts';
import { loadConfig, ssoAllowPrivate } from '../src/config.ts';
import { createDb, withTenant } from '../src/db/database.ts';
import { csvCell } from '../src/lib/csv.ts';
import { discover, isPrivateAddress } from '../src/lib/oidc.ts';
import { pdfHasActiveContent } from '../src/modules/files.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
const base = { ...process.env, DATABASE_URL: process.env.TEST_DATABASE_URL, LOG_LEVEL: 'silent' };

beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

describe('configuration (D-01, D-02, D-05)', () => {
  const prod = { ...base, NODE_ENV: 'production', CORS_ORIGINS: 'https://app.example.in', DATA_KEY: Buffer.alloc(32, 7).toString('base64') };

  it('refuses * origins and a missing DATA_KEY in production', () => {
    expect(() => loadConfig({ ...prod, CORS_ORIGINS: '*' })).toThrow(/CORS_ORIGINS/);
    expect(() => loadConfig({ ...prod, DATA_KEY: undefined })).toThrow(/DATA_KEY/);
    expect(loadConfig(prod).NODE_ENV).toBe('production');
    // Development keeps the easy defaults.
    expect(loadConfig({ ...base, NODE_ENV: 'development', CORS_ORIGINS: '*', DATA_KEY: undefined }).CORS_ORIGINS).toBe('*');
  });

  it('trusts no proxy unless told to', () => {
    expect(loadConfig({ ...base, TRUST_PROXY: undefined }).TRUST_PROXY).toBe(false);
    expect(loadConfig({ ...base, TRUST_PROXY: '1' }).TRUST_PROXY).toBe(1);
    expect(loadConfig({ ...base, TRUST_PROXY: '10.0.0.1, 10.0.0.2' }).TRUST_PROXY).toEqual(['10.0.0.1', '10.0.0.2']);
  });

  it('blocks private SSO issuers in production only, unless allowed', () => {
    expect(ssoAllowPrivate(loadConfig(prod))).toBe(false);
    expect(ssoAllowPrivate(loadConfig({ ...prod, SSO_ALLOW_PRIVATE_ISSUERS: 'true' }))).toBe(true);
    expect(ssoAllowPrivate(loadConfig({ ...base, NODE_ENV: 'development' }))).toBe(true);
  });
});

describe('rate limits (D-02)', () => {
  it('limits every API route per IP, but never /health', async () => {
    const config = loadConfig({ ...base, RATE_LIMIT_PER_MINUTE: '3' });
    const db = createDb(process.env.TEST_DATABASE_URL!, 2);
    const app = await buildApp({ config, db, logger: false });
    try {
      const codes = [];
      for (let i = 0; i < 4; i++) codes.push((await app.inject({ method: 'GET', url: '/api/v1/me' })).statusCode);
      expect(codes).toEqual([401, 401, 401, 429]);
      const res = await app.inject({ method: 'GET', url: '/api/v1/me' });
      expect(res.json().error.code).toBe('RATE_LIMITED');
      for (let i = 0; i < 5; i++) expect((await app.inject({ method: 'GET', url: '/health' })).statusCode).toBe(200);
    } finally {
      await app.close();
      await db.destroy();
    }
  });
});

describe('CSV formula guard (D-03)', () => {
  it('neutralises formulas but keeps numbers', () => {
    for (const bad of ['=1+2', '+91 98', '@SUM(A1)', '-2+3', '\tcmd', '\rcmd', '-cmd|calc']) {
      expect(csvCell(bad).replace(/^"/, '').startsWith("'")).toBe(true);
    }
    expect(csvCell('-1200.50')).toBe('-1200.50');
    expect(csvCell(-5)).toBe('-5');
    expect(csvCell('Rs 10')).toBe('Rs 10');
  });
});

describe('SSO discovery (D-04)', () => {
  it('knows private and public addresses', () => {
    for (const ip of ['127.0.0.1', '10.1.2.3', '172.20.0.5', '192.168.1.1', '169.254.169.254', '100.64.0.1', '0.0.0.0', '::1', 'fd00::1', 'fe80::1', '::ffff:192.168.1.1']) {
      expect(isPrivateAddress(ip), ip).toBe(true);
    }
    for (const ip of ['8.8.8.8', '1.1.1.1', '2606:4700:4700::1111']) expect(isPrivateAddress(ip), ip).toBe(false);
  });

  it('refuses an issuer on a private address before fetching anything', async () => {
    await expect(discover('http://127.0.0.1:9', { allowPrivate: false })).rejects.toMatchObject({ code: 'SSO_DISCOVERY_FAILED' });
    await expect(discover('https://10.0.0.8/realms/x', { allowPrivate: false })).rejects.toThrow(/private network/);
  });
});

describe('health check (D-06)', () => {
  it('reports the database', async () => {
    const res = await env.app.inject({ method: 'GET', url: '/health' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ status: 'ok', db: 'ok' });
  });
});

describe('uploads (D-08)', () => {
  it('spots scripts and launch actions in PDFs', () => {
    const pdf = (body: string) => Buffer.from(`%PDF-1.7\n${body}\n%%EOF`, 'latin1');
    expect(pdfHasActiveContent(pdf('<< /OpenAction << /S /JavaScript /JS (app.alert(1)) >> >>'))).toBe(true);
    expect(pdfHasActiveContent(pdf('<< /S /J#61vaScript >>'))).toBe(true);
    expect(pdfHasActiveContent(pdf('<< /S /Launch /F (cmd.exe) >>'))).toBe(true);
    expect(pdfHasActiveContent(pdf('<< /Type /Catalog /Pages 2 0 R /JSONData 3 0 R >>'))).toBe(false);
  });

  it('rejects such a PDF at upload', async () => {
    const res = await client(env.app)('POST', '/auth/signup', {
      businessName: 'Upload Co', name: 'Owner', email: uniqueEmail('up'), password: 'Secret@123', stateCode: '24',
    });
    const token = res.body.accessToken as string;
    const boundary = 'x1b2';
    const body = Buffer.concat([
      Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="bill.pdf"\r\nContent-Type: application/pdf\r\n\r\n`),
      Buffer.from('%PDF-1.4\n<< /OpenAction << /S /JavaScript /JS (x) >> >>\n%%EOF'),
      Buffer.from(`\r\n--${boundary}--\r\n`),
    ]);
    const up = await env.app.inject({
      method: 'POST', url: '/api/v1/files', payload: body,
      headers: { authorization: `Bearer ${token}`, 'content-type': `multipart/form-data; boundary=${boundary}` },
    });
    expect(up.statusCode).toBe(400);
    expect(up.json().error.details.file).toBe('Active content');
  });
});

describe('job claims (D-10)', () => {
  it('re-queues a running job only when its heartbeat is stale', async () => {
    const res = await client(env.app)('POST', '/auth/signup', {
      businessName: 'Jobs Co', name: 'Owner', email: uniqueEmail('jobs'), password: 'Secret@123', stateCode: '24',
    });
    const tenantId = decodeJwt(res.body.accessToken as string).tid as string;
    const old = new Date(Date.now() - 20 * 60_000);
    const [alive, dead] = await withTenant(env.db, tenantId, async (tx) => Promise.all([
      tx.insertInto('jobs').values({ tenant_id: tenantId, company_id: null, kind: 'test.alive', status: 'running', started_at: old, heartbeat_at: new Date() })
        .returning('id').executeTakeFirstOrThrow(),
      tx.insertInto('jobs').values({ tenant_id: tenantId, company_id: null, kind: 'test.dead', status: 'running', started_at: old, heartbeat_at: old })
        .returning('id').executeTakeFirstOrThrow(),
    ]));
    const claimed = (await sql<{ id: string }>`select id from jobs_claim(100)`.execute(env.db)).rows.map((r) => r.id);
    expect(claimed).toContain(dead!.id);
    expect(claimed).not.toContain(alive!.id);

    // A heartbeat renews the claim.
    await sql`select jobs_heartbeat(${dead!.id}::uuid)`.execute(env.db);
    const row = await withTenant(env.db, tenantId, (tx) => tx.selectFrom('jobs').select(['status', 'heartbeat_at']).where('id', '=', dead!.id).executeTakeFirstOrThrow());
    expect(row.status).toBe('running');
    expect(row.heartbeat_at!.getTime()).toBeGreaterThan(Date.now() - 60_000);
  });
});
