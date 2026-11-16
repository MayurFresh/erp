-- Statutory payroll: dated rate rows, Labour Code wages rule, bonus, leave encashment, full and final settlement, shifts and overtime.
-- No new permissions: settings use payroll.employees, runs use payroll.run, approval uses payroll.approve, reads use payroll.view.

-- Company rows that add to the built-in dated rates (EPF, ESI, PT per state, LWF per state). The row with the latest
-- effective_from on or before the pay month is in force; built-in rows are kept in code.
create table payroll_rate_rows (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  kind           text not null check (kind in ('epf','esi','pt','lwf')),
  state_code     text check (state_code ~ '^[0-9]{2}$'),
  effective_from date not null,
  config         jsonb not null,
  note           text check (length(note) <= 300),
  created_by     uuid references users(id),
  created_at     timestamptz not null default now(),
  check ((kind in ('pt','lwf')) = (state_code is not null))
);
create unique index payroll_rate_rows_unique on payroll_rate_rows (company_id, kind, coalesce(state_code, ''), effective_from);

create table payroll_statutory_settings (
  company_id              uuid primary key references companies(id),
  tenant_id               uuid not null references tenants(id) on delete cascade,
  wages_rule_enabled      boolean not null default false,
  wages_rule_from         date not null default '2025-11-21',
  wages_rule_percent      numeric(5,2) not null default 50 check (wages_rule_percent between 1 and 100),
  minimum_wage            numeric(12,2) not null default 0 check (minimum_wage >= 0),
  bonus_pct               numeric(5,2) not null default 8.33 check (bonus_pct between 8.33 and 20),
  bonus_eligibility_ceiling numeric(12,2) not null default 21000,
  bonus_calc_ceiling      numeric(12,2) not null default 7000,
  bonus_min_days          int not null default 30,
  gratuity_years          int not null default 5,
  gratuity_fixed_term_years int not null default 1,
  gratuity_cap            numeric(14,2) not null default 2000000,
  leave_exempt_cap        numeric(14,2) not null default 2500000,
  ot_multiplier           numeric(4,2) not null default 2 check (ot_multiplier >= 1),
  hours_per_day           numeric(4,2) not null default 8 check (hours_per_day > 0 and hours_per_day <= 24),
  updated_at              timestamptz not null default now()
);

create table employee_statutory (
  employee_id uuid primary key references employees(id) on delete cascade,
  tenant_id   uuid not null references tenants(id) on delete cascade,
  fixed_term  boolean not null default false
);

create table leave_type_encashment (
  leave_type_id uuid primary key references leave_types(id) on delete cascade,
  tenant_id     uuid not null references tenants(id) on delete cascade,
  encashable    boolean not null default false,
  max_days      numeric(6,2) not null default 0 check (max_days >= 0)
);

-- Extra figures for a payroll line (rebuilt with the line).
create table payroll_line_extras (
  line_id            uuid primary key references payroll_lines(id) on delete cascade,
  tenant_id          uuid not null references tenants(id) on delete cascade,
  wage_rule_addback  numeric(14,2) not null default 0,
  ot_hours           numeric(6,2) not null default 0,
  ot_pay             numeric(14,2) not null default 0
);

create table shifts (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  name          text not null check (length(name) between 1 and 60),
  start_time    time not null,
  end_time      time not null,
  break_minutes int not null default 0 check (break_minutes between 0 and 480),
  is_active     boolean not null default true,
  updated_at    timestamptz not null default now(),
  unique (company_id, name)
);

-- Shift worked and overtime hours for one employee on one day.
create table shift_logs (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  employee_id uuid not null references employees(id),
  day         date not null,
  shift_id    uuid references shifts(id),
  ot_hours    numeric(4,2) not null default 0 check (ot_hours >= 0 and ot_hours <= 24),
  updated_by  uuid references users(id),
  updated_at  timestamptz not null default now(),
  unique (employee_id, day)
);
create index on shift_logs (company_id, day);

-- One statutory bonus per employee per financial year (fy = start year).
create table bonus_payouts (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  employee_id uuid not null references employees(id),
  fy          int not null,
  pct         numeric(5,2) not null,
  amount      numeric(14,2) not null check (amount > 0),
  run_id      uuid references payroll_runs(id) on delete set null,
  created_by  uuid references users(id),
  created_at  timestamptz not null default now(),
  unique (employee_id, fy)
);

create table leave_encashments (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  employee_id   uuid not null references employees(id),
  leave_type_id uuid not null references leave_types(id),
  fy            int not null,
  days          numeric(6,2) not null check (days > 0),
  amount        numeric(14,2) not null check (amount > 0),
  kind          text not null default 'yearly' check (kind in ('yearly','exit')),
  run_id        uuid references payroll_runs(id) on delete set null,
  settlement_id uuid,
  created_by    uuid references users(id),
  created_at    timestamptz not null default now()
);
create index on leave_encashments (company_id, fy);

create table fnf_settlements (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  company_id        uuid not null references companies(id),
  number            text not null,
  employee_id       uuid not null references employees(id),
  exit_date         date not null,
  notice_required_days int not null default 0 check (notice_required_days >= 0),
  notice_served_days   int not null default 0 check (notice_served_days >= 0),
  notice_mode       text not null default 'none' check (notice_mode in ('none','recover','payout')),
  lop_days          numeric(5,2) not null default 0 check (lop_days >= 0),
  include_gratuity  boolean not null default true,
  include_leave     boolean not null default true,
  include_bonus     boolean not null default false,
  leave_exempt      boolean not null default false,
  extra_lines       jsonb not null default '[]',
  notes             text check (length(notes) <= 300),
  status            text not null default 'draft' check (status in ('draft','approved','paid','cancelled')),
  result            jsonb not null default '{}',
  gross             numeric(14,2) not null default 0,
  deductions        numeric(14,2) not null default 0,
  tds               numeric(14,2) not null default 0,
  net               numeric(14,2) not null default 0,
  created_by        uuid references users(id),
  approved_by       uuid references users(id),
  approved_at       timestamptz,
  accrual_entry_id  uuid references journal_entries(id),
  paid_at           timestamptz,
  pay_date          date,
  payout_entry_id   uuid references journal_entries(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create unique index fnf_one_live on fnf_settlements (employee_id) where status <> 'cancelled';
create index on fnf_settlements (company_id, status);

do $$
declare t text;
begin
  foreach t in array array['payroll_rate_rows','payroll_statutory_settings','employee_statutory','leave_type_encashment',
    'payroll_line_extras','shifts','shift_logs','bonus_payouts','leave_encashments','fnf_settlements']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['payroll_statutory_settings','shifts','shift_logs','fnf_settlements']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;
