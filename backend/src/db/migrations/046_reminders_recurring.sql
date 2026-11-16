-- Automatic payment reminders, company interest rate for statements, and recurring invoices.

alter table parties add column no_reminders boolean not null default false;

create table receivable_settings (
  company_id          uuid primary key references companies(id) on delete cascade,
  tenant_id           uuid not null references tenants(id) on delete cascade,
  reminders_enabled   boolean not null default false,
  days_before         integer check (days_before between 1 and 30),
  on_due_date         boolean not null default true,
  repeat_every_days   integer not null default 7 check (repeat_every_days between 1 and 90),
  max_repeats         integer not null default 3 check (max_repeats between 0 and 12),
  channels            text[] not null default '{email,whatsapp}' check (channels <@ array['email','whatsapp']),
  overdue_interest_pct numeric(5,2) not null default 0 check (overdue_interest_pct between 0 and 60),
  updated_at          timestamptz not null default now()
);

-- One row per invoice and step. The unique key is what keeps a reminder from going out twice.
create table reminder_log (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  party_id    uuid not null references parties(id),
  invoice_id  uuid not null references invoices(id),
  step        text not null check (step ~ '^(before|due|after_[0-9]{1,2})$'),
  step_date   date not null,
  run_date    date not null,
  channels    text[] not null default '{}',
  outbox_ids  uuid[] not null default '{}',
  amount      numeric(14,2) not null default 0,
  status      text not null check (status in ('queued','skipped')),
  note        text check (length(note) <= 200),
  created_at  timestamptz not null default now(),
  unique (invoice_id, step)
);
create index on reminder_log (company_id, created_at desc);
create index on reminder_log (company_id, party_id, run_date);

create table recurring_invoices (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  company_id    uuid not null references companies(id),
  name          text not null check (length(name) between 1 and 120),
  party_id      uuid not null references parties(id),
  location_id   uuid not null references locations(id),
  lines         jsonb not null,
  frequency     text not null check (frequency in ('weekly','monthly','quarterly','half_yearly','yearly')),
  start_date    date not null,
  end_date      date,
  max_runs      integer check (max_runs between 1 and 1000),
  day_of_month  integer check (day_of_month between 1 and 31),
  status        text not null default 'active' check (status in ('active','paused','ended')),
  slot_no       integer not null default 0,
  next_date     date,
  runs_done     integer not null default 0,
  auto_send     boolean not null default false,
  send_channels text[] not null default '{email}' check (send_channels <@ array['email','whatsapp']),
  notes         text check (length(notes) <= 1000),
  last_error    text check (length(last_error) <= 500),
  last_run_at   timestamptz,
  created_by    uuid not null references users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (end_date is null or end_date >= start_date)
);
create index on recurring_invoices (company_id, status, next_date);
create index on recurring_invoices (company_id, party_id);

-- One invoice per template per period; the unique key makes runs safe to repeat.
create table recurring_invoice_runs (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id),
  template_id uuid not null references recurring_invoices(id) on delete cascade,
  period      date not null,
  invoice_id  uuid not null references invoices(id),
  created_at  timestamptz not null default now(),
  unique (template_id, period)
);
create index on recurring_invoice_runs (company_id, template_id);

do $$
declare t text;
begin
  foreach t in array array['receivable_settings','reminder_log','recurring_invoices','recurring_invoice_runs']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['receivable_settings','recurring_invoices']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;
