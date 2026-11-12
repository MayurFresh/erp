-- v1.12 HR and payroll: employees, salary structures, leave, holidays, monthly attendance and payroll runs.
-- Site workers paid by the day stay in the labour tables. These tables are for salaried staff.

create table payroll_settings (
  company_id        uuid primary key references companies(id) on delete cascade,
  tenant_id         uuid not null references tenants(id) on delete cascade,
  lop_divisor       text not null default 'calendar' check (lop_divisor in ('calendar','30','26')),
  pf_enabled        boolean not null default true,
  esi_enabled       boolean not null default true,
  lwf_enabled       boolean not null default false,
  pt_enabled        boolean not null default true,
  pf_rate           numeric(5,2) not null default 12 check (pf_rate in (10, 12)),
  pf_code           text check (length(pf_code) <= 30),
  esi_code          text check (length(esi_code) <= 30),
  pt_registration   text check (length(pt_registration) <= 30),
  updated_at        timestamptz not null default now()
);

create table employees (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  company_id       uuid not null references companies(id),
  code             text not null check (length(code) between 1 and 30),
  user_id          uuid references users(id),
  name             text not null check (length(name) between 1 and 120),
  father_spouse_name text check (length(father_spouse_name) <= 120),
  dob              date,
  sex              text check (sex in ('M','F','O')),
  email            text check (length(email) <= 200),
  phone            text check (length(phone) <= 20),
  joining_date     date not null,
  leaving_date     date,
  department       text check (length(department) <= 80),
  designation      text check (length(designation) <= 80),
  location_id      uuid references locations(id),
  reporting_to     uuid references employees(id),
  pan              text check (pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  aadhaar_masked   text check (length(aadhaar_masked) <= 20),
  aadhaar_last4    text check (aadhaar_last4 ~ '^[0-9]{4}$'),
  uan              text check (uan ~ '^[0-9]{12}$'),
  esi_number       text check (length(esi_number) <= 20),
  bank_name        text check (length(bank_name) <= 80),
  bank_account     text check (length(bank_account) <= 30),
  bank_ifsc        text check (bank_ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  salary_mode      text not null default 'bank' check (salary_mode in ('bank','cash','cheque')),
  tax_regime       text not null default 'new' check (tax_regime in ('new','old')),
  pf_applicable    boolean not null default true,
  pf_higher_wage   boolean not null default false,
  esi_applicable   boolean not null default true,
  esi_covered_until date,
  pt_state_code    text check (pt_state_code ~ '^[0-9]{2}$'),
  previous_income  numeric(14,2) not null default 0 check (previous_income >= 0),
  previous_tds     numeric(14,2) not null default 0 check (previous_tds >= 0),
  status           text not null default 'active' check (status in ('active','inactive','left')),
  notes            text check (length(notes) <= 500),
  created_by       uuid references users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (company_id, code),
  check (leaving_date is null or leaving_date >= joining_date)
);
create unique index employees_user_unique on employees (company_id, user_id) where user_id is not null;
create index on employees (company_id, status);
create index on employees (location_id);

create table salary_components (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  code        text not null check (length(code) between 1 and 20),
  name        text not null check (length(name) between 1 and 60),
  kind        text not null check (kind in ('earning','deduction')),
  calc        text not null default 'fixed' check (calc in ('fixed','pct_basic','pct_gross')),
  percent     numeric(7,3) check (percent is null or (percent >= 0 and percent <= 1000)),
  is_basic    boolean not null default false,
  taxable     boolean not null default true,
  pf_wage     boolean not null default false,
  esi_wage    boolean not null default true,
  pro_rata    boolean not null default true,
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  updated_at  timestamptz not null default now(),
  unique (company_id, code)
);

-- One row per revision. History is kept: a new revision never changes an older one.
create table employee_salaries (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  employee_id    uuid not null references employees(id),
  effective_from date not null,
  ctc_annual     numeric(14,2) not null default 0 check (ctc_annual >= 0),
  note           text check (length(note) <= 300),
  created_by     uuid references users(id),
  created_at     timestamptz not null default now(),
  unique (employee_id, effective_from)
);
create table employee_salary_lines (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  salary_id     uuid not null references employee_salaries(id) on delete cascade,
  component_id  uuid not null references salary_components(id),
  amount        numeric(14,2) not null check (amount >= 0),
  unique (salary_id, component_id)
);

create table leave_types (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references tenants(id) on delete cascade,
  company_id          uuid not null references companies(id),
  code                text not null check (length(code) between 1 and 10),
  name                text not null check (length(name) between 1 and 60),
  is_paid             boolean not null default true,
  yearly_quota        numeric(6,2) not null default 0 check (yearly_quota >= 0),
  carry_forward_limit numeric(6,2) not null default 0 check (carry_forward_limit >= 0),
  is_active           boolean not null default true,
  updated_at          timestamptz not null default now(),
  unique (company_id, code)
);

-- Manual balance changes (opening balance, encashment, correction). `fy` is the start year of the April-March year.
create table leave_adjustments (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  employee_id   uuid not null references employees(id),
  leave_type_id uuid not null references leave_types(id),
  fy            int not null,
  days          numeric(6,2) not null,
  reason        text not null check (length(reason) between 2 and 200),
  created_by    uuid references users(id),
  created_at    timestamptz not null default now()
);

create table leave_applications (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  employee_id   uuid not null references employees(id),
  leave_type_id uuid not null references leave_types(id),
  from_date     date not null,
  to_date       date not null,
  half_day      boolean not null default false,
  days          numeric(6,2) not null check (days > 0),
  reason        text check (length(reason) <= 300),
  status        text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  decided_by    uuid references users(id),
  decided_at    timestamptz,
  decision_note text check (length(decision_note) <= 300),
  created_by    uuid references users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (to_date >= from_date)
);
create index on leave_applications (company_id, status);
create index on leave_applications (employee_id, from_date);

create table holidays (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  holiday_date date not null,
  name        text not null check (length(name) between 1 and 80),
  location_id uuid references locations(id),
  unique (company_id, holiday_date, location_id)
);

-- Month totals that feed payroll. `month` is the first day of the month.
create table attendance_summaries (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  employee_id    uuid not null references employees(id),
  month          date not null check (extract(day from month) = 1),
  present_days   numeric(5,2) not null default 0 check (present_days >= 0),
  paid_leave_days numeric(5,2) not null default 0 check (paid_leave_days >= 0),
  lop_days       numeric(5,2) not null default 0 check (lop_days >= 0),
  source         text not null default 'manual' check (source in ('manual','derived')),
  updated_by     uuid references users(id),
  updated_at     timestamptz not null default now(),
  unique (employee_id, month)
);

create table payroll_runs (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  number        text not null,
  month         date not null check (extract(day from month) = 1),
  location_id   uuid references locations(id),
  status        text not null default 'draft' check (status in ('draft','computed','approved','posted','cancelled')),
  gross         numeric(14,2) not null default 0,
  deductions    numeric(14,2) not null default 0,
  net           numeric(14,2) not null default 0,
  employer_cost numeric(14,2) not null default 0,
  employee_count int not null default 0,
  notes         text check (length(notes) <= 300),
  created_by    uuid references users(id),
  computed_by   uuid references users(id),
  computed_at   timestamptz,
  approved_by   uuid references users(id),
  approved_at   timestamptz,
  accrual_entry_id uuid references journal_entries(id),
  paid_by       uuid references users(id),
  paid_at       timestamptz,
  pay_date      date,
  payout_entry_id uuid references journal_entries(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on payroll_runs (company_id, month);
-- A month and location can have one live run. Cancelled runs do not count.
create unique index payroll_runs_one_live on payroll_runs (company_id, month, coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status <> 'cancelled';

create table payroll_lines (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  run_id         uuid not null references payroll_runs(id) on delete cascade,
  company_id     uuid not null references companies(id),
  employee_id    uuid not null references employees(id),
  month          date not null,
  is_live        boolean not null default true,
  working_days   numeric(5,2) not null,
  paid_days      numeric(5,2) not null,
  lop_days       numeric(5,2) not null default 0,
  earnings       jsonb not null default '[]',
  adjustments    jsonb not null default '[]',
  other_deductions jsonb not null default '[]',
  gross          numeric(14,2) not null default 0,
  taxable_gross  numeric(14,2) not null default 0,
  pf_wage        numeric(14,2) not null default 0,
  esi_wage       numeric(14,2) not null default 0,
  pf_employee    numeric(14,2) not null default 0,
  pf_eps         numeric(14,2) not null default 0,
  pf_epf_employer numeric(14,2) not null default 0,
  pf_edli        numeric(14,2) not null default 0,
  pf_admin       numeric(14,2) not null default 0,
  esi_employee   numeric(14,2) not null default 0,
  esi_employer   numeric(14,2) not null default 0,
  esi_covered_until date,
  pt             numeric(14,2) not null default 0,
  pt_state_code  text,
  lwf_employee   numeric(14,2) not null default 0,
  lwf_employer   numeric(14,2) not null default 0,
  tds            numeric(14,2) not null default 0,
  tds_working    jsonb,
  other_ded_total numeric(14,2) not null default 0,
  net            numeric(14,2) not null default 0,
  overrides      jsonb not null default '[]',
  warnings       jsonb not null default '[]',
  updated_at     timestamptz not null default now()
);
create index on payroll_lines (run_id);
create index on payroll_lines (employee_id, month);
-- An employee is in one live run per month.
create unique index payroll_lines_one_live on payroll_lines (employee_id, month) where is_live;

-- One-time additions or deductions (bonus, arrears, advance recovery) entered for a run. They survive a recompute.
create table payroll_adjustments (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  run_id      uuid not null references payroll_runs(id) on delete cascade,
  employee_id uuid not null references employees(id),
  kind        text not null check (kind in ('earning','deduction')),
  label       text not null check (length(label) between 1 and 80),
  amount      numeric(14,2) not null check (amount > 0),
  taxable     boolean not null default true,
  reason      text check (length(reason) <= 200),
  created_by  uuid references users(id),
  created_at  timestamptz not null default now()
);
create index on payroll_adjustments (run_id, employee_id);

-- A hand-set value for one figure of one employee in a run. The reason is required.
create table payroll_overrides (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  run_id      uuid not null references payroll_runs(id) on delete cascade,
  employee_id uuid not null references employees(id),
  field       text not null check (field in ('lop_days','pf_employee','esi_employee','pt','lwf_employee','tds')),
  value       numeric(14,2) not null check (value >= 0),
  reason      text not null check (length(reason) between 3 and 200),
  created_by  uuid references users(id),
  created_at  timestamptz not null default now(),
  unique (run_id, employee_id, field)
);

do $$
declare t text;
begin
  foreach t in array array['payroll_settings','employees','salary_components','employee_salaries','employee_salary_lines',
    'leave_types','leave_adjustments','leave_applications','holidays','attendance_summaries','payroll_runs','payroll_lines',
    'payroll_adjustments','payroll_overrides']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['payroll_settings','employees','salary_components','leave_types','leave_applications',
    'attendance_summaries','payroll_runs','payroll_lines']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

update roles set permissions = array(select distinct unnest(permissions ||
  array['payroll.view','payroll.employees','payroll.leave_approve','payroll.run','payroll.approve','payroll.self']) order by 1)
  where is_system and name in ('Owner','Company Admin');

update companies set enabled_modules = array_append(enabled_modules, 'payroll')
  where business_type not in ('freelancer') and enabled_modules is not null and not ('payroll' = any(enabled_modules))
    and plan <> 'solo';
