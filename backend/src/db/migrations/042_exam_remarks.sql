-- Report card extras: class teacher remarks and co-scholastic grades per student per exam term.
create table edu_co_areas (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  company_id uuid not null references companies(id),
  class_id   uuid not null references edu_classes(id),
  name       text not null check (length(name) between 1 and 80),
  seq        integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (class_id, name)
);
create table edu_term_remarks (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  company_id uuid not null references companies(id),
  term_id    uuid not null references edu_exam_terms(id) on delete cascade,
  student_id uuid not null references edu_students(id),
  remark     text not null check (length(remark) between 1 and 500),
  entered_by uuid not null references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (term_id, student_id)
);
create table edu_co_grades (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  company_id uuid not null references companies(id),
  term_id    uuid not null references edu_exam_terms(id) on delete cascade,
  student_id uuid not null references edu_students(id),
  area       text not null check (length(area) between 1 and 80),
  grade      text not null check (length(grade) between 1 and 10),
  entered_by uuid not null references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (term_id, student_id, area)
);
alter table edu_exam_settings add column co_grades jsonb;

do $$
declare t text;
begin
  foreach t in array array['edu_co_areas','edu_term_remarks','edu_co_grades']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;
