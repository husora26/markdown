-- =============================================================================
-- HUSORA · Phase 2: Auftragskern – Status-Engine und Auftragsereignisse
-- =============================================================================
-- Spezifikation §11–13 und §46. Bestehende Spalten, Status und Abläufe bleiben erhalten:
--   * `offered` entspricht dem Status „sent“ der Spezifikation.
--   * Neu: `waiting_customer`, `waiting_parts`.
--   * Alle Statuswechsel werden zentral geprüft (private.order_transition_allowed).
--   * Jede Änderung an Status, Termin, Zuteilung oder Notiz erzeugt ein Ereignis in
--     public.service_order_events (sichtbar für Hausbesitzer und Partner des Auftrags).
-- Idempotent: kann mehrfach ausgeführt werden.

-- -----------------------------------------------------------------------------
-- 1) Neue Spalten an service_orders
-- -----------------------------------------------------------------------------
alter table public.service_orders
  add column if not exists order_type        text not null default 'other',
  add column if not exists priority          text not null default 'normal',
  add column if not exists scheduled_end     timestamptz,
  add column if not exists started_at        timestamptz,
  add column if not exists cancelled_at      timestamptz,
  add column if not exists estimated_minutes integer,
  add column if not exists actual_minutes    integer,
  add column if not exists requires_approval boolean not null default false,
  add column if not exists approval_status   text,
  add column if not exists customer_visible  boolean not null default true;

comment on column public.service_orders.order_type is 'Auftragsart: inspection, maintenance, repair, cleaning, garden, snow, heating, pool, sauna, renovation, emergency, other';
comment on column public.service_orders.priority is 'low, normal, high, urgent, emergency';
comment on column public.service_orders.scheduled_at is 'Geplanter Beginn (entspricht scheduled_start der Spezifikation)';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'service_orders_order_type_check') then
    alter table public.service_orders add constraint service_orders_order_type_check check (order_type in
      ('inspection', 'maintenance', 'repair', 'cleaning', 'garden', 'snow', 'heating', 'pool', 'sauna', 'renovation', 'emergency', 'other'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'service_orders_priority_check') then
    alter table public.service_orders add constraint service_orders_priority_check check (priority in ('low', 'normal', 'high', 'urgent', 'emergency'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'service_orders_approval_status_check') then
    alter table public.service_orders add constraint service_orders_approval_status_check check (approval_status is null or approval_status in ('pending', 'approved', 'rejected'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'service_orders_minutes_check') then
    alter table public.service_orders add constraint service_orders_minutes_check check (
      (estimated_minutes is null or estimated_minutes between 0 and 100000) and (actual_minutes is null or actual_minutes between 0 and 100000));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'service_orders_schedule_range_check') then
    alter table public.service_orders add constraint service_orders_schedule_range_check check (scheduled_end is null or scheduled_at is null or scheduled_end >= scheduled_at);
  end if;
end $$;

-- Status um die Wartezustände erweitern (bestehende Werte bleiben)
alter table public.service_orders drop constraint if exists service_orders_status_check;
alter table public.service_orders add constraint service_orders_status_check check (status in
  ('draft', 'offered', 'accepted', 'rejected', 'scheduled', 'in_progress', 'waiting_customer', 'waiting_parts', 'completed', 'cancelled'));

create index if not exists service_orders_priority_idx on public.service_orders (priority) where priority in ('urgent', 'emergency');

-- Bestehende Aufträge: Auftragsart aus Leistung bzw. Titel ableiten, Startzeit nachtragen
create or replace function private.order_type_for(p_service_task_id uuid, p_title text)
returns text
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select case
       when st.code in ('inspection', 'holiday_home_inspection') or st.category = 'inspection' then 'inspection'
       when st.code = 'general_maintenance' or st.category = 'maintenance' then 'maintenance'
       when st.code = 'cleaning' or st.category = 'housekeeping' then 'cleaning'
       when st.code = 'gardening' then 'garden'
       when st.code = 'snow_removal' then 'snow'
       when st.code = 'heating' then 'heating'
       when st.code = 'renovation' then 'renovation'
       when st.code in ('repair', 'plumbing', 'electrician', 'roofing', 'windows', 'facade') then 'repair'
       else null end
     from public.service_tasks t join public.service_types st on st.id = t.service_type_id
     where t.id = p_service_task_id),
    case
      when p_title ~* '^(mangel|reparatur)' then 'repair'
      when p_title ~* 'kontrolle|inspektion|tillsyn' then 'inspection'
      when p_title ~* 'reinigung|putz|städ' then 'cleaning'
      when p_title ~* 'rasen|garten|hecke' then 'garden'
      when p_title ~* 'schnee|snö' then 'snow'
      when p_title ~* 'heizung|wärmepumpe|kamin' then 'heating'
      when p_title ~* 'pool' then 'pool'
      when p_title ~* 'sauna' then 'sauna'
      when p_title ~* 'wartung' then 'maintenance'
      when p_title ~* 'renovier|sanier' then 'renovation'
      else 'other' end)
$$;

alter table public.service_orders disable trigger user;
update public.service_orders o
set order_type = private.order_type_for(o.service_task_id, o.title)
where o.order_type = 'other' and private.order_type_for(o.service_task_id, o.title) <> 'other';
update public.service_orders o
set started_at = coalesce(o.started_at, o.accepted_at, o.updated_at)
where o.status in ('in_progress', 'completed') and o.started_at is null;
update public.service_orders o
set cancelled_at = coalesce(o.cancelled_at, o.updated_at)
where o.status = 'cancelled' and o.cancelled_at is null;
alter table public.service_orders enable trigger user;

-- -----------------------------------------------------------------------------
-- 2) Zentrale Status-Engine
-- -----------------------------------------------------------------------------
-- p_side: 'partner' (Partnerbetrieb im Auftrag eines Kunden) oder 'owner' (Verwaltung der
-- auftraggebenden Organisation, auch Partner bei Aufträgen eigener Kunden).
-- completed → in_progress nur über public.reopen_service_order().
create or replace function private.order_transition_allowed(p_old text, p_new text, p_side text)
returns boolean
language sql immutable set search_path = ''
as $$
  select p_old is not distinct from p_new
    or (p_old, p_new) in (
         ('offered', 'accepted'), ('offered', 'rejected'),
         ('accepted', 'scheduled'), ('accepted', 'in_progress'), ('accepted', 'completed'),
         ('scheduled', 'in_progress'), ('scheduled', 'completed'),
         ('in_progress', 'waiting_customer'), ('in_progress', 'waiting_parts'), ('in_progress', 'completed'),
         ('waiting_customer', 'in_progress'), ('waiting_customer', 'scheduled'), ('waiting_customer', 'waiting_parts'), ('waiting_customer', 'completed'),
         ('waiting_parts', 'in_progress'), ('waiting_parts', 'scheduled'), ('waiting_parts', 'waiting_customer'), ('waiting_parts', 'completed'))
    or (p_side = 'owner' and (
         (p_old, p_new) in (('draft', 'offered'), ('offered', 'draft'))
         or (p_new = 'cancelled' and p_old in ('draft', 'offered', 'accepted', 'scheduled', 'in_progress', 'waiting_customer', 'waiting_parts'))))
$$;
comment on function private.order_transition_allowed(text, text, text) is 'Erlaubte Statuswechsel für Aufträge (Spezifikation §46). Einzige Quelle der Regeln.';

-- Auftragsart bei neuen Aufträgen vorbelegen
create or replace function private.service_orders_defaults()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.order_type is null or new.order_type = 'other' then
    new.order_type := case when new.priority = 'emergency' then 'emergency' else private.order_type_for(new.service_task_id, new.title) end;
  end if;
  return new;
end;
$$;
drop trigger if exists service_orders_defaults on public.service_orders;
create trigger service_orders_defaults before insert on public.service_orders
  for each row execute function private.service_orders_defaults();

-- Guard: Rechte wie bisher, Statuswechsel jetzt zentral geprüft (auch für die Verwaltung)
create or replace function private.service_orders_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status   text;
  v_note     text;
  v_sched    timestamptz;
  v_sched_end timestamptz;
  v_actual   numeric(12, 2);
  v_minutes  integer;
  v_assigned uuid;
  v_lead     boolean;
  v_staff    boolean;
  v_reopen   boolean;
begin
  if tg_op = 'UPDATE' and not private.is_system_context() then
    new.order_number := old.order_number;
    v_staff := private.is_org_staff(old.organization_id);
    if not v_staff then
      v_lead := private.is_partner_member(old.service_partner_id);
      if not v_lead and not (old.assigned_user_id = private.current_user_id() and private.is_partner_employee(old.service_partner_id)) then
        raise exception 'Keine Berechtigung für Auftrag %', old.order_number using errcode = '42501';
      end if;
    end if;
    if new.status is distinct from old.status then
      v_reopen := old.status = 'completed' and new.status = 'in_progress'
                  and coalesce(current_setting('husora.order_reopen', true), '') = old.id::text;
      if not v_reopen and not private.order_transition_allowed(old.status, new.status, case when v_staff then 'owner' else 'partner' end) then
        -- 22023 statt 42501: fachliche Regel, keine fehlende Berechtigung (die App zeigt den Text direkt an)
        raise exception 'Statuswechsel % → % ist nicht erlaubt', old.status, new.status using errcode = '22023';
      end if;
    end if;
    if not v_staff then
      v_status := new.status;
      v_note := new.response_note;
      v_sched := new.scheduled_at;
      v_sched_end := new.scheduled_end;
      v_actual := new.actual_cost;
      v_minutes := new.actual_minutes;
      v_assigned := case when v_lead then new.assigned_user_id else old.assigned_user_id end;
      new := old;
      new.status := v_status;
      new.response_note := v_note;
      new.scheduled_at := v_sched;
      new.scheduled_end := v_sched_end;
      new.actual_cost := v_actual;
      new.actual_minutes := v_minutes;
      new.assigned_user_id := v_assigned;
    end if;
  end if;

  if tg_op = 'INSERT' or new.status is distinct from old.status then
    case new.status
      when 'offered'     then new.offered_at := coalesce(new.offered_at, now());
      when 'accepted'    then new.accepted_at := coalesce(new.accepted_at, now());
      when 'rejected'    then new.rejected_at := coalesce(new.rejected_at, now());
      when 'in_progress' then new.started_at := coalesce(new.started_at, now());
      when 'completed'   then new.completed_at := coalesce(new.completed_at, now());
                              new.started_at := coalesce(new.started_at, new.accepted_at, now());
      when 'cancelled'   then new.cancelled_at := coalesce(new.cancelled_at, now());
      else null;
    end case;
    if tg_op = 'UPDATE' and old.status = 'completed' and new.status <> 'completed' then
      new.completed_at := null;
    end if;
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3) Auftragsereignisse (Spezifikation §13: work_order_events)
-- -----------------------------------------------------------------------------
create table if not exists public.service_order_events (
  id                uuid primary key default gen_random_uuid(),
  service_order_id  uuid not null references public.service_orders(id) on delete cascade,
  organization_id   uuid not null references public.organizations(id) on delete cascade,
  user_id           uuid references public.users(id) on delete set null,
  actor_side        text not null default 'system' check (actor_side in ('owner', 'partner', 'system')),
  event_type        text not null check (event_type in ('created', 'status_changed', 'reopened', 'scheduled', 'assigned', 'note')),
  old_status        text,
  new_status        text,
  message           text check (message is null or length(message) <= 2000),
  metadata          jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now()
);
comment on table public.service_order_events is 'Protokoll je Auftrag: Status, Termin, Zuteilung, Notizen. Nur per Trigger/RPC beschreibbar.';
create index if not exists service_order_events_order_idx on public.service_order_events (service_order_id, created_at);
create index if not exists service_order_events_org_idx on public.service_order_events (organization_id, created_at desc);
create index if not exists service_order_events_user_idx on public.service_order_events (user_id) where user_id is not null;

alter table public.service_order_events enable row level security;
drop policy if exists service_order_events_select on public.service_order_events;
create policy service_order_events_select on public.service_order_events for select to authenticated
  using (private.can_read_service_order(service_order_id));
revoke all on public.service_order_events from anon;
revoke insert, update, delete on public.service_order_events from authenticated;
grant select on public.service_order_events to authenticated;

create or replace function private.log_service_order_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := private.current_user_id();
  v_side text;
  v_reason text := nullif(current_setting('husora.order_reopen_reason', true), '');
begin
  if not exists (select 1 from public.organizations o where o.id = new.organization_id) then
    return null;
  end if;
  -- Trigger läuft als Eigentümer (security definer): Systemkontext daher über die Anmeldung bestimmen
  v_side := case when v_user is null or coalesce(auth.role(), '') = 'service_role' then 'system'
                 when private.is_org_staff(new.organization_id) then 'owner'
                 else 'partner' end;

  if tg_op = 'INSERT' then
    insert into public.service_order_events (service_order_id, organization_id, user_id, actor_side, event_type, new_status, message, metadata)
    values (new.id, new.organization_id, v_user, v_side, 'created', new.status, null,
            jsonb_strip_nulls(jsonb_build_object('order_type', new.order_type, 'priority', new.priority, 'scheduled_at', new.scheduled_at)));
    return null;
  end if;

  if new.status is distinct from old.status then
    insert into public.service_order_events (service_order_id, organization_id, user_id, actor_side, event_type, old_status, new_status, message, metadata)
    values (new.id, new.organization_id, v_user, v_side,
            case when old.status = 'completed' and new.status = 'in_progress' then 'reopened' else 'status_changed' end,
            old.status, new.status,
            left(case when old.status = 'completed' and new.status = 'in_progress' then v_reason
                      when new.response_note is distinct from old.response_note then new.response_note end, 2000),
            jsonb_strip_nulls(jsonb_build_object('scheduled_at', case when new.scheduled_at is distinct from old.scheduled_at then new.scheduled_at end)));
  else
    if new.scheduled_at is distinct from old.scheduled_at or new.scheduled_end is distinct from old.scheduled_end then
      insert into public.service_order_events (service_order_id, organization_id, user_id, actor_side, event_type, old_status, new_status, metadata)
      values (new.id, new.organization_id, v_user, v_side, 'scheduled', old.status, new.status,
              jsonb_strip_nulls(jsonb_build_object('scheduled_at', new.scheduled_at, 'scheduled_end', new.scheduled_end, 'previous', old.scheduled_at)));
    end if;
    if new.response_note is distinct from old.response_note and nullif(trim(new.response_note), '') is not null then
      insert into public.service_order_events (service_order_id, organization_id, user_id, actor_side, event_type, old_status, new_status, message)
      values (new.id, new.organization_id, v_user, v_side, 'note', old.status, new.status, left(new.response_note, 2000));
    end if;
  end if;
  if new.assigned_user_id is distinct from old.assigned_user_id then
    insert into public.service_order_events (service_order_id, organization_id, user_id, actor_side, event_type, old_status, new_status, metadata)
    values (new.id, new.organization_id, v_user, v_side, 'assigned', old.status, new.status,
            jsonb_build_object('assigned_user_id', new.assigned_user_id, 'assigned_name',
              (select coalesce(nullif(trim(concat_ws(' ', u.first_name, u.last_name)), ''), u.email) from public.users u where u.id = new.assigned_user_id)));
  end if;
  return null;
end;
$$;
drop trigger if exists service_orders_log_event on public.service_orders;
create trigger service_orders_log_event after insert or update of status, scheduled_at, scheduled_end, assigned_user_id, response_note on public.service_orders
  for each row execute function private.log_service_order_event();

-- Bisherigen Verlauf aus dem Audit-Protokoll übernehmen (nur Aufträge ohne Ereignisse)
insert into public.service_order_events (service_order_id, organization_id, user_id, actor_side, event_type, old_status, new_status, message, metadata, created_at)
select o.id, o.organization_id, a.user_id,
       case when a.user_id is null then 'system' when exists (
         select 1 from public.organization_members m where m.organization_id = o.organization_id and m.user_id = a.user_id
           and m.role in ('admin', 'property_manager', 'service_manager')) then 'owner' else 'partner' end,
       case when a.action = 'insert' then 'created'
            when a.old_data ->> 'status' is distinct from a.new_data ->> 'status' then 'status_changed'
            when a.old_data ->> 'scheduled_at' is distinct from a.new_data ->> 'scheduled_at' then 'scheduled'
            else 'assigned' end,
       case when a.action = 'insert' then null else a.old_data ->> 'status' end,
       a.new_data ->> 'status',
       case when a.action <> 'insert' and a.old_data ->> 'response_note' is distinct from a.new_data ->> 'response_note' then left(a.new_data ->> 'response_note', 2000) end,
       jsonb_strip_nulls(jsonb_build_object('scheduled_at', a.new_data ->> 'scheduled_at', 'assigned_user_id', a.new_data ->> 'assigned_user_id', 'backfilled', true)),
       a.created_at
from public.audit_logs a
join public.service_orders o on o.id = a.entity_id
where a.entity_type = 'service_orders'
  and a.action in ('insert', 'update')
  and (a.action = 'insert'
       or a.old_data ->> 'status' is distinct from a.new_data ->> 'status'
       or a.old_data ->> 'scheduled_at' is distinct from a.new_data ->> 'scheduled_at'
       or a.old_data ->> 'assigned_user_id' is distinct from a.new_data ->> 'assigned_user_id')
  and (a.user_id is null or exists (select 1 from public.users u where u.id = a.user_id))
  and not exists (select 1 from public.service_order_events e where e.service_order_id = o.id);

insert into public.service_order_events (service_order_id, organization_id, actor_side, event_type, new_status, metadata, created_at)
select o.id, o.organization_id, 'system', 'created', o.status, '{"backfilled": true}'::jsonb, o.created_at
from public.service_orders o
where not exists (select 1 from public.service_order_events e where e.service_order_id = o.id);

-- -----------------------------------------------------------------------------
-- 4) RPCs: Statuswechsel mit Nachricht, Wiedereröffnung
-- -----------------------------------------------------------------------------
create or replace function public.transition_service_order(p_service_order_id uuid, p_status text, p_message text default null)
returns public.service_orders
language plpgsql
set search_path = ''
as $$
declare
  v_order public.service_orders;
begin
  update public.service_orders o
  set status = p_status,
      response_note = coalesce(nullif(left(trim(p_message), 2000), ''), o.response_note)
  where o.id = p_service_order_id
  returning * into v_order;
  if v_order.id is null then
    raise exception 'Auftrag nicht gefunden oder keine Berechtigung' using errcode = 'P0002';
  end if;
  return v_order;
end;
$$;
revoke all on function public.transition_service_order(uuid, text, text) from public, anon;
grant execute on function public.transition_service_order(uuid, text, text) to authenticated;

-- Abgeschlossenen Auftrag wieder öffnen: nur Admin der Organisation oder Partnerleitung, mit Begründung
create or replace function public.reopen_service_order(p_service_order_id uuid, p_reason text)
returns public.service_orders
language plpgsql
set search_path = ''
as $$
declare
  v_order public.service_orders;
begin
  if nullif(trim(p_reason), '') is null then
    raise exception 'Bitte einen Grund für die Wiedereröffnung angeben' using errcode = '22023';
  end if;
  select * into v_order from public.service_orders o where o.id = p_service_order_id;
  if v_order.id is null then
    raise exception 'Auftrag nicht gefunden oder keine Berechtigung' using errcode = 'P0002';
  end if;
  if v_order.status <> 'completed' then
    raise exception 'Nur abgeschlossene Aufträge können wieder geöffnet werden' using errcode = '22023';
  end if;
  if not (private.is_org_admin(v_order.organization_id) or private.is_partner_member(v_order.service_partner_id)) then
    raise exception 'Nur Administratoren oder die Partnerleitung dürfen Aufträge wieder öffnen' using errcode = '42501';
  end if;
  perform set_config('husora.order_reopen', v_order.id::text, true);
  perform set_config('husora.order_reopen_reason', left(trim(p_reason), 2000), true);
  update public.service_orders o set status = 'in_progress' where o.id = v_order.id returning * into v_order;
  perform set_config('husora.order_reopen', '', true);
  perform set_config('husora.order_reopen_reason', '', true);
  return v_order;
end;
$$;
revoke all on function public.reopen_service_order(uuid, text) from public, anon;
grant execute on function public.reopen_service_order(uuid, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 5) Benachrichtigungen: Wartezustände und Wiedereröffnung
-- -----------------------------------------------------------------------------
create or replace function private.notify_order_status()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_partner text;
  v_partner_org uuid;
  v_title text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return new; end if;
  select sp.company_name, sp.partner_organization_id into v_partner, v_partner_org
  from public.service_partners sp where sp.id = new.service_partner_id;

  -- an den Hausbesitzer
  v_title := case new.status
    when 'accepted' then coalesce(v_partner, 'Servicepartner') || ' hat den Auftrag angenommen'
    when 'rejected' then coalesce(v_partner, 'Servicepartner') || ' hat den Auftrag abgelehnt'
    when 'scheduled' then 'Termin geplant: ' || new.title
    when 'in_progress' then case when tg_op = 'UPDATE' and old.status = 'completed'
                                 then 'Auftrag wieder geöffnet: ' || new.title
                                 else coalesce(v_partner, 'Servicepartner') || ' hat mit dem Auftrag begonnen' end
    when 'waiting_customer' then coalesce(v_partner, 'Servicepartner') || ' wartet auf deine Rückmeldung'
    when 'waiting_parts' then 'Wartet auf Material: ' || new.title
    when 'completed' then 'Auftrag erledigt: ' || new.title
    else null end;
  if tg_op = 'UPDATE' and v_title is not null and v_partner_org is not null and v_partner_org <> new.organization_id then
    insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
    select new.organization_id, m.user_id, 'service_order', v_title,
           left(concat_ws(' · ', new.title, nullif(new.response_note, '')), 200), 'service_order', new.id
    from public.organization_members m
    where m.organization_id = new.organization_id and m.status = 'active'
      and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher');
  end if;

  -- an den Partnerbetrieb
  if v_partner_org is not null and v_partner_org <> new.organization_id
     and ((tg_op = 'INSERT' and new.status = 'offered') or (tg_op = 'UPDATE' and new.status = 'cancelled')) then
    insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
    select v_partner_org, m.user_id, 'service_order',
           case when new.status = 'offered' then 'Neue Anfrage: ' || new.title else 'Anfrage zurückgezogen: ' || new.title end,
           left(coalesce(new.description, ''), 200), 'service_order', new.id
    from public.organization_members m
    where m.organization_id = v_partner_org and m.status = 'active'
      and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher');
  end if;
  return new;
end;
$$;
