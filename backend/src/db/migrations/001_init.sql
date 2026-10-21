-- Progen ERP initial schema.
-- Every business table carries tenant_id and is protected by row-level security:
-- the app sets `app.tenant_id` at the start of each transaction and can only
-- see or write rows of that tenant.

create table tenants (
  id          uuid primary key,
  name        text not null,
  created_at  timestamptz not null default now()
);

create table companies (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id),
  name        text not null,
  legal_name  text,
  gstin       text,
  state_code  char(2) not null,
  pan         text,
  address     text,
  created_at  timestamptz not null default now()
);
create index on companies (tenant_id);

create table locations (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id),
  company_id  uuid not null references companies(id),
  parent_id   uuid references locations(id),
  type        text not null check (type in ('branch','site','warehouse','department','store','office')),
  name        text not null,
  code        text,
  state_code  char(2) not null,
  address     text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index on locations (company_id);

create table users (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id),
  name           text not null,
  email          text not null,
  phone          text,
  password_hash  text not null,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);
-- One login per email across the whole platform.
create unique index users_email_key on users (lower(email));
create index on users (tenant_id);

create table roles (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id),
  name         text not null,
  description  text,
  is_system    boolean not null default false,
  permissions  text[] not null default '{}',
  created_at   timestamptz not null default now(),
  unique (tenant_id, name)
);

-- A user's role in one company, optionally limited to some locations.
create table user_roles (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id),
  user_id       uuid not null references users(id) on delete cascade,
  role_id       uuid not null references roles(id),
  company_id    uuid not null references companies(id),
  location_ids  uuid[],            -- null = all locations of the company
  valid_from    date,
  valid_to      date,
  created_at    timestamptz not null default now()
);
create index on user_roles (user_id);

create table refresh_tokens (
  id          uuid primary key,    -- the token's jti
  tenant_id   uuid not null references tenants(id),
  user_id     uuid not null references users(id) on delete cascade,
  expires_at  timestamptz not null,
  revoked_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index on refresh_tokens (user_id);

create table items (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id),
  company_id      uuid not null references companies(id),
  name            text not null,
  sku             text,
  hsn_code        text,
  unit            text not null,
  gst_rate        numeric(5,2) not null check (gst_rate >= 0 and gst_rate <= 100),
  sale_price      numeric(14,2) not null default 0 check (sale_price >= 0),
  purchase_price  numeric(14,2) not null default 0 check (purchase_price >= 0),
  track_stock     boolean not null default true,
  reorder_level   numeric(14,3) not null default 0,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index items_sku_key on items (company_id, lower(sku)) where sku is not null;
create index on items (company_id);

create table parties (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id),
  company_id    uuid not null references companies(id),
  type          text not null check (type in ('customer','vendor','both')),
  name          text not null,
  gstin         text,
  state_code    char(2),
  phone         text,
  email         text,
  address       text,
  credit_limit  numeric(14,2) not null default 0,
  created_at    timestamptz not null default now()
);
create index on parties (company_id);

-- Append-only stock ledger: balance = sum(qty).
create table stock_moves (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id),
  company_id   uuid not null references companies(id),
  location_id  uuid not null references locations(id),
  item_id      uuid not null references items(id),
  qty          numeric(14,3) not null check (qty <> 0),
  rate         numeric(14,2),
  ref_type     text not null check (ref_type in ('opening','adjustment','invoice','invoice_cancel')),
  ref_id       uuid,
  note         text,
  created_by   uuid references users(id),
  created_at   timestamptz not null default now()
);
create index on stock_moves (company_id, location_id, item_id);

-- Gapless invoice numbering per company and financial year.
create table invoice_series (
  tenant_id   uuid not null references tenants(id),
  company_id  uuid not null references companies(id),
  fy          text not null,
  next_no     integer not null,
  primary key (company_id, fy)
);

create table invoices (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id),
  company_id       uuid not null references companies(id),
  location_id      uuid not null references locations(id),
  party_id         uuid not null references parties(id),
  number           text not null,
  fy               text not null,
  invoice_date     date not null,
  place_of_supply  char(2) not null,
  supply_type      text not null check (supply_type in ('intra','inter')),
  status           text not null default 'posted' check (status in ('posted','cancelled')),
  subtotal         numeric(14,2) not null,
  cgst             numeric(14,2) not null,
  sgst             numeric(14,2) not null,
  igst             numeric(14,2) not null,
  round_off        numeric(14,2) not null,
  total            numeric(14,2) not null,
  notes            text,
  created_by       uuid not null references users(id),
  created_at       timestamptz not null default now(),
  cancelled_at     timestamptz,
  cancel_reason    text,
  unique (company_id, number)
);
create index on invoices (company_id, invoice_date desc);

create table invoice_lines (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id),
  invoice_id     uuid not null references invoices(id) on delete cascade,
  line_no        integer not null,
  item_id        uuid not null references items(id),
  description    text not null,
  hsn_code       text,
  qty            numeric(14,3) not null,
  unit           text not null,
  rate           numeric(14,2) not null,
  discount_pct   numeric(5,2) not null default 0,
  taxable_value  numeric(14,2) not null,
  gst_rate       numeric(5,2) not null,
  cgst           numeric(14,2) not null,
  sgst           numeric(14,2) not null,
  igst           numeric(14,2) not null,
  line_total     numeric(14,2) not null
);
create index on invoice_lines (invoice_id);

-- Immutable audit trail.
create table audit_log (
  id          bigserial primary key,
  tenant_id   uuid not null references tenants(id),
  company_id  uuid,
  user_id     uuid,
  entity      text not null,
  entity_id   uuid,
  action      text not null,
  before      jsonb,
  after       jsonb,
  created_at  timestamptz not null default now()
);
create index on audit_log (tenant_id, entity, entity_id);

-- Row-level security ---------------------------------------------------------

create function app_tenant_id() returns uuid
  language sql stable
  as $$ select nullif(current_setting('app.tenant_id', true), '')::uuid $$;

alter table tenants enable row level security;
create policy tenant_isolation on tenants
  using (id = app_tenant_id()) with check (id = app_tenant_id());

do $$
declare t text;
begin
  foreach t in array array['companies','locations','users','roles','user_roles','refresh_tokens',
                           'items','parties','stock_moves','invoice_series','invoices',
                           'invoice_lines','audit_log']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
end $$;

-- The audit log can be added to but never changed.
create rule audit_log_no_update as on update to audit_log do instead nothing;
create rule audit_log_no_delete as on delete to audit_log do instead nothing;

-- Login happens before the tenant is known, so this one lookup bypasses RLS.
-- It runs with the owner's rights and returns only what login needs.
create function auth_find_user_by_email(p_email text)
  returns table (id uuid, tenant_id uuid, password_hash text, is_active boolean)
  language sql stable security definer
  set search_path = public
  as $$ select u.id, u.tenant_id, u.password_hash, u.is_active
        from users u where lower(u.email) = lower(p_email) $$;
