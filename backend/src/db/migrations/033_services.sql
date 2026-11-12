-- Wave 2: service businesses. Memberships with recurring bills, and repair job cards.

create table mem_plans (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  item_id         uuid not null references items(id),
  name            text not null check (length(name) between 1 and 120),
  billing         text not null default 'upfront' check (billing in ('upfront','monthly')),
  rate_basis      text not null default 'fixed' check (rate_basis in ('fixed','per_sqft')),
  duration_unit   text not null default 'months' check (duration_unit in ('months','days')),
  duration_count  integer not null default 1 check (duration_count between 1 and 3650),
  price           numeric(12,2) not null default 0 check (price >= 0),
  joining_fee     numeric(12,2) not null default 0 check (joining_fee >= 0),
  freeze_days     integer not null default 0 check (freeze_days between 0 and 365),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index on mem_plans (company_id, is_active);

create table mem_members (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  party_id        uuid not null references parties(id),
  member_no       text not null,
  name            text not null check (length(name) between 1 and 200),
  phone           text check (length(phone) between 5 and 20),
  emergency_name  text check (length(emergency_name) <= 100),
  emergency_phone text check (length(emergency_phone) <= 20),
  photo_file_id   uuid references files(id) on delete set null,
  flat_no         text check (length(flat_no) <= 30),
  wing            text check (length(wing) <= 30),
  area_sqft       numeric(10,2) check (area_sqft > 0),
  occupancy       text check (occupancy in ('owner','tenant')),
  notes           text check (length(notes) <= 1000),
  is_active       boolean not null default true,
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, member_no),
  unique (company_id, party_id)
);
create index on mem_members (company_id, phone);
create index on mem_members (company_id, lower(name));

create table mem_subscriptions (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  member_id       uuid not null references mem_members(id) on delete cascade,
  plan_id         uuid not null references mem_plans(id),
  start_date      date not null,
  end_date        date,
  price           numeric(12,2) not null check (price >= 0),
  status          text not null default 'active' check (status in ('active','frozen','cancelled')),
  frozen_from     date,
  freeze_days_used integer not null default 0 check (freeze_days_used >= 0),
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (end_date is null or end_date >= start_date)
);
create index on mem_subscriptions (company_id, member_id, end_date desc);
create index on mem_subscriptions (company_id, status, end_date);

-- One invoice per subscription per period; the unique key makes bill runs safe to repeat.
create table mem_bills (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  member_id       uuid not null references mem_members(id) on delete cascade,
  subscription_id uuid not null references mem_subscriptions(id) on delete cascade,
  period          text not null check (length(period) between 1 and 30),
  invoice_id      uuid not null references invoices(id),
  created_at      timestamptz not null default now(),
  unique (subscription_id, period)
);
create index on mem_bills (company_id, member_id);

create table mem_visits (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  member_id       uuid not null references mem_members(id) on delete cascade,
  visit_date      date not null,
  visited_at      timestamptz not null default now(),
  checked_by      uuid references users(id)
);
create index on mem_visits (company_id, visit_date);
create index on mem_visits (member_id, visited_at desc);

create table job_cards (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  location_id     uuid not null references locations(id),
  party_id        uuid not null references parties(id),
  number          text not null,
  kind            text not null default 'vehicle' check (kind in ('vehicle','device')),
  vehicle_no      text check (length(vehicle_no) <= 20),
  make            text check (length(make) <= 60),
  model           text check (length(model) <= 60),
  odometer        integer check (odometer >= 0),
  serial_no       text check (length(serial_no) <= 60),
  complaints      text not null check (length(complaints) between 1 and 2000),
  accessories     text check (length(accessories) <= 500),
  photo_file_ids  uuid[] not null default '{}',
  promised_date   date,
  technician_id   uuid references users(id),
  status          text not null default 'received'
                  check (status in ('received','estimate_sent','approved','in_progress','ready','delivered','cancelled')),
  estimate_sent_at timestamptz,
  approved_at     timestamptz,
  approved_by     text check (length(approved_by) <= 100),
  started_at      timestamptz,
  ready_at        timestamptz,
  delivered_at    timestamptz,
  cancel_reason   text check (length(cancel_reason) <= 300),
  invoice_id      uuid references invoices(id),
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, number)
);
create index on job_cards (company_id, status, created_at desc);
create index on job_cards (company_id, technician_id, status);
create index on job_cards (company_id, lower(vehicle_no));

create table job_card_lines (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  job_card_id     uuid not null references job_cards(id) on delete cascade,
  line_no         integer not null,
  kind            text not null check (kind in ('part','labour')),
  item_id         uuid not null references items(id),
  description     text check (length(description) <= 300),
  qty             numeric(14,3) not null check (qty > 0),
  rate            numeric(12,2) not null check (rate >= 0),
  discount_pct    numeric(5,2) not null default 0 check (discount_pct between 0 and 100),
  issued_at       timestamptz,
  issued_by       uuid references users(id),
  unique (job_card_id, line_no)
);

do $$
declare t text;
begin
  foreach t in array array['mem_plans','mem_members','mem_subscriptions','mem_bills','mem_visits','job_cards','job_card_lines']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['mem_plans','mem_members','mem_subscriptions','job_cards']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

-- Owner and Company Admin of existing businesses get the new permissions.
update roles set permissions = array(select distinct unnest(permissions ||
  array['memberships.view','memberships.manage','memberships.checkin',
        'job_cards.view','job_cards.create','job_cards.work','job_cards.manage']) order by 1)
  where is_system and name in ('Owner','Company Admin');

-- Existing businesses with a custom module list get the modules.
update companies set enabled_modules = array_append(enabled_modules, 'memberships')
  where business_type in ('gym','salon','housing_society') and enabled_modules is not null
    and not ('memberships' = any(enabled_modules));
update companies set enabled_modules = array_append(enabled_modules, 'job_cards')
  where business_type in ('garage','electronics','auto_parts') and enabled_modules is not null
    and not ('job_cards' = any(enabled_modules));
