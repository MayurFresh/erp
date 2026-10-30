-- v1.5 hardening: idempotency keys for POST requests (kept 24 hours).

create table idempotency_keys (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  user_id     uuid not null,
  key         text not null,
  method      text not null,
  path        text not null,
  body_hash   text not null,
  status      integer,
  response    jsonb,
  state       text not null default 'running' check (state in ('running','done')),
  created_at  timestamptz not null default now(),
  unique (tenant_id, user_id, key)
);
create index on idempotency_keys (created_at);

alter table idempotency_keys enable row level security;
create policy tenant_isolation on idempotency_keys using (tenant_id = app_tenant_id())
  with check (tenant_id = app_tenant_id());
