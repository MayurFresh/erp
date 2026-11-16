-- Employee expense claims, salary advances and loans. Payroll is fed only through payroll_adjustments:
-- triggers attach approved reimbursements and loan instalments to each new payroll run.

create table claim_categories (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  company_id        uuid not null references companies(id),
  name              text not null check (length(name) between 1 and 60),
  expense_account_id uuid not null references accounts(id),
  gst_itc_allowed   boolean not null default false,
  per_claim_limit   numeric(14,2) check (per_claim_limit > 0),
  monthly_limit     numeric(14,2) check (monthly_limit > 0),
  requires_receipt  boolean not null default false,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (company_id, name)
);

create table expense_claims (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references tenants(id) on delete cascade,
  company_id         uuid not null references companies(id),
  number             text not null,
  employee_id        uuid not null references employees(id),
  purpose            text not null check (length(purpose) between 2 and 300),
  claim_date         date not null,
  status             text not null default 'draft' check (status in ('draft','submitted','approved','rejected','paid')),
  total              numeric(14,2) not null default 0 check (total >= 0),
  gst_total          numeric(14,2) not null default 0 check (gst_total >= 0),
  itc_total          numeric(14,2) not null default 0 check (itc_total >= 0),
  settlement         text check (settlement in ('pay_now','payroll')),
  submitted_at       timestamptz,
  submitted_by       uuid references users(id),
  decided_by         uuid references users(id),
  decided_at         timestamptz,
  decision_note      text check (length(decision_note) <= 300),
  entry_id           uuid,
  paid_at            timestamptz,
  pay_date           date,
  pay_account_id     uuid references accounts(id),
  pay_entry_id       uuid,
  payroll_run_id     uuid references payroll_runs(id) on delete set null,
  payroll_adjustment_id uuid,
  created_by         uuid not null references users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (company_id, number)
);
create index on expense_claims (company_id, status);
create index on expense_claims (employee_id, claim_date desc);
create index on expense_claims (payroll_run_id);

create table expense_claim_lines (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  claim_id       uuid not null references expense_claims(id) on delete cascade,
  line_no        integer not null,
  category_id    uuid not null references claim_categories(id),
  expense_date   date not null,
  description    text not null check (length(description) between 1 and 300),
  amount         numeric(14,2) not null check (amount > 0),
  vendor_gstin   text check (vendor_gstin ~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$'),
  gst_amount     numeric(14,2) not null default 0 check (gst_amount >= 0),
  itc_eligible   boolean not null default false,
  receipt_file_id uuid references files(id) on delete set null,
  unique (claim_id, line_no),
  check (gst_amount < amount)
);
create index on expense_claim_lines (category_id, expense_date);

create table employee_loans (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  company_id      uuid not null references companies(id),
  number          text not null,
  employee_id     uuid not null references employees(id),
  kind            text not null check (kind in ('advance','loan')),
  purpose         text not null check (length(purpose) between 2 and 300),
  amount          numeric(14,2) not null check (amount > 0),
  interest_rate   numeric(5,2) not null default 0 check (interest_rate between 0 and 50),
  instalment      numeric(14,2) not null check (instalment > 0),
  start_month     date not null,
  tenure          integer not null check (tenure > 0),
  total_interest  numeric(14,2) not null default 0,
  status          text not null default 'active' check (status in ('active','paused','closed','foreclosed')),
  disbursed_on    date not null,
  disburse_account_id uuid references accounts(id),
  disburse_entry_id uuid,
  ca_review       boolean not null default false,
  foreclosed_on   date,
  foreclose_amount numeric(14,2),
  foreclose_entry_id uuid,
  closed_on       date,
  created_by      uuid not null references users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, number)
);
create index on employee_loans (employee_id, status);

create table loan_installments (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  loan_id       uuid not null references employee_loans(id) on delete cascade,
  seq           integer not null,
  due_month     date not null,
  principal     numeric(14,2) not null check (principal >= 0),
  interest      numeric(14,2) not null default 0 check (interest >= 0),
  amount        numeric(14,2) not null check (amount > 0),
  status        text not null default 'due' check (status in ('due','in_run','recovered','waived')),
  run_id        uuid references payroll_runs(id) on delete set null,
  adjustment_id uuid,
  recovered_on  date,
  unique (loan_id, seq)
);
create index on loan_installments (run_id);
create index on loan_installments (adjustment_id);

do $$
declare t text;
begin
  foreach t in array array['claim_categories','expense_claims','expense_claim_lines','employee_loans','loan_installments']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy tenant_isolation on %I using (tenant_id = app_tenant_id()) '
                   'with check (tenant_id = app_tenant_id())', t);
  end loop;
  foreach t in array array['claim_categories','expense_claims','employee_loans']
  loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

-- A new payroll run picks up the next instalment of each active loan (deduction) and each approved
-- reimbursement that was sent to payroll (non-taxable earning).
create or replace function cl_attach_to_run() returns trigger language plpgsql as $$
declare r record; adj uuid;
begin
  for r in
    select i.id as inst_id, i.amount, l.employee_id, l.number, l.kind, i.seq
      from employee_loans l
      join employees e on e.id = l.employee_id
      join lateral (select x.* from loan_installments x where x.loan_id = l.id and x.status = 'due'
                     and x.due_month <= new.month order by x.seq limit 1) i on true
     where l.company_id = new.company_id and l.status = 'active' and e.status <> 'inactive'
       and (new.location_id is null or e.location_id = new.location_id)
  loop
    insert into payroll_adjustments (tenant_id, run_id, employee_id, kind, label, amount, taxable, reason)
      values (new.tenant_id, new.id, r.employee_id, 'deduction',
              (case when r.kind = 'loan' then 'Loan recovery ' else 'Advance recovery ' end) || r.number,
              r.amount, false, 'Instalment ' || r.seq)
      returning id into adj;
    update loan_installments set status = 'in_run', run_id = new.id, adjustment_id = adj where id = r.inst_id;
  end loop;
  for r in
    select c.id as claim_id, c.employee_id, c.number, c.total
      from expense_claims c join employees e on e.id = c.employee_id
     where c.company_id = new.company_id and c.status = 'approved' and c.settlement = 'payroll'
       and c.payroll_run_id is null and e.status <> 'inactive'
       and (new.location_id is null or e.location_id = new.location_id)
  loop
    insert into payroll_adjustments (tenant_id, run_id, employee_id, kind, label, amount, taxable, reason)
      values (new.tenant_id, new.id, r.employee_id, 'earning', 'Expense reimbursement ' || r.number, r.total, false,
              'Reimbursement of claim ' || r.number || ', not taxable')
      returning id into adj;
    update expense_claims set payroll_run_id = new.id, payroll_adjustment_id = adj where id = r.claim_id;
  end loop;
  return new;
end $$;

drop trigger if exists cl_run_attach on payroll_runs;
create trigger cl_run_attach after insert on payroll_runs for each row execute function cl_attach_to_run();

-- A cancelled run, or a recovery removed from a run by hand, puts the instalment or claim back in the queue.
create or replace function cl_release_run() returns trigger language plpgsql as $$
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    update loan_installments set status = 'due', run_id = null, adjustment_id = null where run_id = new.id and status = 'in_run';
    update expense_claims set payroll_run_id = null, payroll_adjustment_id = null where payroll_run_id = new.id and status = 'approved';
  end if;
  return new;
end $$;
drop trigger if exists cl_run_release on payroll_runs;
create trigger cl_run_release after update of status on payroll_runs for each row execute function cl_release_run();

create or replace function cl_release_adjustment() returns trigger language plpgsql as $$
begin
  update loan_installments set status = 'due', run_id = null, adjustment_id = null where adjustment_id = old.id and status = 'in_run';
  update expense_claims set payroll_run_id = null, payroll_adjustment_id = null where payroll_adjustment_id = old.id and status = 'approved';
  return old;
end $$;
drop trigger if exists cl_adjustment_release on payroll_adjustments;
create trigger cl_adjustment_release after delete on payroll_adjustments for each row execute function cl_release_adjustment();

-- Owner and Company Admin of existing businesses get the new permissions.
update roles set permissions = array(select distinct unnest(permissions ||
  array['claims.approve','claims.manage','loans.manage']) order by 1)
  where is_system and name in ('Owner','Company Admin');
