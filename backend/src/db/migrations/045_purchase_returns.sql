-- v1.14 purchase returns and debit notes, and the customer credit-limit override permission.

-- New stock move kinds and voucher type, added to whatever the checks hold now.
do $$
declare def text; kinds text[];
begin
  select pg_get_constraintdef(oid) into def from pg_constraint
    where conname = 'stock_moves_ref_type_check' and conrelid = 'stock_moves'::regclass;
  select coalesce(array_agg(distinct m[1]), '{}') into kinds from regexp_matches(coalesce(def, ''), '''([a-z_]+)''', 'g') as m;
  kinds := array(select distinct unnest(kinds || array['purchase_return','purchase_return_cancel']) order by 1);
  alter table stock_moves drop constraint if exists stock_moves_ref_type_check;
  execute format('alter table stock_moves add constraint stock_moves_ref_type_check check (ref_type in (%s))',
                 (select string_agg(quote_literal(k), ',') from unnest(kinds) k));

  select pg_get_constraintdef(oid) into def from pg_constraint
    where conrelid = 'journal_entries'::regclass and conname = 'journal_entries_voucher_type_check';
  if def is not null and def not like '%''debit_note''%' then
    select coalesce(array_agg(distinct m[1]), '{}') into kinds from regexp_matches(def, '''([a-z_]+)''', 'g') as m;
    kinds := array(select distinct unnest(kinds || array['debit_note']) order by 1);
    alter table journal_entries drop constraint journal_entries_voucher_type_check;
    execute format('alter table journal_entries add constraint journal_entries_voucher_type_check check (voucher_type in (%s))',
                   (select string_agg(quote_literal(k), ',') from unnest(kinds) k));
  end if;
end $$;

-- What each bill line has already given back (set by posted returns).
alter table purchase_lines
  add column returned_qty     numeric(14,3) not null default 0 check (returned_qty >= 0),
  add column returned_taxable numeric(14,2) not null default 0 check (returned_taxable >= 0);

create table purchase_returns (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id) on delete cascade,
  purchase_id     uuid not null references purchases(id),
  location_id     uuid not null references locations(id),
  party_id        uuid not null references parties(id),
  number          text not null,
  fy              text not null,
  return_date     date not null,
  kind            text not null check (kind in ('goods','price')),
  reason          text not null check (length(reason) between 3 and 300),
  status          text not null default 'posted' check (status in ('posted','cancelled')),
  place_of_supply text not null,
  supply_type     text not null check (supply_type in ('intra','inter')),
  reverse_charge  boolean not null default false,
  subtotal        numeric(14,2) not null,
  cgst            numeric(14,2) not null default 0,
  sgst            numeric(14,2) not null default 0,
  igst            numeric(14,2) not null default 0,
  round_off       numeric(14,2) not null default 0,
  total           numeric(14,2) not null,
  tds_reversed    numeric(14,2) not null default 0,
  applied_amount  numeric(14,2) not null default 0,
  stock_value     numeric(14,2) not null default 0,
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  cancelled_at    timestamptz,
  cancel_reason   text,
  unique (company_id, number)
);
create index on purchase_returns (company_id, return_date);
create index on purchase_returns (purchase_id);
create index on purchase_returns (company_id, party_id);

create table purchase_return_lines (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  return_id        uuid not null references purchase_returns(id) on delete cascade,
  line_no          integer not null,
  purchase_line_id uuid not null references purchase_lines(id),
  item_id          uuid not null references items(id),
  description      text not null,
  hsn_code         text,
  qty              numeric(14,3) not null default 0 check (qty >= 0),
  unit             text not null,
  gst_rate         numeric(5,2) not null,
  taxable_value    numeric(14,2) not null check (taxable_value > 0),
  cgst             numeric(14,2) not null default 0,
  sgst             numeric(14,2) not null default 0,
  igst             numeric(14,2) not null default 0,
  line_total       numeric(14,2) not null,
  stock_value      numeric(14,2) not null default 0,
  unique (return_id, line_no)
);
create index on purchase_return_lines (purchase_line_id);

do $$
declare t text;
begin
  foreach t in array array['purchase_returns','purchase_return_lines']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  execute 'drop trigger if exists purchase_returns_touch on purchase_returns';
  execute 'create trigger purchase_returns_touch before update on purchase_returns for each row execute function touch_updated_at()';
end $$;

-- Owner and Company Admin of existing businesses (and the sector owner roles, which hold role design) may bill
-- customers over their credit limit.
update roles set permissions = array(select distinct unnest(permissions || array['parties.credit_override']) order by 1)
  where is_system and (name in ('Owner','Company Admin') or 'roles.manage' = any(permissions));
