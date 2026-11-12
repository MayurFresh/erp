import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addDays, financialYear, todayIst } from '../src/lib/dates.ts';
import { blockDepreciation, bookDepreciation } from '../src/lib/depreciation.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => {
  env = await setupTestApp();
});
afterAll(async () => {
  await teardown(env);
});

async function business() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Asset Co', name: 'Meera Shah', email: uniqueEmail('owner'), password: 'Secret@123', stateCode: '24',
  });
  expect(res.status).toBe(201);
  const token = res.body.accessToken as string;
  const me = (await client(env.app, token)('GET', '/me')).body;
  const api = client(env.app, token, me.companies[0].id as string);
  const balance = async (name: string) => ((await api('GET', '/accounts')).body.data as any[]).find((a) => a.name === name).balance as number;
  const bank = ((await api('GET', '/accounts')).body.data as any[]).find((a) => a.code === '1010');
  return { api, balance, bank };
}

describe('depreciation maths', () => {
  it('SLM, WDV, residual floor', () => {
    expect(bookDepreciation({ method: 'slm', cost: 100000, residualPct: 5, lifeYears: 5, accumulated: 0 }, 365)).toBe(19000);
    const wdv = bookDepreciation({ method: 'wdv', cost: 100000, residualPct: 5, lifeYears: 5, accumulated: 0 }, 365);
    expect(wdv).toBeGreaterThan(40000);
    expect(wdv).toBeLessThan(46000);
    // floor: never below the residual
    expect(bookDepreciation({ method: 'slm', cost: 100000, residualPct: 5, lifeYears: 5, accumulated: 94000 }, 365)).toBe(1000);
    expect(bookDepreciation({ method: 'slm', cost: 100000, residualPct: 5, lifeYears: 5, accumulated: 95000 }, 365)).toBe(0);
  });
  it('IT block: half rate and sale netting', () => {
    const b = blockDepreciation({ rate: 40, opening: 100000, additionsFull: 0, additionsHalf: 50000, saleValue: 0 });
    expect(b.depreciation).toBe(50000);
    expect(b.closingWdv).toBe(100000);
    const s = blockDepreciation({ rate: 40, opening: 100000, additionsFull: 0, additionsHalf: 50000, saleValue: 120000 });
    expect(s.depreciation).toBe(6000); // 30000 of the half addition is left, at half rate
    expect(s.shortTermGain).toBe(0);
    expect(blockDepreciation({ rate: 40, opening: 100000, additionsFull: 0, additionsHalf: 0, saleValue: 130000 }).shortTermGain).toBe(30000);
  });
});

describe('fixed assets', () => {
  it('capitalises, runs depreciation, cancels and guards order', async () => {
    const b = await business();
    const today = todayIst();
    const put = addDays(today, -100);
    const created = await b.api('POST', '/fixed-assets', {
      name: 'Laptop', blockCode: 'computer', bookMethod: 'slm', usefulLifeYears: 5, cost: 100000, purchaseDate: put, putToUseDate: put, sourceAccountId: b.bank.id,
    });
    expect(created.status).toBe(201);
    expect(created.body).toMatchObject({ cost: 100000, accumulatedDep: 0, bookValue: 100000, status: 'active' });
    expect(created.body.number).toMatch(/^FA/);
    expect(await b.balance('Fixed Assets')).toBe(100000);
    expect(await b.balance('Cash in Hand')).toBeDefined();

    const toDate = addDays(today, -30);
    const prev = await b.api('POST', '/fixed-assets/depreciation-runs?preview=true', { toDate });
    expect(prev.status).toBe(200);
    expect(prev.body.id).toBeNull();
    expect(prev.body.lines).toHaveLength(1);
    expect(await b.balance('Accumulated Depreciation')).toBe(0);

    const run = await b.api('POST', '/fixed-assets/depreciation-runs', { toDate });
    expect(run.status).toBe(201);
    expect(run.body.total).toBe(prev.body.total);
    expect(run.body.entryId).toBeTruthy();
    expect(await b.balance('Accumulated Depreciation')).toBe(-run.body.total);
    const asset = (await b.api('GET', `/fixed-assets/${created.body.id}`)).body;
    expect(asset.depreciatedUntil).toBe(toDate);
    expect(asset.history.length).toBeGreaterThan(0);

    const again = await b.api('POST', '/fixed-assets/depreciation-runs', { toDate });
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('RUN_OVERLAP');

    const run2 = await b.api('POST', '/fixed-assets/depreciation-runs', { toDate: addDays(today, -10) });
    expect(run2.status).toBe(201);
    const notLatest = await b.api('POST', `/fixed-assets/depreciation-runs/${run.body.id}/cancel`, { reason: 'redo' });
    expect(notLatest.status).toBe(409);
    expect(notLatest.body.error.code).toBe('NOT_LATEST');
    expect((await b.api('POST', `/fixed-assets/depreciation-runs/${run2.body.id}/cancel`, { reason: 'redo' })).status).toBe(200);
    expect((await b.api('POST', `/fixed-assets/depreciation-runs/${run.body.id}/cancel`, { reason: 'redo' })).status).toBe(200);
    expect((await b.api('GET', `/fixed-assets/${created.body.id}`)).body.depreciatedUntil).toBeNull();
    expect(await b.balance('Accumulated Depreciation')).toBe(0);
  });

  it('opening asset with accumulated depreciation', async () => {
    const b = await business();
    const opening = ((await b.api('GET', '/accounts')).body.data as any[]).find((a) => a.name === 'Opening Balances');
    const r = await b.api('POST', '/fixed-assets', {
      name: 'Old building', blockCode: 'building', bookMethod: 'slm', usefulLifeYears: 30, cost: 1000000, purchaseDate: '2020-04-01', putToUseDate: '2020-04-01',
      sourceAccountId: opening.id, openingAccDep: 200000,
    });
    expect(r.status).toBe(201);
    expect(r.body).toMatchObject({ openingAccDep: 200000, accumulatedDep: 200000, bookValue: 800000 });
    expect(await b.balance('Accumulated Depreciation')).toBe(-200000);
    const bad = await b.api('POST', '/fixed-assets', {
      name: 'x', blockCode: 'building', bookMethod: 'slm', usefulLifeYears: 5, cost: 100, purchaseDate: today(), putToUseDate: addDays(today(), -5), sourceAccountId: opening.id,
    });
    expect(bad.status).toBe(400);
  });

  it('disposes with a gain and with a loss', async () => {
    const b = await business();
    const put = addDays(todayIst(), -200);
    const mk = async (name: string) => (await b.api('POST', '/fixed-assets', {
      name, blockCode: 'plant', bookMethod: 'slm', usefulLifeYears: 10, cost: 100000, purchaseDate: put, putToUseDate: put, sourceAccountId: b.bank.id,
    })).body;
    const a1 = await mk('Mixer');
    const a2 = await mk('Crusher');
    const gain = await b.api('POST', `/fixed-assets/${a1.id}/dispose`, { date: todayIst(), saleValue: 150000, receivedInAccountId: b.bank.id });
    expect(gain.status).toBe(200);
    expect(gain.body.status).toBe('disposed');
    expect(gain.body.disposal.gainLoss).toBeGreaterThan(0);
    const loss = await b.api('POST', `/fixed-assets/${a2.id}/dispose`, { date: todayIst(), saleValue: 0 });
    expect(loss.status).toBe(200);
    expect(loss.body.disposal.gainLoss).toBeLessThan(0);
    const noAcc = await b.api('POST', `/fixed-assets/${(await mk('Pump')).id}/dispose`, { date: todayIst(), saleValue: 500 });
    expect(noAcc.status).toBe(400);
    expect((await b.api('POST', `/fixed-assets/${a1.id}/dispose`, { date: todayIst(), saleValue: 0 })).status).toBe(409);
    expect(await b.balance('Fixed Assets')).toBe(100000);
  });

  it('chains the IT schedule from the openings', async () => {
    const b = await business();
    const fy = financialYear(todayIst());
    const up = await b.api('POST', '/fixed-assets/it-openings', { fy, blockCode: 'plant', openingWdv: 200000 });
    expect(up.status).toBe(200);
    expect(up.body).toMatchObject({ fy, blockCode: 'plant', openingWdv: 200000 });
    const s = await b.api('GET', `/fixed-assets/it-schedule?fy=${fy}`);
    expect(s.status).toBe(200);
    const row = s.body.rows.find((r: any) => r.blockCode === 'plant');
    expect(row).toMatchObject({ openingWdv: 200000, depreciation: 30000, closingWdv: 170000 });
    const next = `${Number(fy.slice(0, 4)) + 1}-${String(Number(fy.slice(5)) + 1).padStart(2, '0')}`;
    const n = await b.api('GET', `/fixed-assets/it-schedule?fy=${next}`);
    expect(n.body.rows.find((r: any) => r.blockCode === 'plant').openingWdv).toBe(170000);
    expect((await b.api('GET', '/fixed-assets/blocks')).body.data.length).toBeGreaterThan(8);
  });
});

const today = todayIst;
