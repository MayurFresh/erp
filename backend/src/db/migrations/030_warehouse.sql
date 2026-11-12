-- v1.10 Warehouse depth: bins, batches and expiry, serial numbers, putaway and picking by bin, FEFO.
-- Additive. stock_moves is untouched; wh_moves is a sub-ledger that says where inside a location the stock sits.
-- Stock on hand not covered by wh_moves is "unassigned" (no bin, no batch).

create table wh_settings (
  company_id        uuid primary key references companies(id) on delete cascade,
  tenant_id         uuid not null references tenants(id) on delete cascade,
  fefo              boolean not null default true,
  block_expired     boolean not null default true,
  expiry_warn_days  integer not null default 90 check (expiry_warn_days between 0 and 3650),
  updated_at        timestamptz not null default now()
);

create table wh_bins (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  location_id   uuid not null references locations(id),
  code          text not null check (length(code) between 1 and 30),
  name          text check (length(name) <= 100),
  zone          text check (length(zone) <= 40),
  kind          text not null default 'storage' check (kind in ('storage','receiving','dispatch','quarantine')),
  capacity_qty  numeric(14,3) check (capacity_qty > 0),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (company_id, location_id, code)
);

create table wh_item_rules (
  item_id         uuid primary key references items(id) on delete cascade,
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  tracking        text not null default 'none' check (tracking in ('none','batch','serial')),
  shelf_life_days integer check (shelf_life_days between 1 and 36500),
  updated_at      timestamptz not null default now()
);

create table wh_batches (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  company_id   uuid not null references companies(id),
  item_id      uuid not null references items(id),
  batch_no     text not null check (length(batch_no) between 1 and 50),
  mfg_date     date,
  expiry_date  date,
  mrp          numeric(12,2) check (mrp >= 0),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (company_id, item_id, batch_no),
  check (mfg_date is null or expiry_date is null or expiry_date >= mfg_date)
);
create index on wh_batches (company_id, expiry_date);

create table wh_serials (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  item_id        uuid not null references items(id),
  serial_no      text not null check (length(serial_no) between 1 and 80),
  batch_id       uuid references wh_batches(id),
  location_id    uuid not null references locations(id),
  bin_id         uuid references wh_bins(id),
  status         text not null default 'in_stock' check (status in ('in_stock','issued')),
  warranty_until date,
  issued_ref     text check (length(issued_ref) <= 80),
  issued_at      timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (company_id, item_id, serial_no)
);
create index on wh_serials (company_id, serial_no);

create table wh_moves (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  company_id   uuid not null references companies(id),
  location_id  uuid not null references locations(id),
  item_id      uuid not null references items(id),
  bin_id       uuid references wh_bins(id),
  batch_id     uuid references wh_batches(id),
  qty          numeric(14,3) not null check (qty <> 0),
  kind         text not null check (kind in ('receipt','putaway_out','putaway_in','pick','adjust')),
  ref_type     text check (length(ref_type) <= 40),
  ref_id       uuid,
  note         text check (length(note) <= 300),
  created_by   uuid references users(id),
  created_at   timestamptz not null default now()
);
create index on wh_moves (company_id, location_id, item_id);
create index on wh_moves (company_id, bin_id);

create or replace function wh_moves_append_only() returns trigger
language plpgsql as $$
begin
  raise exception 'wh_moves is append-only: % is not allowed; post a reversing move instead', tg_op
    using errcode = 'restrict_violation';
end $$;
create trigger wh_moves_no_change before update or delete on wh_moves
  for each row execute function wh_moves_append_only();

do $$
declare t text;
begin
  foreach t in array array['wh_settings','wh_bins','wh_item_rules','wh_batches','wh_serials','wh_moves']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['wh_settings','wh_bins','wh_item_rules','wh_batches','wh_serials']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

update roles set permissions = array(select distinct unnest(permissions ||
  array['warehouse.view','warehouse.pick','warehouse.manage']) order by 1)
  where is_system and name in ('Owner','Company Admin','Shop Owner','Pharmacy Owner');

update companies set enabled_modules = array_append(enabled_modules, 'warehouse')
  where business_type in ('medical_store','wholesale','electronics','retail','hardware','auto_parts','manufacturer')
    and enabled_modules is not null and not ('warehouse' = any(enabled_modules));
