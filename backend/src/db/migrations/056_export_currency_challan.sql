-- Delivery challans, export and SEZ invoices, multi-currency and TCS on sales.

do $$
declare def text; kinds text[];
begin
  select pg_get_constraintdef(oid) into def from pg_constraint
    where conname = 'stock_moves_ref_type_check' and conrelid = 'stock_moves'::regclass;
  select coalesce(array_agg(distinct m[1]), '{}') into kinds from regexp_matches(coalesce(def, ''), '''([a-z_]+)''', 'g') as m;
  kinds := array(select distinct unnest(kinds || array['challan','challan_return','challan_cancel']) order by 1);
  alter table stock_moves drop constraint if exists stock_moves_ref_type_check;
  execute format('alter table stock_moves add constraint stock_moves_ref_type_check check (ref_type in (%s))',
                 (select string_agg(quote_literal(k), ',') from unnest(kinds) k));
end $$;

-- One row per company: switches and defaults for this feature set.
create table export_settings (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  tcs_enabled     boolean not null default false,
  tcs_base        text not null default 'taxable' check (tcs_base in ('taxable','total')),
  reval_account_note text check (length(reval_account_note) <= 200),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id)
);

-- Letter of undertaking per financial year (rule 96A, FORM GST RFD-11).
create table export_luts (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  fy              text not null check (fy ~ '^[0-9]{4}-[0-9]{2}$'),
  lut_no          text not null check (length(lut_no) between 1 and 40),
  arn             text check (length(arn) <= 40),
  valid_from      date not null,
  valid_to        date not null,
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (valid_to >= valid_from),
  unique (company_id, fy)
);

create table currencies (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  code            text not null check (code ~ '^[A-Z]{3}$'),
  name            text not null check (length(name) between 1 and 60),
  symbol          text not null check (length(symbol) between 1 and 6),
  decimals        integer not null default 2 check (decimals between 0 and 4),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, code)
);

create table exchange_rates (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  currency_code   text not null check (currency_code ~ '^[A-Z]{3}$'),
  rate_date       date not null,
  rate            numeric(16,6) not null check (rate > 0),
  note            text check (length(note) <= 200),
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  unique (company_id, currency_code, rate_date)
);

-- Party defaults: currency and TCS. Kept apart so the party table is not touched.
create table party_trade_settings (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  company_id       uuid not null references companies(id),
  party_id         uuid not null references parties(id) on delete cascade,
  default_currency text check (default_currency ~ '^[A-Z]{3}$'),
  tcs_nature_id    uuid,
  tcs_exempt       boolean not null default false,
  updated_at       timestamptz not null default now(),
  unique (party_id)
);

create table tcs_natures (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  code            text not null check (length(code) between 1 and 30),
  label           text not null check (length(label) between 1 and 120),
  section_old     text not null check (length(section_old) <= 30),
  section_new     text check (length(section_new) <= 30),
  rate            numeric(6,3) not null check (rate >= 0 and rate <= 100),
  threshold       numeric(14,2) not null default 0 check (threshold >= 0),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, code)
);

create table item_tcs (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  item_id         uuid not null references items(id) on delete cascade,
  tcs_nature_id   uuid not null references tcs_natures(id),
  unique (item_id)
);

-- Export, currency and TCS facts of one invoice.
create table invoice_ext (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  invoice_id      uuid not null references invoices(id) on delete cascade,
  category        text check (category in ('export_igst','export_lut','sez_igst','sez_lut','deemed')),
  lut_id          uuid references export_luts(id),
  shipping_bill_no   text check (length(shipping_bill_no) <= 30),
  shipping_bill_date date,
  port_code       text check (length(port_code) <= 10),
  country         text check (length(country) <= 60),
  currency_code   text check (currency_code ~ '^[A-Z]{3}$'),
  exchange_rate   numeric(16,6) check (exchange_rate > 0),
  fc_total        numeric(16,4),
  tcs_nature_id   uuid references tcs_natures(id),
  tcs_section     text,
  tcs_rate        numeric(6,3),
  tcs_base        numeric(14,2),
  tcs_amount      numeric(14,2) not null default 0 check (tcs_amount >= 0),
  created_at      timestamptz not null default now(),
  unique (invoice_id)
);
create index on invoice_ext (company_id, category);
create index on invoice_ext (company_id, currency_code);

-- Foreign currency receipts: what the customer paid and what the books cleared.
create table fx_receipts (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  payment_id      uuid not null references payments(id) on delete cascade,
  currency_code   text not null,
  fc_amount       numeric(16,4) not null check (fc_amount > 0),
  receipt_rate    numeric(16,6) not null check (receipt_rate > 0),
  inr_received    numeric(14,2) not null,
  inr_cleared     numeric(14,2) not null,
  gain_loss       numeric(14,2) not null,
  unique (payment_id)
);
create table fx_receipt_lines (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  payment_id      uuid not null references payments(id) on delete cascade,
  invoice_id      uuid not null references invoices(id),
  fc_amount       numeric(16,4) not null check (fc_amount > 0),
  inr_cleared     numeric(14,2) not null
);
create index on fx_receipt_lines (invoice_id);

-- Period-end revaluation journals (reversed the next day).
create table fx_revaluations (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  as_of           date not null,
  entry_id        uuid,
  total_adjustment numeric(14,2) not null,
  status          text not null default 'posted' check (status in ('posted','cancelled')),
  detail          jsonb not null default '[]',
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now()
);

-- Delivery challans (rule 55).
create table dc_challans (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  number          text not null,
  challan_date    date not null,
  reason          text not null check (reason in ('job_work','supply_on_approval','exhibition','branch_transfer','liquid_gas','other')),
  reason_note     text check (length(reason_note) <= 200),
  location_id     uuid not null references locations(id),
  to_location_id  uuid references locations(id),
  party_id        uuid references parties(id),
  consignee_name  text not null check (length(consignee_name) between 1 and 200),
  consignee_address text check (length(consignee_address) <= 400),
  consignee_gstin text check (length(consignee_gstin) <= 15),
  consignee_state text check (length(consignee_state) <= 2),
  vehicle_no      text check (length(vehicle_no) <= 20),
  transporter     text check (length(transporter) <= 120),
  ewb_no          text check (length(ewb_no) <= 20),
  notes           text check (length(notes) <= 1000),
  status          text not null default 'open' check (status in ('open','partly_closed','closed','cancelled')),
  cancel_reason   text,
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, number)
);
create index on dc_challans (company_id, challan_date desc);
create index on dc_challans (company_id, status);

create table dc_lines (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  challan_id      uuid not null references dc_challans(id) on delete cascade,
  line_no         integer not null,
  item_id         uuid not null references items(id),
  description     text not null,
  hsn_code        text,
  unit            text not null,
  qty             numeric(14,3) not null check (qty > 0),
  provisional     boolean not null default false,
  rate            numeric(12,2) not null check (rate >= 0),
  gst_rate        numeric(5,2) not null default 0,
  taxable_value   numeric(14,2) not null default 0,
  cgst            numeric(14,2) not null default 0,
  sgst            numeric(14,2) not null default 0,
  igst            numeric(14,2) not null default 0,
  cost_rate       numeric(14,4) not null default 0,
  cost_value      numeric(14,2) not null default 0,
  cost_moved      numeric(14,2) not null default 0,
  returned_qty    numeric(14,3) not null default 0 check (returned_qty >= 0),
  invoiced_qty    numeric(14,3) not null default 0 check (invoiced_qty >= 0),
  tracked         boolean not null default false,
  unique (challan_id, line_no)
);

create table dc_events (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  challan_id      uuid not null references dc_challans(id) on delete cascade,
  kind            text not null check (kind in ('return','invoice')),
  event_date      date not null,
  invoice_id      uuid references invoices(id),
  detail          jsonb not null default '[]',
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['export_settings','export_luts','currencies','exchange_rates','party_trade_settings','tcs_natures','item_tcs',
                           'invoice_ext','fx_receipts','fx_receipt_lines','fx_revaluations','dc_challans','dc_lines','dc_events']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['export_settings','export_luts','currencies','party_trade_settings','tcs_natures','dc_challans']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

-- Owner and Company Admin of existing businesses get the new permissions.
update roles set permissions = array(select distinct unnest(permissions ||
  array['challans.view','challans.manage','fx.view','fx.manage','tcs.view','tcs.manage']) order by 1)
  where is_system and name in ('Owner','Company Admin');
update roles set permissions = array(select distinct unnest(permissions || array['challans.view','fx.view','tcs.view']) order by 1)
  where is_system and name in ('Accountant','Auditor');
update roles set permissions = array(select distinct unnest(permissions || array['challans.view','challans.manage']) order by 1)
  where is_system and name = 'Sales Executive';
