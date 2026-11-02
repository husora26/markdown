-- =============================================================================
-- HUSORA · Ergänzende Objektinfos des Servicepartners
-- =============================================================================
-- Der Servicepartner ergänzt ein übertragenes Haus mit eigenen Arbeitsinfos
-- (Schlüssel, Zugang, Technik, Entsorgung, Notizen). Die Daten gehören dem Partnerbetrieb
-- (organization_id = Partner-Organisation); das Haus des Kunden bleibt unverändert.
-- Lesen: Mitglieder des Partnerbetriebs, solange sie das Haus sehen dürfen.
-- Schreiben: Leitung/Disposition des Partnerbetriebs. Hausbesitzer sehen diese Notizen nicht.
-- Idempotent.

create table if not exists public.partner_property_notes (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  property_id      uuid not null references public.properties(id) on delete cascade,
  key_info         text check (key_info is null or length(key_info) <= 500),
  access_info      text check (access_info is null or length(access_info) <= 1000),
  technical_info   text check (technical_info is null or length(technical_info) <= 2000),
  waste_info       text check (waste_info is null or length(waste_info) <= 500),
  notes            text check (notes is null or length(notes) <= 4000),
  created_by       uuid references public.users(id) on delete set null,
  updated_by       uuid references public.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (organization_id, property_id)
);
comment on table public.partner_property_notes is 'Eigene Arbeitsinfos eines Servicepartners zu einem Haus (nur für den Partnerbetrieb sichtbar)';
create index if not exists ppn_property_idx on public.partner_property_notes (property_id);
create index if not exists ppn_created_by_idx on public.partner_property_notes (created_by) where created_by is not null;
create index if not exists ppn_updated_by_idx on public.partner_property_notes (updated_by) where updated_by is not null;

drop trigger if exists ppn_set_updated_at on public.partner_property_notes;
create trigger ppn_set_updated_at before update on public.partner_property_notes
  for each row execute function private.set_updated_at();
drop trigger if exists ppn_set_actor on public.partner_property_notes;
create trigger ppn_set_actor before insert or update on public.partner_property_notes
  for each row execute function private.set_actor_columns();
drop trigger if exists partner_property_notes_audit on public.partner_property_notes;
create trigger partner_property_notes_audit after insert or update or delete on public.partner_property_notes
  for each row execute function private.audit_row_change();

-- Haus darf nicht verschoben werden
create or replace function private.ppn_guard()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.organization_id := old.organization_id;
  new.property_id := old.property_id;
  return new;
end;
$$;
drop trigger if exists ppn_guard on public.partner_property_notes;
create trigger ppn_guard before update on public.partner_property_notes
  for each row execute function private.ppn_guard();

alter table public.partner_property_notes enable row level security;
drop policy if exists ppn_select on public.partner_property_notes;
create policy ppn_select on public.partner_property_notes for select to authenticated
  using (private.is_org_member(organization_id)
         and (private.can_read_property(property_id) or private.partner_property_level(property_id) is not null));
drop policy if exists ppn_insert on public.partner_property_notes;
create policy ppn_insert on public.partner_property_notes for insert to authenticated
  with check (private.has_org_role(organization_id, array['admin', 'service_manager', 'dispatcher'])
              and (private.can_read_property(property_id) or private.partner_property_level(property_id) is not null));
drop policy if exists ppn_update on public.partner_property_notes;
create policy ppn_update on public.partner_property_notes for update to authenticated
  using (private.has_org_role(organization_id, array['admin', 'service_manager', 'dispatcher']))
  with check (private.has_org_role(organization_id, array['admin', 'service_manager', 'dispatcher']));
drop policy if exists ppn_delete on public.partner_property_notes;
create policy ppn_delete on public.partner_property_notes for delete to authenticated
  using (private.has_org_role(organization_id, array['admin', 'service_manager', 'dispatcher']));
revoke all on public.partner_property_notes from anon;
grant select, insert, update, delete on public.partner_property_notes to authenticated;

-- -----------------------------------------------------------------------------
-- Mindestens ein Bild: Bei Freigabe „basic“ sieht der Partner das Titelbild des Hauses
-- (ältestes allgemeines Hausfoto). Ab „service“ und über Aufträge weiterhin alle Hausfotos.
-- -----------------------------------------------------------------------------
create or replace function private.property_cover_photo(p_property_id uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select ph.id from public.photos ph
  where ph.property_id = p_property_id
    and ph.inspection_id is null and ph.service_order_id is null and ph.service_task_id is null and ph.repair_id is null
  order by ph.created_at, ph.id
  limit 1
$$;
grant execute on function private.property_cover_photo(uuid) to authenticated, service_role;

drop policy if exists photos_select on public.photos;
create policy photos_select on public.photos for select to authenticated
  using (
    private.can_read_org(organization_id)
    or uploaded_by = (select private.current_user_id())
    or private.is_property_owner(property_id)
    or (inspection_id is not null and private.can_read_inspection(inspection_id))
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
    or (service_task_id is not null and private.can_read_task(service_task_id))
    or (repair_id is not null and private.can_read_repair(repair_id))
    or (property_id is not null and inspection_id is null and service_order_id is null and service_task_id is null and repair_id is null
        and (private.is_property_partner(property_id)
             or private.partner_property_level(property_id) in ('service', 'full')
             or (private.partner_property_level(property_id) = 'basic' and id = private.property_cover_photo(property_id))))
  );
