-- Gratuity provision postings, loan recovery capped at net pay (part-paid instalments) and foreclosure interest.

create table gratuity_provisions (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  as_of          date not null,
  total          numeric(14,2) not null check (total >= 0),
  prior_balance  numeric(14,2) not null,
  posted_amount  numeric(14,2) not null,
  employee_count integer not null default 0,
  entry_id       uuid,
  created_by     uuid not null references users(id),
  created_at     timestamptz not null default now(),
  unique (company_id, as_of)
);
alter table gratuity_provisions enable row level security;
create policy tenant_isolation on gratuity_provisions using (tenant_id = app_tenant_id()) with check (tenant_id = app_tenant_id());

-- The part of an instalment already recovered when net pay could not cover all of it. The instalment's
-- principal, interest and amount hold what is still due.
alter table loan_installments add column paid_amount numeric(14,2) not null default 0 check (paid_amount >= 0);

alter table employee_loans add column foreclose_principal numeric(14,2);
alter table employee_loans add column foreclose_interest numeric(14,2);
