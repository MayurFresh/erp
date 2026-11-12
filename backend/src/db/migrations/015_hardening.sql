-- v1.8.1 hardening. A running job sends a heartbeat, so only a job whose worker died goes back to the queue
-- (D-10: a long job used to be re-queued after 10 minutes even while it was still running).
alter table jobs add column heartbeat_at timestamptz;

create or replace function jobs_claim(p_limit integer)
  returns setof jobs
  language plpgsql volatile security definer
  set search_path = public
  as $$
begin
  update jobs set status = 'queued'
    where status = 'running' and coalesce(heartbeat_at, started_at) < now() - interval '10 minutes';
  return query
    update jobs j set status = 'running', attempts = j.attempts + 1, started_at = now(), heartbeat_at = now()
    where j.id in (select q.id from jobs q where q.status = 'queued' and q.run_after <= now()
                   order by q.run_after limit p_limit for update skip locked)
    returning j.*;
end $$;

-- Called by the worker about once a minute for each job it is still running.
create function jobs_heartbeat(p_id uuid)
  returns void
  language sql volatile security definer
  set search_path = public
  as $$ update jobs set heartbeat_at = now() where id = p_id and status = 'running' $$;
