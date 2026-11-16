-- v1.15 finance reports and controls: cash-flow mapping, year-end close, budgets, cheques.

do $$
declare def text; kinds text[];
begin
  select pg_get_constraintdef(oid) into def from pg_constraint
    where conrelid = 'journal_entries'::regclass and conname = 'journal_entries_voucher_type_check';
  if def is not null and def not like '%''closing''%' then
    select coalesce(array_agg(distinct m[1]), '{}') into kinds from regexp_matches(def, '''([a-z_]+)''', 'g') as m;
    kinds := array(select distinct unnest(kinds || array['closing']) order by 1);
    alter table journal_entries drop constraint journal_entries_voucher_type_check;
    execute format('alter table journal_entries add constraint journal_entries_voucher_type_check check (voucher_type in (%s))',
                   (select string_agg(quote_literal(k), ',') from unnest(kinds) k));
  end if;
end $$;

create table cf_mappings (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  account_id  uuid not null references accounts(id) on delete cascade,
  category    text not null check (category in ('operating','investing','financing','noncash')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, account_id)
);

create table year_end_closes (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  company_id        uuid not null references companies(id) on delete cascade,
  fy                text not null check (fy ~ '^\d{4}-\d{2}$'),
  close_date        date not null,
  entry_id          uuid not null references journal_entries(id),
  profit            numeric(14,2) not null,
  equity_account_id uuid not null references accounts(id),
  previous_lock     date,
  status            text not null default 'closed' check (status in ('closed','reopened')),
  closed_by         uuid references users(id),
  closed_at         timestamptz not null default now(),
  reopened_at       timestamptz,
  reopened_by       uuid references users(id)
);
create unique index year_end_open_idx on year_end_closes (company_id, fy) where status = 'closed';

create table budgets (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id) on delete cascade,
  fy             text not null check (fy ~ '^\d{4}-\d{2}$'),
  account_id     uuid not null references accounts(id) on delete cascade,
  cost_centre_id uuid references cost_centres(id) on delete cascade,
  month          date not null check (extract(day from month) = 1),
  amount         numeric(14,2) not null check (amount >= 0),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index budgets_key_idx on budgets
  (company_id, fy, account_id, coalesce(cost_centre_id, '00000000-0000-0000-0000-000000000000'::uuid), month);

create table cheque_books (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  account_id  uuid not null references accounts(id),
  name        text check (length(name) <= 80),
  prefix      text not null default '' check (length(prefix) <= 10),
  from_no     bigint not null check (from_no >= 0),
  to_no       bigint not null,
  is_active   boolean not null default true,
  created_by  uuid references users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (to_no >= from_no and to_no - from_no < 500)
);
create index on cheque_books (company_id, account_id);

create table cheques (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id) on delete cascade,
  direction       text not null check (direction in ('received','issued')),
  bank_account_id uuid not null references accounts(id),
  book_id         uuid references cheque_books(id),
  cheque_no       text not null check (length(cheque_no) between 1 and 20),
  cheque_no_num   bigint,
  cheque_date     date not null,
  party_id        uuid not null references parties(id),
  amount          numeric(14,2) not null check (amount > 0),
  drawn_on        text check (length(drawn_on) <= 80),
  status          text not null default 'held' check (status in ('held','deposited','cleared','bounced','cancelled')),
  payment_id      uuid references payments(id),
  deposited_on    date,
  cleared_on      date,
  bounced_on      date,
  bounce_reason   text check (length(bounce_reason) <= 300),
  bounce_charges  numeric(12,2) not null default 0,
  bounce_entry_id uuid references journal_entries(id),
  notes           text check (length(notes) <= 500),
  created_by      uuid references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index on cheques (company_id, direction, status, cheque_date);
create index on cheques (book_id, cheque_no_num);
create unique index cheques_live_no_idx on cheques (company_id, bank_account_id, direction, cheque_no, party_id)
  where status <> 'cancelled';

create table cheque_layouts (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  account_id  uuid not null references accounts(id) on delete cascade,
  layout      jsonb not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, account_id)
);

do $$
declare t text;
begin
  foreach t in array array['cf_mappings','year_end_closes','budgets','cheque_books','cheques','cheque_layouts']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['cf_mappings','budgets','cheque_books','cheques','cheque_layouts']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

update roles set permissions = array(select distinct unnest(permissions ||
  array['finreports.view','finreports.manage','cheques.view','cheques.manage']) order by 1)
  where is_system and name in ('Owner','Company Admin','Accountant');
update roles set permissions = array(select distinct unnest(permissions || array['finreports.view','cheques.view']) order by 1)
  where is_system and name = 'Auditor';
