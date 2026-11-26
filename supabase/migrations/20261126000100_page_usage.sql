-- =============================================================================
-- HUSORA · Migration 2026-11-26 · Seiten-Nutzung für das Husora-Team
-- =============================================================================
-- Die App meldet „page_opened“ (einmal je Seite und Tag und Nutzer, nur mit
-- Einwilligung zu Analysen) über die bestehende Ereignis-Schnittstelle in
-- public.analytics_events. Diese Funktion fasst das für das Beta-Dashboard
-- zusammen: welche Seiten wie viele Nutzer öffnen. Kein Drittanbieter.

create or replace function public.page_usage(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_super_admin() then raise exception 'Nur für das Husora-Team' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('page', page, 'users', users, 'opens', opens) order by users desc, opens desc)
    from (
      select e.metadata ->> 'page' as page, count(distinct e.user_id) as users, count(*) as opens
      from public.analytics_events e
      where e.event_name = 'page_opened'
        and e.occurred_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)))
        and coalesce(e.metadata ->> 'page', '') <> ''
      group by 1
    ) x
  ), '[]'::jsonb);
end; $$;

revoke all on function public.page_usage(integer) from public, anon;
grant execute on function public.page_usage(integer) to authenticated;

-- track_events (Stand aus Migration 4500) – einzige Änderung: Ereignis 'page_opened' mit Metadatum 'page' erlaubt
CREATE OR REPLACE FUNCTION public.track_events(p_events jsonb, p_organization_id uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user   uuid := private.current_user_id();
  v_org    uuid;
  v_ev     jsonb;
  v_name   text;
  v_meta   jsonb;
  v_at     timestamptz;
  v_count  integer := 0;
  v_today  integer;
  v_allowed constant text[] := array['session_started', 'onboarding_started', 'onboarding_completed', 'house_created', 'room_created',
    'document_uploaded', 'task_created', 'task_completed', 'inspection_started', 'inspection_completed', 'service_search',
    'subscription_interest', 'partner_profile_completed', 'partner_service_created', 'partner_area_created', 'page_opened'];
begin
  if v_user is null then raise exception 'Nicht angemeldet' using errcode = '28000'; end if;
  if not private.beta_config('analytics') then return 0; end if;
  if not private.has_consent(v_user, 'analytics') then return 0; end if;  -- Einwilligung (TDDDG/DSGVO)
  if jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 50 then
    raise exception 'Höchstens 50 Ereignisse je Aufruf' using errcode = '22023';
  end if;
  -- Organisation nur, wenn der Nutzer Mitglied ist (nie blind vom Client übernehmen)
  v_org := case when p_organization_id is not null and private.is_org_member(p_organization_id) then p_organization_id end;
  select count(*) into v_today from public.analytics_events e where e.user_id = v_user and e.created_at > now() - interval '1 day';
  if v_today >= 2000 then return 0; end if;

  -- Beta-Nutzer markieren (einmalig, Gruppe aus der Konfiguration)
  update public.users u set is_beta_user = true, beta_started_at = coalesce(u.beta_started_at, now()),
         beta_group = coalesce(u.beta_group, (select c.value ->> 'default_group' from public.app_config c where c.key = 'beta'))
  where u.id = v_user and not u.is_beta_user;

  for v_ev in select * from jsonb_array_elements(p_events) loop
    v_name := v_ev ->> 'event_name';
    continue when v_name is null or not (v_name = any (v_allowed));
    -- nur flache, kurze Metadaten ohne verdächtige Schlüssel
    select coalesce(jsonb_object_agg(k, val), '{}'::jsonb) into v_meta
    from jsonb_each(case when jsonb_typeof(v_ev -> 'metadata') = 'object' then v_ev -> 'metadata' else '{}'::jsonb end) as m(k, val)
    where k = any (array['count', 'houses', 'rooms', 'added', 'auto', 'category', 'query_length', 'usage', 'demo_before', 'onboarding',
                         'feature', 'type', 'severity', 'context', 'rating', 'order_type', 'priority', 'step', 'source', 'page'])  -- Allowlist (Datensparsamkeit)
      and jsonb_typeof(val) in ('string', 'number', 'boolean')
      and length(val::text) <= 80;
    v_at := case when (v_ev ->> 'occurred_at') ~ '^\d{4}-\d{2}-\d{2}T' then (v_ev ->> 'occurred_at')::timestamptz end;
    if v_at is null or v_at > now() + interval '5 minutes' or v_at < now() - interval '90 days' then v_at := now(); end if;
    insert into public.analytics_events (organization_id, user_id, event_name, entity_type, entity_ref, app_role, app_version, platform, environment, source, metadata, occurred_at)
    values (v_org, v_user, v_name,
            case when (v_ev ->> 'entity_type') ~ '^[a-z][a-z0-9_]{1,40}$' then v_ev ->> 'entity_type' end,
            left(v_ev ->> 'entity_ref', 80),
            case when v_ev ->> 'app_role' in ('owner', 'partner', 'guest') then v_ev ->> 'app_role' end,
            left(v_ev ->> 'app_version', 40), left(v_ev ->> 'platform', 40),
            case when v_ev ->> 'environment' in ('production', 'staging', 'development', 'beta') then v_ev ->> 'environment' end,
            'client', v_meta, v_at)
    on conflict do nothing;
    if found then v_count := v_count + 1; end if;
  end loop;
  return v_count;
end;
$function$;
revoke all on function public.track_events(jsonb, uuid) from public, anon;
grant execute on function public.track_events(jsonb, uuid) to authenticated;

