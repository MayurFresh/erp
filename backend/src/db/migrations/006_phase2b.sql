-- Phase 2b: labour advance register, subcontract work orders and RA bills, real-estate sales
-- (units, payment plans, bookings, demands, RERA account) and GST e-invoice / e-way bill fields.

alter table journal_entries drop constraint journal_entries_voucher_type_check;
alter table journal_entries add constraint journal_entries_voucher_type_check check (voucher_type in
  ('sales','purchase','receipt','payment','credit_note','expense','stock','transfer','journal','issue','wages',
   'labour_advance','contractor_advance','ra_bill','retention_release','demand','possession'));

alter table payment_allocations drop constraint payment_allocations_doc_type_check;
alter table payment_allocations add constraint payment_allocations_doc_type_check
  check (doc_type in ('invoice','purchase','ra_bill','demand'));

-- Master data needed by TDS defaults and e-invoice JSON --------------------------------------

alter table parties
  add column pan text check (pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  add column pincode text check (pincode ~ '^[1-9][0-9]{5}$');
alter table companies
  add column pincode text check (pincode ~ '^[1-9][0-9]{5}$'),
  add column einvoice_enabled boolean not null default false,
  add column einvoice_mode text not null default 'manual' check (einvoice_mode in ('manual','sandbox'));
alter table locations add column pincode text check (pincode ~ '^[1-9][0-9]{5}$');
alter table projects
  add column rera_reg_no text,
  add column rera_account_id uuid references accounts(id);

alter table invoices
  add column irn text,
  add column irn_ack_no text,
  add column irn_ack_date timestamptz,
  add column irn_status text check (irn_status in ('active','cancelled')),
  add column irn_signed_qr text,
  add column irn_sandbox boolean not null default false,
  add column irn_cancelled_at timestamptz,
  add column irn_cancel_reason text,
  add column ewb_no text,
  add column ewb_date timestamptz,
  add column ewb_valid_until timestamptz,
  add column ewb_status text check (ewb_status in ('active','cancelled')),
  add column ewb_transport_mode text check (ewb_transport_mode in ('road','rail','air','ship')),
  add column ewb_vehicle_no text,
  add column ewb_distance_km integer check (ewb_distance_km between 0 and 4000),
  add column ewb_transporter_gstin text,
  add column ewb_cancelled_at timestamptz;
create unique index on invoices (company_id, irn) where irn is not null and irn_status = 'active';

-- Labour advance register ----------------------------------------------------------------------

create table labour_advances (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references tenants(id),
  company_id            uuid not null references companies(id),
  number                text not null,
  worker_id             uuid not null references workers(id),
  site_id               uuid references locations(id),
  advance_date          date not null,
  amount                numeric(14,2) not null check (amount > 0),
  recovered             numeric(14,2) not null default 0 check (recovered >= 0 and recovered <= amount),
  paid_from_account_id  uuid not null references accounts(id),
  notes                 text,
  status                text not null default 'open' check (status in ('open','recovered','cancelled')),
  created_by            uuid not null references users(id),
  created_at            timestamptz not null default now(),
  cancelled_at          timestamptz,
  cancel_reason         text
);
create index on labour_advances (worker_id, advance_date);

-- One row per advance a paid wage sheet recovered from (FIFO by advance date).
create table labour_advance_recoveries (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references tenants(id),
  labour_advance_id  uuid not null references labour_advances(id),
  wage_sheet_id      uuid not null references wage_sheets(id),
  amount             numeric(14,2) not null check (amount > 0)
);
create index on labour_advance_recoveries (labour_advance_id);
create index on labour_advance_recoveries (wage_sheet_id);

-- Subcontract work orders and running-account bills --------------------------------------------

create table work_orders (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references tenants(id),
  company_id            uuid not null references companies(id),
  number                text not null,
  project_id            uuid not null references projects(id),
  contractor_party_id   uuid not null references parties(id),
  order_date            date not null,
  title                 text not null,
  scope                 text,
  status                text not null default 'draft' check (status in ('draft','active','closed','cancelled')),
  retention_pct         numeric(5,2) not null default 5 check (retention_pct between 0 and 20),
  advance_recovery_pct  numeric(5,2) not null default 0 check (advance_recovery_pct between 0 and 100),
  tds_pct               numeric(5,2) not null default 2 check (tds_pct between 0 and 20),
  gst_pct               numeric(5,2) not null default 18 check (gst_pct between 0 and 28),
  itc_eligible          boolean not null default true,
  cess_pct              numeric(5,2) not null default 0 check (cess_pct between 0 and 2),
  total_value           numeric(14,2) not null default 0,
  created_by            uuid not null references users(id),
  created_at            timestamptz not null default now(),
  closed_at             timestamptz,
  cancelled_at          timestamptz,
  cancel_reason         text
);
create unique index on work_orders (company_id, number);
create index on work_orders (project_id);
create index on work_orders (contractor_party_id);

create table work_order_lines (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id),
  work_order_id  uuid not null references work_orders(id),
  line_no        integer not null,
  boq_line_id    uuid references boq_lines(id),
  description    text not null,
  unit           text not null,
  qty            numeric(14,3) not null check (qty > 0),
  rate           numeric(14,2) not null check (rate >= 0),
  amount         numeric(14,2) not null
);
create index on work_order_lines (work_order_id);

create table contractor_advances (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references tenants(id),
  company_id            uuid not null references companies(id),
  number                text not null,
  work_order_id         uuid not null references work_orders(id),
  advance_date          date not null,
  amount                numeric(14,2) not null check (amount > 0),
  paid_from_account_id  uuid not null references accounts(id),
  notes                 text,
  created_by            uuid not null references users(id),
  created_at            timestamptz not null default now(),
  cancelled_at          timestamptz,
  cancel_reason         text
);
create unique index on contractor_advances (company_id, number);
create index on contractor_advances (work_order_id);

create table ra_bills (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references tenants(id),
  company_id            uuid not null references companies(id),
  number                text not null,
  work_order_id         uuid not null references work_orders(id),
  bill_seq              integer not null,
  bill_date             date not null,
  period_from           date,
  period_to             date,
  due_date              date not null,
  status                text not null default 'draft' check (status in ('draft','submitted','approved','cancelled')),
  is_final              boolean not null default false,
  gross                 numeric(14,2) not null default 0,
  cgst                  numeric(14,2) not null default 0,
  sgst                  numeric(14,2) not null default 0,
  igst                  numeric(14,2) not null default 0,
  retention             numeric(14,2) not null default 0,
  advance_recovery      numeric(14,2) not null default 0,
  tds                   numeric(14,2) not null default 0,
  cess                  numeric(14,2) not null default 0,
  other_deduction       numeric(14,2) not null default 0,
  other_deduction_note  text,
  net_payable           numeric(14,2) not null default 0,
  amount_paid           numeric(14,2) not null default 0,
  notes                 text,
  reject_reason         text,
  created_by            uuid not null references users(id),
  created_at            timestamptz not null default now(),
  submitted_at          timestamptz,
  approved_by           uuid references users(id),
  approved_at           timestamptz,
  cancelled_at          timestamptz,
  cancel_reason         text,
  unique (work_order_id, bill_seq)
);
create unique index on ra_bills (company_id, number);

create table ra_bill_lines (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references tenants(id),
  ra_bill_id          uuid not null references ra_bills(id),
  work_order_line_id  uuid not null references work_order_lines(id),
  prev_qty            numeric(14,3) not null default 0,
  cum_qty             numeric(14,3) not null,
  this_qty            numeric(14,3) not null,
  rate                numeric(14,2) not null,
  amount              numeric(14,2) not null,
  unique (ra_bill_id, work_order_line_id)
);

create table retention_releases (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id),
  company_id     uuid not null references companies(id),
  number         text not null,
  work_order_id  uuid not null references work_orders(id),
  release_date   date not null,
  amount         numeric(14,2) not null check (amount > 0),
  notes          text,
  created_by     uuid not null references users(id),
  created_at     timestamptz not null default now()
);
create unique index on retention_releases (company_id, number);
create index on retention_releases (work_order_id);

-- Real-estate sales ------------------------------------------------------------------------------

create table units (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id),
  company_id    uuid not null references companies(id),
  project_id    uuid not null references projects(id),
  code          text not null,
  wing          text,
  floor         integer,
  unit_type     text not null,
  carpet_area   numeric(10,2) not null check (carpet_area > 0),
  balcony_area  numeric(10,2) check (balcony_area >= 0),
  list_price    numeric(14,2) not null default 0 check (list_price >= 0),
  status        text not null default 'available'
                check (status in ('available','hold','booked','agreement','possession')),
  notes         text,
  created_at    timestamptz not null default now()
);
create unique index on units (project_id, lower(code));

create table payment_plans (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id),
  company_id  uuid not null references companies(id),
  project_id  uuid not null references projects(id),
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create unique index on payment_plans (project_id, lower(name));

create table payment_plan_stages (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id),
  payment_plan_id  uuid not null references payment_plans(id),
  sort_order       integer not null,
  name             text not null,
  pct              numeric(5,2) not null check (pct > 0 and pct <= 100)
);
create index on payment_plan_stages (payment_plan_id);

create table bookings (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references tenants(id),
  company_id         uuid not null references companies(id),
  number             text not null,
  project_id         uuid not null references projects(id),
  unit_id            uuid not null references units(id),
  customer_party_id  uuid not null references parties(id),
  booking_date       date not null,
  agreement_value    numeric(14,2) not null check (agreement_value > 0),
  gst_pct            numeric(5,2) not null default 5 check (gst_pct between 0 and 28),
  payment_plan_id    uuid not null references payment_plans(id),
  status             text not null default 'booked' check (status in ('booked','agreement','possession','cancelled')),
  agreement_no       text,
  agreement_date     date,
  possession_date    date,
  notes              text,
  created_by         uuid not null references users(id),
  created_at         timestamptz not null default now(),
  cancelled_at       timestamptz,
  cancel_reason      text
);
create unique index on bookings (company_id, number);
create unique index on bookings (unit_id) where status <> 'cancelled';
create index on bookings (customer_party_id);

create table demands (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id),
  company_id     uuid not null references companies(id),
  number         text not null,
  booking_id     uuid not null references bookings(id),
  party_id       uuid not null references parties(id),
  demand_date    date not null,
  due_date       date not null,
  amount         numeric(14,2) not null check (amount > 0),
  cgst           numeric(14,2) not null default 0,
  sgst           numeric(14,2) not null default 0,
  total          numeric(14,2) not null,
  amount_paid    numeric(14,2) not null default 0,
  status         text not null default 'open' check (status in ('open','cancelled')),
  created_by     uuid not null references users(id),
  created_at     timestamptz not null default now(),
  cancelled_at   timestamptz,
  cancel_reason  text
);
create unique index on demands (company_id, number);
create index on demands (booking_id);
create index on demands (party_id);

-- The plan's stages are copied onto each booking, so later plan edits never change a booking.
create table booking_stages (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id),
  booking_id  uuid not null references bookings(id),
  sort_order  integer not null,
  name        text not null,
  pct         numeric(5,2) not null,
  amount      numeric(14,2) not null,
  demand_id   uuid references demands(id)
);
create index on booking_stages (booking_id);

-- Row-level security --------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['labour_advances','labour_advance_recoveries','work_orders','work_order_lines',
                           'contractor_advances','ra_bills','ra_bill_lines','retention_releases','units',
                           'payment_plans','payment_plan_stages','bookings','demands','booking_stages']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
end $$;

-- New permissions for the built-in roles of existing businesses ----------------------------

create function add_permissions(role_name text, extra text[]) returns void language sql as $$
  update roles set permissions = array(select distinct unnest(permissions || extra) order by 1)
  where is_system and name = role_name;
$$;

select add_permissions('Owner', array['subcontracts.view','subcontracts.manage','subcontracts.approve',
  'units.view','units.manage','bookings.view','bookings.manage','einvoice.manage']);
select add_permissions('Company Admin', array['subcontracts.view','subcontracts.manage','subcontracts.approve',
  'units.view','units.manage','bookings.view','bookings.manage','einvoice.manage']);
select add_permissions('Accountant', array['subcontracts.view','subcontracts.approve','units.view','bookings.view',
  'bookings.manage','einvoice.manage']);
select add_permissions('Sales Executive', array['units.view','bookings.view','bookings.manage']);
select add_permissions('Site Supervisor', array['subcontracts.view','subcontracts.manage']);
select add_permissions('Project Manager', array['subcontracts.view','subcontracts.manage','subcontracts.approve',
  'units.view']);
select add_permissions('Auditor', array['subcontracts.view','units.view','bookings.view']);

drop function add_permissions(text, text[]);
