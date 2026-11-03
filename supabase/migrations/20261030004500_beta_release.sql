-- =============================================================================
-- HUSORA · Beta Release & App Distribution (Android + iOS)
-- =============================================================================
-- Grundlage: „Husora Beta Release & App Distribution Specification“ v1.0 (03.11.2026)
--   1) Tester-Felder an public.users (Spec §10/§25) – nur ergänzt, was fehlt:
--        is_beta_tester  → vorhanden als users.is_beta_user (Migration 3700)
--        beta_joined_at  → vorhanden als users.beta_started_at
--        beta_group      → vorhanden, aber als Phase (alpha/closed_beta/…). Die Zielgruppe der Spec
--                          (homeowner/service_partner/internal) heißt deshalb tester_group.
--        neu: tester_group, app_platform, last_app_version, last_app_build, last_environment, last_seen_at, beta_invite_id
--   2) Umgebungskennung app_config 'environment' (beta | production …) – die App prüft beim Start, dass
--      sie mit der richtigen Datenbank spricht. Nur per SQL änderbar, nie aus der App.
--   3) app_config 'release' (Store-Links, Mindest-Build, Einladungspflicht, Support) und 'maintenance'
--   4) Einladungscodes (beta_invites): nur Hash gespeichert, Einlösen begrenzt, serverseitige Sperre:
--      Ist die Einladungspflicht aktiv, kann ohne eingelösten Code keine Organisation angelegt werden.
--   5) report_app_session(): App-Version/Build/Plattform/Umgebung beim Start bzw. Login (Spec §24)
--   6) my_beta_status(): Rollen für das Routing nach dem Login (Hausbesitzer / Servicepartner / Admin)
--   7) Admin: beta_testers_overview() (pseudonymisiert), Einladungen verwalten, Tester markieren
-- Idempotent.

-- -----------------------------------------------------------------------------
-- 1) Tester-Felder
-- -----------------------------------------------------------------------------
alter table public.users
  add column if not exists tester_group     text,
  add column if not exists app_platform     text,
  add column if not exists last_app_version text,
  add column if not exists last_app_build   text,
  add column if not exists last_environment text,
  add column if not exists last_seen_at     timestamptz,
  add column if not exists beta_invite_id   uuid;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'users_tester_group_check') then
    alter table public.users add constraint users_tester_group_check
      check (tester_group is null or tester_group in ('homeowner', 'service_partner', 'internal'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'users_app_meta_check') then
    alter table public.users add constraint users_app_meta_check
      check ((app_platform is null or app_platform ~ '^[a-z0-9-]{1,20}$')
         and (last_app_version is null or length(last_app_version) <= 40)
         and (last_app_build is null or length(last_app_build) <= 20)
         and (last_environment is null or last_environment in ('development', 'staging', 'beta', 'production')));
  end if;
end $$;
comment on column public.users.tester_group is 'Beta-Zielgruppe (Spec §10): homeowner | service_partner | internal. users.beta_group ist die Beta-Phase.';
comment on column public.users.last_seen_at is 'Letzter App-Start/Login (report_app_session) – für die Beta-Auswertung.';

-- Schutz: Beta-/App-Felder setzt nur der Server (Definer-RPCs) bzw. ein Super-Admin
create or replace function private.protect_user_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' and current_user not in ('postgres', 'supabase_admin') then
    new.is_super_admin := old.is_super_admin;
    new.auth_user_id := old.auth_user_id;
    new.app_platform := old.app_platform;
    new.last_app_version := old.last_app_version;
    new.last_app_build := old.last_app_build;
    new.last_environment := old.last_environment;
    new.last_seen_at := old.last_seen_at;
    new.beta_invite_id := old.beta_invite_id;
    if not private.has_admin_role('super_admin') then
      new.is_beta_user := old.is_beta_user;
      new.beta_started_at := old.beta_started_at;
      new.beta_group := old.beta_group;
      new.tester_group := old.tester_group;
      new.admin_roles := old.admin_roles;
    end if;
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2) + 3) Konfiguration
-- -----------------------------------------------------------------------------
-- Neue Datenbanken gelten als Beta. Für Production nach dem Einspielen per SQL setzen:
--   update public.app_config set value = '{"name": "production"}' where key = 'environment';
insert into public.app_config (key, value) values ('environment', '{"name": "beta"}') on conflict (key) do nothing;
insert into public.app_config (key, value) values ('maintenance', '{"enabled": false, "blocking": false, "message": null}') on conflict (key) do nothing;
insert into public.app_config (key, value) values ('release', '{"latest_version": "1.0.0-beta.1", "min_build": {"android": 0, "ios": 0}, "android_beta_url": null, "ios_beta_url": null, "support_email": null, "feedback_url": null, "invite_required": false}')
  on conflict (key) do nothing;

-- 'environment' ist aus der App nie änderbar (auch nicht für Admins) – nur per SQL/Migration
drop policy if exists app_config_write on public.app_config;
create policy app_config_write on public.app_config for update to authenticated
  using (key <> 'environment' and case when key in ('imprint') then private.has_admin_role('content_admin') else private.has_admin_role('super_admin') end)
  with check (key <> 'environment' and case when key in ('imprint') then private.has_admin_role('content_admin') else private.has_admin_role('super_admin') end);

create or replace function private.config_bool(p_key text, p_field text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select (c.value ->> p_field)::boolean from public.app_config c where c.key = p_key), false)
$$;

-- -----------------------------------------------------------------------------
-- 4) Einladungscodes
-- -----------------------------------------------------------------------------
create table if not exists public.beta_invites (
  id            uuid primary key default gen_random_uuid(),
  code_hash     text not null unique check (code_hash ~ '^[0-9a-f]{64}$'),
  code_hint     text not null check (length(code_hint) <= 12),
  label         text check (label is null or length(label) <= 120),
  tester_group  text check (tester_group is null or tester_group in ('homeowner', 'service_partner', 'internal')),
  max_uses      integer not null default 1 check (max_uses between 1 and 1000),
  used_count    integer not null default 0 check (used_count >= 0),
  expires_at    timestamptz,
  active        boolean not null default true,
  created_by    uuid references public.users(id) on update cascade on delete set null,
  created_at    timestamptz not null default now()
);
comment on table public.beta_invites is 'Beta-Einladungscodes. Gespeichert wird nur der SHA-256-Hash; der Klartext wird beim Anlegen einmal angezeigt.';
create index if not exists beta_invites_created_by_idx on public.beta_invites (created_by) where created_by is not null;

create table if not exists public.beta_invite_redemptions (
  invite_id    uuid not null references public.beta_invites(id) on delete cascade,
  user_id      uuid not null references public.users(id) on update cascade on delete cascade,
  redeemed_at  timestamptz not null default now(),
  primary key (invite_id, user_id)
);
create index if not exists beta_invite_redemptions_user_idx on public.beta_invite_redemptions (user_id);

create table if not exists public.beta_invite_attempts (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.users(id) on update cascade on delete cascade,
  created_at  timestamptz not null default now()
);
create index if not exists beta_invite_attempts_user_idx on public.beta_invite_attempts (user_id, created_at desc);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'users_beta_invite_fk') then
    alter table public.users add constraint users_beta_invite_fk foreign key (beta_invite_id) references public.beta_invites(id) on delete set null;
  end if;
end $$;
create index if not exists users_beta_invite_idx on public.users (beta_invite_id) where beta_invite_id is not null;

alter table public.beta_invites enable row level security;
alter table public.beta_invite_redemptions enable row level security;
alter table public.beta_invite_attempts enable row level security;
drop policy if exists beta_invites_admin_read on public.beta_invites;
create policy beta_invites_admin_read on public.beta_invites for select to authenticated using (private.has_admin_role('support_admin'));
drop policy if exists beta_invite_redemptions_read on public.beta_invite_redemptions;
create policy beta_invite_redemptions_read on public.beta_invite_redemptions for select to authenticated
  using (user_id = (select private.current_user_id()) or private.has_admin_role('support_admin'));
revoke all on public.beta_invites, public.beta_invite_redemptions, public.beta_invite_attempts from anon, authenticated;
grant select (id, code_hint, label, tester_group, max_uses, used_count, expires_at, active, created_at) on public.beta_invites to authenticated;
grant select on public.beta_invite_redemptions to authenticated;

create or replace function private.invite_hash(p_code text)
returns text language sql immutable set search_path = '' as $$
  select encode(sha256(convert_to(upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')), 'UTF8')), 'hex')
$$;

-- Darf der angemeldete Nutzer (weiter) arbeiten? Einladungspflicht aus → immer
create or replace function private.beta_invite_ok()
returns boolean language sql stable security definer set search_path = '' as $$
  select not private.config_bool('release', 'invite_required')
      or exists (select 1 from public.users u
                 where u.auth_user_id = auth.uid()
                   and (u.beta_invite_id is not null or u.is_super_admin or cardinality(u.admin_roles) > 0 or u.tester_group = 'internal'))
      or exists (select 1 from public.organization_members m
                 where m.user_id = private.current_user_id() and m.status = 'active')
$$;

-- Serverseitige Sperre: neue Organisation (Hausbesitzer oder Servicepartner) nur mit Einladung
create or replace function private.organizations_beta_gate()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and coalesce(auth.role(), '') <> 'service_role' and not private.beta_invite_ok() then
    raise exception 'Husora ist gerade eine geschlossene Beta – bitte zuerst deinen Einladungscode eingeben.' using errcode = '42501';
  end if;
  return new;
end; $$;
drop trigger if exists organizations_beta_gate on public.organizations;
create trigger organizations_beta_gate before insert on public.organizations
  for each row execute function private.organizations_beta_gate();

create or replace function public.redeem_beta_invite(p_code text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_user   uuid := private.current_user_id();
  v_inv    public.beta_invites;
  v_tries  integer;
begin
  if v_user is null then raise exception 'Bitte zuerst anmelden' using errcode = '42501'; end if;
  delete from public.beta_invite_attempts a where a.created_at < now() - interval '1 day';
  select count(*) into v_tries from public.beta_invite_attempts a where a.user_id = v_user and a.created_at > now() - interval '1 hour';
  if v_tries >= 10 then raise exception 'Zu viele Versuche – bitte in einer Stunde erneut versuchen.' using errcode = 'P0001'; end if;
  insert into public.beta_invite_attempts (user_id) values (v_user);

  select * into v_inv from public.beta_invites i where i.code_hash = private.invite_hash(p_code) for update;
  -- Fehlversuche nicht per Exception melden (sonst würde der Versuch zurückgerollt und nie gezählt)
  if v_inv.id is null or not v_inv.active or (v_inv.expires_at is not null and v_inv.expires_at < now()) then
    return jsonb_build_object('ok', false, 'error', 'Dieser Einladungscode ist ungültig oder abgelaufen.');
  end if;
  if not exists (select 1 from public.beta_invite_redemptions r where r.invite_id = v_inv.id and r.user_id = v_user) then
    if v_inv.used_count >= v_inv.max_uses then return jsonb_build_object('ok', false, 'error', 'Dieser Einladungscode wurde bereits vollständig genutzt.'); end if;
    insert into public.beta_invite_redemptions (invite_id, user_id) values (v_inv.id, v_user);
    update public.beta_invites set used_count = used_count + 1 where id = v_inv.id;
  end if;
  update public.users u
  set beta_invite_id = v_inv.id,
      is_beta_user = true,
      beta_started_at = coalesce(u.beta_started_at, now()),
      beta_group = coalesce(u.beta_group, (select c.value ->> 'default_group' from public.app_config c where c.key = 'beta')),
      tester_group = coalesce(v_inv.tester_group, u.tester_group)
  where u.id = v_user;
  delete from public.beta_invite_attempts a where a.user_id = v_user;
  perform private.log_security_event('permission_change', null, 'beta_invite', v_inv.id, jsonb_build_object('action', 'redeem'));
  return public.my_beta_status() || jsonb_build_object('ok', true);
end; $$;

-- Admin: Code anlegen (Klartext nur in der Antwort), deaktivieren
create or replace function public.beta_invite_create(p_label text default null, p_tester_group text default null, p_max_uses integer default 1,
                                                     p_valid_days integer default 60, p_code text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_code text := upper(regexp_replace(coalesce(nullif(trim(p_code), ''),
                  'HUSORA-' || substr(md5(gen_random_uuid()::text), 1, 4) || '-' || substr(md5(gen_random_uuid()::text), 1, 4) || '-' || substr(md5(gen_random_uuid()::text), 1, 4)), '\s', '', 'g'));
  v_id   uuid;
begin
  if not private.has_admin_role('support_admin') then raise exception 'Nur für Husora-Admins (mit MFA)' using errcode = '42501'; end if;
  if length(v_code) < 8 or length(v_code) > 40 or v_code !~ '^[A-Z0-9-]+$' then
    raise exception 'Code: 8–40 Zeichen, nur Buchstaben, Ziffern und Bindestrich' using errcode = '22023';
  end if;
  insert into public.beta_invites (code_hash, code_hint, label, tester_group, max_uses, expires_at, created_by)
  values (private.invite_hash(v_code), '…' || right(v_code, 4), left(nullif(trim(p_label), ''), 120), p_tester_group,
          greatest(1, least(coalesce(p_max_uses, 1), 1000)),
          case when p_valid_days is null or p_valid_days <= 0 then null else now() + make_interval(days => least(p_valid_days, 365)) end,
          private.current_user_id())
  returning id into v_id;
  perform private.log_security_event('admin_action', null, 'beta_invite', v_id, jsonb_build_object('action', 'create', 'tester_group', p_tester_group, 'max_uses', p_max_uses));
  return jsonb_build_object('id', v_id, 'code', v_code);
exception when unique_violation then
  raise exception 'Diesen Code gibt es bereits' using errcode = '23505';
end; $$;

create or replace function public.beta_invite_set_active(p_id uuid, p_active boolean)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.has_admin_role('support_admin') then raise exception 'Nur für Husora-Admins (mit MFA)' using errcode = '42501'; end if;
  update public.beta_invites set active = p_active where id = p_id;
  perform private.log_security_event('admin_action', null, 'beta_invite', p_id, jsonb_build_object('action', case when p_active then 'activate' else 'deactivate' end));
end; $$;

-- Admin: vorhandenes Konto als Tester markieren (z. B. interne Tester)
create or replace function public.admin_set_beta_tester(p_email text, p_is_beta boolean, p_tester_group text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not private.has_admin_role('support_admin') then raise exception 'Nur für Husora-Admins (mit MFA)' using errcode = '42501'; end if;
  if p_tester_group is not null and p_tester_group not in ('homeowner', 'service_partner', 'internal') then
    raise exception 'Ungültige Testgruppe' using errcode = '22023';
  end if;
  update public.users u
  set is_beta_user = p_is_beta,
      beta_started_at = case when p_is_beta then coalesce(u.beta_started_at, now()) else u.beta_started_at end,
      beta_group = case when p_is_beta then coalesce(u.beta_group, (select c.value ->> 'default_group' from public.app_config c where c.key = 'beta')) else u.beta_group end,
      tester_group = case when p_is_beta then coalesce(p_tester_group, u.tester_group) else null end
  where lower(u.email) = lower(trim(p_email))
  returning u.id into v_id;
  if v_id is null then raise exception 'Kein Konto mit dieser E-Mail' using errcode = 'P0002'; end if;
  perform private.log_security_event('permission_change', null, 'beta_tester', v_id, jsonb_build_object('is_beta', p_is_beta, 'tester_group', p_tester_group));
  return jsonb_build_object('ok', true);
end; $$;

-- -----------------------------------------------------------------------------
-- 5) + 6) Status, Rollen, App-Version
-- -----------------------------------------------------------------------------
create or replace function public.my_beta_status()
returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'environment', (select c.value ->> 'name' from public.app_config c where c.key = 'environment'),
    'is_beta_tester', coalesce(u.is_beta_user, false),
    'tester_group', u.tester_group,
    'beta_group', u.beta_group,
    'invite_required', private.config_bool('release', 'invite_required'),
    'invite_redeemed', u.beta_invite_id is not null,
    'invite_ok', private.beta_invite_ok(),
    'roles', jsonb_build_object(
      'owner', exists (select 1 from public.organization_members m join public.organizations o on o.id = m.organization_id
                       where m.user_id = u.id and m.status = 'active' and o.org_type in ('homeowner', 'both')
                         and m.role not in ('service_partner', 'cleaner')),
      'partner', exists (select 1 from public.organization_members m join public.organizations o on o.id = m.organization_id
                         where m.user_id = u.id and m.status = 'active' and o.org_type in ('service_partner', 'both')),
      'admin', coalesce(u.is_super_admin, false) or cardinality(coalesce(u.admin_roles, '{}')) > 0))
  from public.users u
  where u.auth_user_id = auth.uid()
$$;

create or replace function public.report_app_session(p_app_version text, p_app_build text default null, p_platform text default null, p_environment text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_platform text := lower(left(coalesce(p_platform, ''), 20));
begin
  if auth.uid() is null then raise exception 'Bitte zuerst anmelden' using errcode = '42501'; end if;
  if v_platform !~ '^[a-z0-9-]{1,20}$' then v_platform := null; end if;
  update public.users u
  set app_platform = coalesce(v_platform, u.app_platform),
      last_app_version = left(nullif(trim(p_app_version), ''), 40),
      last_app_build = left(nullif(trim(p_app_build), ''), 20),
      last_environment = case when p_environment in ('development', 'staging', 'beta', 'production') then p_environment else u.last_environment end,
      last_seen_at = now()
  where u.auth_user_id = auth.uid();
  return public.my_beta_status();
end; $$;

-- -----------------------------------------------------------------------------
-- 7) Admin-Übersicht (pseudonymisiert: keine E-Mail, kein Name)
-- -----------------------------------------------------------------------------
create or replace function public.beta_testers_overview(p_limit integer default 200)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if not private.has_admin_role('support_admin') then raise exception 'Nur für Husora-Admins (mit MFA)' using errcode = '42501'; end if;
  with t as (
    select u.id, u.tester_group, u.beta_group, u.app_platform, u.last_app_version, u.last_app_build, u.last_environment, u.last_seen_at, u.beta_started_at,
           exists (select 1 from public.organization_members m join public.organizations o on o.id = m.organization_id
                   where m.user_id = u.id and m.status = 'active' and o.org_type in ('homeowner', 'both')
                     and m.role not in ('service_partner', 'cleaner')) as is_owner,
           exists (select 1 from public.organization_members m join public.organizations o on o.id = m.organization_id
                   where m.user_id = u.id and m.status = 'active' and o.org_type in ('service_partner', 'both')) as is_partner,
           (select jsonb_build_object('at', f.created_at, 'message', left(f.message, 80), 'version', f.app_version)
              from public.app_feedback f where f.user_id = u.id and f.kind in ('error', 'bug') order by f.created_at desc limit 1) as last_error
    from public.users u
    where u.is_beta_user
  )
  select jsonb_build_object(
    'totals', jsonb_build_object(
      'testers', (select count(*) from t),
      'active_7d', (select count(*) from t where t.last_seen_at > now() - interval '7 days'),
      'active_30d', (select count(*) from t where t.last_seen_at > now() - interval '30 days'),
      'by_group', (select coalesce(jsonb_object_agg(g, n), '{}') from (select coalesce(t.tester_group, 'ohne') g, count(*) n from t group by 1) x),
      'by_platform', (select coalesce(jsonb_object_agg(g, n), '{}') from (select coalesce(t.app_platform, 'unbekannt') g, count(*) n from t group by 1) x),
      'by_version', (select coalesce(jsonb_object_agg(g, n), '{}') from (select coalesce(t.last_app_version, 'unbekannt') g, count(*) n from t group by 1) x)),
    'invites', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'hint', i.code_hint, 'label', i.label, 'tester_group', i.tester_group,
                  'used', i.used_count, 'max', i.max_uses, 'expires_at', i.expires_at, 'active', i.active) order by i.created_at desc), '[]')
                from public.beta_invites i),
    'testers', (select coalesce(jsonb_agg(jsonb_build_object(
                  'ref', left(md5(t.id::text), 8),
                  'role', case when t.is_owner and t.is_partner then 'both' when t.is_partner then 'service_partner' when t.is_owner then 'homeowner' else 'none' end,
                  'tester_group', t.tester_group, 'beta_group', t.beta_group, 'platform', t.app_platform,
                  'version', t.last_app_version, 'build', t.last_app_build, 'environment', t.last_environment,
                  'last_seen', t.last_seen_at, 'joined', t.beta_started_at, 'last_error', t.last_error) order by t.last_seen_at desc nulls last), '[]')
                from (select * from t order by t.last_seen_at desc nulls last limit greatest(1, least(coalesce(p_limit, 200), 1000))) t))
  into v;
  return v;
end; $$;

-- -----------------------------------------------------------------------------
-- Rechte
-- -----------------------------------------------------------------------------
revoke all on function private.config_bool(text, text), private.invite_hash(text), private.beta_invite_ok() from public, anon;
grant execute on function private.config_bool(text, text), private.beta_invite_ok() to authenticated;
revoke all on function public.redeem_beta_invite(text), public.beta_invite_create(text, text, integer, integer, text),
  public.beta_invite_set_active(uuid, boolean), public.admin_set_beta_tester(text, boolean, text), public.my_beta_status(),
  public.report_app_session(text, text, text, text), public.beta_testers_overview(integer) from public, anon;
grant execute on function public.redeem_beta_invite(text), public.beta_invite_create(text, text, integer, integer, text),
  public.beta_invite_set_active(uuid, boolean), public.admin_set_beta_tester(text, boolean, text), public.my_beta_status(),
  public.report_app_session(text, text, text, text), public.beta_testers_overview(integer) to authenticated;

comment on function public.report_app_session(text, text, text, text) is 'App-Start/Login: Version, Build, Plattform, Umgebung (Spec §24). Antwort = my_beta_status().';

-- -----------------------------------------------------------------------------
-- 8) Umgebung „beta“ auch in Feedback, Fehlerberichten und Ereignissen zulassen
-- -----------------------------------------------------------------------------
alter table public.analytics_events drop constraint if exists analytics_events_environment_check;
alter table public.analytics_events add constraint analytics_events_environment_check
  check (environment is null or environment in ('production', 'staging', 'development', 'beta'));
alter table public.app_feedback drop constraint if exists app_feedback_beta_check;
alter table public.app_feedback add constraint app_feedback_beta_check check (
  (app_role is null or app_role in ('owner', 'partner', 'guest'))
  and (feedback_type is null or feedback_type in ('idea', 'problem', 'missing', 'unclear', 'praise', 'other'))
  and (title is null or length(title) <= 160)
  and (expected_behavior is null or length(expected_behavior) <= 2000)
  and (actual_behavior is null or length(actual_behavior) <= 2000)
  and (platform is null or length(platform) <= 40)
  and (environment is null or environment in ('production', 'staging', 'development', 'beta'))
  and (severity is null or severity in ('low', 'medium', 'high', 'critical'))
  and status in ('open', 'in_progress', 'resolved', 'wont_fix'));

-- track_events (aktueller Stand) – einzige Änderung: 'beta' als Umgebung
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
