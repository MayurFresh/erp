import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { isValidDate } from '../lib/dates.ts';
import { badRequest } from '../lib/errors.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

const query = z.object({
  from: z.string().refine(isValidDate, 'Use YYYY-MM-DD'),
  to: z.string().refine(isValidDate, 'Use YYYY-MM-DD'),
});

const GROUP: Record<string, string> = {
  asset: 'Current Assets', liability: 'Current Liabilities', equity: 'Capital Account', income: 'Indirect Incomes', expense: 'Indirect Expenses',
};
const SUBTYPE_GROUP: Record<string, string> = {
  cash: 'Cash-in-Hand', bank: 'Bank Accounts', receivables: 'Sundry Debtors', payables: 'Sundry Creditors', tax: 'Duties & Taxes', inventory: 'Stock-in-Hand',
};

/** Escapes text for XML and drops characters XML 1.0 cannot hold. */
const esc = (s: string) => s.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '')
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
/** Tally voucher type for a ledger voucher type. Documents keep their own type; everything else posts as Journal. */
const TALLY_TYPE: Record<string, string> = {
  sales: 'Sales', purchase: 'Purchase', receipt: 'Receipt', payment: 'Payment', credit_note: 'Credit Note', debit_note: 'Debit Note',
};
const day = (d: string | Date) => (typeof d === 'string' ? d : d.toISOString().slice(0, 10)).replaceAll('-', '');

/** Tally Prime XML export (v1.9): documents as Sales, Purchase, Receipt, Payment, Credit Note and Debit Note vouchers; the rest as Journal. */
export async function tallyRoutes(app: FastifyInstance) {
  app.get('/export/tally', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('data.export');
    const q = parse(query, req.query);
    if (q.to < q.from) throw badRequest('The end date is before the start date.', { to: 'Before start' });
    if ((Date.parse(q.to) - Date.parse(q.from)) / 86_400_000 > 366) throw badRequest('Export at most 366 days at a time.', { to: 'Range too long' });
    const xml = await ctx.tx(async (tx) => {
      const company = await tx.selectFrom('companies').select('name').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const entries = await tx.selectFrom('journal_entries').select(['id', 'entry_date', 'voucher_type', 'number', 'narration'])
        .where('company_id', '=', ctx.companyId).where('entry_date', '>=', q.from).where('entry_date', '<=', q.to)
        .orderBy('entry_date').orderBy('created_at').orderBy('id').limit(50_000).execute();
      const lines = entries.length
        ? await tx.selectFrom('journal_lines as l').innerJoin('accounts as a', 'a.id', 'l.account_id')
          .select(['l.entry_id', 'l.line_no', 'l.debit', 'l.credit', 'a.id as account_id', 'a.name', 'a.type', 'a.subtype'])
          .where('l.entry_id', 'in', entries.map((e) => e.id)).orderBy('l.line_no').execute()
        : [];
      const ledgers = new Map<string, { name: string; group: string }>();
      for (const l of lines) ledgers.set(l.account_id, { name: l.name, group: SUBTYPE_GROUP[l.subtype] ?? GROUP[l.type] ?? 'Suspense A/c' });
      const out: string[] = [];
      out.push('<?xml version="1.0" encoding="UTF-8"?>', '<ENVELOPE><HEADER><TALLYREQUEST>Import Data</TALLYREQUEST></HEADER><BODY><IMPORTDATA>',
        `<REQUESTDESC><REPORTNAME>All Masters</REPORTNAME><STATICVARIABLES><SVCURRENTCOMPANY>${esc(company.name)}</SVCURRENTCOMPANY></STATICVARIABLES></REQUESTDESC><REQUESTDATA>`);
      const seen = new Set<string>();
      for (const { name, group } of ledgers.values()) {
        if (seen.has(name)) continue;
        seen.add(name);
        out.push(`<TALLYMESSAGE xmlns:UDF="TallyUDF"><LEDGER NAME="${esc(name)}" ACTION="Create"><NAME>${esc(name)}</NAME><PARENT>${esc(group)}</PARENT></LEDGER></TALLYMESSAGE>`);
      }
      for (const e of entries) {
        const rows = lines.filter((l) => l.entry_id === e.id);
        const vt = TALLY_TYPE[e.voucher_type] ?? 'Journal';
        const narration = [vt === 'Journal' ? e.voucher_type : null, e.narration].filter(Boolean).join(': ');
        out.push(`<TALLYMESSAGE xmlns:UDF="TallyUDF"><VOUCHER REMOTEID="${e.id}" VCHTYPE="${vt}" ACTION="Create">`,
          `<DATE>${day(e.entry_date)}</DATE><VOUCHERTYPENAME>${vt}</VOUCHERTYPENAME>${e.number ? `<VOUCHERNUMBER>${esc(e.number)}</VOUCHERNUMBER>` : ''}`,
          `<NARRATION>${esc(narration)}</NARRATION>`);
        for (const l of rows) {
          const debit = Number(l.debit) > 0;
          const amt = (debit ? -Number(l.debit) : Number(l.credit)).toFixed(2);
          out.push(`<ALLLEDGERENTRIES.LIST><LEDGERNAME>${esc(l.name)}</LEDGERNAME><ISDEEMEDPOSITIVE>${debit ? 'Yes' : 'No'}</ISDEEMEDPOSITIVE><AMOUNT>${amt}</AMOUNT></ALLLEDGERENTRIES.LIST>`);
        }
        out.push('</VOUCHER></TALLYMESSAGE>');
      }
      out.push('</REQUESTDATA></IMPORTDATA></BODY></ENVELOPE>');
      await writeAudit(tx, auditOf(ctx), 'export', ctx.companyId, 'tally', null, { from: q.from, to: q.to, vouchers: entries.length });
      return out.join('\n');
    });
    return reply.header('content-disposition', `attachment; filename="tally-${q.from}-${q.to}.xml"`).type('application/xml; charset=utf-8').send(xml);
  });
}
