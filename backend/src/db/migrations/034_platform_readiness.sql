-- v1.11 Platform readiness: append-only stock ledger, API keys, outbound webhooks.

-- 1. stock_moves is append-only (ADR-004). Corrections are new reversing rows.
--    truncate (tests, tenant removal by the platform owner) does not fire row triggers, so it still works.
create or replace function stock_moves_append_only() returns trigger
  language plpgsql as $$
begin
  raise exception 'stock_moves is append-only: % is not allowed; post a reversing move instead', tg_op
    using errcode = 'P0001';
end $$;
drop trigger if exists stock_moves_no_change on stock_moves;
create trigger stock_moves_no_change before update or delete on stock_moves
  for each row execute function stock_moves_append_only();

-- 2. API keys. Only the SHA-256 of the key is stored. The key acts with the permissions of one role.
create table api_keys (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  company_id   uuid not null references companies(id),
  name         text not null check (length(name) between 1 and 80),
  prefix       text not null,
  key_hash     text not null unique,
  role_id      uuid not null references roles(id),
  created_by   uuid not null references users(id),
  expires_at   timestamptz,
  last_used_at timestamptz,
  revoked_at   timestamptz,
  created_at   timestamptz not null default now()
);
create index on api_keys (company_id);

-- Sign-in by key has no tenant yet, so the lookup is a definer function like auth_find_user_by_email.
create or replace function auth_find_api_key(p_hash text)
  returns table (id uuid, tenant_id uuid, company_id uuid, role_id uuid, created_by uuid)
  language sql stable security definer
  set search_path = public
  as $$ select k.id, k.tenant_id, k.company_id, k.role_id, k.created_by
        from api_keys k
        where k.key_hash = p_hash and k.revoked_at is null and (k.expires_at is null or k.expires_at > now()) $$;

-- 3. Outbound webhooks.
create table webhook_endpoints (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  url           text not null check (length(url) between 8 and 500),
  description   text check (length(description) <= 200),
  secret_sealed text not null,
  events        text[] not null check (cardinality(events) > 0),
  is_active     boolean not null default true,
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on webhook_endpoints (company_id);

create table webhook_deliveries (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  endpoint_id     uuid not null references webhook_endpoints(id) on delete cascade,
  event           text not null,
  payload         jsonb not null,
  status          text not null default 'pending' check (status in ('pending','retrying','delivered','failed')),
  attempts        integer not null default 0,
  response_status integer,
  error           text check (length(error) <= 500),
  next_attempt_at timestamptz,
  delivered_at    timestamptz,
  created_at      timestamptz not null default now()
);
create index on webhook_deliveries (endpoint_id, created_at desc);

do $$
declare t text;
begin
  foreach t in array array['api_keys','webhook_endpoints','webhook_deliveries']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
end $$;

drop trigger if exists webhook_endpoints_touch on webhook_endpoints;
create trigger webhook_endpoints_touch before update on webhook_endpoints for each row execute function touch_updated_at();

-- Existing Owner and Company Admin roles get the new permission.
update roles set permissions = array_append(permissions, 'integrations.manage')
  where is_system and name in ('Owner', 'Company Admin') and not ('integrations.manage' = any(permissions));
