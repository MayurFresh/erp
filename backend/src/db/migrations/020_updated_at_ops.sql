-- v1.8.2: STALE_EDIT for work orders, RA bills, projects, cost centres, units, bookings and workers.
-- Uses touch_updated_at() from 019.
alter table work_orders add column if not exists updated_at timestamptz not null default now();
alter table ra_bills add column if not exists updated_at timestamptz not null default now();
alter table projects add column if not exists updated_at timestamptz not null default now();
alter table cost_centres add column if not exists updated_at timestamptz not null default now();
alter table units add column if not exists updated_at timestamptz not null default now();
alter table bookings add column if not exists updated_at timestamptz not null default now();
alter table workers add column if not exists updated_at timestamptz not null default now();

drop trigger if exists work_orders_touch on work_orders;
create trigger work_orders_touch before update on work_orders for each row execute function touch_updated_at();
drop trigger if exists ra_bills_touch on ra_bills;
create trigger ra_bills_touch before update on ra_bills for each row execute function touch_updated_at();
drop trigger if exists projects_touch on projects;
create trigger projects_touch before update on projects for each row execute function touch_updated_at();
drop trigger if exists cost_centres_touch on cost_centres;
create trigger cost_centres_touch before update on cost_centres for each row execute function touch_updated_at();
drop trigger if exists units_touch on units;
create trigger units_touch before update on units for each row execute function touch_updated_at();
drop trigger if exists bookings_touch on bookings;
create trigger bookings_touch before update on bookings for each row execute function touch_updated_at();
drop trigger if exists workers_touch on workers;
create trigger workers_touch before update on workers for each row execute function touch_updated_at();
