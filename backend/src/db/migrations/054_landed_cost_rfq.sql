-- Landed cost vouchers and requests for quotation.

-- Value-only stock moves: a landed cost raises stock value without changing quantity.
do $$
declare def text; kinds text[];
begin
  select pg_get_constraintdef(oid) into def from pg_constraint
    where conname = 'stock_moves_ref_type_check' and conrelid = 'stock_moves'::regclass;
  select coalesce(array_agg(distinct m[1]), '{}') into kinds from regexp_matches(coalesce(def, ''), '''([a-z_]+)''', 'g') as m;
  kinds := array(select distinct unnest(kinds || array['landed_cost','landed_cost_cancel']) order by 1);
  alter table stock_moves drop constraint if exists stock_moves_ref_type_check;
  execute format('alter table stock_moves add constraint stock_moves_ref_type_check check (ref_type in (%s))',
                 (select string_agg(quote_literal(k), ',') from unnest(kinds) k));
  alter table stock_moves drop constraint if exists stock_moves_qty_check;
  alter table stock_moves add constraint stock_moves_qty_nonzero
    check (qty <> 0 or ref_type in ('landed_cost','landed_cost_cancel'));
end $$;

create table landed_costs (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  number          text not null,
  fy              text not null,
  voucher_date    date not null,
  basis           text not null check (basis in ('value','qty','weight')),
  charges_total   numeric(14,2) not null check (charges_total >= 0),
  igst_total      numeric(14,2) not null default 0 check (igst_total >= 0),
  inventory_total numeric(14,2) not null default 0,
  cogs_total      numeric(14,2) not null default 0,
  status          text not null default 'posted' check (status in ('posted','cancelled')),
  notes           text check (length(notes) <= 1000),
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  cancelled_at    timestamptz,
  cancel_reason   text,
  unique (company_id, number)
);
create index on landed_costs (company_id, voucher_date desc);

create table landed_cost_charges (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  landed_cost_id  uuid not null references landed_costs(id) on delete cascade,
  line_no         integer not null,
  kind            text not null check (kind in ('freight','customs_duty','insurance','clearing','handling','other')),
  description     text check (length(description) <= 200),
  amount          numeric(14,2) not null check (amount >= 0),
  igst_amount     numeric(14,2) not null default 0 check (igst_amount >= 0),
  source_type     text not null default 'direct' check (source_type in ('direct','expense','vendor_bill','journal')),
  source_id       uuid,
  credit_account_id uuid references accounts(id),
  party_id        uuid references parties(id)
);
create index on landed_cost_charges (landed_cost_id);
create index on landed_cost_charges (source_id) where source_id is not null;

create table landed_cost_lines (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  landed_cost_id  uuid not null references landed_costs(id) on delete cascade,
  line_no         integer not null,
  doc_type        text not null check (doc_type in ('purchase','grn')),
  doc_id          uuid not null,
  doc_line_id     uuid not null,
  doc_number      text not null,
  doc_date        date not null,
  item_id         uuid not null references items(id),
  location_id     uuid not null references locations(id),
  qty             numeric(14,3) not null,
  base_value      numeric(14,2) not null,
  weight          numeric(14,3) not null default 0,
  on_hand_pct     numeric(7,4) not null default 100,
  allocated       numeric(14,2) not null default 0,
  to_inventory    numeric(14,2) not null default 0,
  to_cogs         numeric(14,2) not null default 0
);
create index on landed_cost_lines (landed_cost_id);
create index on landed_cost_lines (doc_id);
create index on landed_cost_lines (item_id);

create table rfqs (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  location_id     uuid not null references locations(id),
  number          text not null,
  fy              text not null,
  rfq_date        date not null,
  due_date        date,
  status          text not null default 'draft' check (status in ('draft','sent','quotes_received','closed')),
  indent_id       uuid references indents(id),
  notes           text check (length(notes) <= 1000),
  sent_at         timestamptz,
  closed_at       timestamptz,
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, number)
);
create index on rfqs (company_id, rfq_date desc);

create table rfq_lines (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  rfq_id          uuid not null references rfqs(id) on delete cascade,
  line_no         integer not null,
  item_id         uuid not null references items(id),
  description     text,
  qty             numeric(14,3) not null check (qty > 0),
  unit            text not null,
  indent_line_id  uuid references indent_lines(id),
  chosen_party_id uuid references parties(id),
  purchase_order_id uuid references purchase_orders(id)
);
create index on rfq_lines (rfq_id);

create table rfq_vendors (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  rfq_id          uuid not null references rfqs(id) on delete cascade,
  party_id        uuid not null references parties(id),
  sent_at         timestamptz,
  unique (rfq_id, party_id)
);

create table rfq_quotes (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  rfq_id          uuid not null references rfqs(id) on delete cascade,
  rfq_line_id     uuid not null references rfq_lines(id) on delete cascade,
  party_id        uuid not null references parties(id),
  rate            numeric(14,2) not null check (rate >= 0),
  discount_pct    numeric(5,2) not null default 0 check (discount_pct between 0 and 100),
  gst_rate        numeric(5,2) not null default 0 check (gst_rate between 0 and 100),
  lead_days       integer check (lead_days between 0 and 3650),
  payment_terms   text check (length(payment_terms) <= 200),
  valid_until     date,
  notes           text check (length(notes) <= 500),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (rfq_line_id, party_id)
);
create index on rfq_quotes (rfq_id);

do $$
declare t text;
begin
  foreach t in array array['landed_costs','landed_cost_charges','landed_cost_lines','rfqs','rfq_lines','rfq_vendors','rfq_quotes']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['landed_costs','rfqs','rfq_quotes']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;
