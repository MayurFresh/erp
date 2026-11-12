-- Warehouse: default bin per item, and the link from a pick list to the invoice that billed it.
alter table wh_item_rules add column default_bin_id uuid references wh_bins(id);

create table wh_pick_links (
  pick_ref_id  uuid primary key,
  tenant_id    uuid not null references tenants(id) on delete cascade,
  company_id   uuid not null references companies(id),
  invoice_id   uuid not null references invoices(id),
  created_by   uuid references users(id),
  created_at   timestamptz not null default now()
);
create index on wh_pick_links (company_id, invoice_id);
alter table wh_pick_links enable row level security;
create policy tenant_isolation on wh_pick_links using (tenant_id = app_tenant_id()) with check (tenant_id = app_tenant_id());
