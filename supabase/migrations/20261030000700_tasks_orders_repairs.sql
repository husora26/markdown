-- =============================================================================
-- HUSORA · Migration 0700 · Serviceaufgaben, Serviceaufträge, Wartung, Reparaturen
-- =============================================================================

-- Systemkontext: Migration, SQL-Editor, service_role oder Aufruf aus einer
-- security-definer-Funktion. Bewusst security invoker (current_user = Aufrufer).
create or replace function private.is_system_context()
returns boolean
language sql
stable
set search_path = ''
as $$
  select current_user in ('postgres', 'supabase_admin', 'service_role')
      or coalesce(auth.role(), '') = 'service_role'
$$;

-- Serviceart muss global sein oder zur selben Organisation gehören
create or replace function private.check_service_type_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org      uuid;
  v_type_org uuid;
begin
  if new.service_type_id is null then
    return new;
  end if;
  if tg_table_name = 'service_partner_services' then
    v_org := private.partner_org(new.service_partner_id);
  else
    v_org := (to_jsonb(new) ->> 'organization_id')::uuid;
  end if;
  select st.organization_id into v_type_org from public.service_types st where st.id = new.service_type_id;
  if v_type_org is not null and v_type_org is distinct from v_org then
    raise exception 'Serviceart % gehört zu einer anderen Organisation', new.service_type_id using errcode = '23503';
  end if;
  return new;
end;
$$;

create trigger service_partner_services_check_type before insert or update of service_type_id on public.service_partner_services
  for each row execute function private.check_service_type_scope();

-- -----------------------------------------------------------------------------
-- service_tasks: Aufgaben (Reinigung, Wäsche, Kontrolle, Garten …)
-- -----------------------------------------------------------------------------
create table public.service_tasks (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references public.organizations(id) on delete cascade,
  property_id          uuid not null,
  booking_id           uuid,
  inspection_id        uuid,
  service_type_id      uuid references public.service_types(id) on delete set null,
  title                text not null check (length(trim(title)) > 0),
  description          text,
  priority             text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  status               text not null default 'pending' check (status in ('pending', 'assigned', 'accepted', 'in_progress', 'completed', 'cancelled')),
  scheduled_start      timestamptz,
  scheduled_end        timestamptz,
  assigned_partner_id  uuid,
  assigned_user_id     uuid references public.users(id) on delete set null,
  completed_at         timestamptz,
  completion_notes     text,
  created_by           uuid references public.users(id) on delete set null,
  updated_by           uuid references public.users(id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, booking_id) references public.bookings (organization_id, id) on delete set null (booking_id),
  foreign key (organization_id, inspection_id) references public.inspections (organization_id, id) on delete set null (inspection_id),
  foreign key (organization_id, assigned_partner_id) references public.service_partners (organization_id, id) on delete set null (assigned_partner_id),
  check (scheduled_end is null or scheduled_start is null or scheduled_end >= scheduled_start)
);
comment on column public.service_tasks.assigned_user_id is 'Eingeteilte Person (z. B. Reinigungskraft). Rolle cleaner sieht nur ihre eigenen Aufgaben.';
comment on column public.service_tasks.assigned_partner_id is 'Beauftragter Partnerbetrieb. Rolle service_partner sieht nur Aufgaben seines Betriebs.';

create index service_tasks_property_status_idx on public.service_tasks (property_id, status);
create index service_tasks_org_status_idx on public.service_tasks (organization_id, status);
create index service_tasks_scheduled_start_idx on public.service_tasks (scheduled_start);
create index service_tasks_open_idx on public.service_tasks (organization_id, scheduled_start)
  where status not in ('completed', 'cancelled');
create index service_tasks_partner_idx on public.service_tasks (assigned_partner_id, status) where assigned_partner_id is not null;
create index service_tasks_user_idx on public.service_tasks (assigned_user_id, status) where assigned_user_id is not null;
create index service_tasks_booking_idx on public.service_tasks (booking_id) where booking_id is not null;
create index service_tasks_inspection_idx on public.service_tasks (inspection_id) where inspection_id is not null;
create index service_tasks_type_idx on public.service_tasks (service_type_id);
create index service_tasks_created_at_idx on public.service_tasks (created_at);

-- Ausführende (Reinigungskraft, Partner) dürfen nur Status und Erledigungsnotiz ändern
create or replace function private.service_tasks_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status text;
  v_notes  text;
begin
  if tg_op = 'UPDATE'
     and not private.is_system_context()
     and not private.is_org_staff(old.organization_id)
     and not private.can_manage_property(old.property_id) then
    if new.status is distinct from old.status and new.status not in ('accepted', 'in_progress', 'completed') then
      raise exception 'Status "%" darf nur von der Verwaltung gesetzt werden', new.status using errcode = '42501';
    end if;
    v_status := new.status;
    v_notes := new.completion_notes;
    new := old;
    new.status := v_status;
    new.completion_notes := v_notes;
  end if;

  if new.status = 'completed' then
    new.completed_at := coalesce(new.completed_at, now());
  elsif tg_op = 'UPDATE' and old.status = 'completed' then
    new.completed_at := null;
  end if;
  if tg_op = 'INSERT' and new.status = 'pending' and (new.assigned_partner_id is not null or new.assigned_user_id is not null) then
    new.status := 'assigned';
  end if;
  return new;
end;
$$;

create trigger service_tasks_guard before insert or update on public.service_tasks
  for each row execute function private.service_tasks_guard();
create trigger service_tasks_check_type before insert or update of service_type_id on public.service_tasks
  for each row execute function private.check_service_type_scope();
create trigger service_tasks_set_actor before insert or update on public.service_tasks
  for each row execute function private.set_actor_columns();
create trigger service_tasks_set_updated_at before update on public.service_tasks
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- service_orders: Aufträge an Servicepartner
-- -----------------------------------------------------------------------------
create table public.service_orders (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  service_task_id     uuid,
  property_id         uuid not null,
  service_partner_id  uuid,
  order_number        text not null unique
                      default 'SO-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.service_order_number_seq')::text, 6, '0'),
  title               text not null check (length(trim(title)) > 0),
  description         text,
  status              text not null default 'draft' check (status in ('draft', 'offered', 'accepted', 'rejected', 'scheduled', 'in_progress', 'completed', 'cancelled')),
  offered_at          timestamptz,
  accepted_at         timestamptz,
  rejected_at         timestamptz,
  response_note       text,
  scheduled_at        timestamptz,
  completed_at        timestamptz,
  estimated_cost      numeric(12, 2) check (estimated_cost >= 0),
  actual_cost         numeric(12, 2) check (actual_cost >= 0),
  currency            text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  match_score         numeric(6, 2),
  created_by          uuid references public.users(id) on delete set null,
  updated_by          uuid references public.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, service_task_id) references public.service_tasks (organization_id, id) on delete set null (service_task_id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, service_partner_id) references public.service_partners (organization_id, id) on delete set null (service_partner_id),
  check (status in ('draft', 'cancelled') or service_partner_id is not null)
);
comment on column public.service_orders.match_score is 'Score aus public.match_service_partners zum Zeitpunkt der Vergabe.';
comment on column public.service_orders.response_note is 'Antwort des Partners (Begründung bei Ablehnung, Terminvorschlag …).';

create index service_orders_partner_status_idx on public.service_orders (service_partner_id, status);
create index service_orders_org_status_idx on public.service_orders (organization_id, status);
create index service_orders_property_idx on public.service_orders (property_id, status);
create index service_orders_task_idx on public.service_orders (service_task_id) where service_task_id is not null;
create index service_orders_scheduled_idx on public.service_orders (scheduled_at);
create index service_orders_created_at_idx on public.service_orders (created_at);

-- Verwaltung darf alles; der Partner nur annehmen/ablehnen/terminieren/abschließen
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
begin
  if tg_op = 'UPDATE' and not private.is_system_context() then
    new.order_number := old.order_number;
    if not private.is_org_staff(old.organization_id) then
      if not private.is_partner_member(old.service_partner_id) then
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
      new := old;
      new.status := v_status;
      new.response_note := v_note;
      new.scheduled_at := v_sched;
      new.actual_cost := v_actual;
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

create trigger service_orders_guard before insert or update on public.service_orders
  for each row execute function private.service_orders_guard();
create trigger service_orders_set_actor before insert or update on public.service_orders
  for each row execute function private.set_actor_columns();
create trigger service_orders_set_updated_at before update on public.service_orders
  for each row execute function private.set_updated_at();

-- Auftragsstatus auf die verknüpfte Aufgabe übertragen
create or replace function private.sync_task_from_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.service_task_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.status is not distinct from old.status
     and new.service_partner_id is not distinct from old.service_partner_id then
    return new;
  end if;

  -- Absage: Aufgabe nur freigeben, wenn sie noch diesem Partner zugeordnet ist
  -- (ein Folgeangebot an den nächsten Partner kann bereits erfolgt sein)
  if new.status = 'rejected' then
    update public.service_tasks t
    set assigned_partner_id = null, status = 'pending'
    where t.id = new.service_task_id
      and t.assigned_partner_id is not distinct from new.service_partner_id
      and t.status not in ('completed', 'cancelled');
    return new;
  end if;

  update public.service_tasks t
  set assigned_partner_id = new.service_partner_id,
      status = case new.status
                 when 'offered'     then 'assigned'
                 when 'accepted'    then 'accepted'
                 when 'scheduled'   then 'accepted'
                 when 'in_progress' then 'in_progress'
                 when 'completed'   then 'completed'
                 else t.status
               end,
      scheduled_start = coalesce(new.scheduled_at, t.scheduled_start)
  where t.id = new.service_task_id
    and new.status not in ('draft', 'cancelled')
    and t.status <> 'cancelled';
  return new;
end;
$$;

create trigger service_orders_sync_task after insert or update of status, service_partner_id on public.service_orders
  for each row execute function private.sync_task_from_order();

-- -----------------------------------------------------------------------------
-- maintenance: wiederkehrende Wartung (Heizung, Schornstein, Brunnen …)
-- -----------------------------------------------------------------------------
create table public.maintenance (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references public.organizations(id) on delete cascade,
  property_id          uuid not null,
  service_type_id      uuid references public.service_types(id) on delete set null,
  title                text not null check (length(trim(title)) > 0),
  description          text,
  category             text,
  last_performed_at    timestamptz,
  next_due_at          timestamptz,
  interval_days        integer check (interval_days > 0),
  status               text not null default 'active' check (status in ('active', 'due', 'overdue', 'paused', 'retired')),
  assigned_partner_id  uuid,
  estimated_cost       numeric(12, 2) check (estimated_cost >= 0),
  created_by           uuid references public.users(id) on delete set null,
  updated_by           uuid references public.users(id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, assigned_partner_id) references public.service_partners (organization_id, id) on delete set null (assigned_partner_id)
);
create index maintenance_property_due_idx on public.maintenance (property_id, next_due_at);
create index maintenance_org_status_idx on public.maintenance (organization_id, status);
create index maintenance_due_idx on public.maintenance (next_due_at) where status in ('active', 'due', 'overdue');
create index maintenance_partner_idx on public.maintenance (assigned_partner_id) where assigned_partner_id is not null;
create index maintenance_created_at_idx on public.maintenance (created_at);

-- Nächste Fälligkeit aus letzter Ausführung + Intervall berechnen
create or replace function private.maintenance_next_due()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.interval_days is not null and new.last_performed_at is not null
     and (tg_op = 'INSERT' or new.last_performed_at is distinct from old.last_performed_at or new.interval_days is distinct from old.interval_days) then
    new.next_due_at := new.last_performed_at + make_interval(days => new.interval_days);
    if new.status in ('due', 'overdue') then
      new.status := 'active';
    end if;
  end if;
  return new;
end;
$$;

create trigger maintenance_next_due before insert or update on public.maintenance
  for each row execute function private.maintenance_next_due();
create trigger maintenance_check_type before insert or update of service_type_id on public.maintenance
  for each row execute function private.check_service_type_scope();
create trigger maintenance_set_actor before insert or update on public.maintenance
  for each row execute function private.set_actor_columns();
create trigger maintenance_set_updated_at before update on public.maintenance
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- repairs: Reparaturen (aus Mängeln der Hauskontrolle oder gemeldet)
-- -----------------------------------------------------------------------------
create table public.repairs (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  property_id         uuid not null,
  inspection_id       uuid,
  inspection_item_id  uuid references public.inspection_items(id) on delete set null,
  service_order_id    uuid,
  title               text not null check (length(trim(title)) > 0),
  description         text,
  priority            text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  status              text not null default 'reported' check (status in ('reported', 'approved', 'assigned', 'in_progress', 'completed', 'cancelled')),
  estimated_cost      numeric(12, 2) check (estimated_cost >= 0),
  actual_cost         numeric(12, 2) check (actual_cost >= 0),
  reported_at         timestamptz not null default now(),
  approved_at         timestamptz,
  approved_by         uuid references public.users(id) on delete set null,
  completed_at        timestamptz,
  created_by          uuid references public.users(id) on delete set null,
  updated_by          uuid references public.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, inspection_id) references public.inspections (organization_id, id) on delete set null (inspection_id),
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete set null (service_order_id),
  check (status <> 'completed' or completed_at is not null)
);
create unique index repairs_inspection_item_unique_idx on public.repairs (inspection_item_id)
  where inspection_item_id is not null and status <> 'cancelled';
create index repairs_property_status_idx on public.repairs (property_id, status);
create index repairs_org_status_idx on public.repairs (organization_id, status);
create index repairs_inspection_idx on public.repairs (inspection_id) where inspection_id is not null;
create index repairs_order_idx on public.repairs (service_order_id) where service_order_id is not null;
create index repairs_created_at_idx on public.repairs (created_at);

-- Prüfpunkt muss zur angegebenen Kontrolle und Organisation gehören (für repairs und photos)
create or replace function private.check_inspection_item_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inspection uuid;
  v_org        uuid;
  v_property   uuid;
begin
  if new.inspection_item_id is null then
    return new;
  end if;
  select ii.inspection_id, i.organization_id, i.property_id into v_inspection, v_org, v_property
  from public.inspection_items ii
  join public.inspections i on i.id = ii.inspection_id
  where ii.id = new.inspection_item_id;

  if v_org is distinct from new.organization_id or v_property is distinct from new.property_id
     or (new.inspection_id is not null and new.inspection_id <> v_inspection) then
    raise exception 'Prüfpunkt % gehört nicht zu dieser Kontrolle', new.inspection_item_id using errcode = '23503';
  end if;
  new.inspection_id := v_inspection;
  return new;
end;
$$;

-- Freigabe und Abschluss automatisch protokollieren
create or replace function private.repairs_status_timestamps()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'completed' then
    new.completed_at := coalesce(new.completed_at, now());
  end if;
  if new.status = 'approved' and (tg_op = 'INSERT' or old.status <> 'approved') then
    new.approved_at := coalesce(new.approved_at, now());
    new.approved_by := coalesce(new.approved_by, private.current_user_id());
  end if;
  return new;
end;
$$;

create trigger repairs_check_item before insert or update of inspection_item_id, inspection_id on public.repairs
  for each row execute function private.check_inspection_item_scope();
create trigger repairs_status_timestamps before insert or update on public.repairs
  for each row execute function private.repairs_status_timestamps();
create trigger repairs_set_actor before insert or update on public.repairs
  for each row execute function private.set_actor_columns();
create trigger repairs_set_updated_at before update on public.repairs
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- Zugriffs-Helfer
-- -----------------------------------------------------------------------------
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
      )
  )
$$;

create or replace function private.can_read_repair(p_repair_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.repairs r
    where r.id = p_repair_id
      and (
        private.can_read_org(r.organization_id)
        or private.is_property_owner(r.property_id)
        or (r.service_order_id is not null and private.can_read_service_order(r.service_order_id))
        or (r.inspection_id is not null and private.can_read_inspection(r.inspection_id))
      )
  )
$$;

-- Haus lesen: zusätzlich Personen und Partner, die dort eine Aufgabe, einen Auftrag
-- oder eine Kontrolle haben (Adresse, Zugangsinfos – aber keine Gästedaten).
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
          and private.is_partner_member(o.service_partner_id)
      )
      or exists (
        select 1 from public.inspections i
        where i.property_id = p_property_id
          and i.status <> 'cancelled'
          and (
            (i.inspector_user_id = private.current_user_id() and private.is_org_member(i.organization_id))
            or private.is_partner_member(i.service_partner_id)
          )
      )
$$;
