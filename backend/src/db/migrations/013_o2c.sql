-- v1.8 order to cash: sales orders, stock reservations, pick lists, scans, shipments, sales returns.

create table sales_orders (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  location_id     uuid not null references locations(id),
  party_id        uuid not null references parties(id),
  number          text not null,
  fy              text not null,
  order_date      date not null,
  expected_date   date,
  status          text not null default 'draft' check (status in
    ('draft','confirmed','picking','packed','partially_dispatched','dispatched','closed','cancelled')),
  source          text not null default 'manual' check (source in ('manual','csv','channel')),
  external_ref    text check (external_ref is null or length(external_ref) between 1 and 100),
  place_of_supply text not null,
  subtotal        numeric(14,2) not null default 0,
  tax_total       numeric(14,2) not null default 0,
  total           numeric(14,2) not null default 0,
  notes           text check (length(notes) <= 2000),
  cancel_reason   text check (length(cancel_reason) <= 300),
  confirmed_at    timestamptz,
  cancelled_at    timestamptz,
  closed_at       timestamptz,
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, number)
);
create unique index sales_orders_external_uq on sales_orders (company_id, source, external_ref) where external_ref is not null;
create index on sales_orders (company_id, status, order_date desc);
create index on sales_orders (party_id);

create table sales_order_lines (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  order_id       uuid not null references sales_orders(id) on delete cascade,
  line_no        integer not null,
  item_id        uuid not null references items(id),
  description    text not null check (length(description) <= 300),
  qty_ordered    numeric(14,3) not null check (qty_ordered > 0),
  rate           numeric(14,2) not null check (rate >= 0),
  discount_pct   numeric(5,2) not null default 0 check (discount_pct between 0 and 100),
  gst_rate       numeric(5,2) not null,
  allow_backorder boolean not null default false,
  qty_reserved   numeric(14,3) not null default 0 check (qty_reserved >= 0),
  qty_picked     numeric(14,3) not null default 0 check (qty_picked >= 0),
  qty_packed     numeric(14,3) not null default 0 check (qty_packed >= 0),
  qty_dispatched numeric(14,3) not null default 0 check (qty_dispatched >= 0),
  qty_returned   numeric(14,3) not null default 0 check (qty_returned >= 0),
  qty_cancelled  numeric(14,3) not null default 0 check (qty_cancelled >= 0),
  unique (order_id, line_no),
  check (qty_dispatched <= qty_packed and qty_packed <= qty_picked),
  check (qty_dispatched + qty_cancelled <= qty_ordered),
  check (qty_reserved <= qty_ordered - qty_dispatched - qty_cancelled),
  check (qty_returned <= qty_dispatched)
);
create index on sales_order_lines (order_id);
create index on sales_order_lines (item_id);

create table sales_order_events (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  order_id    uuid not null references sales_orders(id) on delete cascade,
  kind        text not null check (length(kind) <= 40),
  message     text not null check (length(message) <= 500),
  created_by  uuid references users(id),
  created_at  timestamptz not null default now()
);
create index on sales_order_events (order_id, created_at);

create table stock_reservations (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  location_id   uuid not null references locations(id),
  item_id       uuid not null references items(id),
  order_line_id uuid not null references sales_order_lines(id) on delete cascade,
  qty           numeric(14,3) not null check (qty > 0),
  status        text not null default 'active' check (status in ('active','consumed','released')),
  note          text check (length(note) <= 300),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index stock_reservations_active_idx on stock_reservations (company_id, location_id, item_id) where status = 'active';
create index on stock_reservations (order_line_id);

create table pick_lists (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  location_id   uuid not null references locations(id),
  number        text not null,
  status        text not null default 'open' check (status in ('open','completed','cancelled')),
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now(),
  completed_at  timestamptz,
  unique (company_id, number)
);
create index on pick_lists (company_id, status, created_at desc);

create table pick_list_lines (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  pick_list_id  uuid not null references pick_lists(id) on delete cascade,
  line_no       integer not null,
  order_id      uuid not null references sales_orders(id),
  order_line_id uuid not null references sales_order_lines(id),
  item_id       uuid not null references items(id),
  qty_target    numeric(14,3) not null check (qty_target > 0),
  qty_picked    numeric(14,3) not null default 0 check (qty_picked >= 0),
  unique (pick_list_id, line_no),
  check (qty_picked <= qty_target)
);
create index on pick_list_lines (order_line_id);

-- One row per accepted scan. The client's scan id makes a repeated scan return the first result.
create table scan_events (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  kind        text not null check (kind in ('pick','pack')),
  ref_id      uuid not null,
  scan_id     text not null check (length(scan_id) between 4 and 100),
  code        text check (length(code) <= 64),
  item_id     uuid not null references items(id),
  qty         numeric(14,3) not null check (qty > 0),
  result      jsonb not null,
  created_by  uuid references users(id),
  created_at  timestamptz not null default now(),
  unique (company_id, kind, ref_id, scan_id)
);

create table shipments (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  order_id      uuid not null references sales_orders(id),
  invoice_id    uuid not null references invoices(id),
  number        text not null,
  courier       text check (length(courier) <= 100),
  awb           text check (length(awb) <= 60),
  mode          text not null default 'prepaid' check (mode in ('prepaid','cod')),
  cod_amount    numeric(14,2) not null default 0 check (cod_amount >= 0),
  status        text not null default 'booked' check (status in
    ('booked','in_transit','delivered','rto_initiated','rto_delivered','lost')),
  dispatch_key  text check (length(dispatch_key) <= 100),
  notes         text check (length(notes) <= 500),
  dispatched_at timestamptz not null default now(),
  delivered_at  timestamptz,
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (company_id, number),
  unique (invoice_id),
  check (mode = 'cod' or cod_amount = 0)
);
create unique index shipments_dispatch_key_uq on shipments (company_id, dispatch_key) where dispatch_key is not null;
create index on shipments (company_id, status, created_at desc);
create index on shipments (order_id);

create table shipment_lines (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  shipment_id      uuid not null references shipments(id) on delete cascade,
  order_line_id    uuid not null references sales_order_lines(id),
  invoice_line_id  uuid not null references invoice_lines(id),
  item_id          uuid not null references items(id),
  qty              numeric(14,3) not null check (qty > 0)
);
create index on shipment_lines (shipment_id);
create index on shipment_lines (order_line_id);
create index on shipment_lines (invoice_line_id);

create table shipment_status_history (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  shipment_id  uuid not null references shipments(id) on delete cascade,
  status       text not null,
  note         text check (length(note) <= 300),
  created_by   uuid references users(id),
  created_at   timestamptz not null default now()
);
create index on shipment_status_history (shipment_id, created_at);

create table sales_returns (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  company_id       uuid not null references companies(id),
  location_id      uuid not null references locations(id),
  invoice_id       uuid not null references invoices(id),
  order_id         uuid references sales_orders(id),
  shipment_id      uuid references shipments(id),
  party_id         uuid not null references parties(id),
  number           text not null,
  type             text not null default 'customer_return' check (type in ('customer_return','rto')),
  status           text not null default 'requested' check (status in ('requested','received','inspected','closed','cancelled')),
  reason           text not null check (length(reason) between 3 and 300),
  credit_note_id   uuid references credit_notes(id),
  received_at      timestamptz,
  inspected_at     timestamptz,
  closed_at        timestamptz,
  created_by       uuid references users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (company_id, number)
);
create unique index sales_returns_rto_uq on sales_returns (shipment_id) where type = 'rto' and status <> 'cancelled';
create index on sales_returns (company_id, status, created_at desc);
create index on sales_returns (invoice_id);

create table sales_return_lines (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  return_id        uuid not null references sales_returns(id) on delete cascade,
  line_no          integer not null,
  invoice_line_id  uuid not null references invoice_lines(id),
  order_line_id    uuid references sales_order_lines(id),
  item_id          uuid not null references items(id),
  qty              numeric(14,3) not null check (qty > 0),
  qty_received     numeric(14,3) check (qty_received >= 0),
  disposition      text check (disposition in ('restock','damaged','scrap')),
  note             text check (length(note) <= 300),
  unique (return_id, line_no)
);
create index on sales_return_lines (invoice_line_id);

do $$
declare t text;
begin
  foreach t in array array['sales_orders','sales_order_lines','sales_order_events','stock_reservations','pick_lists',
                           'pick_list_lines','scan_events','shipments','shipment_lines','shipment_status_history',
                           'sales_returns','sales_return_lines']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
end $$;

-- Permissions for the built-in roles of existing businesses.
create function add_permissions(role_name text, extra text[]) returns void language sql as $$
  update roles set permissions = array(select distinct unnest(permissions || extra) order by 1)
  where is_system and name = role_name;
$$;
select add_permissions('Owner', array['sales_orders.view','sales_orders.manage','fulfilment.manage','returns.manage']);
select add_permissions('Company Admin', array['sales_orders.view','sales_orders.manage','fulfilment.manage','returns.manage']);
select add_permissions('Accountant', array['sales_orders.view','returns.manage']);
select add_permissions('Sales Executive', array['sales_orders.view','sales_orders.manage']);
select add_permissions('Store Keeper', array['sales_orders.view','fulfilment.manage','returns.manage']);
select add_permissions('Auditor', array['sales_orders.view']);
drop function add_permissions(text, text[]);
