-- v1.7 enterprise platform: 2FA, sessions, password reset, SSO, jobs, notifications, approvals,
-- custom fields, cost centres, CSV import, inter-company entries, GSP adapter.

alter table journal_entries drop constraint journal_entries_voucher_type_check;
alter table journal_entries add constraint journal_entries_voucher_type_check check (voucher_type in
  ('sales','purchase','receipt','payment','credit_note','expense','stock','transfer','journal','issue','wages',
   'labour_advance','contractor_advance','ra_bill','retention_release','demand','possession',
   'tds_challan','bank_entry',
   'gst_payment','gst_setoff','tax_payment','asset_capitalise','depreciation','asset_disposal',
   'intercompany','opening'));

-- Identity ---------------------------------------------------------------------------------

alter table users
  add column two_factor_secret_enc  text,
  add column two_factor_pending_enc text,
  add column two_factor_enabled_at  timestamptz,
  add column two_factor_last_step   bigint,
  add column recovery_codes         text[] not null default '{}',
  add column failed_logins          integer not null default 0,
  add column locked_until           timestamptz,
  add column password_changed_at    timestamptz;

alter table refresh_tokens
  add column session_id   uuid,
  add column user_agent   text check (length(user_agent) <= 300),
  add column ip           text check (length(ip) <= 64),
  add column last_used_at timestamptz,
  add column amr          text not null default 'pwd' check (amr in ('pwd','mfa','sso'));
update refresh_tokens set session_id = id where session_id is null;
alter table refresh_tokens alter column session_id set not null;
create index on refresh_tokens (session_id);

-- One row per password sign-in that still needs its second factor (the mfaToken's jti).
create table mfa_challenges (
  id          uuid primary key,
  tenant_id   uuid not null references tenants(id) on delete cascade,
  user_id     uuid not null references users(id) on delete cascade,
  attempts    integer not null default 0,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  created_at  timestamptz not null default now()
);

create table password_resets (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  user_id     uuid not null references users(id) on delete cascade,
  token_hash  text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  expires_at  timestamptz not null,
  used_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index on password_resets (user_id);

create table sso_providers (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references tenants(id) on delete cascade,
  name                text not null check (length(name) between 1 and 80),
  issuer              text not null check (issuer ~ '^https://'),
  client_id           text not null check (length(client_id) between 1 and 300),
  client_secret_enc   text,
  email_domains       text[] not null check (cardinality(email_domains) between 1 and 10),
  enforce             boolean not null default false,
  auto_provision      boolean not null default false,
  default_company_id  uuid references companies(id),
  default_role_id     uuid references roles(id),
  is_active           boolean not null default true,
  created_by          uuid references users(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table sso_states (
  state          text primary key,
  tenant_id      uuid not null references tenants(id) on delete cascade,
  provider_id    uuid not null references sso_providers(id) on delete cascade,
  nonce          text not null,
  code_verifier  text not null,
  return_to      text not null,
  expires_at     timestamptz not null,
  created_at     timestamptz not null default now()
);

create table sso_tickets (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  ticket_hash  text not null unique check (ticket_hash ~ '^[0-9a-f]{64}$'),
  user_id      uuid not null references users(id) on delete cascade,
  provider_id  uuid not null references sso_providers(id) on delete cascade,
  expires_at   timestamptz not null,
  used_at      timestamptz,
  created_at   timestamptz not null default now()
);

-- Company settings and the GSP adapter -----------------------------------------------------

alter table companies drop constraint companies_einvoice_mode_check;
alter table companies add constraint companies_einvoice_mode_check check (einvoice_mode in ('manual','sandbox','gsp'));
alter table companies
  add column require_2fa          boolean not null default false,
  add column cost_centre_required boolean not null default false,
  add column gsp_provider         text check (length(gsp_provider) <= 40);

create table gsp_credentials (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  provider    text not null,
  -- { key: plain value } for non-secret fields, { key: sealed value } for secret ones.
  values      jsonb not null default '{}',
  updated_by  uuid references users(id),
  updated_at  timestamptz not null default now(),
  unique (company_id, provider)
);

create table gsp_submissions (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  kind        text not null check (kind in ('gstr1')),
  period      text not null check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  provider    text not null,
  reference   text not null,
  status      text not null,
  response    jsonb,
  created_by  uuid not null references users(id),
  created_at  timestamptz not null default now()
);
create index on gsp_submissions (company_id, period);

-- Background jobs and notifications ----------------------------------------------------------

create table jobs (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid references companies(id) on delete cascade,
  kind          text not null check (length(kind) <= 60),
  payload       jsonb not null default '{}',
  status        text not null default 'queued' check (status in ('queued','running','done','failed')),
  attempts      integer not null default 0,
  max_attempts  integer not null default 3 check (max_attempts between 1 and 10),
  run_after     timestamptz not null default now(),
  started_at    timestamptz,
  finished_at   timestamptz,
  result        jsonb,
  error         text,
  dedupe_key    text unique,
  created_by    uuid references users(id),
  created_at    timestamptz not null default now()
);
create index jobs_ready on jobs (run_after) where status = 'queued';
create index on jobs (company_id, created_at desc);

create table notifications (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid references companies(id) on delete cascade,
  user_id     uuid not null references users(id) on delete cascade,
  template    text not null,
  title       text not null,
  body        text not null,
  link        text,
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index on notifications (user_id, created_at desc);
create index notifications_unread on notifications (user_id) where read_at is null;

create table notification_outbox (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid references companies(id) on delete cascade,
  channel       text not null check (channel in ('email','whatsapp')),
  to_address    text,
  user_id       uuid references users(id) on delete set null,
  party_id      uuid references parties(id) on delete set null,
  template      text not null,
  subject       text,
  body          text not null,
  data          jsonb not null default '{}',
  status        text not null default 'pending' check (status in ('pending','sent','failed','skipped')),
  attempts      integer not null default 0,
  error         text,
  provider_ref  text,
  sent_at       timestamptz,
  created_at    timestamptz not null default now()
);
create index on notification_outbox (company_id, created_at desc);
create index on notification_outbox (party_id, channel, created_at desc) where party_id is not null;

create table notification_prefs (
  tenant_id  uuid not null references tenants(id) on delete cascade,
  user_id    uuid not null references users(id) on delete cascade,
  template   text not null,
  email      boolean not null,
  whatsapp   boolean,
  updated_at timestamptz not null default now(),
  primary key (user_id, template)
);

-- Approvals ------------------------------------------------------------------------------------

create table approval_rules (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  doc_type    text not null check (doc_type in ('purchase','payment','expense','journal','credit_note')),
  name        text not null check (length(name) between 1 and 80),
  min_amount  numeric(14,2) not null check (min_amount >= 0),
  location_id uuid references locations(id),
  is_active   boolean not null default true,
  created_by  uuid references users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on approval_rules (company_id, doc_type) where is_active;

create table approval_rule_levels (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  rule_id           uuid not null references approval_rules(id) on delete cascade,
  level             integer not null check (level between 1 and 5),
  approver_role_id  uuid references roles(id),
  approver_user_id  uuid references users(id),
  check ((approver_role_id is null) <> (approver_user_id is null)),
  unique (rule_id, level)
);

create table approval_requests (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  company_id       uuid not null references companies(id) on delete cascade,
  number           text not null,
  doc_type         text not null check (doc_type in ('purchase','payment','expense','journal','credit_note')),
  status           text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  amount           numeric(14,2) not null,
  doc_date         date not null,
  party_id         uuid references parties(id),
  location_id      uuid references locations(id),
  narration        text,
  payload          jsonb not null,
  rule_id          uuid not null references approval_rules(id),
  rule_name        text not null,
  levels           jsonb not null,
  current_level    integer not null default 1,
  total_levels     integer not null,
  requested_by     uuid not null references users(id),
  requested_at     timestamptz not null default now(),
  decided_at       timestamptz,
  document_id      uuid,
  document_number  text
);
create index on approval_requests (company_id, status, requested_at desc);
create index on approval_requests (requested_by);

create table approval_actions (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  request_id  uuid not null references approval_requests(id) on delete cascade,
  level       integer,
  action      text not null check (action in ('submitted','approved','rejected','cancelled')),
  user_id     uuid not null references users(id),
  comment     text check (length(comment) <= 500),
  created_at  timestamptz not null default now()
);
create index on approval_actions (request_id);

-- Custom fields ----------------------------------------------------------------------------

create table custom_fields (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id) on delete cascade,
  entity         text not null check (entity in ('item','party','invoice','purchase','project')),
  key            text not null check (key ~ '^[a-z][a-z0-9_]{1,29}$'),
  label          text not null check (length(label) between 1 and 60),
  type           text not null check (type in ('text','number','date','boolean','select')),
  options        text[] not null default '{}',
  required       boolean not null default false,
  show_on_print  boolean not null default false,
  sort_order     integer not null default 0,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (company_id, entity, key)
);

alter table items     add column custom jsonb not null default '{}';
alter table parties   add column custom jsonb not null default '{}';
alter table invoices  add column custom jsonb not null default '{}';
alter table purchases add column custom jsonb not null default '{}';
alter table projects  add column custom jsonb not null default '{}';

-- Cost centres -------------------------------------------------------------------------------

create table cost_centres (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  code        text not null check (length(code) between 1 and 20),
  name        text not null check (length(name) between 1 and 80),
  parent_id   uuid references cost_centres(id),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create unique index cost_centres_code on cost_centres (company_id, lower(code));

alter table journal_lines add column cost_centre_id uuid references cost_centres(id);
create index on journal_lines (cost_centre_id) where cost_centre_id is not null;
create index on journal_lines (location_id) where location_id is not null;
alter table invoices     add column cost_centre_id uuid references cost_centres(id);
alter table purchases    add column cost_centre_id uuid references cost_centres(id);
alter table expenses     add column cost_centre_id uuid references cost_centres(id);
alter table credit_notes add column cost_centre_id uuid references cost_centres(id);

-- Branch P&L: tag older document lines with their document's location.
update journal_lines jl set location_id = d.location_id
  from journal_entries je join invoices d on d.id = je.voucher_id
  where jl.entry_id = je.id and je.voucher_type = 'sales' and jl.location_id is null;
update journal_lines jl set location_id = d.location_id
  from journal_entries je join purchases d on d.id = je.voucher_id
  where jl.entry_id = je.id and je.voucher_type = 'purchase' and jl.location_id is null;
update journal_lines jl set location_id = d.location_id
  from journal_entries je join credit_notes d on d.id = je.voucher_id
  where jl.entry_id = je.id and je.voucher_type = 'credit_note' and jl.location_id is null;

-- CSV import and inter-company entries ---------------------------------------------------------

create table import_jobs (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  company_id   uuid not null references companies(id) on delete cascade,
  kind         text not null check (kind in ('items','parties','opening_stock','account_balances')),
  status       text not null check (status in ('validated','invalid','queued','running','done','failed')),
  file_name    text check (length(file_name) <= 200),
  csv          text not null,
  total_rows   integer not null default 0,
  valid_rows   integer not null default 0,
  errors       jsonb not null default '[]',
  preview      jsonb not null default '[]',
  options      jsonb not null default '{}',
  result       jsonb,
  error        text,
  job_id       uuid references jobs(id) on delete set null,
  created_by   uuid not null references users(id),
  created_at   timestamptz not null default now(),
  finished_at  timestamptz
);
create index on import_jobs (company_id, created_at desc);

create table intercompany_entries (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  number           text not null,
  entry_date       date not null,
  amount           numeric(14,2) not null check (amount > 0),
  narration        text not null check (length(narration) between 3 and 300),
  status           text not null default 'posted' check (status in ('posted','cancelled')),
  from_company_id  uuid not null references companies(id),
  from_account_id  uuid not null references accounts(id),
  from_entry_id    uuid not null references journal_entries(id),
  to_company_id    uuid not null references companies(id),
  to_account_id    uuid not null references accounts(id),
  to_entry_id      uuid not null references journal_entries(id),
  created_by       uuid not null references users(id),
  created_at       timestamptz not null default now(),
  cancelled_at     timestamptz,
  cancel_reason    text,
  check (from_company_id <> to_company_id)
);
create index on intercompany_entries (from_company_id, entry_date);
create index on intercompany_entries (to_company_id, entry_date);

do $$
declare t text;
begin
  foreach t in array array['mfa_challenges','password_resets','sso_providers','sso_states','sso_tickets',
                           'gsp_credentials','gsp_submissions','jobs','notifications','notification_outbox',
                           'notification_prefs','approval_rules','approval_rule_levels','approval_requests',
                           'approval_actions','custom_fields','cost_centres','import_jobs','intercompany_entries']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
end $$;

-- Lookups that must cross businesses before the tenant is known (owned by the migration role) ----

create function auth_find_password_reset(p_hash text)
  returns table (id uuid, tenant_id uuid, user_id uuid, expires_at timestamptz, used_at timestamptz)
  language sql stable security definer
  set search_path = public
  as $$ select r.id, r.tenant_id, r.user_id, r.expires_at, r.used_at from password_resets r where r.token_hash = p_hash $$;

create function auth_find_sso_by_domain(p_domain text)
  returns table (id uuid, tenant_id uuid, name text, enforce boolean)
  language sql stable security definer
  set search_path = public
  as $$ select p.id, p.tenant_id, p.name, p.enforce from sso_providers p
        where p.is_active and lower(p_domain) = any (p.email_domains) order by p.created_at $$;

create function auth_find_sso_provider(p_id uuid)
  returns table (id uuid, tenant_id uuid, issuer text, client_id text, is_active boolean)
  language sql stable security definer
  set search_path = public
  as $$ select p.id, p.tenant_id, p.issuer, p.client_id, p.is_active from sso_providers p where p.id = p_id $$;

-- Single use: the row is deleted as it is read.
create function auth_take_sso_state(p_state text)
  returns table (tenant_id uuid, provider_id uuid, nonce text, code_verifier text, return_to text, expires_at timestamptz)
  language sql volatile security definer
  set search_path = public
  as $$ delete from sso_states s where s.state = p_state
        returning s.tenant_id, s.provider_id, s.nonce, s.code_verifier, s.return_to, s.expires_at $$;

create function auth_take_sso_ticket(p_hash text)
  returns table (tenant_id uuid, user_id uuid, provider_id uuid)
  language sql volatile security definer
  set search_path = public
  as $$ update sso_tickets t set used_at = now()
        where t.ticket_hash = p_hash and t.used_at is null and t.expires_at > now()
        returning t.tenant_id, t.user_id, t.provider_id $$;

-- Claims up to p_limit ready jobs for this worker; jobs stuck in 'running' for 10 minutes go back to the queue.
create function jobs_claim(p_limit integer)
  returns setof jobs
  language plpgsql volatile security definer
  set search_path = public
  as $$
begin
  update jobs set status = 'queued' where status = 'running' and started_at < now() - interval '10 minutes';
  return query
    update jobs j set status = 'running', attempts = j.attempts + 1, started_at = now()
    where j.id in (select q.id from jobs q where q.status = 'queued' and q.run_after <= now()
                   order by q.run_after limit p_limit for update skip locked)
    returning j.*;
end $$;

-- One job of p_kind per company for p_day; returns how many were added.
create function jobs_enqueue_daily(p_kind text, p_day date)
  returns integer
  language plpgsql volatile security definer
  set search_path = public
  as $$
declare n integer;
begin
  insert into jobs (tenant_id, company_id, kind, payload, dedupe_key)
    select c.tenant_id, c.id, p_kind, jsonb_build_object('day', p_day), p_kind || ':' || c.id || ':' || p_day
    from companies c
    on conflict (dedupe_key) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- New permissions for the built-in roles of existing businesses ----------------------------

create function add_permissions(role_name text, extra text[]) returns void language sql as $$
  update roles set permissions = array(select distinct unnest(permissions || extra) order by 1)
  where is_system and name = role_name;
$$;

select add_permissions('Owner', array['approvals.view','approvals.manage','imports.run','companies.create','security.manage']);
select add_permissions('Company Admin', array['approvals.view','approvals.manage','imports.run']);
select add_permissions('Accountant', array['approvals.view','imports.run']);
select add_permissions('Auditor', array['approvals.view']);

drop function add_permissions(text, text[]);
