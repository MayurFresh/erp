-- v1.8.2: optimistic edit checks need updated_at on master data that lacked it.
-- A trigger keeps it current so no route can forget to touch it.
create or replace function touch_updated_at() returns trigger as $$
begin
  new.updated_at := now();
  return new;
end;
$$ language plpgsql;

alter table parties add column if not exists updated_at timestamptz not null default now();
alter table accounts add column if not exists updated_at timestamptz not null default now();
alter table locations add column if not exists updated_at timestamptz not null default now();

drop trigger if exists parties_touch on parties;
create trigger parties_touch before update on parties for each row execute function touch_updated_at();
drop trigger if exists accounts_touch on accounts;
create trigger accounts_touch before update on accounts for each row execute function touch_updated_at();
drop trigger if exists locations_touch on locations;
create trigger locations_touch before update on locations for each row execute function touch_updated_at();
