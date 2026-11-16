-- v1.15 pricing: price lists, customer-specific prices, schemes.

create table price_lists (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  name        text not null check (length(name) between 1 and 80),
  mode        text not null default 'fixed' check (mode in ('fixed','percent')),
  adjust_pct  numeric(7,2) not null default 0 check (adjust_pct between -100 and 1000),
  valid_from  date,
  valid_to    date,
  is_active   boolean not null default true,
  notes       text check (length(notes) <= 500),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (valid_to is null or valid_from is null or valid_to >= valid_from)
);
create unique index price_lists_name_uq on price_lists (company_id, lower(name));

create table price_list_items (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  price_list_id uuid not null references price_lists(id) on delete cascade,
  item_id       uuid not null references items(id),
  min_qty       numeric(14,3) not null default 1 check (min_qty > 0),
  rate          numeric(14,2) not null check (rate >= 0),
  unique (price_list_id, item_id, min_qty)
);
create index on price_list_items (company_id, item_id);

create table customer_prices (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  party_id    uuid not null references parties(id) on delete cascade,
  item_id     uuid not null references items(id),
  min_qty     numeric(14,3) not null default 1 check (min_qty > 0),
  rate        numeric(14,2) not null check (rate >= 0),
  valid_from  date,
  valid_to    date,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (party_id, item_id, min_qty),
  check (valid_to is null or valid_from is null or valid_to >= valid_from)
);
create index on customer_prices (company_id, item_id);

create table price_schemes (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  company_id   uuid not null references companies(id),
  name         text not null check (length(name) between 1 and 100),
  kind         text not null check (kind in ('free_qty','slab_discount')),
  item_id      uuid not null references items(id),
  buy_qty      numeric(14,3) check (buy_qty > 0),
  free_qty     numeric(14,3) check (free_qty > 0),
  free_item_id uuid references items(id),
  min_qty      numeric(14,3) check (min_qty > 0),
  discount_pct numeric(5,2) check (discount_pct > 0 and discount_pct <= 100),
  valid_from   date,
  valid_to     date,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (valid_to is null or valid_from is null or valid_to >= valid_from),
  check ((kind = 'free_qty' and buy_qty is not null and free_qty is not null)
      or (kind = 'slab_discount' and min_qty is not null and discount_pct is not null))
);
create index on price_schemes (company_id, item_id, is_active);

alter table parties add column price_list_id uuid references price_lists(id) on delete set null;

do $$
declare t text;
begin
  foreach t in array array['price_lists','price_list_items','customer_prices','price_schemes']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['price_lists','customer_prices','price_schemes']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

update roles set permissions = array(select distinct unnest(permissions || array['pricing.manage']) order by 1)
  where is_system and name in ('Owner','Company Admin');
