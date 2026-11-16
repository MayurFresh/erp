-- Helpdesk tickets with SLA, service contracts (AMC) with preventive visits, and timesheets.

create table hd_settings (
  company_id      uuid primary key references companies(id) on delete cascade,
  tenant_id       uuid not null references tenants(id) on delete cascade,
  hours_mode      text not null default 'business' check (hours_mode in ('24x7','business')),
  work_days       integer[] not null default '{1,2,3,4,5,6}',
  start_time      text not null default '09:00' check (start_time ~ '^[0-2][0-9]:[0-5][0-9]$'),
  end_time        text not null default '18:00' check (end_time ~ '^[0-2][0-9]:[0-5][0-9]$'),
  auto_close_days integer not null default 7 check (auto_close_days between 0 and 90),
  notify_customer boolean not null default true,
  renewal_days    integer not null default 30 check (renewal_days between 1 and 120),
  updated_at      timestamptz not null default now()
);

create table hd_sla (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references tenants(id) on delete cascade,
  company_id           uuid not null references companies(id) on delete cascade,
  priority             text not null check (priority in ('low','medium','high','urgent')),
  first_response_hours numeric(7,2) not null check (first_response_hours > 0 and first_response_hours <= 2000),
  resolution_hours     numeric(7,2) not null check (resolution_hours > 0 and resolution_hours <= 20000),
  unique (company_id, priority)
);

create table service_contracts (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  number          text not null,
  party_id        uuid not null references parties(id),
  title           text not null check (length(title) between 1 and 200),
  start_date      date not null,
  end_date        date not null,
  value           numeric(14,2) not null check (value >= 0),
  billing         text not null check (billing in ('upfront','periodic')),
  bill_frequency  text check (bill_frequency in ('monthly','quarterly','half_yearly','yearly')),
  visit_frequency text not null default 'none' check (visit_frequency in ('none','monthly','quarterly','half_yearly','yearly')),
  service_item_id uuid not null references items(id),
  location_id     uuid references locations(id),
  status          text not null default 'active' check (status in ('active','cancelled','renewed')),
  cancel_reason   text check (length(cancel_reason) <= 300),
  renewed_from_id uuid references service_contracts(id),
  renewed_to_id   uuid references service_contracts(id),
  notes           text check (length(notes) <= 2000),
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (end_date > start_date),
  check (billing = 'upfront' or bill_frequency is not null),
  unique (company_id, number)
);
create index on service_contracts (company_id, status, end_date);
create index on service_contracts (company_id, party_id);

create table service_contract_assets (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  contract_id uuid not null references service_contracts(id) on delete cascade,
  item_id     uuid references items(id),
  serial_no   text check (length(serial_no) <= 60),
  description text check (length(description) <= 300)
);
create index on service_contract_assets (contract_id);
create index on service_contract_assets (lower(serial_no));

create table service_contract_bills (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  contract_id uuid not null references service_contracts(id) on delete cascade,
  period      text not null,
  period_date date not null,
  amount      numeric(14,2) not null,
  invoice_id  uuid not null references invoices(id),
  created_at  timestamptz not null default now(),
  unique (contract_id, period)
);

create table service_visits (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  contract_id    uuid not null references service_contracts(id) on delete cascade,
  due_date       date not null,
  status         text not null default 'scheduled' check (status in ('scheduled','done','skipped')),
  technician_id  uuid references users(id),
  done_date      date,
  notes          text check (length(notes) <= 2000),
  parts_used     jsonb not null default '[]',
  signature_name text check (length(signature_name) <= 100),
  signature_file_id uuid references files(id) on delete set null,
  photo_file_ids uuid[] not null default '{}',
  skip_reason    text check (length(skip_reason) <= 300),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on service_visits (company_id, due_date);
create index on service_visits (contract_id, due_date);

create table service_contract_links (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  contract_id uuid not null references service_contracts(id) on delete cascade,
  ref_type    text not null check (ref_type in ('ticket','job_card')),
  ref_id      uuid not null,
  created_at  timestamptz not null default now(),
  unique (contract_id, ref_type, ref_id)
);

create table service_contract_reminders (
  contract_id uuid not null references service_contracts(id) on delete cascade,
  tenant_id   uuid not null references tenants(id) on delete cascade,
  sent_on     date not null default current_date,
  primary key (contract_id)
);

create table hd_tickets (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  number          text not null,
  party_id        uuid not null references parties(id),
  contact_name    text check (length(contact_name) <= 100),
  contact_phone   text check (length(contact_phone) <= 20),
  subject         text not null check (length(subject) between 1 and 200),
  description     text check (length(description) <= 5000),
  channel         text not null check (channel in ('phone','email','whatsapp','walk_in','portal')),
  category        text check (length(category) <= 60),
  priority        text not null default 'medium' check (priority in ('low','medium','high','urgent')),
  status          text not null default 'new' check (status in ('new','open','waiting','resolved','closed')),
  item_id         uuid references items(id),
  serial_no       text check (length(serial_no) <= 60),
  invoice_id      uuid references invoices(id),
  contract_id     uuid references service_contracts(id),
  assignee_id     uuid references users(id),
  first_response_due timestamptz not null,
  resolution_due  timestamptz not null,
  first_response_at timestamptz,
  resolved_at     timestamptz,
  closed_at       timestamptz,
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, number)
);
create index on hd_tickets (company_id, status, resolution_due);
create index on hd_tickets (company_id, assignee_id, status);
create index on hd_tickets (company_id, party_id);

create table hd_messages (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  ticket_id   uuid not null references hd_tickets(id) on delete cascade,
  kind        text not null check (kind in ('reply','note','customer','system')),
  body        text not null check (length(body) between 1 and 5000),
  author_id   uuid references users(id),
  file_ids    uuid[] not null default '{}',
  created_at  timestamptz not null default now()
);
create index on hd_messages (ticket_id, created_at);

create table ts_settings (
  company_id        uuid primary key references companies(id) on delete cascade,
  tenant_id         uuid not null references tenants(id) on delete cascade,
  service_item_id   uuid references items(id),
  approval_required boolean not null default true,
  daily_target_hours numeric(4,2) not null default 8 check (daily_target_hours > 0 and daily_target_hours <= 24),
  updated_at        timestamptz not null default now()
);

create table ts_rates (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  company_id uuid not null references companies(id) on delete cascade,
  user_id    uuid references users(id) on delete cascade,
  party_id   uuid references parties(id) on delete cascade,
  rate       numeric(12,2) not null check (rate >= 0),
  updated_at timestamptz not null default now(),
  check (user_id is not null or party_id is not null)
);
create unique index ts_rates_key on ts_rates (company_id, coalesce(user_id, '00000000-0000-0000-0000-000000000000'),
  coalesce(party_id, '00000000-0000-0000-0000-000000000000'));

create table ts_entries (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  user_id       uuid not null references users(id),
  work_date     date not null,
  party_id      uuid not null references parties(id),
  project_id    uuid references projects(id),
  matter_id     uuid references legal_matters(id),
  ticket_id     uuid references hd_tickets(id),
  task          text not null check (length(task) between 1 and 300),
  hours         numeric(5,2) not null check (hours > 0 and hours <= 24),
  billable      boolean not null default true,
  rate          numeric(12,2) not null default 0 check (rate >= 0),
  status        text not null default 'draft' check (status in ('draft','submitted','approved','rejected')),
  reject_reason text check (length(reject_reason) <= 300),
  submitted_at  timestamptz,
  approved_by   uuid references users(id),
  approved_at   timestamptz,
  invoice_id    uuid references invoices(id),
  billed_at     timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on ts_entries (company_id, user_id, work_date);
create index on ts_entries (company_id, party_id, status);

do $$
declare t text;
begin
  foreach t in array array['hd_settings','hd_sla','service_contracts','service_contract_assets','service_contract_bills','service_visits',
    'service_contract_links','service_contract_reminders','hd_tickets','hd_messages','ts_settings','ts_rates','ts_entries']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['hd_settings','service_contracts','service_visits','hd_tickets','ts_settings','ts_rates','ts_entries']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

update roles set permissions = array(select distinct unnest(permissions ||
  array['helpdesk.view','helpdesk.manage','helpdesk.settings','service_contracts.view','service_contracts.manage',
        'timesheets.log','timesheets.view','timesheets.approve','timesheets.bill']) order by 1)
  where is_system and name in ('Owner','Company Admin');

update companies set enabled_modules = array_append(enabled_modules, 'helpdesk')
  where business_type in ('it_services','consultant','electronics','garage','auto_parts','manufacturer','proprietorship','partnership',
    'llp','pvt_ltd','public_ltd','enterprise_group','general') and enabled_modules is not null and not ('helpdesk' = any(enabled_modules));
update companies set enabled_modules = array_append(enabled_modules, 'timesheets')
  where business_type in ('it_services','consultant','ca_firm','advocate','architect','freelancer','interior','contractor','proprietorship',
    'partnership','llp','pvt_ltd','public_ltd','enterprise_group','general') and enabled_modules is not null and not ('timesheets' = any(enabled_modules));
