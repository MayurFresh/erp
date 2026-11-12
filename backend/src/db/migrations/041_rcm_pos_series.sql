-- Reverse charge on sales invoices, a separate POS number series, and exact fixed-discount credit notes.
alter table invoices add column if not exists reverse_charge boolean not null default false;
-- Tax the recipient pays under reverse charge; the invoice total excludes it.
alter table invoices add column if not exists rcm_tax numeric(14,2) not null default 0;
alter table invoice_lines add column if not exists discount_amount numeric(14,2);
alter table credit_note_lines add column if not exists discount_amount numeric(14,2);
alter table companies add column if not exists pos_invoice_prefix text not null default 'POS';
