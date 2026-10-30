-- Adds the construction system accounts (Labour Advances, Material Consumed at Sites,
-- Site Labour Wages) to every existing company. If a company already uses the standard
-- code for one of its own accounts, the system account takes the next free code instead.

do $$
declare
  c record;
  k record;
  n integer;
begin
  for c in select id, tenant_id from companies loop
    for k in select * from (values
      ('1400', 'Labour Advances', 'asset', 'labour_advances'),
      ('5300', 'Material Consumed at Sites', 'expense', 'material_consumed'),
      ('5310', 'Site Labour Wages', 'expense', 'site_labour')
    ) as v(code, name, type, key) loop
      if not exists (select 1 from accounts where company_id = c.id and system_key = k.key) then
        n := k.code::integer;
        while exists (select 1 from accounts where company_id = c.id and code = n::text) loop
          n := n + 1;
        end loop;
        insert into accounts (tenant_id, company_id, code, name, type, subtype, system_key, is_system)
        values (c.tenant_id, c.id, n::text, k.name, k.type, 'other', k.key, true);
      end if;
    end loop;
  end loop;
end $$;
