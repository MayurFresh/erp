-- Platform extras: global search indexes, scheduled report emails, SMS channel and online payment links.

-- Search -----------------------------------------------------------------------------------------------------
do $$
begin
  create extension if not exists pg_trgm;
exception when others then
  raise notice 'pg_trgm is not available; search uses prefix indexes only';
end $$;

-- Prefix matches use these; the trigram ones (below, when the extension exists) serve "contains".
create index if not exists parties_search_name on parties (company_id, lower(name) text_pattern_ops);
create index if not exists items_search_name on items (company_id, lower(name) text_pattern_ops);
create index if not exists invoices_search_number on invoices (company_id, lower(number) text_pattern_ops);
create index if not exists purchases_search_number on purchases (company_id, lower(number) text_pattern_ops);
create index if not exists payments_search_number on payments (company_id, lower(number) text_pattern_ops);
create index if not exists employees_search_name on employees (company_id, lower(name) text_pattern_ops);
create index if not exists crm_leads_search_name on crm_leads (company_id, lower(name) text_pattern_ops);
create index if not exists crm_deals_search_title on crm_deals (company_id, lower(title) text_pattern_ops);

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_trgm') then
    create index if not exists parties_trgm_name on parties using gin (lower(name) gin_trgm_ops);
    create index if not exists items_trgm_name on items using gin (lower(name) gin_trgm_ops);
    create index if not exists employees_trgm_name on employees using gin (lower(name) gin_trgm_ops);
  end if;
end $$;

-- Notification outbox: SMS as a third channel ------------------------------------------------------------------
alter table notification_outbox drop constraint if exists notification_outbox_channel_check;
alter table notification_outbox add constraint notification_outbox_channel_check check (channel in ('email','whatsapp','sms'));

create table sms_settings (
  company_id     uuid primary key references companies(id) on delete cascade,
  tenant_id      uuid not null references tenants(id) on delete cascade,
  enabled        boolean not null default false,
  dlt_entity_id  text check (length(dlt_entity_id) <= 40),
  sender_id      text check (length(sender_id) <= 11),
  -- {"<template id>": {"dltTemplateId": "...", "text": "..."}}
  templates      jsonb not null default '{}',
  updated_at     timestamptz not null default now()
);

-- Scheduled reports -------------------------------------------------------------------------------------------
create table scheduled_reports (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  company_id       uuid not null references companies(id),
  name             text not null check (length(name) between 1 and 120),
  report           text not null check (report in ('profit_loss','sales_register','receivables_ageing','stock_valuation','gst_summary','crm_numbers')),
  filters          jsonb not null default '{}',
  frequency        text not null check (frequency in ('daily','weekly','monthly')),
  weekday          integer check (weekday between 0 and 6),
  month_day        integer check (month_day between 1 and 28),
  send_time        text not null default '08:00' check (send_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  recipient_user_ids uuid[] not null default '{}',
  recipient_emails text[] not null default '{}',
  is_active        boolean not null default true,
  next_run_at      timestamptz,
  last_run_at      timestamptz,
  created_by       uuid not null references users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index on scheduled_reports (company_id);
create index on scheduled_reports (next_run_at) where is_active;

create table scheduled_report_runs (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  report_id     uuid not null references scheduled_reports(id) on delete cascade,
  trigger       text not null check (trigger in ('schedule','manual')),
  status        text not null check (status in ('sent','failed')),
  recipients    integer not null default 0,
  row_count     integer not null default 0,
  outbox_ids    uuid[] not null default '{}',
  error         text check (length(error) <= 500),
  ran_at        timestamptz not null default now()
);
create index on scheduled_report_runs (report_id, ran_at desc);

-- One job per due report. The key includes the due time, so a report is queued once per due time.
create function scheduled_reports_enqueue() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  with ins as (
    insert into jobs (tenant_id, company_id, kind, payload, dedupe_key, max_attempts, created_by)
    select r.tenant_id, r.company_id, 'report.scheduled', jsonb_build_object('reportId', r.id, 'trigger', 'schedule'),
           'report.scheduled:' || r.id || ':' || extract(epoch from r.next_run_at)::bigint, 2, r.created_by
    from scheduled_reports r
    where r.is_active and r.next_run_at is not null and r.next_run_at <= now()
    on conflict (dedupe_key) do nothing
    returning 1)
  select count(*) into n from ins;
  return n;
end $$;

-- Online payment links ----------------------------------------------------------------------------------------
create table payment_gateways (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  provider       text not null check (provider in ('razorpay','cashfree')),
  credentials    text,
  account_id     uuid references accounts(id),
  is_active      boolean not null default false,
  webhook_rejects integer not null default 0,
  last_check_at  timestamptz,
  last_error     text check (length(last_error) <= 300),
  created_by     uuid references users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (company_id, provider)
);

create table payment_links (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  company_id       uuid not null references companies(id),
  gateway_id       uuid not null references payment_gateways(id),
  invoice_id       uuid not null references invoices(id),
  party_id         uuid not null references parties(id),
  provider         text not null,
  provider_link_id text,
  reference_id     text not null,
  short_url        text,
  amount           numeric(14,2) not null check (amount > 0),
  status           text not null default 'created' check (status in ('created','paid','expired','cancelled','failed')),
  expires_at       timestamptz,
  customer_phone   text,
  customer_email   text,
  provider_payment_id text,
  payment_id       uuid references payments(id),
  fee              numeric(14,2) not null default 0,
  paid_at          timestamptz,
  error            text check (length(error) <= 300),
  created_by       uuid not null references users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index on payment_links (company_id, created_at desc);
create index on payment_links (invoice_id);
create unique index payment_links_provider_id on payment_links (gateway_id, provider_link_id) where provider_link_id is not null;

-- The unique key is what makes a provider payment count once, however often the webhook repeats.
create table gateway_payments (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references tenants(id) on delete cascade,
  gateway_id          uuid not null references payment_gateways(id),
  link_id             uuid references payment_links(id),
  provider_payment_id text not null,
  amount              numeric(14,2) not null,
  fee                 numeric(14,2) not null default 0,
  payment_id          uuid references payments(id),
  note                text check (length(note) <= 300),
  created_at          timestamptz not null default now(),
  unique (gateway_id, provider_payment_id)
);

-- The public webhook has no tenant yet; it finds the gateway by id here, then continues inside that tenant.
create function gateway_webhook_target(p_id uuid)
returns table (tenant_id uuid, company_id uuid, provider text, is_active boolean, credentials text)
language sql stable security definer set search_path = public as $$
  select g.tenant_id, g.company_id, g.provider, g.is_active, g.credentials from payment_gateways g where g.id = p_id
$$;
create function gateway_webhook_reject(p_id uuid) returns void
language sql security definer set search_path = public as $$
  update payment_gateways set webhook_rejects = webhook_rejects + 1 where id = p_id
$$;

do $$
declare t text;
begin
  foreach t in array array['sms_settings','scheduled_reports','scheduled_report_runs','payment_gateways','payment_links','gateway_payments']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['sms_settings','scheduled_reports','payment_gateways','payment_links']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;
