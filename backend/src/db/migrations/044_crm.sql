-- v1.14 CRM: leads, deals, follow-ups, contact persons, targets, IndiaMART enquiries; quotations and proforma invoices.

create table crm_settings (
  company_id           uuid primary key references companies(id),
  tenant_id            uuid not null references tenants(id) on delete cascade,
  default_owner_id     uuid references users(id) on delete set null,
  lost_reasons         text[] not null default array['Price too high','Chose another supplier','No budget','No response','Not a fit'],
  indiamart_key_sealed text,
  indiamart_last_pull_at timestamptz,
  indiamart_last_error text check (length(indiamart_last_error) <= 500),
  updated_at           timestamptz not null default now()
);

create table crm_stages (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  name        text not null check (length(name) between 1 and 60),
  probability numeric(5,2) not null check (probability between 0 and 100),
  kind        text not null default 'open' check (kind in ('open','won','lost')),
  sort        integer not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, name)
);
create index on crm_stages (company_id, sort);

create table party_contacts (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  party_id    uuid not null references parties(id) on delete cascade,
  name        text not null check (length(name) between 1 and 120),
  designation text check (length(designation) <= 80),
  phone       text check (length(phone) between 5 and 20),
  email       text check (length(email) <= 200),
  is_primary  boolean not null default false,
  notes       text check (length(notes) <= 500),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on party_contacts (party_id);
create index on party_contacts (company_id, phone);

create table crm_leads (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  company_id       uuid not null references companies(id),
  name             text not null check (length(name) between 1 and 120),
  company_name     text check (length(company_name) <= 200),
  phone            text check (length(phone) between 5 and 20),
  email            text check (length(email) <= 200),
  city             text check (length(city) <= 80),
  state_code       text check (state_code ~ '^[0-9]{2}$'),
  requirement      text check (length(requirement) <= 2000),
  estimated_value  numeric(14,2) check (estimated_value >= 0),
  source           text not null default 'other' check (source in
                     ('walk_in','phone','website','indiamart','justdial','tradeindia','referral','whatsapp','social','other')),
  source_ref       text check (length(source_ref) <= 100),
  owner_id         uuid references users(id) on delete set null,
  status           text not null default 'new' check (status in ('new','contacted','qualified','converted','lost')),
  lost_reason      text check (length(lost_reason) <= 200),
  party_id         uuid references parties(id),
  deal_id          uuid,
  first_contact_at timestamptz,
  converted_at     timestamptz,
  created_by       uuid references users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index crm_leads_source_ref_uq on crm_leads (company_id, source, source_ref) where source_ref is not null;
create index on crm_leads (company_id, status, created_at desc);
create index on crm_leads (company_id, owner_id);
create index on crm_leads (company_id, phone);

create table crm_deals (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  company_id       uuid not null references companies(id),
  title            text not null check (length(title) between 1 and 200),
  party_id         uuid references parties(id),
  contact_id       uuid references party_contacts(id) on delete set null,
  lead_id          uuid references crm_leads(id) on delete set null,
  stage_id         uuid not null references crm_stages(id),
  value            numeric(14,2) not null default 0 check (value >= 0),
  probability      numeric(5,2) check (probability between 0 and 100),
  expected_close   date,
  owner_id         uuid references users(id) on delete set null,
  status           text not null default 'open' check (status in ('open','won','lost')),
  lost_reason      text check (length(lost_reason) <= 200),
  won_at           timestamptz,
  lost_at          timestamptz,
  stage_changed_at timestamptz not null default now(),
  notes            text check (length(notes) <= 2000),
  created_by       uuid references users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (party_id is not null or lead_id is not null)
);
create index on crm_deals (company_id, status, stage_id);
create index on crm_deals (company_id, owner_id, status);
create index on crm_deals (party_id);
alter table crm_leads add constraint crm_leads_deal_fk foreign key (deal_id) references crm_deals(id) on delete set null;

create table crm_deal_stage_history (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  deal_id       uuid not null references crm_deals(id) on delete cascade,
  from_stage_id uuid references crm_stages(id),
  to_stage_id   uuid not null references crm_stages(id),
  changed_by    uuid references users(id),
  changed_at    timestamptz not null default now()
);
create index on crm_deal_stage_history (deal_id, changed_at);

create table crm_activities (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  company_id   uuid not null references companies(id),
  kind         text not null check (kind in ('call','meeting','visit','task','note','whatsapp','email')),
  subject      text not null check (length(subject) between 1 and 300),
  notes        text check (length(notes) <= 2000),
  due_at       timestamptz,
  done_at      timestamptz,
  outcome      text check (length(outcome) <= 300),
  duration_min integer check (duration_min between 0 and 1440),
  lead_id      uuid references crm_leads(id) on delete cascade,
  deal_id      uuid references crm_deals(id) on delete cascade,
  party_id     uuid references parties(id),
  owner_id     uuid references users(id) on delete set null,
  created_by   uuid references users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (lead_id is not null or deal_id is not null or party_id is not null)
);
create index on crm_activities (company_id, owner_id, done_at, due_at);
create index on crm_activities (lead_id);
create index on crm_activities (deal_id);
create index on crm_activities (party_id);

create table crm_targets (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  company_id uuid not null references companies(id),
  user_id    uuid references users(id) on delete cascade,
  month      date not null check (extract(day from month) = 1),
  amount     numeric(14,2) not null check (amount >= 0),
  unique nulls not distinct (company_id, user_id, month)
);

create table quotations (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  kind            text not null default 'quotation' check (kind in ('quotation','proforma')),
  number          text not null,
  fy              text not null,
  location_id     uuid not null references locations(id),
  party_id        uuid not null references parties(id),
  contact_id      uuid references party_contacts(id) on delete set null,
  deal_id         uuid references crm_deals(id) on delete set null,
  quote_date      date not null,
  valid_until     date,
  place_of_supply text,
  status          text not null default 'draft' check (status in ('draft','sent','accepted','declined','converted','cancelled')),
  subtotal        numeric(14,2) not null default 0,
  tax_total       numeric(14,2) not null default 0,
  total           numeric(14,2) not null default 0,
  notes           text check (length(notes) <= 2000),
  terms           text check (length(terms) <= 4000),
  revision_of     uuid references quotations(id) on delete set null,
  sales_order_id  uuid references sales_orders(id),
  invoice_id      uuid references invoices(id),
  sent_at         timestamptz,
  accepted_at     timestamptz,
  declined_at     timestamptz,
  decline_reason  text check (length(decline_reason) <= 300),
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, number)
);
create index on quotations (company_id, status, quote_date desc);
create index on quotations (party_id);
create index on quotations (deal_id);

create table quotation_lines (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  quotation_id    uuid not null references quotations(id) on delete cascade,
  line_no         integer not null,
  item_id         uuid not null references items(id),
  description     text not null check (length(description) <= 300),
  qty             numeric(14,3) not null check (qty > 0),
  rate            numeric(14,2) not null check (rate >= 0),
  discount_pct    numeric(5,2) not null default 0 check (discount_pct between 0 and 100),
  discount_amount numeric(14,2) not null default 0 check (discount_amount >= 0),
  gst_rate        numeric(5,2) not null,
  unique (quotation_id, line_no)
);

do $$
declare t text;
begin
  foreach t in array array['crm_settings','crm_stages','party_contacts','crm_leads','crm_deals','crm_deal_stage_history',
                           'crm_activities','crm_targets','quotations','quotation_lines']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['crm_settings','crm_stages','party_contacts','crm_leads','crm_deals','crm_activities','quotations']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

-- Owner and Company Admin of existing businesses get the new permissions.
update roles set permissions = array(select distinct unnest(permissions ||
  array['crm.view','crm.manage','crm.all','crm.settings','quotations.view','quotations.manage']) order by 1)
  where is_system and name in ('Owner','Company Admin');
update roles set permissions = array(select distinct unnest(permissions ||
  array['crm.view','crm.manage','quotations.view','quotations.manage']) order by 1)
  where is_system and name = 'Sales Executive';
update roles set permissions = array(select distinct unnest(permissions || array['quotations.view']) order by 1)
  where is_system and name in ('Accountant','Auditor');
update roles set permissions = array(select distinct unnest(permissions || array['crm.view']) order by 1)
  where is_system and name = 'Auditor';

-- Existing businesses with a custom module list get CRM when their type sells to customers.
update companies set enabled_modules = array_append(enabled_modules, 'crm')
  where enabled_modules is not null and 'sales' = any(enabled_modules)
    and business_type not in ('government','local_body','religious','housing_society')
    and not ('crm' = any(enabled_modules));
