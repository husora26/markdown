-- =============================================================================
-- HUSORA · Aufbewahrung der neuen Beta-/Benachrichtigungs-/KI-Daten (Compliance-Test 02.11.2026)
-- =============================================================================
-- Erweitert die wöchentliche Bereinigung (Migration 2200) um die Fristen aus der Datenschutzerklärung:
--   analytics_events 13 Monate · beta_ratings 24 Monate · ai_suggestions 24 Monate (offene/fehlgeschlagene 30 Tage)
--   push_subscriptions ohne Nutzung 6 Monate · service_order_events bleiben (Nachweis der Aufträge)
--   * track_events(): Metadaten nur noch über eine Allowlist bekannter Schlüssel (statt Sperrliste) –
--     verhindert, dass ein Freitext wie „title“ mit Inhalt in die Analytics gelangt.
-- Idempotent.
create or replace function private.cleanup_retention()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.app_feedback where created_at < now() - interval '12 months';
  delete from public.notifications where read_at is not null and read_at < now() - interval '6 months';
  delete from public.stripe_events where processed_at < now() - interval '3 months';
  delete from public.analytics_events where occurred_at < now() - interval '13 months';
  delete from public.beta_ratings where created_at < now() - interval '24 months';
  delete from public.ai_suggestions where created_at < now() - interval '24 months'
     or (status in ('pending', 'failed') and created_at < now() - interval '30 days');
  delete from public.push_subscriptions where coalesce(last_used_at, created_at) < now() - interval '6 months';
$$;
revoke all on function private.cleanup_retention() from public, anon, authenticated;

-- Analytics: Metadaten nur aus einer Allowlist
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
    'subscription_interest', 'partner_profile_completed', 'partner_service_created', 'partner_area_created'];
begin
  if v_user is null then raise exception 'Nicht angemeldet' using errcode = '28000'; end if;
  if not private.beta_config('analytics') then return 0; end if;
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
                         'feature', 'type', 'severity', 'context', 'rating', 'order_type', 'priority', 'step', 'source'])  -- Allowlist (Datensparsamkeit)
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
            case when v_ev ->> 'environment' in ('production', 'staging', 'development') then v_ev ->> 'environment' end,
            'client', v_meta, v_at)
    on conflict do nothing;
    if found then v_count := v_count + 1; end if;
  end loop;
  return v_count;
end;
$function$;
revoke all on function public.track_events(jsonb, uuid) from public, anon;
grant execute on function public.track_events(jsonb, uuid) to authenticated;

-- Fix (Compliance-Test): Beim Löschen eines Kontos setzt die Datenbank app_feedback.user_id bzw.
-- organization_id auf NULL (ON DELETE SET NULL). Der Status-Schutz-Trigger hatte das zurückgesetzt und
-- damit „Konto löschen“ für Nutzer mit Feedback verhindert. Entfernen eines Bezugs ist jetzt erlaubt.
create or replace function private.app_feedback_identity()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_new public.app_feedback := new;
begin
  if tg_op = 'INSERT' then
    new.auth_user_id := auth.uid();
    new.user_id := private.current_user_id();
    if new.organization_id is not null and (new.user_id is null or not private.is_org_member(new.organization_id)) then
      new.organization_id := null;
    end if;
    new.status := 'open';
    new.resolved_at := null;
    if new.kind = 'bug' and new.severity is null then new.severity := 'medium'; end if;
    return new;
  end if;
  -- UPDATE: nur Status ändern (Super-Admin); Bezüge dürfen nur entfernt werden (Löschung von Konto/Organisation)
  new := old;
  new.status := v_new.status;
  new.resolved_at := case when v_new.status in ('resolved', 'wont_fix') then coalesce(old.resolved_at, now()) else null end;
  if v_new.user_id is null then new.user_id := null; end if;
  if v_new.organization_id is null then new.organization_id := null; end if;
  if v_new.auth_user_id is null then new.auth_user_id := null; end if;
  return new;
end;
$$;

-- Fix (frische Installation): seed.sql vergibt public.users.id neu; das automatisch erzeugte Ereignis
-- „user_registered“ verhinderte das. Bezüge der neuen Tabellen folgen einer geänderten Nutzer-ID.
do $$
declare r record;
begin
  for r in select * from (values
      ('analytics_events', 'analytics_events_user_id_fkey', 'user_id', 'cascade'),
      ('beta_ratings', 'beta_ratings_user_id_fkey', 'user_id', 'cascade'),
      ('notification_preferences', 'notification_preferences_user_id_fkey', 'user_id', 'cascade'),
      ('push_subscriptions', 'push_subscriptions_user_id_fkey', 'user_id', 'cascade'),
      ('app_feedback', 'app_feedback_user_id_fkey', 'user_id', 'set null'),
      ('ai_suggestions', 'ai_suggestions_requested_by_fkey', 'requested_by', 'set null')) v(tbl, con, col, on_delete)
  loop
    execute format('alter table public.%I drop constraint if exists %I', r.tbl, r.con);
    execute format('alter table public.%I add constraint %I foreign key (%I) references public.users(id) on update cascade on delete %s', r.tbl, r.con, r.col, r.on_delete);
  end loop;
end $$;
