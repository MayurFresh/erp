-- MRP on items, and stock age that survives a transfer between locations.
alter table items add column mrp numeric(12,2) check (mrp is null or mrp >= 0);

-- A transfer receipt keeps the date of the source layer it carries (stock ageing and FIFO read it).
alter table stock_moves add column layer_date date;
-- The source layers a transfer line took at dispatch: [{qty, date}], oldest first.
alter table transfer_lines add column layers jsonb not null default '[]'::jsonb;

-- Purchase orders keep the unit the buyer typed, like the other document lines (053).
alter table purchase_order_lines add column entered_unit text, add column entered_qty numeric(14,3);
