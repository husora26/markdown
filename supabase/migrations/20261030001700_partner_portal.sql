-- =============================================================================
-- HUSORA · Migration 1700 · Zugang für Servicepartner (Partner-Portal)
-- =============================================================================
-- Servicepartner sind eigene Organisationen (org_type service_partner) mit
-- Firmendaten, Mitarbeitern, eigenen Kunden, Leistungen und Kontrollvorlagen.
-- Ein Hausbesitzer lädt einen Partner per Code ein; danach ist der Partner-
-- Datensatz des Hausbesitzers (service_partners) mit der Partner-Organisation
-- verknüpft. Alle bestehenden Regeln (Aufträge, Aufgaben, Kontrollen, Angebote,
-- Rechnungen, Nachrichten, Dateien) greifen damit automatisch – ohne doppelte Daten.
--
-- Rollen in der Partner-Organisation (organization_members.role):
--   admin            Inhaber / Administration
--   dispatcher       Disposition: alle Aufträge, Mitarbeiter einteilen
--   service_manager  wie dispatcher
--   accounting       Buchhaltung: Aufträge lesen, Angebote/Rechnungen
--   technician       Techniker: nur ihm zugewiesene Aufträge
--   inspector        Kontrolleur: nur ihm zugewiesene Aufträge und Kontrollen
--   viewer           nur lesen

-- -----------------------------------------------------------------------------
-- Rollen erweitern
-- -----------------------------------------------------------------------------
alter table public.organization_members drop constraint organization_members_role_check;
alter table public.organization_members add constraint organization_members_role_check check (role in (
  'owner', 'admin', 'property_manager', 'service_manager', 'service_partner', 'cleaner', 'viewer',
  'dispatcher', 'technician', 'inspector', 'accounting'));

create or replace function private.is_org_staff(p_organization_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select private.has_org_role(p_organization_id, array['admin', 'property_manager', 'service_manager', 'dispatcher']) $$;

create or replace function private.can_read_org(p_organization_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select private.has_org_role(p_organization_id, array['admin', 'property_manager', 'service_manager', 'dispatcher', 'accounting', 'viewer']) $$;

-- -----------------------------------------------------------------------------
-- Organisationen: Art und Firmendaten
-- -----------------------------------------------------------------------------
alter table public.organizations
  add column org_type             text not null default 'homeowner' check (org_type in ('homeowner', 'service_partner', 'both')),
  add column legal_form           text,
  add column description          text,
  add column logo_url             text,
  add column vat_id               text,
  add column registration_number  text,
  add column contact_name         text,
  add column street               text,
  add column postal_code          text,
  add column city                 text,
  add column billing_street       text,
  add column billing_postal_code  text,
  add column billing_city         text,
  add column billing_country      text check (billing_country is null or billing_country ~ '^[A-Z]{2}$'),
  add column bank_name            text,
  add column iban                 text check (iban is null or replace(iban, ' ', '') ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{8,30}$'),
  add column bic                  text check (bic is null or bic ~ '^[A-Z0-9]{8}([A-Z0-9]{3})?$'),
  add column service_radius_km    numeric(7, 2) check (service_radius_km >= 0),
  add column business_hours       jsonb not null default '{}'::jsonb,
  add column emergency_phone      text;
comment on column public.organizations.org_type is 'homeowner = Hausbesitzer/Verwaltung · service_partner = Servicebetrieb · both = beides';
create index organizations_type_idx on public.organizations (org_type);

-- Verknüpfung: Partner-Datensatz eines Hausbesitzers ↔ Organisation des Partners
alter table public.service_partners add column partner_organization_id uuid references public.organizations(id) on delete set null;
comment on column public.service_partners.partner_organization_id is 'Organisation des Servicepartners (Partner-Portal). Ihre Mitarbeiter sehen die Aufträge dieses Partners.';
create unique index service_partners_partner_org_idx on public.service_partners (organization_id, partner_organization_id)
  where partner_organization_id is not null;
create index service_partners_partner_org_lookup_idx on public.service_partners (partner_organization_id) where partner_organization_id is not null;

-- Zuständiger Mitarbeiter des Partners
alter table public.service_orders add column assigned_user_id uuid references public.users(id) on delete set null;
comment on column public.service_orders.assigned_user_id is 'Mitarbeiter des Servicepartners, der den Auftrag ausführt (Techniker sehen nur ihre Aufträge).';
create index service_orders_assigned_user_idx on public.service_orders (assigned_user_id, status) where assigned_user_id is not null;

-- -----------------------------------------------------------------------------
-- Kunden des Servicepartners
-- -----------------------------------------------------------------------------
create table public.customers (
  id                      uuid primary key default gen_random_uuid(),
  organization_id         uuid not null references public.organizations(id) on delete cascade,
  linked_organization_id  uuid references public.organizations(id) on delete set null,
  customer_number         text,
  company_name            text,
  first_name              text,
  last_name               text,
  email                   text,
  phone                   text,
  street                  text,
  postal_code             text,
  city                    text,
  country                 text check (country is null or country ~ '^[A-Z]{2}$'),
  notes                   text,
  created_by              uuid references public.users(id) on delete set null,
  updated_by              uuid references public.users(id) on delete set null,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  unique (organization_id, id),
  check (coalesce(nullif(trim(company_name), ''), nullif(trim(first_name), ''), nullif(trim(last_name), '')) is not null)
);
comment on table public.customers is 'Kunden eines Servicepartners. linked_organization_id = Hausbesitzer-Organisation, die den Partner eingeladen hat.';
create index customers_org_idx on public.customers (organization_id, lower(coalesce(company_name, last_name, first_name)));
create unique index customers_linked_idx on public.customers (organization_id, linked_organization_id) where linked_organization_id is not null;
create index customers_linked_lookup_idx on public.customers (linked_organization_id) where linked_organization_id is not null;
create index customers_created_by_fk_idx on public.customers (created_by) where created_by is not null;
create index customers_updated_by_fk_idx on public.customers (updated_by) where updated_by is not null;
create trigger customers_set_updated_at before update on public.customers
  for each row execute function private.set_updated_at();
create trigger customers_set_actor before insert or update on public.customers
  for each row execute function private.set_actor_columns();
create trigger customers_audit after insert or update or delete on public.customers
  for each row execute function private.audit_row_change();

alter table public.properties add column owner_customer_id uuid;
alter table public.properties add constraint properties_owner_customer_fkey
  foreign key (organization_id, owner_customer_id) references public.customers (organization_id, id) on delete set null (owner_customer_id);
create index properties_owner_customer_idx on public.properties (owner_customer_id) where owner_customer_id is not null;

-- -----------------------------------------------------------------------------
-- Einladungen: Hausbesitzer → Partner, Partner → Mitarbeiter
-- -----------------------------------------------------------------------------
create table public.service_partner_invites (
  id                        uuid primary key default gen_random_uuid(),
  organization_id           uuid not null references public.organizations(id) on delete cascade,
  service_partner_id        uuid not null,
  email                     text,
  code                      text not null unique,
  created_by                uuid references public.users(id) on delete set null,
  expires_at                timestamptz not null default now() + interval '30 days',
  accepted_at               timestamptz,
  accepted_organization_id  uuid references public.organizations(id) on delete set null,
  created_at                timestamptz not null default now(),
  foreign key (organization_id, service_partner_id) references public.service_partners (organization_id, id) on delete cascade
);
create index service_partner_invites_org_idx on public.service_partner_invites (organization_id, created_at desc);
create index service_partner_invites_partner_idx on public.service_partner_invites (service_partner_id);
create index service_partner_invites_accepted_org_idx on public.service_partner_invites (accepted_organization_id) where accepted_organization_id is not null;
create index service_partner_invites_created_by_idx on public.service_partner_invites (created_by) where created_by is not null;

create table public.organization_invites (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  email            text not null,
  role             text not null check (role in ('admin', 'dispatcher', 'service_manager', 'accounting', 'technician', 'inspector', 'viewer', 'property_manager', 'owner', 'cleaner')),
  code             text not null unique,
  created_by       uuid references public.users(id) on delete set null,
  expires_at       timestamptz not null default now() + interval '14 days',
  accepted_at      timestamptz,
  accepted_by      uuid references public.users(id) on delete set null,
  created_at       timestamptz not null default now()
);
create index organization_invites_org_idx on public.organization_invites (organization_id, created_at desc);
create index organization_invites_created_by_idx on public.organization_invites (created_by) where created_by is not null;
create index organization_invites_accepted_by_idx on public.organization_invites (accepted_by) where accepted_by is not null;

-- Kurzer, gut abtippbarer Code (ohne 0/O/1/I)
create or replace function private.invite_code(p_prefix text)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea := extensions.gen_random_bytes(8);
  v_code  text := '';
begin
  for i in 0..7 loop
    v_code := v_code || substr(v_chars, (get_byte(v_bytes, i) % 32) + 1, 1);
    if i = 3 then v_code := v_code || '-'; end if;
  end loop;
  return p_prefix || '-' || v_code;
end;
$$;

-- -----------------------------------------------------------------------------
-- Zugriffs-Helfer für Partner-Organisationen
-- -----------------------------------------------------------------------------
-- Partnerbetriebe mit vollem Zugriff: direkte Zuordnung (service_partner_users) oder
-- Leitung/Disposition/Buchhaltung der verknüpften Partner-Organisation
create or replace function private.my_partner_ids()
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select spu.service_partner_id
  from public.service_partner_users spu
  join public.service_partners sp on sp.id = spu.service_partner_id
  where spu.user_id = private.current_user_id()
    and private.org_role(sp.organization_id) is not null
  union
  select sp.id
  from public.service_partners sp
  join public.organization_members m on m.organization_id = sp.partner_organization_id
  where m.user_id = private.current_user_id()
    and m.status = 'active'
    and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher', 'accounting')
$$;

-- Jeder aktive Mitarbeiter der Partner-Organisation (auch Techniker/Kontrolleure)
create or replace function private.is_partner_employee(p_service_partner_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_service_partner_id is not null and (
    private.is_partner_member(p_service_partner_id)
    or exists (
      select 1 from public.service_partners sp
      join public.organization_members m on m.organization_id = sp.partner_organization_id
      where sp.id = p_service_partner_id and m.user_id = private.current_user_id() and m.status = 'active'
    )
  )
$$;

-- Auftrag bearbeiten (Partnerseite): Leitung/Disposition oder zugewiesener Mitarbeiter
create or replace function private.can_work_order(p_service_order_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.service_orders o
    where o.id = p_service_order_id
      and o.status <> 'draft'
      and (
        private.is_org_staff(o.organization_id)
        or private.is_partner_member(o.service_partner_id)
        or (o.assigned_user_id = private.current_user_id() and private.is_partner_employee(o.service_partner_id))
      )
  )
$$;

create or replace function private.can_read_service_order(p_service_order_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.service_orders o
    where o.id = p_service_order_id
      and (
        private.can_read_org(o.organization_id)
        or private.is_property_owner(o.property_id)
        or (o.status <> 'draft' and private.is_partner_member(o.service_partner_id))
        or (o.status <> 'draft' and o.assigned_user_id = private.current_user_id() and private.is_partner_employee(o.service_partner_id))
      )
  )
$$;

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
      )
  )
$$;

create or replace function private.can_work_inspection(p_inspection_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.inspections i
    where i.id = p_inspection_id
      and (
        private.is_org_staff(i.organization_id)
        or (i.status in ('scheduled', 'in_progress') and (
              (i.inspector_user_id = private.current_user_id() and (private.is_org_member(i.organization_id) or private.is_partner_employee(i.service_partner_id)))
              or private.is_partner_member(i.service_partner_id)))
      )
  )
$$;

create or replace function private.can_read_property(p_property_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.can_read_org(private.property_org(p_property_id))
      or private.property_role(p_property_id) is not null
      or exists (
        select 1 from public.service_tasks t
        where t.property_id = p_property_id
          and t.status not in ('cancelled')
          and (
            (t.assigned_user_id = private.current_user_id() and private.is_org_member(t.organization_id))
            or private.is_partner_member(t.assigned_partner_id)
          )
      )
      or exists (
        select 1 from public.service_orders o
        where o.property_id = p_property_id
          and o.status not in ('draft', 'cancelled')
          and (private.is_partner_member(o.service_partner_id)
               or (o.assigned_user_id = private.current_user_id() and private.is_partner_employee(o.service_partner_id)))
      )
      or exists (
        select 1 from public.inspections i
        where i.property_id = p_property_id
          and i.status <> 'cancelled'
          and (
            (i.inspector_user_id = private.current_user_id() and (private.is_org_member(i.organization_id) or private.is_partner_employee(i.service_partner_id)))
            or private.is_partner_member(i.service_partner_id)
          )
      )
$$;

-- Partnerseite: Mitarbeiter einteilen, Techniker dürfen nur Ablauf ändern
create or replace function private.service_orders_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status   text;
  v_note     text;
  v_sched    timestamptz;
  v_actual   numeric(12, 2);
  v_assigned uuid;
  v_lead     boolean;
begin
  if tg_op = 'UPDATE' and not private.is_system_context() then
    new.order_number := old.order_number;
    if not private.is_org_staff(old.organization_id) then
      v_lead := private.is_partner_member(old.service_partner_id);
      if not v_lead and not (old.assigned_user_id = private.current_user_id() and private.is_partner_employee(old.service_partner_id)) then
        raise exception 'Keine Berechtigung für Auftrag %', old.order_number using errcode = '42501';
      end if;
      if new.status is distinct from old.status and not (
           (old.status = 'offered' and new.status in ('accepted', 'rejected'))
        or (old.status in ('accepted', 'scheduled') and new.status in ('scheduled', 'in_progress'))
        or (old.status in ('accepted', 'scheduled', 'in_progress') and new.status = 'completed')
      ) then
        raise exception 'Statuswechsel % → % ist für Partner nicht erlaubt', old.status, new.status using errcode = '42501';
      end if;
      v_status := new.status;
      v_note := new.response_note;
      v_sched := new.scheduled_at;
      v_actual := new.actual_cost;
      v_assigned := case when v_lead then new.assigned_user_id else old.assigned_user_id end;
      new := old;
      new.status := v_status;
      new.response_note := v_note;
      new.scheduled_at := v_sched;
      new.actual_cost := v_actual;
      new.assigned_user_id := v_assigned;
    end if;
  end if;

  if tg_op = 'INSERT' or new.status is distinct from old.status then
    case new.status
      when 'offered'   then new.offered_at := coalesce(new.offered_at, now());
      when 'accepted'  then new.accepted_at := coalesce(new.accepted_at, now());
      when 'rejected'  then new.rejected_at := coalesce(new.rejected_at, now());
      when 'completed' then new.completed_at := coalesce(new.completed_at, now());
      else null;
    end case;
  end if;
  return new;
end;
$$;

-- Zugewiesener Mitarbeiter muss zum Partner gehören
create or replace function private.check_order_assignee()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.assigned_user_id is not null and new.assigned_user_id is distinct from old.assigned_user_id
     and not exists (
       select 1 from public.service_partners sp
       join public.organization_members m on m.organization_id = sp.partner_organization_id
       where sp.id = new.service_partner_id and m.user_id = new.assigned_user_id and m.status = 'active'
       union all
       select 1 from public.service_partner_users spu
       where spu.service_partner_id = new.service_partner_id and spu.user_id = new.assigned_user_id
     ) then
    raise exception 'Die zugewiesene Person arbeitet nicht für diesen Servicepartner' using errcode = '23503';
  end if;
  return new;
end;
$$;
create trigger service_orders_check_assignee before insert or update of assigned_user_id, service_partner_id on public.service_orders
  for each row execute function private.check_order_assignee();

-- Partner darf bei seiner Kontrolle auch den Prüfer aus seinem Team einteilen
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
  v_inspector uuid;
begin
  if not private.is_system_context()
     and not private.is_org_staff(old.organization_id)
     and not private.can_manage_property(old.property_id) then
    if new.status is distinct from old.status and new.status not in ('in_progress', 'completed') then
      raise exception 'Status "%" darf nur von der Verwaltung gesetzt werden', new.status using errcode = '42501';
    end if;
    v_status := new.status; v_started := new.started_at; v_done := new.completed_at;
    v_overall := new.overall_status; v_notes := new.notes;
    v_inspector := case when private.is_partner_member(old.service_partner_id) then new.inspector_user_id else old.inspector_user_id end;
    new := old;
    new.status := v_status; new.started_at := v_started; new.completed_at := v_done;
    new.overall_status := v_overall; new.notes := v_notes; new.inspector_user_id := v_inspector;
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

-- -----------------------------------------------------------------------------
-- Policies anpassen
-- -----------------------------------------------------------------------------
-- Häuser: Organisation direkt prüfen (sonst scheitert INSERT … RETURNING, weil die
-- Hilfsfunktion die gerade eingefügte Zeile noch nicht sieht)
drop policy properties_select on public.properties;
create policy properties_select on public.properties for select to authenticated
  using (private.can_read_org(organization_id) or private.can_read_property(id));

drop policy service_orders_select on public.service_orders;
create policy service_orders_select on public.service_orders for select to authenticated
  using (
    private.can_read_org(organization_id)
    or private.is_property_owner(property_id)
    or (status <> 'draft' and private.is_partner_member(service_partner_id))
    or (status <> 'draft' and assigned_user_id = (select private.current_user_id()) and private.is_partner_employee(service_partner_id))
  );
drop policy service_orders_update on public.service_orders;
create policy service_orders_update on public.service_orders for update to authenticated
  using (
    private.is_org_staff(organization_id)
    or (status <> 'draft' and private.is_partner_member(service_partner_id))
    or (status <> 'draft' and assigned_user_id = (select private.current_user_id()) and private.is_partner_employee(service_partner_id))
  )
  with check (private.is_org_staff(organization_id) or private.is_partner_employee(service_partner_id));

drop policy inspections_select on public.inspections;
create policy inspections_select on public.inspections for select to authenticated
  using (private.can_read_inspection(id));
drop policy inspections_insert on public.inspections;
create policy inspections_insert on public.inspections for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
drop policy inspections_update on public.inspections;
create policy inspections_update on public.inspections for update to authenticated
  using (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or private.can_work_inspection(id)
  )
  with check (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or private.is_partner_employee(service_partner_id)
    or (inspector_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
  );

-- Kontrolle des eigenen Betriebs (auch nach Abschluss, z. B. für den Prüfbericht)
create or replace function private.is_inspection_partner(p_inspection_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.inspections i
    where i.id = p_inspection_id
      and (private.is_partner_member(i.service_partner_id)
           or (i.inspector_user_id = private.current_user_id() and private.is_partner_employee(i.service_partner_id)))
  )
$$;

drop policy documents_insert on public.documents;
create policy documents_insert on public.documents for insert to authenticated
  with check (
    private.is_org_staff(organization_id)
    or (property_id is not null and private.can_manage_property(property_id))
    or (service_order_id is not null and private.can_work_order(service_order_id))
    or (inspection_id is not null and private.is_inspection_partner(inspection_id))
  );
drop policy photos_insert on public.photos;
create policy photos_insert on public.photos for insert to authenticated
  with check (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or (inspection_id is not null and private.can_work_inspection(inspection_id))
    or (service_order_id is not null and private.can_work_order(service_order_id))
    or (service_task_id is not null and private.can_read_task(service_task_id) and private.is_org_member(organization_id))
  );
drop policy messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (
    (private.is_org_member(organization_id) or (service_order_id is not null and private.can_work_order(service_order_id)))
    and (service_order_id is null or private.can_read_service_order(service_order_id))
    and (recipient_user_id is null or private.is_user_in_org(recipient_user_id, organization_id))
  );

alter table public.customers enable row level security;
create policy customers_select on public.customers for select to authenticated
  using (private.can_read_org(organization_id));
create policy customers_insert on public.customers for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy customers_update on public.customers for update to authenticated
  using (private.is_org_staff(organization_id)) with check (private.is_org_staff(organization_id));
create policy customers_delete on public.customers for delete to authenticated
  using (private.is_org_staff(organization_id));

alter table public.service_partner_invites enable row level security;
create policy service_partner_invites_select on public.service_partner_invites for select to authenticated
  using (private.is_org_staff(organization_id) or (accepted_organization_id is not null and private.can_read_org(accepted_organization_id)));
create policy service_partner_invites_delete on public.service_partner_invites for delete to authenticated
  using (private.is_org_staff(organization_id));

alter table public.organization_invites enable row level security;
create policy organization_invites_select on public.organization_invites for select to authenticated
  using (private.is_org_admin(organization_id));
create policy organization_invites_delete on public.organization_invites for delete to authenticated
  using (private.is_org_admin(organization_id));
revoke all on public.customers, public.service_partner_invites, public.organization_invites from anon;
revoke insert, update on public.service_partner_invites, public.organization_invites from authenticated;

-- -----------------------------------------------------------------------------
-- Globale Servicearten (Leistungskategorien)
-- -----------------------------------------------------------------------------
insert into public.service_types (id, organization_id, code, name, description, category) values
  ('eeeeeeee-0000-4000-8000-000000000004', null, 'inspection',              'Hauskontrolle',        'Abwesenheits- und Saisonkontrollen',         'inspection'),
  ('eeeeeeee-0000-4000-8000-000000000010', null, 'holiday_home_inspection', 'Ferienhauskontrolle',  'Kontrolle vor/nach Aufenthalten',            'inspection'),
  ('eeeeeeee-0000-4000-8000-000000000001', null, 'cleaning',                'Reinigung',            'End- und Zwischenreinigung, Wäschewechsel', 'housekeeping'),
  ('eeeeeeee-0000-4000-8000-000000000002', null, 'gardening',               'Gartenpflege',         'Rasen, Hecken, Laub',                        'outdoor'),
  ('eeeeeeee-0000-4000-8000-000000000003', null, 'snow_removal',            'Winterdienst',         'Schneeräumung, Streudienst, Dach',           'outdoor'),
  ('eeeeeeee-0000-4000-8000-000000000011', null, 'repair',                  'Reparatur',            'Reparaturen aller Art',                      'craft'),
  ('eeeeeeee-0000-4000-8000-000000000006', null, 'plumbing',                'Sanitär',              'Wasser, Abwasser, Brunnen',                  'craft'),
  ('eeeeeeee-0000-4000-8000-000000000007', null, 'heating',                 'Heizung',              'Wartung und Reparatur von Heizanlagen',      'craft'),
  ('eeeeeeee-0000-4000-8000-000000000005', null, 'electrician',             'Elektro',              'Elektroinstallation und -reparatur',         'craft'),
  ('eeeeeeee-0000-4000-8000-000000000008', null, 'roofing',                 'Dach',                 'Dacharbeiten, Rinnenreinigung',              'craft'),
  ('eeeeeeee-0000-4000-8000-000000000012', null, 'facade',                  'Fassade',              'Anstrich, Holzschutz, Fassadenreparatur',    'craft'),
  ('eeeeeeee-0000-4000-8000-000000000013', null, 'windows',                 'Fenster',              'Fenster und Türen',                          'craft'),
  ('eeeeeeee-0000-4000-8000-000000000014', null, 'key_service',             'Schlüsselservice',     'Schlüsselübergabe und -verwaltung',          'service'),
  ('eeeeeeee-0000-4000-8000-000000000009', null, 'general_maintenance',     'Technische Wartung',   'Hausmeisterservice und technische Wartung',  'maintenance')
on conflict on constraint service_types_code_unique do nothing;

-- -----------------------------------------------------------------------------
-- RPC: Partner-Organisation anlegen (Onboarding)
-- -----------------------------------------------------------------------------
create or replace function public.create_partner_organization(p_profile jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := private.current_user_id();
  v_org      uuid;
  v_partner  uuid;
  v_template uuid;
  v_name     text := nullif(trim(p_profile ->> 'name'), '');
  v_code     text;
  v_tpl      record;
begin
  if v_user is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;
  if v_name is null then
    raise exception 'Bitte den Firmennamen angeben' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.organization_members m join public.organizations o on o.id = m.organization_id
    where m.user_id = v_user and m.status = 'active' and o.org_type in ('service_partner', 'both') and m.role = 'admin'
  ) then
    raise exception 'Du hast bereits einen Servicebetrieb angelegt' using errcode = '23505';
  end if;

  insert into public.organizations (name, org_type, legal_form, contact_name, email, phone, website, street, postal_code, city,
                                    country, currency, timezone, vat_id, registration_number, emergency_phone, service_radius_km, description)
  values (v_name, 'service_partner', nullif(p_profile ->> 'legal_form', ''), nullif(p_profile ->> 'contact_name', ''),
          nullif(p_profile ->> 'email', ''), nullif(p_profile ->> 'phone', ''), nullif(p_profile ->> 'website', ''),
          nullif(p_profile ->> 'street', ''), nullif(p_profile ->> 'postal_code', ''), nullif(p_profile ->> 'city', ''),
          coalesce(nullif(upper(p_profile ->> 'country'), ''), 'SE'), coalesce(nullif(upper(p_profile ->> 'currency'), ''), 'SEK'),
          'Europe/Stockholm', nullif(p_profile ->> 'vat_id', ''), nullif(p_profile ->> 'registration_number', ''),
          nullif(p_profile ->> 'emergency_phone', ''), private.app_num(p_profile ->> 'service_radius_km'), nullif(p_profile ->> 'description', ''))
  returning id into v_org;
  -- Admin-Mitgliedschaft legt private.add_creator_as_admin an

  -- Eigener Partner-Datensatz: für Aufträge eigener Kunden
  insert into public.service_partners (organization_id, partner_organization_id, company_name, contact_name, email, phone,
                                       website, street, postal_code, city, country, status, description)
  values (v_org, v_org, v_name, nullif(p_profile ->> 'contact_name', ''), nullif(p_profile ->> 'email', ''),
          nullif(p_profile ->> 'phone', ''), nullif(p_profile ->> 'website', ''), nullif(p_profile ->> 'street', ''),
          nullif(p_profile ->> 'postal_code', ''), nullif(p_profile ->> 'city', ''),
          coalesce(nullif(upper(p_profile ->> 'country'), ''), 'SE'), 'active', nullif(p_profile ->> 'description', ''))
  returning id into v_partner;

  if coalesce(p_profile ->> 'service_radius_km', '') <> '' or coalesce(p_profile ->> 'city', '') <> '' then
    insert into public.service_partner_areas (service_partner_id, city, radius_km)
    values (v_partner, nullif(p_profile ->> 'city', ''), private.app_num(p_profile ->> 'service_radius_km'));
  end if;

  for v_code in select jsonb_array_elements_text(coalesce(p_profile -> 'services', '[]'::jsonb)) loop
    insert into public.service_partner_services (service_partner_id, service_type_id, currency)
    select v_partner, st.id, coalesce(nullif(upper(p_profile ->> 'currency'), ''), 'SEK')
    from public.service_types st where st.code = v_code and st.organization_id is null
    on conflict (service_partner_id, service_type_id) do nothing;
  end loop;

  -- Standard-Kontrollvorlagen
  for v_tpl in
    select * from (values
      ('Standard Hauskontrolle', 'Regelmäßige Kontrolle eines Wohnhauses', array[
         'Außen|Dach und Dachrinne', 'Außen|Fassade und Holzschutz', 'Außen|Fenster und Türen', 'Außen|Grundstück und Zufahrt',
         'Innen|Feuchtigkeit und Schimmel', 'Innen|Raumtemperatur', 'Technik|Wasserleitungen und Hähne', 'Technik|Heizung',
         'Technik|Strom und Sicherungen', 'Sicherheit|Rauchmelder']),
      ('Ferienhaus Kontrolle', 'Abwesenheitskontrolle für Ferienhäuser', array[
         'Außen|Dach und Dachrinne', 'Außen|Fenster und Türen verschlossen', 'Außen|Briefkasten', 'Innen|Raumtemperatur (Frostschutz)',
         'Innen|Feuchtigkeit und Schimmel', 'Innen|Schädlinge', 'Technik|Wasser und Hauptventil', 'Technik|Heizung / Wärmepumpe',
         'Technik|Strom und Zählerstand', 'Sicherheit|Rauchmelder', 'Sicherheit|Feuerlöscher']),
      ('Übergabekontrolle', 'Kontrolle bei An- und Abreise von Gästen', array[
         'Innen|Sauberkeit', 'Innen|Inventar vollständig', 'Innen|Schäden an Möbeln', 'Innen|Bettwäsche und Handtücher',
         'Technik|Geräte funktionsfähig', 'Außen|Terrasse und Grill', 'Außen|Müll entsorgt', 'Sicherheit|Schlüssel übergeben']),
      ('Winterkontrolle', 'Kontrolle in der Frostperiode', array[
         'Außen|Schneelast auf dem Dach', 'Außen|Zufahrt geräumt', 'Außen|Eiszapfen und Dachrinne', 'Innen|Raumtemperatur (Frostschutz)',
         'Technik|Wasser abgestellt / Frostschutz', 'Technik|Heizung läuft', 'Technik|Stromversorgung', 'Sicherheit|Rauchmelder']),
      ('Technik-Kontrolle', 'Kontrolle der Haustechnik', array[
         'Technik|Heizung / Wärmepumpe', 'Technik|Warmwasserbereiter', 'Technik|Wasserfilter / Brunnen', 'Technik|Abwasser / Kläranlage',
         'Technik|Elektroinstallation und FI-Schalter', 'Technik|Lüftung', 'Sicherheit|Rauchmelder', 'Sicherheit|Feuerlöscher'])
    ) as t(name, description, items)
  loop
    insert into public.inspection_templates (organization_id, name, description)
    values (v_org, v_tpl.name, v_tpl.description) returning id into v_template;
    insert into public.inspection_template_items (template_id, category, name, sort_order)
    select v_template, split_part(item, '|', 1), split_part(item, '|', 2), ord * 10
    from unnest(v_tpl.items) with ordinality as x(item, ord);
  end loop;

  return v_org;
end;
$$;

-- -----------------------------------------------------------------------------
-- RPC: Kontext des Partner-Portals (Organisation, Rolle, verbundene Kunden)
-- -----------------------------------------------------------------------------
create or replace function public.partner_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user   uuid := private.current_user_id();
  v_org_id uuid;
  v_org    public.organizations;
  v_role   text;
begin
  if v_user is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;
  select m.organization_id, m.role into v_org_id, v_role
  from public.organization_members m
  join public.organizations o on o.id = m.organization_id
  where m.user_id = v_user and m.status = 'active' and o.org_type in ('service_partner', 'both')
  order by (m.role = 'admin') desc, m.created_at
  limit 1;
  select * into v_org from public.organizations o where o.id = v_org_id;
  if v_org.id is null then
    return jsonb_build_object('organization', null);
  end if;
  return jsonb_build_object(
    'organization', to_jsonb(v_org) - 'settings',
    'role', v_role,
    'user_id', v_user,
    'self_partner_id', (select sp.id from public.service_partners sp where sp.organization_id = v_org.id and sp.partner_organization_id = v_org.id limit 1),
    'links', coalesce((
      select jsonb_agg(jsonb_build_object('service_partner_id', sp.id, 'organization_id', sp.organization_id, 'organization_name', o.name) order by o.name)
      from public.service_partners sp join public.organizations o on o.id = sp.organization_id
      where sp.partner_organization_id = v_org.id and sp.organization_id <> v_org.id
    ), '[]'::jsonb)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- RPC: Einladung Hausbesitzer → Partner
-- -----------------------------------------------------------------------------
create or replace function public.create_service_partner_invite(p_service_partner_id uuid, p_email text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org  uuid := private.partner_org(p_service_partner_id);
  v_code text;
begin
  if v_org is null or not private.is_org_staff(v_org) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  if exists (select 1 from public.service_partners sp where sp.id = p_service_partner_id and sp.partner_organization_id is not null) then
    raise exception 'Dieser Servicepartner ist bereits verbunden' using errcode = '23505';
  end if;
  -- offene Einladungen dieses Partners ersetzen
  delete from public.service_partner_invites where service_partner_id = p_service_partner_id and accepted_at is null;
  loop
    v_code := private.invite_code('HUS');
    exit when not exists (select 1 from public.service_partner_invites where code = v_code);
  end loop;
  insert into public.service_partner_invites (organization_id, service_partner_id, email, code, created_by)
  values (v_org, p_service_partner_id, nullif(trim(p_email), ''), v_code, private.current_user_id());
  return v_code;
end;
$$;

create or replace function public.accept_service_partner_invite(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := private.current_user_id();
  v_invite   public.service_partner_invites;
  v_partner_org uuid;
  v_home     public.organizations;
  v_inviter  public.users;
begin
  if v_user is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;
  select m.organization_id into v_partner_org
  from public.organization_members m join public.organizations o on o.id = m.organization_id
  where m.user_id = v_user and m.status = 'active' and o.org_type in ('service_partner', 'both') and m.role in ('admin', 'dispatcher', 'service_manager')
  order by (m.role = 'admin') desc limit 1;
  if v_partner_org is null then
    raise exception 'Bitte zuerst deinen Servicebetrieb anlegen' using errcode = '42501';
  end if;

  select * into v_invite from public.service_partner_invites i where i.code = upper(trim(p_code)) for update;
  if v_invite.id is null or v_invite.expires_at < now() then
    raise exception 'Der Einladungscode ist ungültig oder abgelaufen' using errcode = 'P0002';
  end if;
  if v_invite.accepted_at is not null then
    raise exception 'Dieser Einladungscode wurde bereits verwendet' using errcode = '23505';
  end if;
  if v_invite.organization_id = v_partner_org then
    raise exception 'Das ist eine Einladung deiner eigenen Organisation' using errcode = '22023';
  end if;
  if exists (select 1 from public.service_partners sp where sp.organization_id = v_invite.organization_id and sp.partner_organization_id = v_partner_org) then
    raise exception 'Du bist mit diesem Kunden bereits verbunden' using errcode = '23505';
  end if;

  update public.service_partners sp set partner_organization_id = v_partner_org where sp.id = v_invite.service_partner_id;
  update public.service_partner_invites set accepted_at = now(), accepted_organization_id = v_partner_org where id = v_invite.id;

  select * into v_home from public.organizations o where o.id = v_invite.organization_id;
  select * into v_inviter from public.users u where u.id = v_invite.created_by;
  insert into public.customers (organization_id, linked_organization_id, company_name, first_name, last_name, email, phone, country)
  values (v_partner_org, v_home.id, v_home.name, v_inviter.first_name, v_inviter.last_name,
          coalesce(v_home.email, v_inviter.email), coalesce(v_home.phone, v_inviter.phone), v_home.country)
  on conflict (organization_id, linked_organization_id) where linked_organization_id is not null do nothing;

  return jsonb_build_object('organization_id', v_home.id, 'organization_name', v_home.name, 'service_partner_id', v_invite.service_partner_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- RPC: Mitarbeiter einladen / Einladung annehmen
-- -----------------------------------------------------------------------------
create or replace function public.create_member_invite(p_organization_id uuid, p_email text, p_role text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
begin
  if not private.is_org_admin(p_organization_id) then
    raise exception 'Nur Admins können Mitarbeiter einladen' using errcode = '42501';
  end if;
  if coalesce(trim(p_email), '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Bitte eine gültige E-Mail-Adresse angeben' using errcode = '22023';
  end if;
  loop
    v_code := private.invite_code('TEAM');
    exit when not exists (select 1 from public.organization_invites where code = v_code);
  end loop;
  insert into public.organization_invites (organization_id, email, role, code, created_by)
  values (p_organization_id, lower(trim(p_email)), p_role, v_code, private.current_user_id());
  return v_code;
end;
$$;

create or replace function public.accept_member_invite(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user   public.users;
  v_invite public.organization_invites;
begin
  select * into v_user from public.users u where u.id = private.current_user_id();
  if v_user.id is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;
  select * into v_invite from public.organization_invites i where i.code = upper(trim(p_code)) for update;
  if v_invite.id is null or v_invite.expires_at < now() or v_invite.accepted_at is not null then
    raise exception 'Der Einladungscode ist ungültig, abgelaufen oder schon verwendet' using errcode = 'P0002';
  end if;
  if lower(coalesce(v_user.email, '')) <> v_invite.email then
    raise exception 'Diese Einladung gilt für %. Bitte mit dieser E-Mail-Adresse anmelden.', v_invite.email using errcode = '42501';
  end if;
  insert into public.organization_members (organization_id, user_id, role, status, invited_by)
  values (v_invite.organization_id, v_user.id, v_invite.role, 'active', v_invite.created_by)
  on conflict (organization_id, user_id) do update set role = excluded.role, status = 'active';
  update public.organization_invites set accepted_at = now(), accepted_by = v_user.id where id = v_invite.id;
  return jsonb_build_object('organization_id', v_invite.organization_id, 'role', v_invite.role,
    'organization_name', (select o.name from public.organizations o where o.id = v_invite.organization_id));
end;
$$;

-- -----------------------------------------------------------------------------
-- RPC: Kontrolle beim Kunden starten (Vorlage des Partners)
-- -----------------------------------------------------------------------------
create or replace function public.partner_start_inspection(p_property_id uuid, p_template_id uuid, p_scheduled_at timestamptz default now())
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org      uuid := private.property_org(p_property_id);
  v_tpl_org  uuid := private.template_org(p_template_id);
  v_partner  uuid;
  v_id       uuid;
  v_user     uuid := private.current_user_id();
begin
  if v_org is null or not private.can_read_property(p_property_id) then
    raise exception 'Kein Zugriff auf dieses Haus' using errcode = '42501';
  end if;
  if v_tpl_org is null or not private.can_read_org(v_tpl_org) then
    raise exception 'Vorlage nicht gefunden' using errcode = 'P0002';
  end if;
  -- Partner-Datensatz des Kunden, der zu meiner Organisation gehört
  select sp.id into v_partner from public.service_partners sp
  where sp.organization_id = v_org and sp.partner_organization_id = v_tpl_org;
  if v_partner is null or not private.is_partner_employee(v_partner) then
    raise exception 'Für dieses Haus bist du nicht als Servicepartner verbunden' using errcode = '42501';
  end if;

  insert into public.inspections (organization_id, property_id, template_id, inspector_user_id, service_partner_id, scheduled_at, status, notes)
  values (v_org, p_property_id, case when v_tpl_org = v_org then p_template_id end, v_user, v_partner,
          coalesce(p_scheduled_at, now()), 'scheduled',
          'Vorlage: ' || (select t.name from public.inspection_templates t where t.id = p_template_id))
  returning id into v_id;
  if v_tpl_org <> v_org then
    insert into public.inspection_items (inspection_id, category, name, status)
    select v_id, ti.category, ti.name, ti.default_status
    from public.inspection_template_items ti where ti.template_id = p_template_id order by ti.sort_order;
  end if;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Cloud-Sync: Fortschritt des Partners nicht durch den App-Stand überschreiben
-- -----------------------------------------------------------------------------
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
      description = excluded.description, priority = excluded.priority,
      -- Ein Partner arbeitet daran: offener App-Status überschreibt dessen Fortschritt nicht
      status = case
        when public.service_tasks.assigned_partner_id is not null and excluded.status = 'pending' then public.service_tasks.status
        else excluded.status end,
      scheduled_start = excluded.scheduled_start;
    v_refs := v_refs || (v_item ->> 'id');
    v_count := v_count + 1;
  end loop;
  delete from public.service_tasks t
  where t.organization_id = p_org and t.app_ref is not null and not (t.app_ref = any (v_refs));
  return v_count;
end;
$$;


-- -----------------------------------------------------------------------------
-- Auftrag anbieten: Währung der Organisation übernehmen
-- -----------------------------------------------------------------------------
create or replace function public.offer_service_order(
  p_service_task_id uuid,
  p_service_partner_id uuid default null,
  p_estimated_cost numeric default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_task    public.service_tasks;
  v_partner uuid := p_service_partner_id;
  v_price   numeric;
  v_score   numeric;
  v_order   uuid;
  v_exclude uuid[];
begin
  select * into v_task from public.service_tasks t where t.id = p_service_task_id;
  if v_task.id is null then
    raise exception 'Aufgabe nicht gefunden' using errcode = 'P0002';
  end if;

  if v_partner is null then
    select array_agg(o.service_partner_id) into v_exclude
    from public.service_orders o where o.service_task_id = v_task.id and o.status = 'rejected';
    select m.service_partner_id, m.price_from, m.score into v_partner, v_price, v_score
    from public.match_service_partners(v_task.property_id, v_task.service_type_id, 1, v_exclude, v_task.scheduled_start) m;
    if v_partner is null then
      raise exception 'Kein passender Servicepartner gefunden' using errcode = 'P0002';
    end if;
  end if;

  insert into public.service_orders (organization_id, service_task_id, property_id, service_partner_id, title,
                                     description, status, scheduled_at, estimated_cost, match_score, currency)
  values (v_task.organization_id, v_task.id, v_task.property_id, v_partner,
          v_task.title, v_task.description, 'offered', v_task.scheduled_start,
          coalesce(p_estimated_cost, v_price), v_score,
          (select o.currency from public.organizations o where o.id = v_task.organization_id))
  returning id into v_order;
  return v_order;
end;
$$;

-- -----------------------------------------------------------------------------
-- Hausbesitzer-Cloud-Sync: nur Hausbesitzer-Organisationen verwenden
-- (ein reiner Servicepartner bekommt beim Sync eine eigene Hausbesitzer-Organisation)
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
  join public.organizations o on o.id = m.organization_id
  where m.user_id = v_user and m.status = 'active' and o.org_type in ('homeowner', 'both')
  order by (m.role = 'admin') desc, m.created_at
  limit 1;

  if v_org is null then
    insert into public.organizations (name, country, currency, timezone, org_type)
    values (coalesce(nullif(trim(p_name), ''), 'Meine Ferienhäuser'), 'SE', 'EUR', 'Europe/Stockholm', 'homeowner')
    returning id into v_org;
  end if;

  return query
    select o.id, o.name, m.role
    from public.organizations o
    join public.organization_members m on m.organization_id = o.id and m.user_id = v_user
    where o.id = v_org;
end;
$$;

-- -----------------------------------------------------------------------------
-- Rechte
-- -----------------------------------------------------------------------------
revoke all on function public.create_partner_organization(jsonb) from public, anon;
revoke all on function public.partner_context() from public, anon;
revoke all on function public.create_service_partner_invite(uuid, text) from public, anon;
revoke all on function public.accept_service_partner_invite(text) from public, anon;
revoke all on function public.create_member_invite(uuid, text, text) from public, anon;
revoke all on function public.accept_member_invite(text) from public, anon;
revoke all on function public.partner_start_inspection(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.create_partner_organization(jsonb), public.partner_context(),
  public.create_service_partner_invite(uuid, text), public.accept_service_partner_invite(text),
  public.create_member_invite(uuid, text, text), public.accept_member_invite(text),
  public.partner_start_inspection(uuid, uuid, timestamptz) to authenticated, service_role;
revoke all on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated, service_role;
