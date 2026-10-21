-- Accounting (double entry), weighted-average stock valuation, purchases,
-- receipts/payments, credit notes, transfers and expenses.

-- Company profile used on printed invoices.
alter table companies
  add column phone text, add column email text, add column website text,
  add column bank_name text, add column bank_account_no text, add column bank_ifsc text,
  add column upi_id text, add column invoice_terms text, add column invoice_footer text;

alter table parties add column credit_days integer not null default 0 check (credit_days between 0 and 365);

alter table invoices
  add column due_date date,
  add column amount_paid numeric(14,2) not null default 0 check (amount_paid >= 0);
update invoices set due_date = invoice_date;
alter table invoices alter column due_date set not null;

alter table invoice_lines add column returned_qty numeric(14,3) not null default 0 check (returned_qty >= 0);

-- Every stock move carries its cost; stock value = sum(value).
alter table stock_moves
  add column cost_rate numeric(14,4),
  add column value numeric(14,2) not null default 0;
update stock_moves m set cost_rate = i.purchase_price, value = round(m.qty * i.purchase_price, 2)
  from items i where i.id = m.item_id;
alter table stock_moves drop constraint stock_moves_ref_type_check;
alter table stock_moves add constraint stock_moves_ref_type_check check (ref_type in (
  'opening','adjustment','invoice','invoice_cancel','purchase','purchase_cancel',
  'credit_note','credit_note_cancel','transfer_out','transfer_in','transfer_cancel'));
create index on stock_moves (company_id, item_id);

-- Gapless numbering for every other document type.
create table doc_series (
  tenant_id   uuid not null references tenants(id),
  company_id  uuid not null references companies(id),
  doc_type    text not null,
  fy          text not null,
  next_no     integer not null,
  primary key (company_id, doc_type, fy)
);

-- Chart of accounts -----------------------------------------------------------

create table accounts (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id),
  company_id  uuid not null references companies(id),
  code        text not null,
  name        text not null,
  type        text not null check (type in ('asset','liability','equity','income','expense')),
  subtype     text not null default 'other'
              check (subtype in ('cash','bank','receivables','payables','inventory','tax','other')),
  system_key  text,
  is_system   boolean not null default false,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (company_id, code)
);
create unique index accounts_system_key on accounts (company_id, system_key) where system_key is not null;

create table journal_entries (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id),
  company_id    uuid not null references companies(id),
  entry_date    date not null,
  voucher_type  text not null check (voucher_type in
                ('sales','purchase','receipt','payment','credit_note','expense','stock','transfer','journal')),
  voucher_id    uuid,
  number        text,
  narration     text,
  is_reversal   boolean not null default false,
  reverses_id   uuid references journal_entries(id),
  created_by    uuid references users(id),
  created_at    timestamptz not null default now()
);
create index on journal_entries (company_id, entry_date);
create index on journal_entries (voucher_id);
create unique index journal_reversed_once on journal_entries (reverses_id) where reverses_id is not null;

create table journal_lines (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id),
  entry_id     uuid not null references journal_entries(id),
  line_no      integer not null,
  account_id   uuid not null references accounts(id),
  party_id     uuid references parties(id),
  location_id  uuid references locations(id),
  debit        numeric(14,2) not null default 0,
  credit       numeric(14,2) not null default 0,
  check (debit >= 0 and credit >= 0 and (debit = 0 or credit = 0) and debit + credit > 0)
);
create index on journal_lines (entry_id);
create index on journal_lines (account_id);
create index on journal_lines (party_id) where party_id is not null;

-- Debits must equal credits for every entry, checked when the transaction commits.
create function check_journal_balanced() returns trigger language plpgsql as $$
declare
  eid uuid := coalesce(new.entry_id, old.entry_id);
  d numeric; c numeric;
begin
  select coalesce(sum(debit), 0), coalesce(sum(credit), 0) into d, c from journal_lines where entry_id = eid;
  if d <> c then
    raise exception 'Journal entry % is not balanced (debit %, credit %)', eid, d, c;
  end if;
  return null;
end $$;
create constraint trigger journal_balanced after insert or update or delete on journal_lines
  deferrable initially deferred for each row execute function check_journal_balanced();

create rule journal_lines_no_update as on update to journal_lines do instead nothing;
create rule journal_lines_no_delete as on delete to journal_lines do instead nothing;

-- Purchases ------------------------------------------------------------------

create table purchases (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references tenants(id),
  company_id             uuid not null references companies(id),
  location_id            uuid not null references locations(id),
  party_id               uuid not null references parties(id),
  number                 text not null,
  supplier_invoice_no    text,
  supplier_invoice_date  date,
  fy                     text not null,
  bill_date              date not null,
  due_date               date not null,
  place_of_supply        char(2) not null,
  supply_type            text not null check (supply_type in ('intra','inter')),
  status                 text not null default 'posted' check (status in ('posted','cancelled')),
  subtotal numeric(14,2) not null, cgst numeric(14,2) not null, sgst numeric(14,2) not null,
  igst numeric(14,2) not null, round_off numeric(14,2) not null, total numeric(14,2) not null,
  amount_paid            numeric(14,2) not null default 0 check (amount_paid >= 0),
  notes                  text,
  created_by             uuid not null references users(id),
  created_at             timestamptz not null default now(),
  cancelled_at           timestamptz,
  cancel_reason          text,
  unique (company_id, number)
);
create index on purchases (company_id, bill_date desc);

create table purchase_lines (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  purchase_id uuid not null references purchases(id),
  line_no integer not null,
  item_id uuid not null references items(id),
  description text not null, hsn_code text, qty numeric(14,3) not null, unit text not null,
  rate numeric(14,2) not null, discount_pct numeric(5,2) not null default 0,
  taxable_value numeric(14,2) not null, gst_rate numeric(5,2) not null,
  cgst numeric(14,2) not null, sgst numeric(14,2) not null, igst numeric(14,2) not null,
  line_total numeric(14,2) not null
);
create index on purchase_lines (purchase_id);

-- Receipts and payments --------------------------------------------------------

create table payments (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id),
  company_id    uuid not null references companies(id),
  kind          text not null check (kind in ('receipt','payment')),
  number        text not null,
  payment_date  date not null,
  party_id      uuid not null references parties(id),
  account_id    uuid not null references accounts(id),
  mode          text not null check (mode in ('cash','bank','upi','cheque','card')),
  reference     text,
  amount        numeric(14,2) not null check (amount > 0),
  notes         text,
  status        text not null default 'posted' check (status in ('posted','cancelled')),
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now(),
  cancelled_at  timestamptz,
  cancel_reason text,
  unique (company_id, number)
);
create index on payments (company_id, payment_date desc);

create table payment_allocations (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id),
  payment_id  uuid not null references payments(id),
  doc_type    text not null check (doc_type in ('invoice','purchase')),
  doc_id      uuid not null,
  amount      numeric(14,2) not null check (amount > 0)
);
create index on payment_allocations (payment_id);
create index on payment_allocations (doc_id);

-- Credit notes ---------------------------------------------------------------

create table credit_notes (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id),
  company_id       uuid not null references companies(id),
  invoice_id       uuid not null references invoices(id),
  location_id      uuid not null references locations(id),
  party_id         uuid not null references parties(id),
  number           text not null,
  fy               text not null,
  note_date        date not null,
  reason           text not null,
  restock          boolean not null,
  place_of_supply  char(2) not null,
  supply_type      text not null check (supply_type in ('intra','inter')),
  status           text not null default 'posted' check (status in ('posted','cancelled')),
  subtotal numeric(14,2) not null, cgst numeric(14,2) not null, sgst numeric(14,2) not null,
  igst numeric(14,2) not null, round_off numeric(14,2) not null, total numeric(14,2) not null,
  applied_amount   numeric(14,2) not null default 0,  -- part of the total set against the invoice
  created_by       uuid not null references users(id),
  created_at       timestamptz not null default now(),
  cancelled_at     timestamptz,
  cancel_reason    text,
  unique (company_id, number)
);
create index on credit_notes (invoice_id);

create table credit_note_lines (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  credit_note_id uuid not null references credit_notes(id),
  invoice_line_id uuid not null references invoice_lines(id),
  line_no integer not null,
  item_id uuid not null references items(id),
  description text not null, hsn_code text, qty numeric(14,3) not null, unit text not null,
  rate numeric(14,2) not null, discount_pct numeric(5,2) not null default 0,
  taxable_value numeric(14,2) not null, gst_rate numeric(5,2) not null,
  cgst numeric(14,2) not null, sgst numeric(14,2) not null, igst numeric(14,2) not null,
  line_total numeric(14,2) not null
);
create index on credit_note_lines (credit_note_id);

-- Stock transfers ------------------------------------------------------------

create table transfers (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id),
  company_id        uuid not null references companies(id),
  number            text not null,
  from_location_id  uuid not null references locations(id),
  to_location_id    uuid not null references locations(id),
  status            text not null default 'in_transit' check (status in ('in_transit','received','cancelled')),
  transfer_date     date not null,
  notes             text,
  created_by        uuid not null references users(id),
  created_at        timestamptz not null default now(),
  received_by       uuid references users(id),
  received_at       timestamptz,
  cancelled_at      timestamptz,
  cancel_reason     text,
  check (from_location_id <> to_location_id),
  unique (company_id, number)
);

create table transfer_lines (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  transfer_id uuid not null references transfers(id),
  line_no integer not null,
  item_id uuid not null references items(id),
  qty numeric(14,3) not null check (qty > 0),
  cost_rate numeric(14,4) not null,
  value numeric(14,2) not null
);
create index on transfer_lines (transfer_id);

-- Expenses -------------------------------------------------------------------

create table expenses (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references tenants(id),
  company_id            uuid not null references companies(id),
  number                text not null,
  expense_date          date not null,
  location_id           uuid not null references locations(id),
  account_id            uuid not null references accounts(id),
  party_id              uuid references parties(id),
  description           text not null,
  amount                numeric(14,2) not null check (amount > 0),
  gst_rate              numeric(5,2) not null default 0,
  cgst numeric(14,2) not null, sgst numeric(14,2) not null, igst numeric(14,2) not null,
  total                 numeric(14,2) not null,
  paid_from_account_id  uuid not null references accounts(id),
  status                text not null default 'posted' check (status in ('posted','cancelled')),
  created_by            uuid not null references users(id),
  created_at            timestamptz not null default now(),
  cancelled_at          timestamptz,
  cancel_reason         text,
  unique (company_id, number)
);
create index on expenses (company_id, expense_date desc);

-- Row-level security for the new tables ----------------------------------------

do $$
declare t text;
begin
  foreach t in array array['doc_series','accounts','journal_entries','journal_lines','purchases','purchase_lines',
                           'payments','payment_allocations','credit_notes','credit_note_lines','transfers',
                           'transfer_lines','expenses']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
end $$;

-- New permissions for the built-in roles of existing businesses ------------------

create function add_permissions(role_name text, extra text[]) returns void language sql as $$
  update roles set permissions = array(select distinct unnest(permissions || extra) order by 1)
  where is_system and name = role_name;
$$;

select add_permissions('Owner', array['company.manage','purchases.view','purchases.create','purchases.cancel',
  'payments.view','payments.create','payments.cancel','credit_notes.view','credit_notes.create','credit_notes.cancel',
  'transfers.view','transfers.create','transfers.receive','expenses.view','expenses.create','expenses.cancel',
  'accounts.view','accounts.manage','accounts.journal','reports.view']);
select add_permissions('Company Admin', array['company.manage','purchases.view','purchases.create','purchases.cancel',
  'payments.view','payments.create','payments.cancel','credit_notes.view','credit_notes.create','credit_notes.cancel',
  'transfers.view','transfers.create','transfers.receive','expenses.view','expenses.create','expenses.cancel',
  'accounts.view','accounts.manage','accounts.journal','reports.view']);
select add_permissions('Accountant', array['purchases.view','purchases.create','purchases.cancel',
  'payments.view','payments.create','payments.cancel','credit_notes.view','credit_notes.create','credit_notes.cancel',
  'transfers.view','expenses.view','expenses.create','expenses.cancel',
  'accounts.view','accounts.manage','accounts.journal','reports.view']);
select add_permissions('Sales Executive', array['payments.view','payments.create','credit_notes.view']);
select add_permissions('Store Keeper', array['purchases.view','transfers.view','transfers.create','transfers.receive']);
select add_permissions('Site Supervisor', array['transfers.view','transfers.create','transfers.receive']);
select add_permissions('Auditor', array['purchases.view','payments.view','credit_notes.view','transfers.view',
  'expenses.view','accounts.view','reports.view']);

drop function add_permissions(text, text[]);
