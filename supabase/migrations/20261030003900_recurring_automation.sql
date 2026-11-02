-- =============================================================================
-- HUSORA · Phase 10: Automatisierung & Wiederkehr
-- =============================================================================
--   * Jahresverträge können ihre Besuche serverseitig planen (opt-in: service_agreements.auto_schedule).
--     Husora legt die Termine rechtzeitig (lead_days) als Aufträge beim Partner an – genau einmal je
--     Besuchstermin (service_orders.recurrence_key). Sendet der Hausbesitzer dieselbe Aufgabe aus seiner
--     App, wird sie mit dem geplanten Besuch verknüpft statt doppelt angelegt.
--   * Neue Automatik-Aktion „create_repair_order“: Mangel aus einer Kontrolle → Reparaturauftrag beim
--     Partner, der die Kontrolle gemacht hat (Ablauf wie Phase 7, aber ohne Rückfrage, wenn der
--     Hausbesitzer die Regel eingeschaltet hat).
--   * Zeitplan per pg_cron: stündlich run_scheduled_automations() (Wartung fällig, Rechnungen überfällig),
--     täglich run_recurring_agreements().
-- Idempotent.

-- -----------------------------------------------------------------------------
-- 1) Wiederkehrende Besuche aus Jahresverträgen
-- -----------------------------------------------------------------------------
alter table public.service_agreements
  add column if not exists auto_schedule boolean not null default false,
  add column if not exists visit_time    time not null default '09:00',
  add column if not exists lead_days     integer not null default 21,
  add column if not exists last_planned_on date;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'service_agreements_lead_days_check') then
    alter table public.service_agreements add constraint service_agreements_lead_days_check check (lead_days between 1 and 120);
  end if;
end $$;
comment on column public.service_agreements.auto_schedule is 'Husora plant die Besuche selbst (Aufträge beim Partner, lead_days im Voraus)';

alter table public.service_orders add column if not exists recurrence_key text;
create unique index if not exists service_orders_recurrence_key_idx on public.service_orders (recurrence_key) where recurrence_key is not null;

-- Besuchstermine eines Vertrags (gleichmäßig über das Vertragsjahr verteilt)
create or replace function private.agreement_visit_dates(p_starts date, p_ends date, p_visits integer)
returns setof date language sql immutable set search_path = '' as $$
  select (p_starts + (n * (365.0 / greatest(1, p_visits)))::integer)::date
  from generate_series(0, greatest(1, p_visits) * 3) n
  where (p_starts + (n * (365.0 / greatest(1, p_visits)))::integer)::date < coalesce(p_ends, p_starts + 365)
$$;

create or replace function public.run_recurring_agreements()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a       public.service_agreements;
  v_day     date;
  v_window  integer;
  v_created integer := 0;
  v_tz      text;
  v_id      uuid;
begin
  for v_a in
    select a.* from public.service_agreements a
    join public.service_partners sp on sp.id = a.service_partner_id
    where a.status = 'active' and a.auto_schedule and sp.partner_organization_id is not null and sp.disconnected_at is null
      and a.property_id is not null
  loop
    v_window := greatest(2, (365 / greatest(1, v_a.visits_per_year)) / 2);
    select coalesce(o.timezone, 'Europe/Stockholm') into v_tz from public.organizations o where o.id = v_a.organization_id;
    for v_day in
      select d from private.agreement_visit_dates(v_a.starts_on, v_a.ends_on, v_a.visits_per_year) d
      where d >= current_date and d <= current_date + v_a.lead_days
    loop
      -- schon ein Auftrag dieses Vertrags rund um diesen Termin (egal woher)? dann nichts anlegen
      continue when exists (
        select 1 from public.service_orders o
        where o.agreement_id = v_a.id and o.status not in ('cancelled', 'rejected')
          and o.scheduled_at is not null and abs(o.scheduled_at::date - v_day) <= v_window);
      insert into public.service_orders (organization_id, property_id, service_partner_id, agreement_id, title, description, status,
                                         scheduled_at, order_type, currency, recurrence_key, response_note)
      values (v_a.organization_id, v_a.property_id, v_a.service_partner_id, v_a.id, left(v_a.task_title, 200),
              'Geplanter Besuch aus dem Jahresvertrag „' || v_a.title || '“', 'scheduled',
              ((v_day + v_a.visit_time)::timestamp at time zone v_tz), 'maintenance', v_a.currency,
              v_a.id::text || ':' || v_day::text, 'Automatisch aus dem Jahresvertrag geplant')
      on conflict (recurrence_key) where recurrence_key is not null do nothing
      returning id into v_id;
      if v_id is not null then
        v_created := v_created + 1;
        insert into public.notifications (organization_id, user_id, type, category, title, message, entity_type, entity_id)
        select sp.partner_organization_id, m.user_id, 'service_order', 'order', 'Besuch geplant: ' || v_a.task_title,
               left(concat_ws(' · ', (select p.name from public.properties p where p.id = v_a.property_id), to_char(v_day, 'DD.MM.YYYY'), 'Jahresvertrag'), 200),
               'service_order', v_id
        from public.service_partners sp join public.organization_members m on m.organization_id = sp.partner_organization_id
        where sp.id = v_a.service_partner_id and m.status = 'active' and m.role in ('admin', 'service_manager', 'dispatcher');
      end if;
    end loop;
    update public.service_agreements set last_planned_on = current_date where id = v_a.id;
  end loop;
  return jsonb_build_object('created', v_created);
end;
$$;
revoke all on function public.run_recurring_agreements() from public, anon, authenticated;
grant execute on function public.run_recurring_agreements() to service_role;

-- Vertragsparteien schalten die automatische Planung ein/aus (Partnerleitung oder Hausbesitzer)
create or replace function public.set_agreement_auto_schedule(p_agreement_id uuid, p_enabled boolean, p_lead_days integer default null, p_visit_time time default null)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.service_agreements;
begin
  select * into v_a from public.service_agreements a where a.id = p_agreement_id for update;
  if v_a.id is null or not (private.is_org_staff(v_a.organization_id) or private.is_partner_member(v_a.service_partner_id)) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  if v_a.status <> 'active' then raise exception 'Nur aktive Jahresverträge können Besuche planen' using errcode = '22023'; end if;
  update public.service_agreements
  set auto_schedule = p_enabled,
      lead_days = case when p_lead_days is null then lead_days else least(120, greatest(1, p_lead_days)) end,  -- greatest() ignoriert NULL
      visit_time = coalesce(p_visit_time, visit_time)
  where id = v_a.id;
  if p_enabled then perform public.run_recurring_agreements(); end if;
  return p_enabled;
end;
$$;
revoke all on function public.set_agreement_auto_schedule(uuid, boolean, integer, time) from public, anon;
grant execute on function public.set_agreement_auto_schedule(uuid, boolean, integer, time) to authenticated;

-- Aufgabe des Hausbesitzers mit einem bereits geplanten Besuch verknüpfen (statt doppelt senden)
create or replace function private.link_agreement_visit(p_task public.service_tasks, p_partner uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  select o.id into v_id
  from public.service_orders o join public.service_agreements a on a.id = o.agreement_id
  where o.recurrence_key is not null and o.service_task_id is null and a.auto_schedule and a.status = 'active'
    and o.organization_id = p_task.organization_id and o.property_id = p_task.property_id
    and (p_partner is null or o.service_partner_id = p_partner)
    and o.status not in ('cancelled', 'rejected', 'completed')
    and private.agreement_covers(coalesce(a.task_titles, array[a.task_title]), p_task.title)
    and abs(o.scheduled_at::date - coalesce(p_task.scheduled_start, o.scheduled_at)::date) <= 7
  order by abs(o.scheduled_at::date - coalesce(p_task.scheduled_start, o.scheduled_at)::date)
  limit 1;
  if v_id is not null then
    update public.service_orders set service_task_id = p_task.id where id = v_id;
  end if;
  return v_id;
end; $$;

create or replace function public.offer_service_order(p_service_task_id uuid, p_service_partner_id uuid default null, p_estimated_cost numeric default null)
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

  -- Phase 10: bereits automatisch geplanter Vertragsbesuch → verknüpfen statt doppelt anlegen
  if private.is_org_staff(v_task.organization_id) then
    v_order := private.link_agreement_visit(v_task, v_partner);
    if v_order is not null then return v_order; end if;
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
-- 2) Automatik: Mangel aus Kontrolle → Reparaturauftrag beim Partner der Kontrolle
-- -----------------------------------------------------------------------------
alter table public.automation_rules drop constraint if exists automation_rules_action_config_check;
do $$
declare v_name text;
begin
  -- bestehende Aktionsprüfung (Name kann je Installation abweichen) ersetzen
  for v_name in select conname from pg_constraint where conrelid = 'public.automation_rules'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%action_config ->> ''type''%' loop
    execute format('alter table public.automation_rules drop constraint %I', v_name);
  end loop;
  alter table public.automation_rules add constraint automation_rules_action_type_check check ((action_config ->> 'type') = any (array[
    'create_task', 'create_cleaning_task', 'create_inspection', 'create_repair', 'notify', 'cancel_booking_tasks', 'offer_next_partner', 'create_repair_order']));
end $$;

-- Aktion ausführen (bestehende Funktion um create_repair_order erweitert)
create or replace function private.execute_automation_action(p_rule public.automation_rules, p_context jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_action    jsonb := p_rule.action_config;
  v_trigger   jsonb := p_rule.trigger_config;
  v_type      text := p_rule.action_config ->> 'type';
  v_org       uuid := p_rule.organization_id;
  v_property  uuid := (p_context ->> 'property_id')::uuid;
  v_anchor    timestamptz;
  v_start     timestamptz;
  v_end       timestamptz;
  v_id        uuid;
  v_type_id   uuid;
  v_partner   record;
  v_order     uuid;
  v_template  uuid;
  v_count     integer := 0;
  v_exclude   uuid[];
begin
  v_anchor := coalesce((p_context ->> coalesce(v_trigger ->> 'anchor', 'check_out'))::timestamptz, now());
  v_start := v_anchor + make_interval(hours => coalesce((v_trigger ->> 'offset_hours')::integer, 0));
  v_end := case when v_trigger ? 'duration_hours'
                then v_start + make_interval(hours => (v_trigger ->> 'duration_hours')::integer) end;

  if v_type in ('create_task', 'create_cleaning_task') then
    v_type_id := private.service_type_by_code(v_org, coalesce(v_action ->> 'service_type_code',
                   case when v_type = 'create_cleaning_task' then 'cleaning' end));
    insert into public.service_tasks (organization_id, property_id, booking_id, inspection_id, service_type_id,
                                      title, description, priority, scheduled_start, scheduled_end)
    values (v_org, v_property, (p_context ->> 'booking_id')::uuid, (p_context ->> 'inspection_id')::uuid, v_type_id,
            coalesce(nullif(private.automation_text(v_action ->> 'title', p_context), ''),
                     case when v_type = 'create_cleaning_task' then 'Endreinigung' else p_rule.name end),
            nullif(private.automation_text(v_action ->> 'description', p_context), ''),
            coalesce(v_action ->> 'priority', 'normal'), v_start, v_end)
    returning id into v_id;

    if coalesce((v_action ->> 'auto_assign')::boolean, false) and v_type_id is not null then
      select * into v_partner from public.match_service_partners(v_property, v_type_id, 1, null, v_start) limit 1;
      if v_partner.service_partner_id is not null then
        insert into public.service_orders (organization_id, service_task_id, property_id, service_partner_id, title,
                                           description, status, scheduled_at, estimated_cost, match_score)
        values (v_org, v_id, v_property, v_partner.service_partner_id,
                (select t.title from public.service_tasks t where t.id = v_id),
                nullif(private.automation_text(v_action ->> 'description', p_context), ''),
                'offered', v_start, v_partner.price_from, v_partner.score)
        returning id into v_order;
      end if;
    end if;
    return jsonb_build_object('service_task_id', v_id, 'service_order_id', v_order);

  elsif v_type = 'create_inspection' then
    v_template := coalesce((v_action ->> 'template_id')::uuid,
      (select t.id from public.inspection_templates t where t.organization_id = v_org and t.active order by t.created_at limit 1));
    insert into public.inspections (organization_id, property_id, template_id, booking_id, scheduled_at, notes)
    values (v_org, v_property, v_template, (p_context ->> 'booking_id')::uuid, v_start,
            nullif(private.automation_text(v_action ->> 'notes', p_context), ''))
    returning id into v_id;
    return jsonb_build_object('inspection_id', v_id);

  elsif v_type = 'create_repair' then
    insert into public.repairs (organization_id, property_id, inspection_id, inspection_item_id, title, description,
                                priority, estimated_cost)
    values (v_org, v_property, (p_context ->> 'inspection_id')::uuid, (p_context ->> 'inspection_item_id')::uuid,
            coalesce(v_action ->> 'title_prefix', 'Mangel: ') || coalesce(p_context ->> 'item_name', 'Kontrollpunkt'),
            p_context ->> 'item_notes',
            coalesce(v_action ->> 'priority', case when p_context ->> 'item_status' = 'defect' then 'high' else 'normal' end),
            (p_context ->> 'estimated_cost')::numeric)
    on conflict (inspection_item_id) where inspection_item_id is not null and status <> 'cancelled' do nothing
    returning id into v_id;
    return jsonb_build_object('repair_id', v_id);

  elsif v_type = 'notify' then
    insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
    select v_org, u.user_id, coalesce(v_action ->> 'notification_type', 'automation'),
           coalesce(nullif(private.automation_text(v_action ->> 'title', p_context), ''), p_rule.name),
           nullif(private.automation_text(v_action ->> 'message', p_context), ''),
           p_context ->> 'entity_type', (p_context ->> 'entity_id')::uuid
    from (
      select m.user_id from public.organization_members m
      where m.organization_id = v_org and m.status = 'active'
        and m.role in (select jsonb_array_elements_text(coalesce(v_action -> 'roles', '["admin"]'::jsonb)))
      union
      select p.owner_user_id from public.properties p
      where coalesce((v_action ->> 'include_owner')::boolean, false) and p.id = v_property and p.owner_user_id is not null
    ) u;
    get diagnostics v_count = row_count;
    return jsonb_build_object('notifications', v_count);

  elsif v_type = 'cancel_booking_tasks' then
    update public.service_tasks set status = 'cancelled'
    where booking_id = (p_context ->> 'booking_id')::uuid and status in ('pending', 'assigned');
    get diagnostics v_count = row_count;
    update public.service_orders set status = 'cancelled'
    where service_task_id in (select t.id from public.service_tasks t where t.booking_id = (p_context ->> 'booking_id')::uuid)
      and status in ('draft', 'offered');
    update public.inspections set status = 'cancelled'
    where booking_id = (p_context ->> 'booking_id')::uuid and status = 'scheduled';
    return jsonb_build_object('cancelled_tasks', v_count);

  elsif v_type = 'offer_next_partner' then
    select array_agg(o.service_partner_id) into v_exclude from public.service_orders o
    where o.service_task_id = (p_context ->> 'service_task_id')::uuid and o.status = 'rejected';
    select * into v_partner from public.match_service_partners(
      v_property, (select t.service_type_id from public.service_tasks t where t.id = (p_context ->> 'service_task_id')::uuid),
      1, v_exclude, (p_context ->> 'scheduled_at')::timestamptz) limit 1;
    if v_partner.service_partner_id is null then
      return jsonb_build_object('service_order_id', null, 'reason', 'kein weiterer Partner verfügbar');
    end if;
    insert into public.service_orders (organization_id, service_task_id, property_id, service_partner_id, title, description,
                                       status, scheduled_at, estimated_cost, match_score)
    select o.organization_id, o.service_task_id, o.property_id, v_partner.service_partner_id, o.title, o.description,
           'offered', o.scheduled_at, coalesce(v_partner.price_from, o.estimated_cost), v_partner.score
    from public.service_orders o where o.id = (p_context ->> 'service_order_id')::uuid
    returning id into v_order;
    return jsonb_build_object('service_order_id', v_order);
  elsif v_type = 'create_repair_order' then
    -- Phase 10: Mangel → Reparaturauftrag direkt beim Partner, der die Kontrolle gemacht hat
    select sp.id, sp.partner_organization_id into v_partner
    from public.inspections i join public.service_partners sp on sp.id = i.service_partner_id
    where i.id = (p_context ->> 'inspection_id')::uuid and sp.partner_organization_id is not null and sp.partner_organization_id <> v_org;
    if v_partner.id is null then return jsonb_build_object('skipped', 'kein verbundener Partner an der Kontrolle'); end if;
    insert into public.repairs (organization_id, property_id, inspection_id, inspection_item_id, title, description,
                                priority, estimated_cost, status, service_partner_id, source, approved_at)
    values (v_org, v_property, (p_context ->> 'inspection_id')::uuid, (p_context ->> 'inspection_item_id')::uuid,
            coalesce(v_action ->> 'title_prefix', 'Mangel: ') || coalesce(p_context ->> 'item_name', 'Kontrollpunkt'),
            p_context ->> 'item_notes', coalesce(v_action ->> 'priority', 'high'), (p_context ->> 'estimated_cost')::numeric,
            'approved', v_partner.id, 'inspection', now())
    on conflict (inspection_item_id) where inspection_item_id is not null and status <> 'cancelled' do nothing
    returning id into v_id;
    if v_id is null then return jsonb_build_object('skipped', 'Mangel bereits erfasst'); end if;
    insert into public.service_orders (organization_id, property_id, service_partner_id, title, description, status,
                                       estimated_cost, currency, priority, order_type, response_note)
    values (v_org, v_property, v_partner.id, left('Mangelbeseitigung: ' || coalesce(p_context ->> 'item_name', 'Kontrollpunkt'), 200),
            p_context ->> 'item_notes', 'accepted', (p_context ->> 'estimated_cost')::numeric,
            (select o.currency from public.organizations o where o.id = v_org), 'high', 'repair', 'Automatisch beauftragt (Regel: ' || p_rule.name || ')')
    returning id into v_order;
    update public.repairs set service_order_id = v_order where id = v_id;
    insert into public.notifications (organization_id, user_id, type, category, title, message, entity_type, entity_id)
    select v_partner.partner_organization_id, m.user_id, 'service_order', 'repair',
           'Mangelbeseitigung beauftragt: ' || coalesce(p_context ->> 'item_name', 'Kontrollpunkt'),
           left(concat_ws(' · ', p_context ->> 'property_name', 'Termin festlegen unter Mängel'), 200), 'service_order', v_order
    from public.organization_members m
    where m.organization_id = v_partner.partner_organization_id and m.status = 'active' and m.role in ('admin', 'service_manager', 'dispatcher');
    return jsonb_build_object('repair_id', v_id, 'service_order_id', v_order);
  end if;

  raise exception 'Unbekannte Aktion %', v_type;
end;
$function$;

-- -----------------------------------------------------------------------------
-- 3) Zeitplan (pg_cron): stündlich Automatik/Wartung, täglich Vertragsbesuche
-- -----------------------------------------------------------------------------
do $$
begin
  create extension if not exists pg_cron with schema pg_catalog;
  perform cron.schedule('husora-automations', '23 * * * *', 'select public.run_scheduled_automations()');
  perform cron.schedule('husora-recurring-agreements', '41 4 * * *', 'select public.run_recurring_agreements()');
exception when others then
  raise notice 'pg_cron nicht verfügbar – Zeitplan bitte im Dashboard anlegen: %', sqlerrm;
end $$;
