-- =============================================================================
-- HUSORA · Phase 3: Rollen und Objektfreigabe
-- =============================================================================
-- Spezifikation §2 und §10:
--   * Rolle `contractor` (Subunternehmer): sieht nur ihm zugewiesene Aufträge – wie ein Techniker.
--   * public.property_service_assignments: der Hausbesitzer gibt einzelne Häuser für einen
--     verbundenen Servicepartner frei, mit Zugriffsstufe
--       basic   – Stammdaten des Hauses (Name, Adresse, Lage)
--       service – zusätzlich allgemeine Hausfotos, Ausstattung und technische Unterlagen
--                 (Anleitungen, Grundrisse, Energieausweis, Genehmigungen)
--       full    – zusätzlich alle Dokumente des Hauses (außer Rechnungen/Angebote anderer)
--                 und alle Hauskontrollen mit Ergebnissen
--   * Zugriff über Aufträge bleibt unverändert; Policies werden nur ergänzt (OR), nie eingeschränkt.
--   * Bestehende Verbindungen: Häuser mit Aufträgen werden mit Stufe `service` übernommen.
--   * Korrektur aus Phase 2: Wartestatus gelten überall als laufende Aufträge.
-- Idempotent.

-- -----------------------------------------------------------------------------
-- 1) Rolle Subunternehmer
-- -----------------------------------------------------------------------------
alter table public.organization_members drop constraint if exists organization_members_role_check;
alter table public.organization_members add constraint organization_members_role_check check (role in (
  'owner', 'admin', 'property_manager', 'service_manager', 'service_partner', 'cleaner', 'viewer',
  'dispatcher', 'technician', 'inspector', 'accounting', 'contractor'));
alter table public.organization_invites drop constraint if exists organization_invites_role_check;
alter table public.organization_invites add constraint organization_invites_role_check check (role in (
  'admin', 'dispatcher', 'service_manager', 'accounting', 'technician', 'inspector', 'viewer',
  'property_manager', 'owner', 'cleaner', 'contractor'));

-- -----------------------------------------------------------------------------
-- 2) Objektfreigaben
-- -----------------------------------------------------------------------------
create table if not exists public.property_service_assignments (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  property_id         uuid not null references public.properties(id) on delete cascade,
  service_partner_id  uuid not null references public.service_partners(id) on delete cascade,
  service_type_id     uuid references public.service_types(id) on delete set null,
  status              text not null default 'active' check (status in ('active', 'paused', 'ended')),
  access_level        text not null default 'service' check (access_level in ('basic', 'service', 'full')),
  start_date          date not null default current_date,
  end_date            date,
  notes               text check (notes is null or length(notes) <= 1000),
  created_by          uuid references public.users(id) on delete set null,
  updated_by          uuid references public.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (property_id, service_partner_id),
  check (end_date is null or end_date >= start_date)
);
comment on table public.property_service_assignments is 'Freigabe einzelner Häuser für einen verbundenen Servicepartner (Spezifikation §10)';
create index if not exists psa_org_idx on public.property_service_assignments (organization_id);
create index if not exists psa_partner_idx on public.property_service_assignments (service_partner_id) where status = 'active';
create index if not exists psa_type_idx on public.property_service_assignments (service_type_id) where service_type_id is not null;
create index if not exists psa_created_by_idx on public.property_service_assignments (created_by) where created_by is not null;
create index if not exists psa_updated_by_idx on public.property_service_assignments (updated_by) where updated_by is not null;

-- Haus und Partner müssen zur selben Organisation gehören; organization_id kommt immer vom Haus
create or replace function private.psa_check()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_org uuid := private.property_org(new.property_id);
begin
  if v_org is null then
    raise exception 'Haus nicht gefunden' using errcode = '23503';
  end if;
  new.organization_id := v_org;
  if not exists (select 1 from public.service_partners sp where sp.id = new.service_partner_id and sp.organization_id = v_org) then
    raise exception 'Der Servicepartner gehört nicht zu dieser Organisation' using errcode = '23503';
  end if;
  if tg_op = 'UPDATE' then
    new.property_id := old.property_id;
    new.service_partner_id := old.service_partner_id;
  end if;
  return new;
end;
$$;
drop trigger if exists psa_check on public.property_service_assignments;
create trigger psa_check before insert or update on public.property_service_assignments
  for each row execute function private.psa_check();
drop trigger if exists psa_set_updated_at on public.property_service_assignments;
create trigger psa_set_updated_at before update on public.property_service_assignments
  for each row execute function private.set_updated_at();
drop trigger if exists psa_set_actor on public.property_service_assignments;
create trigger psa_set_actor before insert or update on public.property_service_assignments
  for each row execute function private.set_actor_columns();
drop trigger if exists property_service_assignments_audit on public.property_service_assignments;
create trigger property_service_assignments_audit after insert or update or delete on public.property_service_assignments
  for each row execute function private.audit_row_change();

alter table public.property_service_assignments enable row level security;
drop policy if exists psa_select on public.property_service_assignments;
create policy psa_select on public.property_service_assignments for select to authenticated
  using (private.can_read_org(organization_id) or private.is_partner_member(service_partner_id));
drop policy if exists psa_insert on public.property_service_assignments;
create policy psa_insert on public.property_service_assignments for insert to authenticated
  with check (private.is_org_staff(organization_id));
drop policy if exists psa_update on public.property_service_assignments;
create policy psa_update on public.property_service_assignments for update to authenticated
  using (private.is_org_staff(organization_id)) with check (private.is_org_staff(organization_id));
drop policy if exists psa_delete on public.property_service_assignments;
create policy psa_delete on public.property_service_assignments for delete to authenticated
  using (private.is_org_staff(organization_id));
revoke all on public.property_service_assignments from anon;
grant select, insert, update, delete on public.property_service_assignments to authenticated;

-- Höchste aktive Zugriffsstufe der Partnerleitung des angemeldeten Nutzers für ein Haus (oder null).
-- Mitarbeiter, Techniker und Subunternehmer sehen Häuser weiterhin nur über ihre Aufträge.
create or replace function private.partner_property_level(p_property_id uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select case max(case a.access_level when 'full' then 3 when 'service' then 2 else 1 end)
           when 3 then 'full' when 2 then 'service' when 1 then 'basic' end
  from public.property_service_assignments a
  join public.service_partners sp on sp.id = a.service_partner_id
  where a.property_id = p_property_id
    and a.status = 'active'
    and a.start_date <= current_date
    and (a.end_date is null or a.end_date >= current_date)
    and sp.partner_organization_id is not null
    and private.is_partner_member(a.service_partner_id)
$$;
grant execute on function private.partner_property_level(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3) Policies ergänzen (zusätzliche OR-Bedingungen)
-- -----------------------------------------------------------------------------
drop policy if exists properties_select on public.properties;
create policy properties_select on public.properties for select to authenticated
  using (private.can_read_org(organization_id) or private.can_read_property(id)
         or private.partner_property_level(id) is not null);

drop policy if exists property_features_select on public.property_features;
create policy property_features_select on public.property_features for select to authenticated
  using (private.can_read_property(property_id) or private.partner_property_level(property_id) in ('service', 'full'));

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
        and (private.is_property_partner(property_id) or private.partner_property_level(property_id) in ('service', 'full')))
  );

drop policy if exists documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated
  using (
    private.can_read_org(organization_id)
    or uploaded_by = (select private.current_user_id())
    or (property_id is not null and private.is_property_owner(property_id))
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
    or (property_id is not null and service_order_id is null
        and document_type in ('manual', 'floor_plan', 'energy_certificate', 'permit')
        and private.partner_property_level(property_id) in ('service', 'full'))
    or (property_id is not null and service_order_id is null
        and document_type not in ('invoice', 'quote')
        and private.partner_property_level(property_id) = 'full')
  );

-- Hauskontrollen (und damit ihre Positionen und Fotos) bei Vollzugriff
create or replace function private.can_read_inspection(p_inspection_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.inspections i
    where i.id = p_inspection_id
      and (
        private.can_read_org(i.organization_id)
        or private.is_property_owner(i.property_id)
        or (i.inspector_user_id = private.current_user_id() and (private.is_org_member(i.organization_id) or private.is_partner_employee(i.service_partner_id)))
        or private.is_partner_member(i.service_partner_id)
        or (i.status <> 'cancelled' and private.partner_property_level(i.property_id) = 'full')
      )
  )
$$;

-- -----------------------------------------------------------------------------
-- 4) Korrektur Phase 2: Wartestatus zählen als laufende Aufträge
-- -----------------------------------------------------------------------------
create or replace function private.is_property_partner(p_property_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.service_orders o
    where o.property_id = p_property_id
      and o.status in ('offered', 'accepted', 'scheduled', 'in_progress', 'waiting_customer', 'waiting_parts', 'completed')
      and (private.is_partner_member(o.service_partner_id)
           or (o.assigned_user_id = private.current_user_id() and private.is_partner_employee(o.service_partner_id)))
  )
$$;

create or replace function public.order_access(p_service_order_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_order public.service_orders;
  v_share public.order_access_shares;
begin
  select * into v_order from public.service_orders o where o.id = p_service_order_id;
  if v_order.id is null then return null; end if;
  if not (private.is_org_staff(v_order.organization_id)
          or private.is_partner_member(v_order.service_partner_id)
          or (v_order.assigned_user_id = private.current_user_id() and private.is_partner_employee(v_order.service_partner_id))) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  if v_order.status not in ('accepted', 'scheduled', 'in_progress', 'waiting_customer', 'waiting_parts') and not private.is_org_staff(v_order.organization_id) then
    return null;
  end if;
  select * into v_share from public.order_access_shares s
  where s.service_order_id = v_order.id and s.revoked_at is null and s.valid_until > now()
  order by s.created_at desc limit 1;
  if v_share.id is null then return null; end if;
  if not private.is_org_staff(v_order.organization_id) then
    update public.order_access_shares set last_viewed_at = now(), view_count = view_count + 1 where id = v_share.id;
  end if;
  return jsonb_build_object('access_text', v_share.access_text, 'valid_until', v_share.valid_until, 'created_at', v_share.created_at);
end;
$$;
revoke all on function public.order_access(uuid) from public, anon;
grant execute on function public.order_access(uuid) to authenticated;

create or replace function public.respond_service_agreement(p_agreement_id uuid, p_accept boolean)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_ag public.service_agreements;
  v_side text;
begin
  select * into v_ag from public.service_agreements where id = p_agreement_id for update;
  if v_ag.id is null then raise exception 'Vertrag nicht gefunden' using errcode = 'P0002'; end if;
  if private.is_org_staff(v_ag.organization_id) then v_side := 'owner';
  elsif private.is_partner_member(v_ag.service_partner_id) then v_side := 'partner';
  else raise exception 'Keine Berechtigung' using errcode = '42501'; end if;
  if v_ag.status <> 'proposed' then raise exception 'Der Vertrag ist nicht mehr offen' using errcode = '22023'; end if;
  if v_ag.proposed_by = v_side then raise exception 'Den eigenen Vorschlag nimmt die andere Seite an' using errcode = '42501'; end if;
  update public.service_agreements set status = case when p_accept then 'active' else 'declined' end, responded_at = now()
  where id = v_ag.id returning * into v_ag;
  perform private.agreement_notify(v_ag, v_side = 'owner', case when p_accept then 'Jahresvertrag angenommen' else 'Jahresvertrag abgelehnt' end);
  if p_accept then
    update public.service_orders o set agreement_id = v_ag.id
    where o.organization_id = v_ag.organization_id and o.property_id = v_ag.property_id
      and o.service_partner_id = v_ag.service_partner_id and o.agreement_id is null
      and o.status in ('offered', 'accepted', 'scheduled', 'in_progress', 'waiting_customer', 'waiting_parts')
      and coalesce(o.scheduled_at, now())::date between v_ag.starts_on and v_ag.ends_on
      and private.agreement_covers(v_ag.task_titles, o.title)
      and not exists (select 1 from public.invoices i where i.service_order_id = o.id);
  end if;
  return v_ag.status;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5) Trennen beendet auch die Objektfreigaben
-- -----------------------------------------------------------------------------
create or replace function private.psa_end_on_disconnect()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.partner_organization_id is not null and new.partner_organization_id is null then
    update public.property_service_assignments a
    set status = 'ended', end_date = greatest(a.start_date, current_date)
    where a.service_partner_id = new.id and a.status <> 'ended';
  end if;
  return null;
end;
$$;
drop trigger if exists service_partners_end_assignments on public.service_partners;
create trigger service_partners_end_assignments after update of partner_organization_id on public.service_partners
  for each row execute function private.psa_end_on_disconnect();

-- -----------------------------------------------------------------------------
-- 6) Bestehende Verbindungen übernehmen: Häuser mit Aufträgen → Stufe „service“
-- -----------------------------------------------------------------------------
insert into public.property_service_assignments (organization_id, property_id, service_partner_id, access_level, start_date, notes)
select sp.organization_id, o.property_id, sp.id, 'service', min(o.created_at)::date, 'Aus bisherigen Aufträgen übernommen'
from public.service_orders o
join public.service_partners sp on sp.id = o.service_partner_id
join public.properties p on p.id = o.property_id and p.organization_id = sp.organization_id
where sp.partner_organization_id is not null
  and sp.partner_organization_id <> sp.organization_id
  and o.status not in ('draft', 'cancelled', 'rejected')
group by sp.organization_id, o.property_id, sp.id
on conflict (property_id, service_partner_id) do nothing;
