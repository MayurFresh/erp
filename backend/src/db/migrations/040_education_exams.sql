-- Education exams: subjects per class, exam terms, papers (max marks per subject), marks and the grading scale.
-- A term is published as a whole; after that its marks cannot change until it is reopened by someone who manages exams.

create table edu_subjects (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  company_id uuid not null references companies(id),
  class_id   uuid not null references edu_classes(id),
  name       text not null check (length(name) between 1 and 80),
  code       text check (length(code) <= 20),
  seq        integer not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index edu_subjects_name_uq on edu_subjects (class_id, lower(name));

create table edu_exam_terms (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  company_id   uuid not null references companies(id),
  year_id      uuid not null references edu_years(id),
  name         text not null check (length(name) between 1 and 80),
  seq          integer not null default 0,
  start_date   date,
  end_date     date,
  status       text not null default 'draft' check (status in ('draft','published')),
  published_at timestamptz,
  published_by uuid references users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index edu_exam_terms_name_uq on edu_exam_terms (company_id, year_id, lower(name));

create table edu_exam_papers (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  company_id uuid not null references companies(id),
  term_id    uuid not null references edu_exam_terms(id) on delete cascade,
  class_id   uuid not null references edu_classes(id),
  subject_id uuid not null references edu_subjects(id),
  max_marks  numeric(7,2) not null check (max_marks > 0),
  pass_marks numeric(7,2) check (pass_marks >= 0),
  exam_date  date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (term_id, subject_id),
  check (pass_marks is null or pass_marks <= max_marks)
);
create index on edu_exam_papers (term_id, class_id);

create table edu_marks (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  company_id uuid not null references companies(id),
  paper_id   uuid not null references edu_exam_papers(id) on delete cascade,
  student_id uuid not null references edu_students(id),
  marks      numeric(7,2) check (marks >= 0),
  absent     boolean not null default false,
  entered_by uuid not null references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (paper_id, student_id),
  check (not absent or marks is null),
  check (absent or marks is not null)
);
create index on edu_marks (student_id);

-- One row per company; no row means the default CBSE-style scale.
create table edu_exam_settings (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  company_id   uuid not null references companies(id) unique,
  grades       jsonb not null,
  pass_percent numeric(5,2) not null default 33 check (pass_percent between 0 and 100),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['edu_subjects','edu_exam_terms','edu_exam_papers','edu_marks','edu_exam_settings']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

update roles set permissions = array(select distinct unnest(permissions || array['education.exams','education.exams_manage']) order by 1)
  where is_system and name in ('Owner','Company Admin');

-- Schools and coaching institutes: heads manage exams, teachers enter marks.
update roles set permissions = array(select distinct unnest(permissions || array['education.exams','education.exams_manage']) order by 1)
  where name in ('Principal','Centre Manager')
    and tenant_id in (select tenant_id from companies where business_type in ('school','coaching'));
update roles set permissions = array(select distinct unnest(permissions || array['education.exams']) order by 1)
  where name = 'Teacher'
    and tenant_id in (select tenant_id from companies where business_type in ('school','coaching'));
