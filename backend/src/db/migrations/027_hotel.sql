-- Wave 2: hotel and guest house front office. Rooms, rate plans, reservations, stays and folios.
-- Billing goes through the existing invoice and payment services; nothing here writes ledger rows.

create extension if not exists btree_gist;

create table hotel_settings (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references tenants(id) on delete cascade,
  company_id         uuid not null references companies(id),
  prices_include_tax boolean not null default false,
  check_in_time      text not null default '14:00' check (check_in_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  check_out_time     text not null default '11:00' check (check_out_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (company_id)
);

create table hotel_room_types (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references tenants(id) on delete cascade,
  company_id          uuid not null references companies(id),
  name                text not null check (length(name) between 1 and 80),
  base_occupancy      integer not null default 2 check (base_occupancy between 1 and 20),
  max_occupancy       integer not null default 3 check (max_occupancy between 1 and 20),
  base_tariff         numeric(12,2) not null default 0 check (base_tariff >= 0),
  extra_person_charge numeric(12,2) not null default 0 check (extra_person_charge >= 0),
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (max_occupancy >= base_occupancy)
);
create unique index hotel_room_types_name_uq on hotel_room_types (company_id, lower(name));

create table hotel_rooms (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  room_type_id   uuid not null references hotel_room_types(id),
  number         text not null check (length(number) between 1 and 20),
  floor          text check (length(floor) <= 20),
  status         text not null default 'clean' check (status in ('clean','dirty','inspected','out_of_order')),
  status_reason  text check (length(status_reason) <= 200),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (company_id, number)
);
create index on hotel_rooms (company_id, room_type_id);

create table hotel_rate_plans (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  room_type_id   uuid not null references hotel_room_types(id),
  name           text not null check (length(name) between 1 and 80),
  meal           text not null default 'room_only' check (meal in ('room_only','breakfast')),
  weekday_tariff numeric(12,2) not null check (weekday_tariff >= 0),
  weekend_tariff numeric(12,2) not null check (weekend_tariff >= 0),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on hotel_rate_plans (company_id, room_type_id);

create table hotel_reservations (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  number          text not null,
  party_id        uuid not null references parties(id),
  arrival         date not null,
  departure       date not null,
  override_tariff numeric(12,2) check (override_tariff >= 0),
  source          text not null default 'walk_in' check (source in ('walk_in','phone','ota','agent')),
  source_name     text check (length(source_name) <= 100),
  status          text not null default 'confirmed'
                  check (status in ('tentative','confirmed','checked_in','checked_out','cancelled','no_show')),
  notes           text check (length(notes) <= 1000),
  cancel_reason   text check (length(cancel_reason) <= 300),
  checked_in_at   timestamptz,
  checked_out_at  timestamptz,
  invoice_id      uuid references invoices(id),
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, number),
  check (departure > arrival)
);
create index on hotel_reservations (company_id, status, arrival);
create index on hotel_reservations (company_id, departure);
create index on hotel_reservations (party_id);

create table hotel_reservation_rooms (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  reservation_id uuid not null references hotel_reservations(id) on delete cascade,
  room_type_id  uuid not null references hotel_room_types(id),
  room_id       uuid references hotel_rooms(id),
  rate_plan_id  uuid references hotel_rate_plans(id),
  arrival       date not null,
  departure     date not null,
  adults        integer not null default 1 check (adults between 1 and 20),
  children      integer not null default 0 check (children between 0 and 20),
  -- Live while the booking holds the room: tentative, confirmed or checked in.
  live          boolean not null default true,
  guest_name    text check (length(guest_name) <= 200),
  guest_phone   text check (length(guest_phone) <= 20),
  guest_address text check (length(guest_address) <= 500),
  id_type       text check (id_type in ('aadhaar','passport','driving_licence','voter_id','pan','other')),
  id_number     text check (length(id_number) <= 60),
  nationality   text check (length(nationality) <= 60),
  passport_no   text check (length(passport_no) <= 40),
  visa_no       text check (length(visa_no) <= 40),
  visa_type     text check (length(visa_type) <= 40),
  visa_expiry   date,
  arrived_from  text check (length(arrived_from) <= 120),
  going_to      text check (length(going_to) <= 120),
  purpose       text check (length(purpose) <= 120),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (departure > arrival),
  -- A specific room cannot be held by two live bookings on overlapping nights.
  constraint hotel_room_overlap exclude using gist (room_id with =, daterange(arrival, departure) with &&)
    where (room_id is not null and live)
);
create index on hotel_reservation_rooms (reservation_id);
create index on hotel_reservation_rooms (company_id, room_type_id, arrival, departure) where live;

create table hotel_folio_lines (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references tenants(id) on delete cascade,
  company_id          uuid not null references companies(id),
  reservation_id      uuid not null references hotel_reservations(id) on delete cascade,
  reservation_room_id uuid references hotel_reservation_rooms(id),
  line_date           date not null,
  kind                text not null check (kind in ('room','extra','discount')),
  charge_type         text not null check (charge_type in ('room','food','laundry','minibar','extra_bed','other','discount')),
  description         text not null check (length(description) between 1 and 300),
  item_id             uuid references items(id),
  qty                 numeric(10,3) not null default 1 check (qty > 0),
  rate                numeric(12,2) not null check (rate >= 0),
  amount              numeric(12,2) not null check (amount >= 0),
  gst_rate            numeric(5,2) not null default 0 check (gst_rate between 0 and 100),
  source              text not null default 'front_office' check (length(source) <= 30),
  source_ref          text check (length(source_ref) <= 80),
  voided              boolean not null default false,
  void_reason         text check (length(void_reason) <= 200),
  created_by          uuid not null references users(id),
  created_at          timestamptz not null default now()
);
create index on hotel_folio_lines (reservation_id, line_date);
-- One room charge per room per night, which makes posting night charges safe to repeat.
create unique index hotel_folio_night_uq on hotel_folio_lines (reservation_room_id, line_date) where kind = 'room';
create unique index hotel_folio_source_uq on hotel_folio_lines (company_id, source, source_ref) where source_ref is not null;

create table hotel_folio_payments (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  reservation_id uuid not null references hotel_reservations(id) on delete cascade,
  payment_id     uuid not null references payments(id),
  kind           text not null check (kind in ('advance','payment')),
  amount         numeric(12,2) not null check (amount > 0),
  created_at     timestamptz not null default now(),
  unique (payment_id)
);
create index on hotel_folio_payments (reservation_id);

do $$
declare t text;
begin
  foreach t in array array['hotel_settings','hotel_room_types','hotel_rooms','hotel_rate_plans','hotel_reservations',
                           'hotel_reservation_rooms','hotel_folio_lines','hotel_folio_payments']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['hotel_settings','hotel_room_types','hotel_rooms','hotel_rate_plans','hotel_reservations','hotel_reservation_rooms']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

update roles set permissions = array(select distinct unnest(permissions ||
  array['hotel.view','hotel.front_office','hotel.housekeeping','hotel.manage']) order by 1)
  where is_system and name in ('Owner','Company Admin');

update companies set enabled_modules = array_append(enabled_modules, 'hotel')
  where business_type = 'hotel' and enabled_modules is not null and not ('hotel' = any(enabled_modules));
