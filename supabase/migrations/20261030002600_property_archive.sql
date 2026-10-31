-- =============================================================================
-- HUSORA · Migration 2600 · Häuser archivieren statt löschen
-- =============================================================================
-- Archivierte Häuser bleiben in der Cloud erhalten (status = 'archived'), samt
-- Aufträgen, Rechnungen, Fotos und Kontrollen. Die App verschiebt sie lokal in ein
-- Archiv; der Abgleich der Hausliste löscht archivierte Häuser deshalb nicht mehr.
-- Wiederhergestellte Häuser werden wieder aktiv. Archivierte zählen nicht gegen
-- das Häuser-Limit des Tarifs.

create or replace function private.project_app_properties(p_org uuid, p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item  jsonb;
  v_count integer := 0;
  v_refs  text[] := '{}';
  v_addr  text;
  v_year  numeric;
begin
  for v_item in select * from jsonb_array_elements(p_items) loop
    continue when coalesce(v_item ->> 'id', '') = '' or coalesce(trim(v_item ->> 'name'), '') = '';
    v_addr := coalesce(v_item ->> 'address', '');
    v_year := private.app_num(v_item ->> 'yearBuilt');
    insert into public.properties (organization_id, app_ref, name, description, city, region, country,
                                   living_area_m2, land_area_m2, bedrooms, max_guests, year_built, property_type, status)
    values (p_org, v_item ->> 'id', trim(v_item ->> 'name'),
            nullif(concat_ws(' · ', nullif(v_addr, ''), nullif(v_item ->> 'condition', '')), ''),
            nullif(trim(split_part(v_addr, ',', 1)), ''),
            coalesce(nullif(v_item ->> 'region', ''), nullif(trim(split_part(v_addr, ',', 2)), '')),
            private.app_country(v_addr),
            private.app_num(v_item ->> 'livingArea'),
            private.app_num(v_item ->> 'plotSize'),
            private.app_num(v_item ->> 'rooms')::integer,
            private.app_num(v_item ->> 'beds')::integer,
            case when v_year between 1600 and 2100 then v_year::integer end,
            'holiday_home', 'active')
    on conflict (organization_id, app_ref) where app_ref is not null do update set
      name = excluded.name,
      description = excluded.description,
      city = excluded.city,
      region = excluded.region,
      country = excluded.country,
      living_area_m2 = excluded.living_area_m2,
      land_area_m2 = excluded.land_area_m2,
      bedrooms = excluded.bedrooms,
      max_guests = excluded.max_guests,
      year_built = excluded.year_built,
      status = case when public.properties.status = 'archived' then 'active' else public.properties.status end;
    v_refs := v_refs || (v_item ->> 'id');
    v_count := v_count + 1;
  end loop;
  -- In der App gelöschte Häuser entfernen (nur aus der App stammende, archivierte bleiben)
  delete from public.properties p
  where p.organization_id = p_org and p.app_ref is not null and p.status <> 'archived' and not (p.app_ref = any (v_refs));
  return v_count;
end;
$$;

-- Häuser-Limit: archivierte Häuser zählen nicht
create or replace function private.enforce_plan_limit()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_key text := case tg_table_name when 'properties' then 'properties' else 'documents' end;
  v_limit integer;
  v_used integer;
begin
  if auth.uid() is null or coalesce(auth.role(), '') = 'service_role' then return new; end if;
  if exists (select 1 from public.organizations o where o.id = new.organization_id and o.org_type = 'service_partner') then return new; end if;
  if not private.is_org_member(new.organization_id) then return new; end if;
  select nullif(p.limits ->> v_key, '')::integer into v_limit from public.plans p where p.id = private.org_plan(new.organization_id);
  if v_limit is null then return new; end if;
  if tg_table_name = 'properties' then
    select count(*) into v_used from public.properties where organization_id = new.organization_id and status <> 'archived';
  else
    select count(*) into v_used from public.documents where organization_id = new.organization_id;
  end if;
  if v_used >= v_limit then
    raise exception 'Tariflimit erreicht: höchstens % % in deinem Tarif.', v_limit, case when v_key = 'properties' and v_limit = 1 then 'Haus' when v_key = 'properties' then 'Häuser' when v_limit = 1 then 'Dokument' else 'Dokumente' end using errcode = 'P0001';
  end if;
  return new;
end;
$$;

-- Haus in der Cloud archivieren / reaktivieren (vor dem lokalen Verschieben aufgerufen)
create or replace function public.set_property_archived(p_organization_id uuid, p_app_ref text, p_archived boolean)
returns boolean
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_org_staff(p_organization_id) then
    raise exception 'Keine Berechtigung für diese Organisation' using errcode = '42501';
  end if;
  update public.properties set status = case when p_archived then 'archived' else 'active' end
  where organization_id = p_organization_id and app_ref = p_app_ref;
  -- offene, noch nicht angenommene Anfragen zum Haus zurückziehen
  if p_archived then
    update public.service_orders o set status = 'cancelled', response_note = 'Zurückgezogen: Haus wurde archiviert.'
    from public.properties p
    where p.organization_id = p_organization_id and p.app_ref = p_app_ref and o.property_id = p.id and o.status = 'offered';
  end if;
  return found;
end;
$$;
revoke all on function public.set_property_archived(uuid, text, boolean) from public, anon;
grant execute on function public.set_property_archived(uuid, text, boolean) to authenticated;
