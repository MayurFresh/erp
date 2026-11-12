-- Daily attendance register. Saving a month's register rewrites that employee's month totals
-- (attendance_summaries, source 'register'), which payroll reads for loss-of-pay days.
create table attendance_days (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  employee_id uuid not null references employees(id),
  day         date not null,
  status      text not null check (status in ('present','absent','half_day','leave','holiday','week_off')),
  updated_by  uuid references users(id),
  updated_at  timestamptz not null default now(),
  unique (employee_id, day)
);
create index attendance_days_month_idx on attendance_days (company_id, day);
alter table attendance_days enable row level security;
create policy tenant_isolation on attendance_days using (tenant_id = app_tenant_id()) with check (tenant_id = app_tenant_id());
drop trigger if exists attendance_days_touch on attendance_days;
create trigger attendance_days_touch before update on attendance_days for each row execute function touch_updated_at();

alter table attendance_summaries drop constraint if exists attendance_summaries_source_check;
alter table attendance_summaries add constraint attendance_summaries_source_check check (source in ('manual','derived','register'));
