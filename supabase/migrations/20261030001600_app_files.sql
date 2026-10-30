-- =============================================================================
-- HUSORA · Migration 1600 · Dateien der App in Supabase Storage
-- =============================================================================
-- Die App lädt Fotos und Dokumente beim Cloud-Sync als echte Dateien in Storage
-- (husora-property-photos, husora-documents, husora-private) und ersetzt sie in
-- app_data durch Verweise der Form
--   husora-storage:<bucket>/organization/<org>/property/<haus>/<bereich>/<hash>.<ext>
-- Diese Migration legt dazu Metadaten in public.documents und public.photos an.

alter table public.documents add column app_ref text;
alter table public.photos    add column app_ref text;
comment on column public.documents.app_ref is 'ID des Dokuments in der Husora-App (Cloud-Sync).';
comment on column public.photos.app_ref is 'Herkunft in der Husora-App, z. B. <haus-id>:<datei> (Cloud-Sync).';
create unique index documents_app_ref_idx on public.documents (organization_id, app_ref) where app_ref is not null;
create unique index photos_app_ref_idx    on public.photos (organization_id, app_ref)    where app_ref is not null;

-- Verweis zerlegen: Bucket, Pfad und – falls vorhanden – Haus-UUID aus dem Pfad
create or replace function private.app_file_ref(p_ref text, out bucket text, out path text, out property_id uuid)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_rest text;
  v_parts text[];
begin
  if p_ref is null or p_ref !~ '^husora-storage:[a-z-]+/organization/' then
    return;
  end if;
  v_rest := substr(p_ref, length('husora-storage:') + 1);
  bucket := split_part(v_rest, '/', 1);
  path := substr(v_rest, length(bucket) + 2);
  v_parts := string_to_array(path, '/');
  if v_parts[3] = 'property' and v_parts[4] ~ '^[0-9a-f-]{36}$' then
    property_id := v_parts[4]::uuid;
  end if;
end;
$$;

create or replace function private.app_document_type(p_category text, p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when concat_ws(' ', p_category, p_name) ~* '(vertrag|contract|miet|pacht)' then 'contract'
    when concat_ws(' ', p_category, p_name) ~* '(rechnung|invoice|faktura|beleg)' then 'invoice'
    when concat_ws(' ', p_category, p_name) ~* '(angebot|offert|quote)' then 'quote'
    when concat_ws(' ', p_category, p_name) ~* '(versicherung|insurance|försäkring|police)' then 'insurance'
    when concat_ws(' ', p_category, p_name) ~* '(anleitung|handbuch|manual|bedienung)' then 'manual'
    when concat_ws(' ', p_category, p_name) ~* '(protokoll|kontroll|inspection|besiktning)' then 'inspection_report'
    when concat_ws(' ', p_category, p_name) ~* '(reparatur|repair)' then 'repair_report'
    when concat_ws(' ', p_category, p_name) ~* '(grundriss|plan|ritning)' then 'floor_plan'
    when concat_ws(' ', p_category, p_name) ~* '(energie|energy)' then 'energy_certificate'
    when concat_ws(' ', p_category, p_name) ~* '(genehmigung|permit|bygglov)' then 'permit'
    else 'other'
  end
$$;

-- Dokumente (stugliv-documents) → public.documents
create or replace function private.project_app_documents(p_org uuid, p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item  jsonb;
  v_file  record;
  v_count integer := 0;
  v_refs  text[] := '{}';
begin
  for v_item in select * from jsonb_array_elements(p_items) loop
    continue when coalesce(v_item ->> 'id', '') = '';
    select * into v_file from private.app_file_ref(v_item ->> 'dataUrl');
    continue when v_file.bucket is null or v_file.bucket not in ('husora-documents', 'husora-private', 'husora-public');
    begin
      insert into public.documents (organization_id, property_id, app_ref, file_name, file_type, file_size,
                                    storage_bucket, storage_path, document_type)
      values (p_org, v_file.property_id, v_item ->> 'id', coalesce(nullif(trim(v_item ->> 'name'), ''), 'Dokument'),
              nullif(v_item ->> 'type', ''), private.app_num(v_item ->> 'size')::bigint,
              v_file.bucket, v_file.path, private.app_document_type(v_item ->> 'category', v_item ->> 'name'))
      on conflict (organization_id, app_ref) where app_ref is not null do update set
        property_id = excluded.property_id, file_name = excluded.file_name, file_type = excluded.file_type,
        file_size = excluded.file_size, storage_bucket = excluded.storage_bucket, storage_path = excluded.storage_path,
        document_type = excluded.document_type;
      v_refs := v_refs || (v_item ->> 'id');
      v_count := v_count + 1;
    exception when unique_violation then
      null;  -- gleiche Datei mehrfach in der App: ein Eintrag genügt
    end;
  end loop;
  delete from public.documents d
  where d.organization_id = p_org and d.app_ref is not null and not (d.app_ref = any (v_refs));
  return v_count;
end;
$$;

-- Hausfotos (stugliv-properties → photo / photos[]) → public.photos
create or replace function private.project_app_photos(p_org uuid, p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ref   record;
  v_file  record;
  v_count integer := 0;
  v_refs  text[] := '{}';
  v_app   text;
begin
  for v_ref in
    select distinct p ->> 'id' as property_ref, p ->> 'name' as property_name, f.value as ref
    from jsonb_array_elements(p_items) p
    cross join lateral (
      select jsonb_array_elements_text(case when jsonb_typeof(p -> 'photos') = 'array' then p -> 'photos' else '[]'::jsonb end)
      union all
      select p ->> 'photo'
    ) f(value)
    where f.value like 'husora-storage:husora-property-photos/%'
  loop
    select * into v_file from private.app_file_ref(v_ref.ref);
    continue when v_file.property_id is null;
    v_app := v_ref.property_ref || ':' || regexp_replace(v_file.path, '^.*/', '');
    begin
      insert into public.photos (organization_id, property_id, app_ref, storage_bucket, storage_path, caption)
      values (p_org, v_file.property_id, v_app, v_file.bucket, v_file.path, v_ref.property_name)
      on conflict (organization_id, app_ref) where app_ref is not null do update set
        storage_bucket = excluded.storage_bucket, storage_path = excluded.storage_path, caption = excluded.caption;
      v_refs := v_refs || v_app;
      v_count := v_count + 1;
    exception when unique_violation or foreign_key_violation or check_violation then
      null;
    end;
  end loop;
  delete from public.photos ph
  where ph.organization_id = p_org and ph.app_ref is not null and not (ph.app_ref = any (v_refs));
  return v_count;
end;
$$;

-- Übernahme-Trigger um Dokumente und Fotos erweitern
create or replace function private.project_app_data()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_json   jsonb;
  v_count  integer;
  v_photos integer;
  v_status text;
begin
  if new.key not in ('stugliv-properties', 'stugliv-bookings', 'stugliv-tasks', 'stugliv-documents') then
    return null;
  end if;
  begin
    v_json := new.value::jsonb;
    if jsonb_typeof(v_json) <> 'array' then
      v_status := 'übersprungen: keine Liste';
    elsif new.key = 'stugliv-properties' then
      v_count := private.project_app_properties(new.organization_id, v_json);
      v_photos := private.project_app_photos(new.organization_id, v_json);
      v_status := v_count || ' Ferienhäuser' || case when v_photos > 0 then ', ' || v_photos || ' Fotos' else '' end || ' übernommen';
      update public.app_data set value = value
      where organization_id = new.organization_id and key in ('stugliv-bookings', 'stugliv-tasks', 'stugliv-documents');
    elsif new.key = 'stugliv-bookings' then
      v_count := private.project_app_bookings(new.organization_id, v_json);
      v_status := v_count || ' Buchungen übernommen';
      update public.app_data set value = value
      where organization_id = new.organization_id and key = 'stugliv-tasks';
    elsif new.key = 'stugliv-documents' then
      v_count := private.project_app_documents(new.organization_id, v_json);
      v_status := v_count || ' Dokumente übernommen';
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

grant execute on function private.app_file_ref(text), private.app_document_type(text, text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Speicherverbrauch für die Anzeige in der App
-- Grenzen: Supabase Free-Plan (500 MB Datenbank, 1 GB Dateien); anpassbar über
-- organizations.settings -> 'storage_limits' -> {"database_mb": …, "files_mb": …}
-- -----------------------------------------------------------------------------
create or replace function public.my_cloud_usage(p_organization_id uuid)
returns table (
  app_data_bytes  bigint,
  file_count      bigint,
  file_bytes      bigint,
  database_bytes  bigint,
  database_limit  bigint,
  files_limit     bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limits jsonb;
begin
  if not private.can_read_org(p_organization_id) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  select coalesce(o.settings -> 'storage_limits', '{}'::jsonb) into v_limits from public.organizations o where o.id = p_organization_id;
  return query
    select
      (select coalesce(sum(a.size_bytes), 0)::bigint from public.app_data a where a.organization_id = p_organization_id),
      (select count(*) from storage.objects so where so.name like 'organization/' || p_organization_id::text || '/%'),
      (select coalesce(sum((so.metadata ->> 'size')::bigint), 0)::bigint from storage.objects so
        where so.name like 'organization/' || p_organization_id::text || '/%'),
      pg_database_size(current_database()),
      coalesce((v_limits ->> 'database_mb')::bigint, 500) * 1024 * 1024,
      coalesce((v_limits ->> 'files_mb')::bigint, 1024) * 1024 * 1024;
end;
$$;
revoke all on function public.my_cloud_usage(uuid) from public, anon;
grant execute on function public.my_cloud_usage(uuid) to authenticated, service_role;
