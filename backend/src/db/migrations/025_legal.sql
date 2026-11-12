-- Wave 2: practice management for advocates and law firms. Matters, hearings, tasks, time and expenses, billing.

create table legal_matters (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  matter_no     text not null,
  title         text not null check (length(title) between 1 and 200),
  client_id     uuid not null references parties(id),
  opposing_party text check (length(opposing_party) <= 200),
  court         text check (length(court) <= 200),
  case_type     text check (length(case_type) <= 100),
  case_no       text check (length(case_no) <= 60),
  case_year     integer check (case_year between 1900 and 2100),
  filing_date   date,
  stage         text check (length(stage) <= 100),
  status        text not null default 'open' check (status in ('open','disposed','closed')),
  advocate_id   uuid not null references users(id),
  fee_type      text not null default 'hourly' check (fee_type in ('fixed_stage','per_hearing','hourly','retainer')),
  agreed_fee    numeric(14,2) not null default 0 check (agreed_fee >= 0),
  hourly_rate   numeric(12,2) check (hourly_rate >= 0),
  notes         text check (length(notes) <= 2000),
  closed_at     timestamptz,
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (company_id, matter_no)
);
create index on legal_matters (company_id, status);
create index on legal_matters (company_id, advocate_id);
create index on legal_matters (company_id, client_id);

create table legal_matter_team (
  tenant_id  uuid not null references tenants(id) on delete cascade,
  matter_id  uuid not null references legal_matters(id) on delete cascade,
  user_id    uuid not null references users(id),
  primary key (matter_id, user_id)
);
create index on legal_matter_team (user_id);

create table legal_hearings (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  matter_id       uuid not null references legal_matters(id) on delete cascade,
  hearing_date    date not null,
  court           text check (length(court) <= 200),
  purpose         text check (length(purpose) <= 300),
  status          text not null default 'scheduled' check (status in ('scheduled','held')),
  outcome         text check (length(outcome) <= 2000),
  next_hearing_id uuid references legal_hearings(id),
  recorded_by     uuid references users(id),
  recorded_at     timestamptz,
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index on legal_hearings (company_id, hearing_date) where status = 'scheduled';
create index on legal_hearings (matter_id, hearing_date);

create table legal_tasks (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  matter_id   uuid not null references legal_matters(id) on delete cascade,
  title       text not null check (length(title) between 1 and 200),
  kind        text not null default 'other' check (kind in ('limitation','filing','other')),
  due_date    date not null,
  assignee_id uuid references users(id),
  status      text not null default 'open' check (status in ('open','done')),
  done_at     timestamptz,
  notes       text check (length(notes) <= 1000),
  created_by  uuid not null references users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on legal_tasks (company_id, due_date) where status = 'open';
create index on legal_tasks (matter_id);

create table legal_rates (
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  user_id     uuid not null references users(id),
  hourly_rate numeric(12,2) not null check (hourly_rate >= 0),
  updated_at  timestamptz not null default now(),
  primary key (company_id, user_id)
);

create table legal_entries (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  matter_id     uuid not null references legal_matters(id) on delete cascade,
  kind          text not null check (kind in ('time','fee','disbursement')),
  disb_type     text check (disb_type in ('court_fee','stamp_duty','clerkage','other')),
  user_id       uuid not null references users(id),
  entry_date    date not null,
  minutes       integer check (minutes between 1 and 1440),
  rate          numeric(12,2) check (rate >= 0),
  amount        numeric(14,2) not null check (amount >= 0),
  billable      boolean not null default true,
  description   text not null check (length(description) between 1 and 300),
  hearing_id    uuid references legal_hearings(id),
  invoice_id    uuid references invoices(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check ((kind = 'time') = (minutes is not null)),
  check ((kind = 'disbursement') = (disb_type is not null))
);
create index on legal_entries (matter_id, entry_date);
create index on legal_entries (company_id) where invoice_id is null;

create table legal_bills (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  matter_id      uuid not null references legal_matters(id) on delete cascade,
  invoice_id     uuid not null references invoices(id),
  reverse_charge boolean not null default false,
  created_by     uuid not null references users(id),
  created_at     timestamptz not null default now(),
  unique (invoice_id)
);
create index on legal_bills (matter_id);

create table legal_receipts (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  matter_id   uuid not null references legal_matters(id) on delete cascade,
  payment_id  uuid not null references payments(id),
  invoice_id  uuid references invoices(id),
  kind        text not null check (kind in ('advance','fee')),
  created_by  uuid not null references users(id),
  created_at  timestamptz not null default now(),
  unique (payment_id)
);
create index on legal_receipts (matter_id);

create table legal_documents (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  matter_id   uuid not null references legal_matters(id) on delete cascade,
  file_id     uuid not null references files(id),
  label       text check (length(label) <= 200),
  created_by  uuid not null references users(id),
  created_at  timestamptz not null default now(),
  unique (matter_id, file_id)
);

do $$
declare t text;
begin
  foreach t in array array['legal_matters','legal_matter_team','legal_hearings','legal_tasks','legal_rates','legal_entries',
                           'legal_bills','legal_receipts','legal_documents']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['legal_matters','legal_hearings','legal_tasks','legal_entries']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

update roles set permissions = array(select distinct unnest(permissions || array['legal.view','legal.work','legal.manage']) order by 1)
  where is_system and name in ('Owner','Company Admin');

update companies set enabled_modules = array_append(enabled_modules, 'legal')
  where business_type = 'advocate' and enabled_modules is not null and not ('legal' = any(enabled_modules));
