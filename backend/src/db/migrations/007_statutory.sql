-- v1.4: statutory core and quick wins. GST rate master (GST 2.0), TDS section master and deductions,
-- TDS challans, reverse charge, MSME fields, period lock, GSTR-2B reconciliation, bank reconciliation
-- and compliance documents. Research: docs/research/statutory-core.md and industry-verticals.md.

alter table journal_entries drop constraint journal_entries_voucher_type_check;
alter table journal_entries add constraint journal_entries_voucher_type_check check (voucher_type in
  ('sales','purchase','receipt','payment','credit_note','expense','stock','transfer','journal','issue','wages',
   'labour_advance','contractor_advance','ra_bill','retention_release','demand','possession',
   'tds_challan','bank_entry'));

-- Shared reference masters: system rows have tenant_id null; a business may add its own effective-dated rows.

create table gst_rates (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id),
  rate            numeric(5,2) not null check (rate >= 0 and rate <= 100),
  kind            text not null check (kind in ('any','goods','services')),
  label           text not null,
  effective_from  date not null,
  effective_to    date check (effective_to is null or effective_to >= effective_from),
  is_legacy       boolean not null default false,
  created_at      timestamptz not null default now()
);
create index on gst_rates (rate, effective_from);

insert into gst_rates (rate, kind, label, effective_from, effective_to, is_legacy) values
  (0,    'any',      'Nil / exempt',                                     '2017-07-01', null,         false),
  (5,    'any',      'GST 5%',                                           '2017-07-01', null,         false),
  (18,   'any',      'GST 18%',                                          '2017-07-01', null,         false),
  (40,   'any',      'GST 40% (sin and luxury goods)',                   '2025-09-22', null,         false),
  (0.25, 'goods',    'Rough diamonds and precious stones 0.25%',         '2017-07-01', null,         false),
  (3,    'goods',    'Gold, silver and jewellery 3%',                    '2017-07-01', null,         false),
  (1,    'services', 'Affordable housing 1% (no ITC)',                   '2019-04-01', null,         false),
  (12,   'services', 'Concessional services still at 12% (verify)',      '2025-09-22', null,         false),
  (12,   'any',      'GST 12% (before GST 2.0)',                         '2017-07-01', '2025-09-21', true),
  (28,   'any',      'GST 28% (before GST 2.0)',                         '2017-07-01', '2025-09-21', true);

create table tds_sections (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid references tenants(id),
  code                text not null,
  new_ref             text,
  name                text not null,
  rate_individual     numeric(6,3) not null check (rate_individual >= 0 and rate_individual <= 100),
  rate_other          numeric(6,3) not null check (rate_other >= 0 and rate_other <= 100),
  rate_no_pan         numeric(6,3) not null check (rate_no_pan >= 0 and rate_no_pan <= 100),
  threshold_single    numeric(14,2) check (threshold_single >= 0),
  threshold_aggregate numeric(14,2) check (threshold_aggregate >= 0),
  aggregate_mode      text not null default 'whole' check (aggregate_mode in ('whole','excess')),
  effective_from      date not null,
  effective_to        date check (effective_to is null or effective_to >= effective_from),
  verified            boolean not null default false,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now()
);

insert into tds_sections (code, new_ref, name, rate_individual, rate_other, rate_no_pan, threshold_single,
                          threshold_aggregate, aggregate_mode, effective_from, verified) values
  ('194C',    's.393(1) Sl. 6(i)',   'Payments to contractors',                    1,   2,   20, 30000,  100000,  'whole',  '2025-04-01', true),
  ('194J(a)', 's.393(1) Sl. 6(iii)', 'Professional fees',                          10,  10,  20, null,   50000,   'whole',  '2025-04-01', true),
  ('194J(b)', 's.393(1) Sl. 6(iii)', 'Fees for technical services',                2,   2,   20, null,   50000,   'whole',  '2025-04-01', true),
  ('194H',    's.393(1) Sl. 1(ii)',  'Commission or brokerage',                    2,   2,   20, null,   20000,   'whole',  '2025-04-01', true),
  ('194I(a)', 's.393(1) Sl. 2(ii)',  'Rent of plant, machinery or equipment',      2,   2,   20, 50000,  null,    'whole',  '2025-04-01', false),
  ('194I(b)', 's.393(1) Sl. 2(ii)',  'Rent of land, building or furniture',        10,  10,  20, 50000,  null,    'whole',  '2025-04-01', false),
  ('194Q',    's.393(1) Sl. 8(ii)',  'Purchase of goods (buyer turnover > ₹10 cr)', 0.1, 0.1, 5,  null,   5000000, 'excess', '2021-07-01', true),
  ('194A',    's.393(1) Sl. 5(ii)',  'Interest other than on securities',          10,  10,  20, null,   10000,   'whole',  '2025-04-01', false),
  ('194R',    's.393(1) Sl. 8(iv)',  'Business perquisites or benefits',           10,  10,  20, null,   20000,   'whole',  '2025-04-01', false),
  ('194T',    's.393(3) Sl. 7',      'Payments to partners',                       10,  10,  20, null,   20000,   'whole',  '2025-04-01', false);

do $$
declare t text;
begin
  foreach t in array array['gst_rates','tds_sections']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id is null or tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
end $$;

-- Master data ----------------------------------------------------------------------------------

alter table companies
  add column tan text check (tan ~ '^[A-Z]{4}[0-9]{5}[A-Z]$'),
  add column books_locked_until date,
  add column msme_bank_rate numeric(5,2) check (msme_bank_rate > 0 and msme_bank_rate < 50),
  add column gst_filing text not null default 'monthly' check (gst_filing in ('monthly','quarterly'));

alter table parties
  add column udyam_no text check (udyam_no ~ '^UDYAM-[A-Z]{2}-[0-9]{2}-[0-9]{7}$'),
  add column msme_category text check (msme_category in ('micro','small','medium')),
  add column tds_section_id uuid references tds_sections(id);

-- Documents: TDS, reverse charge and MSME due date --------------------------------------------

alter table purchases
  add column tds_section_id uuid references tds_sections(id),
  add column tds_base numeric(14,2) not null default 0 check (tds_base >= 0),
  add column tds_rate numeric(6,3) not null default 0 check (tds_rate >= 0),
  add column tds_amount numeric(14,2) not null default 0 check (tds_amount >= 0),
  add column net_payable numeric(14,2) generated always as (total - tds_amount) stored,
  add column reverse_charge boolean not null default false,
  add column rcm_self_invoice_no text,
  add column msme_due_date date;

alter table expenses
  add column tds_section_id uuid references tds_sections(id),
  add column tds_base numeric(14,2) not null default 0 check (tds_base >= 0),
  add column tds_rate numeric(6,3) not null default 0 check (tds_rate >= 0),
  add column tds_amount numeric(14,2) not null default 0 check (tds_amount >= 0),
  add column reverse_charge boolean not null default false,
  add column rcm_self_invoice_no text;

alter table payments
  add column tds_amount numeric(14,2) not null default 0 check (tds_amount >= 0);

create table tds_challans (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references tenants(id),
  company_id            uuid not null references companies(id),
  number                text not null,
  deposit_date          date not null,
  bsr_code              text not null check (bsr_code ~ '^[0-9]{7}$'),
  challan_serial        text not null check (challan_serial ~ '^[0-9]{5}$'),
  tax_amount            numeric(14,2) not null check (tax_amount > 0),
  interest              numeric(14,2) not null default 0 check (interest >= 0),
  late_fee              numeric(14,2) not null default 0 check (late_fee >= 0),
  total                 numeric(14,2) not null,
  paid_from_account_id  uuid not null references accounts(id),
  status                text not null default 'posted' check (status in ('posted','cancelled')),
  created_by            uuid not null references users(id),
  created_at            timestamptz not null default now(),
  cancelled_at          timestamptz,
  cancel_reason         text,
  unique (company_id, number)
);

-- One row per document that carries a TDS section, even below the threshold (amount 0), so the FY
-- aggregate per party and section is the sum of `gross`; `base` is what TDS was charged on this time.
create table tds_deductions (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id),
  company_id      uuid not null references companies(id),
  source_type     text not null check (source_type in ('purchase','expense','ra_bill')),
  source_id       uuid not null,
  number          text not null,
  party_id        uuid not null references parties(id),
  pan             text,
  section_id      uuid references tds_sections(id),
  section_code    text not null,
  fy              text not null,
  deduction_date  date not null,
  gross           numeric(14,2) not null check (gross >= 0),
  base            numeric(14,2) not null check (base >= 0),
  rate            numeric(6,3) not null check (rate >= 0),
  amount          numeric(14,2) not null check (amount >= 0),
  status          text not null default 'active' check (status in ('active','cancelled')),
  challan_id      uuid references tds_challans(id),
  created_at      timestamptz not null default now()
);
create index on tds_deductions (company_id, party_id, section_code, fy);
create index on tds_deductions (company_id, deduction_date);
create unique index on tds_deductions (source_type, source_id) where status = 'active';

-- GSTR-2B import and reconciliation -------------------------------------------------------------

create table gst_2b_imports (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id),
  company_id  uuid not null references companies(id),
  period      text not null check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  file_name   text,
  line_count  integer not null default 0,
  created_by  uuid not null references users(id),
  created_at  timestamptz not null default now(),
  unique (company_id, period)
);

create table gst_2b_lines (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id),
  company_id      uuid not null references companies(id),
  import_id       uuid not null references gst_2b_imports(id) on delete cascade,
  supplier_gstin  text not null,
  supplier_name   text,
  doc_type        text not null default 'invoice' check (doc_type in ('invoice','credit_note','debit_note')),
  doc_no          text not null,
  doc_date        date not null,
  taxable         numeric(14,2) not null default 0,
  igst            numeric(14,2) not null default 0,
  cgst            numeric(14,2) not null default 0,
  sgst            numeric(14,2) not null default 0,
  cess            numeric(14,2) not null default 0,
  itc_available   boolean not null default true,
  purchase_id     uuid references purchases(id),
  match_status    text not null check (match_status in ('matched','mismatch','missing_in_books')),
  ims_action      text not null default 'none' check (ims_action in ('none','accept','reject','pending')),
  note            text
);
create index on gst_2b_lines (import_id);

-- Bank reconciliation --------------------------------------------------------------------------

create table bank_statements (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id),
  company_id       uuid not null references companies(id),
  account_id       uuid not null references accounts(id),
  file_name        text,
  from_date        date,
  to_date          date,
  closing_balance  numeric(14,2),
  created_by       uuid not null references users(id),
  created_at       timestamptz not null default now()
);

create table bank_statement_lines (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id),
  company_id       uuid not null references companies(id),
  statement_id     uuid not null references bank_statements(id) on delete cascade,
  line_no          integer not null,
  txn_date         date not null,
  description      text not null default '',
  reference        text,
  withdrawal       numeric(14,2) not null default 0 check (withdrawal >= 0),
  deposit          numeric(14,2) not null default 0 check (deposit >= 0),
  balance          numeric(14,2),
  status           text not null default 'unmatched' check (status in ('unmatched','matched','ignored')),
  journal_line_id  uuid references journal_lines(id),
  matched_by       uuid references users(id),
  matched_at       timestamptz,
  check (withdrawal = 0 or deposit = 0)
);
create index on bank_statement_lines (statement_id, line_no);
create unique index on bank_statement_lines (journal_line_id) where journal_line_id is not null;

-- Compliance documents (licences, registrations, insurance) ------------------------------------

create table compliance_docs (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id),
  company_id   uuid not null references companies(id),
  name         text not null,
  category     text not null check (category in ('licence','registration','insurance','certificate','agreement','other')),
  doc_no       text,
  issued_by    text,
  issue_date   date,
  expiry_date  date,
  remind_days  integer not null default 30 check (remind_days between 0 and 365),
  location_id  uuid references locations(id),
  file_id      uuid references files(id),
  notes        text,
  is_active    boolean not null default true,
  created_by   uuid not null references users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index on compliance_docs (company_id, expiry_date);

do $$
declare t text;
begin
  foreach t in array array['tds_challans','tds_deductions','gst_2b_imports','gst_2b_lines',
                           'bank_statements','bank_statement_lines','compliance_docs']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
end $$;

-- New permissions for the built-in roles of existing businesses ----------------------------

create function add_permissions(role_name text, extra text[]) returns void language sql as $$
  update roles set permissions = array(select distinct unnest(permissions || extra) order by 1)
  where is_system and name = role_name;
$$;

select add_permissions('Owner', array['gst.view','gst.manage','tds.view','tds.manage','bank.reconcile',
  'compliance.view','compliance.manage','books.lock','data.export']);
select add_permissions('Company Admin', array['gst.view','gst.manage','tds.view','tds.manage','bank.reconcile',
  'compliance.view','compliance.manage','books.lock','data.export']);
select add_permissions('Accountant', array['gst.view','gst.manage','tds.view','tds.manage','bank.reconcile',
  'compliance.view','compliance.manage','data.export']);
select add_permissions('Site Supervisor', array['compliance.view']);
select add_permissions('Project Manager', array['compliance.view']);
select add_permissions('Auditor', array['gst.view','tds.view','compliance.view']);

drop function add_permissions(text, text[]);
