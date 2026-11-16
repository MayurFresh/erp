-- TDS certificates and returns across the 1961 and 2025 Acts: dated section map, salary challans, issued certificates.
-- All new-Act references are data, marked unconfirmed until a CA checks them against the Gazette text.

create table tds_section_map (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete cascade,
  old_code        text not null check (length(old_code) between 1 and 20),
  old_section     text not null check (length(old_section) between 1 and 40),
  new_section     text not null check (length(new_section) between 1 and 60),
  payment_code    text check (length(payment_code) <= 10),
  nature          text not null check (length(nature) between 1 and 120),
  rate_text       text check (length(rate_text) <= 60),
  threshold_text  text check (length(threshold_text) <= 80),
  kind            text not null default 'tds' check (kind in ('tds','tcs','salary')),
  effective_from  date not null default '2026-04-01',
  confirmed       boolean not null default false,
  source_url      text check (length(source_url) <= 300),
  note            text check (length(note) <= 300),
  is_active       boolean not null default true,
  updated_at      timestamptz not null default now()
);
create unique index tds_section_map_unique on tds_section_map (coalesce(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), old_code, effective_from);

-- Salary TDS deposited for one payroll month. Record only: the payment itself is posted from a bank entry.
create table tds_salary_challans (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  company_id     uuid not null references companies(id),
  month          date not null check (extract(day from month) = 1),
  deposit_date   date not null,
  bsr_code       text not null check (bsr_code ~ '^[0-9]{7}$'),
  challan_serial text not null check (challan_serial ~ '^[0-9]{5}$'),
  amount         numeric(14,2) not null check (amount > 0),
  interest       numeric(14,2) not null default 0 check (interest >= 0),
  late_fee       numeric(14,2) not null default 0 check (late_fee >= 0),
  status         text not null default 'posted' check (status in ('posted','cancelled')),
  cancel_reason  text check (length(cancel_reason) <= 300),
  created_by     uuid references users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on tds_salary_challans (company_id, month);
create unique index tds_salary_challans_one on tds_salary_challans (company_id, month) where status = 'posted';

-- A certificate that was generated, with the figures as issued. Numbered per company, kind and tax year.
create table tds_certificates (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  company_id   uuid not null references companies(id),
  kind         text not null check (kind in ('salary','non_salary')),
  fy           text not null check (fy ~ '^[0-9]{4}-[0-9]{2}$'),
  quarter      int check (quarter between 1 and 4),
  employee_id  uuid references employees(id),
  party_id     uuid references parties(id),
  form_name    text not null,
  seq          int not null,
  number       text not null,
  snapshot     jsonb not null,
  issued_by    uuid references users(id),
  issued_at    timestamptz not null default now(),
  check ((kind = 'salary' and employee_id is not null) or (kind = 'non_salary' and party_id is not null and quarter is not null))
);
create unique index tds_certificates_one on tds_certificates (company_id, kind, fy, coalesce(quarter, 0), coalesce(employee_id, party_id));
create unique index tds_certificates_seq on tds_certificates (company_id, kind, fy, seq);

do $$
declare t text;
begin
  execute 'alter table tds_section_map enable row level security';
  execute 'create policy tenant_isolation on tds_section_map using (tenant_id is null or tenant_id = app_tenant_id()) with check (tenant_id = app_tenant_id())';
  foreach t in array array['tds_salary_challans','tds_certificates']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['tds_section_map','tds_salary_challans']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

-- Rent threshold: 6,00,000 a year from 1 April 2025 (was 50,000 a month, tested per payment here). Unconfirmed against the Finance Act text.
update tds_sections set threshold_single = null, threshold_aggregate = 600000, aggregate_mode = 'whole', verified = false
  where tenant_id is null and code in ('194I(a)', '194I(b)');

-- Section map seed. new_section reuses the references already in tds_sections.new_ref; payment codes are from
-- secondary commentary. Every row is unconfirmed.
insert into tds_section_map (old_code, old_section, new_section, payment_code, nature, rate_text, threshold_text, kind, source_url) values
  ('192',     's.192',     's.392',                   '1002', 'Salary',                                    'Slab rates',      'Basic exemption',   'salary', 'https://www.compliancecalendar.in/learn/new-tds-tcs-rates-under-income-tax-act-2025'),
  ('194C',    's.194C',    's.393(1) Sl. 6(i)',       null,   'Payments to contractors',                    '1% / 2%',         '30,000 / 1,00,000', 'tds', null),
  ('194J(a)', 's.194J(a)', 's.393(1) Sl. 6(iii)',     '1027', 'Professional fees',                          '10%',             '50,000',            'tds', 'https://www.compliancecalendar.in/learn/new-tds-tcs-rates-under-income-tax-act-2025'),
  ('194J(b)', 's.194J(b)', 's.393(1) Sl. 6(iii)',     '1026', 'Fees for technical services',                '2%',              '50,000',            'tds', 'https://www.compliancecalendar.in/learn/new-tds-tcs-rates-under-income-tax-act-2025'),
  ('194H',    's.194H',    's.393(1) Sl. 1(ii)',      '1006', 'Commission or brokerage',                    '2%',              '20,000',            'tds', 'https://www.compliancecalendar.in/learn/new-tds-tcs-rates-under-income-tax-act-2025'),
  ('194I(a)', 's.194I(a)', 's.393(1) Sl. 2(ii)',      '1008', 'Rent of plant, machinery or equipment',      '2%',              '6,00,000 a year',   'tds', null),
  ('194I(b)', 's.194I(b)', 's.393(1) Sl. 2(ii)',      '1009', 'Rent of land, building or furniture',        '10%',             '6,00,000 a year',   'tds', null),
  ('194Q',    's.194Q',    's.393(1) Sl. 8(ii)',      null,   'Purchase of goods',                          '0.1%',            '50,00,000',         'tds', null),
  ('194A',    's.194A',    's.393(1) Sl. 5(ii)',      '1021', 'Interest other than on securities',          '10%',             '10,000 (banks 50,000; senior citizens 1,00,000)', 'tds', 'https://www.compliancecalendar.in/learn/new-tds-tcs-rates-under-income-tax-act-2025'),
  ('194R',    's.194R',    's.393(1) Sl. 8(iv)',      '1033', 'Business perquisites or benefits',           '10%',             '20,000',            'tds', null),
  ('194T',    's.194T',    's.393(3) Sl. 7',          '1067', 'Payments to partners',                       '10%',             '20,000',            'tds', 'https://www.compliancecalendar.in/learn/new-tds-tcs-rates-under-income-tax-act-2025'),
  ('194IB',   's.194IB',   's.393(1)',                '1007', 'Rent paid by individual or HUF',             '2%',              '50,000 a month',    'tds', null),
  ('194IA',   's.194-IA',  's.393(1)',                null,   'Transfer of immovable property',             '1%',              '50,00,000',         'tds', null),
  ('194M',    's.194M',    's.393(1)',                null,   'Contract or professional fees by individual or HUF', '2% / 5%', '50,00,000',         'tds', null),
  ('194O',    's.194-O',   's.393(1) Sl. 8(v)',       '1035', 'E-commerce operator payments',               '0.1%',            '5,00,000 (individual or HUF)', 'tds', null),
  ('195',     's.195',     's.393(2)',                null,   'Payments to non-residents',                  'As per rate in force', 'None',         'tds', null),
  ('206C',    's.206C',    's.394',                   null,   'Tax collected at source (all goods and remittances)', 'Varies', 'Varies',            'tcs', null)
on conflict do nothing;
