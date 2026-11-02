-- =============================================================================
-- HUSORA · Beta Mode: Konfiguration, Analytics, Feedback/Fehler, Bewertungen, Beta-Nutzer, Auswertung
-- =============================================================================
-- Brief „Husora Beta Mode“. Bestehendes wird erweitert, nicht doppelt angelegt:
--   * public.app_feedback (Migration 2200) bleibt die Tabelle für Feedback, Fehlerberichte und
--     automatische Fehler; neue Spalten für Feedback-Art, Rolle, erwartetes/tatsächliches Verhalten,
--     Plattform, Umgebung, Schwere und Bearbeitungsstatus. Die Views beta_feedback/beta_bug_reports
--     zeigen sie unter den Namen des Briefs (security_invoker: es gelten die Regeln der Tabelle).
--   * public.users bekommt is_beta_user, beta_started_at, beta_group (nur Server/Super-Admin setzt sie).
--   * neu: public.app_config (globale Schalter ohne Codeänderung), public.analytics_events,
--     public.beta_ratings (Sterne, 7-/30-Tage-Umfrage).
-- „tenant_id“ heißt in Husora organization_id. Nutzer und Organisation leitet der Server aus der
-- Sitzung ab; eine mitgeschickte Organisation wird nur übernommen, wenn der Nutzer Mitglied ist.
-- Auswertung nur für Super-Admins (Husora-Team) über public.beta_dashboard().
-- Idempotent.

-- -----------------------------------------------------------------------------
-- 1) Globale Konfiguration (Beta später ohne Codeänderung abschaltbar)
-- -----------------------------------------------------------------------------
create table if not exists public.app_config (
  key         text primary key check (key ~ '^[a-z][a-z0-9_]{1,40}$'),
  value       jsonb not null default '{}'::jsonb check (pg_column_size(value) <= 4000),
  updated_by  uuid references public.users(id) on delete set null,
  updated_at  timestamptz not null default now()
);
comment on table public.app_config is 'Globale App-Schalter (z. B. Beta Mode); lesbar für alle, änderbar nur durch Super-Admins';
create index if not exists app_config_updated_by_idx on public.app_config (updated_by) where updated_by is not null;
insert into public.app_config (key, value)
values ('beta', '{"enabled": true, "feedback": true, "analytics": true, "error_reporting": true, "default_group": "closed_beta"}')
on conflict (key) do nothing;
alter table public.app_config enable row level security;
drop policy if exists app_config_select on public.app_config;
create policy app_config_select on public.app_config for select to anon, authenticated using (true);
drop policy if exists app_config_write on public.app_config;
create policy app_config_write on public.app_config for update to authenticated
  using ((select private.is_super_admin())) with check ((select private.is_super_admin()));
revoke all on public.app_config from anon, authenticated;
grant select on public.app_config to anon, authenticated;
grant update (value) on public.app_config to authenticated;
drop trigger if exists app_config_set_updated_at on public.app_config;
create trigger app_config_set_updated_at before update on public.app_config
  for each row execute function private.set_updated_at();
create or replace function private.app_config_actor()
returns trigger language plpgsql security definer set search_path = '' as $$
begin new.updated_by := private.current_user_id(); return new; end; $$;
drop trigger if exists app_config_actor on public.app_config;
create trigger app_config_actor before update on public.app_config
  for each row execute function private.app_config_actor();

create or replace function private.beta_config(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select (c.value ->> 'enabled')::boolean and coalesce((c.value ->> p_key)::boolean, true)
                   from public.app_config c where c.key = 'beta'), false)
$$;

-- -----------------------------------------------------------------------------
-- 2) Beta-Status am bestehenden Nutzer
-- -----------------------------------------------------------------------------
alter table public.users
  add column if not exists is_beta_user    boolean not null default false,
  add column if not exists beta_started_at timestamptz,
  add column if not exists beta_group      text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'users_beta_group_check') then
    alter table public.users add constraint users_beta_group_check
      check (beta_group is null or beta_group in ('alpha', 'closed_beta', 'open_beta', 'pre_launch'));
  end if;
end $$;
-- Nutzer dürfen ihren Beta-Status nicht selbst ändern (bestehender Schutz um die Beta-Spalten erweitert)
create or replace function private.protect_user_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' and current_user not in ('postgres', 'supabase_admin') then
    new.is_super_admin := old.is_super_admin;
    new.auth_user_id := old.auth_user_id;
    if not coalesce((select u.is_super_admin from public.users u where u.auth_user_id = auth.uid()), false) then
      new.is_beta_user := old.is_beta_user;
      new.beta_started_at := old.beta_started_at;
      new.beta_group := old.beta_group;
    end if;
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3) Feedback und Fehlerberichte: bestehende Tabelle app_feedback erweitern
-- -----------------------------------------------------------------------------
alter table public.app_feedback
  add column if not exists user_id           uuid references public.users(id) on delete set null,
  add column if not exists app_role          text,
  add column if not exists feedback_type     text,
  add column if not exists title             text,
  add column if not exists expected_behavior text,
  add column if not exists actual_behavior   text,
  add column if not exists platform          text,
  add column if not exists environment       text,
  add column if not exists severity          text,
  add column if not exists status            text not null default 'open',
  add column if not exists resolved_at       timestamptz;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'app_feedback_beta_check') then
    alter table public.app_feedback add constraint app_feedback_beta_check check (
      (app_role is null or app_role in ('owner', 'partner', 'guest'))
      and (feedback_type is null or feedback_type in ('idea', 'problem', 'missing', 'unclear', 'praise', 'other'))
      and (title is null or length(title) <= 160)
      and (expected_behavior is null or length(expected_behavior) <= 2000)
      and (actual_behavior is null or length(actual_behavior) <= 2000)
      and (platform is null or length(platform) <= 40)
      and (environment is null or environment in ('production', 'staging', 'development'))
      and (severity is null or severity in ('low', 'medium', 'high', 'critical'))
      and status in ('open', 'in_progress', 'resolved', 'wont_fix'));
  end if;
end $$;
create index if not exists app_feedback_user_idx on public.app_feedback (user_id) where user_id is not null;
create index if not exists app_feedback_org_idx on public.app_feedback (organization_id) where organization_id is not null;
create index if not exists app_feedback_status_idx on public.app_feedback (kind, status, created_at desc);

-- Nutzer und Organisation aus der Sitzung, nie vom Client; Status beim Anlegen immer „offen“
create or replace function private.app_feedback_identity()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_status text := new.status;
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
  -- UPDATE (nur Super-Admins, siehe Policy): alles außer Status/Schwere bleibt unverändert
  new := old;
  new.status := v_status;
  new.resolved_at := case when v_status in ('resolved', 'wont_fix') then coalesce(old.resolved_at, now()) else null end;
  return new;
end;
$$;
drop trigger if exists app_feedback_identity on public.app_feedback;
create trigger app_feedback_identity before insert or update on public.app_feedback
  for each row execute function private.app_feedback_identity();

-- Lesen: eigene Meldungen; Super-Admins alles. Ändern: nur Super-Admins (Status)
drop policy if exists app_feedback_select on public.app_feedback;
create policy app_feedback_select on public.app_feedback for select to authenticated
  using (auth_user_id = (select auth.uid()) or (select private.is_super_admin()));
drop policy if exists app_feedback_update on public.app_feedback;
create policy app_feedback_update on public.app_feedback for update to authenticated
  using ((select private.is_super_admin())) with check ((select private.is_super_admin()));
grant select on public.app_feedback to authenticated;
grant update (status) on public.app_feedback to authenticated;

-- Namen aus dem Brief (Lesesicht, es gelten die Regeln von app_feedback)
create or replace view public.beta_feedback with (security_invoker = true) as
  select id, organization_id as tenant_id, user_id, app_role, coalesce(feedback_type, 'other') as feedback_type, message,
         page as screen, app_version, status, created_at
  from public.app_feedback where kind = 'feedback';
create or replace view public.beta_bug_reports with (security_invoker = true) as
  select id, organization_id as tenant_id, user_id, app_role, title, message as description, expected_behavior, actual_behavior,
         page as screen, app_version, platform, environment, coalesce(severity, 'medium') as severity, status, created_at, resolved_at,
         kind = 'error' as automatic
  from public.app_feedback where kind in ('bug', 'error');
revoke all on public.beta_feedback, public.beta_bug_reports from anon;
grant select on public.beta_feedback, public.beta_bug_reports to authenticated;

-- -----------------------------------------------------------------------------
-- 4) Bewertungen und 7-/30-Tage-Umfrage
-- -----------------------------------------------------------------------------
create table if not exists public.beta_ratings (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid references public.organizations(id) on delete set null,
  user_id          uuid references public.users(id) on delete cascade,
  app_role         text check (app_role is null or app_role in ('owner', 'partner', 'guest')),
  rating           integer check (rating between 1 and 5),
  context          text not null default 'general' check (context in ('inspection', 'service', 'day7', 'day30', 'general')),
  comment          text check (comment is null or length(comment) <= 2000),
  answers          jsonb not null default '{}'::jsonb check (pg_column_size(answers) <= 4000),
  app_version      text check (app_version is null or length(app_version) <= 40),
  created_at       timestamptz not null default now(),
  check (rating is not null or context in ('day30'))
);
comment on table public.beta_ratings is 'Beta: „Wie hilfreich war Husora?“ (1–5) nach Kontrolle/Service sowie 7-/30-Tage-Umfrage';
create index if not exists beta_ratings_user_idx on public.beta_ratings (user_id, context);
create index if not exists beta_ratings_org_idx on public.beta_ratings (organization_id) where organization_id is not null;
create index if not exists beta_ratings_created_idx on public.beta_ratings (created_at desc);
create or replace function private.beta_ratings_identity()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_count integer;
begin
  new.user_id := private.current_user_id();
  if new.user_id is null then raise exception 'Bitte zuerst anmelden' using errcode = '42501'; end if;
  if new.organization_id is not null and not private.is_org_member(new.organization_id) then new.organization_id := null; end if;
  new.created_at := now();
  select count(*) into v_count from public.beta_ratings r where r.user_id = new.user_id and r.created_at > now() - interval '1 day';
  if v_count >= 20 then raise exception 'Zu viele Bewertungen – bitte später erneut versuchen.' using errcode = 'P0001'; end if;
  -- Umfragen nur einmal je Nutzer
  if new.context in ('day7', 'day30') and exists (select 1 from public.beta_ratings r where r.user_id = new.user_id and r.context = new.context) then
    raise exception 'Diese Umfrage hast du bereits beantwortet' using errcode = '23505';
  end if;
  return new;
end;
$$;
drop trigger if exists beta_ratings_identity on public.beta_ratings;
create trigger beta_ratings_identity before insert on public.beta_ratings
  for each row execute function private.beta_ratings_identity();
alter table public.beta_ratings enable row level security;
drop policy if exists beta_ratings_select on public.beta_ratings;
create policy beta_ratings_select on public.beta_ratings for select to authenticated
  using (user_id = (select private.current_user_id()) or (select private.is_super_admin()));
drop policy if exists beta_ratings_insert on public.beta_ratings;
create policy beta_ratings_insert on public.beta_ratings for insert to authenticated
  with check ((select private.current_user_id()) is not null);
revoke all on public.beta_ratings from anon, authenticated;
grant select, insert on public.beta_ratings to authenticated;

-- -----------------------------------------------------------------------------
-- 5) Analytics-Ereignisse
-- -----------------------------------------------------------------------------
create table if not exists public.analytics_events (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid references public.organizations(id) on delete set null,
  user_id          uuid references public.users(id) on delete cascade,
  event_name       text not null check (event_name ~ '^[a-z][a-z0-9_]{2,40}$'),
  entity_type      text check (entity_type is null or entity_type ~ '^[a-z][a-z0-9_]{1,40}$'),
  entity_id        uuid,
  entity_ref       text check (entity_ref is null or length(entity_ref) <= 80),
  app_role         text check (app_role is null or app_role in ('owner', 'partner', 'guest', 'system')),
  app_version      text check (app_version is null or length(app_version) <= 40),
  platform         text check (platform is null or length(platform) <= 40),
  environment      text check (environment is null or environment in ('production', 'staging', 'development')),
  source           text not null default 'client' check (source in ('client', 'server')),
  metadata         jsonb not null default '{}'::jsonb check (pg_column_size(metadata) <= 2000),
  occurred_at      timestamptz not null default now(),
  created_at       timestamptz not null default now()
);
comment on table public.analytics_events is 'Beta-Analytics: nur Ereignisse und technische Metadaten (keine Inhalte, keine Geheimnisse). Lesen nur für Super-Admins.';
create index if not exists analytics_events_name_idx on public.analytics_events (event_name, occurred_at desc);
create index if not exists analytics_events_user_idx on public.analytics_events (user_id, occurred_at desc);
create index if not exists analytics_events_org_idx on public.analytics_events (organization_id) where organization_id is not null;
-- dieselbe Sache zählt je Nutzer nur einmal (z. B. house_created für dasselbe Haus, session_started je Tag)
create unique index if not exists analytics_events_dedupe_idx on public.analytics_events (user_id, event_name, (coalesce(entity_id::text, entity_ref)))
  where user_id is not null and (entity_id is not null or entity_ref is not null);
alter table public.analytics_events enable row level security;
drop policy if exists analytics_events_select on public.analytics_events;
create policy analytics_events_select on public.analytics_events for select to authenticated
  using ((select private.is_super_admin()));
-- Schreiben nur über track_events() bzw. Server-Trigger
revoke all on public.analytics_events from anon, authenticated;
grant select on public.analytics_events to authenticated;

-- Server-Ereignis (aus Triggern); Fehler dürfen die eigentliche Aktion nie verhindern
create or replace function private.track_server_event(p_event text, p_user uuid, p_org uuid, p_entity_type text, p_entity_id uuid, p_metadata jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.beta_config('analytics') then return; end if;
  insert into public.analytics_events (organization_id, user_id, event_name, entity_type, entity_id, app_role, source, metadata)
  values (p_org, p_user, p_event, p_entity_type, p_entity_id, 'system', 'server', coalesce(p_metadata, '{}'::jsonb))
  on conflict do nothing;
exception when others then
  raise warning 'Analytics-Ereignis % nicht gespeichert: %', p_event, sqlerrm;
end;
$$;

-- Client-Ereignisse im Stapel (max. 50 je Aufruf, 2000 je Nutzer und Tag)
create or replace function public.track_events(p_events jsonb, p_organization_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
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
    where k ~ '^[a-z][a-z0-9_]{0,30}$'
      and k !~ '(pass|token|secret|auth|key|mail|phone|name|address|message|note|text)'
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
$$;
revoke all on function public.track_events(jsonb, uuid) from public, anon;
grant execute on function public.track_events(jsonb, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 6) Server-Ereignisse aus Triggern (zählen nur, was wirklich gespeichert wurde)
-- -----------------------------------------------------------------------------
create or replace function private.beta_events_users()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.track_server_event('user_registered', new.id, null, 'user', new.id);
  return null;
end; $$;
drop trigger if exists users_beta_events on public.users;
create trigger users_beta_events after insert on public.users
  for each row execute function private.beta_events_users();

create or replace function private.beta_events_orders()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_partner_org uuid;
begin
  select sp.partner_organization_id into v_partner_org from public.service_partners sp where sp.id = new.service_partner_id;
  -- nur echte Anfragen an einen verbundenen fremden Partner, keine eigenen Aufträge des Partners
  if v_partner_org is null or v_partner_org = new.organization_id then return null; end if;
  if tg_op = 'INSERT' then
    perform private.track_server_event('service_request_created', coalesce(new.created_by, private.current_user_id()), new.organization_id, 'service_order', new.id,
                                       jsonb_build_object('order_type', new.order_type, 'priority', new.priority));
  end if;
  if tg_op = 'INSERT' and new.status in ('accepted', 'scheduled') or tg_op = 'UPDATE' and new.status in ('accepted', 'scheduled') and old.status = 'offered' then
    perform private.track_server_event('service_request_accepted', private.current_user_id(), v_partner_org, 'service_order', new.id,
                                       jsonb_build_object('auto', private.current_user_id() is null or tg_op = 'INSERT'));
  end if;
  if new.status = 'completed' and (tg_op = 'INSERT' or old.status is distinct from 'completed') then
    perform private.track_server_event('service_completed', private.current_user_id(), v_partner_org, 'service_order', new.id,
                                       jsonb_build_object('order_type', new.order_type));
  end if;
  return null;
end; $$;
drop trigger if exists service_orders_beta_events on public.service_orders;
create trigger service_orders_beta_events after insert or update of status on public.service_orders
  for each row execute function private.beta_events_orders();

create or replace function private.beta_events_inspections()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'in_progress' and (tg_op = 'INSERT' or old.status is distinct from 'in_progress') then
    perform private.track_server_event('inspection_started', private.current_user_id(), new.organization_id, 'inspection', new.id);
  end if;
  if new.status = 'completed' and (tg_op = 'INSERT' or old.status is distinct from 'completed') then
    perform private.track_server_event('inspection_completed', private.current_user_id(), new.organization_id, 'inspection', new.id);
  end if;
  return null;
end; $$;
drop trigger if exists inspections_beta_events on public.inspections;
create trigger inspections_beta_events after insert or update of status on public.inspections
  for each row execute function private.beta_events_inspections();

create or replace function private.beta_events_partners()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'service_partner_invites' then
    perform private.track_server_event('partner_invited', private.current_user_id(), new.organization_id, 'service_partner', new.service_partner_id);
  elsif new.partner_organization_id is not null and new.partner_organization_id <> new.organization_id
        and (tg_op = 'INSERT' or old.partner_organization_id is null) then
    perform private.track_server_event('partner_connected', private.current_user_id(), new.partner_organization_id, 'service_partner', new.id);
  end if;
  return null;
end; $$;
drop trigger if exists service_partner_invites_beta_events on public.service_partner_invites;
create trigger service_partner_invites_beta_events after insert on public.service_partner_invites
  for each row execute function private.beta_events_partners();
drop trigger if exists service_partners_beta_events on public.service_partners;
create trigger service_partners_beta_events after insert or update of partner_organization_id on public.service_partners
  for each row execute function private.beta_events_partners();

create or replace function private.beta_events_feedback()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.user_id is null then return null; end if;
  if tg_table_name = 'beta_ratings' then
    perform private.track_server_event('rating_created', new.user_id, new.organization_id, 'beta_rating', new.id,
                                       jsonb_build_object('context', new.context, 'rating', new.rating));
  elsif new.kind = 'feedback' then
    perform private.track_server_event('feedback_created', new.user_id, new.organization_id, 'feedback', new.id,
                                       jsonb_build_object('type', coalesce(new.feedback_type, 'other')));
  elsif new.kind = 'bug' then
    perform private.track_server_event('bug_report_created', new.user_id, new.organization_id, 'bug_report', new.id,
                                       jsonb_build_object('severity', new.severity));
  end if;
  return null;
end; $$;
drop trigger if exists app_feedback_beta_events on public.app_feedback;
create trigger app_feedback_beta_events after insert on public.app_feedback
  for each row execute function private.beta_events_feedback();
drop trigger if exists beta_ratings_beta_events on public.beta_ratings;
create trigger beta_ratings_beta_events after insert on public.beta_ratings
  for each row execute function private.beta_events_feedback();

-- -----------------------------------------------------------------------------
-- 7) Auswertung für das Husora-Team (Super-Admin)
-- -----------------------------------------------------------------------------
create or replace function public.beta_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if not private.is_super_admin() then raise exception 'Nur für das Husora-Team' using errcode = '42501'; end if;
  with
  owners as (
    select distinct m.user_id from public.organization_members m join public.organizations o on o.id = m.organization_id
    where m.status = 'active' and o.org_type in ('homeowner', 'both')),
  partners as (
    select distinct m.user_id from public.organization_members m join public.organizations o on o.id = m.organization_id
    where m.status = 'active' and o.org_type in ('service_partner', 'both')),
  ev as (select e.user_id, e.event_name, e.occurred_at from public.analytics_events e where e.user_id is not null),
  did as (select event_name, count(distinct user_id) as n from ev group by event_name),
  activity as (select user_id, min(occurred_at) as first_at, max(occurred_at) as last_at from ev group by user_id),
  ret7 as (
    select count(*) filter (where exists (select 1 from ev x where x.user_id = a.user_id and x.occurred_at >= a.first_at + interval '7 days')) as back,
           count(*) as base
    from activity a where a.first_at <= now() - interval '7 days'),
  ret30 as (
    select count(*) filter (where exists (select 1 from ev x where x.user_id = a.user_id and x.occurred_at >= a.first_at + interval '30 days')) as back,
           count(*) as base
    from activity a where a.first_at <= now() - interval '30 days'),
  porgs as (
    select o.id,
           (o.phone is not null or o.email is not null) and exists (select 1 from public.service_partner_services s join public.service_partners sp on sp.id = s.service_partner_id where sp.organization_id = o.id)
             and exists (select 1 from public.service_partner_areas a join public.service_partners sp on sp.id = a.service_partner_id where sp.organization_id = o.id) as complete,
           exists (select 1 from public.service_partner_services s join public.service_partners sp on sp.id = s.service_partner_id where sp.organization_id = o.id) as has_service,
           exists (select 1 from public.service_orders so join public.service_partners sp on sp.id = so.service_partner_id where sp.partner_organization_id = o.id and so.organization_id <> o.id) as got_request,
           exists (select 1 from public.service_orders so join public.service_partners sp on sp.id = so.service_partner_id where sp.partner_organization_id = o.id and so.organization_id <> o.id and so.status not in ('offered', 'rejected', 'draft')) as accepted,
           exists (select 1 from public.service_orders so join public.service_partners sp on sp.id = so.service_partner_id where sp.partner_organization_id = o.id and so.organization_id <> o.id and so.status = 'completed') as completed
    from public.organizations o where o.org_type in ('service_partner', 'both')),
  foreign_orders as (
    select so.* from public.service_orders so join public.service_partners sp on sp.id = so.service_partner_id
    where sp.partner_organization_id is not null and sp.partner_organization_id <> so.organization_id)
  select jsonb_build_object(
    'generated_at', now(),
    'config', (select c.value from public.app_config c where c.key = 'beta'),
    'users', jsonb_build_object(
      'registered', (select count(*) from public.users),
      'owners', (select count(*) from owners),
      'partners', (select count(*) from partners),
      'beta_users', (select count(*) from public.users where is_beta_user),
      'beta_groups', (select coalesce(jsonb_object_agg(g, n), '{}'::jsonb) from (select coalesce(beta_group, 'ohne') g, count(*) n from public.users where is_beta_user group by 1) x),
      'active_today', (select count(distinct user_id) from ev where occurred_at >= date_trunc('day', now())),
      'active_7d', (select count(distinct user_id) from ev where occurred_at >= now() - interval '7 days'),
      'active_30d', (select count(distinct user_id) from ev where occurred_at >= now() - interval '30 days')),
    'content', jsonb_build_object(
      'houses', (select count(*) from public.properties where status <> 'archived'),
      'houses_events', (select count(*) from public.analytics_events where event_name = 'house_created'),
      'tasks', (select count(*) from public.service_tasks) + (select count(*) from public.analytics_events where event_name = 'task_created'),
      'inspections', (select count(*) from public.inspections where status = 'completed') + (select count(*) from public.analytics_events where event_name = 'inspection_completed' and source = 'client')),
    'services', jsonb_build_object(
      'requests', (select count(*) from foreign_orders),
      'accepted', (select count(*) from foreign_orders where status not in ('offered', 'rejected', 'draft', 'cancelled')),
      'completed', (select count(*) from foreign_orders where status = 'completed')),
    'quality', jsonb_build_object(
      'avg_rating', (select round(avg(rating)::numeric, 2) from public.beta_ratings where rating is not null),
      'ratings', (select count(*) from public.beta_ratings where rating is not null),
      'open_bugs', (select count(*) from public.app_feedback where kind in ('bug', 'error') and status in ('open', 'in_progress')),
      'open_feedback', (select count(*) from public.app_feedback where kind = 'feedback' and status in ('open', 'in_progress')),
      'subscription_interest', (select coalesce(jsonb_object_agg(f, n), '{}'::jsonb) from (select coalesce(metadata ->> 'feature', 'allgemein') f, count(distinct user_id) n from public.analytics_events where event_name = 'subscription_interest' group by 1) x),
      'value_per_month', (select coalesce(jsonb_object_agg(v, n), '{}'::jsonb) from (select answers ->> 'value' v, count(*) n from public.beta_ratings where context = 'day30' and answers ? 'value' group by 1) x),
      'continue', (select coalesce(jsonb_object_agg(v, n), '{}'::jsonb) from (select answers ->> 'continue' v, count(*) n from public.beta_ratings where context = 'day30' and answers ? 'continue' group by 1) x)),
    'funnel_owner', jsonb_build_array(
      jsonb_build_object('step', 'Registrierung', 'n', (select count(*) from owners)),
      jsonb_build_object('step', 'Onboarding abgeschlossen', 'n', (select coalesce(max(n), 0) from did where event_name = 'onboarding_completed')),
      jsonb_build_object('step', 'Haus erstellt', 'n', (select coalesce(max(n), 0) from did where event_name = 'house_created')),
      jsonb_build_object('step', 'Aufgabe erstellt', 'n', (select coalesce(max(n), 0) from did where event_name = 'task_created')),
      jsonb_build_object('step', 'Hauskontrolle', 'n', (select count(distinct user_id) from ev where event_name = 'inspection_completed' and user_id in (select user_id from owners))),
      jsonb_build_object('step', 'Service gesucht', 'n', (select coalesce(max(n), 0) from did where event_name = 'service_search')),
      jsonb_build_object('step', 'Serviceanfrage', 'n', (select coalesce(max(n), 0) from did where event_name = 'service_request_created')),
      jsonb_build_object('step', 'Service abgeschlossen', 'n', (select count(distinct so.organization_id) from foreign_orders so where so.status = 'completed'))),
    'funnel_partner', jsonb_build_array(
      jsonb_build_object('step', 'Registrierung', 'n', (select count(*) from porgs)),
      jsonb_build_object('step', 'Profil vollständig', 'n', (select count(*) from porgs where complete)),
      jsonb_build_object('step', 'Leistung erstellt', 'n', (select count(*) from porgs where has_service)),
      jsonb_build_object('step', 'Anfrage erhalten', 'n', (select count(*) from porgs where got_request)),
      jsonb_build_object('step', 'Anfrage angenommen', 'n', (select count(*) from porgs where accepted)),
      jsonb_build_object('step', 'Service abgeschlossen', 'n', (select count(*) from porgs where completed))),
    'kpis', jsonb_build_array(
      jsonb_build_object('key', 'registration_house', 'label', 'Registrierung → erstes Haus', 'target', 60,
        'value', (select round(100.0 * count(*) filter (where exists (select 1 from ev x where x.user_id = o.user_id and x.event_name = 'house_created')) / nullif(count(*), 0)) from owners o)),
      jsonb_build_object('key', 'house_task', 'label', 'Haus → erste Aufgabe', 'target', 50,
        'value', (select round(100.0 * count(*) filter (where exists (select 1 from ev x where x.user_id = h.user_id and x.event_name = 'task_created')) / nullif(count(*), 0))
                  from (select distinct user_id from ev where event_name = 'house_created') h)),
      jsonb_build_object('key', 'return_7d', 'label', '7-Tage-Wiederkehr', 'target', 30, 'value', (select round(100.0 * back / nullif(base, 0)) from ret7)),
      jsonb_build_object('key', 'return_30d', 'label', '30-Tage-Wiederkehr', 'target', 20, 'value', (select round(100.0 * back / nullif(base, 0)) from ret30)),
      jsonb_build_object('key', 'inspection', 'label', 'Hauskontrolle durchgeführt', 'target', 30,
        'value', (select round(100.0 * count(*) filter (where exists (select 1 from ev x where x.user_id = o.user_id and x.event_name = 'inspection_completed')) / nullif(count(*), 0)) from owners o)),
      jsonb_build_object('key', 'partner_profile', 'label', 'Partnerprofil vollständig', 'target', 60,
        'value', (select round(100.0 * count(*) filter (where complete) / nullif(count(*), 0)) from porgs)),
      jsonb_build_object('key', 'service_request', 'label', 'Serviceanfrage gestellt', 'target', 20,
        'value', (select round(100.0 * count(distinct so.organization_id) / nullif((select count(*) from public.organizations where org_type in ('homeowner', 'both')), 0)) from foreign_orders so)),
      jsonb_build_object('key', 'avg_rating', 'label', 'Durchschnittliche Bewertung', 'target', 4, 'unit', 'stars',
        'value', (select round(avg(rating)::numeric, 1) from public.beta_ratings where rating is not null))),
    'events_7d', (select coalesce(jsonb_object_agg(event_name, n), '{}'::jsonb) from (select event_name, count(*) n from public.analytics_events where occurred_at >= now() - interval '7 days' group by 1) x)
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.beta_dashboard() from public, anon;
grant execute on function public.beta_dashboard() to authenticated;
