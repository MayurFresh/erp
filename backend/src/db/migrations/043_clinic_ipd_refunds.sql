-- Refund of deposit left over after an in-patient bill.
create table clinic_ipd_refunds (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  admission_id  uuid not null references clinic_admissions(id) on delete cascade,
  payment_id    uuid not null references payments(id),
  amount        numeric(14,2) not null check (amount > 0),
  created_at    timestamptz not null default now()
);
create index on clinic_ipd_refunds (admission_id);
alter table clinic_ipd_refunds enable row level security;
create policy tenant_isolation on clinic_ipd_refunds using (tenant_id = app_tenant_id()) with check (tenant_id = app_tenant_id());
