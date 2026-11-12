-- v1.8.2: what kind of business a company is, its plan and country, and its
-- branding. enabled_modules null means "the defaults for business_type".
-- Hiding a module is a menu choice; permissions still decide access.
alter table companies
  add column business_type   text not null default 'general',
  add column plan            text not null default 'business' check (plan in ('solo','team','business','enterprise')),
  add column enabled_modules text[],
  add column terms           jsonb not null default '{}',
  add column country         char(2) not null default 'IN',
  add column currency        char(3) not null default 'INR',
  add column logo_file_id    uuid references files(id),
  add column brand_color     text check (brand_color ~ '^#[0-9A-Fa-f]{6}$');
