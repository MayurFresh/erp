-- Allow daily progress reports to be rejected and resubmitted.

alter table dprs drop constraint if exists dprs_status_check;
alter table dprs add constraint dprs_status_check check (status in ('draft','submitted','approved','rejected'));

alter table dprs add column rejected_by uuid references users(id);
alter table dprs add column rejected_at timestamptz;
alter table dprs add column reject_reason text;
