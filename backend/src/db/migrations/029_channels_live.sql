-- v1.9 phase 2: sealed credentials, pull cursors, stock push, webhook lookup and a stock change trigger.

alter table channel_connections
  add column provider_version text,
  add column credentials      text,                                  -- sealed JSON; never selected into responses
  add column push_stock       boolean not null default false,
  add column cursors          jsonb not null default '{}'::jsonb,
  add column last_check_at    timestamptz,
  add column last_success_at  timestamptz,
  add column last_error_at    timestamptz,
  add column webhook_rejects  int not null default 0;

alter table channel_listings
  add column pushed_qty  numeric(14,3),
  add column pushed_at   timestamptz,
  add column push_error  text check (length(push_error) <= 300);

create index on channel_inbox (connection_id, topic, status);

-- The public webhook route has no tenant yet; it finds the channel by id here, then continues inside that tenant.
create function channel_webhook_target(p_id uuid)
returns table (tenant_id uuid, company_id uuid, provider text, status text, credentials text, created_by uuid)
language sql stable security definer set search_path = public as $$
  select c.tenant_id, c.company_id, c.provider, c.status, c.credentials, c.created_by
  from channel_connections c where c.id = p_id
$$;

create function channel_webhook_reject(p_id uuid) returns void
language sql security definer set search_path = public as $$
  update channel_connections set webhook_rejects = webhook_rejects + 1 where id = p_id
$$;

create function channel_webhook_accept(p_id uuid) returns void
language sql security definer set search_path = public as $$
  update channel_connections set webhook_rejects = 0 where id = p_id and webhook_rejects <> 0
$$;

-- Scheduler: one pull job per connected live channel per 5-minute bucket.
create function channel_enqueue_pulls() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  with ins as (
    insert into jobs (tenant_id, company_id, kind, payload, dedupe_key, max_attempts, created_by)
    select c.tenant_id, c.company_id, 'channel.pull', jsonb_build_object('connectionId', c.id),
           'channel.pull:' || c.id || ':' || floor(extract(epoch from now()) / 300)::bigint, 3, c.created_by
    from channel_connections c
    where c.status = 'connected' and c.credentials is not null and c.provider in ('shopify','woocommerce')
    on conflict (dedupe_key) do nothing
    returning 1)
  select count(*) into n from ins;
  return n;
end $$;

-- Stock changed: queue one channel.stock job per company in the current tenant that pushes stock. The job runs at the
-- end of the one-minute bucket, so every change inside the bucket is seen by one diff-based run.
create function channel_stock_changed() returns trigger
language plpgsql security definer set search_path = public as $$
declare bucket bigint := floor(extract(epoch from now()) / 60)::bigint;
begin
  insert into jobs (tenant_id, company_id, kind, payload, dedupe_key, run_after, max_attempts, created_by)
  select distinct on (c.company_id) c.tenant_id, c.company_id, 'channel.stock', '{}'::jsonb,
         'channel.stock:' || c.company_id || ':' || bucket, to_timestamp((bucket + 1) * 60), 3, c.created_by
  from channel_connections c
  where c.tenant_id = app_tenant_id() and c.push_stock and c.status = 'connected'
  on conflict (dedupe_key) do nothing;
  return null;
end $$;

create trigger channel_stock_moves_changed after insert on stock_moves
  for each statement execute function channel_stock_changed();
create trigger channel_reservations_ins_changed after insert on stock_reservations
  for each statement execute function channel_stock_changed();
create trigger channel_reservations_upd_changed after update on stock_reservations
  for each statement execute function channel_stock_changed();
