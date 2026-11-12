-- Wave 2: restaurant operations (menu, floor, orders, kitchen tickets). Bills post through the normal invoice and receipt services.

create table restaurant_settings (
  company_id         uuid primary key references companies(id) on delete cascade,
  tenant_id          uuid not null references tenants(id) on delete cascade,
  service_charge_pct numeric(5,2) not null default 0 check (service_charge_pct between 0 and 30),
  service_charge_gst numeric(5,2) not null default 5 check (service_charge_gst between 0 and 28),
  location_id        uuid references locations(id),
  updated_at         timestamptz not null default now()
);

create table restaurant_categories (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  name        text not null check (length(name) between 1 and 80),
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index restaurant_categories_name_uq on restaurant_categories (company_id, lower(name));

create table restaurant_menu (
  item_id     uuid primary key references items(id) on delete cascade,
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  category_id uuid references restaurant_categories(id) on delete set null,
  diet        text not null default 'veg' check (diet in ('veg','non_veg','egg')),
  available   boolean not null default true,
  station     text not null default 'Main' check (length(station) between 1 and 40),
  short_name  text check (short_name is null or length(short_name) between 1 and 40),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on restaurant_menu (company_id, category_id);

create table restaurant_areas (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  name        text not null check (length(name) between 1 and 60),
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index restaurant_areas_name_uq on restaurant_areas (company_id, lower(name));

create table restaurant_tables (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  area_id     uuid not null references restaurant_areas(id),
  name        text not null check (length(name) between 1 and 30),
  seats       integer not null default 4 check (seats between 1 and 100),
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index restaurant_tables_name_uq on restaurant_tables (company_id, lower(name));

-- Per-day counters for order and KOT numbers.
create table restaurant_counters (
  company_id uuid not null references companies(id) on delete cascade,
  tenant_id  uuid not null references tenants(id) on delete cascade,
  kind       text not null check (kind in ('order','kot')),
  day        date not null,
  next_no    integer not null,
  primary key (company_id, kind, day)
);

create table restaurant_orders (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  company_id       uuid not null references companies(id) on delete cascade,
  location_id      uuid not null references locations(id),
  number           text not null,
  order_date       date not null,
  kind             text not null check (kind in ('dine_in','takeaway','delivery')),
  table_id         uuid references restaurant_tables(id),
  covers           integer check (covers is null or covers between 1 and 500),
  captain_id       uuid references users(id),
  customer_party_id uuid references parties(id),
  customer_name    text check (length(customer_name) <= 120),
  customer_phone   text check (length(customer_phone) <= 20),
  delivery_address text check (length(delivery_address) <= 300),
  notes            text check (length(notes) <= 500),
  status           text not null default 'open' check (status in ('open','bill_printed','settled','cancelled')),
  discount_pct     numeric(5,2) not null default 0 check (discount_pct between 0 and 100),
  discount_reason  text check (length(discount_reason) <= 200),
  service_charge_pct numeric(5,2) not null default 0,
  bill_printed_at  timestamptz,
  settled_at       timestamptz,
  invoice_id       uuid references invoices(id),
  cancel_reason    text check (length(cancel_reason) <= 300),
  created_by       uuid not null references users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (company_id, order_date, number),
  check (kind <> 'dine_in' or table_id is not null or status in ('settled','cancelled'))
);
create unique index restaurant_orders_table_active_uq on restaurant_orders (table_id) where status in ('open','bill_printed');
create index on restaurant_orders (company_id, status, created_at desc);

create table restaurant_kots (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  order_id    uuid not null references restaurant_orders(id) on delete cascade,
  kot_date    date not null,
  kot_no      integer not null,
  station     text not null,
  status      text not null default 'new' check (status in ('new','preparing','ready','served','cancelled')),
  created_by  uuid not null references users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, kot_date, kot_no, station)
);
create index on restaurant_kots (company_id, station, status);
create index on restaurant_kots (order_id);

create table restaurant_order_lines (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  order_id      uuid not null references restaurant_orders(id) on delete cascade,
  item_id       uuid not null references items(id),
  name          text not null,
  short_name    text,
  station       text not null,
  qty           numeric(10,3) not null check (qty > 0),
  rate          numeric(14,2) not null check (rate >= 0),
  note          text check (length(note) <= 200),
  state         text not null default 'draft' check (state in ('draft','sent','cancelled')),
  kitchen_status text not null default 'new' check (kitchen_status in ('new','preparing','ready','served')),
  kot_id        uuid references restaurant_kots(id),
  cancel_reason text check (length(cancel_reason) <= 300),
  cancelled_by  uuid references users(id),
  cancelled_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (state <> 'cancelled' or cancel_reason is not null or kot_id is null)
);
create index on restaurant_order_lines (order_id);
create index on restaurant_order_lines (kot_id);

do $$
declare t text;
begin
  foreach t in array array['restaurant_settings','restaurant_categories','restaurant_menu','restaurant_areas','restaurant_tables',
                           'restaurant_counters','restaurant_orders','restaurant_kots','restaurant_order_lines']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array['restaurant_settings','restaurant_categories','restaurant_menu','restaurant_areas','restaurant_tables',
                           'restaurant_orders','restaurant_kots','restaurant_order_lines']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

-- Permissions for existing businesses' built-in roles.
-- Owner and Company Admin everywhere; other role names only in food and hotel businesses,
-- because names like Manager and Cashier also exist in shops and clinics.
create function add_permissions(role_name text, extra text[]) returns void language sql as $$
  update roles set permissions = array(select distinct unnest(permissions || extra) order by 1)
  where is_system and name = role_name
    and (role_name in ('Owner', 'Company Admin') or tenant_id in (
      select tenant_id from companies where business_type in ('restaurant', 'cafe', 'cloud_kitchen', 'caterer', 'hotel')));
$$;
select add_permissions('Owner', array['restaurant.orders','restaurant.kitchen','restaurant.settle','restaurant.manage']);
select add_permissions('Company Admin', array['restaurant.orders','restaurant.kitchen','restaurant.settle','restaurant.manage']);
select add_permissions('Manager', array['restaurant.orders','restaurant.kitchen','restaurant.settle','restaurant.manage']);
select add_permissions('General Manager', array['restaurant.orders','restaurant.kitchen','restaurant.settle','restaurant.manage']);
select add_permissions('Captain', array['restaurant.orders']);
select add_permissions('Cashier', array['restaurant.orders','restaurant.settle']);
select add_permissions('Kitchen', array['restaurant.kitchen']);
drop function add_permissions(text, text[]);
