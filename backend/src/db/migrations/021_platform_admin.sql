-- Platform super admin: the product owner sees and manages every tenant.
-- The app role gets no direct rows from the platform tables (RLS on, no policy).
-- Everything goes through security definer functions, each of which re-checks that the caller is an admin.

alter table tenants
  add column status text not null default 'active' check (status in ('active', 'suspended')),
  add column suspended_at timestamptz,
  add column suspended_reason text;

create table platform_admins (
  user_id     uuid primary key references users(id) on delete cascade,
  created_at  timestamptz not null default now()
);
alter table platform_admins enable row level security;

create table platform_audit (
  id             uuid primary key default gen_random_uuid(),
  admin_user_id  uuid not null references users(id),
  action         text not null,
  tenant_id      uuid references tenants(id),
  target_type    text not null,
  target_id      text,
  detail         jsonb not null default '{}',
  created_at     timestamptz not null default now()
);
create index on platform_audit (created_at desc);
alter table platform_audit enable row level security;

create function platform_is_admin(p_user uuid) returns boolean
  language sql stable security definer set search_path = public
  as $$ select exists (select 1 from platform_admins where user_id = p_user) $$;

create function platform_require_admin(p_user uuid) returns void
  language plpgsql stable security definer set search_path = public
  as $$ begin
    if not exists (select 1 from platform_admins where user_id = p_user) then
      raise exception 'not a platform admin' using errcode = '42501';
    end if;
  end $$;

-- One row per tenant (or the one named). Sign-in time is the newest session token of any user.
create function platform_tenants(p_admin uuid, p_tenant uuid default null)
  returns table (
    id uuid, name text, status text, created_at timestamptz, suspended_at timestamptz, suspended_reason text,
    company_count bigint, user_count bigint, active_users bigint,
    business_type text, plan text, country text,
    owner_name text, owner_email text, last_sign_in timestamptz, has_platform_admin boolean)
  language plpgsql stable security definer set search_path = public
  as $$ begin
    perform platform_require_admin(p_admin);
    return query
    select t.id, t.name, t.status, t.created_at, t.suspended_at, t.suspended_reason,
      (select count(*) from companies c where c.tenant_id = t.id),
      (select count(*) from users u where u.tenant_id = t.id),
      (select count(*) from users u where u.tenant_id = t.id and u.is_active),
      fc.business_type::text, fc.plan::text, fc.country::text,
      ow.name, ow.email,
      (select max(rt.created_at) from refresh_tokens rt where rt.tenant_id = t.id),
      exists (select 1 from platform_admins pa join users u on u.id = pa.user_id where u.tenant_id = t.id)
    from tenants t
    left join lateral (select c.business_type, c.plan, c.country from companies c
                       where c.tenant_id = t.id order by c.created_at limit 1) fc on true
    left join lateral (select u.name, u.email from users u
                       left join user_roles ur on ur.user_id = u.id
                       left join roles r on r.id = ur.role_id
                       where u.tenant_id = t.id
                       order by (r.name = 'Owner') desc nulls last, u.created_at limit 1) ow on true
    where p_tenant is null or t.id = p_tenant
    order by t.created_at desc;
  end $$;

-- Users who signed in (or refreshed) within the last p_days days, across all tenants.
create function platform_active_users(p_admin uuid, p_days int) returns bigint
  language plpgsql stable security definer set search_path = public
  as $$ declare n bigint; begin
    perform platform_require_admin(p_admin);
    select count(distinct user_id) into n from refresh_tokens where created_at > now() - make_interval(days => p_days);
    return n;
  end $$;

-- Finds the tenant of a company or user so a route can then open that tenant with withTenant.
create function platform_locate(p_admin uuid, p_kind text, p_id uuid) returns uuid
  language plpgsql stable security definer set search_path = public
  as $$ declare t uuid; begin
    perform platform_require_admin(p_admin);
    if p_kind = 'company' then select tenant_id into t from companies where id = p_id;
    elsif p_kind = 'user' then select tenant_id into t from users where id = p_id;
    end if;
    return t;
  end $$;

create function platform_user_is_admin(p_admin uuid, p_user uuid) returns boolean
  language plpgsql stable security definer set search_path = public
  as $$ begin
    perform platform_require_admin(p_admin);
    return exists (select 1 from platform_admins where user_id = p_user);
  end $$;

create function platform_audit_write(p_admin uuid, p_action text, p_tenant uuid, p_type text, p_target text, p_detail jsonb)
  returns uuid
  language plpgsql volatile security definer set search_path = public
  as $$ declare new_id uuid; begin
    perform platform_require_admin(p_admin);
    insert into platform_audit (admin_user_id, action, tenant_id, target_type, target_id, detail)
      values (p_admin, p_action, p_tenant, p_type, p_target, coalesce(p_detail, '{}'))
      returning id into new_id;
    return new_id;
  end $$;

create function platform_audit_list(p_admin uuid, p_limit int, p_before timestamptz default null, p_tenant uuid default null)
  returns table (id uuid, admin_user_id uuid, admin_name text, action text, tenant_id uuid, tenant_name text,
                 target_type text, target_id text, detail jsonb, created_at timestamptz)
  language plpgsql stable security definer set search_path = public
  as $$ begin
    perform platform_require_admin(p_admin);
    return query
    select a.id, a.admin_user_id, u.name, a.action, a.tenant_id, t.name, a.target_type, a.target_id, a.detail, a.created_at
    from platform_audit a join users u on u.id = a.admin_user_id left join tenants t on t.id = a.tenant_id
    where (p_before is null or a.created_at < p_before) and (p_tenant is null or a.tenant_id = p_tenant)
    order by a.created_at desc limit least(greatest(p_limit, 1), 200);
  end $$;

-- Tenant status for sign-in checks before a tenant context exists.
create function auth_tenant_status(p_tenant uuid) returns text
  language sql stable security definer set search_path = public
  as $$ select status from tenants where id = p_tenant $$;

-- Only the app role may call these; PUBLIC loses the default execute right.
revoke all on function platform_is_admin(uuid), platform_require_admin(uuid), platform_tenants(uuid, uuid),
  platform_active_users(uuid, int), platform_locate(uuid, text, uuid), platform_user_is_admin(uuid, uuid),
  platform_audit_write(uuid, text, uuid, text, text, jsonb), platform_audit_list(uuid, int, timestamptz, uuid),
  auth_tenant_status(uuid) from public;
