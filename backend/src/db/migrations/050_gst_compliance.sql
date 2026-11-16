-- GST compliance: IMS reasons, e-invoice turnover band, item GST rate history.

alter table gst_2b_lines
  add column ims_reason   text check (length(ims_reason) <= 300),
  add column ims_acted_at timestamptz,
  add column ims_acted_by uuid references users(id);

alter table companies
  add column aato_band text not null default 'below_10cr' check (aato_band in ('below_10cr','10cr_plus'));

-- Rate of an item from a date. The latest row on or before the date applies; with no row the item's own rate applies.
create table item_gst_rates (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  item_id         uuid not null references items(id) on delete cascade,
  rate            numeric(5,2) not null check (rate >= 0 and rate <= 100),
  effective_from  date not null,
  reason          text check (length(reason) <= 200),
  created_by      uuid references users(id),
  created_at      timestamptz not null default now(),
  unique (item_id, effective_from)
);
create index on item_gst_rates (company_id, effective_from);

alter table item_gst_rates enable row level security;
create policy tenant_isolation on item_gst_rates using (tenant_id = app_tenant_id()) with check (tenant_id = app_tenant_id());
