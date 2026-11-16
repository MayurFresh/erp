-- Stock valuation method (average or FIFO), alternate units of measure, entered-unit columns on document lines.

create table stock_valuation_settings (
  company_id     uuid primary key references companies(id) on delete cascade,
  tenant_id      uuid not null references tenants(id) on delete cascade,
  method         text not null default 'average' check (method in ('average','fifo')),
  effective_from date not null default current_date,
  updated_by     uuid references users(id),
  updated_at     timestamptz not null default now()
);

create table item_units (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  item_id     uuid not null references items(id) on delete cascade,
  name        text not null check (length(name) between 1 and 20),
  factor      numeric(14,6) not null check (factor > 0),
  created_at  timestamptz not null default now()
);
create unique index item_units_name_uq on item_units (item_id, lower(name));

alter table items add column default_purchase_unit text check (length(default_purchase_unit) <= 20);
alter table items add column default_sale_unit text check (length(default_sale_unit) <= 20);

-- The unit the user typed on the line. qty and rate stay in the item's base unit.
alter table invoice_lines add column entered_unit text, add column entered_qty numeric(14,3);
alter table purchase_lines add column entered_unit text, add column entered_qty numeric(14,3);
alter table sales_order_lines add column entered_unit text, add column entered_qty numeric(14,3);
alter table quotation_lines add column entered_unit text, add column entered_qty numeric(14,3);

-- A converted rate (100 per box of 12 is 8.3333 per piece) needs more than two decimals.
alter table invoice_lines alter column rate type numeric(14,4);
alter table purchase_lines alter column rate type numeric(14,4);
alter table sales_order_lines alter column rate type numeric(14,4);
alter table quotation_lines alter column rate type numeric(14,4);

do $$
declare t text;
begin
  foreach t in array array['stock_valuation_settings','item_units']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
end $$;

update roles set permissions = array(select distinct unnest(permissions || array['stock.valuation']) order by 1)
  where is_system and name in ('Owner','Company Admin');
