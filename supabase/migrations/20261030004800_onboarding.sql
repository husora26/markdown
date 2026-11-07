-- =============================================================================
-- HUSORA · Onboarding (Spezifikation „Onboarding Architecture“, Flows homeowner_v1 / service_partner_v1)
-- =============================================================================
-- Speichert nur Fortschritt und Referenzen – keine Haus- oder Firmendaten (die bleiben in properties /
-- organizations bzw. lokal in der App). Rollen = bestehendes Modell: Hausbesitzer-App (homeowner) und
-- Partner-Portal (service_partner, Mitglied einer Organisation vom Typ service_partner/both).
-- Lesen nur eigene Zeilen (RLS), Schreiben ausschließlich über die RPCs unten (Identität aus auth.uid()).

create table if not exists public.onboarding_sessions (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references public.users(id) on delete cascade,
  role_key              text not null check (role_key in ('homeowner', 'service_partner')),
  flow_version          text not null check (flow_version ~ '^(homeowner|service_partner)_v[0-9]{1,3}$'),
  current_step_key      text check (current_step_key is null or current_step_key ~ '^[a-z][a-z0-9_]{1,39}$'),
  status                text not null default 'in_progress' check (status in ('not_started', 'in_progress', 'completed', 'skipped')),
  paused                boolean not null default false,
  primary_property_ref  text check (primary_property_ref is null or length(primary_property_ref) <= 80),
  organization_id       uuid references public.organizations(id) on delete set null,
  started_at            timestamptz not null default now(),
  completed_at          timestamptz,
  last_activity_at      timestamptz not null default now(),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (user_id, role_key, flow_version)
);
comment on table public.onboarding_sessions is 'Onboarding-Fortschritt je Nutzer, Rolle und Flow-Version (nur Status und Referenzen, keine Inhalte)';
create index if not exists onboarding_sessions_user_idx on public.onboarding_sessions (user_id, role_key, status);
create index if not exists onboarding_sessions_org_idx on public.onboarding_sessions (organization_id) where organization_id is not null;

create table if not exists public.onboarding_step_progress (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid not null references public.onboarding_sessions(id) on delete cascade,
  step_key      text not null check (step_key ~ '^[a-z][a-z0-9_]{1,39}$'),
  status        text not null default 'pending' check (status in ('pending', 'in_progress', 'completed', 'skipped')),
  started_at    timestamptz,
  completed_at  timestamptz,
  metadata      jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object' and pg_column_size(metadata) <= 1000),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (session_id, step_key)
);
create index if not exists onboarding_step_progress_session_idx on public.onboarding_step_progress (session_id, status);

create table if not exists public.user_onboarding_preferences (
  user_id                  uuid primary key references public.users(id) on delete cascade,
  onboarding_dismissed_at  timestamptz,
  help_tips_enabled        boolean not null default true,
  dismissed_guides         text[] not null default '{}' check (cardinality(dismissed_guides) <= 100),
  updated_at               timestamptz not null default now()
);

drop trigger if exists onboarding_sessions_set_updated_at on public.onboarding_sessions;
create trigger onboarding_sessions_set_updated_at before update on public.onboarding_sessions for each row execute function private.set_updated_at();
drop trigger if exists onboarding_step_progress_set_updated_at on public.onboarding_step_progress;
create trigger onboarding_step_progress_set_updated_at before update on public.onboarding_step_progress for each row execute function private.set_updated_at();
drop trigger if exists user_onboarding_preferences_set_updated_at on public.user_onboarding_preferences;
create trigger user_onboarding_preferences_set_updated_at before update on public.user_onboarding_preferences for each row execute function private.set_updated_at();

alter table public.onboarding_sessions enable row level security;
alter table public.onboarding_step_progress enable row level security;
alter table public.user_onboarding_preferences enable row level security;
drop policy if exists onboarding_sessions_own on public.onboarding_sessions;
create policy onboarding_sessions_own on public.onboarding_sessions for select to authenticated using (user_id = (select private.current_user_id()));
drop policy if exists onboarding_steps_own on public.onboarding_step_progress;
create policy onboarding_steps_own on public.onboarding_step_progress for select to authenticated
  using (exists (select 1 from public.onboarding_sessions s where s.id = session_id and s.user_id = (select private.current_user_id())));
drop policy if exists onboarding_prefs_own on public.user_onboarding_preferences;
create policy onboarding_prefs_own on public.user_onboarding_preferences for select to authenticated using (user_id = (select private.current_user_id()));
revoke all on public.onboarding_sessions, public.onboarding_step_progress, public.user_onboarding_preferences from anon, authenticated;
grant select on public.onboarding_sessions, public.onboarding_step_progress, public.user_onboarding_preferences to authenticated;

-- Gültige Schritte je Flow-Version (Reihenfolge = Anzeige)
create or replace function private.onboarding_flow_steps(p_flow text)
returns text[] language sql immutable set search_path = '' as $$
  select case p_flow
    when 'homeowner_v1' then array['welcome', 'property', 'profile', 'task', 'inspection', 'automation', 'partners', 'organize', 'done']
    when 'service_partner_v1' then array['welcome', 'profile', 'area', 'services', 'orders', 'workflow', 'documentation', 'finance', 'team', 'done']
  end
$$;

-- Zustand als JSON (Sitzung, Schritte, Präferenzen) – nur für den angemeldeten Nutzer
create or replace function private.onboarding_state_json(p_user uuid, p_role text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'session', (select to_jsonb(s) - 'user_id' from public.onboarding_sessions s where s.user_id = p_user and s.role_key = p_role order by s.updated_at desc limit 1),
    'steps', coalesce((select jsonb_object_agg(p.step_key, jsonb_build_object('status', p.status, 'completed_at', p.completed_at, 'metadata', p.metadata))
                       from public.onboarding_step_progress p
                       where p.session_id = (select s.id from public.onboarding_sessions s where s.user_id = p_user and s.role_key = p_role order by s.updated_at desc limit 1)), '{}'::jsonb),
    'preferences', coalesce((select to_jsonb(x) - 'user_id' from public.user_onboarding_preferences x where x.user_id = p_user), jsonb_build_object('help_tips_enabled', true, 'dismissed_guides', '[]'::jsonb)))
$$;

create or replace function private.onboarding_user(p_role text)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare v_user uuid := private.current_user_id();
begin
  if v_user is null then raise exception 'Bitte anmelden' using errcode = '42501'; end if;
  if p_role not in ('homeowner', 'service_partner') then raise exception 'Unbekannte Rolle' using errcode = '22023'; end if;
  -- Servicepartner-Flow nur für Mitglieder eines Servicebetriebs
  if p_role = 'service_partner' and not exists (
       select 1 from public.organization_members m join public.organizations o on o.id = m.organization_id
       where m.user_id = v_user and m.status = 'active' and o.org_type in ('service_partner', 'both')) then
    raise exception 'Kein Servicebetrieb verbunden' using errcode = '42501';
  end if;
  return v_user;
end; $$;

create or replace function public.onboarding_get(p_role text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  return private.onboarding_state_json(private.onboarding_user(p_role), p_role);
end; $$;

-- Schritt speichern (idempotent). Erlaubte Übergänge: pending→in_progress→completed, pending/in_progress→skipped,
-- skipped→in_progress/completed (später erledigt). completed bleibt completed (außer nach Neustart).
create or replace function public.onboarding_save(p_role text, p_flow text, p_step text, p_status text,
                                                  p_current text default null, p_metadata jsonb default null, p_refs jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user  uuid := private.onboarding_user(p_role);
  v_steps text[] := private.onboarding_flow_steps(p_flow);
  v_sess  public.onboarding_sessions;
  v_prev  text;
  v_meta  jsonb := coalesce(p_metadata, '{}'::jsonb);
  v_org   uuid;
begin
  if v_steps is null or split_part(p_flow, '_v', 1) <> p_role then raise exception 'Unbekannte Flow-Version' using errcode = '22023'; end if;
  if p_step is not null and not (p_step = any (v_steps)) then raise exception 'Unbekannter Schritt' using errcode = '22023'; end if;
  if p_current is not null and not (p_current = any (v_steps)) then raise exception 'Unbekannter Schritt' using errcode = '22023'; end if;
  if p_status is not null and p_status not in ('in_progress', 'completed', 'skipped') then raise exception 'Unbekannter Status' using errcode = '22023'; end if;
  if jsonb_typeof(v_meta) <> 'object' or pg_column_size(v_meta) > 1000 then raise exception 'Metadaten zu groß' using errcode = '22023'; end if;
  -- nur technische Metadaten (Schlüssel/Werte kurz, keine Freitexte)
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into v_meta from jsonb_each(v_meta) e(k, v)
  where k ~ '^[a-z][a-z0-9_]{0,30}$' and (jsonb_typeof(v) in ('number', 'boolean') or (jsonb_typeof(v) = 'string' and length(v #>> '{}') <= 60));
  if p_role = 'service_partner' then
    v_org := nullif(p_refs ->> 'organization_id', '')::uuid;
    if v_org is not null and not exists (select 1 from public.organization_members m where m.user_id = v_user and m.organization_id = v_org and m.status = 'active') then v_org := null; end if;
  end if;

  insert into public.onboarding_sessions (user_id, role_key, flow_version, current_step_key, status)
  values (v_user, p_role, p_flow, coalesce(p_current, p_step, v_steps[1]), 'in_progress')
  on conflict (user_id, role_key, flow_version) do update set last_activity_at = now()
  returning * into v_sess;
  update public.onboarding_sessions s set
    current_step_key = coalesce(p_current, s.current_step_key),
    paused = case when p_refs ? 'paused' then coalesce((p_refs ->> 'paused')::boolean, false) else s.paused end,
    primary_property_ref = case when p_refs ? 'primary_property_ref' then left(p_refs ->> 'primary_property_ref', 80) else s.primary_property_ref end,
    organization_id = coalesce(v_org, s.organization_id),
    last_activity_at = now()
  where s.id = v_sess.id returning * into v_sess;

  if p_step is not null and p_status is not null then
    select status into v_prev from public.onboarding_step_progress where session_id = v_sess.id and step_key = p_step;
    if v_prev is null then
      insert into public.onboarding_step_progress (session_id, step_key, status, started_at, completed_at, metadata)
      values (v_sess.id, p_step, p_status, now(), case when p_status = 'completed' then now() end, v_meta);
    elsif v_prev <> 'completed' and not (v_prev = 'skipped' and p_status = 'skipped') then
      update public.onboarding_step_progress set status = p_status,
             completed_at = case when p_status = 'completed' then now() end,
             metadata = metadata || v_meta
      where session_id = v_sess.id and step_key = p_step;
    elsif v_prev = 'completed' and v_meta <> '{}'::jsonb then
      update public.onboarding_step_progress set metadata = metadata || v_meta where session_id = v_sess.id and step_key = p_step;
    end if;
  end if;
  return private.onboarding_state_json(v_user, p_role);
end; $$;

-- Abschließen oder ganz überspringen
create or replace function public.onboarding_finish(p_role text, p_flow text, p_status text default 'completed')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := private.onboarding_user(p_role);
begin
  if private.onboarding_flow_steps(p_flow) is null or split_part(p_flow, '_v', 1) <> p_role then raise exception 'Unbekannte Flow-Version' using errcode = '22023'; end if;
  if p_status not in ('completed', 'skipped') then raise exception 'Unbekannter Status' using errcode = '22023'; end if;
  insert into public.onboarding_sessions (user_id, role_key, flow_version, current_step_key, status, completed_at, paused)
  values (v_user, p_role, p_flow, 'done', p_status, now(), false)
  on conflict (user_id, role_key, flow_version) do update
    set status = case when public.onboarding_sessions.status = 'completed' then 'completed' else excluded.status end,
        completed_at = coalesce(public.onboarding_sessions.completed_at, now()), current_step_key = 'done', paused = false, last_activity_at = now();
  if p_status = 'completed' then
    insert into public.onboarding_step_progress (session_id, step_key, status, started_at, completed_at)
    select s.id, 'done', 'completed', now(), now() from public.onboarding_sessions s where s.user_id = v_user and s.role_key = p_role and s.flow_version = p_flow
    on conflict (session_id, step_key) do nothing;
  end if;
  return private.onboarding_state_json(v_user, p_role);
end; $$;

-- Erneut starten (Einstellungen / Hilfe): Schritte zurücksetzen, echte Daten bleiben unberührt
create or replace function public.onboarding_restart(p_role text, p_flow text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := private.onboarding_user(p_role);
begin
  if private.onboarding_flow_steps(p_flow) is null or split_part(p_flow, '_v', 1) <> p_role then raise exception 'Unbekannte Flow-Version' using errcode = '22023'; end if;
  delete from public.onboarding_step_progress p using public.onboarding_sessions s
  where p.session_id = s.id and s.user_id = v_user and s.role_key = p_role and s.flow_version = p_flow;
  insert into public.onboarding_sessions (user_id, role_key, flow_version, current_step_key, status)
  values (v_user, p_role, p_flow, (private.onboarding_flow_steps(p_flow))[1], 'in_progress')
  on conflict (user_id, role_key, flow_version) do update
    set status = 'in_progress', completed_at = null, paused = false, current_step_key = excluded.current_step_key, started_at = now(), last_activity_at = now();
  update public.user_onboarding_preferences set onboarding_dismissed_at = null where user_id = v_user;
  return private.onboarding_state_json(v_user, p_role);
end; $$;

-- Präferenzen: Checkliste ausblenden, Hilfe-Tipps, einzelne Feature-Guides „nicht mehr anzeigen“
create or replace function public.onboarding_preferences(p_dismissed boolean default null, p_help_tips boolean default null,
                                                         p_guide text default null, p_guide_dismissed boolean default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := private.current_user_id();
begin
  if v_user is null then raise exception 'Bitte anmelden' using errcode = '42501'; end if;
  if p_guide is not null and p_guide !~ '^[a-z][a-z0-9_]{1,39}$' then raise exception 'Unbekannter Hinweis' using errcode = '22023'; end if;
  insert into public.user_onboarding_preferences (user_id) values (v_user) on conflict (user_id) do nothing;
  update public.user_onboarding_preferences x set
    onboarding_dismissed_at = case when p_dismissed is null then x.onboarding_dismissed_at when p_dismissed then coalesce(x.onboarding_dismissed_at, now()) else null end,
    help_tips_enabled = coalesce(p_help_tips, x.help_tips_enabled),
    dismissed_guides = case when p_guide is null then x.dismissed_guides
                            when coalesce(p_guide_dismissed, true) then (select array_agg(distinct g) from unnest(x.dismissed_guides || p_guide) g)
                            else array_remove(x.dismissed_guides, p_guide) end
  where x.user_id = v_user;
  return (select to_jsonb(x) - 'user_id' from public.user_onboarding_preferences x where x.user_id = v_user);
end; $$;

revoke all on function private.onboarding_flow_steps(text), private.onboarding_state_json(uuid, text), private.onboarding_user(text) from public, anon, authenticated;
revoke all on function public.onboarding_get(text), public.onboarding_save(text, text, text, text, text, jsonb, jsonb), public.onboarding_finish(text, text, text),
                       public.onboarding_restart(text, text), public.onboarding_preferences(boolean, boolean, text, boolean) from public, anon;
grant execute on function public.onboarding_get(text), public.onboarding_save(text, text, text, text, text, jsonb, jsonb), public.onboarding_finish(text, text, text),
                          public.onboarding_restart(text, text), public.onboarding_preferences(boolean, boolean, text, boolean) to authenticated;
