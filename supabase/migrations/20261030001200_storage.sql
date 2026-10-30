-- =============================================================================
-- HUSORA · Migration 1200 · Supabase Storage: Buckets und Zugriffsregeln
-- =============================================================================
-- Pfadkonvention (alle Buckets):
--   organization/{organization_id}/property/{property_id}/photos/…
--   organization/{organization_id}/property/{property_id}/documents/…
--   organization/{organization_id}/property/{property_id}/inspections/…
--   organization/{organization_id}/property/{property_id}/repairs/…
--   organization/{organization_id}/documents/…          (ohne Hausbezug)
-- Nur husora-public ist öffentlich. Private Dateien sind nie öffentlich erreichbar;
-- Zugriff erfolgt über RLS bzw. kurzlebige signierte URLs.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('husora-public',          'husora-public',          true,  5242880,
     array['image/jpeg', 'image/png', 'image/webp', 'image/svg+xml']),
  ('husora-private',         'husora-private',         false, 52428800, null),
  ('husora-documents',       'husora-documents',       false, 52428800,
     array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'text/plain', 'text/csv',
           'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
           'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']),
  ('husora-property-photos', 'husora-property-photos', false, 15728640,
     array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Pfad zerlegen: organization / {org} / property / {property} / {bereich} / datei
create or replace function private.storage_path_parts(p_name text, out organization_id uuid, out property_id uuid, out area text)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_parts text[] := string_to_array(p_name, '/');
  v_uuid  text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
begin
  if p_name like '%..%' or p_name like '/%' or v_parts[1] is distinct from 'organization' or v_parts[2] !~ v_uuid then
    return;
  end if;
  organization_id := v_parts[2]::uuid;
  if v_parts[3] = 'property' and array_length(v_parts, 1) >= 6 and v_parts[4] ~ v_uuid
     and v_parts[5] in ('photos', 'documents', 'inspections', 'repairs') then
    property_id := v_parts[4]::uuid;
    area := v_parts[5];
  elsif v_parts[3] = 'documents' and array_length(v_parts, 1) >= 4 then
    area := 'org_documents';
  else
    organization_id := null;  -- ungültiger Pfad
  end if;
end;
$$;

-- Bereich passt zum Bucket?
create or replace function private.storage_area_allowed(p_bucket text, p_area text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case p_bucket
    when 'husora-property-photos' then p_area in ('photos', 'inspections', 'repairs')
    when 'husora-documents'       then p_area in ('documents', 'inspections', 'repairs', 'org_documents')
    when 'husora-private'         then p_area is not null
    when 'husora-public'          then p_area is not null
    else false
  end
$$;

-- Lesen: Verwaltung/viewer der Organisation oder Eigentümer des Hauses
create or replace function private.storage_can_read(p_bucket text, p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select private.can_read_org(sp.organization_id)
        or (sp.property_id is not null
            and private.property_org(sp.property_id) = sp.organization_id
            and private.is_property_owner(sp.property_id))
    from private.storage_path_parts(p_name) sp
    where sp.organization_id is not null
  ), false)
$$;

-- Hochladen: gültiger Pfad + Verwaltung, Eigentümer/Hausverwalter oder Person/Partner
-- mit Arbeit an diesem Haus (Fotos, Kontroll- und Reparaturbelege). viewer nie.
create or replace function private.storage_can_write(p_bucket text, p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select private.storage_area_allowed(p_bucket, sp.area)
       and (
         private.is_org_staff(sp.organization_id)
         or (p_bucket <> 'husora-public'
             and sp.property_id is not null
             and private.property_org(sp.property_id) = sp.organization_id
             and (
               private.can_manage_property(sp.property_id)
               or (private.can_read_property(sp.property_id)
                   and coalesce(private.org_role(sp.organization_id), '') <> 'viewer'
                   and sp.area in ('photos', 'inspections', 'repairs', 'documents'))
             ))
       )
    from private.storage_path_parts(p_name) sp
    where sp.organization_id is not null
  ), false)
$$;

grant execute on function private.storage_path_parts(text), private.storage_area_allowed(text, text),
  private.storage_can_read(text, text), private.storage_can_write(text, text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Policies auf storage.objects
-- -----------------------------------------------------------------------------
-- Öffentlicher Bucket: lesen für alle, schreiben nur Verwaltung
create policy husora_public_read on storage.objects for select to anon, authenticated
  using (bucket_id = 'husora-public');
create policy husora_public_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'husora-public' and private.storage_can_write(bucket_id, name));
create policy husora_public_update on storage.objects for update to authenticated
  using (bucket_id = 'husora-public' and private.storage_can_write(bucket_id, name))
  with check (bucket_id = 'husora-public' and private.storage_can_write(bucket_id, name));
create policy husora_public_delete on storage.objects for delete to authenticated
  using (bucket_id = 'husora-public' and private.storage_can_write(bucket_id, name));

-- Private Buckets: lesen nur mit Berechtigung. Zusätzlich darf lesen, wer den zugehörigen
-- Datensatz in public.photos / public.documents sehen darf (dort greift deren RLS).
create policy husora_private_read on storage.objects for select to authenticated
  using (
    bucket_id in ('husora-private', 'husora-documents', 'husora-property-photos')
    and (
      private.storage_can_read(bucket_id, name)
      or owner_id = (select auth.uid())::text
      or exists (select 1 from public.photos p where p.storage_bucket = bucket_id and p.storage_path = name)
      or exists (select 1 from public.documents d where d.storage_bucket = bucket_id and d.storage_path = name)
    )
  );
create policy husora_private_insert on storage.objects for insert to authenticated
  with check (
    bucket_id in ('husora-private', 'husora-documents', 'husora-property-photos')
    and private.storage_can_write(bucket_id, name)
  );
create policy husora_private_update on storage.objects for update to authenticated
  using (
    bucket_id in ('husora-private', 'husora-documents', 'husora-property-photos')
    and (owner_id = (select auth.uid())::text
         or private.is_org_staff((private.storage_path_parts(name)).organization_id))
  )
  with check (
    bucket_id in ('husora-private', 'husora-documents', 'husora-property-photos')
    and private.storage_can_write(bucket_id, name)
  );
create policy husora_private_delete on storage.objects for delete to authenticated
  using (
    bucket_id in ('husora-private', 'husora-documents', 'husora-property-photos')
    and (owner_id = (select auth.uid())::text
         or private.is_org_staff((private.storage_path_parts(name)).organization_id))
  );
