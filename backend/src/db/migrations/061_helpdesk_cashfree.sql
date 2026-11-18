-- Helpdesk wave 4: SLA pause history, visit parts that move stock, visit cancel.

do $$
declare def text; kinds text[];
begin
  select pg_get_constraintdef(oid) into def from pg_constraint
    where conname = 'stock_moves_ref_type_check' and conrelid = 'stock_moves'::regclass;
  select coalesce(array_agg(distinct m[1]), '{}') into kinds from regexp_matches(coalesce(def, ''), '''([a-z_]+)''', 'g') as m;
  kinds := array(select distinct unnest(kinds || array['service_visit','service_visit_reverse']) order by 1);
  alter table stock_moves drop constraint if exists stock_moves_ref_type_check;
  execute format('alter table stock_moves add constraint stock_moves_ref_type_check check (ref_type in (%s))',
                 (select string_agg(quote_literal(k), ',') from unnest(kinds) k));
end $$;

alter table service_visits drop constraint if exists service_visits_status_check;
alter table service_visits add constraint service_visits_status_check check (status in ('scheduled','done','skipped','cancelled'));
alter table service_visits add column parts_location_id uuid references locations(id);

-- Time a ticket has spent waiting on the customer, in business milliseconds. It is added to the SLA targets.
alter table hd_tickets add column waiting_since timestamptz;
alter table hd_tickets add column paused_ms bigint not null default 0 check (paused_ms >= 0);

create table hd_status_history (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  ticket_id   uuid not null references hd_tickets(id) on delete cascade,
  status      text not null,
  at          timestamptz not null default now(),
  changed_by  uuid references users(id)
);
create index on hd_status_history (ticket_id, at);
insert into hd_status_history (tenant_id, ticket_id, status, at)
  select tenant_id, id, status, coalesce(updated_at, created_at) from hd_tickets;
update hd_tickets set waiting_since = updated_at where status = 'waiting';

alter table hd_status_history enable row level security;
create policy tenant_isolation on hd_status_history using (tenant_id = app_tenant_id()) with check (tenant_id = app_tenant_id());
