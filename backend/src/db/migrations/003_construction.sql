-- Construction pack (phase 2a): projects and BOQ, material indents, material issued to work,
-- file uploads, daily progress reports, workers, attendance and wage sheets.

-- New voucher and stock move types --------------------------------------------

alter table journal_entries drop constraint journal_entries_voucher_type_check;
alter table journal_entries add constraint journal_entries_voucher_type_check check (voucher_type in
  ('sales','purchase','receipt','payment','credit_note','expense','stock','transfer','journal','issue','wages'));

alter table stock_moves drop constraint stock_moves_ref_type_check;
alter table stock_moves add constraint stock_moves_ref_type_check check (ref_type in (
  'opening','adjustment','invoice','invoice_cancel','purchase','purchase_cancel',
  'credit_note','credit_note_cancel','transfer_out','transfer_in','transfer_cancel','issue','issue_cancel'));

-- Projects and BOQ ---------------------------------------------------------------

create table projects (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id),
  company_id       uuid not null references companies(id),
  code             text not null,
  name             text not null,
  client_party_id  uuid references parties(id),
  manager_user_id  uuid references users(id),
  status           text not null default 'planning' check (status in ('planning','active','on_hold','completed')),
  start_date       date,
  end_date         date,
  contract_value   numeric(14,2) not null default 0 check (contract_value >= 0),
  address          text,
  created_by       uuid references users(id),
  created_at       timestamptz not null default now(),
  check (start_date is null or end_date is null or end_date >= start_date)
);
create unique index projects_code_key on projects (company_id, lower(code));

-- A site belongs to at most one project.
alter table locations add column project_id uuid references projects(id);
create index on locations (project_id) where project_id is not null;

create table boq_lines (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id),
  project_id       uuid not null references projects(id),
  code             text not null,
  description      text not null,
  unit             text not null,
  qty              numeric(14,3) not null check (qty > 0),
  rate             numeric(14,2) not null check (rate >= 0),
  amount           numeric(16,2) generated always as (round(qty * rate, 2)) stored,
  material_budget  numeric(14,2) not null default 0 check (material_budget >= 0),
  labour_budget    numeric(14,2) not null default 0 check (labour_budget >= 0),
  other_budget     numeric(14,2) not null default 0 check (other_budget >= 0),
  sort_order       integer not null default 0,
  created_at       timestamptz not null default now()
);
create unique index boq_lines_code_key on boq_lines (project_id, lower(code));
create index on boq_lines (project_id, sort_order);

-- Material indents -----------------------------------------------------------------

create table indents (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id),
  company_id     uuid not null references companies(id),
  number         text not null,
  location_id    uuid not null references locations(id),
  required_by    date,
  status         text not null default 'draft' check (status in ('draft','submitted','approved','rejected','closed')),
  notes          text,
  created_by     uuid not null references users(id),
  created_at     timestamptz not null default now(),
  submitted_at   timestamptz,
  approved_by    uuid references users(id),
  approved_at    timestamptz,
  rejected_by    uuid references users(id),
  rejected_at    timestamptz,
  reject_reason  text,
  closed_by      uuid references users(id),
  closed_at      timestamptz,
  unique (company_id, number)
);
create index on indents (company_id, created_at desc);
create index on indents (location_id);

create table indent_lines (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id),
  indent_id     uuid not null references indents(id),
  line_no       integer not null,
  item_id       uuid not null references items(id),
  qty           numeric(14,3) not null check (qty > 0),
  approved_qty  numeric(14,3) check (approved_qty >= 0),
  boq_line_id   uuid references boq_lines(id)
);
create index on indent_lines (indent_id);
create index on indent_lines (boq_line_id) where boq_line_id is not null;

-- How much of each indent line a received transfer or posted purchase delivered.
create table indent_fulfilments (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id),
  indent_line_id  uuid not null references indent_lines(id),
  source_type     text not null check (source_type in ('transfer','purchase')),
  source_id       uuid not null,
  qty             numeric(14,3) not null check (qty > 0),
  created_at      timestamptz not null default now()
);
create index on indent_fulfilments (indent_line_id);
create index on indent_fulfilments (source_id);

alter table transfers add column indent_id uuid references indents(id);
alter table purchases add column indent_id uuid references indents(id);

-- Material issued to work ------------------------------------------------------------

create table issues (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id),
  company_id     uuid not null references companies(id),
  number         text not null,
  issue_date     date not null,
  location_id    uuid not null references locations(id),
  boq_line_id    uuid references boq_lines(id),
  notes          text,
  status         text not null default 'posted' check (status in ('posted','cancelled')),
  created_by     uuid not null references users(id),
  created_at     timestamptz not null default now(),
  cancelled_at   timestamptz,
  cancel_reason  text,
  unique (company_id, number)
);
create index on issues (company_id, issue_date desc);
create index on issues (location_id);
create index on issues (boq_line_id) where boq_line_id is not null;

create table issue_lines (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id),
  issue_id   uuid not null references issues(id),
  line_no    integer not null,
  item_id    uuid not null references items(id),
  qty        numeric(14,3) not null check (qty > 0),
  cost_rate  numeric(14,4) not null,
  value      numeric(14,2) not null
);
create index on issue_lines (issue_id);

-- Uploaded files (bytes live on disk under UPLOAD_DIR/<tenant>/) ----------------------

create table files (
  id           uuid primary key,
  tenant_id    uuid not null references tenants(id),
  company_id   uuid references companies(id),
  name         text not null,
  mime_type    text not null check (mime_type in ('image/jpeg','image/png','image/webp','application/pdf')),
  size         integer not null check (size > 0),
  storage_key  text not null,
  created_by   uuid references users(id),
  created_at   timestamptz not null default now()
);

-- Daily progress reports --------------------------------------------------------------

create table dprs (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id),
  company_id    uuid not null references companies(id),
  location_id   uuid not null references locations(id),
  report_date   date not null,
  weather       text,
  status        text not null default 'draft' check (status in ('draft','submitted','approved')),
  summary       text,
  hindrances    text,
  labour        jsonb not null default '[]',
  equipment     jsonb not null default '[]',
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  submitted_at  timestamptz,
  approved_by   uuid references users(id),
  approved_at   timestamptz,
  unique (location_id, report_date)
);
create index on dprs (company_id, report_date desc);

create table dpr_work (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id),
  dpr_id       uuid not null references dprs(id),
  line_no      integer not null,
  boq_line_id  uuid references boq_lines(id),
  description  text not null,
  qty          numeric(14,3),
  unit         text
);
create index on dpr_work (dpr_id);
create index on dpr_work (boq_line_id) where boq_line_id is not null;

create table dpr_photos (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id),
  dpr_id     uuid not null references dprs(id),
  line_no    integer not null,
  file_id    uuid not null references files(id),
  caption    text
);
create index on dpr_photos (dpr_id);

-- Workers, attendance and wage sheets ---------------------------------------------------

create table workers (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references tenants(id),
  company_id           uuid not null references companies(id),
  name                 text not null,
  phone                text,
  trade                text not null check (trade in ('mason','carpenter','bar_bender','helper','electrician',
                                                      'plumber','painter','welder','operator','other')),
  skill                text not null default 'unskilled'
                       check (skill in ('unskilled','semi_skilled','skilled','highly_skilled')),
  daily_rate           numeric(14,2) not null check (daily_rate >= 0),
  contractor_party_id  uuid references parties(id),
  site_id              uuid references locations(id),
  aadhaar_last4        text check (aadhaar_last4 ~ '^[0-9]{4}$'),
  bocw_reg_no          text,
  photo_file_id        uuid references files(id),
  joined_on            date,
  is_active            boolean not null default true,
  created_at           timestamptz not null default now()
);
create index on workers (company_id, name);
create index on workers (site_id);

-- One mark per worker per day, at one site.
create table attendance (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id),
  company_id  uuid not null references companies(id),
  site_id     uuid not null references locations(id),
  worker_id   uuid not null references workers(id),
  att_date    date not null,
  status      text not null check (status in ('present','half_day','absent')),
  ot_hours    numeric(5,2) not null default 0 check (ot_hours >= 0 and ot_hours <= 24),
  marked_by   uuid references users(id),
  marked_at   timestamptz not null default now(),
  unique (worker_id, att_date)
);
create index on attendance (site_id, att_date);

create table wage_sheets (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references tenants(id),
  company_id            uuid not null references companies(id),
  number                text not null,
  site_id               uuid not null references locations(id),
  from_date             date not null,
  to_date               date not null,
  status                text not null default 'draft' check (status in ('draft','approved','paid','cancelled')),
  total_gross           numeric(14,2) not null default 0,
  total_deductions      numeric(14,2) not null default 0,
  total_net             numeric(14,2) not null default 0,
  approved_by           uuid references users(id),
  approved_at           timestamptz,
  paid_from_account_id  uuid references accounts(id),
  paid_date             date,
  paid_at               timestamptz,
  paid_by               uuid references users(id),
  created_by            uuid not null references users(id),
  created_at            timestamptz not null default now(),
  cancelled_at          timestamptz,
  cancel_reason         text,
  check (to_date >= from_date),
  unique (company_id, number)
);
create index on wage_sheets (site_id, from_date);

create table wage_sheet_rows (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id),
  wage_sheet_id  uuid not null references wage_sheets(id),
  worker_id      uuid not null references workers(id),
  daily_rate     numeric(14,2) not null,
  present_days   numeric(6,1) not null,
  ot_hours       numeric(8,2) not null,
  basic          numeric(14,2) not null,
  ot_amount      numeric(14,2) not null,
  gross          numeric(14,2) not null,
  advance        numeric(14,2) not null default 0 check (advance >= 0),
  net            numeric(14,2) not null,
  unique (wage_sheet_id, worker_id)
);

-- Row-level security for the new tables ------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['projects','boq_lines','indents','indent_lines','indent_fulfilments','issues',
                           'issue_lines','files','dprs','dpr_work','dpr_photos','workers','attendance',
                           'wage_sheets','wage_sheet_rows']
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

select add_permissions('Owner', array['projects.view','projects.manage','boq.manage','indents.view','indents.create',
  'indents.approve','consumption.view','consumption.create','dpr.view','dpr.create','dpr.approve','labour.view',
  'labour.manage','attendance.mark','wages.view','wages.manage','wages.pay']);
select add_permissions('Company Admin', array['projects.view','projects.manage','boq.manage','indents.view','indents.create',
  'indents.approve','consumption.view','consumption.create','dpr.view','dpr.create','dpr.approve','labour.view',
  'labour.manage','attendance.mark','wages.view','wages.manage','wages.pay']);
select add_permissions('Accountant', array['projects.view','consumption.view','wages.view','wages.pay']);
select add_permissions('Store Keeper', array['indents.view','consumption.view','consumption.create']);
select add_permissions('Site Supervisor', array['projects.view','indents.view','indents.create','consumption.view',
  'consumption.create','dpr.view','dpr.create','labour.view','attendance.mark','wages.view']);
select add_permissions('Auditor', array['projects.view','indents.view','consumption.view','dpr.view','labour.view','wages.view']);

drop function add_permissions(text, text[]);

-- The new built-in Project Manager role for every existing business.
insert into roles (tenant_id, name, description, is_system, permissions)
select t.id, 'Project Manager', 'Projects, BOQ, indent and DPR approval, labour and wage sheets', true,
  array['boq.manage','consumption.view','dashboard.view','dpr.approve','dpr.view','indents.approve','indents.view',
        'items.view','labour.manage','labour.view','locations.view','projects.view','purchases.view','reports.view',
        'stock.view','transfers.create','transfers.receive','transfers.view','wages.manage','wages.view']
from tenants t
on conflict (tenant_id, name) do nothing;
