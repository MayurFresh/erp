-- Wave 2: counter billing (POS). Sessions (shifts), cash moves, sales, returns and held bills.
-- Sales are normal invoices plus receipts; these tables link them to the register session.

create table pos_sessions (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  location_id    uuid not null references locations(id),
  user_id        uuid not null references users(id),
  status         text not null default 'open' check (status in ('open','closed')),
  opening_float  numeric(14,2) not null default 0 check (opening_float >= 0),
  opened_at      timestamptz not null default now(),
  closed_at      timestamptz,
  closed_by      uuid references users(id),
  expected       jsonb,
  counted        jsonb,
  difference     jsonb,
  notes          text check (length(notes) <= 500),
  updated_at     timestamptz not null default now()
);
create unique index pos_sessions_one_open on pos_sessions (company_id, location_id, user_id) where status = 'open';
create index on pos_sessions (company_id, status, opened_at desc);
create index on pos_sessions (location_id);

create table pos_cash_moves (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  session_id  uuid not null references pos_sessions(id) on delete cascade,
  kind        text not null check (kind in ('in','out')),
  amount      numeric(14,2) not null check (amount > 0),
  reason      text not null check (length(reason) between 2 and 200),
  created_by  uuid not null references users(id),
  created_at  timestamptz not null default now()
);
create index on pos_cash_moves (session_id);

create table pos_sales (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  session_id      uuid not null references pos_sessions(id),
  invoice_id      uuid not null unique references invoices(id),
  party_id        uuid not null references parties(id),
  total           numeric(14,2) not null,
  tax_total       numeric(14,2) not null default 0,
  discount_total  numeric(14,2) not null default 0,
  bill_discount   numeric(14,2) not null default 0,
  item_qty        numeric(14,3) not null default 0,
  tendered_cash   numeric(14,2) not null default 0,
  change_due      numeric(14,2) not null default 0,
  credit_amount   numeric(14,2) not null default 0,
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now()
);
create index on pos_sales (session_id);

-- Money taken per mode for a sale; cash is net of change given.
create table pos_payments (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  sale_id     uuid not null references pos_sales(id) on delete cascade,
  session_id  uuid not null references pos_sessions(id),
  mode        text not null check (mode in ('cash','upi','card','other')),
  amount      numeric(14,2) not null check (amount > 0),
  payment_id  uuid references payments(id),
  reference   text check (length(reference) <= 60)
);
create index on pos_payments (session_id);
create index on pos_payments (sale_id);

create table pos_returns (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  session_id     uuid not null references pos_sessions(id),
  sale_id        uuid not null references pos_sales(id),
  credit_note_id uuid not null references credit_notes(id),
  total          numeric(14,2) not null,
  refund_mode    text not null check (refund_mode in ('cash','upi','card','other')),
  refund_amount  numeric(14,2) not null check (refund_amount >= 0),
  reason         text not null,
  created_by     uuid not null references users(id),
  created_at     timestamptz not null default now()
);
create index on pos_returns (session_id);
create index on pos_returns (sale_id);

create table pos_held_bills (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  company_id   uuid not null references companies(id),
  location_id  uuid not null references locations(id),
  session_id   uuid not null references pos_sessions(id),
  label        text check (length(label) <= 60),
  payload      jsonb not null,
  total        numeric(14,2) not null default 0,
  created_by   uuid not null references users(id),
  created_at   timestamptz not null default now()
);
create index on pos_held_bills (company_id, location_id, created_at);

drop trigger if exists pos_sessions_touch on pos_sessions;
create trigger pos_sessions_touch before update on pos_sessions for each row execute function touch_updated_at();

do $$
declare t text;
begin
  foreach t in array array['pos_sessions','pos_cash_moves','pos_sales','pos_payments','pos_returns','pos_held_bills']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
end $$;

create function add_permissions(role_name text, extra text[]) returns void language sql as $$
  update roles set permissions = array(select distinct unnest(permissions || extra) order by 1)
  where is_system and name = role_name;
$$;
select add_permissions('Owner', array['pos.use','pos.manage']);
select add_permissions('Company Admin', array['pos.use','pos.manage']);
select add_permissions('Shop Owner', array['pos.use','pos.manage']);
select add_permissions('Pharmacy Owner', array['pos.use','pos.manage']);
select add_permissions('Manager', array['pos.use','pos.manage']);
select add_permissions('Sales Executive', array['pos.use']);
select add_permissions('Counter Staff', array['pos.use']);
select add_permissions('Sales Staff', array['pos.use']);
select add_permissions('Cashier', array['pos.use']);
select add_permissions('Pharmacist', array['pos.use']);
drop function add_permissions(text, text[]);
