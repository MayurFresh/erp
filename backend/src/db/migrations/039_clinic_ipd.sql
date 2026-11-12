-- Wave 2: clinic in-patient care. Wards, beds, admissions, bed stays, charges and deposits.

create table clinic_wards (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  name        text not null check (length(name) between 1 and 100),
  kind        text not null default 'general' check (kind in ('general','semi_private','private','icu','nicu','other')),
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index clinic_wards_name_uq on clinic_wards (company_id, lower(name));

create table clinic_beds (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  ward_id     uuid not null references clinic_wards(id),
  bed_no      text not null check (length(bed_no) between 1 and 30),
  daily_rate  numeric(12,2) not null default 0 check (daily_rate >= 0),
  status      text not null default 'available' check (status in ('available','occupied','cleaning','maintenance')),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index clinic_beds_no_uq on clinic_beds (ward_id, lower(bed_no));

create table clinic_admissions (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references tenants(id) on delete cascade,
  company_id            uuid not null references companies(id),
  admission_no          text not null,
  patient_id            uuid not null references clinic_patients(id),
  doctor_id             uuid not null references clinic_doctors(id),
  bed_id                uuid references clinic_beds(id),
  status                text not null default 'admitted' check (status in ('admitted','discharged')),
  admit_date            date not null,
  admitted_at           timestamptz not null default now(),
  expected_days         integer check (expected_days between 1 and 365),
  provisional_diagnosis text check (length(provisional_diagnosis) <= 1000),
  discharge_date        date,
  discharged_at         timestamptz,
  diagnosis             text check (length(diagnosis) <= 1000),
  treatment             text check (length(treatment) <= 4000),
  advice                text check (length(advice) <= 2000),
  condition             text check (length(condition) <= 200),
  followup_date         date,
  invoice_id            uuid references invoices(id),
  created_by            uuid not null references users(id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (company_id, admission_no)
);
create unique index clinic_adm_bed_uq on clinic_admissions (bed_id) where status = 'admitted';
create unique index clinic_adm_patient_uq on clinic_admissions (patient_id) where status = 'admitted';
create index on clinic_admissions (company_id, status, admit_date desc);
create index on clinic_admissions (patient_id);

create table clinic_bed_stays (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  admission_id  uuid not null references clinic_admissions(id) on delete cascade,
  bed_id        uuid not null references clinic_beds(id),
  from_date     date not null,
  to_date       date,
  daily_rate    numeric(12,2) not null check (daily_rate >= 0),
  reason        text check (length(reason) <= 300),
  created_at    timestamptz not null default now()
);
create index on clinic_bed_stays (admission_id, from_date);

create table clinic_ipd_charges (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  admission_id  uuid not null references clinic_admissions(id) on delete cascade,
  charge_date   date not null,
  kind          text not null check (kind in ('bed','service','medicine')),
  item_id       uuid references items(id),
  description   text not null check (length(description) between 1 and 300),
  qty           numeric(12,3) not null check (qty > 0),
  rate          numeric(12,2) not null check (rate >= 0),
  amount        numeric(14,2) not null,
  bed_stay_id   uuid references clinic_bed_stays(id) on delete cascade,
  is_void       boolean not null default false,
  void_reason   text check (length(void_reason) <= 300),
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now()
);
create index on clinic_ipd_charges (admission_id, charge_date);
create unique index clinic_ipd_bed_day_uq on clinic_ipd_charges (bed_stay_id, charge_date) where kind = 'bed' and not is_void;

create table clinic_ipd_deposits (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  admission_id  uuid not null references clinic_admissions(id) on delete cascade,
  payment_id    uuid not null references payments(id),
  amount        numeric(14,2) not null check (amount > 0),
  created_at    timestamptz not null default now()
);
create index on clinic_ipd_deposits (admission_id);

do $$
declare t text;
begin
  foreach t in array array['clinic_wards','clinic_beds','clinic_admissions','clinic_bed_stays','clinic_ipd_charges','clinic_ipd_deposits']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['clinic_wards','clinic_beds','clinic_admissions']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

-- Owner and Company Admin get both permissions.
update roles set permissions = array(select distinct unnest(permissions || array['clinic.ipd','clinic.ipd_manage']) order by 1)
  where is_system and name in ('Owner','Company Admin');

-- Hospital and clinic tenants: staff roles get IPD access. Scoped to those tenants.
update roles r set permissions = array(select distinct unnest(r.permissions ||
    case when r.name in ('Front Desk','Billing') then array['clinic.ipd','clinic.ipd_manage'] else array['clinic.ipd'] end) order by 1)
  where r.name in ('Administrator','Doctor','Nurse','Front Desk','Billing')
    and exists (select 1 from companies c where c.tenant_id = r.tenant_id and c.business_type in ('clinic','hospital'));
update roles r set permissions = array(select distinct unnest(r.permissions || array['clinic.ipd_manage']) order by 1)
  where r.name = 'Administrator'
    and exists (select 1 from companies c where c.tenant_id = r.tenant_id and c.business_type in ('clinic','hospital'));
