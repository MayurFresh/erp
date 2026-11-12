-- Wave 2: fund and budget control (government, local bodies, NGOs, societies) and donations.
-- Spending is linked to heads and funds through fund_links; purchase bills, expenses and payments post as before.

create table funds_settings (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  overspend_mode  text not null default 'warn' check (overspend_mode in ('block','warn')),
  reg_80g_no      text check (length(reg_80g_no) <= 60),
  reg_80g_from    date,
  reg_80g_to      date,
  trust_pan       text check (length(trust_pan) <= 10),
  receipt_footer  text check (length(receipt_footer) <= 300),
  updated_at      timestamptz not null default now(),
  unique (company_id)
);

create table funds (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  company_id        uuid not null references companies(id),
  name              text not null check (length(name) between 1 and 150),
  kind              text not null default 'grant' check (kind in ('grant','csr','own','donation','other')),
  sponsor           text check (length(sponsor) <= 200),
  sanction_no       text check (length(sanction_no) <= 60),
  sanction_date     date,
  total_amount      numeric(14,2) not null default 0 check (total_amount >= 0),
  period_from       date,
  period_to         date,
  return_unspent    boolean not null default false,
  status            text not null default 'active' check (status in ('active','closed')),
  income_account_id uuid references accounts(id),
  notes             text check (length(notes) <= 1000),
  created_by        uuid not null references users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (company_id, name),
  check (period_from is null or period_to is null or period_from <= period_to)
);

create table budget_heads (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  company_id       uuid not null references companies(id),
  fy               text not null check (fy ~ '^[0-9]{4}-[0-9]{2}$'),
  parent_id        uuid references budget_heads(id),
  level            text not null check (level in ('major','minor','object')),
  code             text not null check (length(code) between 1 and 30),
  name             text not null check (length(name) between 1 and 150),
  account_id       uuid references accounts(id),
  budget_estimate  numeric(14,2) not null default 0 check (budget_estimate >= 0),
  revised_estimate numeric(14,2) check (revised_estimate >= 0),
  is_active        boolean not null default true,
  created_by       uuid not null references users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (company_id, fy, code)
);
create index on budget_heads (company_id, fy);
create index on budget_heads (parent_id);

create table budget_reappropriations (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  fy            text not null,
  from_head_id  uuid not null references budget_heads(id),
  to_head_id    uuid not null references budget_heads(id),
  amount        numeric(14,2) not null check (amount > 0),
  order_no      text not null check (length(order_no) between 1 and 60),
  order_date    date not null,
  reason        text not null check (length(reason) between 1 and 500),
  status        text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_by    uuid not null references users(id),
  decided_by    uuid references users(id),
  decided_at    timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (from_head_id <> to_head_id)
);
create index on budget_reappropriations (company_id, fy);

create table fund_sanctions (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references tenants(id) on delete cascade,
  company_id           uuid not null references companies(id),
  number               text not null,
  head_id              uuid not null references budget_heads(id),
  fund_id              uuid not null references funds(id),
  purpose              text not null check (length(purpose) between 1 and 500),
  amount               numeric(14,2) not null check (amount > 0),
  status               text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  admin_order_no       text check (length(admin_order_no) <= 60),
  admin_order_date     date,
  financial_order_no   text check (length(financial_order_no) <= 60),
  financial_order_date date,
  decision_note        text check (length(decision_note) <= 300),
  created_by           uuid not null references users(id),
  decided_by           uuid references users(id),
  decided_at           timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (company_id, number)
);
create index on fund_sanctions (company_id, status);
create index on fund_sanctions (head_id);
create index on fund_sanctions (fund_id);

create table fund_links (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  source_type    text not null check (source_type in ('purchase','expense','payment')),
  source_id      uuid not null,
  head_id        uuid not null references budget_heads(id),
  fund_id        uuid not null references funds(id),
  sanction_id    uuid references fund_sanctions(id),
  amount         numeric(14,2) not null check (amount > 0),
  note           text check (length(note) <= 300),
  created_by     uuid not null references users(id),
  created_at     timestamptz not null default now(),
  unique (source_type, source_id, head_id, fund_id)
);
create index on fund_links (company_id, head_id);
create index on fund_links (company_id, fund_id);
create index on fund_links (source_type, source_id);

create table fund_receipts (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  number        text not null,
  fund_id       uuid not null references funds(id),
  receipt_date  date not null,
  amount        numeric(14,2) not null check (amount > 0),
  account_id    uuid not null references accounts(id),
  reference     text check (length(reference) <= 100),
  narration     text check (length(narration) <= 300),
  status        text not null default 'posted' check (status in ('posted','cancelled')),
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now(),
  unique (company_id, number)
);
create index on fund_receipts (company_id, fund_id, receipt_date);

create table donors (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  party_id    uuid not null references parties(id),
  name        text not null check (length(name) between 1 and 200),
  phone       text check (length(phone) <= 20),
  email       text check (length(email) <= 200),
  pan         text check (pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  aadhaar     text check (aadhaar ~ '^[0-9]{12}$'),
  address     text check (length(address) <= 500),
  is_active   boolean not null default true,
  created_by  uuid not null references users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, party_id)
);
create index on donors (company_id, lower(name));
create index on donors (company_id, phone);
create unique index donors_pan_uq on donors (company_id, pan) where pan is not null;

create table donations (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references tenants(id) on delete cascade,
  company_id         uuid not null references companies(id),
  receipt_no         text not null,
  donor_id           uuid not null references donors(id),
  donation_date      date not null,
  amount             numeric(14,2) not null check (amount > 0),
  mode               text not null check (mode in ('cash','upi','cheque','bank')),
  reference          text check (length(reference) <= 100),
  fund_id            uuid references funds(id),
  purpose            text check (length(purpose) <= 200),
  is_corpus          boolean not null default false,
  tax_80g            boolean not null default false,
  deduction_eligible boolean not null default false,
  warning            text check (length(warning) <= 300),
  account_id         uuid not null references accounts(id),
  fy                 text not null,
  status             text not null default 'posted' check (status in ('posted','cancelled')),
  cancel_reason      text check (length(cancel_reason) <= 300),
  created_by         uuid not null references users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (company_id, receipt_no)
);
create index on donations (company_id, donation_date desc);
create index on donations (company_id, donor_id, fy);
create index on donations (company_id, fund_id);

do $$
declare t text;
begin
  foreach t in array array['funds_settings','funds','budget_heads','budget_reappropriations','fund_sanctions','fund_links',
                           'fund_receipts','donors','donations']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['funds_settings','funds','budget_heads','budget_reappropriations','fund_sanctions','donors','donations']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

update roles set permissions = array(select distinct unnest(permissions ||
  array['funds.view','funds.entry','funds.manage','donations.view','donations.create','donations.manage']) order by 1)
  where is_system and name in ('Owner','Company Admin');

update companies set enabled_modules = array_append(enabled_modules, 'funds')
  where business_type in ('government','psu','local_body','ngo','religious','housing_society') and enabled_modules is not null
    and not ('funds' = any(enabled_modules));
update companies set enabled_modules = array_append(enabled_modules, 'donations')
  where business_type in ('ngo','religious') and enabled_modules is not null
    and not ('donations' = any(enabled_modules));
