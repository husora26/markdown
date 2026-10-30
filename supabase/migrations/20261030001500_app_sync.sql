-- =============================================================================
-- HUSORA · Migration 1500 · Cloud-Sync der Husora-App
-- =============================================================================
-- Die App speichert ihre Daten als Schlüssel "stugliv-…" (JSON). public.app_data
-- nimmt diese Schlüssel vollständig und unverändert auf – damit liegt die komplette
-- App-Datenbank in Supabase und lässt sich auf jedem Gerät wiederherstellen.
-- Zusätzlich überträgt ein Trigger Ferienhäuser, Buchungen und Aufgaben in die
-- normalisierten Tabellen (properties, bookings, service_tasks). Dort sind sie über
-- app_ref (ID aus der App) eindeutig zugeordnet und werden bei jedem Sync aktualisiert.

-- -----------------------------------------------------------------------------
-- Zuordnung App-ID ↔ Datensatz
-- -----------------------------------------------------------------------------
alter table public.properties    add column app_ref text;
alter table public.bookings      add column app_ref text;
alter table public.service_tasks add column app_ref text;
comment on column public.properties.app_ref is 'ID des Datensatzes in der Husora-App (Cloud-Sync).';
comment on column public.bookings.app_ref is 'ID des Datensatzes in der Husora-App (Cloud-Sync).';
comment on column public.service_tasks.app_ref is 'ID des Datensatzes in der Husora-App (Cloud-Sync).';
create unique index properties_app_ref_idx    on public.properties (organization_id, app_ref)    where app_ref is not null;
create unique index bookings_app_ref_idx      on public.bookings (organization_id, app_ref)      where app_ref is not null;
create unique index service_tasks_app_ref_idx on public.service_tasks (organization_id, app_ref) where app_ref is not null;

-- Aus der App übernommene Buchungen lösen keine Datenbank-Automationen aus:
-- die App plant Reinigung und Kontrolle selbst, die Aufgaben kommen per Sync.
drop trigger bookings_automation on public.bookings;
create trigger bookings_automation after insert or update of status, check_out on public.bookings
  for each row when (new.app_ref is null) execute function private.automation_on_booking();

-- -----------------------------------------------------------------------------
-- app_data: alle App-Schlüssel je Organisation
-- -----------------------------------------------------------------------------
create table public.app_data (
  organization_id    uuid not null references public.organizations(id) on delete cascade,
  key                text not null check (key ~ '^stugliv-[a-z0-9-]+$'),
  value              text not null,
  size_bytes         integer generated always as (octet_length(value)) stored,
  device_id          text check (device_id is null or length(device_id) <= 64),
  updated_by         uuid references public.users(id) on delete set null,
  updated_at         timestamptz not null default now(),
  projection_status  text,
  primary key (organization_id, key)
);
comment on table public.app_data is 'Komplette Daten der Husora-App (localStorage-Schlüssel "stugliv-…") je Organisation.';
comment on column public.app_data.projection_status is 'Ergebnis der Übernahme in die Fachtabellen, z. B. "3 Häuser" oder die Fehlermeldung.';
create index app_data_org_updated_idx on public.app_data (organization_id, updated_at desc);
create index app_data_updated_by_idx on public.app_data (updated_by) where updated_by is not null;

create or replace function private.app_data_stamp()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(private.current_user_id(), new.updated_by);
  return new;
end;
$$;
create trigger app_data_stamp before insert or update on public.app_data
  for each row execute function private.app_data_stamp();

alter table public.app_data enable row level security;
create policy app_data_select on public.app_data for select to authenticated
  using (private.can_read_org(organization_id));
create policy app_data_insert on public.app_data for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy app_data_update on public.app_data for update to authenticated
  using (private.is_org_staff(organization_id)) with check (private.is_org_staff(organization_id));
create policy app_data_delete on public.app_data for delete to authenticated
  using (private.is_org_staff(organization_id));
revoke all on public.app_data from anon;

-- -----------------------------------------------------------------------------
-- Hilfsfunktionen für die Übernahme
-- -----------------------------------------------------------------------------
-- Erste Zahl aus einem Text ("86 m²", "1.978", "6 Schlafplätze" …)
create or replace function private.app_num(p_text text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select nullif(replace(substring(coalesce(p_text, '') from '-?[0-9]+(?:[.,][0-9]+)?'), ',', '.'), '')::numeric
$$;

create or replace function private.app_country(p_address text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_address ~* '(schweden|sweden|sverige)' then 'SE'
    when p_address ~* '(norwegen|norway|norge)' then 'NO'
    when p_address ~* '(dänemark|daenemark|denmark|danmark)' then 'DK'
    when p_address ~* '(finnland|finland|suomi)' then 'FI'
    when p_address ~* '(deutschland|germany)' then 'DE'
    when p_address ~* '(österreich|austria)' then 'AT'
    when p_address ~* '(schweiz|switzerland)' then 'CH'
    when p_address ~* '(niederlande|netherlands)' then 'NL'
  end
$$;

-- Datum (YYYY-MM-DD) + Uhrzeit (HH:MM) in der Zeitzone der Organisation
create or replace function private.app_ts(p_date text, p_time text, p_default_time text, p_timezone text)
returns timestamptz
language plpgsql
stable
set search_path = ''
as $$
declare
  v_time text := coalesce(substring(coalesce(p_time, '') from '^\d{1,2}:\d{2}'), p_default_time);
begin
  if p_date !~ '^\d{4}-\d{2}-\d{2}$' then
    return null;
  end if;
  return ((p_date || ' ' || v_time)::timestamp) at time zone coalesce(p_timezone, 'Europe/Stockholm');
exception when others then
  return null;
end;
$$;

-- Ferienhäuser übernehmen
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
                                   living_area_m2, land_area_m2, bedrooms, max_guests, year_built, property_type)
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
            'holiday_home')
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
      year_built = excluded.year_built;
    v_refs := v_refs || (v_item ->> 'id');
    v_count := v_count + 1;
  end loop;
  -- In der App gelöschte Häuser entfernen (nur aus der App stammende)
  delete from public.properties p
  where p.organization_id = p_org and p.app_ref is not null and not (p.app_ref = any (v_refs));
  return v_count;
end;
$$;

-- Buchungen übernehmen
create or replace function private.project_app_bookings(p_org uuid, p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item     jsonb;
  v_count    integer := 0;
  v_refs     text[] := '{}';
  v_tz       text := (select o.timezone from public.organizations o where o.id = p_org);
  v_property uuid;
  v_in       timestamptz;
  v_out      timestamptz;
  v_owner    boolean;
  v_source   text;
  v_status   text;
  v_name     text;
begin
  for v_item in select * from jsonb_array_elements(p_items) loop
    continue when coalesce(v_item ->> 'id', '') = '';
    select p.id into v_property from public.properties p
    where p.organization_id = p_org and p.app_ref = v_item ->> 'propertyId';
    v_in := private.app_ts(v_item ->> 'startDate', v_item ->> 'arrivalTime', '15:00', v_tz);
    v_out := private.app_ts(v_item ->> 'endDate', v_item ->> 'departureTime', '11:00', v_tz);
    continue when v_property is null or v_in is null or v_out is null or v_out <= v_in;

    v_owner := v_item ->> 'kind' = 'owner' or lower(coalesce(v_item ->> 'source', '')) = 'owner'
               or coalesce(v_item ->> 'owner', '') in ('true', '1');
    v_source := case
      when v_owner then 'owner'
      when lower(coalesce(v_item ->> 'source', '')) like '%airbnb%' then 'airbnb'
      when lower(coalesce(v_item ->> 'source', '')) like '%booking%' then 'booking_com'
      when lower(coalesce(v_item ->> 'source', '')) like '%vrbo%' then 'vrbo'
      when lower(coalesce(v_item ->> 'source', '')) like '%ical%' then 'ical'
      else 'direct' end;
    v_status := case when coalesce(v_item ->> 'cancelled', '') in ('true', '1') then 'cancelled'
                     when v_out < now() then 'completed' else 'confirmed' end;
    v_name := nullif(trim(coalesce(v_item ->> 'guestName', '')), '');

    begin
      insert into public.bookings (organization_id, property_id, app_ref, source, guest_first_name, guest_last_name,
                                   guest_count, check_in, check_out, status, notes)
      values (p_org, v_property, v_item ->> 'id', v_source,
              nullif(split_part(v_name, ' ', 1), ''), nullif(trim(substr(v_name, length(split_part(v_name, ' ', 1)) + 1)), ''),
              private.app_num(v_item ->> 'guestCount')::integer, v_in, v_out, v_status, nullif(v_item ->> 'notes', ''))
      on conflict (organization_id, app_ref) where app_ref is not null do update set
        property_id = excluded.property_id, source = excluded.source,
        guest_first_name = excluded.guest_first_name, guest_last_name = excluded.guest_last_name,
        guest_count = excluded.guest_count, check_in = excluded.check_in, check_out = excluded.check_out,
        status = excluded.status, notes = excluded.notes;
    exception when exclusion_violation then
      -- Überschneidung mit einer anderen bestätigten Buchung: als Anfrage übernehmen
      insert into public.bookings (organization_id, property_id, app_ref, source, guest_first_name, guest_last_name,
                                   guest_count, check_in, check_out, status, notes)
      values (p_org, v_property, v_item ->> 'id', v_source,
              nullif(split_part(v_name, ' ', 1), ''), nullif(trim(substr(v_name, length(split_part(v_name, ' ', 1)) + 1)), ''),
              private.app_num(v_item ->> 'guestCount')::integer, v_in, v_out, 'inquiry',
              concat_ws(' · ', nullif(v_item ->> 'notes', ''), 'Überschneidet sich mit einer anderen Buchung'))
      on conflict (organization_id, app_ref) where app_ref is not null do update set
        status = 'inquiry', check_in = excluded.check_in, check_out = excluded.check_out, notes = excluded.notes;
    end;
    v_refs := v_refs || (v_item ->> 'id');
    v_count := v_count + 1;
  end loop;
  delete from public.bookings b
  where b.organization_id = p_org and b.app_ref is not null and not (b.app_ref = any (v_refs));
  return v_count;
end;
$$;

-- Aufgaben übernehmen
create or replace function private.project_app_tasks(p_org uuid, p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item     jsonb;
  v_count    integer := 0;
  v_refs     text[] := '{}';
  v_tz       text := (select o.timezone from public.organizations o where o.id = p_org);
  v_property uuid;
  v_booking  uuid;
  v_status   text;
begin
  for v_item in select * from jsonb_array_elements(p_items) loop
    continue when coalesce(v_item ->> 'id', '') = '' or coalesce(trim(v_item ->> 'title'), '') = '';
    select p.id into v_property from public.properties p
    where p.organization_id = p_org
      and (p.app_ref = v_item ->> 'propertyId' or (v_item ->> 'propertyId' is null and p.name = v_item ->> 'property'))
    order by (p.app_ref = v_item ->> 'propertyId') desc nulls last
    limit 1;
    continue when v_property is null;
    select b.id into v_booking from public.bookings b
    where b.organization_id = p_org and b.app_ref = v_item ->> 'bookingId';

    v_status := case
      when coalesce(v_item ->> 'done', '') = 'true' or v_item ->> 'status' ilike 'erledigt%' then 'completed'
      when v_item ->> 'status' ilike 'in bearbeitung%' then 'in_progress'
      when v_item ->> 'status' ilike 'storniert%' then 'cancelled'
      else 'pending' end;

    insert into public.service_tasks (organization_id, property_id, booking_id, app_ref, title, description,
                                      priority, status, scheduled_start)
    values (p_org, v_property, v_booking, v_item ->> 'id', trim(v_item ->> 'title'),
            nullif(concat_ws(E'\n', nullif(v_item ->> 'description', ''),
                             case when coalesce(v_item ->> 'area', '') <> '' then 'Bereich: ' || (v_item ->> 'area') end), ''),
            case v_item ->> 'priority' when 'urgent' then 'urgent' when 'soon' then 'high' when 'low' then 'low' else 'normal' end,
            v_status,
            private.app_ts(v_item ->> 'date', v_item ->> 'time', '09:00', v_tz))
    on conflict (organization_id, app_ref) where app_ref is not null do update set
      property_id = excluded.property_id, booking_id = excluded.booking_id, title = excluded.title,
      description = excluded.description, priority = excluded.priority, status = excluded.status,
      scheduled_start = excluded.scheduled_start;
    v_refs := v_refs || (v_item ->> 'id');
    v_count := v_count + 1;
  end loop;
  delete from public.service_tasks t
  where t.organization_id = p_org and t.app_ref is not null and not (t.app_ref = any (v_refs));
  return v_count;
end;
$$;

-- Trigger: nach jedem Upload die passenden Fachtabellen aktualisieren.
-- Fehler werden protokolliert, verhindern aber nie das Speichern der App-Daten.
create or replace function private.project_app_data()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_json   jsonb;
  v_count  integer;
  v_status text;
begin
  if new.key not in ('stugliv-properties', 'stugliv-bookings', 'stugliv-tasks') then
    return null;
  end if;
  begin
    v_json := new.value::jsonb;
    if jsonb_typeof(v_json) <> 'array' then
      v_status := 'übersprungen: keine Liste';
    elsif new.key = 'stugliv-properties' then
      v_count := private.project_app_properties(new.organization_id, v_json);
      v_status := v_count || ' Ferienhäuser übernommen';
      -- Buchungen und Aufgaben hängen an den Häusern: nach neuen Häusern erneut zuordnen
      update public.app_data set value = value
      where organization_id = new.organization_id and key in ('stugliv-bookings', 'stugliv-tasks');
    elsif new.key = 'stugliv-bookings' then
      v_count := private.project_app_bookings(new.organization_id, v_json);
      v_status := v_count || ' Buchungen übernommen';
      update public.app_data set value = value
      where organization_id = new.organization_id and key = 'stugliv-tasks';
    else
      v_count := private.project_app_tasks(new.organization_id, v_json);
      v_status := v_count || ' Aufgaben übernommen';
    end if;
  exception when others then
    v_status := 'Fehler: ' || left(sqlerrm, 500);
  end;
  update public.app_data set projection_status = v_status
  where organization_id = new.organization_id and key = new.key and projection_status is distinct from v_status;
  return null;
end;
$$;

create trigger app_data_project after insert or update of value on public.app_data
  for each row execute function private.project_app_data();

-- -----------------------------------------------------------------------------
-- Organisation des angemeldeten Benutzers (wird beim ersten Anmelden angelegt)
-- -----------------------------------------------------------------------------
create or replace function public.ensure_my_organization(p_name text default 'Meine Ferienhäuser')
returns table (organization_id uuid, name text, role text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := private.current_user_id();
  v_org  uuid;
begin
  if v_user is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;
  select m.organization_id into v_org
  from public.organization_members m
  where m.user_id = v_user and m.status = 'active'
  order by (m.role = 'admin') desc, m.created_at
  limit 1;

  if v_org is null then
    insert into public.organizations (name, country, currency, timezone)
    values (coalesce(nullif(trim(p_name), ''), 'Meine Ferienhäuser'), 'SE', 'EUR', 'Europe/Stockholm')
    returning id into v_org;
    -- private.add_creator_as_admin trägt den Benutzer als Admin ein
  end if;

  return query
    select o.id, o.name, m.role
    from public.organizations o
    join public.organization_members m on m.organization_id = o.id and m.user_id = v_user
    where o.id = v_org;
end;
$$;

revoke all on function public.ensure_my_organization(text) from public, anon;
grant execute on function public.ensure_my_organization(text) to authenticated, service_role;
grant execute on function private.app_data_stamp(), private.app_num(text), private.app_country(text),
  private.app_ts(text, text, text, text) to authenticated, service_role;
