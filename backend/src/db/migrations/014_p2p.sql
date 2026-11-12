-- v1.8 procure to pay and stock counts: purchase orders, goods receipts (GRN), three-way match, cycle counts.

-- Approval engine also covers purchase orders ------------------------------------------------
do $$
declare t text; c text; d text;
begin
  foreach t in array array['approval_rules','approval_requests'] loop
    c := t || '_doc_type_check';
    select pg_get_constraintdef(oid) into d from pg_constraint where conrelid = t::regclass and conname = c;
    if d is not null and position('purchase_order' in d) = 0 then
      d := replace(d, '''credit_note''::text', '''credit_note''::text, ''purchase_order''::text');
      execute format('alter table %I drop constraint %I', t, c);
      execute format('alter table %I add constraint %I %s', t, c, d);
    end if;
  end loop;
end $$;

-- Company settings ---------------------------------------------------------------------------
alter table companies
  add column po_receipt_tolerance_pct numeric(5,2) not null default 0 check (po_receipt_tolerance_pct between 0 and 100),
  add column po_price_tolerance_pct   numeric(5,2) not null default 0 check (po_price_tolerance_pct between 0 and 100),
  add column count_approval_value     numeric(14,2) not null default 10000 check (count_approval_value >= 0);

-- Purchase orders ----------------------------------------------------------------------------
create table purchase_orders (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references tenants(id) on delete cascade,
  company_id           uuid not null references companies(id) on delete cascade,
  location_id          uuid not null references locations(id),
  party_id             uuid not null references parties(id),
  number               text not null,
  fy                   text not null,
  order_date           date not null,
  expected_date        date,
  status               text not null default 'draft' check (status in
    ('draft','pending_approval','approved','sent','partially_received','received','closed','cancelled')),
  place_of_supply      text not null,
  supply_type          text not null check (supply_type in ('intra','inter')),
  subtotal             numeric(14,2) not null,
  cgst                 numeric(14,2) not null default 0,
  sgst                 numeric(14,2) not null default 0,
  igst                 numeric(14,2) not null default 0,
  round_off            numeric(14,2) not null default 0,
  total                numeric(14,2) not null,
  notes                text,
  approval_request_id  uuid references approval_requests(id),
  submitted_at         timestamptz,
  approved_at          timestamptz,
  sent_at              timestamptz,
  cancelled_at         timestamptz,
  cancel_reason        text,
  created_by           uuid not null references users(id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (company_id, number)
);
create index on purchase_orders (company_id, status, order_date desc);
create index on purchase_orders (company_id, party_id);

create table purchase_order_lines (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  purchase_order_id uuid not null references purchase_orders(id) on delete cascade,
  line_no           integer not null,
  item_id           uuid not null references items(id),
  description       text not null,
  hsn_code          text,
  qty               numeric(14,3) not null check (qty > 0),
  unit              text not null,
  rate              numeric(14,2) not null check (rate >= 0),
  discount_pct      numeric(5,2) not null default 0,
  taxable_value     numeric(14,2) not null,
  gst_rate          numeric(5,2) not null,
  cgst              numeric(14,2) not null default 0,
  sgst              numeric(14,2) not null default 0,
  igst              numeric(14,2) not null default 0,
  line_total        numeric(14,2) not null,
  received_qty      numeric(14,3) not null default 0 check (received_qty >= 0),
  rejected_qty      numeric(14,3) not null default 0 check (rejected_qty >= 0),
  billed_qty        numeric(14,3) not null default 0 check (billed_qty >= 0),
  cancelled_qty     numeric(14,3) not null default 0 check (cancelled_qty >= 0)
);
create index on purchase_order_lines (purchase_order_id);

-- Goods receipts -----------------------------------------------------------------------------
create table goods_receipts (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  company_id        uuid not null references companies(id) on delete cascade,
  purchase_order_id uuid not null references purchase_orders(id),
  party_id          uuid not null references parties(id),
  location_id       uuid not null references locations(id),
  number            text not null,
  fy                text not null,
  receipt_date      date not null,
  challan_no        text,
  challan_date      date,
  vehicle_no        text,
  notes             text,
  status            text not null default 'posted' check (status in ('posted','cancelled')),
  created_by        uuid not null references users(id),
  created_at        timestamptz not null default now(),
  cancelled_at      timestamptz,
  cancel_reason     text,
  unique (company_id, number)
);
create index on goods_receipts (company_id, receipt_date desc);
create index on goods_receipts (purchase_order_id);

create table goods_receipt_lines (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  goods_receipt_id  uuid not null references goods_receipts(id) on delete cascade,
  line_no           integer not null,
  po_line_id        uuid not null references purchase_order_lines(id),
  item_id           uuid not null references items(id),
  received_qty      numeric(14,3) not null check (received_qty > 0),
  accepted_qty      numeric(14,3) not null check (accepted_qty >= 0),
  rejected_qty      numeric(14,3) not null default 0 check (rejected_qty >= 0),
  reject_reason     text,
  unit_cost         numeric(14,4) not null,
  value             numeric(14,2) not null default 0,
  billed_qty        numeric(14,3) not null default 0 check (billed_qty >= 0),
  cleared_value     numeric(14,2) not null default 0,
  check (received_qty = accepted_qty + rejected_qty)
);
create index on goods_receipt_lines (goods_receipt_id);
create index on goods_receipt_lines (po_line_id);

-- Bills may reference the goods they invoice --------------------------------------------------
alter table purchases
  add column purchase_order_id uuid references purchase_orders(id),
  add column variance_accepted boolean not null default false;
alter table purchase_lines
  add column grn_line_id uuid references goods_receipt_lines(id),
  add column grni_value numeric(14,2) not null default 0,
  add column variance_value numeric(14,2) not null default 0;
create index on purchase_lines (grn_line_id) where grn_line_id is not null;

-- Stock counts -------------------------------------------------------------------------------
create table stock_counts (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id) on delete cascade,
  location_id    uuid not null references locations(id),
  number         text not null,
  fy             text not null,
  scope          text not null check (scope in ('all','selected')),
  status         text not null default 'open' check (status in ('open','posted','cancelled')),
  snapshot_at    timestamptz not null default now(),
  notes          text,
  variance_value numeric(14,2),
  approved_by    uuid references users(id),
  posted_by      uuid references users(id),
  posted_at      timestamptz,
  cancelled_at   timestamptz,
  cancel_reason  text,
  created_by     uuid not null references users(id),
  created_at     timestamptz not null default now(),
  unique (company_id, number)
);
create index on stock_counts (company_id, status, created_at desc);

create table stock_count_lines (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  count_id     uuid not null references stock_counts(id) on delete cascade,
  item_id      uuid not null references items(id),
  expected_qty numeric(14,3) not null,
  counted_qty  numeric(14,3) check (counted_qty is null or counted_qty >= 0),
  counted_at   timestamptz,
  counted_by   uuid references users(id),
  variance_qty numeric(14,3),
  variance_value numeric(14,2),
  unique (count_id, item_id)
);

create table stock_count_scans (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  count_id   uuid not null references stock_counts(id) on delete cascade,
  scan_id    text not null,
  item_id    uuid not null references items(id),
  code       text,
  mode       text not null check (mode in ('add','set')),
  qty        numeric(14,3) not null,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  unique (count_id, scan_id)
);

-- Row-level security -------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['purchase_orders','purchase_order_lines','goods_receipts','goods_receipt_lines',
                           'stock_counts','stock_count_lines','stock_count_scans']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
end $$;

-- New system accounts for existing companies (2140 Goods received not invoiced, 5110 Purchase price variance)
do $$
declare c record; k record; n integer;
begin
  for c in select id, tenant_id from companies loop
    for k in select * from (values
      ('2140', 'Goods Received Not Invoiced', 'liability', 'grni'),
      ('5110', 'Purchase Price Variance', 'expense', 'purchase_price_variance')
    ) as v(code, name, type, key) loop
      if not exists (select 1 from accounts where company_id = c.id and system_key = k.key) then
        n := k.code::integer;
        while exists (select 1 from accounts where company_id = c.id and code = n::text) loop n := n + 1; end loop;
        insert into accounts (tenant_id, company_id, code, name, type, subtype, system_key, is_system)
        values (c.tenant_id, c.id, n::text, k.name, k.type, 'other', k.key, true);
      end if;
    end loop;
  end loop;
end $$;

-- New permissions for the built-in roles of existing businesses --------------------------------
create function add_permissions(role_name text, extra text[]) returns void language sql as $$
  update roles set permissions = array(select distinct unnest(permissions || extra) order by 1)
  where is_system and name = role_name;
$$;
select add_permissions('Owner', array['purchase_orders.view','purchase_orders.manage','grn.manage','purchases.override','stock_counts.manage','stock_counts.approve']);
select add_permissions('Company Admin', array['purchase_orders.view','purchase_orders.manage','grn.manage','purchases.override','stock_counts.manage','stock_counts.approve']);
select add_permissions('Accountant', array['purchase_orders.view','purchase_orders.manage']);
select add_permissions('Store Keeper', array['purchase_orders.view','grn.manage','stock_counts.manage']);
select add_permissions('Project Manager', array['purchase_orders.view']);
select add_permissions('Auditor', array['purchase_orders.view']);
drop function add_permissions(text, text[]);
