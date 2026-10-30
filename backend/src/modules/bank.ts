import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { postJournal } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { parseCsv } from '../lib/csv.ts';
import { addDays, daysBetween, financialYear, isValidDate } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const AUTO_DAYS = 3;
const CANDIDATE_DAYS = 10;

const DATE_FORMATS = ['dd/mm/yyyy', 'dd-mm-yyyy', 'yyyy-mm-dd', 'dd-MMM-yyyy', 'dd/mm/yy'] as const;
const mappingSchema = z.object({
  date: z.string().optional(), description: z.string().optional(), reference: z.string().optional(), withdrawal: z.string().optional(),
  deposit: z.string().optional(), amount: z.string().optional(), balance: z.string().optional(), dateFormat: z.enum(DATE_FORMATS).optional(),
});
const importBody = z.object({
  accountId: z.uuid(), fileName: z.string().trim().max(200).optional(), csv: z.string().min(1).max(10_000_000), mapping: mappingSchema.optional(),
});

// Header names of common Indian bank exports, normalised (lower case, letters and digits only), best first.
const HEADERS = {
  date: ['transactiondate', 'txndate', 'trandate', 'date', 'valuedate', 'postingdate'],
  description: ['narration', 'description', 'particulars', 'remarks', 'transactiondetails', 'transactionremarks'],
  reference: ['chqrefno', 'refnochqno', 'refno', 'chequeno', 'utr', 'referenceno', 'chqno', 'chequerefno', 'refchqno'],
  withdrawal: ['withdrawal', 'withdrawalamt', 'debit', 'debitamount', 'withdrawalamount', 'dr'],
  deposit: ['deposit', 'depositamt', 'credit', 'creditamount', 'depositamount', 'cr'],
  amount: ['amount', 'transactionamount', 'amountinr'],
  balance: ['balance', 'closingbalance', 'runningbalance'],
} as const;
type Field = keyof typeof HEADERS;
const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, '');

function detectColumns(row: string[]): Partial<Record<Field, number>> {
  const keys = row.map(norm);
  const found: Partial<Record<Field, number>> = {};
  for (const f of Object.keys(HEADERS) as Field[]) {
    for (const cand of HEADERS[f]) {
      const i = keys.indexOf(cand);
      if (i >= 0) { found[f] = i; break; }
    }
    if (found[f] === undefined) {
      const i = keys.findIndex((k) => HEADERS[f].some((c) => c.length > 3 && k.startsWith(c)));
      if (i >= 0) found[f] = i;
    }
  }
  return found;
}

const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
/** Parses the date styles Indian banks use; day always comes first except in ISO dates. */
export function parseBankDate(raw: string): string | null {
  const s = raw.trim();
  let y: number; let m: number; let d: number;
  let r: RegExpExecArray | null;
  if ((r = /^(\d{4})-(\d{1,2})-(\d{1,2})/.exec(s))) { y = +r[1]!; m = +r[2]!; d = +r[3]!; }
  else if ((r = /^(\d{1,2})[/-](\d{1,2})[/-](\d{4})/.exec(s))) { d = +r[1]!; m = +r[2]!; y = +r[3]!; }
  else if ((r = /^(\d{1,2})[/-](\d{1,2})[/-](\d{2})\b/.exec(s))) { d = +r[1]!; m = +r[2]!; y = 2000 + +r[3]!; }
  else if ((r = /^(\d{1,2})[-/ ]([A-Za-z]{3})[a-z]*[-/ ](\d{2,4})/.exec(s))) {
    d = +r[1]!; m = MONTHS.indexOf(r[2]!.toLowerCase()) + 1; y = r[3]!.length === 2 ? 2000 + +r[3]! : +r[3]!;
    if (m < 1) return null;
  } else return null;
  const iso = `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
  return isValidDate(iso) ? iso : null;
}

/** Amount text to a number: strips commas and currency marks; (123) and a trailing Dr are negative. */
function parseAmount(raw: string | undefined): number | null {
  if (raw === undefined) return null;
  let s = raw.trim();
  if (!s) return null;
  let neg = false;
  if (/^\(.*\)$/.test(s)) { neg = true; s = s.slice(1, -1); }
  if (/dr\.?$/i.test(s)) { neg = true; s = s.replace(/dr\.?$/i, ''); } else s = s.replace(/cr\.?$/i, '');
  s = s.replace(/[₹,\s]|rs\.?|inr/gi, '');
  if (s.startsWith('-')) { neg = !neg; s = s.slice(1); }
  const n = Number(s);
  if (!Number.isFinite(n)) return null;
  return round2(neg ? -n : n);
}

interface ParsedLine { date: string; description: string; reference: string | null; withdrawal: number; deposit: number; balance: number | null }

function parseStatement(csv: string, mapping?: z.infer<typeof mappingSchema>): ParsedLine[] {
  const rows = parseCsv(csv);
  let headerIdx = -1;
  let cols: Partial<Record<Field, number>> = {};
  if (mapping && (mapping.date || mapping.amount || mapping.withdrawal || mapping.deposit)) {
    // Explicit mapping: find the row that holds the named headers.
    for (let i = 0; i < Math.min(rows.length, 30); i++) {
      const keys = rows[i]!.map(norm);
      const idx = (name?: string) => (name ? keys.indexOf(norm(name)) : -1);
      if (mapping.date && idx(mapping.date) >= 0) {
        headerIdx = i;
        for (const f of Object.keys(HEADERS) as Field[]) { const j = idx(mapping[f]); if (j >= 0) cols[f] = j; }
        break;
      }
    }
  } else {
    for (let i = 0; i < Math.min(rows.length, 30); i++) {
      const c = detectColumns(rows[i]!);
      if (c.date !== undefined && (c.amount !== undefined || c.withdrawal !== undefined || c.deposit !== undefined)) { headerIdx = i; cols = c; break; }
    }
  }
  if (headerIdx < 0 || cols.date === undefined) {
    throw badRequest('Could not find the Date and amount columns. Send a column mapping.', { csv: 'Header not recognised' });
  }
  if (cols.amount === undefined && cols.withdrawal === undefined && cols.deposit === undefined) {
    throw badRequest('Could not find withdrawal, deposit or amount columns.', { csv: 'No amount columns' });
  }
  const out: ParsedLine[] = [];
  for (const r of rows.slice(headerIdx + 1)) {
    const date = parseBankDate(r[cols.date] ?? '');
    if (!date) continue; // footers, totals and blank lines
    let withdrawal = 0;
    let deposit = 0;
    if (cols.withdrawal !== undefined || cols.deposit !== undefined) {
      withdrawal = Math.abs(parseAmount(r[cols.withdrawal ?? -1]) ?? 0);
      deposit = Math.abs(parseAmount(r[cols.deposit ?? -1]) ?? 0);
    } else {
      const a = parseAmount(r[cols.amount!]) ?? 0;
      if (a < 0) withdrawal = -a; else deposit = a;
    }
    if (withdrawal === 0 && deposit === 0) continue;
    if (withdrawal > 0 && deposit > 0) throw badRequest(`A row on ${date} has both a withdrawal and a deposit.`, { csv: 'Row has both' });
    out.push({
      date, description: (cols.description !== undefined ? r[cols.description] ?? '' : '').trim().slice(0, 500),
      reference: (cols.reference !== undefined ? (r[cols.reference] ?? '').trim() : '') || null,
      withdrawal, deposit, balance: cols.balance !== undefined ? parseAmount(r[cols.balance]) : null,
    });
  }
  if (!out.length) throw badRequest('No transactions found in the CSV.', { csv: 'No rows' });
  return out;
}

// ---- Matching --------------------------------------------------------------------------------

interface BookLine { journalLineId: string; entryId: string; voucherType: string; number: string | null; date: string; narration: string | null; debit: number; credit: number; partyName: string | null; reference: string | null }

/** Journal lines of the bank account that are live (not reversed, not a reversal) and not yet matched, within a date window. */
async function bookLines(tx: Tx, accountId: string, from: string, to: string, includeMatched = false): Promise<BookLine[]> {
  let q = tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .leftJoin('parties as p', 'p.id', 'jl.party_id')
    .leftJoin('payments as pay', (j) => j.onRef('pay.id', '=', 'je.voucher_id').on('je.voucher_type', 'in', ['receipt', 'payment']))
    .select(['jl.id as journal_line_id', 'je.id as entry_id', 'je.voucher_type', 'je.number', 'je.entry_date', 'je.narration', 'jl.debit', 'jl.credit', 'p.name as party_name', 'pay.reference'])
    .where('jl.account_id', '=', accountId).where('je.entry_date', '>=', from).where('je.entry_date', '<=', to)
    .where('je.is_reversal', '=', false)
    .where((eb) => eb.not(eb.exists(eb.selectFrom('journal_entries as r').select('r.id').whereRef('r.reverses_id', '=', 'je.id'))));
  if (!includeMatched) {
    q = q.where((eb) => eb.not(eb.exists(eb.selectFrom('bank_statement_lines as b').select('b.id').whereRef('b.journal_line_id', '=', 'jl.id'))));
  }
  return (await q.orderBy('je.entry_date').orderBy('jl.line_no').execute()).map((r) => ({
    journalLineId: r.journal_line_id, entryId: r.entry_id, voucherType: r.voucher_type, number: r.number, date: r.entry_date,
    narration: r.narration, debit: r.debit, credit: r.credit, partyName: r.party_name, reference: r.reference,
  }));
}

interface LineLike { txn_date: string; description: string; reference: string | null; withdrawal: number; deposit: number }

const directionMatches = (l: LineLike, b: BookLine) => (l.deposit > 0 ? b.debit === l.deposit : b.credit === l.withdrawal);

/** A reference or a 12-digit UTR/UPI number from the line found in the book entry's payment reference or narration. */
function refHit(l: LineLike, b: BookLine): boolean {
  const hay = `${b.reference ?? ''} ${b.narration ?? ''}`.toLowerCase();
  const tokens = new Set<string>();
  if (l.reference && l.reference.length >= 4) tokens.add(l.reference.toLowerCase());
  for (const m of l.description.match(/\b\d{12}\b/g) ?? []) tokens.add(m);
  return [...tokens].some((t) => hay.includes(t));
}

function pickMatch(l: LineLike, pool: BookLine[], days: number, used: Set<string>): BookLine | null {
  const cands = pool.filter((b) => !used.has(b.journalLineId) && directionMatches(l, b) && Math.abs(daysBetween(l.txn_date, b.date)) <= days);
  const winners = cands.filter((b) => refHit(l, b));
  if (winners.length) return winners.sort((a, b) => Math.abs(daysBetween(l.txn_date, a.date)) - Math.abs(daysBetween(l.txn_date, b.date)))[0]!;
  return cands.length === 1 ? cands[0]! : null;
}

async function autoMatch(tx: Tx, ctx: RequestContext, statementId: string): Promise<number> {
  const st = await tx.selectFrom('bank_statements').select(['account_id', 'from_date', 'to_date']).where('id', '=', statementId).executeTakeFirstOrThrow();
  if (!st.from_date || !st.to_date) return 0;
  const lines = await tx.selectFrom('bank_statement_lines').selectAll().where('statement_id', '=', statementId).where('status', '=', 'unmatched').orderBy('line_no').execute();
  if (!lines.length) return 0;
  const pool = await bookLines(tx, st.account_id, addDays(st.from_date, -AUTO_DAYS), addDays(st.to_date, AUTO_DAYS));
  const used = new Set<string>();
  let matched = 0;
  // Reference hits first so a plain amount match cannot steal their entry.
  const order = [...lines].sort((a, b) => Number(pool.some((p) => refHit(b, p))) - Number(pool.some((p) => refHit(a, p))));
  for (const l of order) {
    const hit = pickMatch(l, pool, AUTO_DAYS, used);
    if (!hit) continue;
    used.add(hit.journalLineId);
    await tx.updateTable('bank_statement_lines').set({ status: 'matched', journal_line_id: hit.journalLineId, matched_by: ctx.userId, matched_at: new Date() }).where('id', '=', l.id).execute();
    matched++;
  }
  return matched;
}

// ---- JSON shapes ---------------------------------------------------------------------------------

async function statementJson(tx: Tx, ctx: RequestContext, ids?: string[], accountId?: string) {
  let q = tx.selectFrom('bank_statements as s').innerJoin('accounts as a', 'a.id', 's.account_id').selectAll('s').select('a.name as account_name')
    .where('s.company_id', '=', ctx.companyId);
  if (ids) q = q.where('s.id', 'in', ids);
  if (accountId) q = q.where('s.account_id', '=', accountId);
  const rows = await q.orderBy('s.created_at', 'desc').execute();
  if (!rows.length) return [];
  const counts = await tx.selectFrom('bank_statement_lines').select(['statement_id', 'status', (eb) => eb.fn.countAll<number>().as('n')])
    .where('statement_id', 'in', rows.map((r) => r.id)).groupBy(['statement_id', 'status']).execute();
  const n = (id: string, st?: string) => counts.filter((c) => c.statement_id === id && (!st || c.status === st)).reduce((s, c) => s + Number(c.n), 0);
  return rows.map((r) => ({
    id: r.id, accountId: r.account_id, accountName: r.account_name, fileName: r.file_name, fromDate: r.from_date, toDate: r.to_date,
    closingBalance: r.closing_balance, lines: n(r.id), matched: n(r.id, 'matched'), unmatched: n(r.id, 'unmatched'), ignored: n(r.id, 'ignored'), createdAt: r.created_at,
  }));
}

async function lineJson(tx: Tx, ctx: RequestContext, ids: string[]) {
  const rows = await tx.selectFrom('bank_statement_lines as l')
    .leftJoin('journal_lines as jl', 'jl.id', 'l.journal_line_id').leftJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .select(['l.id', 'l.line_no', 'l.txn_date', 'l.description', 'l.reference', 'l.withdrawal', 'l.deposit', 'l.balance', 'l.status',
      'jl.id as jl_id', 'je.id as entry_id', 'je.voucher_type', 'je.number', 'je.entry_date', 'je.narration', 'jl.debit', 'jl.credit'])
    .where('l.company_id', '=', ctx.companyId).where('l.id', 'in', ids).orderBy('l.line_no').execute();
  return rows.map((r) => ({
    id: r.id, lineNo: r.line_no, date: r.txn_date, description: r.description, reference: r.reference, withdrawal: r.withdrawal, deposit: r.deposit,
    balance: r.balance, status: r.status,
    match: r.jl_id ? { journalLineId: r.jl_id, entryId: r.entry_id!, voucherType: r.voucher_type!, number: r.number, date: r.entry_date!, narration: r.narration, amount: r.debit || r.credit } : null,
  }));
}

async function loadLine(tx: Tx, ctx: RequestContext, id: string) {
  const l = await tx.selectFrom('bank_statement_lines as l').innerJoin('bank_statements as s', 's.id', 'l.statement_id')
    .select(['l.id', 'l.status', 'l.txn_date', 'l.description', 'l.reference', 'l.withdrawal', 'l.deposit', 'l.journal_line_id', 's.account_id'])
    .where('l.id', '=', id).where('l.company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!l) throw notFound('Bank line');
  return l;
}

export async function bankRoutes(app: FastifyInstance) {
  app.post('/bank-statements', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('bank.reconcile');
    const body = parse(importBody, req.body);
    const parsed = parseStatement(body.csv, body.mapping);
    const out = await ctx.tx(async (tx) => {
      const account = await tx.selectFrom('accounts').select(['id', 'subtype', 'is_active']).where('id', '=', body.accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!account || account.subtype !== 'bank') throw badRequest('Choose a bank account.', { accountId: 'Not a bank account' });
      // Skip lines already imported for this account (same date, amounts and reference); identical rows in one file all count.
      const existing = await tx.selectFrom('bank_statement_lines as l').innerJoin('bank_statements as s', 's.id', 'l.statement_id')
        .select(['l.txn_date', 'l.withdrawal', 'l.deposit', 'l.reference']).where('s.account_id', '=', body.accountId).where('l.company_id', '=', ctx.companyId).execute();
      const seen = new Map<string, number>();
      const key = (d: string, w: number, p: number, r: string | null) => `${d}|${w}|${p}|${r ?? ''}`;
      for (const e of existing) seen.set(key(e.txn_date, e.withdrawal, e.deposit, e.reference), (seen.get(key(e.txn_date, e.withdrawal, e.deposit, e.reference)) ?? 0) + 1);
      const fresh = parsed.filter((l) => {
        const k = key(l.date, l.withdrawal, l.deposit, l.reference);
        const c = seen.get(k) ?? 0;
        if (c > 0) { seen.set(k, c - 1); return false; }
        return true;
      });
      const dates = parsed.map((l) => l.date).sort();
      const last = [...fresh].reverse().filter((l) => l.balance !== null).sort((a, b) => b.date.localeCompare(a.date))[0];
      const st = await tx.insertInto('bank_statements').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, account_id: account.id, file_name: body.fileName ?? null,
        from_date: dates[0]!, to_date: dates[dates.length - 1]!, closing_balance: last?.balance ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      for (let i = 0; i < fresh.length; i += 500) {
        await tx.insertInto('bank_statement_lines').values(fresh.slice(i, i + 500).map((l, j) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, statement_id: st.id, line_no: i + j + 1, txn_date: l.date, description: l.description,
          reference: l.reference, withdrawal: l.withdrawal, deposit: l.deposit, balance: l.balance, matched_by: null, matched_at: null, journal_line_id: null,
        }))).execute();
      }
      await autoMatch(tx, ctx, st.id);
      await writeAudit(tx, auditOf(ctx), 'bank_statement', st.id, 'create', null, { lines: fresh.length, skipped: parsed.length - fresh.length });
      return (await statementJson(tx, ctx, [st.id]))[0]!;
    });
    return reply.status(201).send(out);
  });

  app.get('/bank-statements', async (req) => {
    const ctx = req.ctx;
    ctx.require('bank.reconcile');
    const q = parse(z.object({ accountId: z.uuid().optional() }), req.query);
    return ctx.tx(async (tx) => {
      const data = await statementJson(tx, ctx, undefined, q.accountId);
      return { data, total: data.length };
    });
  });

  app.get<{ Params: { id: string } }>('/bank-statements/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('bank.reconcile');
    const id = parse(z.uuid(), req.params.id);
    const q = parse(z.object({ status: z.enum(['unmatched', 'matched', 'ignored']).optional() }), req.query);
    return ctx.tx(async (tx) => {
      const st = (await statementJson(tx, ctx, [id]))[0];
      if (!st) throw notFound('Bank statement');
      let lq = tx.selectFrom('bank_statement_lines').select('id').where('statement_id', '=', id);
      if (q.status) lq = lq.where('status', '=', q.status);
      const ids = (await lq.execute()).map((r) => r.id);
      const lines = ids.length ? await lineJson(tx, ctx, ids) : [];
      const bal = st.toDate
        ? await tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
          .select((eb) => [eb.fn.coalesce(eb.fn.sum<number>('jl.debit'), eb.lit(0)).as('d'), eb.fn.coalesce(eb.fn.sum<number>('jl.credit'), eb.lit(0)).as('c')])
          .where('jl.account_id', '=', st.accountId).where('je.entry_date', '<=', st.toDate).executeTakeFirstOrThrow()
        : { d: 0, c: 0 };
      const unmatchedBook = st.fromDate && st.toDate ? (await bookLines(tx, st.accountId, st.fromDate, st.toDate)).length : 0;
      return { ...st, lines, bookBalance: round2(Number(bal.d) - Number(bal.c)), unmatchedBook };
    });
  });

  app.post<{ Params: { id: string } }>('/bank-statements/:id/auto-match', async (req) => {
    const ctx = req.ctx;
    ctx.require('bank.reconcile');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const st = await tx.selectFrom('bank_statements').select('id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!st) throw notFound('Bank statement');
      return { matched: await autoMatch(tx, ctx, id) };
    });
  });

  app.get<{ Params: { id: string } }>('/bank-lines/:id/candidates', async (req) => {
    const ctx = req.ctx;
    ctx.require('bank.reconcile');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const l = await loadLine(tx, ctx, id);
      const pool = await bookLines(tx, l.account_id, addDays(l.txn_date, -CANDIDATE_DAYS), addDays(l.txn_date, CANDIDATE_DAYS));
      const data = pool.filter((b) => directionMatches(l, b)).map((b) => ({
        journalLineId: b.journalLineId, entryId: b.entryId, voucherType: b.voucherType, number: b.number, date: b.date, narration: b.narration,
        amount: b.debit || b.credit, partyName: b.partyName, score: 100 - 5 * Math.abs(daysBetween(l.txn_date, b.date)) + (refHit(l, b) ? 50 : 0),
      })).sort((a, b) => b.score - a.score);
      return { data };
    });
  });

  app.post<{ Params: { id: string } }>('/bank-lines/:id/match', async (req) => {
    const ctx = req.ctx;
    ctx.require('bank.reconcile');
    const id = parse(z.uuid(), req.params.id);
    const { journalLineId } = parse(z.object({ journalLineId: z.uuid() }), req.body);
    return ctx.tx(async (tx) => {
      const l = await loadLine(tx, ctx, id);
      if (l.status !== 'unmatched') throw conflict('This line is already matched or ignored. Unmatch it first.', 'NOT_UNMATCHED');
      const jl = await tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
        .select(['jl.id', 'jl.debit', 'jl.credit']).where('jl.id', '=', journalLineId).where('je.company_id', '=', ctx.companyId).where('jl.account_id', '=', l.account_id).executeTakeFirst();
      if (!jl) throw badRequest('That journal line is not on this bank account.', { journalLineId: 'Not on this account' });
      if (!(l.deposit > 0 ? jl.debit === l.deposit : jl.credit === l.withdrawal)) {
        throw badRequest('Amount or direction does not match the statement line.', { journalLineId: 'Amount mismatch' });
      }
      const taken = await tx.selectFrom('bank_statement_lines').select('id').where('journal_line_id', '=', journalLineId).executeTakeFirst();
      if (taken) throw conflict('That journal line is already matched to another statement line.', 'ALREADY_MATCHED');
      await tx.updateTable('bank_statement_lines').set({ status: 'matched', journal_line_id: journalLineId, matched_by: ctx.userId, matched_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'bank_line', id, 'match', null, { journalLineId });
      return (await lineJson(tx, ctx, [id]))[0]!;
    });
  });

  app.post<{ Params: { id: string } }>('/bank-lines/:id/unmatch', async (req) => {
    const ctx = req.ctx;
    ctx.require('bank.reconcile');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const l = await loadLine(tx, ctx, id);
      if (l.status === 'unmatched') return (await lineJson(tx, ctx, [id]))[0]!;
      await tx.updateTable('bank_statement_lines').set({ status: 'unmatched', journal_line_id: null, matched_by: null, matched_at: null }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'bank_line', id, 'unmatch', { status: l.status }, { status: 'unmatched' });
      return (await lineJson(tx, ctx, [id]))[0]!;
    });
  });

  app.post<{ Params: { id: string } }>('/bank-lines/:id/ignore', async (req) => {
    const ctx = req.ctx;
    ctx.require('bank.reconcile');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const l = await loadLine(tx, ctx, id);
      if (l.status === 'matched') throw conflict('Unmatch this line before ignoring it.', 'ALREADY_MATCHED');
      await tx.updateTable('bank_statement_lines').set({ status: 'ignored' }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'bank_line', id, 'ignore', { status: l.status }, { status: 'ignored' });
      return (await lineJson(tx, ctx, [id]))[0]!;
    });
  });

  app.post<{ Params: { id: string } }>('/bank-lines/:id/create-entry', async (req) => {
    const ctx = req.ctx;
    ctx.require('bank.reconcile');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(z.object({ accountId: z.uuid(), partyId: z.uuid().nullable().optional(), narration: z.string().trim().max(300).optional() }), req.body);
    return ctx.tx(async (tx) => {
      const l = await loadLine(tx, ctx, id);
      if (l.status !== 'unmatched') throw conflict('Only an unmatched line can get a new entry.', 'NOT_UNMATCHED');
      const contra = await tx.selectFrom('accounts').select(['id', 'subtype', 'is_active', 'name']).where('id', '=', body.accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!contra || !contra.is_active || ['cash', 'bank'].includes(contra.subtype)) {
        throw badRequest('Choose an active account that is not cash or bank.', { accountId: 'Not allowed' });
      }
      if (body.partyId) {
        const p = await tx.selectFrom('parties').select('id').where('id', '=', body.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!p) throw badRequest('Party not found.', { partyId: 'Not found' });
      }
      const amount = l.deposit > 0 ? l.deposit : l.withdrawal;
      const sign = l.deposit > 0 ? 1 : -1; // deposit: Dr bank, Cr contra
      const number = await nextNumber(tx, ctx, 'bank_entry', financialYear(l.txn_date));
      const entryId = await postJournal(tx, auditOf(ctx), {
        date: l.txn_date, voucherType: 'bank_entry', voucherId: l.id, number, narration: body.narration ?? (l.description || `Bank entry ${number}`),
        lines: [
          { accountId: l.account_id, amount: sign * amount },
          { accountId: contra.id, amount: -sign * amount, partyId: body.partyId ?? null },
        ],
      });
      const jl = await tx.selectFrom('journal_lines').select('id').where('entry_id', '=', entryId).where('account_id', '=', l.account_id).executeTakeFirstOrThrow();
      await tx.updateTable('bank_statement_lines').set({ status: 'matched', journal_line_id: jl.id, matched_by: ctx.userId, matched_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'bank_line', id, 'create_entry', null, { number, amount, account: contra.name });
      return (await lineJson(tx, ctx, [id]))[0]!;
    });
  });
}
