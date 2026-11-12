-- v1.13 manufacturing: work centres, bills of materials, production orders, material issue and output,
-- quality inspections, and job work challans. Stock and ledger rows are written by the stock and journal code.

-- New stock move kinds. Rebuilt from the kinds already allowed so other releases' kinds are kept.
do $$
declare def text; kinds text[];
begin
  select pg_get_constraintdef(oid) into def from pg_constraint
    where conname = 'stock_moves_ref_type_check' and conrelid = 'stock_moves'::regclass;
  select coalesce(array_agg(distinct m[1]), '{}') into kinds from regexp_matches(coalesce(def, ''), '''([a-z_]+)''', 'g') as m;
  kinds := array(select distinct unnest(kinds || array['production_issue','production_return','production_output',
                                                       'jobwork_out','jobwork_in','jobwork_cancel']) order by 1);
  alter table stock_moves drop constraint if exists stock_moves_ref_type_check;
  execute format('alter table stock_moves add constraint stock_moves_ref_type_check check (ref_type in (%s))',
                 (select string_agg(quote_literal(k), ',') from unnest(kinds) k));
end $$;

create table mfg_settings (
  company_id    uuid primary key references companies(id) on delete cascade,
  tenant_id     uuid not null references tenants(id) on delete cascade,
  overhead_pct  numeric(6,2) not null default 0 check (overhead_pct between 0 and 500),
  updated_at    timestamptz not null default now()
);

create table mfg_work_centres (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  name        text not null check (length(name) between 1 and 80),
  hourly_cost numeric(12,2) not null default 0 check (hourly_cost >= 0),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index mfg_work_centres_name_uq on mfg_work_centres (company_id, lower(name));

create table mfg_boms (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  item_id     uuid not null references items(id),
  version     integer not null check (version >= 1),
  output_qty  numeric(14,3) not null default 1 check (output_qty > 0),
  status      text not null default 'draft' check (status in ('draft','active','archived')),
  note        text check (length(note) <= 500),
  activated_at timestamptz,
  created_by  uuid not null references users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, item_id, version)
);
create unique index mfg_boms_one_active_uq on mfg_boms (company_id, item_id) where status = 'active';

create table mfg_bom_lines (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  bom_id     uuid not null references mfg_boms(id) on delete cascade,
  line_no    integer not null,
  kind       text not null default 'component' check (kind in ('component','byproduct')),
  item_id    uuid not null references items(id),
  qty        numeric(14,3) not null check (qty > 0),
  scrap_pct  numeric(5,2) not null default 0 check (scrap_pct between 0 and 100),
  rate       numeric(14,2) not null default 0 check (rate >= 0)
);
create index on mfg_bom_lines (bom_id);

create table mfg_bom_steps (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  bom_id           uuid not null references mfg_boms(id) on delete cascade,
  step_no          integer not null,
  operation        text not null check (length(operation) between 1 and 100),
  work_centre_id   uuid not null references mfg_work_centres(id),
  minutes_per_unit numeric(10,2) not null check (minutes_per_unit > 0)
);
create index on mfg_bom_steps (bom_id);

create table mfg_orders (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id) on delete cascade,
  number        text not null,
  fy            text not null,
  item_id       uuid not null references items(id),
  bom_id        uuid not null references mfg_boms(id),
  location_id   uuid not null references locations(id),
  qty           numeric(14,3) not null check (qty > 0),
  planned_start date,
  planned_end   date,
  status        text not null default 'draft' check (status in ('draft','released','in_progress','completed','cancelled')),
  overhead_pct  numeric(6,2) not null default 0,
  sales_order_id uuid references sales_orders(id),
  notes         text check (length(notes) <= 1000),
  good_qty      numeric(14,3) not null default 0,
  rejected_qty  numeric(14,3) not null default 0,
  material_absorbed numeric(14,2) not null default 0,
  conversion_cost   numeric(14,2) not null default 0,
  output_value  numeric(14,2) not null default 0,
  loss_value    numeric(14,2) not null default 0,
  released_at   timestamptz,
  closed_at     timestamptz,
  close_note    text check (length(close_note) <= 500),
  cancel_reason text check (length(cancel_reason) <= 300),
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (company_id, number),
  check (planned_end is null or planned_start is null or planned_end >= planned_start)
);
create index on mfg_orders (company_id, status, created_at desc);
create index on mfg_orders (item_id);

create table mfg_order_materials (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  order_id     uuid not null references mfg_orders(id) on delete cascade,
  item_id      uuid not null references items(id),
  planned_qty  numeric(14,3) not null check (planned_qty >= 0),
  issued_qty   numeric(14,3) not null default 0 check (issued_qty >= 0),
  returned_qty numeric(14,3) not null default 0 check (returned_qty >= 0),
  issued_value numeric(14,2) not null default 0,
  returned_value numeric(14,2) not null default 0,
  check (returned_qty <= issued_qty),
  unique (order_id, item_id)
);

create table mfg_order_steps (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  order_id         uuid not null references mfg_orders(id) on delete cascade,
  step_no          integer not null,
  operation        text not null,
  work_centre_id   uuid not null references mfg_work_centres(id),
  minutes_per_unit numeric(10,2) not null check (minutes_per_unit > 0),
  hourly_cost      numeric(12,2) not null default 0
);
create index on mfg_order_steps (order_id);

-- One row per issue, return or output so the order has a readable trail.
create table mfg_movements (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  order_id    uuid not null references mfg_orders(id) on delete cascade,
  kind        text not null check (kind in ('issue','return')),
  item_id     uuid not null references items(id),
  qty         numeric(14,3) not null check (qty > 0),
  cost_rate   numeric(14,4) not null default 0,
  value       numeric(14,2) not null default 0,
  note        text check (length(note) <= 300),
  created_by  uuid not null references users(id),
  created_at  timestamptz not null default now()
);
create index on mfg_movements (order_id, created_at);

create table mfg_outputs (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  order_id      uuid not null references mfg_orders(id) on delete cascade,
  output_date   date not null,
  good_qty      numeric(14,3) not null check (good_qty >= 0),
  rejected_qty  numeric(14,3) not null default 0 check (rejected_qty >= 0),
  minutes       numeric(10,2) not null default 0,
  material_cost numeric(14,2) not null default 0,
  labour_cost   numeric(14,2) not null default 0,
  overhead_cost numeric(14,2) not null default 0,
  byproduct_value numeric(14,2) not null default 0,
  unit_cost     numeric(14,4) not null default 0,
  value         numeric(14,2) not null default 0,
  loss_value    numeric(14,2) not null default 0,
  note          text check (length(note) <= 300),
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now(),
  check (good_qty + rejected_qty > 0)
);
create index on mfg_outputs (order_id, created_at);

create table mfg_output_byproducts (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  output_id uuid not null references mfg_outputs(id) on delete cascade,
  item_id   uuid not null references items(id),
  qty       numeric(14,3) not null check (qty > 0),
  value     numeric(14,2) not null default 0
);

create table mfg_inspections (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  order_id    uuid not null references mfg_orders(id) on delete cascade,
  output_id   uuid references mfg_outputs(id) on delete set null,
  pass_qty    numeric(14,3) not null default 0 check (pass_qty >= 0),
  rework_qty  numeric(14,3) not null default 0 check (rework_qty >= 0),
  reject_qty  numeric(14,3) not null default 0 check (reject_qty >= 0),
  note        text check (length(note) <= 500),
  inspected_by uuid not null references users(id),
  created_at  timestamptz not null default now(),
  check (pass_qty + rework_qty + reject_qty > 0)
);
create index on mfg_inspections (order_id);

-- Job work outward: material sent to a job worker under a delivery challan and received back processed.
create table mfg_jobwork_challans (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id) on delete cascade,
  number        text not null,
  fy            text not null,
  party_id      uuid not null references parties(id),
  location_id   uuid not null references locations(id),
  challan_date  date not null,
  process       text not null check (length(process) between 1 and 150),
  expected_return date,
  vehicle_no    text check (length(vehicle_no) <= 20),
  notes         text check (length(notes) <= 500),
  status        text not null default 'open' check (status in ('open','partially_returned','returned','cancelled')),
  cancel_reason text check (length(cancel_reason) <= 300),
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (company_id, number)
);
create index on mfg_jobwork_challans (company_id, status, challan_date desc);

create table mfg_jobwork_lines (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  challan_id     uuid not null references mfg_jobwork_challans(id) on delete cascade,
  line_no        integer not null,
  item_id        uuid not null references items(id),
  return_item_id uuid not null references items(id),
  qty_sent       numeric(14,3) not null check (qty_sent > 0),
  qty_received   numeric(14,3) not null default 0 check (qty_received >= 0),
  qty_scrap      numeric(14,3) not null default 0 check (qty_scrap >= 0),
  cost_rate      numeric(14,4) not null default 0,
  value          numeric(14,2) not null default 0,
  check (qty_received + qty_scrap <= qty_sent)
);
create index on mfg_jobwork_lines (challan_id);

create table mfg_jobwork_receipts (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  challan_id   uuid not null references mfg_jobwork_challans(id) on delete cascade,
  receipt_date date not null,
  note         text check (length(note) <= 300),
  created_by   uuid not null references users(id),
  created_at   timestamptz not null default now()
);

create table mfg_jobwork_receipt_lines (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  receipt_id  uuid not null references mfg_jobwork_receipts(id) on delete cascade,
  line_id     uuid not null references mfg_jobwork_lines(id),
  qty_received numeric(14,3) not null default 0 check (qty_received >= 0),
  qty_scrap   numeric(14,3) not null default 0 check (qty_scrap >= 0),
  value       numeric(14,2) not null default 0
);

do $$
declare t text;
begin
  foreach t in array array['mfg_settings','mfg_work_centres','mfg_boms','mfg_bom_lines','mfg_bom_steps','mfg_orders',
    'mfg_order_materials','mfg_order_steps','mfg_movements','mfg_outputs','mfg_output_byproducts','mfg_inspections',
    'mfg_jobwork_challans','mfg_jobwork_lines','mfg_jobwork_receipts','mfg_jobwork_receipt_lines']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['mfg_settings','mfg_work_centres','mfg_boms','mfg_orders','mfg_jobwork_challans']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

-- Permissions for existing businesses' built-in roles. Owner and Company Admin everywhere; the other
-- role names only in manufacturing and corporate businesses.
create function mfg_add_permissions(role_name text, extra text[]) returns void language sql as $$
  update roles set permissions = array(select distinct unnest(permissions || extra) order by 1)
  where is_system and name = role_name
    and (role_name in ('Owner', 'Company Admin') or tenant_id in (
      select tenant_id from companies where business_type in ('manufacturer','job_work','textile','pvt_ltd','public_ltd','enterprise_group')));
$$;
select mfg_add_permissions('Owner', array['manufacturing.view','manufacturing.bom','manufacturing.orders','manufacturing.issue','manufacturing.output','manufacturing.inspect','manufacturing.manage']);
select mfg_add_permissions('Company Admin', array['manufacturing.view','manufacturing.bom','manufacturing.orders','manufacturing.issue','manufacturing.output','manufacturing.inspect','manufacturing.manage']);
select mfg_add_permissions('Production Manager', array['manufacturing.view','manufacturing.bom','manufacturing.orders','manufacturing.issue','manufacturing.output','manufacturing.inspect','manufacturing.manage','purchase_orders.view','purchase_orders.manage','items.view_cost']);
select mfg_add_permissions('Store', array['manufacturing.view','manufacturing.issue']);
drop function mfg_add_permissions(text, text[]);
