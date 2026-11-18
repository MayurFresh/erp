-- 060: wave 4 finance and export gaps.
-- TCS reversed by a credit note, foreign-currency tags on purchase bills, and revaluation of payables.

alter table credit_notes add column tcs_reversed numeric(14,2) not null default 0 check (tcs_reversed >= 0);

-- A purchase bill in a foreign currency: the rate it was booked at and its total in that currency.
create table purchase_fx (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  purchase_id     uuid not null references purchases(id) on delete cascade,
  currency_code   text not null check (currency_code ~ '^[A-Z]{3}$'),
  exchange_rate   numeric(16,6) not null check (exchange_rate > 0),
  fc_total        numeric(16,4) not null check (fc_total > 0),
  created_at      timestamptz not null default now(),
  unique (purchase_id)
);
create index on purchase_fx (company_id, currency_code);
alter table purchase_fx enable row level security;
create policy tenant_isolation on purchase_fx using (tenant_id = app_tenant_id()) with check (tenant_id = app_tenant_id());

alter table fx_revaluations add column kind text not null default 'receivable' check (kind in ('receivable','payable'));
