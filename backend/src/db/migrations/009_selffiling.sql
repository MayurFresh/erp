-- v1.6 self-filing kit: filing register, GST ledgers and payments, income-tax payments, fixed assets.

alter table journal_entries drop constraint journal_entries_voucher_type_check;
alter table journal_entries add constraint journal_entries_voucher_type_check check (voucher_type in
  ('sales','purchase','receipt','payment','credit_note','expense','stock','transfer','journal','issue','wages',
   'labour_advance','contractor_advance','ra_bill','retention_release','demand','possession',
   'tds_challan','bank_entry',
   'gst_payment','gst_setoff','tax_payment','asset_capitalise','depreciation','asset_disposal'));

alter table accounts drop constraint accounts_subtype_check;
alter table accounts add constraint accounts_subtype_check
  check (subtype in ('cash','bank','receivables','payables','inventory','tax','fixed_asset','other'));

alter table companies
  add column constitution text check (constitution in
    ('proprietorship','partnership','llp','private_company','public_company','huf','trust','other')),
  add column responsible_person jsonb,
  add column itr_form text check (itr_form in ('itr3','itr4','itr5','itr6'));

-- Filing register -------------------------------------------------------------------------------

create table statutory_filings (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references tenants(id) on delete cascade,
  company_id            uuid not null references companies(id) on delete cascade,
  return_type           text not null check (return_type in ('gstr1','iff','gstr3b','pmt06','gstr9','gstr9c','tds_140','itr')),
  period                text not null check (period ~ '^([0-9]{4}-(0[1-9]|1[0-2])|[0-9]{4}-[0-9]{2}(-Q[1-4])?)$'),
  status                text not null default 'filed' check (status in ('filed','cancelled')),
  filed_on              date not null,
  arn                   text check (length(arn) <= 100),
  amount_paid           numeric(14,2) check (amount_paid >= 0),
  notes                 text check (length(notes) <= 2000),
  export_sha256         text check (export_sha256 ~ '^[0-9a-f]{64}$'),
  acknowledged_failures jsonb not null default '[]',
  setoff_entry_id       uuid references journal_entries(id),
  created_by            uuid not null references users(id),
  created_at            timestamptz not null default now(),
  cancelled_at          timestamptz,
  cancel_reason         text
);
create unique index statutory_filings_one_filed on statutory_filings (company_id, return_type, period) where status = 'filed';

-- GST: portal ledger snapshots and PMT-06 payments -------------------------------------------

create table gst_ledger_balances (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  ledger      text not null check (ledger in ('credit','cash')),
  as_of       date not null,
  igst        numeric(14,2) not null default 0 check (igst >= 0),
  cgst        numeric(14,2) not null default 0 check (cgst >= 0),
  sgst        numeric(14,2) not null default 0 check (sgst >= 0),
  cess        numeric(14,2) not null default 0 check (cess >= 0),
  note        text check (length(note) <= 2000),
  created_by  uuid not null references users(id),
  created_at  timestamptz not null default now()
);
create index on gst_ledger_balances (company_id, ledger, as_of desc);

create table gst_payments (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references tenants(id) on delete cascade,
  company_id           uuid not null references companies(id) on delete cascade,
  number               text not null,
  payment_date         date not null,
  period               text check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  cpin                 text check (cpin ~ '^[0-9]{14}$'),
  cin                  text check (length(cin) <= 30),
  paid_from_account_id uuid not null references accounts(id),
  igst                 numeric(14,2) not null default 0 check (igst >= 0),
  cgst                 numeric(14,2) not null default 0 check (cgst >= 0),
  sgst                 numeric(14,2) not null default 0 check (sgst >= 0),
  cess                 numeric(14,2) not null default 0 check (cess >= 0),
  interest             numeric(14,2) not null default 0 check (interest >= 0),
  late_fee             numeric(14,2) not null default 0 check (late_fee >= 0),
  total                numeric(14,2) not null check (total > 0),
  status               text not null default 'posted' check (status in ('posted','cancelled')),
  created_by           uuid not null references users(id),
  created_at           timestamptz not null default now(),
  cancelled_at         timestamptz,
  cancel_reason        text,
  unique (company_id, number)
);

-- Income tax payments (advance and self-assessment tax) --------------------------------------

create table tax_payments (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references tenants(id) on delete cascade,
  company_id           uuid not null references companies(id) on delete cascade,
  number               text not null,
  kind                 text not null check (kind in ('advance_tax','self_assessment','other')),
  tax_year             text not null check (tax_year ~ '^[0-9]{4}-[0-9]{2}$'),
  payment_date         date not null,
  amount               numeric(14,2) not null check (amount > 0),
  bsr_code             text not null check (bsr_code ~ '^[0-9]{7}$'),
  challan_serial       text not null check (challan_serial ~ '^[0-9]{5}$'),
  paid_from_account_id uuid not null references accounts(id),
  status               text not null default 'posted' check (status in ('posted','cancelled')),
  created_by           uuid not null references users(id),
  created_at           timestamptz not null default now(),
  cancelled_at         timestamptz,
  cancel_reason        text,
  unique (company_id, number)
);

-- Fixed assets --------------------------------------------------------------------------------

-- Income-tax depreciation blocks: a global reference table (no tenant), effective-dated.
create table it_depreciation_blocks (
  id              uuid primary key default gen_random_uuid(),
  code            text not null,
  name            text not null,
  rate            numeric(5,2) not null check (rate >= 0 and rate <= 100),
  effective_from  date not null,
  effective_to    date check (effective_to is null or effective_to >= effective_from),
  verified        boolean not null default false,
  unique (code, effective_from)
);

insert into it_depreciation_blocks (code, name, rate, effective_from) values
  ('land',           'Land (not depreciable)',                           0,  '2026-04-01'),
  ('building_res',   'Residential building',                             5,  '2026-04-01'),
  ('building',       'Other buildings',                                  10, '2026-04-01'),
  ('temp_structure', 'Temporary structures',                             40, '2026-04-01'),
  ('furniture',      'Furniture and fittings',                           10, '2026-04-01'),
  ('plant',          'Plant and machinery',                              15, '2026-04-01'),
  ('vehicle',        'Motor cars (not for hire)',                        15, '2026-04-01'),
  ('computer',       'Computers and software',                           40, '2026-04-01'),
  ('intangible',     'Intangibles (patents, licences, know-how)',        25, '2026-04-01'),
  ('energy',         'Energy-saving and pollution-control equipment',    40, '2026-04-01');

create table fixed_assets (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references tenants(id) on delete cascade,
  company_id         uuid not null references companies(id) on delete cascade,
  number             text not null,
  name               text not null check (length(name) between 1 and 200),
  block_code         text not null,
  book_method        text not null check (book_method in ('slm','wdv')),
  useful_life_years  numeric(5,2) not null check (useful_life_years > 0 and useful_life_years <= 100),
  residual_pct       numeric(5,2) not null default 5 check (residual_pct >= 0 and residual_pct < 100),
  cost               numeric(14,2) not null check (cost > 0),
  gst_itc            numeric(14,2) not null default 0 check (gst_itc >= 0),
  purchase_date      date not null,
  put_to_use_date    date not null check (put_to_use_date >= purchase_date),
  location_id        uuid references locations(id),
  supplier_name      text check (length(supplier_name) <= 200),
  bill_no            text check (length(bill_no) <= 50),
  serial_no          text check (length(serial_no) <= 100),
  tag_no             text check (length(tag_no) <= 100),
  custodian          text check (length(custodian) <= 200),
  notes              text check (length(notes) <= 2000),
  opening_acc_dep    numeric(14,2) not null default 0 check (opening_acc_dep >= 0),
  accumulated_dep    numeric(14,2) not null default 0 check (accumulated_dep >= 0),
  depreciated_until  date,
  status             text not null default 'active' check (status in ('active','disposed')),
  disposal_date      date,
  sale_value         numeric(14,2) check (sale_value >= 0),
  gain_loss          numeric(14,2),
  capitalise_entry_id uuid references journal_entries(id),
  disposal_entry_id  uuid references journal_entries(id),
  created_by         uuid not null references users(id),
  created_at         timestamptz not null default now(),
  unique (company_id, number),
  check (opening_acc_dep + accumulated_dep <= cost)
);
create index on fixed_assets (company_id, status);

create table depreciation_runs (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id) on delete cascade,
  number        text not null,
  to_date       date not null,
  total         numeric(14,2) not null check (total >= 0),
  entry_id      uuid references journal_entries(id),
  status        text not null default 'posted' check (status in ('posted','cancelled')),
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now(),
  cancelled_at  timestamptz,
  cancel_reason text,
  unique (company_id, number)
);

create table depreciation_run_lines (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  run_id      uuid not null references depreciation_runs(id) on delete cascade,
  asset_id    uuid not null references fixed_assets(id),
  from_date   date not null,
  to_date     date not null check (to_date >= from_date),
  days        integer not null check (days > 0),
  amount      numeric(14,2) not null check (amount >= 0),
  prev_depreciated_until date
);
create index on depreciation_run_lines (asset_id);

create table it_block_openings (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id) on delete cascade,
  fy            text not null check (fy ~ '^[0-9]{4}-[0-9]{2}$'),
  block_code    text not null,
  opening_wdv   numeric(14,2) not null check (opening_wdv >= 0),
  updated_at    timestamptz not null default now(),
  unique (company_id, fy, block_code)
);

do $$
declare t text;
begin
  foreach t in array array['statutory_filings','gst_ledger_balances','gst_payments','tax_payments',
                           'fixed_assets','depreciation_runs','depreciation_run_lines','it_block_openings']
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

select add_permissions('Owner', array['tax.view','tax.manage','assets.view','assets.manage']);
select add_permissions('Company Admin', array['tax.view','tax.manage','assets.view','assets.manage']);
select add_permissions('Accountant', array['tax.view','tax.manage','assets.view','assets.manage']);
select add_permissions('Auditor', array['tax.view','assets.view']);

drop function add_permissions(text, text[]);
