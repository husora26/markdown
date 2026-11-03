-- =============================================================================
-- HUSORA · Beta-Tester-Steckbrief (einmalig, freiwillig, datensparsam)
-- =============================================================================
-- Kurze Angaben nach der ersten Anmeldung eines Beta-Testers – nur Auswahlfelder, keine Freitexte
-- außer einer groben Region (max. 60 Zeichen). Bewusst NICHT erhoben: Alter, Geschlecht, Telefon, Adresse.
--   * public.tester_profiles: eine Zeile je Nutzer, nur der Nutzer selbst liest/schreibt (über RPC)
--   * save_tester_profile(): speichern oder „überspringen“ (skipped = true)
--   * my_beta_status(): + profile_done (Steckbrief beantwortet oder übersprungen)
--   * beta_tester_profiles_summary(): Auswertung nur zusammengefasst (Admin mit MFA)
--   * export_my_data(): Steckbrief im Datenexport
-- Löschung: mit dem Konto (on delete cascade). Idempotent.

create table if not exists public.tester_profiles (
  user_id        uuid primary key references public.users(id) on update cascade on delete cascade,
  role           text check (role is null or role in ('owner', 'partner', 'both')),
  house_count    text check (house_count is null or house_count in ('1', '2-3', '4-10', '10+')),
  team_size      text check (team_size is null or team_size in ('1', '2-5', '6-20', '20+')),
  region         text check (region is null or length(region) <= 60),
  current_tool   text check (current_tool is null or current_tool in ('paper', 'excel', 'other_app', 'none', 'other')),
  source         text check (source is null or source in ('friend', 'search', 'social', 'partner', 'event', 'other')),
  interview_ok   boolean not null default false,
  skipped        boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
comment on table public.tester_profiles is 'Freiwilliger Beta-Tester-Steckbrief (Auswahlfelder). Auswertung nur zusammengefasst.';
drop trigger if exists tester_profiles_set_updated_at on public.tester_profiles;
create trigger tester_profiles_set_updated_at before update on public.tester_profiles
  for each row execute function private.set_updated_at();
alter table public.tester_profiles enable row level security;
drop policy if exists tester_profiles_own on public.tester_profiles;
create policy tester_profiles_own on public.tester_profiles for select to authenticated
  using (user_id = (select private.current_user_id()));
revoke all on public.tester_profiles from anon, authenticated;
grant select on public.tester_profiles to authenticated;

create or replace function public.save_tester_profile(p_profile jsonb, p_skip boolean default false)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := private.current_user_id();
  v_p    jsonb := coalesce(p_profile, '{}'::jsonb);
  pick   text;
begin
  if v_user is null then raise exception 'Bitte zuerst anmelden' using errcode = '42501'; end if;
  insert into public.tester_profiles (user_id, role, house_count, team_size, region, current_tool, source, interview_ok, skipped)
  values (v_user,
          case when not p_skip and v_p ->> 'role' in ('owner', 'partner', 'both') then v_p ->> 'role' end,
          case when not p_skip and v_p ->> 'house_count' in ('1', '2-3', '4-10', '10+') then v_p ->> 'house_count' end,
          case when not p_skip and v_p ->> 'team_size' in ('1', '2-5', '6-20', '20+') then v_p ->> 'team_size' end,
          case when not p_skip then left(nullif(trim(v_p ->> 'region'), ''), 60) end,
          case when not p_skip and v_p ->> 'current_tool' in ('paper', 'excel', 'other_app', 'none', 'other') then v_p ->> 'current_tool' end,
          case when not p_skip and v_p ->> 'source' in ('friend', 'search', 'social', 'partner', 'event', 'other') then v_p ->> 'source' end,
          not p_skip and coalesce((v_p ->> 'interview_ok')::boolean, false),
          p_skip)
  on conflict (user_id) do update set
    role = excluded.role, house_count = excluded.house_count, team_size = excluded.team_size, region = excluded.region,
    current_tool = excluded.current_tool, source = excluded.source, interview_ok = excluded.interview_ok, skipped = excluded.skipped;
  return jsonb_build_object('ok', true, 'skipped', p_skip);
end; $$;
revoke all on function public.save_tester_profile(jsonb, boolean) from public, anon;
grant execute on function public.save_tester_profile(jsonb, boolean) to authenticated;

-- Status um profile_done erweitern (Rest wie Migration 4500)
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
    'profile_done', exists (select 1 from public.tester_profiles t where t.user_id = u.id),
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

-- Auswertung nur zusammengefasst (keine Einzelprofile, keine Regionen mit < 3 Nennungen)
create or replace function public.beta_tester_profiles_summary()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if not private.has_admin_role('support_admin') then raise exception 'Nur für Husora-Admins (mit MFA)' using errcode = '42501'; end if;
  with p as (select * from public.tester_profiles where not skipped)
  select jsonb_build_object(
    'answered', (select count(*) from p),
    'skipped', (select count(*) from public.tester_profiles where skipped),
    'interview_ok', (select count(*) from p where interview_ok),
    'role', (select coalesce(jsonb_object_agg(k, n), '{}') from (select coalesce(role, 'keine Angabe') k, count(*) n from p group by 1) x),
    'house_count', (select coalesce(jsonb_object_agg(k, n), '{}') from (select house_count k, count(*) n from p where house_count is not null group by 1) x),
    'team_size', (select coalesce(jsonb_object_agg(k, n), '{}') from (select team_size k, count(*) n from p where team_size is not null group by 1) x),
    'current_tool', (select coalesce(jsonb_object_agg(k, n), '{}') from (select current_tool k, count(*) n from p where current_tool is not null group by 1) x),
    'source', (select coalesce(jsonb_object_agg(k, n), '{}') from (select source k, count(*) n from p where source is not null group by 1) x),
    'region', (select coalesce(jsonb_object_agg(k, n), '{}') from (select initcap(lower(trim(region))) k, count(*) n from p where region is not null group by 1 having count(*) >= 3) x))
  into v;
  return v;
end; $$;
revoke all on function public.beta_tester_profiles_summary() from public, anon;
grant execute on function public.beta_tester_profiles_summary() to authenticated;

-- Datenexport (Art. 15/20 DSGVO): Steckbrief ergänzen
do $$
declare v_src text;
begin
  select pg_get_functiondef('public.export_my_data()'::regprocedure) into v_src;
  if position('tester_profile' in v_src) = 0 then
    v_src := replace(v_src, '''privacy_requests'', (select',
      '''tester_profile'', (select to_jsonb(tp) from public.tester_profiles tp where tp.user_id = v_user),
    ''privacy_requests'', (select');
    execute v_src;
  end if;
end $$;

insert into public.retention_rules (data_type, retention_period, reason, deletion_method, legal_hold, category)
values ('tester_profiles', null, 'Beta-Steckbrief bis zur Kontolöschung', 'on_account_delete', false, 'product')
on conflict (data_type) do nothing;
