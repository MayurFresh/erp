-- Wave 2: school and coaching administration. Years, classes or batches, students, fee plans, demands and attendance.
-- Fee bills are normal invoices and fee receipts are normal payments; these tables only link them to students.

create table edu_years (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  name        text not null check (length(name) between 1 and 40),
  start_date  date not null,
  end_date    date not null,
  is_current  boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (end_date > start_date),
  unique (company_id, name)
);
create unique index edu_years_current_uq on edu_years (company_id) where is_current;

create table edu_classes (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  year_id         uuid not null references edu_years(id),
  kind            text not null default 'class' check (kind in ('class','batch')),
  name            text not null check (length(name) between 1 and 80),
  section         text check (length(section) <= 20),
  course          text check (length(course) <= 100),
  timing          text check (length(timing) <= 100),
  teacher_user_id uuid references users(id),
  teacher_name    text check (length(teacher_name) <= 100),
  capacity        integer check (capacity between 1 and 2000),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index edu_classes_name_uq on edu_classes (company_id, year_id, lower(name), coalesce(lower(section), ''));
create index on edu_classes (company_id, year_id);

create table edu_students (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  company_id        uuid not null references companies(id),
  party_id          uuid not null references parties(id),
  admission_no      text not null,
  name              text not null check (length(name) between 1 and 200),
  class_id          uuid references edu_classes(id),
  roll_no           text check (length(roll_no) <= 20),
  dob               date,
  sex               text not null check (sex in ('male','female','other')),
  guardian_name     text not null check (length(guardian_name) between 1 and 200),
  guardian_relation text check (length(guardian_relation) <= 40),
  guardian_phone    text not null check (length(guardian_phone) between 5 and 20),
  address           text check (length(address) <= 500),
  admission_date    date not null,
  status            text not null default 'active' check (status in ('active','left','passed_out')),
  left_date         date,
  notes             text check (length(notes) <= 2000),
  created_by        uuid not null references users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (company_id, admission_no),
  unique (company_id, party_id)
);
create index on edu_students (company_id, class_id, status);
create index on edu_students (company_id, guardian_phone);
create index on edu_students (company_id, lower(name));

create table edu_fee_heads (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  item_id     uuid not null references items(id),
  name        text not null check (length(name) between 1 and 80),
  gst_rate    numeric(5,2) not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index edu_fee_heads_name_uq on edu_fee_heads (company_id, lower(name));

create table edu_fee_plans (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  company_id       uuid not null references companies(id),
  class_id         uuid not null references edu_classes(id),
  name             text not null check (length(name) between 1 and 80),
  late_kind        text not null default 'none' check (late_kind in ('none','flat','percent','per_day')),
  late_value       numeric(12,2) not null default 0 check (late_value >= 0),
  late_head_id     uuid references edu_fee_heads(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (class_id),
  check (late_kind = 'none' or late_head_id is not null)
);

create table edu_instalments (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  plan_id    uuid not null references edu_fee_plans(id) on delete cascade,
  seq        integer not null check (seq > 0),
  label      text not null check (length(label) between 1 and 60),
  due_date   date not null,
  lines      jsonb not null default '[]',
  unique (plan_id, seq)
);

create table edu_concessions (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  student_id  uuid not null references edu_students(id),
  head_id     uuid not null references edu_fee_heads(id),
  kind        text not null check (kind in ('percent','amount')),
  value       numeric(12,2) not null check (value > 0),
  reason      text not null check (length(reason) between 1 and 200),
  is_active   boolean not null default true,
  created_by  uuid not null references users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (kind <> 'percent' or value <= 100)
);
create unique index edu_concessions_uq on edu_concessions (student_id, head_id) where is_active;

create table edu_demands (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  student_id    uuid not null references edu_students(id),
  instalment_id uuid not null references edu_instalments(id),
  invoice_id    uuid not null references invoices(id),
  late_fee      numeric(12,2) not null default 0,
  status        text not null default 'billed' check (status in ('billed','void')),
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now()
);
-- One live demand per student and instalment; a cancelled invoice voids its demand so it can be raised again.
create unique index edu_demands_live_uq on edu_demands (student_id, instalment_id) where status = 'billed';
create index on edu_demands (company_id, student_id);

create table edu_attendance (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  company_id uuid not null references companies(id),
  student_id uuid not null references edu_students(id),
  class_id   uuid not null references edu_classes(id),
  att_date   date not null,
  status     text not null check (status in ('present','absent','late')),
  marked_by  uuid not null references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id, att_date)
);
create index on edu_attendance (class_id, att_date);

do $$
declare t text;
begin
  foreach t in array array['edu_years','edu_classes','edu_students','edu_fee_heads','edu_fee_plans','edu_instalments',
                           'edu_concessions','edu_demands','edu_attendance']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['edu_years','edu_classes','edu_students','edu_fee_heads','edu_fee_plans','edu_concessions','edu_attendance']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

update roles set permissions = array(select distinct unnest(permissions ||
  array['education.view','education.admissions','education.fees','education.attendance','education.manage']) order by 1)
  where is_system and name in ('Owner','Company Admin');

update companies set enabled_modules = array_append(enabled_modules, 'education')
  where business_type in ('school','coaching') and enabled_modules is not null
    and not ('education' = any(enabled_modules));

-- The built-in Accountant role of schools and coaching institutes sees students and collects fees.
update roles set permissions = array(select distinct unnest(permissions || array['education.view','education.fees']) order by 1)
  where is_system and name = 'Accountant'
    and tenant_id in (select tenant_id from companies where business_type in ('school', 'coaching'));
