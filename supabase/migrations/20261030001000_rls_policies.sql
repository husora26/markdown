-- =============================================================================
-- HUSORA · Migration 1000 · Row Level Security
-- =============================================================================
-- Grundregel: Zugriff nur auf Zeilen von Organisationen, in denen der Benutzer
-- aktives Mitglied ist. Darüber hinaus:
--   owner            → nur eigene Häuser (properties.owner_user_id / property_users)
--   service_partner  → nur zugewiesene Aufträge, Aufgaben und Kontrollen seines Betriebs
--   cleaner          → nur ihm zugewiesene Aufgaben (+ Lesezugriff auf das Haus)
--   viewer           → alles der Organisation lesen, nichts ändern
--   admin / property_manager / service_manager → alle Daten der Organisation
--   Super-Admin      → interne Husora-Verwaltung (alle Organisationen)
-- Hilfsfunktionen liegen im nicht veröffentlichten Schema "private" (security definer,
-- dadurch keine rekursiven Policies). Argumentlose Aufrufe stehen in (select …),
-- damit Postgres sie je Abfrage nur einmal auswertet.

-- -----------------------------------------------------------------------------
-- Weitere Zugriffs-Helfer
-- -----------------------------------------------------------------------------
create or replace function private.shares_org_with(p_user_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.organization_members m
    where m.user_id = p_user_id
      and m.organization_id in (select private.my_organization_ids())
  )
$$;

create or replace function private.is_user_in_org(p_user_id uuid, p_organization_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.organization_members m
    where m.user_id = p_user_id and m.organization_id = p_organization_id and m.status = 'active'
  )
$$;

create or replace function private.template_org(p_template_id uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$ select t.organization_id from public.inspection_templates t where t.id = p_template_id $$;

create or replace function private.inspection_org(p_inspection_id uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$ select i.organization_id from public.inspections i where i.id = p_inspection_id $$;

-- Aufgabe sehen: Verwaltung/viewer, Eigentümer, eingeteilte Person, beauftragter Partner
create or replace function private.can_read_task(p_service_task_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.service_tasks t
    where t.id = p_service_task_id
      and (
        private.can_read_org(t.organization_id)
        or private.is_property_owner(t.property_id)
        or (t.assigned_user_id = private.current_user_id() and private.is_org_member(t.organization_id))
        or private.is_partner_member(t.assigned_partner_id)
      )
  )
$$;

-- Partnerbetrieb sehen: Verwaltung/viewer, eigene Mitarbeiter, Eigentümer mit Auftrag dieses Partners
create or replace function private.can_read_partner(p_service_partner_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.can_read_org(private.partner_org(p_service_partner_id))
      or private.is_partner_member(p_service_partner_id)
      or exists (
        select 1 from public.service_orders o
        where o.service_partner_id = p_service_partner_id and private.is_property_owner(o.property_id)
      )
$$;

-- -----------------------------------------------------------------------------
-- Spalten-Schutz für Rollen mit eingeschränktem Schreibrecht
-- -----------------------------------------------------------------------------
-- Eigentümer/Hausverwalter dürfen Hausdaten pflegen, aber nicht Organisation oder Eigentümer ändern
create or replace function private.properties_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_system_context() and not private.is_org_staff(old.organization_id) then
    new.organization_id := old.organization_id;
    new.owner_user_id := old.owner_user_id;
    new.status := case when new.status = 'archived' then old.status else new.status end;
  end if;
  return new;
end;
$$;
create trigger properties_guard before update on public.properties
  for each row execute function private.properties_guard();

-- Partner pflegen ihr Profil; Status, Bewertung und interne Notizen bleiben der Verwaltung vorbehalten
create or replace function private.service_partners_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_system_context() and not private.is_org_staff(old.organization_id) then
    new.organization_id := old.organization_id;
    new.status := old.status;
    new.rating := old.rating;
    new.notes := old.notes;
  end if;
  return new;
end;
$$;
create trigger service_partners_guard before update on public.service_partners
  for each row execute function private.service_partners_guard();

-- Prüfer (Mitarbeiter/Partner) dürfen nur Ablauf und Ergebnis der Kontrolle ändern
create or replace function private.inspections_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status   text;
  v_started  timestamptz;
  v_done     timestamptz;
  v_overall  text;
  v_notes    text;
begin
  if not private.is_system_context()
     and not private.is_org_staff(old.organization_id)
     and not private.can_manage_property(old.property_id) then
    if new.status is distinct from old.status and new.status not in ('in_progress', 'completed') then
      raise exception 'Status "%" darf nur von der Verwaltung gesetzt werden', new.status using errcode = '42501';
    end if;
    v_status := new.status; v_started := new.started_at; v_done := new.completed_at;
    v_overall := new.overall_status; v_notes := new.notes;
    new := old;
    new.status := v_status; new.started_at := v_started; new.completed_at := v_done;
    new.overall_status := v_overall; new.notes := v_notes;
  end if;
  if new.status = 'in_progress' then
    new.started_at := coalesce(new.started_at, now());
  elsif new.status = 'completed' then
    new.started_at := coalesce(new.started_at, now());
    new.completed_at := coalesce(new.completed_at, now());
  end if;
  return new;
end;
$$;
create trigger inspections_guard before update on public.inspections
  for each row execute function private.inspections_guard();

-- Prüfpunkt: geprüft von / am automatisch setzen
create or replace function private.inspection_items_checked()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status <> 'not_checked' and (tg_op = 'INSERT' or new.status is distinct from old.status) then
    new.checked_at := now();
    new.checked_by := coalesce(private.current_user_id(), new.checked_by);
  elsif new.status = 'not_checked' then
    new.checked_at := null;
    new.checked_by := null;
  end if;
  return new;
end;
$$;
create trigger inspection_items_checked before insert or update of status on public.inspection_items
  for each row execute function private.inspection_items_checked();

-- Letzter aktiver Admin einer Organisation darf nicht entfernt oder herabgestuft werden
create or replace function private.keep_last_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.role = 'admin' and old.status = 'active'
     and (tg_op = 'DELETE' or new.role <> 'admin' or new.status <> 'active')
     and exists (select 1 from public.organizations o where o.id = old.organization_id)
     and not exists (
       select 1 from public.organization_members m
       where m.organization_id = old.organization_id and m.id <> old.id and m.role = 'admin' and m.status = 'active'
     ) then
    if pg_trigger_depth() > 1 then
      return coalesce(new, old);  -- Organisation wird gerade gelöscht (cascade)
    end if;
    raise exception 'Die Organisation braucht mindestens einen aktiven Admin' using errcode = '23514';
  end if;
  return coalesce(new, old);
end;
$$;
create trigger organization_members_keep_last_admin before update or delete on public.organization_members
  for each row execute function private.keep_last_admin();

-- -----------------------------------------------------------------------------
-- RLS aktivieren – ausnahmslos auf jeder Tabelle
-- -----------------------------------------------------------------------------
alter table public.users                    enable row level security;
alter table public.organizations            enable row level security;
alter table public.organization_members     enable row level security;
alter table public.properties               enable row level security;
alter table public.property_users           enable row level security;
alter table public.property_features        enable row level security;
alter table public.service_types            enable row level security;
alter table public.service_partners         enable row level security;
alter table public.service_partner_users    enable row level security;
alter table public.service_partner_services enable row level security;
alter table public.service_partner_areas    enable row level security;
alter table public.booking_sources          enable row level security;
alter table public.bookings                 enable row level security;
alter table public.inspection_templates     enable row level security;
alter table public.inspection_template_items enable row level security;
alter table public.inspections              enable row level security;
alter table public.inspection_items         enable row level security;
alter table public.service_tasks            enable row level security;
alter table public.service_orders           enable row level security;
alter table public.maintenance              enable row level security;
alter table public.repairs                  enable row level security;
alter table public.documents                enable row level security;
alter table public.photos                   enable row level security;
alter table public.quotes                   enable row level security;
alter table public.invoices                 enable row level security;
alter table public.automation_rules         enable row level security;
alter table public.automation_runs          enable row level security;
alter table public.notifications            enable row level security;
alter table public.messages                 enable row level security;
alter table public.audit_logs               enable row level security;
alter table public.webhook_endpoints        enable row level security;
alter table public.webhook_events           enable row level security;

-- -----------------------------------------------------------------------------
-- users
-- -----------------------------------------------------------------------------
create policy users_select on public.users for select to authenticated
  using (id = (select private.current_user_id()) or (select private.is_super_admin()) or private.shares_org_with(id));
create policy users_update_self on public.users for update to authenticated
  using (id = (select private.current_user_id()))
  with check (id = (select private.current_user_id()));
-- insert/delete: nur über Auth-Trigger bzw. service_role

-- -----------------------------------------------------------------------------
-- organizations / organization_members
-- -----------------------------------------------------------------------------
create policy organizations_select on public.organizations for select to authenticated
  using (private.is_org_member(id));
create policy organizations_insert on public.organizations for insert to authenticated
  with check ((select private.current_user_id()) is not null);
create policy organizations_update on public.organizations for update to authenticated
  using (private.is_org_admin(id)) with check (private.is_org_admin(id));
create policy organizations_delete on public.organizations for delete to authenticated
  using ((select private.is_super_admin()));

create policy organization_members_select on public.organization_members for select to authenticated
  using (user_id = (select private.current_user_id()) or private.can_read_org(organization_id));
create policy organization_members_insert on public.organization_members for insert to authenticated
  with check (private.is_org_admin(organization_id));
create policy organization_members_update on public.organization_members for update to authenticated
  using (private.is_org_admin(organization_id)) with check (private.is_org_admin(organization_id));
create policy organization_members_delete on public.organization_members for delete to authenticated
  using (private.is_org_admin(organization_id) or user_id = (select private.current_user_id()));

-- -----------------------------------------------------------------------------
-- properties, property_users, property_features
-- -----------------------------------------------------------------------------
create policy properties_select on public.properties for select to authenticated
  using (private.can_read_property(id));
create policy properties_insert on public.properties for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy properties_update on public.properties for update to authenticated
  using (private.can_manage_property(id)) with check (private.can_manage_property(id));
create policy properties_delete on public.properties for delete to authenticated
  using (private.is_org_admin(organization_id));

create policy property_users_select on public.property_users for select to authenticated
  using (user_id = (select private.current_user_id()) or private.can_manage_property(property_id)
         or private.can_read_org(private.property_org(property_id)));
create policy property_users_insert on public.property_users for insert to authenticated
  with check (private.is_org_staff(private.property_org(property_id)) or private.is_property_owner(property_id));
create policy property_users_update on public.property_users for update to authenticated
  using (private.is_org_staff(private.property_org(property_id)) or private.is_property_owner(property_id))
  with check (private.is_org_staff(private.property_org(property_id)) or private.is_property_owner(property_id));
create policy property_users_delete on public.property_users for delete to authenticated
  using (private.is_org_staff(private.property_org(property_id)) or private.is_property_owner(property_id));

create policy property_features_select on public.property_features for select to authenticated
  using (private.can_read_property(property_id));
create policy property_features_insert on public.property_features for insert to authenticated
  with check (private.can_manage_property(property_id));
create policy property_features_update on public.property_features for update to authenticated
  using (private.can_manage_property(property_id)) with check (private.can_manage_property(property_id));
create policy property_features_delete on public.property_features for delete to authenticated
  using (private.can_manage_property(property_id));

-- -----------------------------------------------------------------------------
-- service_types (global lesbar, global nur Super-Admin schreibbar)
-- -----------------------------------------------------------------------------
create policy service_types_select on public.service_types for select to authenticated
  using (organization_id is null or private.is_org_member(organization_id));
create policy service_types_insert on public.service_types for insert to authenticated
  with check (case when organization_id is null then (select private.is_super_admin()) else private.is_org_staff(organization_id) end);
create policy service_types_update on public.service_types for update to authenticated
  using (case when organization_id is null then (select private.is_super_admin()) else private.is_org_staff(organization_id) end)
  with check (case when organization_id is null then (select private.is_super_admin()) else private.is_org_staff(organization_id) end);
create policy service_types_delete on public.service_types for delete to authenticated
  using (case when organization_id is null then (select private.is_super_admin()) else private.is_org_staff(organization_id) end);

-- -----------------------------------------------------------------------------
-- service_partners und Unterlagen
-- -----------------------------------------------------------------------------
create policy service_partners_select on public.service_partners for select to authenticated
  using (private.can_read_org(organization_id) or private.can_read_partner(id));
create policy service_partners_insert on public.service_partners for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy service_partners_update on public.service_partners for update to authenticated
  using (private.is_org_staff(organization_id) or private.is_partner_member(id))
  with check (private.is_org_staff(organization_id) or private.is_partner_member(id));
create policy service_partners_delete on public.service_partners for delete to authenticated
  using (private.is_org_staff(organization_id));

create policy service_partner_users_select on public.service_partner_users for select to authenticated
  using (user_id = (select private.current_user_id()) or private.is_partner_member(service_partner_id)
         or private.can_read_org(private.partner_org(service_partner_id)));
create policy service_partner_users_insert on public.service_partner_users for insert to authenticated
  with check (private.is_org_staff(private.partner_org(service_partner_id)));
create policy service_partner_users_update on public.service_partner_users for update to authenticated
  using (private.is_org_staff(private.partner_org(service_partner_id)))
  with check (private.is_org_staff(private.partner_org(service_partner_id)));
create policy service_partner_users_delete on public.service_partner_users for delete to authenticated
  using (private.is_org_staff(private.partner_org(service_partner_id)));

create policy service_partner_services_select on public.service_partner_services for select to authenticated
  using (private.can_read_partner(service_partner_id));
create policy service_partner_services_insert on public.service_partner_services for insert to authenticated
  with check (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id));
create policy service_partner_services_update on public.service_partner_services for update to authenticated
  using (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id))
  with check (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id));
create policy service_partner_services_delete on public.service_partner_services for delete to authenticated
  using (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id));

create policy service_partner_areas_select on public.service_partner_areas for select to authenticated
  using (private.can_read_partner(service_partner_id));
create policy service_partner_areas_insert on public.service_partner_areas for insert to authenticated
  with check (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id));
create policy service_partner_areas_update on public.service_partner_areas for update to authenticated
  using (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id))
  with check (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id));
create policy service_partner_areas_delete on public.service_partner_areas for delete to authenticated
  using (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id));

-- -----------------------------------------------------------------------------
-- booking_sources, bookings (Gästedaten: nur Verwaltung, viewer und Eigentümer)
-- -----------------------------------------------------------------------------
create policy booking_sources_select on public.booking_sources for select to authenticated
  using (private.can_read_org(organization_id));
create policy booking_sources_insert on public.booking_sources for insert to authenticated
  with check (private.is_org_admin(organization_id));
create policy booking_sources_update on public.booking_sources for update to authenticated
  using (private.is_org_admin(organization_id)) with check (private.is_org_admin(organization_id));
create policy booking_sources_delete on public.booking_sources for delete to authenticated
  using (private.is_org_admin(organization_id));

create policy bookings_select on public.bookings for select to authenticated
  using (private.can_read_org(organization_id) or private.is_property_owner(property_id));
create policy bookings_insert on public.bookings for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy bookings_update on public.bookings for update to authenticated
  using (private.is_org_staff(organization_id) or private.can_manage_property(property_id))
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy bookings_delete on public.bookings for delete to authenticated
  using (private.is_org_staff(organization_id));

-- -----------------------------------------------------------------------------
-- Hauskontrollen
-- -----------------------------------------------------------------------------
create policy inspection_templates_select on public.inspection_templates for select to authenticated
  using (private.is_org_member(organization_id));
create policy inspection_templates_insert on public.inspection_templates for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy inspection_templates_update on public.inspection_templates for update to authenticated
  using (private.is_org_staff(organization_id)) with check (private.is_org_staff(organization_id));
create policy inspection_templates_delete on public.inspection_templates for delete to authenticated
  using (private.is_org_staff(organization_id));

create policy inspection_template_items_select on public.inspection_template_items for select to authenticated
  using (private.is_org_member(private.template_org(template_id)));
create policy inspection_template_items_insert on public.inspection_template_items for insert to authenticated
  with check (private.is_org_staff(private.template_org(template_id)));
create policy inspection_template_items_update on public.inspection_template_items for update to authenticated
  using (private.is_org_staff(private.template_org(template_id)))
  with check (private.is_org_staff(private.template_org(template_id)));
create policy inspection_template_items_delete on public.inspection_template_items for delete to authenticated
  using (private.is_org_staff(private.template_org(template_id)));

create policy inspections_select on public.inspections for select to authenticated
  using (
    private.can_read_org(organization_id)
    or private.is_property_owner(property_id)
    or (inspector_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
    or private.is_partner_member(service_partner_id)
  );
create policy inspections_insert on public.inspections for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy inspections_update on public.inspections for update to authenticated
  using (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or (inspector_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
    or private.is_partner_member(service_partner_id)
  )
  with check (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or (inspector_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
    or private.is_partner_member(service_partner_id)
  );
create policy inspections_delete on public.inspections for delete to authenticated
  using (private.is_org_staff(organization_id));

create policy inspection_items_select on public.inspection_items for select to authenticated
  using (private.can_read_inspection(inspection_id));
create policy inspection_items_insert on public.inspection_items for insert to authenticated
  with check (private.can_work_inspection(inspection_id));
create policy inspection_items_update on public.inspection_items for update to authenticated
  using (private.can_work_inspection(inspection_id)) with check (private.can_work_inspection(inspection_id));
create policy inspection_items_delete on public.inspection_items for delete to authenticated
  using (private.is_org_staff(private.inspection_org(inspection_id)));

-- -----------------------------------------------------------------------------
-- service_tasks (cleaner: nur eigene Aufgaben)
-- -----------------------------------------------------------------------------
create policy service_tasks_select on public.service_tasks for select to authenticated
  using (
    private.can_read_org(organization_id)
    or private.is_property_owner(property_id)
    or (assigned_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
    or private.is_partner_member(assigned_partner_id)
  );
create policy service_tasks_insert on public.service_tasks for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy service_tasks_update on public.service_tasks for update to authenticated
  using (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or (assigned_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
    or private.is_partner_member(assigned_partner_id)
  )
  with check (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or (assigned_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
    or private.is_partner_member(assigned_partner_id)
  );
create policy service_tasks_delete on public.service_tasks for delete to authenticated
  using (private.is_org_staff(organization_id));

-- -----------------------------------------------------------------------------
-- service_orders (service_partner: nur Aufträge seines Betriebs, keine Entwürfe)
-- -----------------------------------------------------------------------------
create policy service_orders_select on public.service_orders for select to authenticated
  using (
    private.can_read_org(organization_id)
    or private.is_property_owner(property_id)
    or (status <> 'draft' and private.is_partner_member(service_partner_id))
  );
create policy service_orders_insert on public.service_orders for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy service_orders_update on public.service_orders for update to authenticated
  using (private.is_org_staff(organization_id) or (status <> 'draft' and private.is_partner_member(service_partner_id)))
  with check (private.is_org_staff(organization_id) or private.is_partner_member(service_partner_id));
create policy service_orders_delete on public.service_orders for delete to authenticated
  using (private.is_org_staff(organization_id));

-- -----------------------------------------------------------------------------
-- maintenance, repairs
-- -----------------------------------------------------------------------------
create policy maintenance_select on public.maintenance for select to authenticated
  using (private.can_read_org(organization_id) or private.is_property_owner(property_id)
         or private.is_partner_member(assigned_partner_id));
create policy maintenance_insert on public.maintenance for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy maintenance_update on public.maintenance for update to authenticated
  using (private.is_org_staff(organization_id) or private.can_manage_property(property_id))
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy maintenance_delete on public.maintenance for delete to authenticated
  using (private.is_org_staff(organization_id));

create policy repairs_select on public.repairs for select to authenticated
  using (
    private.can_read_org(organization_id)
    or private.is_property_owner(property_id)
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
    or (inspection_id is not null and private.can_read_inspection(inspection_id))
  );
-- Melden: Verwaltung, Eigentümer/Hausverwalter oder Prüfer während der Kontrolle
create policy repairs_insert on public.repairs for insert to authenticated
  with check (
    private.is_org_staff(organization_id)
    or (status = 'reported' and (
          private.can_manage_property(property_id)
          or (inspection_id is not null and private.can_work_inspection(inspection_id))))
  );
create policy repairs_update on public.repairs for update to authenticated
  using (private.is_org_staff(organization_id) or private.can_manage_property(property_id))
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy repairs_delete on public.repairs for delete to authenticated
  using (private.is_org_staff(organization_id));

-- -----------------------------------------------------------------------------
-- documents, photos
-- -----------------------------------------------------------------------------
create policy documents_select on public.documents for select to authenticated
  using (
    private.can_read_org(organization_id)
    or uploaded_by = (select private.current_user_id())
    or (property_id is not null and private.is_property_owner(property_id))
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
  );
create policy documents_insert on public.documents for insert to authenticated
  with check (
    private.is_org_staff(organization_id)
    or (property_id is not null and private.can_manage_property(property_id))
    or (service_order_id is not null and private.can_read_service_order(service_order_id) and private.is_org_member(organization_id))
  );
create policy documents_update on public.documents for update to authenticated
  using (private.is_org_staff(organization_id) or uploaded_by = (select private.current_user_id()))
  with check (private.is_org_staff(organization_id) or uploaded_by = (select private.current_user_id()));
create policy documents_delete on public.documents for delete to authenticated
  using (private.is_org_staff(organization_id) or uploaded_by = (select private.current_user_id()));

create policy photos_select on public.photos for select to authenticated
  using (
    private.can_read_org(organization_id)
    or uploaded_by = (select private.current_user_id())
    or private.is_property_owner(property_id)
    or (inspection_id is not null and private.can_read_inspection(inspection_id))
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
    or (service_task_id is not null and private.can_read_task(service_task_id))
    or (repair_id is not null and private.can_read_repair(repair_id))
  );
create policy photos_insert on public.photos for insert to authenticated
  with check (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or (inspection_id is not null and private.can_work_inspection(inspection_id))
    or (service_order_id is not null and private.can_read_service_order(service_order_id) and private.is_org_member(organization_id))
    or (service_task_id is not null and private.can_read_task(service_task_id) and private.is_org_member(organization_id))
  );
create policy photos_update on public.photos for update to authenticated
  using (private.is_org_staff(organization_id) or uploaded_by = (select private.current_user_id()))
  with check (private.is_org_staff(organization_id) or uploaded_by = (select private.current_user_id()));
create policy photos_delete on public.photos for delete to authenticated
  using (private.is_org_staff(organization_id) or uploaded_by = (select private.current_user_id()));

-- -----------------------------------------------------------------------------
-- quotes, invoices
-- -----------------------------------------------------------------------------
create policy quotes_select on public.quotes for select to authenticated
  using (private.can_read_org(organization_id) or private.is_property_owner(property_id)
         or private.is_partner_member(service_partner_id));
create policy quotes_insert on public.quotes for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.is_partner_member(service_partner_id));
create policy quotes_update on public.quotes for update to authenticated
  using (private.is_org_staff(organization_id) or private.is_property_owner(property_id)
         or (private.is_partner_member(service_partner_id) and status in ('requested', 'received')))
  with check (private.is_org_staff(organization_id) or private.is_property_owner(property_id)
              or private.is_partner_member(service_partner_id));
create policy quotes_delete on public.quotes for delete to authenticated
  using (private.is_org_staff(organization_id));

create policy invoices_select on public.invoices for select to authenticated
  using (private.can_read_org(organization_id) or private.is_property_owner(property_id)
         or private.is_partner_member(service_partner_id));
create policy invoices_insert on public.invoices for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.is_partner_member(service_partner_id));
create policy invoices_update on public.invoices for update to authenticated
  using (private.is_org_staff(organization_id)
         or (private.is_partner_member(service_partner_id) and status in ('draft', 'received')))
  with check (private.is_org_staff(organization_id) or private.is_partner_member(service_partner_id));
create policy invoices_delete on public.invoices for delete to authenticated
  using (private.is_org_staff(organization_id));

-- -----------------------------------------------------------------------------
-- Automatisierung
-- -----------------------------------------------------------------------------
create policy automation_rules_select on public.automation_rules for select to authenticated
  using (private.can_read_org(organization_id));
create policy automation_rules_insert on public.automation_rules for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy automation_rules_update on public.automation_rules for update to authenticated
  using (private.is_org_staff(organization_id)) with check (private.is_org_staff(organization_id));
create policy automation_rules_delete on public.automation_rules for delete to authenticated
  using (private.is_org_staff(organization_id));

-- Protokoll: nur lesen; geschrieben wird ausschließlich von der Engine
create policy automation_runs_select on public.automation_runs for select to authenticated
  using (private.can_read_org(organization_id));

-- -----------------------------------------------------------------------------
-- notifications (nur eigene), messages (Absender, Empfänger, Auftrags-Thread)
-- -----------------------------------------------------------------------------
create policy notifications_select on public.notifications for select to authenticated
  using (user_id = (select private.current_user_id()));
create policy notifications_insert on public.notifications for insert to authenticated
  with check (private.is_org_staff(organization_id) and private.is_user_in_org(user_id, organization_id));
create policy notifications_update on public.notifications for update to authenticated
  using (user_id = (select private.current_user_id())) with check (user_id = (select private.current_user_id()));
create policy notifications_delete on public.notifications for delete to authenticated
  using (user_id = (select private.current_user_id()));

create policy messages_select on public.messages for select to authenticated
  using (
    sender_user_id = (select private.current_user_id())
    or recipient_user_id = (select private.current_user_id())
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
  );
create policy messages_insert on public.messages for insert to authenticated
  with check (
    private.is_org_member(organization_id)
    and (service_order_id is null or private.can_read_service_order(service_order_id))
    and (recipient_user_id is null or private.is_user_in_org(recipient_user_id, organization_id))
  );
create policy messages_update on public.messages for update to authenticated
  using (recipient_user_id = (select private.current_user_id()))
  with check (recipient_user_id = (select private.current_user_id()));
create policy messages_delete on public.messages for delete to authenticated
  using (sender_user_id = (select private.current_user_id()));

-- -----------------------------------------------------------------------------
-- audit_logs, Webhooks (nur Admins lesen)
-- -----------------------------------------------------------------------------
create policy audit_logs_select on public.audit_logs for select to authenticated
  using (case when organization_id is null then (select private.is_super_admin()) else private.is_org_admin(organization_id) end);

create policy webhook_endpoints_select on public.webhook_endpoints for select to authenticated
  using (private.is_org_admin(organization_id));
create policy webhook_endpoints_insert on public.webhook_endpoints for insert to authenticated
  with check (private.is_org_admin(organization_id));
create policy webhook_endpoints_update on public.webhook_endpoints for update to authenticated
  using (private.is_org_admin(organization_id)) with check (private.is_org_admin(organization_id));
create policy webhook_endpoints_delete on public.webhook_endpoints for delete to authenticated
  using (private.is_org_admin(organization_id));

create policy webhook_events_select on public.webhook_events for select to authenticated
  using (organization_id is not null and private.is_org_admin(organization_id));

-- -----------------------------------------------------------------------------
-- Rechte
-- -----------------------------------------------------------------------------
-- anon (nicht angemeldet) erhält keinerlei Zugriff auf Tabellen
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

-- Protokolle sind für angemeldete Benutzer nur lesbar
revoke insert, update, delete, truncate on public.audit_logs, public.automation_runs, public.webhook_events from authenticated;
revoke truncate, references, trigger on all tables in schema public from authenticated;

-- Hilfsfunktionen
revoke all on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated, service_role;

-- Server-Funktionen (Edge Functions mit service_role, pg_cron)
revoke all on function public.webhook_verify_signature(uuid, text, text) from public, anon, authenticated;
revoke all on function public.webhook_receive(text, text, text, jsonb, boolean, text, jsonb, uuid) from public, anon, authenticated;
revoke all on function public.webhook_claim(integer, integer) from public, anon, authenticated;
revoke all on function public.webhook_complete(uuid, boolean, text, uuid) from public, anon, authenticated;
revoke all on function public.upsert_external_booking(uuid, uuid, text, text, timestamptz, timestamptz, text, text, text, text, text, integer, uuid) from public, anon, authenticated;
revoke all on function public.run_scheduled_automations() from public, anon, authenticated;
grant execute on function public.webhook_verify_signature(uuid, text, text) to service_role;
grant execute on function public.webhook_receive(text, text, text, jsonb, boolean, text, jsonb, uuid) to service_role;
grant execute on function public.webhook_claim(integer, integer) to service_role;
grant execute on function public.webhook_complete(uuid, boolean, text, uuid) to service_role;
grant execute on function public.upsert_external_booking(uuid, uuid, text, text, timestamptz, timestamptz, text, text, text, text, text, integer, uuid) to service_role;
grant execute on function public.run_scheduled_automations() to service_role;
-- Erneut zustellen: Admin der Organisation (Prüfung in der Funktion)
revoke all on function public.webhook_retry(uuid) from public, anon;
grant execute on function public.webhook_retry(uuid) to authenticated, service_role;
