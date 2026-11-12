-- Wave 2: clinic and hospital OPD. Patients, doctors, appointments, consultations and prescriptions.
-- IPD (admissions, wards, beds) is not part of this migration.

create table clinic_patients (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  company_id       uuid not null references companies(id),
  party_id         uuid not null references parties(id),
  uhid             text not null,
  name             text not null check (length(name) between 1 and 200),
  sex              text not null check (sex in ('male','female','other')),
  dob              date,
  age_years        integer check (age_years between 0 and 130),
  phone            text not null check (length(phone) between 5 and 20),
  address          text check (length(address) <= 500),
  blood_group      text check (blood_group in ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
  allergies        text check (length(allergies) <= 500),
  emergency_name   text check (length(emergency_name) <= 100),
  emergency_phone  text check (length(emergency_phone) <= 20),
  notes            text check (length(notes) <= 2000),
  is_active        boolean not null default true,
  created_by       uuid not null references users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (company_id, uhid),
  unique (company_id, party_id),
  check (dob is not null or age_years is not null)
);
create index on clinic_patients (company_id, phone);
create index on clinic_patients (company_id, lower(name));

create table clinic_doctors (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  user_id         uuid references users(id),
  name            text not null check (length(name) between 1 and 120),
  speciality      text check (length(speciality) <= 100),
  registration_no text check (length(registration_no) <= 60),
  consult_fee     numeric(12,2) not null default 0 check (consult_fee >= 0),
  follow_up_fee   numeric(12,2) not null default 0 check (follow_up_fee >= 0),
  follow_up_days  integer not null default 7 check (follow_up_days between 0 and 365),
  slot_minutes    integer not null default 15 check (slot_minutes between 5 and 240),
  working_hours   jsonb not null default '[]',
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index on clinic_doctors (company_id, is_active);
create unique index clinic_doctors_user_uq on clinic_doctors (company_id, user_id) where user_id is not null;

create table clinic_appointments (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  patient_id    uuid not null references clinic_patients(id),
  doctor_id     uuid not null references clinic_doctors(id),
  appt_date     date not null,
  start_time    time,
  end_time      time,
  token_no      integer check (token_no > 0),
  kind          text not null default 'booked' check (kind in ('booked','walk_in')),
  status        text not null default 'booked' check (status in ('booked','arrived','in_consultation','done','cancelled','no_show')),
  reason        text check (length(reason) <= 300),
  cancel_reason text check (length(cancel_reason) <= 300),
  arrived_at    timestamptz,
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (kind = 'walk_in' or start_time is not null),
  check (start_time is null or end_time > start_time)
);
-- One live appointment per doctor, day and slot; a cancelled or no-show slot is free again.
create unique index clinic_appt_slot_uq on clinic_appointments (doctor_id, appt_date, start_time)
  where start_time is not null and status in ('booked','arrived','in_consultation','done');
create unique index clinic_appt_token_uq on clinic_appointments (doctor_id, appt_date, token_no) where token_no is not null;
create index on clinic_appointments (company_id, appt_date, doctor_id);
create index on clinic_appointments (patient_id);

create table clinic_visits (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  appointment_id uuid unique references clinic_appointments(id),
  patient_id     uuid not null references clinic_patients(id),
  doctor_id      uuid not null references clinic_doctors(id),
  visit_date     date not null,
  status         text not null default 'open' check (status in ('open','closed')),
  vitals         jsonb not null default '{}',
  complaints     text check (length(complaints) <= 2000),
  findings       text check (length(findings) <= 2000),
  diagnosis      text check (length(diagnosis) <= 1000),
  tests_advised  text check (length(tests_advised) <= 1000),
  advice         text check (length(advice) <= 2000),
  followup_date  date,
  fee_kind       text check (fee_kind in ('consultation','follow_up','none')),
  invoice_id     uuid references invoices(id),
  created_by     uuid not null references users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  closed_at      timestamptz
);
create index on clinic_visits (company_id, visit_date desc);
create index on clinic_visits (patient_id, visit_date desc);
create index on clinic_visits (doctor_id, visit_date desc);

create table clinic_rx_lines (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  visit_id     uuid not null references clinic_visits(id) on delete cascade,
  line_no      integer not null,
  item_id      uuid references items(id),
  medicine     text not null check (length(medicine) between 1 and 200),
  dose         text check (length(dose) <= 60),
  frequency    text check (length(frequency) <= 60),
  days         integer check (days between 1 and 3650),
  instructions text check (length(instructions) <= 200),
  unique (visit_id, line_no)
);

do $$
declare t text;
begin
  foreach t in array array['clinic_patients','clinic_doctors','clinic_appointments','clinic_visits','clinic_rx_lines']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['clinic_patients','clinic_doctors','clinic_appointments','clinic_visits']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

-- Owner and Company Admin of existing businesses get the new permissions.
update roles set permissions = array(select distinct unnest(permissions ||
  array['clinic.view','clinic.front_desk','clinic.consult','clinic.manage']) order by 1)
  where is_system and name in ('Owner','Company Admin');

-- Existing clinics, hospitals and labs with a custom module list get the module.
update companies set enabled_modules = array_append(enabled_modules, 'clinic')
  where business_type in ('clinic','hospital','diagnostic_lab') and enabled_modules is not null
    and not ('clinic' = any(enabled_modules));
