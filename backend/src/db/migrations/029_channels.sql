-- v1.9 Channels: marketplaces and web stores. Orders arrive by CSV import (or a connector later), become sales orders,
-- and settlement reports are reconciled and posted to the books. No credentials or network calls are stored yet.

create table channel_connections (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  company_id        uuid not null references companies(id),
  provider          text not null check (provider in ('manual','amazon','flipkart','meesho','shopify','woocommerce','other')),
  name              text not null check (length(name) between 1 and 80),
  status            text not null default 'connected' check (status in ('not_connected','connected','degraded','suspended','disabled')),
  status_reason     text check (length(status_reason) <= 300),
  party_id          uuid not null references parties(id),
  location_id       uuid not null references locations(id),
  order_status      text not null default 'confirmed' check (order_status in ('draft','confirmed')),
  prices_include_tax boolean not null default true,
  stock_buffer      numeric(14,3) not null default 0 check (stock_buffer >= 0),
  tcs_rate          numeric(5,3) not null default 0.5 check (tcs_rate between 0 and 100),
  tds_rate          numeric(5,3) not null default 0.1 check (tds_rate between 0 and 100),
  csv_mapping       jsonb not null default '{}'::jsonb,
  settlement_aliases jsonb not null default '{}'::jsonb,
  last_import_at    timestamptz,
  last_error        text check (length(last_error) <= 500),
  created_by        uuid not null references users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (company_id, name)
);
create index on channel_connections (company_id);

create table channel_listings (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  connection_id  uuid not null references channel_connections(id) on delete cascade,
  channel_sku    text not null check (length(channel_sku) between 1 and 100),
  title          text check (length(title) <= 300),
  external_id    text check (length(external_id) <= 100),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (connection_id, channel_sku)
);

-- A single item is one component with qty 1; a bundle has several.
create table channel_listing_components (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  listing_id  uuid not null references channel_listings(id) on delete cascade,
  item_id     uuid not null references items(id),
  qty         numeric(14,3) not null default 1 check (qty > 0),
  unique (listing_id, item_id)
);
create index on channel_listing_components (item_id);

create table channel_inbox (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  connection_id   uuid not null references channel_connections(id) on delete cascade,
  event_id        text not null check (length(event_id) between 1 and 150),
  topic           text not null default 'order',
  source          text not null default 'csv' check (source in ('csv','webhook','poll')),
  payload         jsonb not null,
  status          text not null default 'received' check (status in ('received','processed','ignored','failed','dead')),
  attempts        int not null default 0,
  error           text check (length(error) <= 500),
  error_code      text check (length(error_code) <= 40),
  sales_order_id  uuid references sales_orders(id),
  order_date      date,
  total           numeric(14,2),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (connection_id, event_id)
);
create index on channel_inbox (company_id, status, created_at desc);

-- SKUs that arrived with no mapping: the fix list.
create table channel_unmapped (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  connection_id  uuid not null references channel_connections(id) on delete cascade,
  channel_sku    text not null,
  title          text,
  seen_count     int not null default 1,
  first_seen_at  timestamptz not null default now(),
  last_seen_at   timestamptz not null default now(),
  unique (connection_id, channel_sku)
);

create table channel_settlements (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  company_id       uuid not null references companies(id),
  connection_id    uuid not null references channel_connections(id) on delete cascade,
  settlement_ref   text not null check (length(settlement_ref) between 1 and 100),
  payout_date      date not null,
  payout           numeric(14,2) not null,
  lines_total      numeric(14,2) not null,
  status           text not null default 'imported' check (status in ('imported','matched','posted','unbalanced')),
  bank_account_id  uuid references accounts(id),
  journal_entry_id uuid references journal_entries(id),
  posted_at        timestamptz,
  created_by       uuid not null references users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (connection_id, settlement_ref)
);
create index on channel_settlements (company_id, payout_date desc);

create table channel_settlement_lines (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  settlement_id   uuid not null references channel_settlements(id) on delete cascade,
  line_no         int not null,
  order_ref       text,
  sales_order_id  uuid references sales_orders(id),
  kind            text not null check (kind in ('sale','refund','commission','fee','shipping','gst_on_fees','tcs','tds',
                                                'reserve','reserve_release','adjustment')),
  label           text,
  amount          numeric(14,2) not null,
  unique (settlement_id, line_no)
);
create index on channel_settlement_lines (sales_order_id);

-- Orders keep the channel they came from. The old external reference index now covers orders with no channel.
alter table sales_orders add column channel_id uuid references channel_connections(id);
drop index sales_orders_external_uq;
create unique index sales_orders_external_uq on sales_orders (company_id, source, external_ref)
  where external_ref is not null and channel_id is null;
create unique index sales_orders_channel_ref_uq on sales_orders (channel_id, external_ref)
  where channel_id is not null and external_ref is not null;
create index on sales_orders (channel_id) where channel_id is not null;

-- Voucher type 'settlement': add to whatever list the check holds now, so other releases' types are kept.
do $$
declare def text;
begin
  select pg_get_constraintdef(oid) into def from pg_constraint
    where conrelid = 'journal_entries'::regclass and conname = 'journal_entries_voucher_type_check';
  if def is not null and def not like '%''settlement''%' then
    execute 'alter table journal_entries drop constraint journal_entries_voucher_type_check';
    execute format('alter table journal_entries add constraint journal_entries_voucher_type_check check (voucher_type in (%s))',
      (select string_agg(quote_literal(v), ',') from (
         select distinct v from (
           select (regexp_matches(def, '''([a-z_]+)''', 'g'))[1] as v union select 'settlement') s) t));
  end if;
end $$;

do $$
declare t text;
begin
  foreach t in array array['channel_connections','channel_listings','channel_listing_components','channel_inbox',
                           'channel_unmapped','channel_settlements','channel_settlement_lines']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
end $$;

drop trigger if exists channel_connections_touch on channel_connections;
create trigger channel_connections_touch before update on channel_connections for each row execute function touch_updated_at();
drop trigger if exists channel_settlements_touch on channel_settlements;
create trigger channel_settlements_touch before update on channel_settlements for each row execute function touch_updated_at();

create function add_permissions(role_name text, extra text[]) returns void language sql as $$
  update roles set permissions = array(select distinct unnest(permissions || extra) order by 1)
  where is_system and name = role_name;
$$;
select add_permissions('Owner', array['channels.view','channels.manage','settlements.manage']);
select add_permissions('Company Admin', array['channels.view','channels.manage','settlements.manage']);
select add_permissions('Accountant', array['channels.view','settlements.manage']);
select add_permissions('Sales Executive', array['channels.view']);
select add_permissions('Auditor', array['channels.view']);
drop function add_permissions(text, text[]);
